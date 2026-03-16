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

// ============================================================================
// The Reactor (Layer 2) — Shard-Owned I/O Manager
// ============================================================================
//
// Bridges the Platform_Backend with the Shard's Isolate handles and memory.
// It manages the FD table, the buffer pool, and accumulates I/O submissions
// for a single tick-wide flush (smart batching).

Reactor :: struct {
	// Big/Opaque Fields
	backend:             Platform_Backend,
	pending_submissions: [MAX_REACTOR_BATCH]Submission,

	// Core Data Structures
	fd_table:            FD_Table,
	buffer_pool:         Reactor_Buffer_Pool,

	// Hot Scalars
	pending_count:       u16,
	_padding:            [6]u8, // Explicit padding to maintain 8-byte alignment
}

// Initialize the Reactor with memory pre-carved from the Grand Arena.
reactor_init :: proc(
	reactor: ^Reactor,
	config: Backend_Config,
	fd_backing: []FD_Entry,
	buffer_backing: []u8,
	buffer_slot_size: u32,
	buffer_slot_count: u16,
) -> Backend_Error {
	reactor.pending_count = 0

	err := backend_init(&reactor.backend, config)
	if err != .None do return err

	fd_table_init(&reactor.fd_table, fd_backing)
	reactor_buffer_pool_init(
		&reactor.buffer_pool,
		buffer_backing,
		buffer_slot_size,
		buffer_slot_count,
	)

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

	os_fd, b_err := backend_control_socket(&reactor.backend, domain, socket_type, protocol)
	if b_err != .None do return FD_HANDLE_NONE, .Backend_Error

	fd_handle, t_err := fd_table_alloc(&reactor.fd_table, os_fd, owner)
	if t_err != .None {
		backend_control_close(&reactor.backend, os_fd)
		return FD_HANDLE_NONE, .FD_Table_Full
	}

	return fd_handle, .None
}

reactor_control_bind :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	address: Socket_Address,
) -> Backend_Error {
	os_fd, t_err := fd_table_resolve(&reactor.fd_table, fd)
	if t_err != .None do return .Not_Found
	return backend_control_bind(&reactor.backend, os_fd, address)
}

reactor_control_listen :: proc(reactor: ^Reactor, fd: FD_Handle, backlog: u32) -> Backend_Error {
	os_fd, t_err := fd_table_resolve(&reactor.fd_table, fd)
	if t_err != .None do return .Not_Found
	return backend_control_listen(&reactor.backend, os_fd, backlog)
}

