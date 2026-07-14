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

FD_Authority_Requirement :: enum u8 {
	Read_Direction,
	Write_Direction,
	Either_Direction,
	Both_Directions,
}

Reactor_Backend_State :: enum u8 {
	Uninitialized,
	Initialized,
	Collect_Faulted,
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
	backend_config:      Backend_Config,
	pending_submissions: [MAX_REACTOR_SUBMISSION_BATCH]Submission,
	fd_table:            FD_Table,
	receive_pool:        IO_Slot_Pool,    // For recv/read/recvfrom (kernel writes here)
	staging_pool:        IO_Slot_Pool,    // For claim-based sends (Isolate writes here)
	pending_count:       u16,
	backend_state:       Reactor_Backend_State,
	_padding:            u8,
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
	reactor.backend_state = .Uninitialized
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
	reactor.backend_config = backend_config

	error := backend_init(&reactor.backend, backend_config)
	if error != .None do return error
	reactor.backend_state = .Initialized
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
		for index in u16(0) ..< reactor.receive_pool.slot_count {
			_sanitizer_address_poison_io_slot_payload(&reactor.receive_pool, IO_Slot_Index(index))
		}
		for index in u16(0) ..< reactor.staging_pool.slot_count {
			_sanitizer_address_poison_io_slot_payload(&reactor.staging_pool, IO_Slot_Index(index))
		}
	}
	return .None
}

reactor_deinit :: proc(reactor: ^Reactor) {
	if reactor.backend_state == .Initialized {
		backend_deinit(&reactor.backend)
	} else if reactor.backend_state == .Collect_Faulted {
		quiesce_result := backend_quiesce_after_collect_fault(&reactor.backend)
		assert(quiesce_result == .Quiesced, "reactor deinit cannot reclaim memory before backend quiescence")
	}
	reactor.backend_state = .Uninitialized
	when TINA_ASAN_POISONING {
		_sanitizer_address_unpoison_io_pool_slots(&reactor.receive_pool)
		_sanitizer_address_unpoison_io_pool_slots(&reactor.staging_pool)
	}
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
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Both_Directions)
	if error != IO_ERR_NONE do return .Not_Found
	return backend_control_bind(&reactor.backend, os_fd, address)
}

reactor_control_listen :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	backlog: u32,
) -> Backend_Error {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Both_Directions)
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
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Both_Directions)
	if error != IO_ERR_NONE do return .Not_Found
	return backend_control_setsockopt(&reactor.backend, os_fd, level, option, value)
}

reactor_control_getsockopt :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	level: Socket_Level,
	option: Socket_Option,
) -> (
	Socket_Option_Value,
	Backend_Error,
) {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Either_Direction)
	if error != IO_ERR_NONE do return nil, .Not_Found
	return backend_control_getsockopt(&reactor.backend, os_fd, level, option)
}

// Half-close a socket. Validates direction-scoped ownership (§6.6.3 §11).
reactor_control_shutdown :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	how: Shutdown_How,
) -> Backend_Error {
	requirement: FD_Authority_Requirement
	switch how {
	case .SHUT_READER:
		requirement = .Read_Direction
	case .SHUT_WRITER:
		requirement = .Write_Direction
	case .SHUT_BOTH:
		requirement = .Both_Directions
	}

	os_fd, error := _resolve_os_fd(reactor, fd, owner, requirement)
	if error != IO_ERR_NONE do return .Not_Found

	return backend_control_shutdown(&reactor.backend, os_fd, how)
}

reactor_control_close :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
) -> Backend_Error {
	os_fd, error := _resolve_os_fd(reactor, fd, owner, .Both_Directions)
	if error != IO_ERR_NONE do return .Not_Found

	_ = backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
	close_error := backend_control_close(&reactor.backend, os_fd)
	when TINA_RUNTIME_ASSERTIONS {
		assert(close_error != .Invalid_Argument, "resolved FD became invalid before close")
	}
	_ = fd_table_free(&reactor.fd_table, fd)
	return close_error
}

