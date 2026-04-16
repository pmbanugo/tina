#+private
package tina

import "core:testing"

MAX_REACTOR_BATCH :: DEFAULT_BACKEND_QUEUE_SIZE

Reactor_Socket_Error :: enum u8 {
	None,
	Backend_Error,
	FD_Table_Full,
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
// It manages the FD table, the buffer pool, and accumulates I/O submissions
// for a single tick-wide flush.

Reactor :: struct {
	backend:             Platform_Backend,
	pending_submissions: [MAX_REACTOR_BATCH]Submission,

	// Core Data Structures
	fd_table:            FD_Table,
	buffer_pool:         Reactor_Buffer_Pool,

	// Hot Scalars
	pending_count:       u16,
	_padding:            [6]u8,
}

// Initialize the Reactor with memory carved from the Grand Arena.
reactor_init :: proc(
	reactor: ^Reactor,
	config: Backend_Config,
	fd_backing: []FD_Entry,
	buffer_backing: []u8,
	buffer_slot_size: u32,
	buffer_slot_count: u16,
) -> Backend_Error {
	reactor.pending_count = 0

	// Init buffer pool first — backend needs pool metadata for registered buffers.
	fd_table_init(&reactor.fd_table, fd_backing)
	reactor_buffer_pool_init(
		&reactor.buffer_pool,
		buffer_backing,
		buffer_slot_size,
		buffer_slot_count,
	)

	// Pass buffer pool metadata to backend for io_uring registered buffers.
	backend_config := config
	backend_config.buffer_base = raw_data(buffer_backing)
	backend_config.buffer_slot_size = buffer_slot_size
	backend_config.buffer_slot_count = buffer_slot_count
	backend_config.fd_slot_count = u16(len(fd_backing))

	err := backend_init(&reactor.backend, backend_config)
	if err != .None do return err

	return .None
}

reactor_deinit :: proc(reactor: ^Reactor) {
	backend_deinit(&reactor.backend)
	reactor.pending_count = 0
}

// ======================================
// Synchronous Control Wrappers (§6.6.3)
// ======================================

// Create a socket, register it in the FD table, and establish ownership.
reactor_control_socket :: proc(
	reactor: ^Reactor,
	owner: Handle,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	FD_Handle,
	Reactor_Socket_Error,
) {

	os_fd, backend_error := backend_control_socket(&reactor.backend, domain, socket_type, protocol)
	if backend_error != .None do return FD_HANDLE_NONE, .Backend_Error

	fd_handle, t_err := fd_table_alloc(&reactor.fd_table, os_fd, owner)
	if t_err != .None {
		backend_control_close(&reactor.backend, os_fd)
		return FD_HANDLE_NONE, .FD_Table_Full
	}

	backend_register_fixed_fd(&reactor.backend, fd_handle_index(fd_handle), os_fd)
	return fd_handle, .None
}

reactor_control_bind :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Handle,
	address: Socket_Address,
) -> Backend_Error {
	entry, err := _resolve_fd(reactor, fd, owner, .Any)
	if err != IO_ERR_NONE do return .Not_Found
	return backend_control_bind(&reactor.backend, entry.os_fd, address)
}

reactor_control_listen :: proc(reactor: ^Reactor, fd: FD_Handle, owner: Handle, backlog: u32) -> Backend_Error {
	entry, err := _resolve_fd(reactor, fd, owner, .Any)
	if err != IO_ERR_NONE do return .Not_Found
	return backend_control_listen(&reactor.backend, entry.os_fd, backlog)
}

reactor_control_setsockopt :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	entry, err := _resolve_fd(reactor, fd, owner, .Any)
	if err != IO_ERR_NONE do return .Not_Found
	return backend_control_setsockopt(&reactor.backend, entry.os_fd, level, option, value)
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
	os_fd, t_err := fd_table_resolve(&reactor.fd_table, fd)
	if t_err != .None do return nil, .Not_Found
	return backend_control_getsockopt(&reactor.backend, os_fd, level, option)
}