reactor_control_setsockopt :: proc(
	reactor: ^Reactor,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	os_fd, t_err := fd_table_resolve(&reactor.fd_table, fd)
	if t_err != .None do return .Not_Found
	return backend_control_setsockopt(&reactor.backend, os_fd, level, option, value)
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

reactor_internal_close_fd :: proc(reactor: ^Reactor, fd: FD_Handle) {
	os_fd, t_err := fd_table_resolve(&reactor.fd_table, fd)
	if t_err == .None {
		backend_control_close(&reactor.backend, os_fd)
		fd_table_free(&reactor.fd_table, fd)
	}
}

// ====================
// Cancellation API
// ====================

reactor_cancel_active_io :: proc(
	reactor: ^Reactor,
	shard: ^Shard,
	type_id: u16,
	slot_idx: u32,
) -> Backend_Error {
	soa_meta := shard.metadata[type_id]

	if soa_meta[slot_idx].io_completion_tag == IO_TAG_NONE {
		return .Not_Found
	}

	token := submission_token_pack(
		u8(type_id),
		slot_idx,
		u8(soa_meta[slot_idx].generation),
		soa_meta[slot_idx].io_sequence,
		soa_meta[slot_idx].io_buffer_index,
		u8(soa_meta[slot_idx].io_completion_tag),
	)

	return backend_cancel(&reactor.backend, token)
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

		type_idx := submission_token_type_index(token)
		slot_idx := submission_token_slot_index(token)
		token_gen := submission_token_generation(token)
		token_seq := submission_token_io_sequence(token)
		buf_idx := submission_token_buffer_index(token)
		op_tag := submission_token_operation_tag(token)

		// Flat bounds check
		if int(type_idx) >= len(shard.metadata) do continue
		soa_meta := shard.metadata[type_idx]
		if int(slot_idx) >= len(soa_meta) do continue

		// Flat Routing Firewall
		is_stale :=
			u8(soa_meta[slot_idx].generation) != token_gen ||
			soa_meta[slot_idx].io_sequence != token_seq

		// Fast-fail the stale path to keep the valid path unnested
		if is_stale {
			if buf_idx != BUFFER_INDEX_NONE {
				reactor_buffer_pool_free(&reactor.buffer_pool, buf_idx)
			}

			fd_handle := soa_meta[slot_idx].io_fd
			if fd_handle != FD_HANDLE_NONE {
				entry, err := fd_table_lookup(&reactor.fd_table, fd_handle)
				if err == .None && fd_table_is_close_on_completion(entry) {
					reactor_internal_close_fd(reactor, fd_handle)
					soa_meta[slot_idx].io_fd = FD_HANDLE_NONE
				}
			}

			shard.counters.io_stale_completions += 1
			continue
		}

		// Valid Completion Delivery
		soa_meta[slot_idx].io_completion_tag = IO_Completion_Tag(op_tag)
		soa_meta[slot_idx].io_result = completion.result
		soa_meta[slot_idx].io_buffer_index = buf_idx

		if op_tag == u8(IO_TAG_ACCEPT_COMPLETE) {
			#partial switch e in completion.extra {
			case Completion_Extra_Accept:
				soa_meta[slot_idx].io_peer_address = socket_address_to_peer_address(
					e.client_address,
				)

				if completion.result >= 0 && e.client_fd != OS_FD_INVALID {
					owner := make_handle(
						shard.id,
						u16(type_idx),
						u32(slot_idx),
						soa_meta[slot_idx].generation,
					)
					fd_handle, fd_err := fd_table_alloc(&reactor.fd_table, e.client_fd, owner)

					if fd_err == .None {
						soa_meta[slot_idx].io_fd = fd_handle
					} else {
						backend_control_close(&reactor.backend, e.client_fd)
						soa_meta[slot_idx].io_result = -i32(IO_ERR_RESOURCE_EXHAUSTED)
						soa_meta[slot_idx].io_fd = FD_HANDLE_NONE
					}
				} else {
					soa_meta[slot_idx].io_fd = FD_HANDLE_NONE
				}
			}
		} else if op_tag == u8(IO_TAG_RECVFROM_COMPLETE) {
			#partial switch e in completion.extra {
			case Completion_Extra_Recvfrom:
				soa_meta[slot_idx].io_peer_address = socket_address_to_peer_address(e.peer_address)
			}
		}

		if soa_meta[slot_idx].state == .Waiting_For_Io {
			soa_meta[slot_idx].state = .Runnable
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
		type_idx := submission_token_type_index(sub.token)
		slot_idx := submission_token_slot_index(sub.token)
		buf_idx := submission_token_buffer_index(sub.token)

		if buf_idx != BUFFER_INDEX_NONE {
			reactor_buffer_pool_free(&reactor.buffer_pool, buf_idx)
		}

		soa_meta := shard.metadata[type_idx]

		if u8(soa_meta[slot_idx].generation) == submission_token_generation(sub.token) {
			soa_meta[slot_idx].io_completion_tag = IO_Completion_Tag(
				submission_token_operation_tag(sub.token),
			)
			soa_meta[slot_idx].io_result = -i32(IO_ERR_SUBMISSION_FULL)
			soa_meta[slot_idx].io_buffer_index = BUFFER_INDEX_NONE

			if soa_meta[slot_idx].state == .Waiting_For_Io {
				soa_meta[slot_idx].state = .Runnable
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

	type_idx := extract_type_id(owner)
	slot_idx := extract_slot(owner)
	soa_meta := shard.metadata[type_idx]

	soa_meta[slot_idx].io_sequence += 1
	seq := soa_meta[slot_idx].io_sequence
	gen := soa_meta[slot_idx].generation

	sub: Submission
	sub_op_tag: u8
	buf_idx: u16 = BUFFER_INDEX_NONE
	target_fd: FD_Handle = FD_HANDLE_NONE

	switch op in io_op {
	case IoOp_Read:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_READ_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Read)
		if err != IO_ERR_NONE do return err

		b_idx, b_err := reactor_buffer_pool_alloc(&reactor.buffer_pool)
		if b_err != .None do return IO_ERR_RESOURCE_EXHAUSTED
		buf_idx = b_idx

		sub.operation = Submission_Op_Read {
			fd     = entry.os_fd,
			buffer = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buf_idx),
			size   = op.buffer_size_max,
			offset = op.offset,
		}

	case IoOp_Write:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_WRITE_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err

		b_idx, b_err := _alloc_and_copy_in(
			reactor,
			shard,
			type_idx,
			slot_idx,
			op.payload_offset,
			op.payload_size,
		)
		if b_err != IO_ERR_NONE do return b_err
		buf_idx = b_idx

		sub.operation = Submission_Op_Write {
			fd     = entry.os_fd,
			buffer = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buf_idx),
			size   = op.payload_size,
			offset = op.offset,
		}

	case IoOp_Accept:
		target_fd = op.listen_fd
		sub_op_tag = u8(IO_TAG_ACCEPT_COMPLETE)
		entry, err := _resolve_fd(reactor, op.listen_fd, owner, .Read)
		if err != IO_ERR_NONE do return err
		sub.operation = Submission_Op_Accept {
			listen_fd = entry.os_fd,
		}

	case IoOp_Connect:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_CONNECT_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err
		sub.operation = Submission_Op_Connect {
			socket_fd = entry.os_fd,
			address   = op.address,
		}

	case IoOp_Send:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_SEND_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err

		b_idx, b_err := _alloc_and_copy_in(
			reactor,
			shard,
			type_idx,
			slot_idx,
			op.payload_offset,
			op.payload_size,
		)
		if b_err != IO_ERR_NONE do return b_err
		buf_idx = b_idx

		sub.operation = Submission_Op_Send {
			socket_fd = entry.os_fd,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buf_idx),
			size      = op.payload_size,
		}

	case IoOp_Recv:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_RECV_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Read)
		if err != IO_ERR_NONE do return err

		b_idx, b_err := reactor_buffer_pool_alloc(&reactor.buffer_pool)
		if b_err != .None do return IO_ERR_RESOURCE_EXHAUSTED
		buf_idx = b_idx

		sub.operation = Submission_Op_Recv {
			socket_fd = entry.os_fd,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buf_idx),
			size      = op.buffer_size_max,
		}

	case IoOp_Sendto:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_SENDTO_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Write)
		if err != IO_ERR_NONE do return err

		b_idx, b_err := _alloc_and_copy_in(
			reactor,
			shard,
			type_idx,
			slot_idx,
			op.payload_offset,
			op.payload_size,
		)
		if b_err != IO_ERR_NONE do return b_err
		buf_idx = b_idx

		sub.operation = Submission_Op_Sendto {
			socket_fd = entry.os_fd,
			address   = op.address,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buf_idx),
			size      = op.payload_size,
		}

	case IoOp_Recvfrom:
		target_fd = op.fd
		sub_op_tag = u8(IO_TAG_RECVFROM_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Read)
		if err != IO_ERR_NONE do return err

		b_idx, b_err := reactor_buffer_pool_alloc(&reactor.buffer_pool)
		if b_err != .None do return IO_ERR_RESOURCE_EXHAUSTED
		buf_idx = b_idx

		sub.operation = Submission_Op_Recvfrom {
			socket_fd = entry.os_fd,
			buffer    = reactor_buffer_pool_slot_ptr(&reactor.buffer_pool, buf_idx),
			size      = op.buffer_size_max,
		}

	case IoOp_Close:
		target_fd = FD_HANDLE_NONE
		sub_op_tag = u8(IO_TAG_CLOSE_COMPLETE)
		entry, err := _resolve_fd(reactor, op.fd, owner, .Any)
		if err != IO_ERR_NONE do return err

		sub.operation = Submission_Op_Close {
			fd = entry.os_fd,
		}
		fd_table_free(&reactor.fd_table, op.fd)
	}

	sub.token = submission_token_pack(u8(type_idx), slot_idx, u8(gen), seq, buf_idx, sub_op_tag)
	reactor.pending_submissions[reactor.pending_count] = sub
	reactor.pending_count += 1
	soa_meta[slot_idx].io_fd = target_fd

	return IO_ERR_NONE
}