reactor_internal_close_fd :: proc "contextless" (reactor: ^Reactor, fd: FD_Handle) {
	entry_index, t_error := fd_table_lookup_index(&reactor.fd_table, fd)
	if t_error == .None {
		entry := &reactor.fd_table.entries[entry_index]
		if entry.state == .Close_Queued || entry.state == .Close_In_Flight {
			return
		}
		os_fd := entry.os_fd
		_ = backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
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
	if entry.state != .Open {
		return OS_FD_INVALID, {}, .invalid_fd_state
	}
	if entry.reader_isolate != owner || entry.writer_isolate != owner {
		return OS_FD_INVALID, {}, .not_owner
	}
	if !fd_table_is_fresh_accept(entry) {
		return OS_FD_INVALID, {}, .invalid_fd_state
	}

	cleanup_fd := entry.os_fd
	peer_address := entry.peer_address
	_ = backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
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
	if !fd_table_is_close_after_current_io(entry) {
		return
	}

	reactor_internal_close_fd(reactor, fd_handle)
	soa_meta[slot_index].io_fd = FD_HANDLE_NONE
}

@(private = "file")
_reactor_completion_apply_close :: proc "contextless" (
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
	if entry.state != .Close_In_Flight {
		return
	}
	_ = fd_table_free(&reactor.fd_table, fd_handle)
}

@(private = "file")
_reactor_release_pending_io_reuse :: proc(
	shard: ^Shard,
	type_index: u8,
	slot_index: u32,
) {
	soa_meta := shard.metadata[type_index]
	soa_meta[slot_index].io_operation_kind = .None
	soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	soa_meta[slot_index].io_fd = FD_HANDLE_NONE
	_slot_set_state(
		shard,
		Isolate_Type_Id(type_index),
		Isolate_Slot_Index(slot_index),
		.Unallocated,
	)
	soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_index]
	shard.isolate_free_heads[type_index] = slot_index
	_sanitizer_address_poison_isolate_slot(
		shard,
		Isolate_Type_Id(type_index),
		Isolate_Slot_Index(slot_index),
	)
}

@(private = "file")
_reactor_completion_apply_accept :: proc (
	reactor: ^Reactor,
	shard: ^Shard,
	soa_meta: #soa[]Isolate_Metadata,
	type_index: u8,
	slot_index: u32,
	accept: ^Completion_Accept,
) {
	soa_meta[slot_index].io_peer_address = accept.peer_address

	owner := make_handle(
		shard.id,
		Isolate_Type_Id(type_index),
		Isolate_Slot_Index(slot_index),
		soa_meta[slot_index].generation,
	)
	fd_handle, fd_error := fd_table_alloc(&reactor.fd_table, accept.client_fd, owner)
	if fd_error == .None {
		backend_register_fixed_fd(
			&reactor.backend,
			fd_handle_index(fd_handle),
			accept.client_fd,
		)
		_ = fd_table_mark_fresh_accept(
			&reactor.fd_table,
			fd_handle,
			soa_meta[slot_index].io_peer_address,
		)
		soa_meta[slot_index].io_fd = fd_handle
		return
	}

	backend_control_close(&reactor.backend, accept.client_fd)
	soa_meta[slot_index].io_result = i32(IO_ERR_RESOURCE_EXHAUSTED)
	soa_meta[slot_index].io_fd = FD_HANDLE_NONE
}

@(private = "file")
_reactor_completion_result :: proc(completion: ^Raw_Completion) -> i32 {
	operation_kind := submission_token_operation_kind(completion.token)
	switch &outcome in completion.outcome {
	case Completion_Failure:
		assert(outcome.error_code < 0, "failed completion must carry a negative error code")
		switch operation_kind {
		case .Read_Complete, .Write_Complete, .Accept_Complete, .Connect_Complete,
		     .Send_Complete, .Recv_Complete, .Sendto_Complete,
		     .Recvfrom_Complete, .Close_Complete, .Sendfile_Complete:
			return outcome.error_code
		case .None:
			assert(false, "failed completion token must identify an operation")
		}
	case Completion_Transfer:
		assert(outcome.byte_count <= u32(max(i32)), "completion byte count exceeds i32 result capacity")
		switch operation_kind {
		case .Read_Complete, .Write_Complete, .Send_Complete, .Recv_Complete,
		     .Sendto_Complete, .Sendfile_Complete:
			return i32(outcome.byte_count)
		case .None, .Accept_Complete, .Connect_Complete, .Recvfrom_Complete,
		     .Close_Complete:
			assert(false, "operation kind cannot produce a transfer completion")
		}
	case Completion_Accept:
		assert(operation_kind == .Accept_Complete, "accept outcome requires an accept operation")
		assert(outcome.client_fd != OS_FD_INVALID, "accept outcome must carry a client fd")
		return 0
	case Completion_Datagram:
		assert(operation_kind == .Recvfrom_Complete, "datagram outcome requires a recvfrom operation")
		assert(outcome.byte_count <= u32(max(i32)), "datagram byte count exceeds i32 result capacity")
		return i32(outcome.byte_count)
	case Completion_Success:
		switch operation_kind {
		case .Connect_Complete, .Close_Complete:
			return 0
		case .None, .Read_Complete, .Write_Complete, .Accept_Complete,
		     .Send_Complete, .Recv_Complete, .Sendto_Complete,
		     .Recvfrom_Complete, .Sendfile_Complete:
			assert(false, "operation kind cannot produce a result-free success")
		}
	}
	assert(false, "completion outcome must produce a reactor result")
	return i32(IO_ERR_BACKEND_FAILURE)
}

