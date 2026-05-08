package http_server

import tina "../../.."
import "core:mem"
import "core:testing"

@(private = "package")
_runtime_active_slot_add :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		return
	}

	slot_index := u16(tina.extract_slot(ctx.self_handle))
	if runtime.active_slot_positions[slot_index] != u16(IDLE_ARRAY_INDEX_NONE) {
		return
	}

	active_index := u16(runtime.active_count)
	runtime.active_slot_indices[active_index] = slot_index
	runtime.active_slot_positions[slot_index] = active_index
	runtime.active_count = Active_Array_Count(active_index + 1)
}

@(private = "package")
_runtime_active_slot_remove :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) {
	state := &connection.connection_state
	if state.shard_runtime == nil {
		return
	}
	_runtime_active_slot_remove_by_slot(state.shard_runtime, u16(tina.extract_slot(ctx.self_handle)))
}

@(private = "file")
_runtime_active_slot_remove_by_slot :: proc(runtime: ^HTTP_Shard_Runtime, slot_index: u16) {
	if runtime == nil {
		return
	}

	active_index := runtime.active_slot_positions[slot_index]
	if active_index == u16(IDLE_ARRAY_INDEX_NONE) {
		return
	}

	last_index := u16(runtime.active_count) - 1
	last_slot := runtime.active_slot_indices[last_index]
	if active_index != last_index {
		runtime.active_slot_indices[active_index] = last_slot
		runtime.active_slot_positions[last_slot] = active_index
	}

	runtime.active_slot_positions[slot_index] = u16(IDLE_ARRAY_INDEX_NONE)
	runtime.active_count = Active_Array_Count(last_index)
}

@(private = "file")
_connection_ptr_from_slot :: proc(
	shard: ^tina.Shard,
	type_id: u16,
	slot_index: u32,
) -> ^HTTP_Connection {
	stride := shard.type_descriptors[type_id].stride
	base := &shard.isolate_memory[type_id][int(slot_index) * stride]
	return cast(^HTTP_Connection)base
}

@(private = "file")
_runtime_from_tick_owner :: proc(shard: ^tina.Shard, type_id: u16) -> ^HTTP_Shard_Runtime {
	if int(type_id) >= len(shard.metadata) || len(shard.metadata[type_id]) == 0 {
		return nil
	}
	if shard.metadata[type_id].state[0] == .Unallocated {
		return nil
	}

	base := &shard.isolate_memory[type_id][0]
	stride := shard.type_descriptors[type_id].stride
	if stride == size_of(HTTP_Listener) {
		return (cast(^HTTP_Listener)base).shard_runtime
	}
	if stride == size_of(HTTP_Dispatcher) {
		return (cast(^HTTP_Dispatcher)base).shard_runtime
	}
	return nil
}

@(private = "file")
_connection_timeout_tag :: proc(
	state: ^HTTP_Connection_State,
	now_ns: Monotonic_Time_NS,
) -> (tina.Message_Tag, tina.Correlation_Id, bool) {
	if state.deadline_ns_drain != 0 && u64(now_ns) >= u64(state.deadline_ns_drain) {
		return TAG_DRAIN_TIMEOUT, tina.Correlation_Id(state.request_token), true
	}

	#partial switch state.state {
	case .Recv_Headers:
		if state.deadline_ns_header != 0 && u64(now_ns) >= u64(state.deadline_ns_header) {
			return TAG_HEADER_TIMEOUT, tina.Correlation_Id(state.request_token), true
		}
	case .Recv_Body_Streamed, .Recv_Body_Buffered:
		if state.deadline_ns_body != 0 && u64(now_ns) >= u64(state.deadline_ns_body) {
			return TAG_BODY_TIMEOUT, tina.Correlation_Id(state.request_token), true
		}
	case .Sending:
		if state.deadline_ns_send != 0 && u64(now_ns) >= u64(state.deadline_ns_send) {
			return TAG_SEND_TIMEOUT, tina.Correlation_Id(state.request_token), true
		}
	case .Keep_Alive_Idle:
		if state.deadline_ns_idle != 0 && u64(now_ns) >= u64(state.deadline_ns_idle) {
			return TAG_IDLE_TIMEOUT, tina.Correlation_Id(state.request_token), true
		}
	case:
	}

	return tina.Message_Tag(0), tina.CORRELATION_ID_NONE, false
}

@(private = "file")
_runtime_enqueue_timeout :: proc(
	runtime: ^HTTP_Shard_Runtime,
	shard: ^tina.Shard,
	slot_index: u16,
	tag: tina.Message_Tag,
	correlation: tina.Correlation_Id,
) -> bool {
	meta := shard.metadata[runtime.connection_type_id]
	state := meta.state[slot_index]
	if state == .Runnable || state == .Unallocated || state == .Crashed {
		return false
	}

	pool_index, pool_error := tina.pool_alloc_system(&shard.message_pool)
	if pool_error != .None {
		shard.counters.pool_exhaustion_drops += 1
		return false
	}

	handle := tina.make_handle(
		shard.id,
		u16(runtime.connection_type_id),
		u32(slot_index),
		meta.generation[slot_index],
	)
	envelope := tina.pool_get_ptr_unchecked(&shard.message_pool, pool_index)
	envelope.source = tina.HANDLE_NONE
	envelope.destination = handle
	envelope.correlation = correlation
	envelope.tag = tag
	envelope.flags = {}
	envelope.payload_size = 0
	envelope.next_in_mailbox = tina.POOL_NONE_INDEX

	if meta.inbox_head[slot_index] == tina.POOL_NONE_INDEX {
		meta.inbox_head[slot_index] = pool_index
	} else {
		tail := tina.pool_get_ptr_unchecked(
			&shard.message_pool,
			meta.inbox_tail[slot_index],
		)
		tail.next_in_mailbox = pool_index
	}

	meta.inbox_tail[slot_index] = pool_index
	meta.inbox_count[slot_index] += 1
	if state == .Waiting_For_Io {
		meta.io_sequence[slot_index] += 1
	}
	meta.state[slot_index] = .Runnable
	return true
}