// Half-close a socket. Validates direction-scoped ownership (§6.6.3 §11).
reactor_control_shutdown :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Handle,
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

	entry, err := _resolve_fd(reactor, fd, owner, dir)
	if err != IO_ERR_NONE do return .Not_Found

	return backend_control_shutdown(&reactor.backend, entry.os_fd, how)
}

reactor_internal_close_fd :: proc "contextless" (reactor: ^Reactor, fd: FD_Handle) {
	os_fd, t_err := fd_table_resolve(&reactor.fd_table, fd)
	if t_err == .None {
		backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(fd))
		backend_control_close(&reactor.backend, os_fd)
		fd_table_free(&reactor.fd_table, fd)
	}
}

@(private = "package")
reactor_export_fd_handoff :: proc "contextless" (
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Handle,
) -> (
	OS_FD,
	Peer_Address,
	FD_Handoff_Result,
) {
	entry, err := fd_table_lookup(&reactor.fd_table, fd)
	if err != .None {
		return OS_FD_INVALID, {}, .invalid_fd_state
	}
	if entry.read_owner != owner || entry.write_owner != owner {
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
	owner: Handle,
	os_fd: OS_FD,
	peer_address: Peer_Address,
) -> (
	FD_Handle,
	FD_Handoff_Reject_Reason,
) {
	adopted_fd, dup_err := backend_control_dup(&reactor.backend, os_fd)
	if dup_err == .Unsupported {
		return FD_HANDLE_NONE, .Unsupported
	}
	if dup_err != .None {
		return FD_HANDLE_NONE, .Adopt_Failed
	}

	fd_handle, fd_err := fd_table_alloc(&reactor.fd_table, adopted_fd, owner)
	if fd_err != .None {
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

reactor_collect_completions :: proc(reactor: ^Reactor, shard: ^Shard, timeout_ns: i64) {
	completions: [MAX_REACTOR_BATCH]Raw_Completion

	count, err := backend_collect(&reactor.backend, completions[:], timeout_ns)
	if err != .None || count == 0 do return

	for i in 0 ..< count {
		completion := &completions[i]
		token := completion.token

		type_index := submission_token_type_index(token)
		slot_index := submission_token_slot_index(token)
		token_gen := submission_token_generation(token)
		token_seq := submission_token_io_sequence(token)
		buffer_index := submission_token_buffer_index(token)
		op_tag := submission_token_operation_tag(token)

		// Flat bounds check
		if int(type_index) >= len(shard.metadata) do continue
		soa_meta := shard.metadata[type_index]
		if int(slot_index) >= len(soa_meta) do continue

		// Flat Routing Firewall
		is_stale :=
			u8(soa_meta[slot_index].generation) != token_gen ||
			soa_meta[slot_index].io_sequence != token_seq

		// Fast-fail the stale path to keep the valid path unnested
		if is_stale {
			if buffer_index != BUFFER_INDEX_NONE {
				reactor_buffer_pool_free(&reactor.buffer_pool, buffer_index)
			}

			fd_handle := soa_meta[slot_index].io_fd
			if fd_handle != FD_HANDLE_NONE {
				entry, err := fd_table_lookup(&reactor.fd_table, fd_handle)
				if err == .None && fd_table_is_close_on_completion(entry) {
					reactor_internal_close_fd(reactor, fd_handle)
					soa_meta[slot_index].io_fd = FD_HANDLE_NONE
				}
			}

			// Reclaim leaked OS resources from accept completions.
			// The kernel allocated a client_fd that has no Isolate handler.
			if op_tag == u8(IO_TAG_ACCEPT_COMPLETE) {
				#partial switch e in completion.extra {
				case Completion_Extra_Accept:
					if completion.result >= 0 && e.client_fd != OS_FD_INVALID {
						backend_control_close(&reactor.backend, e.client_fd)
					}
				}
			}

			shard.counters.io_stale_completions += 1
			continue
		}

		// Valid Completion Delivery
		soa_meta[slot_index].io_completion_tag = Message_Tag(op_tag)
		soa_meta[slot_index].io_result = completion.result
		soa_meta[slot_index].io_buffer_index = buffer_index

		if op_tag == u8(IO_TAG_ACCEPT_COMPLETE) {
			#partial switch e in completion.extra {
			case Completion_Extra_Accept:
				soa_meta[slot_index].io_peer_address = socket_address_to_peer_address(
					e.client_address,
				)

				if completion.result >= 0 && e.client_fd != OS_FD_INVALID {
					owner := make_handle(
						shard.id,
						u16(type_index),
						u32(slot_index),
						soa_meta[slot_index].generation,
					)
					fd_handle, fd_err := fd_table_alloc(&reactor.fd_table, e.client_fd, owner)

					if fd_err == .None {
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
					} else {
						backend_control_close(&reactor.backend, e.client_fd)
						soa_meta[slot_index].io_result = i32(IO_ERR_RESOURCE_EXHAUSTED)
						soa_meta[slot_index].io_fd = FD_HANDLE_NONE
					}
				} else {
					soa_meta[slot_index].io_fd = FD_HANDLE_NONE
				}
			}
		} else if op_tag == u8(IO_TAG_RECVFROM_COMPLETE) {
			#partial switch e in completion.extra {
			case Completion_Extra_Recvfrom:
				soa_meta[slot_index].io_peer_address = socket_address_to_peer_address(e.peer_address)
			}
		}

		if soa_meta[slot_index].state == .Waiting_For_Io {
			soa_meta[slot_index].state = .Runnable
		}
	}
}

