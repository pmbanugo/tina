#+private
package tina

import "core:testing"

MAX_REACTOR_SUBMISSION_BATCH :: REACTOR_SUBMISSION_BATCH_COUNT
MAX_REACTOR_COMPLETION_BATCH :: REACTOR_COMPLETION_BATCH_COUNT

#assert(MAX_REACTOR_SUBMISSION_BATCH <= int(max(u16)))
#assert(MAX_REACTOR_COMPLETION_BATCH <= int(max(u16)))

Reactor_Socket_Error :: enum u8 {
	None,
	Backend_Error,
	FD_Table_Full,
	Resource_Exhausted,
	Permission_Denied,
	Invalid_Argument,
	Unsupported,
}

Direction_Affinity :: enum u8 {
	Read,
	Write,
	Any,
}

@(private = "package")
FD_HANDOFF_TIMEOUT_TICKS :: u64(16)

// ============================================================================
// The Reactor
// ============================================================================
//
// Bridges the Platform_Backend with the Shard's Isolate handles and memory.
// It manages the FD table, the I/O slot pools, and accumulates I/O submissions
// for budgeted scheduler service points.

Reactor :: struct {
	backend:             Platform_Backend,
	pending_submissions: [MAX_REACTOR_SUBMISSION_BATCH]Submission,
	fd_table:            FD_Table,
	receive_pool:        IO_Slot_Pool,    // For recv/read/recvfrom (kernel writes here)
	staging_pool:        IO_Slot_Pool,    // For claim-based sends (Isolate writes here)
	pending_count:       u16,
	io_in_flight_count:  u32,
}

// Initialize the Reactor with memory carved from the Grand Arena.
reactor_init :: proc(
	reactor: ^Reactor,
	config: Backend_Config,
	fd_backing: []FD_Entry,
	receive_pool_config: IO_Slot_Pool_Config,
	staging_pool_config: IO_Slot_Pool_Config,
) -> Backend_Error {
	reactor.pending_count = 0
	reactor.io_in_flight_count = 0
	fd_table_init(&reactor.fd_table, fd_backing)
	io_slot_pool_init(
		&reactor.receive_pool,
		receive_pool_config.backing_memory,
		receive_pool_config.slot_size,
		receive_pool_config.slot_count,
	)
	io_slot_pool_init(
		&reactor.staging_pool,
		staging_pool_config.backing_memory,
		staging_pool_config.slot_size,
		staging_pool_config.slot_count,
	)

	backend_config := config
	backend_config.backing_memory_base = raw_data(receive_pool_config.backing_memory)
	backend_config.backing_memory_slot_size = receive_pool_config.slot_size
	backend_config.backing_memory_slot_count = receive_pool_config.slot_count
	backend_config.fd_slot_count = u16(len(fd_backing))

	error := backend_init(&reactor.backend, backend_config)
	if error != .None do return error
	return .None
}

@(private = "package")
reactor_init_tina_owned :: proc(
	reactor: ^Reactor,
	config: Backend_Config,
	fd_backing: []FD_Entry,
	receive_pool_config: IO_Slot_Pool_Config,
	staging_pool_config: IO_Slot_Pool_Config,
) -> Backend_Error {
	error := reactor_init(reactor, config, fd_backing, receive_pool_config, staging_pool_config)
	if error != .None do return error

	when TINA_ASAN_POISONING {
		if backend_recv_uses_provided_buffers(&reactor.backend) {
			_sanitizer_address_poison_io_pool_slots(&reactor.receive_pool)
		} else {
			for index in u16(0) ..< reactor.receive_pool.slot_count {
				_sanitizer_address_poison_io_slot_payload(&reactor.receive_pool, IO_Slot_Index(index))
			}
		}
		for index in u16(0) ..< reactor.staging_pool.slot_count {
			_sanitizer_address_poison_io_slot_payload(&reactor.staging_pool, IO_Slot_Index(index))
		}
	}
	return .None
}

reactor_deinit :: proc(reactor: ^Reactor) {
	when TINA_ASAN_POISONING {
		_sanitizer_address_unpoison_io_pool_slots(&reactor.receive_pool)
		_sanitizer_address_unpoison_io_pool_slots(&reactor.staging_pool)
	}
	backend_deinit(&reactor.backend)
	reactor.pending_count = 0
	reactor.io_in_flight_count = 0
}

reactor_socket_error_label :: #force_inline proc "contextless" (error: Reactor_Socket_Error) -> string {
	@(static, rodata)
	labels := [Reactor_Socket_Error]string {
		.None               = "none",
		.Backend_Error      = "backend error",
		.FD_Table_Full      = "fd table full",
		.Resource_Exhausted = "resource exhausted",
		.Permission_Denied  = "permission denied",
		.Invalid_Argument   = "invalid argument",
		.Unsupported        = "unsupported",
	}
	return labels[error]
}

@(private = "file")
_reactor_socket_error_from_backend_error :: #force_inline proc "contextless" (
	error: Backend_Error,
) -> Reactor_Socket_Error {
	#partial switch error {
	case .Resource_Exhausted:
		return .Resource_Exhausted
	case .Permission_Denied:
		return .Permission_Denied
	case .Invalid_Argument:
		return .Invalid_Argument
	case .Unsupported:
		return .Unsupported
	case:
		return .Backend_Error
	}
}

// ======================================
// Synchronous Control Wrappers (§6.6.3)
// ======================================

// Create a socket, register it in the FD table, and establish ownership.
reactor_control_socket :: proc(
	reactor: ^Reactor,
	owner: Isolate_Handle,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	FD_Handle,
	Reactor_Socket_Error,
) {

	os_fd, backend_error := backend_control_socket(&reactor.backend, domain, socket_type, protocol)
	if backend_error != .None do return FD_HANDLE_NONE, _reactor_socket_error_from_backend_error(backend_error)

	fd_handle, t_error := fd_table_alloc(&reactor.fd_table, os_fd, owner)
	if t_error != .None {
		backend_control_close(&reactor.backend, os_fd)
		return FD_HANDLE_NONE, .FD_Table_Full
	}

	backend_register_fixed_fd(&reactor.backend, fd_handle_index(fd_handle), os_fd)
	return fd_handle, .None
}