@(private = "file")
_reactor_completion_is_live :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_index: u8,
	slot_index: u32,
	token: Submission_Token,
) -> bool {
	meta := &shard.metadata[type_index][slot_index]
	if meta._state == .Unallocated do return false
	if meta._state == .Pending_IO_Reuse do return false
	if u8(meta.generation) != submission_token_generation(token) do return false
	return meta.io_sequence == submission_token_io_sequence(token)
}

@(private = "file")
_reactor_completion_prepare_retire :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	completion: ^Raw_Completion,
) -> (
	type_index: u8,
	slot_index: u32,
	result: i32,
) {
	assert(reactor.io_in_flight_count > 0, "completion arrived without an accepted submission")
	reactor.io_in_flight_count -= 1

	token := completion.token
	type_index = submission_token_type_index(token)
	slot_index = submission_token_slot_index(token)
	assert(int(type_index) < len(shard.metadata), "completion token type index exceeds metadata")
	assert(int(slot_index) < len(shard.metadata[type_index]), "completion token slot index exceeds metadata")
	result = _reactor_completion_result(completion)
	return
}

@(private = "file")
_reactor_completion_retire_stale :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	type_index: u8,
	slot_index: u32,
	completion: ^Raw_Completion,
) {
	operation_kind := submission_token_operation_kind(completion.token)
	buffer_index := submission_token_buffer_index(completion.token)
	soa_meta := shard.metadata[type_index]

	_io_slot_return_to_pool(reactor, io_operation_pool_affinity(operation_kind), buffer_index)
	_reactor_completion_close_on_completion(reactor, soa_meta, slot_index)
	if operation_kind == .Close_Complete {
		_reactor_completion_apply_close(reactor, soa_meta, slot_index)
	}

	if soa_meta[slot_index]._state == .Pending_IO_Reuse {
		_reactor_release_pending_io_reuse(shard, type_index, slot_index)
	} else if soa_meta[slot_index]._state != .Unallocated {
		// A retired completion must clear its identity so later teardown cannot
		// wait for, or observe resources from, an operation that no longer exists.
		soa_meta[slot_index].io_operation_kind = .None
		soa_meta[slot_index].io_fd = FD_HANDLE_NONE
		soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	}

	switch &outcome in completion.outcome {
	case Completion_Accept:
		backend_control_close(&reactor.backend, outcome.client_fd)
	case Completion_Failure, Completion_Transfer, Completion_Datagram,
	     Completion_Success:
	}
	shard.counters.io_stale_completions += 1
}

@(private = "file")
_reactor_completion_publish_live :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	type_index: u8,
	slot_index: u32,
	result: i32,
	completion: ^Raw_Completion,
) {
	operation_kind := submission_token_operation_kind(completion.token)
	buffer_index := submission_token_buffer_index(completion.token)
	soa_meta := shard.metadata[type_index]

	_slot_set_io_completion_ready(
		shard, Isolate_Type_Id(type_index), Isolate_Slot_Index(slot_index),
		operation_kind, result, buffer_index,
	)
	switch &outcome in completion.outcome {
	case Completion_Failure:
		if operation_kind == .Accept_Complete {
			soa_meta[slot_index].io_fd = FD_HANDLE_NONE
		}
	case Completion_Accept:
		_reactor_completion_apply_accept(
			reactor, shard, soa_meta, type_index, slot_index, &outcome,
		)
	case Completion_Datagram:
		soa_meta[slot_index].io_peer_address = outcome.peer_address
	case Completion_Transfer, Completion_Success:
	}
	if operation_kind == .Close_Complete {
		_reactor_completion_apply_close(reactor, soa_meta, slot_index)
	}
}

@(private = "file")
_reactor_completion_retire :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	completion: ^Raw_Completion,
) {
	token := completion.token
	type_index, slot_index, result := _reactor_completion_prepare_retire(reactor, shard, completion)

	if _reactor_completion_is_live(shard, type_index, slot_index, token) {
		_reactor_completion_publish_live(reactor, shard, type_index, slot_index, result, completion)
	} else {
		_reactor_completion_retire_stale(reactor, shard, type_index, slot_index, completion)
	}
}

