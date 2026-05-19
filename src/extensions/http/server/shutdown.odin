package http_server

import tina "../../.."
import "core:testing"
import "core:mem"

@(private = "package")
_timeout_duration_ns :: #force_inline proc "contextless" (timeout_ms: u32) -> u64 {
	return u64(timeout_ms) * 1_000_000
}

@(private = "file")
_connection_arm_or_rearm_deadline :: proc(
	connection: ^HTTP_Connection,
	ctx: tina.TinaContext,
	duration_ns: u64,
	tag: Message_Tag,
) {
	state := &connection.connection_state
	correlation := tina.Correlation_Id(state.request_token)
	handle := state.deadline_timer_handle
	deadline_armed := handle != tina.TIMER_HANDLE_NONE && state.deadline_ns != 0

	state.deadline_ns = tina.Monotonic_Time_NS(u64(tina.ctx_monotonic_time_ns(ctx)) + duration_ns)
	if deadline_armed {
		tina.ctx_rearm_renewable_deadline(ctx, handle, duration_ns, tag, correlation)
		return
	}

	handle = tina.ctx_arm_renewable_deadline(ctx, duration_ns, tag, correlation)
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(
			handle != tina.TIMER_HANDLE_NONE,
			"_connection_arm_or_rearm_deadline: renewable deadline pool exhausted",
		)
	}
	state.deadline_timer_handle = handle
}

@(private = "package")
_connection_should_drain :: #force_inline proc(
	runtime: ^HTTP_Shard_Runtime,
	ctx: tina.TinaContext,
) -> bool {
	return(runtime != nil && runtime.draining) || tina.ctx_is_shutting_down(ctx)
}

@(private = "package")
_idle_slot_push :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	assert(runtime != nil, "_idle_slot_push: runtime is nil")
	assert(u16(runtime.idle_count) < runtime.connection_slot_count, "idle slot tracker overflow")

	self_handle := tina.ctx_self_handle(ctx)
	slot_index := u16(tina.extract_slot(self_handle))
	dense_index := u16(runtime.idle_count)
	runtime.idle_slot_indices[dense_index] = slot_index
	runtime.idle_slot_handles[dense_index] = self_handle
	runtime.idle_slot_positions[slot_index] = dense_index
	state.idle_array_index = Idle_Array_Index(dense_index)
	runtime.idle_count = Idle_Array_Count(u16(runtime.idle_count) + 1)
}

@(private = "package")
_idle_slot_remove :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || u16(runtime.idle_count) == 0 do return

	slot_index := u16(tina.extract_slot(tina.ctx_self_handle(ctx)))
	dense_index := runtime.idle_slot_positions[slot_index]
	if dense_index == u16(IDLE_ARRAY_INDEX_NONE) do return

	last_index := u16(runtime.idle_count) - 1
	last_slot := runtime.idle_slot_indices[last_index]
	last_handle := runtime.idle_slot_handles[last_index]

	if dense_index != last_index {
		runtime.idle_slot_indices[dense_index] = last_slot
		runtime.idle_slot_handles[dense_index] = last_handle
		runtime.idle_slot_positions[last_slot] = dense_index
	}

	runtime.idle_slot_positions[slot_index] = u16(IDLE_ARRAY_INDEX_NONE)
	runtime.idle_count = Idle_Array_Count(u16(runtime.idle_count) - 1)
	state.idle_array_index = IDLE_ARRAY_INDEX_NONE
}

@(private = "package")
_connection_begin_keep_alive_wait :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	assert(runtime != nil, "_connection_begin_keep_alive_wait: runtime is nil")

	request_state_reset(&state.request)
	response_state_reset(&state.response)
	parser_state_reset(&state.parser)
	state.request_arena_region.offset = 0

	state.ingress_size = 0
	state.ingress_parsed_offset = 0
	state.state = .Keep_Alive_Idle
	state.application_expectation_kind = .Reply
	state.application_expected_source = tina.HANDLE_NONE
	state.application_expected_tag = Message_Tag(0)
	state.application_correlation_id = tina.CORRELATION_ID_NONE
	state.application_timeout_ns = 0
	state.application_pending_message_valid = false
	state.application_pending_message.payload_size = 0
	state.request_body_size_received = 0
	state.sendfile_offset = 0
	state.sendfile_size_remaining = 0
	state.request_body_complete_notified = false
	state.request_frame_size = 0
	state.pipeline_tail_size = 0
	state.buffered_body_size = 0
	state.sendfile_file_fd = tina.FD_HANDLE_NONE
	state.response_flush_final = false
	state.sendfile_active = false
	if len(state.route_state_bytes) > 0 {
		mem.zero(raw_data(state.route_state_bytes), len(state.route_state_bytes))
	}
	state.request_token += 1
	if state.request_token == 0 do state.request_token = 1

	duration_ns := _timeout_duration_ns(runtime.server.timeouts.timeout_ms_idle)
	_connection_arm_or_rearm_deadline(connection, ctx, duration_ns, TAG_IDLE_TIMEOUT)

	_idle_slot_push(connection, ctx)
}

@(private = "package")
_connection_prepare_incoming_request :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	if state.state != .Keep_Alive_Idle {
		return
	}

	_idle_slot_remove(connection, ctx)
	state.state = .Recv_Headers
	duration_ns := _timeout_duration_ns(state.shard_runtime.server.timeouts.timeout_ms_header)
	_connection_arm_or_rearm_deadline(connection, ctx, duration_ns, TAG_HEADER_TIMEOUT)
}