reactor_control_bind :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	address: Socket_Address,
) -> Backend_Error {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Any)
	if error != IO_ERR_NONE do return .Not_Found
	return backend_control_bind(&reactor.backend, os_fd, address)
}

reactor_control_listen :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	backlog: u32,
) -> Backend_Error {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Any)
	if error != IO_ERR_NONE do return .Not_Found
	return backend_control_listen(&reactor.backend, os_fd, backlog)
}

reactor_control_setsockopt :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Any)
	if error != IO_ERR_NONE do return .Not_Found
	return backend_control_setsockopt(&reactor.backend, os_fd, level, option, value)
}

reactor_control_getsockopt :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
) -> (
	Socket_Option_Value,
	Backend_Error,
) {
	os_fd, t_error := fd_table_resolve(&reactor.fd_table, fd)
	if t_error != .None do return nil, .Not_Found
	return backend_control_getsockopt(&reactor.backend, os_fd, level, option)
}

// Half-close a socket. Validates direction-scoped ownership (§6.6.3 §11).
reactor_control_shutdown :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	how: Shutdown_How,
) -> Backend_Error {
	dir: Direction_Affinity
	switch how {
	case .SHUT_READER:
		dir = .Read
	case .SHUT_WRITER:
		dir = .Write
	case .SHUT_BOTH:
		dir = .Any
	}

	os_fd, error := _resolve_os_fd(reactor, fd, owner, dir)
	if error != IO_ERR_NONE do return .Not_Found

	return backend_control_shutdown(&reactor.backend, os_fd, how)
}

reactor_control_close :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
) -> Backend_Error {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Any)
	if error != IO_ERR_NONE do return .Not_Found

	backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
	close_error := backend_control_close(&reactor.backend, os_fd)
	_ = fd_table_free(&reactor.fd_table, fd)
	return close_error
}

reactor_internal_close_fd :: proc "contextless" (reactor: ^Reactor, fd: FD_Handle) {
	os_fd, t_error := fd_table_resolve(&reactor.fd_table, fd)
	if t_error == .None {
		backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
		backend_control_close(&reactor.backend, os_fd)
		fd_table_free(&reactor.fd_table, fd)
	}
}

@(private = "package")
reactor_export_fd_handoff :: proc "contextless" (
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
) -> (
	OS_FD,
	Peer_Address,
	FD_Handoff_Result,
) {
	entry_index, error := fd_table_lookup_index(&reactor.fd_table, fd)
	if error != .None {
		return OS_FD_INVALID, {}, .invalid_fd_state
	}
	entry := &reactor.fd_table.entries[entry_index]
	if entry.reader_isolate != owner || entry.writer_isolate != owner {
		return OS_FD_INVALID, {}, .not_owner
	}
	if !fd_table_is_fresh_accept(entry) || fd_table_is_close_on_completion(entry) {
		return OS_FD_INVALID, {}, .invalid_fd_state
	}

	cleanup_fd := entry.os_fd
	peer_address := entry.peer_address
	backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
	_ = fd_table_free(&reactor.fd_table, fd)

	return cleanup_fd, peer_address, .ok
}

@(private = "package")
reactor_adopt_fd_handoff :: proc "contextless" (
	reactor: ^Reactor,
	owner: Isolate_Handle,
	os_fd: OS_FD,
	peer_address: Peer_Address,
) -> (
	FD_Handle,
	FD_Handoff_Reject_Reason,
) {
	adopted_fd, dup_error := backend_control_dup(&reactor.backend, os_fd)
	if dup_error == .Unsupported {
		return FD_HANDLE_NONE, .Unsupported
	}
	if dup_error != .None {
		return FD_HANDLE_NONE, .Adopt_Failed
	}

	fd_handle, fd_error := fd_table_alloc(&reactor.fd_table, adopted_fd, owner)
	if fd_error != .None {
		_ = backend_control_close(&reactor.backend, adopted_fd)
		return FD_HANDLE_NONE, .Adopt_Failed
	}

	backend_register_fixed_fd(&reactor.backend, fd_handle_index(fd_handle), adopted_fd)
	_ = fd_table_mark_fresh_accept(&reactor.fd_table, fd_handle, peer_address)
	return fd_handle, .None
}

// =====================================================
// Scheduler Loop Integration (§6.6.1 §5 & §6.6.2 §9)
// =====================================================

@(private = "file")
_reactor_completion_close_on_completion :: proc "contextless" (
	reactor: ^Reactor,
	soa_meta: #soa[]Isolate_Metadata,
	slot_index: u32,
) {
	fd_handle := soa_meta[slot_index].io_fd
	if fd_handle == FD_HANDLE_NONE {
		return
	}

	entry_index, error := fd_table_lookup_index(&reactor.fd_table, fd_handle)
	if error != .None {
		return
	}
	entry := &reactor.fd_table.entries[entry_index]
	if !fd_table_is_close_on_completion(entry) {
		return
	}

	reactor_internal_close_fd(reactor, fd_handle)
	soa_meta[slot_index].io_fd = FD_HANDLE_NONE
}

@(private = "file")
_reactor_completion_close_stale_accept_fd :: proc "contextless" (
	reactor: ^Reactor,
	completion: ^Raw_Completion,
) {
	if completion.result < 0 {
		return
	}

	#partial switch e in completion.extra {
	case Completion_Extra_Accept:
		if e.client_fd != OS_FD_INVALID {
			backend_control_close(&reactor.backend, e.client_fd)
		}
	}
}

@(private = "file")
_reactor_completion_apply_accept :: proc (
	reactor: ^Reactor,
	shard: ^Shard,
	soa_meta: #soa[]Isolate_Metadata,
	type_index: u8,
	slot_index: u32,
	completion: ^Raw_Completion,
) {
	#partial switch e in completion.extra {
	case Completion_Extra_Accept:
		soa_meta[slot_index].io_peer_address = socket_address_to_peer_address(e.client_address)

		if completion.result < 0 || e.client_fd == OS_FD_INVALID {
			soa_meta[slot_index].io_fd = FD_HANDLE_NONE
			return
		}

		owner := make_handle(
			shard.id,
			Isolate_Type_Id(type_index),
			Isolate_Slot_Index(slot_index),
			soa_meta[slot_index].generation,
		)
		fd_handle, fd_error := fd_table_alloc(&reactor.fd_table, e.client_fd, owner)
		if fd_error == .None {
			backend_register_fixed_fd(
				&reactor.backend,
				fd_handle_index(fd_handle),
				e.client_fd,
			)
			_ = fd_table_mark_fresh_accept(
				&reactor.fd_table,
				fd_handle,
				soa_meta[slot_index].io_peer_address,
			)
			soa_meta[slot_index].io_fd = fd_handle
			return
		}

		backend_control_close(&reactor.backend, e.client_fd)
		soa_meta[slot_index].io_result = i32(IO_ERR_RESOURCE_EXHAUSTED)
		soa_meta[slot_index].io_fd = FD_HANDLE_NONE
	}
}