reactor_collect_completions :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	timeout_ns: i64,
) -> Backend_Collect_Fault {
	// Backend-owned synthesized completions may exist with no kernel operation,
	// so collection cannot short-circuit on io_in_flight_count.
	completions: [MAX_REACTOR_COMPLETION_BATCH]Raw_Completion
	collect_result := backend_collect(&reactor.backend, completions[:], timeout_ns)
	if collect_result.fault == .None {
		for completion_index in 0 ..< collect_result.completion_count {
			_reactor_completion_retire(reactor, shard, &completions[completion_index])
		}
		return .None
	}

	reactor.backend_state = .Collect_Faulted
	for completion_index in 0 ..< collect_result.completion_count {
		completion := &completions[completion_index]
		type_index, slot_index, _ := _reactor_completion_prepare_retire(
			reactor,
			shard,
			completion,
		)
		_reactor_completion_retire_stale(reactor, shard, type_index, slot_index, completion)
	}
	shard.counters.io_backend_fault_count += 1
	return collect_result.fault
}

reactor_service_nonblocking :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
) -> Backend_Collect_Fault {
	fault := reactor_collect_completions(reactor, shard, 0)
	if fault != .None {
		return fault
	}
	reactor_flush_submissions_if_needed(reactor, shard)
	return .None
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

	submit_error := backend_submit(&reactor.backend, reactor.pending_submissions[:reactor.pending_count])

	if submit_error == .None {
		reactor.io_in_flight_count += u32(reactor.pending_count)
		for i in 0 ..< reactor.pending_count {
			submission := &reactor.pending_submissions[i]
			if submission_token_operation_kind(submission.token) != .Close_Complete {
				continue
			}
			fd_handle := shard.metadata[submission_token_type_index(submission.token)][submission_token_slot_index(submission.token)].io_fd
			transition_error := fd_table_mark_close_in_flight(&reactor.fd_table, fd_handle)
			assert(transition_error == .None, "accepted close must transition from Close_Queued to Close_In_Flight")
			_ = backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd_handle))
		}

		// Completion-style backends own pooled buffers after successful submit.
		// Readiness backends poison around their deferred syscalls instead.
		when TINA_ASAN_POISONING && BACKEND_POOL_BUFFER_OWNED_AFTER_SUBMIT {
			for i in 0 ..< reactor.pending_count {
				sub := &reactor.pending_submissions[i]
				buffer_index := submission_token_buffer_index(sub.token)
				if buffer_index == IO_SLOT_INDEX_NONE do continue
				operation_kind := submission_token_operation_kind(sub.token)
				affinity := io_operation_pool_affinity(operation_kind)
				_sanitizer_address_poison_inflight_io_slot(reactor, affinity, buffer_index)
			}
		}

		reactor.pending_count = 0
		return .None
	}

	// Rejected before ownership: reclaim every pending operation locally.
	shard.counters.io_submission_exhaustions += u64(reactor.pending_count)
	io_error := _backend_error_to_io_error(submit_error)

	for i in 0 ..< reactor.pending_count {
		sub := &reactor.pending_submissions[i]
		type_index := submission_token_type_index(sub.token)
		slot_index := submission_token_slot_index(sub.token)
		buffer_index := submission_token_buffer_index(sub.token)

		// Rejection occurs before backend ownership, so reclaim pooled slots
		// directly and restore any queued close transition.
		flush_operation_kind := submission_token_operation_kind(sub.token)
		if flush_operation_kind == .Close_Complete {
			fd_handle := shard.metadata[type_index][slot_index].io_fd
			restore_error := fd_table_restore_open_from_close_queued(&reactor.fd_table, fd_handle)
			assert(restore_error == .None, "rejected close must restore Close_Queued to Open")
		}
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
		} else if soa_meta[slot_index]._state == .Pending_IO_Reuse {
			reactor_internal_close_fd(reactor, soa_meta[slot_index].io_fd)
			_reactor_release_pending_io_reuse(shard, type_index, slot_index)
		}
	}

	reactor.pending_count = 0
	return submit_error
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

Reactor_Submission_Build :: struct {
	submission:     Submission,
	target_fd:      FD_Handle,
	buffer_index:   IO_Slot_Index,
	operation_kind: IO_Operation_Kind,
}