@(private = "package")
_connection_arm_send_timeout :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil do return
	duration_ns := _timeout_duration_ns(runtime.server.timeouts.timeout_ms_send)
	_connection_arm_or_rearm_deadline(connection, ctx, duration_ns, TAG_SEND_TIMEOUT)
}

@(private = "package")
_connection_arm_body_timeout :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil do return
	duration_ns := _timeout_duration_ns(runtime.server.timeouts.timeout_ms_body)
	_connection_arm_or_rearm_deadline(connection, ctx, duration_ns, TAG_BODY_TIMEOUT)
}

@(private = "package")
_connection_arm_drain_timeout :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil do return
	duration_ns := _timeout_duration_ns(runtime.server.graceful_drain_ms)
	_connection_arm_or_rearm_deadline(connection, ctx, duration_ns, TAG_DRAIN_TIMEOUT)
}

@(private = "package")
_connection_mark_draining :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) -> bool {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil do return false

	runtime.draining = true
	state.response.flags += {.In_Drain, .Close_After_Send}
	_connection_arm_drain_timeout(connection, ctx)

	if state.state == .Keep_Alive_Idle {
		_idle_slot_remove(connection, ctx)
		state.state = .Closing
		return true
	}

	return false
}

@(private = "package")
_connection_timeout_is_current :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext, correlation: tina.Correlation_Id) -> bool {
	state := &connection.connection_state
	if state.deadline_ns == 0 do return false
	if correlation != tina.Correlation_Id(state.request_token) do return false
	return tina.ctx_monotonic_time_ns(ctx) >= state.deadline_ns
}

@(private = "package")
_runtime_evict_idle_connection :: proc(runtime: ^HTTP_Shard_Runtime, ctx: tina.TinaContext) -> bool {
	if runtime == nil || u16(runtime.idle_count) == 0 do return false

	victim_handle := runtime.idle_slot_handles[u16(runtime.idle_count)-1]
	if victim_handle == tina.HANDLE_NONE do return false

	empty_payload: []u8
	return tina.ctx_send_raw(ctx, victim_handle, TAG_EVICT, empty_payload) == tina.Send_Result.ok
}

@(private = "package")
_listener_evict_idle_connection :: proc(listener: ^HTTP_Listener, ctx: tina.TinaContext) -> bool {
	return _runtime_evict_idle_connection(listener.shard_runtime, ctx)
}

@(private = "package")
_runtime_active_slot_add :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		return
	}

	self_handle := tina.ctx_self_handle(ctx)
	slot_index := u16(tina.extract_slot(self_handle))
	if int(slot_index) >= len(runtime.active_slot_positions) ||
	   int(runtime.active_count) >= len(runtime.active_slot_indices) ||
	   int(runtime.active_count) >= len(runtime.active_connections) {
		return
	}
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
_runtime_active_slot_remove :: proc(connection: ^HTTP_Connection, ctx: tina.TinaContext) -> bool {
	state := &connection.connection_state
	if state.shard_runtime == nil {
		return false
	}
	return _runtime_active_slot_remove_by_slot(
		state.shard_runtime,
		u16(tina.extract_slot(tina.ctx_self_handle(ctx))),
	)
}

@(private = "file")
_runtime_active_slot_remove_by_slot :: proc(runtime: ^HTTP_Shard_Runtime, slot_index: u16) -> bool {
	if runtime == nil {
		return false
	}
	if int(slot_index) >= len(runtime.active_slot_positions) || u16(runtime.active_count) == 0 {
		return false
	}

	active_index := runtime.active_slot_positions[slot_index]
	if active_index == u16(IDLE_ARRAY_INDEX_NONE) ||
	   active_index >= u16(runtime.active_count) ||
	   int(active_index) >= len(runtime.active_connections) {
		return false
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
	return true
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_idle_slot_swap_and_pop :: proc(t: ^testing.T) {
	indices: [4]u16
	handles: [4]tina.Handle
	positions: [4]u16
	for index in 0 ..< len(positions) {
		positions[index] = u16(IDLE_ARRAY_INDEX_NONE)
	}

	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime{},
		idle_slot_indices   = indices[:],
		idle_slot_handles   = handles[:],
		idle_slot_positions = positions[:],
		connection_slot_count = 4,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	Idle_Slot_Test_State :: struct {connection: ^HTTP_Connection}
	idle_slot_test_state := Idle_Slot_Test_State {connection = &connection}

	first_handle := tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 1, 1)
	second_handle := tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 3, 1)

	tina.test_with_context(
		tina.Test_Context_Config {self_handle = first_handle},
		rawptr(&idle_slot_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Idle_Slot_Test_State)user_data
			_idle_slot_push(test_state.connection, ctx)
		},
	)
	tina.test_with_context(
		tina.Test_Context_Config {self_handle = second_handle},
		rawptr(&idle_slot_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Idle_Slot_Test_State)user_data
			_idle_slot_push(test_state.connection, ctx)
		},
	)
	tina.test_with_context(
		tina.Test_Context_Config {self_handle = first_handle},
		rawptr(&idle_slot_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Idle_Slot_Test_State)user_data
			_idle_slot_remove(test_state.connection, ctx)
		},
	)

	testing.expect_value(t, u16(runtime.idle_count), u16(1))
	testing.expect_value(t, runtime.idle_slot_indices[0], u16(3))
	testing.expect_value(t, runtime.idle_slot_handles[0], second_handle)
	testing.expect_value(t, runtime.idle_slot_positions[3], u16(0))
	testing.expect_value(t, runtime.idle_slot_positions[1], u16(IDLE_ARRAY_INDEX_NONE))
}