@(private = "file")
_reactor_completion_apply_recvfrom :: proc (
	soa_meta: #soa[]Isolate_Metadata,
	slot_index: u32,
	completion: ^Raw_Completion,
) {
	#partial switch e in completion.extra {
	case Completion_Extra_Recvfrom:
		soa_meta[slot_index].io_peer_address = socket_address_to_peer_address(e.peer_address)
	}
}

reactor_collect_completions :: proc(reactor: ^Reactor, shard: ^Shard, timeout_ns: i64) {
	// Synthesized completions live in backend.completed even when
	// io_in_flight_count is zero, so we cannot short-circuit on the
	// count: the backend must still be called to drain them. The
	// kernel call inside backend_collect is cheap with timeout_ns == 0
	// and no in-flight ops.
	completions: [MAX_REACTOR_COMPLETION_BATCH]Raw_Completion

	count, error := backend_collect(&reactor.backend, completions[:], timeout_ns)
	if error != .None || count == 0 do return

	for i in 0 ..< count {
		completion := &completions[i]
		token := completion.token

		type_index := submission_token_type_index(token)
		slot_index := submission_token_slot_index(token)
		token_gen := submission_token_generation(token)
		token_seq := submission_token_io_sequence(token)
		buffer_index := submission_token_buffer_index(token)
		operation_kind := submission_token_operation_kind(token)

		// Every completion retires one in-flight op — unconditionally, before
		// any branching. The ledger must balance regardless of provenance
		// (kernel-delivered, synthesized, stale, or corrupt token).
		if reactor.io_in_flight_count > 0 {
			reactor.io_in_flight_count -= 1
		}

		// Bounds check — corrupt token, nothing safe to read from metadata.
		if int(type_index) >= len(shard.metadata) do continue
		soa_meta := shard.metadata[type_index]
		if int(slot_index) >= len(soa_meta) do continue

		// No_Buffer: the kernel's provided buffer ring was empty for this recv.
		// Re-submit transparently — the Isolate stays in Wait_IO and never
		// sees the transient failure.
		if .No_Buffer in completion.flags {
			shard.counters.io_recv_no_buffers_count += 1
			_reactor_resubmit_recv_after_no_buffer(
				reactor, shard, soa_meta, type_index, slot_index,
			)
			continue
		}

		// Classify: does this completion reach a live handler?
		//
		// The token carries an 8-bit projection of the 28-bit generation
		// (token layout §5.2, bits [28..35]). Combined with io_sequence
		// (8 bits), this gives 16-bit staleness discrimination — a false
		// live requires the slot to cycle 256 generations AND land on the
		// same io_sequence.
		//
		// .Synthesized is NOT checked here. It is provenance metadata
		// ("where did this completion come from"), not disposition metadata
		// ("what to do with it"). A synthesized completion for a dead
		// Isolate has a bumped generation → classified dead. A synthesized
		// completion for a live Isolate (e.g. _sweep_pending_for_fd cancelled
		// a peer's pending op) has a matching generation → classified live
		// and dispatched to the handler with result = -ECANCELED.
		is_live :=
			soa_meta[slot_index]._state != .Unallocated &&
			soa_meta[slot_index]._state != .Pending_IO_Reuse &&
			u8(soa_meta[slot_index].generation) == token_gen &&
			soa_meta[slot_index].io_sequence == token_seq

		if !is_live {
			// Dead: single reclamation pipeline. Every dead-completion
			// obligation is handled here — no other path, no helper function.
			_io_slot_return_to_pool(
				reactor, io_operation_pool_affinity(operation_kind), buffer_index,
			)
			_reactor_completion_close_on_completion(reactor, soa_meta, slot_index)

			if soa_meta[slot_index]._state == .Pending_IO_Reuse {
				soa_meta[slot_index].io_operation_kind = .None
				soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
				soa_meta[slot_index].io_fd = FD_HANDLE_NONE
				// Route through _slot_set_state so io_awaiting_count is
				// decremented and dispatchable bits are refreshed.
				_slot_set_state(shard, Isolate_Type_Id(type_index), Isolate_Slot_Index(slot_index), .Unallocated)
				soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_index]
				shard.isolate_free_heads[type_index] = slot_index
			}

			if operation_kind == .Accept_Complete {
				_reactor_completion_close_stale_accept_fd(reactor, completion)
			}

			shard.counters.io_stale_completions += 1
			continue
		}

		// Live: dispatch to handler.
		_slot_set_io_completion_ready(
			shard,
			Isolate_Type_Id(type_index),
			Isolate_Slot_Index(slot_index),
			operation_kind,
			completion.result,
			buffer_index,
		)

		if operation_kind == .Accept_Complete {
			_reactor_completion_apply_accept(
				reactor, shard, soa_meta, type_index, slot_index, completion,
			)
		} else if operation_kind == .Recvfrom_Complete {
			_reactor_completion_apply_recvfrom(soa_meta, slot_index, completion)
		}
	}
}

reactor_service_nonblocking :: proc(reactor: ^Reactor, shard: ^Shard) {
	reactor_collect_completions(reactor, shard, 0)
	reactor_flush_submissions_if_needed(reactor, shard)
}

reactor_has_io_work :: #force_inline proc "contextless" (reactor: ^Reactor) -> bool {
	return reactor.pending_count > 0 || reactor.io_in_flight_count > 0
}

@(private = "file")
_backend_error_to_io_error :: #force_inline proc "contextless" (error: Backend_Error) -> IO_Error {
	#partial switch error {
	case .Resource_Exhausted:
		return IO_ERR_RESOURCE_EXHAUSTED
	case .System_Error:
		return IO_ERR_BACKEND_FAILURE
	case .Queue_Full:
		return IO_ERR_SUBMISSION_FULL
	case:
		return IO_ERR_BACKEND_FAILURE
	}
}