@(private = "file")
_reactor_submission_build_source :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	type_index: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	data_source: IO_Data_Source,
	payload_offset: u16,
	payload_size: u32,
	staging_slot_index: IO_Slot_Index,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	switch data_source {
	case .Isolate_Struct:
		source, error := _compute_source_pointer(
			shard, type_index, slot_index, payload_offset, payload_size,
		)
		if error != IO_ERR_NONE do return error
		build.submission.data_pointer = source
	case .Staging_Slot:
		assert(staging_slot_index != IO_SLOT_INDEX_NONE, "staging source requires an owned slot")
		assert(
			u16(staging_slot_index) < reactor.staging_pool.slot_count,
			"staging source index exceeds pool capacity",
		)
		if payload_size > reactor.staging_pool.slot_size do return IO_ERR_BOUNDS_VIOLATION
		build.submission.data_pointer = _io_slot_pool_pointer(&reactor.staging_pool, staging_slot_index)
		build.buffer_index = staging_slot_index
	case .None:
		return IO_ERR_INVALID_DATA_SOURCE
	}
	build.submission.data_size = payload_size
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_receive :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	buffer_size_max: u32,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	if buffer_size_max > reactor.receive_pool.slot_size do return IO_ERR_BOUNDS_VIOLATION
	buffer_index, alloc_error := _reactor_alloc_receive_slot(reactor, shard)
	if alloc_error != IO_ERR_NONE do return alloc_error
	build.buffer_index = buffer_index
	build.submission.data_pointer = _io_slot_pool_pointer(&reactor.receive_pool, buffer_index)
	build.submission.data_size = buffer_size_max
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_read :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	op: IoOp_Read,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Read_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Read_Direction)
	if error != IO_ERR_NONE do return error
	error = _reactor_submission_build_receive(reactor, shard, op.buffer_size_max, build)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Read{fd = os_fd, offset = op.offset}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_write :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	op: IoOp_Write,
	data_source: IO_Data_Source,
	payload_offset: u16,
	payload_size: u32,
	staging_slot_index: IO_Slot_Index,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Write_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write_Direction)
	if error != IO_ERR_NONE do return error
	type_index := extract_type_id(owner)
	slot_index := extract_slot(owner)
	error = _reactor_submission_build_source(
		reactor, shard, type_index, slot_index, data_source,
		payload_offset, payload_size, staging_slot_index, build,
	)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Write{fd = os_fd, offset = op.offset}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_accept :: proc(
	reactor: ^Reactor,
	owner: Isolate_Handle,
	op: IoOp_Accept,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.listen_fd
	build.operation_kind = .Accept_Complete
	os_fd, error := _resolve_os_fd(reactor, op.listen_fd, owner, .Read_Direction)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Accept{listen_fd = os_fd}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_connect :: proc(
	reactor: ^Reactor,
	owner: Isolate_Handle,
	op: IoOp_Connect,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Connect_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write_Direction)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Connect{fd_socket = os_fd, address = op.address}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_send :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	op: IoOp_Send,
	data_source: IO_Data_Source,
	payload_offset: u16,
	payload_size: u32,
	staging_slot_index: IO_Slot_Index,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Send_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write_Direction)
	if error != IO_ERR_NONE do return error
	error = _reactor_submission_build_source(
		reactor, shard, extract_type_id(owner), extract_slot(owner), data_source,
		payload_offset, payload_size, staging_slot_index, build,
	)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Send{fd_socket = os_fd}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_recv :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	op: IoOp_Recv,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Recv_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Read_Direction)
	if error != IO_ERR_NONE do return error
	error = _reactor_submission_build_receive(reactor, shard, op.buffer_size_max, build)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Recv{fd_socket = os_fd}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_sendto :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	op: IoOp_Sendto,
	data_source: IO_Data_Source,
	payload_offset: u16,
	payload_size: u32,
	staging_slot_index: IO_Slot_Index,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Sendto_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Write_Direction)
	if error != IO_ERR_NONE do return error
	error = _reactor_submission_build_source(
		reactor, shard, extract_type_id(owner), extract_slot(owner), data_source,
		payload_offset, payload_size, staging_slot_index, build,
	)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Sendto{fd_socket = os_fd, address = op.address}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_recvfrom :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	op: IoOp_Recvfrom,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Recvfrom_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Read_Direction)
	if error != IO_ERR_NONE do return error
	error = _reactor_submission_build_receive(reactor, shard, op.buffer_size_max, build)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Recvfrom{fd_socket = os_fd}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_close :: proc(
	reactor: ^Reactor,
	owner: Isolate_Handle,
	op: IoOp_Close,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd
	build.operation_kind = .Close_Complete
	os_fd, error := _resolve_os_fd(reactor, op.fd, owner, .Both_Directions)
	if error != IO_ERR_NONE do return error
	build.submission.operation = Submission_Op_Close{fd = os_fd}
	queue_error := fd_table_mark_close_queued(&reactor.fd_table, op.fd)
	assert(queue_error == .None, "validated close must transition from Open to Close_Queued")
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_build_sendfile :: proc(
	reactor: ^Reactor,
	owner: Isolate_Handle,
	op: IoOp_Sendfile,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = op.fd_socket
	build.operation_kind = .Sendfile_Complete
	file_fd, error := _resolve_os_fd(reactor, op.fd_file, owner, .Read_Direction)
	if error != IO_ERR_NONE do return error
	socket_fd, socket_error := _resolve_os_fd(reactor, op.fd_socket, owner, .Write_Direction)
	if socket_error != IO_ERR_NONE do return socket_error
	build.submission.operation = Submission_Op_Sendfile {
		fd_file = file_fd, fd_socket = socket_fd,
		source_offset = op.source_offset, size = op.size,
	}
	return IO_ERR_NONE
}

@(private = "file")
_reactor_submission_translate :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Isolate_Handle,
	io_op: IoOp,
	data_source: IO_Data_Source,
	payload_offset: u16,
	payload_size: u32,
	staging_slot_index: IO_Slot_Index,
	build: ^Reactor_Submission_Build,
) -> IO_Error {
	build.target_fd = FD_HANDLE_NONE
	build.buffer_index = IO_SLOT_INDEX_NONE
	build.submission.fixed_file_index = FIXED_FILE_INDEX_NONE

	switch op in io_op {
	case IoOp_Read:
		return _reactor_submission_build_read(reactor, shard, owner, op, build)
	case IoOp_Write:
		return _reactor_submission_build_write(
			reactor, shard, owner, op, data_source, payload_offset,
			payload_size, staging_slot_index, build,
		)
	case IoOp_Accept:
		return _reactor_submission_build_accept(reactor, owner, op, build)
	case IoOp_Connect:
		return _reactor_submission_build_connect(reactor, owner, op, build)
	case IoOp_Send:
		return _reactor_submission_build_send(
			reactor, shard, owner, op, data_source, payload_offset,
			payload_size, staging_slot_index, build,
		)
	case IoOp_Recv:
		return _reactor_submission_build_recv(reactor, shard, owner, op, build)
	case IoOp_Sendto:
		return _reactor_submission_build_sendto(
			reactor, shard, owner, op, data_source, payload_offset,
			payload_size, staging_slot_index, build,
		)
	case IoOp_Recvfrom:
		return _reactor_submission_build_recvfrom(reactor, shard, owner, op, build)
	case IoOp_Close:
		return _reactor_submission_build_close(reactor, owner, op, build)
	case IoOp_Sendfile:
		return _reactor_submission_build_sendfile(reactor, owner, op, build)
	}
	// IoOp is closed: the compiler rejects a switch that omits any variant.
	unreachable()
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
		assert(reactor.pending_count == 0, "successful flush must consume every pending submission")
	}

	type_index := extract_type_id(owner)
	slot_index := extract_slot(owner)
	soa_meta := shard.metadata[type_index]
	meta := &soa_meta[slot_index]

	// Scheduler state is not an ownership ledger: timeout and shutdown may make
	// an Isolate Runnable while its accepted operation is still outstanding.
	// Only a retired completion permits the next submission.
	if meta.io_operation_kind != .None &&
	   .IO_Completion_Ready not_in meta.flags {
		return IO_ERR_SUBMISSION_FULL
	}

	meta.io_sequence += 1
	seq := meta.io_sequence
	gen := u8(meta.generation)

	build: Reactor_Submission_Build
	build_error := _reactor_submission_translate(
		reactor, shard, owner, io_op, data_source, payload_offset,
		payload_size, staging_slot_index, &build,
	)
	if build_error != IO_ERR_NONE do return build_error

	_reactor_submission_finalize(
		reactor,
		shard,
		type_index,
		slot_index,
		gen,
		seq,
		build.target_fd,
		build.buffer_index,
		build.operation_kind,
		build.submission,
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
	payload_start := int(payload_offset)
	payload_end := payload_start + int(payload_size)
	if payload_end > stride {
		return nil, IO_ERR_BOUNDS_VIOLATION
	}
	isolate_pointer := _get_isolate_ptr(shard, type_index, slot_index)
	if isolate_pointer == nil {
		if payload_start == 0 && payload_size == 0 {
			return nil, IO_ERR_NONE
		}
		return nil, IO_ERR_BOUNDS_VIOLATION
	}
	isolate_bytes := (cast([^]u8)isolate_pointer)[:stride]
	return raw_data(isolate_bytes[payload_start:]), IO_ERR_NONE
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
	when TINA_ASAN_POISONING {
		if buffer_index != IO_SLOT_INDEX_NONE {
			switch io_operation_pool_affinity(submission_op_kind) {
			case .Receive:
				submission_value.sanitizer_slot_size = reactor.receive_pool.slot_size
			case .Staging:
				submission_value.sanitizer_slot_size = reactor.staging_pool.slot_size
			case .None:
			}
		}
	}
	assert(reactor.pending_count < MAX_REACTOR_SUBMISSION_BATCH, "submission finalize requires preflighted pending capacity")
	reactor.pending_submissions[reactor.pending_count] = submission_value
	reactor.pending_count += 1
	shard.metadata[type_index][slot_index].io_fd = target_fd
	shard.metadata[type_index][slot_index].io_operation_kind = submission_op_kind
	shard.metadata[type_index][slot_index].io_slot_index = buffer_index
	shard.metadata[type_index][slot_index].flags -= {.IO_Completion_Ready}
}

