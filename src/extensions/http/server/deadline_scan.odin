package http_server

import tina "../../.."
import "core:testing"

@(private = "package")
_runtime_active_slot_add :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		return
	}

	self_handle := tina.ctx_self_handle(ctx)
	slot_index := u16(tina.extract_slot(self_handle))
	if runtime.active_slot_positions[slot_index] != u16(IDLE_ARRAY_INDEX_NONE) {
		return
	}

	active_index := u16(runtime.active_count)
	runtime.active_slot_indices[active_index] = slot_index
	runtime.active_connections[active_index] = connection
	runtime.active_slot_positions[slot_index] = active_index
	runtime.active_count = Active_Array_Count(active_index + 1)
}

@(private = "package")
_runtime_active_slot_remove :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	if state.shard_runtime == nil {
		return
	}
	_runtime_active_slot_remove_by_slot(state.shard_runtime, u16(tina.extract_slot(tina.ctx_self_handle(ctx))))
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
		runtime.active_connections[active_index] = runtime.active_connections[last_index]
		runtime.active_slot_positions[last_slot] = active_index
	}

	runtime.active_connections[last_index] = nil
	runtime.active_slot_positions[slot_index] = u16(IDLE_ARRAY_INDEX_NONE)
	runtime.active_count = Active_Array_Count(last_index)
}

@(private = "file")
_connection_timeout_tag :: proc(
	state: ^HTTP_Connection_State,
	now_ns: tina.Monotonic_Time_NS,
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
	ctx: tina.TinaTickContext,
	slot_index: u16,
	handle: tina.Handle,
	tag: tina.Message_Tag,
	correlation: tina.Correlation_Id,
) -> bool {
	connection := runtime.active_connections[runtime.active_slot_positions[slot_index]]
	if connection == nil {
		return false
	}
	empty_payload: []u8
	return tina.ctx_tick_send_local(ctx, handle, tag, empty_payload, correlation) == .ok
}

@(private = "file")
_runtime_scan_deadlines :: proc(runtime: ^HTTP_Shard_Runtime, ctx: tina.TinaTickContext, now_ns: tina.Monotonic_Time_NS) {
	active_index := 0
	for active_index < int(runtime.active_count) {
		slot_index := runtime.active_slot_indices[active_index]
		connection := runtime.active_connections[active_index]
		if connection == nil || connection.connection_state.shard_runtime != runtime {
			_runtime_active_slot_remove_by_slot(runtime, slot_index)
			continue
		}
		state := &connection.connection_state

		timeout_tag, correlation, timed_out := _connection_timeout_tag(state, now_ns)
		if timed_out {
			_ = _runtime_enqueue_timeout(runtime, ctx, slot_index, state.self_handle, timeout_tag, correlation)
		}

		active_index += 1
	}
}

@(private = "package")
_http_runtime_tick :: proc(self: rawptr, ctx: tina.TinaTickContext) {
	if self == nil {
		return
	}
	runtime: ^HTTP_Shard_Runtime
	type_id := tina.ctx_tick_type_id(ctx)
	if type_id == u16(HTTP_TYPE_OFFSET_LISTENER) {
		runtime = (cast(^HTTP_Listener)self).shard_runtime
	} else {
		runtime = (cast(^HTTP_Dispatcher)self).shard_runtime
	}
	if runtime == nil || runtime.active_count == 0 {
		return
	}

	_runtime_scan_deadlines(runtime, ctx, tina.ctx_tick_monotonic_time_ns(ctx))
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

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)
	Keep_Alive_Test_State :: struct {connection: ^HTTP_Connection}
	keep_alive_test_state := Keep_Alive_Test_State {connection = &connection}

	tina.test_with_context(
		tina.Test_Context_Config {
			self_handle         = connection.connection_state.self_handle,
			timer_resolution_ns = 1,
		},
		rawptr(&keep_alive_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Keep_Alive_Test_State)user_data
			_connection_begin_keep_alive_wait(test_state.connection, ctx)
		},
	)
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Keep_Alive_Idle)
	testing.expect(t, connection.connection_state.deadline_ns_idle != 0, "idle deadline should arm while parked")
	testing.expect_value(t, connection.connection_state.deadline_ns_header, tina.Monotonic_Time_NS(0))

	tina.test_with_context(
		tina.Test_Context_Config {
			self_handle         = connection.connection_state.self_handle,
			timer_resolution_ns = 1,
		},
		rawptr(&keep_alive_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Keep_Alive_Test_State)user_data
			_connection_prepare_incoming_request(test_state.connection, ctx)
		},
	)
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Recv_Headers)
	testing.expect_value(t, connection.connection_state.deadline_ns_idle, tina.Monotonic_Time_NS(0))
	testing.expect(t, connection.connection_state.deadline_ns_header != 0, "header deadline should arm on request start")
}

@(test)
test_runtime_scan_deadlines_wakes_waiting_connection :: proc(t: ^testing.T) {
	active_slot_indices: [1]u16
	active_connections: [1]^HTTP_Connection
	active_slot_positions: [1]u16
	active_slot_positions[0] = 0
	runtime := HTTP_Shard_Runtime {
		connection_type_id    = 0,
		active_slot_indices   = active_slot_indices[:],
		active_connections    = active_connections[:],
		active_slot_positions = active_slot_positions[:],
		active_count          = 1,
		connection_slot_count = 1,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)
	connection.connection_state.state = .Keep_Alive_Idle
	connection.connection_state.request_token = Request_Token(7)
	connection.connection_state.deadline_ns_idle = tina.Monotonic_Time_NS(5)
	active_connections[0] = &connection
	Deadline_Scan_Test_State :: struct {runtime: ^HTTP_Shard_Runtime}
	deadline_scan_test_state := Deadline_Scan_Test_State {runtime = &runtime}

	message_count, message := tina.test_with_local_tick_context(
		tina.Test_Local_Tick_Config {
			self_handle         = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_LISTENER), 0, 1),
			target_handle       = connection.connection_state.self_handle,
			monotonic_time_ns   = tina.Monotonic_Time_NS(10),
			current_tick        = 10,
			timer_resolution_ns = 1,
			target_state        = .Waiting_For_Io,
		},
		rawptr(&deadline_scan_test_state),
		proc(user_data: rawptr, ctx: tina.TinaTickContext) {
			test_state := cast(^Deadline_Scan_Test_State)user_data
			_runtime_scan_deadlines(test_state.runtime, ctx, tina.Monotonic_Time_NS(10))
		},
	)

	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, tina.Message_Tag(TAG_IDLE_TIMEOUT))
	testing.expect_value(t, message.correlation, tina.Correlation_Id(7))
}