reactor_flush_submissions :: proc(reactor: ^Reactor, shard: ^Shard) -> Backend_Error {
	if reactor.pending_count == 0 do return .None

	error := backend_submit(&reactor.backend, reactor.pending_submissions[:reactor.pending_count])

	// Fast-return on success
	if error == .None {
		reactor.io_in_flight_count += u32(reactor.pending_count)
		reactor.pending_count = 0
		return .None
	}

	// Error Path: Backend Queue Full
	shard.counters.io_submission_exhaustions += u64(reactor.pending_count)
	io_error := _backend_error_to_io_error(error)

	for i in 0 ..< reactor.pending_count {
		sub := &reactor.pending_submissions[i]
		type_index := submission_token_type_index(sub.token)
		slot_index := submission_token_slot_index(sub.token)
		buffer_index := submission_token_buffer_index(sub.token)

		// Flush failure: the SQE was never submitted to the kernel. Free
		// buffer slots directly to their pool's free list, bypassing the
		// provided buffer ring. On Linux with provided buffers active,
		// _io_slot_return_to_pool would dispatch receive buffers through
		// backend_replenish_recv_buffer — but the kernel never consumed
		// the buffer from the ring, so replenishing would double-add the
		// same buffer_id, corrupting the ring for subsequent recvs.
		flush_operation_kind := submission_token_operation_kind(sub.token)
		if buffer_index != IO_SLOT_INDEX_NONE {
			flush_affinity := io_operation_pool_affinity(flush_operation_kind)
			switch flush_affinity {
			case .Receive:
				_reactor_receive_pool_free(reactor, buffer_index)
			case .Staging:
				_reactor_staging_pool_free(reactor, buffer_index)
			case .None:
				// No pool slot — nothing to free
			}
		}

		soa_meta := shard.metadata[type_index]

		if u8(soa_meta[slot_index].generation) == submission_token_generation(sub.token) {
			_slot_set_io_submit_failure(
				shard,
				Isolate_Type_Id(type_index),
				Isolate_Slot_Index(slot_index),
				flush_operation_kind,
				i32(io_error),
			)
		}
	}

	reactor.pending_count = 0
	return error
}

reactor_flush_submissions_if_needed :: proc(reactor: ^Reactor, shard: ^Shard) {
	if reactor.pending_count < u16(REACTOR_SUBMISSION_FLUSH_THRESHOLD_COUNT) {
		return
	}
	reactor_flush_submissions(reactor, shard)
}

// ============================================================================
// I/O Submission Translation (§6.6.1 §4, §6.6.3 §6)
// ============================================================================

// Single boundary for receive-pool allocation. The kernel fills these slots
// asynchronously, so we use the unzeroed variant and observe exhaustion at
// the alloc site — not at the commit site — to keep counter attribution
// accurate regardless of the caller's submission path.
@(private, require_results)
_reactor_alloc_receive_slot :: proc(reactor: ^Reactor, shard: ^Shard) -> (IO_Slot_Index, IO_Error) {
	index: IO_Slot_Index
	error: IO_Slot_Pool_Error
	when TINA_ASAN_POISONING {
		index, error = io_slot_pool_alloc_unzeroed_tina_owned(&reactor.receive_pool)
	} else {
		index, error = io_slot_pool_alloc_unzeroed(&reactor.receive_pool)
	}
	if error != .None {
		shard.counters.io_receive_exhaustions += 1
		return IO_SLOT_INDEX_NONE, IO_ERR_RESOURCE_EXHAUSTED
	}
	return index, IO_ERR_NONE
}

// Reconstructs and re-queues a recv submission after the kernel returned
// -ENOBUFS (provided buffer ring empty). The Isolate remains in Wait_IO;
// the recv will be flushed on the next submission cycle by which time other
// completions will have replenished the ring.
@(private = "file")
_reactor_resubmit_recv_after_no_buffer :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	soa_meta: #soa[]Isolate_Metadata,
	type_index: u8,
	slot_index: u32,
) {
	// Liveness re-check: between the ENOBUFS completion and this resubmit, a
	// sibling completion processed in the same drain batch may have torn down
	// the slot or invalidated its in-flight I/O. Today the single-threaded
	// shard makes this rare, but the check is three cache-hot reads and makes
	// the invariant self-documenting (and safe under (possible?) future
	// multi-threaded completion handling).
	// A non-Wait_Io slot must not be re-submitted.
	if soa_meta[slot_index]._state != .Wait_Io do return

	fd_handle := soa_meta[slot_index].io_fd
	if fd_handle == FD_HANDLE_NONE do return

	os_fd, fd_error := fd_table_resolve(&reactor.fd_table, fd_handle)
	if fd_error != .None do return

	generation := u8(soa_meta[slot_index].generation)
	io_sequence := soa_meta[slot_index].io_sequence
	operation_kind := IO_Operation_Kind.Recv_Complete

	submission: Submission
	submission.data_pointer = nil
	submission.data_size = reactor.receive_pool.slot_size
	submission.operation = Submission_Op_Recv{fd_socket = os_fd}
	submission.fixed_file_index = FIXED_FILE_INDEX_NONE

	if backend_recv_uses_provided_buffers(&reactor.backend) {
		submission.fixed_file_index = fd_handle_index(fd_handle)
	}

	submission.token = submission_token_pack(
		type_index, slot_index, generation, io_sequence, IO_SLOT_INDEX_NONE, operation_kind,
	)

	if reactor.pending_count < MAX_REACTOR_SUBMISSION_BATCH {
		reactor.pending_submissions[reactor.pending_count] = submission
		reactor.pending_count += 1
	}
}