reactor_flush_submissions :: proc(reactor: ^Reactor, shard: ^Shard) {
	if reactor.pending_count == 0 do return

	err := backend_submit(&reactor.backend, reactor.pending_submissions[:reactor.pending_count])

	// Fast-return on success
	if err == .None {
		reactor.pending_count = 0
		return
	}

	// Error Path: Backend Queue Full
	shard.counters.io_submission_exhaustions += u64(reactor.pending_count)

	for i in 0 ..< reactor.pending_count {
		sub := &reactor.pending_submissions[i]
		type_index := submission_token_type_index(sub.token)
		slot_index := submission_token_slot_index(sub.token)
		buffer_index := submission_token_buffer_index(sub.token)

		if buffer_index != BUFFER_INDEX_NONE {
			reactor_buffer_pool_free(&reactor.buffer_pool, buffer_index)
		}

		soa_meta := shard.metadata[type_index]

		if u8(soa_meta[slot_index].generation) == submission_token_generation(sub.token) {
			soa_meta[slot_index].io_completion_tag = Message_Tag(
				submission_token_operation_tag(sub.token),
			)
			soa_meta[slot_index].io_result = i32(IO_ERR_SUBMISSION_FULL)
			soa_meta[slot_index].io_buffer_index = BUFFER_INDEX_NONE

			if soa_meta[slot_index].state == .Waiting_For_Io {
				soa_meta[slot_index].state = .Runnable
			}
		}
	}

	reactor.pending_count = 0
}

// ============================================================================
// I/O Submission Translation (§6.6.1 §4, §6.6.3 §6)
// ============================================================================