@(private = "file")
_runtime_scan_deadlines :: proc(runtime: ^HTTP_Shard_Runtime, shard: ^tina.Shard, now_ns: Monotonic_Time_NS) {
	active_index := 0
	for active_index < int(runtime.active_count) {
		slot_index := runtime.active_slot_indices[active_index]
		meta := shard.metadata[runtime.connection_type_id]
		if meta.state[slot_index] == .Unallocated {
			_runtime_active_slot_remove_by_slot(runtime, slot_index)
			continue
		}

		connection := _connection_ptr_from_slot(shard, u16(runtime.connection_type_id), u32(slot_index))
		state := &connection.connection_state
		if state.shard_runtime != runtime {
			_runtime_active_slot_remove_by_slot(runtime, slot_index)
			continue
		}

		timeout_tag, correlation, timed_out := _connection_timeout_tag(state, now_ns)
		if timed_out {
			_ = _runtime_enqueue_timeout(runtime, shard, slot_index, timeout_tag, correlation)
		}

		active_index += 1
	}
}

@(private = "package")
_http_runtime_tick :: proc(shard: ^tina.Shard, type_id: u16) {
	runtime := _runtime_from_tick_owner(shard, type_id)
	if runtime == nil || runtime.active_count == 0 {
		return
	}

	_runtime_scan_deadlines(runtime, shard, Monotonic_Time_NS(shard.current_tick * shard.timer_resolution_ns))
}

@(test)
test_connection_keepalive_wait_arms_idle_before_header :: proc(t: ^testing.T) {
	idle_slot_indices: [1]u16
	idle_slot_handles: [1]tina.Handle
	idle_slot_positions: [1]u16
	idle_slot_positions[0] = u16(IDLE_ARRAY_INDEX_NONE)

	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 60,
				timeout_ms_header = 10,
				timeout_ms_body   = 30,
				timeout_ms_send   = 30,
			},
		},
		idle_slot_indices     = idle_slot_indices[:],
		idle_slot_handles     = idle_slot_handles[:],
		idle_slot_positions   = idle_slot_positions[:],
		connection_slot_count = 1,
	}

	shard := tina.Shard {timer_resolution_ns = 1}
	ctx := tina.TinaContext {}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime

	_connection_begin_keep_alive_wait(&connection, &ctx)
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Keep_Alive_Idle)
	testing.expect(t, connection.connection_state.deadline_ns_idle != 0, "idle deadline should arm while parked")
	testing.expect_value(t, connection.connection_state.deadline_ns_header, Monotonic_Time_NS(0))

	_connection_prepare_incoming_request(&connection, &ctx)
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Recv_Headers)
	testing.expect_value(t, connection.connection_state.deadline_ns_idle, Monotonic_Time_NS(0))
	testing.expect(t, connection.connection_state.deadline_ns_header != 0, "header deadline should arm on request start")
}

@(test)
test_runtime_scan_deadlines_wakes_waiting_connection :: proc(t: ^testing.T) {
	message_pool_backing: [512]u8
	shard := tina.Shard{}
	tina.pool_init(&shard.message_pool, message_pool_backing[:], tina.MESSAGE_ENVELOPE_SIZE)

	shard.type_descriptors = make([]tina.TypeDescriptor, 1)
	defer mem.delete(shard.type_descriptors)
	shard.type_descriptors[0].stride = size_of(HTTP_Connection)

	shard.isolate_memory = make([][]u8, 1)
	defer mem.delete(shard.isolate_memory)
	shard.isolate_memory[0] = make([]u8, size_of(HTTP_Connection))
	defer mem.delete(shard.isolate_memory[0])

	shard.metadata = make([]#soa[]tina.Isolate_Metadata, 1)
	defer mem.delete(shard.metadata)
	shard.metadata[0] = make(#soa[]tina.Isolate_Metadata, 1)
	defer mem.delete(shard.metadata[0])
	shard.metadata[0][0].generation = 1
	shard.metadata[0][0].state = .Waiting_For_Io

	active_slot_indices: [1]u16
	active_slot_positions: [1]u16
	active_slot_positions[0] = 0
	runtime := HTTP_Shard_Runtime {
		connection_type_id    = 0,
		active_slot_indices   = active_slot_indices[:],
		active_slot_positions = active_slot_positions[:],
		active_count          = 1,
		connection_slot_count = 1,
	}

	connection := cast(^HTTP_Connection)&shard.isolate_memory[0][0]
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Keep_Alive_Idle
	connection.connection_state.request_token = Request_Token(7)
	connection.connection_state.deadline_ns_idle = Monotonic_Time_NS(5)

	_runtime_scan_deadlines(&runtime, &shard, Monotonic_Time_NS(10))

	testing.expect_value(t, shard.metadata[0][0].state, tina.Isolate_State.Runnable)
	testing.expect_value(t, shard.metadata[0][0].io_sequence, u8(1))
	testing.expect_value(t, shard.metadata[0][0].inbox_count, u16(1))

	envelope := tina.pool_get_ptr_unchecked(&shard.message_pool, shard.metadata[0][0].inbox_head)
	testing.expect_value(t, envelope.tag, tina.Message_Tag(TAG_IDLE_TIMEOUT))
	testing.expect_value(t, envelope.correlation, tina.Correlation_Id(7))
}