// Translates user IoOp to Platform Submission. Returns IO_Error on failure.
reactor_submit_io :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	io_op: IoOp,
	data_source: IO_Data_Source = .None,
	payload_offset: u16 = 0,
	payload_size: u32 = 0,
	staging_slot_index: IO_Slot_Index = IO_SLOT_INDEX_NONE,
) -> IO_Error {
	if reactor.pending_count >= MAX_REACTOR_SUBMISSION_BATCH {
		flush_error := reactor_flush_submissions(reactor, shard)
		if flush_error != .None {
			return _backend_error_to_io_error(flush_error)
		}
		reactor_service_nonblocking(reactor, shard)
		if reactor.pending_count >= MAX_REACTOR_SUBMISSION_BATCH {
			return IO_ERR_SUBMISSION_FULL
		}
	}

	type_index := extract_type_id(owner)
	slot_index := extract_slot(owner)
	soa_meta := shard.metadata[type_index]
	meta := &soa_meta[slot_index]

	// One-in-flight I/O invariant: an Isolate must not submit new I/O while
	// already in WAITING_FOR_IO. The io_sequence mechanism assumes at most one
	// in-flight operation per Isolate — if two were in flight, bumping the
	// sequence would only invalidate one, leaving the other to corrupt state.
	if meta._state == .Wait_Io {
		if _, is_close := io_op.(IoOp_Close); is_close {
			// A close supersedes the abandoned in-flight operation. Bump once to
			// stale the older completion, then again below for the new close
			// submission so the stale path and valid path stay disjoint.
			meta.io_sequence += 1
		} else {
			when TINA_RUNTIME_ASSERTIONS {
				assert(
					false,
					"One-in-flight I/O invariant violated: Isolate submitted while WAITING_FOR_IO",
				)
			}
		}
	}

	meta.io_sequence += 1
	seq := meta.io_sequence
	gen := u8(meta.generation)

	submission: Submission
	submission.fixed_file_index = FIXED_FILE_INDEX_NONE
	submission_op_kind: IO_Operation_Kind
	buffer_index: IO_Slot_Index = IO_SLOT_INDEX_NONE
	target_fd: FD_Handle = FD_HANDLE_NONE

	switch op in io_op {
	case IoOp_Read:
		target_fd = op.fd
		submission_op_kind = .Read_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Read)
		if error != IO_ERR_NONE do return error

		alloc_index, alloc_error := _reactor_alloc_receive_slot(reactor, shard)
		if alloc_error != IO_ERR_NONE do return alloc_error
		buffer_index = alloc_index

		submission.data_pointer = _io_slot_pool_pointer(&reactor.receive_pool, alloc_index)
		submission.data_size = op.buffer_size_max
		submission.operation = Submission_Op_Read{fd = os_fd, offset = op.offset}

	case IoOp_Write:
		target_fd = op.fd
		submission_op_kind = .Write_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write)
		if error != IO_ERR_NONE do return error

		switch data_source {
		case .Isolate_Struct:
			source_ptr, source_error := _compute_source_pointer(shard, type_index, slot_index, payload_offset, payload_size)
			if source_error != IO_ERR_NONE do return source_error
			submission.data_pointer = source_ptr
			submission.data_size = payload_size
		case .Staging_Slot:
			if payload_size > reactor.staging_pool.slot_size {
				return IO_ERR_BOUNDS_VIOLATION
			}
			submission.data_pointer = _io_slot_pool_pointer(&reactor.staging_pool, staging_slot_index)
			submission.data_size = payload_size
			buffer_index = staging_slot_index
		case .None:
			return IO_ERR_INVALID_DATA_SOURCE
		}
		submission.operation = Submission_Op_Write{fd = os_fd, offset = op.offset}

	case IoOp_Accept:
		target_fd = op.listen_fd
		submission_op_kind = .Accept_Complete
		os_fd, error := _resolve_os_fd(reactor, op.listen_fd, owner, .Read)
		if error != IO_ERR_NONE do return error
		submission.operation = Submission_Op_Accept {
			listen_fd = os_fd,
		}

	case IoOp_Connect:
		target_fd = op.fd
		submission_op_kind = .Connect_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write)
		if error != IO_ERR_NONE do return error
		submission.operation = Submission_Op_Connect {
			fd_socket = os_fd,
			address   = op.address,
		}

	case IoOp_Send:
		target_fd = op.fd
		submission_op_kind = .Send_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write)
		if error != IO_ERR_NONE do return error

		switch data_source {
		case .Isolate_Struct:
			source_ptr, source_error := _compute_source_pointer(shard, type_index, slot_index, payload_offset, payload_size)
			if source_error != IO_ERR_NONE do return source_error
			submission.data_pointer = source_ptr
			submission.data_size = payload_size
		case .Staging_Slot:
			if payload_size > reactor.staging_pool.slot_size {
				return IO_ERR_BOUNDS_VIOLATION
			}
			submission.data_pointer = _io_slot_pool_pointer(&reactor.staging_pool, staging_slot_index)
			submission.data_size = payload_size
			buffer_index = staging_slot_index
		case .None:
			return IO_ERR_INVALID_DATA_SOURCE
		}
		submission.operation = Submission_Op_Send{fd_socket = os_fd}

	case IoOp_Recv:
		target_fd = op.fd
		submission_op_kind = .Recv_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Read)
		if error != IO_ERR_NONE do return error

		// When the kernel manages the buffer ring, skip userspace alloc and
		// let the backend apply IOSQE_BUFFER_SELECT. The CQE will carry the
		// buffer_id, which the backend rewrites into the token's buffer_index.
		if backend_recv_uses_provided_buffers(&reactor.backend) {
			submission.data_pointer = nil
			submission.data_size = reactor.receive_pool.slot_size
		} else {
			alloc_index, alloc_error := _reactor_alloc_receive_slot(reactor, shard)
			if alloc_error != IO_ERR_NONE do return alloc_error
			buffer_index = alloc_index
			submission.data_pointer = _io_slot_pool_pointer(&reactor.receive_pool, alloc_index)
			submission.data_size = op.buffer_size_max
		}
		submission.operation = Submission_Op_Recv{fd_socket = os_fd}

	case IoOp_Sendto:
		target_fd = op.fd
		submission_op_kind = .Sendto_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write)
		if error != IO_ERR_NONE do return error

		switch data_source {
		case .Isolate_Struct:
			source_ptr, source_error := _compute_source_pointer(shard, type_index, slot_index, payload_offset, payload_size)
			if source_error != IO_ERR_NONE do return source_error
			submission.data_pointer = source_ptr
			submission.data_size = payload_size
		case .Staging_Slot:
			if payload_size > reactor.staging_pool.slot_size {
				return IO_ERR_BOUNDS_VIOLATION
			}
			submission.data_pointer = _io_slot_pool_pointer(&reactor.staging_pool, staging_slot_index)
			submission.data_size = payload_size
			buffer_index = staging_slot_index
		case .None:
			return IO_ERR_INVALID_DATA_SOURCE
		}
		submission.operation = Submission_Op_Sendto{fd_socket = os_fd, address = op.address}

	case IoOp_Recvfrom:
		target_fd = op.fd
		submission_op_kind = .Recvfrom_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Read)
		if error != IO_ERR_NONE do return error

		alloc_index, alloc_error := _reactor_alloc_receive_slot(reactor, shard)
		if alloc_error != IO_ERR_NONE do return alloc_error
		buffer_index = alloc_index

		submission.data_pointer = _io_slot_pool_pointer(&reactor.receive_pool, alloc_index)
		submission.data_size = op.buffer_size_max
		submission.operation = Submission_Op_Recvfrom{fd_socket = os_fd}

	case IoOp_Close:
		// Keep the logical handle in metadata so the eventual close completion can
		// identify which FD finished closing after the FD table entry is freed.
		target_fd = op.fd
		submission_op_kind = .Close_Complete
		os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Any)
		if error != IO_ERR_NONE do return error

		submission.operation = Submission_Op_Close {
			fd = os_fd,
		}
		backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(op.fd))
		fd_table_free(&reactor.fd_table, op.fd)

	case IoOp_Sendfile:
		target_fd = op.fd_socket
		submission_op_kind = .Sendfile_Complete

		file_os_fd, file_error := _resolve_os_fd(reactor, op.fd_file, owner, .Read)
		if file_error != IO_ERR_NONE do return file_error

		socket_os_fd, socket_error := _resolve_os_fd(reactor, op.fd_socket, owner, .Write)
		if socket_error != IO_ERR_NONE do return socket_error

		submission.operation = Submission_Op_Sendfile {
			fd_file       = file_os_fd,
			fd_socket     = socket_os_fd,
			source_offset = op.source_offset,
			size          = op.size,
		}
	}

	_reactor_submission_finalize(
		reactor,
		shard,
		type_index,
		slot_index,
		gen,
		seq,
		target_fd,
		buffer_index,
		submission_op_kind,
		submission,
	)

	return IO_ERR_NONE
}