// Translates user IoOp to Platform Submission. Returns IO_Error on failure.
reactor_submit_io :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	owner: Handle,
	io_op: IoOp,
) -> IO_Error {
	if reactor.pending_count >= MAX_REACTOR_BATCH {
		return IO_ERR_SUBMISSION_FULL
	}

	type_index := extract_type_id(owner)
	slot_index := extract_slot(owner)
	soa_meta := shard.metadata[type_index]

	// One-in-flight I/O invariant: an Isolate must not submit new I/O while
	// already in WAITING_FOR_IO. The io_sequence mechanism assumes at most one
	// in-flight operation per Isolate — if two were in flight, bumping the
	// sequence would only invalidate one, leaving the other to corrupt state.
	when TINA_DEBUG_ASSERTS {
		assert(
			soa_meta[slot_index].state != .Waiting_For_Io,
			"One-in-flight I/O invariant violated: Isolate submitted while WAITING_FOR_IO",
		)
	}

	soa_meta[slot_index].io_sequence += 1
	seq := soa_meta[slot_index].io_sequence
	gen := soa_meta[slot_index].generation

	submission: Submission
	submission.fixed_file_index = FIXED_FILE_INDEX_NONE
	submission_op_tag: u8
	buffer_index: u16 = BUFFER_INDEX_NONE
	target_fd: FD_Handle = FD_HANDLE_NONE

	switch op in io_op {
	case IoOp_Read:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_READ_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Read)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)

		alloc_index, alloc_error := reactor_buffer_pool_alloc(&reactor.buffer_pool)
		if alloc_error != .None do return IO_ERR_RESOURCE_EXHAUSTED
		buffer_index = alloc_index

		submission.operation = Submission_Op_Read {
			fd     = entry.os_fd,
			buffer = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buffer_index),
			size   = op.buffer_size_max,
			offset = op.offset,
		}

	case IoOp_Write:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_WRITE_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)

		alloc_index, alloc_error := _alloc_and_copy_in(
			reactor,
			shard,
			type_index,
			slot_index,
			op.payload_offset,
			op.payload_size,
		)
		if alloc_error != IO_ERR_NONE do return alloc_error
		buffer_index = alloc_index

		submission.operation = Submission_Op_Write {
			fd     = entry.os_fd,
			buffer = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buffer_index),
			size   = op.payload_size,
			offset = op.offset,
		}

	case IoOp_Accept:
		target_fd = op.listen_fd
		submission_op_tag = u8(IO_TAG_ACCEPT_COMPLETE)
		entry, err := _resolve_fd(reactor, op.listen_fd, owner, .Read)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.listen_fd)
		submission.operation = Submission_Op_Accept {
			listen_fd = entry.os_fd,
		}

	case IoOp_Connect:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_CONNECT_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)
		submission.operation = Submission_Op_Connect {
			socket_fd = entry.os_fd,
			address   = op.address,
		}

	case IoOp_Send:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_SEND_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)

		alloc_index, alloc_error := _alloc_and_copy_in(
			reactor,
			shard,
			type_index,
			slot_index,
			op.payload_offset,
			op.payload_size,
		)
		if alloc_error != IO_ERR_NONE do return alloc_error
		buffer_index = alloc_index

		submission.operation = Submission_Op_Send {
			socket_fd = entry.os_fd,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buffer_index),
			size      = op.payload_size,
		}

	case IoOp_Recv:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_RECV_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Read)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)

		alloc_index, alloc_error := reactor_buffer_pool_alloc(&reactor.buffer_pool)
		if alloc_error != .None do return IO_ERR_RESOURCE_EXHAUSTED
		buffer_index = alloc_index

		submission.operation = Submission_Op_Recv {
			socket_fd = entry.os_fd,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buffer_index),
			size      = op.buffer_size_max,
		}

	case IoOp_Sendto:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_SENDTO_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)

		alloc_index, alloc_error := _alloc_and_copy_in(
			reactor,
			shard,
			type_index,
			slot_index,
			op.payload_offset,
			op.payload_size,
		)
		if alloc_error != IO_ERR_NONE do return alloc_error
		buffer_index = alloc_index

		submission.operation = Submission_Op_Sendto {
			socket_fd = entry.os_fd,
			address   = op.address,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buffer_index),
			size      = op.payload_size,
		}

	case IoOp_Recvfrom:
		target_fd = op.fd
		submission_op_tag = u8(IO_TAG_RECVFROM_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Read)
		if err != IO_ERR_NONE do return err
		submission.fixed_file_index = fd_handle_index(op.fd)

		alloc_index, alloc_error := reactor_buffer_pool_alloc(&reactor.buffer_pool)
		if alloc_error != .None do return IO_ERR_RESOURCE_EXHAUSTED
		buffer_index = alloc_index

		submission.operation = Submission_Op_Recvfrom {
			socket_fd = entry.os_fd,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buffer_index),
			size      = op.buffer_size_max,
		}

	case IoOp_Close:
		target_fd = FD_HANDLE_NONE
		submission_op_tag = u8(IO_TAG_CLOSE_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Any)
		if err != IO_ERR_NONE do return err

		submission.operation = Submission_Op_Close {
			fd = entry.os_fd,
		}
		backend_unregister_fixed_fd(&reactor.backend, fd_handle_index(op.fd))
		fd_table_free(&reactor.fd_table, op.fd)
	}

	if target_fd != FD_HANDLE_NONE &&
	   submission_op_tag != u8(IO_TAG_ACCEPT_COMPLETE) &&
	   submission_op_tag != u8(IO_TAG_CLOSE_COMPLETE) {
		_ = fd_table_clear_fresh_accept(&reactor.fd_table, target_fd)
	}

	submission.token = submission_token_pack(
		u8(type_index),
		slot_index,
		u8(gen),
		seq,
		buffer_index,
		submission_op_tag,
	)
	reactor.pending_submissions[reactor.pending_count] = submission
	reactor.pending_count += 1
	soa_meta[slot_index].io_fd = target_fd

	return IO_ERR_NONE
}