@(private = "package")
_io_op_to_operation_kind :: #force_inline proc "contextless" (operation: IoOp) -> IO_Operation_Kind {
	switch _ in operation {
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
_resolve_os_fd :: #force_inline proc "contextless" (
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Isolate_Handle,
	requirement: FD_Authority_Requirement,
) -> (
	OS_FD,
	IO_Error,
) {
	entry_index, error := fd_table_lookup_index(&reactor.fd_table, fd)
	if error != .None do return OS_FD_INVALID, IO_ERR_STALE_FD
	entry := &reactor.fd_table.entries[entry_index]
	if entry.state != .Open do return OS_FD_INVALID, IO_ERR_STALE_FD

	switch requirement {
	case .Read_Direction:
		if fd_table_validate_read_affinity(entry, owner) != .None do return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
	case .Write_Direction:
		if fd_table_validate_write_affinity(entry, owner) != .None do return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
	case .Either_Direction:
		if fd_table_validate_read_affinity(entry, owner) != .None {
			if fd_table_validate_write_affinity(entry, owner) != .None {
				return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
			}
		}
	case .Both_Directions:
		if fd_table_validate_read_affinity(entry, owner) != .None do return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
		if fd_table_validate_write_affinity(entry, owner) != .None do return OS_FD_INVALID, IO_ERR_AFFINITY_VIOLATION
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
test_close_submission_advances_sequence_once :: proc(t: ^testing.T) {
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
	test_shard_slot_activate(fixture, owner, .Runnable)
	shard.metadata[1][0].io_sequence = 7

	fd_handle, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

	io_error := reactor_submit_io(reactor, shard, owner, IoOp_Close {fd = fd_handle})
	testing.expect_value(t, io_error, IO_ERR_NONE)
	testing.expect_value(t, shard.metadata[1][0].io_sequence, u8(8))
	testing.expect_value(t, reactor.pending_count, u16(1))
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

	entry_index, resolve_error := fd_table_lookup_index(&reactor.fd_table, fd_handle)
	testing.expect_value(t, resolve_error, FD_Table_Error.None)
	testing.expect_value(t, reactor.fd_table.entries[entry_index].state, FD_Entry_State.Close_Queued)
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

	// 1. Queue close. The FD slot remains reserved until backend completion.
	io_err1 := reactor_submit_io(reactor, shard, owner, IoOp_Close{fd = fd_handle_a})
	testing.expect_value(t, io_err1, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 1)

	// Close submission must NOT use fixed file
	testing.expect_value(t, reactor.pending_submissions[0].fixed_file_index, FIXED_FILE_INDEX_NONE)

	// 2. A new socket cannot alias the close identity before completion.
	fd_handle_b, _ := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	slot_b := fd_handle_index(fd_handle_b)
	testing.expect(t, slot_b != slot_a, "queued close must retain its FD slot")

	// 3. Completion releases slot_a, restoring deterministic LIFO reuse.
	flush_error := reactor_flush_submissions(reactor, shard)
	testing.expect_value(t, flush_error, Backend_Error.None)
	when TINA_SIMULATION_MODE {
		backend_set_current_tick(&reactor.backend, 200)
	}
	reactor_collect_completions(reactor, shard, 0)

	fd_handle_c, _ := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, fd_handle_index(fd_handle_c), slot_a)
}

// Oversized receive must be rejected before any pool slot is allocated.
// This prevents the kernel from writing past the end of a preallocated slot.
@(test)
test_oversized_receive_rejected_before_allocation :: proc(t: ^testing.T) {
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
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 512, 2}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
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

	free_before := reactor.receive_pool.free_count

	io_error := reactor_submit_io(
		reactor, shard, owner,
		IoOp_Recv{fd = fd_handle, buffer_size_max = 1024},
	)
	testing.expect_value(t, io_error, IO_ERR_BOUNDS_VIOLATION)

	// No pool slot was consumed — the rejection happened before allocation.
	testing.expect_value(t, reactor.receive_pool.free_count, free_before)
}