// ================
// Internal Helpers
// ================

@(private = "file")
_compute_source_pointer :: #force_inline proc(
	shard: ^Shard,
	type_index: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	payload_offset: u16,
	payload_size: u32,
) -> ([^]u8, IO_Error) {
	stride := shard.type_descriptors[type_index].stride
	if int(payload_offset) + int(payload_size) > stride {
		return nil, IO_ERR_BOUNDS_VIOLATION
	}
	isolate_pointer := _get_isolate_ptr(shard, type_index, slot_index)
	return cast([^]u8)(uintptr(isolate_pointer) + uintptr(payload_offset)), IO_ERR_NONE
}

@(private = "file")
_reactor_submission_finalize :: #force_inline proc (
	reactor: ^Reactor,
	shard: ^Shard,
	type_index: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	generation: u8,
	sequence: u8,
	target_fd: FD_Handle,
	buffer_index: IO_Slot_Index,
	submission_op_kind: IO_Operation_Kind,
	submission: Submission,
) {
	submission_value := submission

	if target_fd != FD_HANDLE_NONE &&
	   submission_op_kind != .Close_Complete {
		submission_value.fixed_file_index = fd_handle_index(target_fd)
	}

	if target_fd != FD_HANDLE_NONE &&
	   submission_op_kind != .Accept_Complete &&
	   submission_op_kind != .Close_Complete {
		_ = fd_table_clear_fresh_accept(&reactor.fd_table, target_fd)
	}

	submission_value.token = submission_token_pack(
		u8(type_index),
		u32(slot_index),
		generation,
		sequence,
		buffer_index,
		submission_op_kind,
	)
	reactor.pending_submissions[reactor.pending_count] = submission_value
	reactor.pending_count += 1
	shard.metadata[type_index][slot_index].io_fd = target_fd
	shard.metadata[type_index][slot_index].io_operation_kind = submission_op_kind
	shard.metadata[type_index][slot_index].io_slot_index = buffer_index
	shard.metadata[type_index][slot_index].flags -= {.IO_Completion_Ready}
}

@(private = "package")
_io_op_to_operation_kind :: #force_inline proc(op: IoOp) -> IO_Operation_Kind {
	switch _ in op {
	case IoOp_Read:     return .Read_Complete
	case IoOp_Write:    return .Write_Complete
	case IoOp_Accept:   return .Accept_Complete
	case IoOp_Connect:  return .Connect_Complete
	case IoOp_Send:     return .Send_Complete
	case IoOp_Recv:     return .Recv_Complete
	case IoOp_Sendto:   return .Sendto_Complete
	case IoOp_Recvfrom: return .Recvfrom_Complete
	case IoOp_Close:    return .Close_Complete
	case IoOp_Sendfile: return .Sendfile_Complete
	}
	return .None
}

@(private = "file")
_resolve_os_fd :: #force_inline proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	dir: Direction_Affinity,
) -> (
	OS_FD,
	IO_Error,
) {
	entry_index, error := fd_table_lookup_index(&reactor.fd_table, fd)
	if error != .None do return OS_FD_INVALID, IO_ERR_STALE_FD
	entry := &reactor.fd_table.entries[entry_index]

	switch dir {
	case .Read:
		if fd_table_validate_read_affinity(entry, owner) != .None do return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
	case .Write:
		if fd_table_validate_write_affinity(entry, owner) != .None do return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
	case .Any:
		if fd_table_validate_read_affinity(entry, owner) != .None &&
		   fd_table_validate_write_affinity(entry, owner) != .None {
			return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
		}
	}
	return entry.os_fd, IO_ERR_NONE
}

// =====
// Tests
// =====

@(test)
test_reactor_init_deinit :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
		sim_config = Simulation_IO_Config{delay_range_ticks = {0, 0}, world = _world_ptr},
	}

	fd_backing: [16]FD_Entry
	buffer_backing: [1024 * 2]u8 // 2 slots of 1KB
	staging_backing: [1024]u8

	reactor := new(Reactor)
	defer free(reactor)
	error := reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 2}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	testing.expect_value(t, error, Backend_Error.None)
	testing.expect_value(t, reactor.pending_count, 0)
	testing.expect_value(t, reactor.fd_table.slot_count, 16)
	testing.expect_value(t, reactor.receive_pool.slot_count, 2)

	reactor_deinit(reactor)
}