// ================
// Internal Helpers
// ================

@(private = "package")
_io_op_to_completion_tag :: #force_inline proc(op: IoOp) -> IO_Completion_Tag {
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
	type_idx: u16,
	slot_idx: u32,
	offset: u16,
	size: u32,
) -> (
	u16,
	IO_Error,
) {
	stride := shard.type_descriptors[type_idx].stride
	if int(offset) + int(size) > stride do return BUFFER_INDEX_NONE, IO_ERR_BOUNDS_VIOLATION

	b_idx, b_err := reactor_buffer_pool_alloc(&reactor.buffer_pool)
	if b_err != .None do return BUFFER_INDEX_NONE, IO_ERR_RESOURCE_EXHAUSTED

	isolate_ptr := _get_isolate_ptr(shard, type_idx, slot_idx)
	source_pointer := rawptr(uintptr(isolate_ptr) + uintptr(offset))
	reactor_buffer_pool_copy_in(&reactor.buffer_pool, b_idx, source_pointer, size)

	return b_idx, IO_ERR_NONE
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

	reactor: Reactor
	err := reactor_init(&reactor, config, fd_backing[:], buffer_backing[:], 1024, 2)
	testing.expect_value(t, err, Backend_Error.None)
	testing.expect_value(t, reactor.pending_count, 0)
	testing.expect_value(t, reactor.fd_table.slot_count, 16)
	testing.expect_value(t, reactor.buffer_pool.slot_count, 2)

	reactor_deinit(&reactor)
}