// Stale completion (e.g. from shutdown io_sequence bump) must clear its I/O
// identity so later teardown cannot quarantine the slot in Pending_IO_Reuse
// or observe resources from an operation that no longer exists.
@(test)
test_stale_completion_clears_io_identity :: proc(t: ^testing.T) {
	_world_ptr: rawptr
	when TINA_SIMULATION_MODE {
		_world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(_world)
		_world_ptr = cast(rawptr)_world
	}
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {0, 0}, world = _world_ptr},
	}
	fd_backing: [4]FD_Entry
	buffer_backing: [1024]u8
	staging_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 512, 2}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	owner := make_handle(0, 1, 0, 1)

	fd_handle, sock_error := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{type_count = 2, slot_counts = {0, 1}, subsystems = {.Metadata}},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, owner, .Runnable)

	io_error := reactor_submit_io(
		reactor, shard, owner,
		IoOp_Recv{fd = fd_handle, buffer_size_max = 256},
	)
	testing.expect_value(t, io_error, IO_ERR_NONE)

	flush_error := reactor_flush_submissions(reactor, shard)
	testing.expect_value(t, flush_error, Backend_Error.None)
	testing.expect_value(t, reactor.io_in_flight_count, u32(1))

	// Simulate shutdown: bump io_sequence and make Runnable. The pending
	// completion will arrive stale on the next collect.
	soa_meta := shard.metadata[1]
	soa_meta[0].io_sequence += 1
	_slot_set_state(shard, 1, 0, .Runnable)
	second_io_error := reactor_submit_io(
		reactor, shard, owner,
		IoOp_Recv{fd = fd_handle, buffer_size_max = 256},
	)
	testing.expect_value(t, second_io_error, IO_ERR_SUBMISSION_FULL)
	testing.expect_value(t, reactor.pending_count, u16(0))

	when TINA_SIMULATION_MODE {
		backend_set_current_tick(&reactor.backend, 1)
	}
	reactor_collect_completions(reactor, shard, 0)

	testing.expect_value(t, reactor.io_in_flight_count, u32(0))
	testing.expect_value(t, soa_meta[0].io_operation_kind, IO_Operation_Kind.None)
	testing.expect_value(t, soa_meta[0].io_fd, FD_HANDLE_NONE)
	testing.expect_value(t, soa_meta[0].io_slot_index, IO_SLOT_INDEX_NONE)

	// Teardown must go directly to Unallocated — no Pending_IO_Reuse.
	_teardown_isolate(shard, 1, 0, .Normal)
	testing.expect_value(t, soa_meta[0]._state, Isolate_State.Unallocated)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))
}