@(test)
test_reactor_control_socket_and_shutdown :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{world = _world_ptr},
	}
	fd_backing: [4]FD_Entry
	buffer_backing: [1024]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 1}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	owner_handle := make_handle(0, 1, 0, 1)

	// 1. Create a socket
	fd_handle, sock_error := reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)
	testing.expect(t, fd_handle != FD_HANDLE_NONE, "Valid FD handle expected")

	// 2. Validate affinity checking on shutdown
	bad_owner := make_handle(0, 2, 0, 1) // Different type/Isolate

	shut_err_bad := reactor_control_shutdown(reactor, fd_handle, bad_owner, .SHUT_BOTH)
	testing.expect_value(t, shut_err_bad, Backend_Error.Not_Found) // Fails affinity check

	shut_err_ok := reactor_control_shutdown(reactor, fd_handle, owner_handle, .SHUT_WRITER)

	// Exact, strict assertions based on the testing environment:
	when TINA_SIMULATION_MODE {
		// In Simulation, the mock OS unconditionally succeeds to isolate the Reactor's logic.
		testing.expect_value(t, shut_err_ok, Backend_Error.None)
	} else {
		// On a real OS, shutting down an unconnected TCP socket is illegal (ENOTCONN).
		// Asserting .System_Error proves the Reactor successfully passed the request
		// through the affinity firewall and the OS correctly rejected the invalid state.
		testing.expect_value(t, shut_err_ok, Backend_Error.System_Error)
	}

	// 3. Test FD exhaustion
	_, _ = reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	_, _ = reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	_, _ = reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)

	_, exhaust_error := reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, exhaust_error, Reactor_Socket_Error.FD_Table_Full)
}

@(test)
test_fixed_file_sentinel_consistency :: proc(t: ^testing.T) {
	testing.expect_value(t, FIXED_FILE_INDEX_NONE, u16(FD_TABLE_NONE_INDEX))
}

@(test)
test_backend_error_to_io_error_maps_resource_exhausted :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		_backend_error_to_io_error(Backend_Error.Resource_Exhausted),
		IO_Error(IO_ERR_RESOURCE_EXHAUSTED),
	)
	testing.expect_value(
		t,
		_backend_error_to_io_error(Backend_Error.Queue_Full),
		IO_Error(IO_ERR_SUBMISSION_FULL),
	)
	testing.expect_value(
		t,
		_backend_error_to_io_error(Backend_Error.System_Error),
		IO_Error(IO_ERR_BACKEND_FAILURE),
	)
}

@(test)
test_reactor_has_io_work_tracks_pending_and_in_flight_counts :: proc(t: ^testing.T) {
	reactor := new(Reactor)
	defer free(reactor)

	testing.expect(t, !reactor_has_io_work(reactor), "empty reactor must not report I/O work")

	reactor.pending_count = 1
	testing.expect(t, reactor_has_io_work(reactor), "pending submissions are I/O work")

	reactor.pending_count = 0
	reactor.io_in_flight_count = 1
	testing.expect(t, reactor_has_io_work(reactor), "in-flight submissions are I/O work")
}

@(test)
test_close_submission_supersedes_waiting_io_sequence :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{world = _world_ptr},
	}
	fd_backing: [4]FD_Entry
	buffer_backing: [1024]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 1}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 2,
			slot_counts = {0, 1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	owner := make_handle(0, 1, 0, 1)
	test_shard_slot_activate(fixture, owner, .Wait_Io)
	shard.metadata[1][0].io_sequence = 7

	fd_handle, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

	io_error := reactor_submit_io(reactor, shard, owner, IoOp_Close {fd = fd_handle})
	testing.expect_value(t, io_error, IO_ERR_NONE)
	testing.expect_value(t, shard.metadata[1][0].io_sequence, u8(9))
	testing.expect_value(t, reactor.pending_count, u16(1))
	#partial switch close_op in reactor.pending_submissions[0].operation {
	case Submission_Op_Close:
		testing.expect_value(t, reactor.pending_submissions[0].fixed_file_index, FIXED_FILE_INDEX_NONE)
	case:
		testing.expect(t, false, "expected close submission")
	}
}

@(test)
test_fixed_file_index_set_on_recv :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}, world = _world_ptr},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 4}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	owner := make_handle(0, 1, 0, 1)

	// Create a socket owned by this handle
	fd_handle, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)
	testing.expect(t, fd_handle != FD_HANDLE_NONE, "Valid FD handle expected")

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 2,
			slot_counts = {0, 1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, owner, .Runnable)

	// Submit an IoOp_Recv
	io_error := reactor_submit_io(
		reactor,
		shard,
		owner,
		IoOp_Recv{fd = fd_handle, buffer_size_max = 512},
	)
	testing.expect_value(t, io_error, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 1)
	testing.expect_value(
		t,
		reactor.pending_submissions[0].fixed_file_index,
		fd_handle_index(fd_handle),
	)
}

@(test)
test_fixed_file_index_excluded_for_close :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}, world = _world_ptr},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 4}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	owner := make_handle(0, 1, 0, 1)

	fd_handle, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 2,
			slot_counts = {0, 1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, owner, .Runnable)

	// Submit a close — fixed_file_index must be NONE (safety invariant)
	io_error := reactor_submit_io(reactor, shard, owner, IoOp_Close{fd = fd_handle})
	testing.expect_value(t, io_error, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 1)
	testing.expect_value(t, reactor.pending_submissions[0].fixed_file_index, FIXED_FILE_INDEX_NONE)
}

@(test)
test_close_submission_preserves_fd_handle_for_completion_identity :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}, world = _world_ptr},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 4}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	owner := make_handle(0, 1, 0, 1)
	fd_handle, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 2,
			slot_counts = {0, 1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, owner, .Runnable)

	io_error := reactor_submit_io(reactor, shard, owner, IoOp_Close{fd = fd_handle})
	testing.expect_value(t, io_error, IO_ERR_NONE)
	testing.expect_value(t, shard.metadata[1][0].io_fd, fd_handle)

	_, resolve_error := fd_table_resolve(&reactor.fd_table, fd_handle)
	testing.expect_value(t, resolve_error, FD_Table_Error.Stale_Generation)
	// The fd table entry is already gone, so completion identity must come from
	// isolate metadata rather than a later table lookup.
	testing.expect_value(t, reactor.pending_submissions[0].fixed_file_index, FIXED_FILE_INDEX_NONE)
}