// ================
// Internal Helpers
// ================

@(private = "package")
_io_op_to_completion_tag :: #force_inline proc(op: IoOp) -> Message_Tag {
	switch _ in op {
	case IoOp_Read:
		return IO_TAG_READ_COMPLETE
	case IoOp_Write:
		return IO_TAG_WRITE_COMPLETE
	case IoOp_Accept:
		return IO_TAG_ACCEPT_COMPLETE
	case IoOp_Connect:
		return IO_TAG_CONNECT_COMPLETE
	case IoOp_Send:
		return IO_TAG_SEND_COMPLETE
	case IoOp_Recv:
		return IO_TAG_RECV_COMPLETE
	case IoOp_Sendto:
		return IO_TAG_SENDTO_COMPLETE
	case IoOp_Recvfrom:
		return IO_TAG_RECVFROM_COMPLETE
	case IoOp_Close:
		return IO_TAG_CLOSE_COMPLETE
	}
	return IO_TAG_NONE
}

@(private = "file")
_resolve_fd :: #force_inline proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	owner: Handle,
	dir: Direction_Affinity,
) -> (
	^FD_Entry,
	IO_Error,
) {
	entry, err := fd_table_lookup(&reactor.fd_table, fd)
	if err != .None do return nil, IO_ERR_STALE_FD

	switch dir {
	case .Read:
		if fd_table_validate_read_affinity(entry, owner) != .None do return nil, IO_ERR_AFFINITY_VIOLATION
	case .Write:
		if fd_table_validate_write_affinity(entry, owner) != .None do return nil, IO_ERR_AFFINITY_VIOLATION
	case .Any:
		if fd_table_validate_read_affinity(entry, owner) != .None &&
		   fd_table_validate_write_affinity(entry, owner) != .None {
			return nil, IO_ERR_AFFINITY_VIOLATION
		}
	}
	return entry, IO_ERR_NONE
}

@(private = "file")
_alloc_and_copy_in :: #force_inline proc(
	reactor: ^Reactor,
	shard: ^Shard,
	type_index: u16,
	slot_index: u32,
	offset: u16,
	size: u32,
) -> (
	u16,
	IO_Error,
) {
	stride := shard.type_descriptors[type_index].stride
	if int(offset) + int(size) > stride do return BUFFER_INDEX_NONE, IO_ERR_BOUNDS_VIOLATION

	alloc_index, alloc_error := reactor_buffer_pool_alloc(&reactor.buffer_pool)
	if alloc_error != .None do return BUFFER_INDEX_NONE, IO_ERR_RESOURCE_EXHAUSTED

	isolate_pointer := _get_isolate_ptr(shard, type_index, slot_index)
	source_pointer := rawptr(uintptr(isolate_pointer) + uintptr(offset))
	reactor_buffer_pool_copy_in(&reactor.buffer_pool, alloc_index, source_pointer, size)

	return alloc_index, IO_ERR_NONE
}