// A read-only owner in a split full-duplex pair must not be able to close
// the FD. Close requires both-direction authority.
@(test)
test_split_owner_close_rejected :: proc(t: ^testing.T) {
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
	reactor_init(reactor, config, fd_backing[:], IO_Slot_Pool_Config{buffer_backing[:], 512, 2}, IO_Slot_Pool_Config{staging_backing[:], 1024, 1})
	defer {reactor_deinit(reactor); free(reactor)}

	reader_owner := make_handle(0, 1, 0, 1)
	writer_owner := make_handle(0, 2, 0, 1)

	fd_handle, sock_error := reactor_control_socket(reactor, reader_owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_error, Reactor_Socket_Error.None)

	// Split ownership: writer gets write direction only.
	split_error := fd_table_handoff(
		&reactor.fd_table, fd_handle, writer_owner, .Write_Only,
	)
	testing.expect_value(t, split_error, FD_Table_Error.None)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 3,
			slot_counts = {0, 1, 1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, reader_owner, .Runnable)
	test_shard_slot_activate(fixture, writer_owner, .Runnable)

	// Reader cannot close — lacks write direction.
	io_error_reader := reactor_submit_io(
		reactor, shard, reader_owner,
		IoOp_Close{fd = fd_handle},
	)
	testing.expect_value(t, io_error_reader, IO_ERR_AFFINITY_VIOLATION)

	// Writer cannot close — lacks read direction.
	io_error_writer := reactor_submit_io(
		reactor, shard, writer_owner,
		IoOp_Close{fd = fd_handle},
	)
	testing.expect_value(t, io_error_writer, IO_ERR_AFFINITY_VIOLATION)

	// FD entry must still be Open — no partial close transition.
	entry_index, lookup_error := fd_table_lookup_index(&reactor.fd_table, fd_handle)
	testing.expect_value(t, lookup_error, FD_Table_Error.None)
	testing.expect_value(t, reactor.fd_table.entries[entry_index].state, FD_Entry_State.Open)
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