@(test)
test_fixed_file_close_then_reuse_ordering :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}, world = _world_ptr},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 4}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	owner := make_handle(0, 1, 0, 1)

	// Create a socket — gets slot N via LIFO
	fd_handle_a, _ := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	slot_a := fd_handle_index(fd_handle_a)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 2,
			slot_counts = {0, 1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, owner, .Runnable)

	// 1. Close fd_handle_a — frees slot back to free list
	io_err1 := reactor_submit_io(reactor, shard, owner, IoOp_Close{fd = fd_handle_a})
	testing.expect_value(t, io_err1, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 1)

	// Close submission must NOT use fixed file
	testing.expect_value(t, reactor.pending_submissions[0].fixed_file_index, FIXED_FILE_INDEX_NONE)

	// 2. Create a new socket — LIFO reuses slot_a
	fd_handle_b, _ := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	slot_b := fd_handle_index(fd_handle_b)
	testing.expect_value(t, slot_b, slot_a) // LIFO reuse: same slot index

	// 3. Simulate handle reuse: release the isolate slot and reactivate with
	// generation 2, then hand off the new FD and submit recv.
	test_shard_slot_release(fixture, 1, 0)
	owner_b := make_handle(0, 1, 0, 2)
	test_shard_slot_activate(fixture, owner_b, .Runnable)
	fd_table_handoff(&reactor.fd_table, fd_handle_b, owner_b, .Full)

	io_err2 := reactor_submit_io(
		reactor,
		shard,
		owner_b,
		IoOp_Recv{fd = fd_handle_b, buffer_size_max = 512},
	)
	testing.expect_value(t, io_err2, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 2)

	// Recv submission must use the slot index (same as slot_a, now pointing to new FD)
	testing.expect_value(t, reactor.pending_submissions[1].fixed_file_index, slot_b)
}

@(private = "package")
emergency_print_stalled_io_snapshot :: proc "contextless" (shard: ^Shard) {
	for type_index in 0 ..< len(shard.metadata) {
		soa_meta := shard.metadata[type_index]
		for slot_index in 0 ..< len(soa_meta) {
			if soa_meta[slot_index]._state == .Wait_Io {
				buf: [128]u8
				n := 0
				n = _sig_append_str(buf[:], n, "[STALLED IO] Shard: ")
				n = _sig_append_u64(buf[:], n, u64(shard.id))
				n = _sig_append_str(buf[:], n, " Type: ")
				n = _sig_append_u64(buf[:], n, u64(type_index))
				n = _sig_append_str(buf[:], n, " Slot: ")
				n = _sig_append_u64(buf[:], n, u64(slot_index))
				n = _sig_append_str(buf[:], n, " FD: ")
				n = _sig_append_u64(buf[:], n, u64(fd_handle_index(soa_meta[slot_index].io_fd)))
				n = _sig_append_str(buf[:], n, "\n")
				_write_stderr(buf[:n])
			}
		}
	}
}

when TINA_SIMULATION_MODE {
	// The equivalent is named test_io_sequence_stale_completion_reclamation
	// which is in the simulation test file, and runs only in simulation mode
	// Once I make the Simulation IO emulate the kqueue/IOCP/uring semantics,
	// I should remove one of them or merge the concepts.
	@(test)
	test_reactor_real_os_stale_completion_reclamation :: proc(t: ^testing.T) {
		// 1. Setup Backing Memory and Reactor
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		config := Backend_Config {
			queue_size = 32,
			sim_config = Simulation_IO_Config{world = _world},
		}

		fd_backing: [8]FD_Entry
		buffer_backing: [4096]u8
		staging_backing: [1024]u8

		reactor := new(Reactor)
		reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 1024, 4}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
		defer {reactor_deinit(reactor); free(reactor)}

		// 2. Setup Mock Shard Metadata
		fixture := test_shard_fixture_init(
			Test_Shard_Spec{
				type_count  = 1,
				slot_counts = {1},
				subsystems  = {.Metadata},
			},
		)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		owner := make_handle(0, 0, 0, 1)
		test_shard_slot_activate(fixture, owner, .Runnable)
		shard.metadata[0][0].io_sequence = 1

		// 3. Anchor the I/O: Create a UDP socket. It will block forever on Recv.
		fd, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .DGRAM, .UDP)
		testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

		bind_addr := Socket_Address_Inet4 {
			address = {127, 0, 0, 1},
			port    = 0,
		}
		reactor_control_bind(reactor, fd, owner, bind_addr)

		// 4. Submit Recv
		io_error := reactor_submit_io(
			reactor,
			shard,
			owner,
			IoOp_Recv{fd = fd, buffer_size_max = 512},
		)
		testing.expect_value(t, io_error, IO_ERR_NONE)

		// Buffer should be allocated
		testing.expect_value(t, reactor.receive_pool.free_count, 3)

		// Push to the OS kernel / Simulator
		reactor_flush_submissions(reactor, shard)

		// 5. Simulate the Timer Wake (The ADR Structural Guarantee)
		shard.metadata[0][0].io_sequence += 1
		_slot_set_state_no_dispatch(shard, 0, 0, .Runnable)

		// 6. Simulate Isolate closing the socket as a timeout response.
		// This triggers the kqueue sweep, the io_uring cancel, or the IOCP abort.
		reactor_internal_close_fd(reactor, fd)

		// 7. Collect Completions
		// Because kernel cancellation is asynchronous (especially on io_uring/IOCP),
		// we must poll a few times. The kqueue sweep is synchronous, but this loop
		// should safely handles all platforms.
		recovered := false
		for i in 0 ..< 50 {
			reactor_collect_completions(reactor, shard, 10_000_000) // 10ms wait
			if reactor.receive_pool.free_count == 4 {
				recovered = true
				break
			}
		}

		// 8. The Critical Assertions
		testing.expect(
			t,
			recovered,
			"Reactor buffer leaked! The OS completion was lost or never generated.",
		)
		testing.expect_value(t, reactor.receive_pool.free_count, 4)
		testing.expect_value(t, shard.counters.io_stale_completions, 1)
	}
}