// =====
// Tests
// =====

@(test)
test_reactor_init_deinit :: proc(t: ^testing.T) {
	config := Backend_Config {
		queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
		sim_config = Simulation_IO_Config{delay_range_ticks = {0, 0}},
	}

	fd_backing: [16]FD_Entry
	buffer_backing: [1024 * 2]u8 // 2 slots of 1KB

	reactor := new(Reactor)
	defer free(reactor)
	err := reactor_init(reactor, config, fd_backing[:], buffer_backing[:], 1024, 2)
	testing.expect_value(t, err, Backend_Error.None)
	testing.expect_value(t, reactor.pending_count, 0)
	testing.expect_value(t, reactor.fd_table.slot_count, 16)
	testing.expect_value(t, reactor.buffer_pool.slot_count, 2)

	reactor_deinit(reactor)
}

@(test)
test_reactor_control_socket_and_shutdown :: proc(t: ^testing.T) {
	config := Backend_Config {
		sim_config = Simulation_IO_Config{},
	}
	fd_backing: [4]FD_Entry
	buffer_backing: [1024]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], buffer_backing[:], 1024, 1)
	defer { reactor_deinit(reactor); free(reactor) }

	owner_handle := make_handle(0, 1, 0, 1)

	// 1. Create a socket
	fd_handle, sock_err := reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_err, Reactor_Socket_Error.None)
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

	_, exhaust_err := reactor_control_socket(reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, exhaust_err, Reactor_Socket_Error.FD_Table_Full)
}

@(test)
test_fixed_file_sentinel_consistency :: proc(t: ^testing.T) {
	testing.expect_value(t, FIXED_FILE_INDEX_NONE, u16(FD_TABLE_NONE_INDEX))
}