@(test)
test_reactor_control_socket_and_shutdown :: proc(t: ^testing.T) {
	config := Backend_Config {
		sim_config = Simulation_IO_Config{},
	}
	fd_backing: [4]FD_Entry
	buffer_backing: [1024]u8

	reactor: Reactor
	reactor_init(&reactor, config, fd_backing[:], buffer_backing[:], 1024, 1)
	defer reactor_deinit(&reactor)

	owner_handle := make_handle(0, 1, 0, 1)

	// 1. Create a socket
	fd_handle, sock_err := reactor_control_socket(&reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_err, Reactor_Socket_Error.None)
	testing.expect(t, fd_handle != FD_HANDLE_NONE, "Valid FD handle expected")

	// 2. Validate affinity checking on shutdown
	bad_owner := make_handle(0, 2, 0, 1) // Different type/Isolate

	shut_err_bad := reactor_control_shutdown(&reactor, fd_handle, bad_owner, .SHUT_BOTH)
	testing.expect_value(t, shut_err_bad, Backend_Error.Not_Found) // Fails affinity check

	shut_err_ok := reactor_control_shutdown(&reactor, fd_handle, owner_handle, .SHUT_WRITER)

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
	_, _ = reactor_control_socket(&reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	_, _ = reactor_control_socket(&reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	_, _ = reactor_control_socket(&reactor, owner_handle, .AF_INET, .STREAM, .TCP)

	_, exhaust_err := reactor_control_socket(&reactor, owner_handle, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, exhaust_err, Reactor_Socket_Error.FD_Table_Full)
}