@(test)
test_fixed_file_index_set_on_recv :: proc(t: ^testing.T) {
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], buffer_backing[:], 1024, 4)
	defer { reactor_deinit(reactor); free(reactor) }

	owner := make_handle(0, 1, 0, 1)

	// Create a socket owned by this handle
	fd_handle, sock_err := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_err, Reactor_Socket_Error.None)
	testing.expect(t, fd_handle != FD_HANDLE_NONE, "Valid FD handle expected")

	// Build a minimal Shard stub with metadata for type_id=1
	shard := new(Shard)
	defer free(shard)
	shard.metadata = make([]#soa[]Isolate_Metadata, 2)
	defer delete(shard.metadata)
	shard.metadata[1] = make(#soa[]Isolate_Metadata, 1)
	defer delete(shard.metadata[1])
	shard.metadata[1][0].generation = 1
	shard.metadata[1][0].state = .Runnable

	// Submit an IoOp_Recv
	io_err := reactor_submit_io(
		reactor,
		shard,
		owner,
		IoOp_Recv{fd = fd_handle, buffer_size_max = 512},
	)
	testing.expect_value(t, io_err, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 1)
	testing.expect_value(
		t,
		reactor.pending_submissions[0].fixed_file_index,
		fd_handle_index(fd_handle),
	)
}

@(test)
test_fixed_file_index_excluded_for_close :: proc(t: ^testing.T) {
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], buffer_backing[:], 1024, 4)
	defer { reactor_deinit(reactor); free(reactor) }

	owner := make_handle(0, 1, 0, 1)

	fd_handle, sock_err := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_err, Reactor_Socket_Error.None)

	shard := new(Shard)
	defer free(shard)
	shard.metadata = make([]#soa[]Isolate_Metadata, 2)
	defer delete(shard.metadata)
	shard.metadata[1] = make(#soa[]Isolate_Metadata, 1)
	defer delete(shard.metadata[1])
	shard.metadata[1][0].generation = 1
	shard.metadata[1][0].state = .Runnable

	// Submit a close — fixed_file_index must be NONE (safety invariant)
	io_err := reactor_submit_io(reactor, shard, owner, IoOp_Close{fd = fd_handle})
	testing.expect_value(t, io_err, IO_ERR_NONE)
	testing.expect_value(t, reactor.pending_count, 1)
	testing.expect_value(t, reactor.pending_submissions[0].fixed_file_index, FIXED_FILE_INDEX_NONE)
}

@(test)
test_fixed_file_close_then_reuse_ordering :: proc(t: ^testing.T) {
	config := Backend_Config {
		sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}},
	}
	fd_backing: [8]FD_Entry
	buffer_backing: [4096]u8

	reactor := new(Reactor)
	reactor_init(reactor, config, fd_backing[:], buffer_backing[:], 1024, 4)
	defer { reactor_deinit(reactor); free(reactor) }

	owner := make_handle(0, 1, 0, 1)

	// Create a socket — gets slot N via LIFO
	fd_handle_a, _ := reactor_control_socket(reactor, owner, .AF_INET, .STREAM, .TCP)
	slot_a := fd_handle_index(fd_handle_a)

	shard := new(Shard)
	defer free(shard)
	shard.metadata = make([]#soa[]Isolate_Metadata, 2)
	defer delete(shard.metadata)
	shard.metadata[1] = make(#soa[]Isolate_Metadata, 1)
	defer delete(shard.metadata[1])
	shard.metadata[1][0].generation = 1
	shard.metadata[1][0].state = .Runnable

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

	// 3. Submit recv on the new socket — should use the reused slot index
	shard.metadata[1][0].io_sequence += 1
	shard.metadata[1][0].generation += 1 // bump to match new handle
	owner_b := make_handle(0, 1, 0, u32(shard.metadata[1][0].generation))
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
			if soa_meta[slot_index].state == .Waiting_For_Io {
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
    	config := Backend_Config{queue_size = 32}
    	//when TINA_SIMULATION_MODE {
    	//	config.sim_config = Simulation_IO_Config{delay_range_ticks = {100, 200}, seed = t.seed}
    	//}

    	fd_backing: [8]FD_Entry
    	buffer_backing: [4096]u8

    	reactor := new(Reactor)
    	reactor_init(reactor, config, fd_backing[:], buffer_backing[:], 1024, 4)
    	defer { reactor_deinit(reactor); free(reactor) }

    	// 2. Setup Mock Shard Metadata
    	shard := new(Shard)
    	defer free(shard)
    	shard.metadata = make([]#soa[]Isolate_Metadata, 1)
    	defer delete(shard.metadata)
    	shard.metadata[0] = make(#soa[]Isolate_Metadata, 1)
    	defer delete(shard.metadata[0])

    	meta := &shard.metadata[0][0]
    	meta.generation = 1
    	meta.io_sequence = 1
    	meta.state = .Runnable

    	owner := make_handle(0, 0, 0, 1)

    	// 3. Anchor the I/O: Create a UDP socket. It will block forever on Recv.
    	fd, sock_err := reactor_control_socket(reactor, owner, .AF_INET, .DGRAM, .UDP)
    	testing.expect_value(t, sock_err, Reactor_Socket_Error.None)

    	bind_addr := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 0}
    	reactor_control_bind(reactor, fd, owner, bind_addr)

    	// 4. Submit Recv
    	io_err := reactor_submit_io(reactor, shard, owner, IoOp_Recv{fd = fd, buffer_size_max = 512})
    	testing.expect_value(t, io_err, IO_ERR_NONE)

    	// Buffer should be allocated
    	testing.expect_value(t, reactor.buffer_pool.free_count, 3)

    	// Push to the OS kernel / Simulator
    	reactor_flush_submissions(reactor, shard)

    	// 5. Simulate the Timer Wake (The ADR Structural Guarantee)
    	meta.io_sequence += 1
    	meta.state = .Runnable

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
    		if reactor.buffer_pool.free_count == 4 {
    			recovered = true
    			break
    		}
    	}

    	// 8. The Critical Assertions
    	testing.expect(t, recovered, "Reactor buffer leaked! The OS completion was lost or never generated.")
    	testing.expect_value(t, reactor.buffer_pool.free_count, 4)
    	testing.expect_value(t, shard.counters.io_stale_completions, 1)
    }
}
