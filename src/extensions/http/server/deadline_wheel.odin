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

	connection := runtime.active_connections[active_index]
	if connection != nil {
		_deadline_disarm(runtime, connection)
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

@(private = "file")
_deadline_clear_timestamps :: proc(state: ^HTTP_Connection_State) {
	state.deadline_ns_idle = 0
	state.deadline_ns_header = 0
	state.deadline_ns_body = 0
	state.deadline_ns_send = 0
	state.deadline_ns_drain = 0
}

@(private = "file")
_deadline_store_timestamp :: proc(
	state: ^HTTP_Connection_State,
	deadline_ns: tina.Monotonic_Time_NS,
	tag: tina.Message_Tag,
) {
	_deadline_clear_timestamps(state)
	switch tag {
	case TAG_IDLE_TIMEOUT:
		state.deadline_ns_idle = deadline_ns
	case TAG_HEADER_TIMEOUT:
		state.deadline_ns_header = deadline_ns
	case TAG_BODY_TIMEOUT:
		state.deadline_ns_body = deadline_ns
	case TAG_SEND_TIMEOUT:
		state.deadline_ns_send = deadline_ns
	case TAG_DRAIN_TIMEOUT:
		state.deadline_ns_drain = deadline_ns
	case:
	}
}

@(private = "file")
_deadline_connection_at_slot :: proc(runtime: ^HTTP_Shard_Runtime, slot_index: u16) -> ^HTTP_Connection {
	if runtime == nil || slot_index == DEADLINE_SLOT_INDEX_NONE || int(slot_index) >= len(runtime.active_slot_positions) {
		return nil
	}

	active_index := runtime.active_slot_positions[slot_index]
	if active_index == u16(IDLE_ARRAY_INDEX_NONE) || int(active_index) >= len(runtime.active_connections) {
		return nil
	}

	return runtime.active_connections[active_index]
}

@(private = "file")
_deadline_unlink :: proc(runtime: ^HTTP_Shard_Runtime, connection: ^HTTP_Connection) {
	state := &connection.connection_state
	if .Armed not_in state.deadline_flags {
		return
	}

	previous_index := state.deadline_previous_index
	next_index := state.deadline_next_index
	spoke_index := state.deadline_spoke_index

	if previous_index != DEADLINE_SLOT_INDEX_NONE {
		previous_connection := _deadline_connection_at_slot(runtime, previous_index)
		if previous_connection != nil {
			previous_connection.connection_state.deadline_next_index = next_index
		}
	} else if spoke_index != DEADLINE_SLOT_INDEX_NONE {
		runtime.deadline_spoke_heads[spoke_index] = next_index
	}

	if next_index != DEADLINE_SLOT_INDEX_NONE {
		next_connection := _deadline_connection_at_slot(runtime, next_index)
		if next_connection != nil {
			next_connection.connection_state.deadline_previous_index = previous_index
		}
	}

	state.deadline_next_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_previous_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_spoke_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_flags -= {.Armed}
	if runtime.deadline_armed_count > 0 {
		runtime.deadline_armed_count -= 1
	}
}

@(private = "file")
_deadline_link :: proc(runtime: ^HTTP_Shard_Runtime, connection: ^HTTP_Connection, deadline_tick: u64) {
	if runtime == nil || connection == nil || len(runtime.deadline_spoke_heads) == 0 {
		return
	}
	state := &connection.connection_state
	spoke_index := u16(deadline_tick & runtime.deadline_spoke_mask)
	slot_index := u16(tina.extract_slot(state.self_handle))
	head_index := runtime.deadline_spoke_heads[spoke_index]

	if head_index != DEADLINE_SLOT_INDEX_NONE {
		head_connection := _deadline_connection_at_slot(runtime, head_index)
		if head_connection != nil {
			head_connection.connection_state.deadline_previous_index = slot_index
		}
	}

	runtime.deadline_spoke_heads[spoke_index] = slot_index
	state.deadline_tick = deadline_tick
	state.deadline_next_index = head_index
	state.deadline_previous_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_spoke_index = spoke_index
	state.deadline_flags += {.Armed}
	runtime.deadline_armed_count += 1
}

@(private = "package")
_deadline_disarm :: proc(runtime: ^HTTP_Shard_Runtime, connection: ^HTTP_Connection) {
	if runtime == nil || connection == nil {
		return
	}
	_deadline_unlink(runtime, connection)
	state := &connection.connection_state
	_deadline_clear_timestamps(state)
	state.deadline_tick = 0
	state.deadline_next_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_previous_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_spoke_index = DEADLINE_SLOT_INDEX_NONE
	state.deadline_tag = tina.Message_Tag(0)
	state.deadline_correlation = tina.CORRELATION_ID_NONE
	state.deadline_flags = {}
}

@(private = "package")
_deadline_arm :: proc(
	runtime: ^HTTP_Shard_Runtime,
	ctx: tina.TinaContext,
	connection: ^HTTP_Connection,
	duration_ns: u64,
	tag: tina.Message_Tag,
	correlation: tina.Correlation_Id,
) {
	if runtime == nil || connection == nil {
		return
	}
	state := &connection.connection_state
	now_ns := tina.ctx_monotonic_time_ns(ctx)
	deadline_ns := tina.Monotonic_Time_NS(u64(now_ns) + duration_ns)
	if len(runtime.deadline_spoke_heads) == 0 {
		state.deadline_tag = tag
		state.deadline_correlation = correlation
		state.deadline_flags -= {.Timeout_Queued}
		_deadline_store_timestamp(state, deadline_ns, tag)
		return
	}

	_deadline_unlink(runtime, connection)

	resolution_ns := tina.ctx_timer_resolution_ns(ctx)
	duration_tick_count := (duration_ns + resolution_ns - 1) / resolution_ns
	if duration_tick_count == 0 do duration_tick_count = 1
	deadline_tick := tina.ctx_current_tick(ctx) + duration_tick_count
	state.deadline_tag = tag
	state.deadline_correlation = correlation
	state.deadline_flags -= {.Timeout_Queued}
	_deadline_link(runtime, connection, deadline_tick)
	_deadline_store_timestamp(state, deadline_ns, tag)
	if runtime.deadline_task_index != tina.MAINTENANCE_TASK_INDEX_NONE {
		_ = tina.ctx_reschedule_shard_maintenance_task(
			ctx,
			runtime.deadline_task_index,
			tina.ctx_current_tick(ctx),
		)
	}
}

@(private = "file")
_deadline_enqueue_timeout :: proc(
	ctx: tina.Shard_Maintenance_Context,
	connection: ^HTTP_Connection,
) -> tina.Send_Result {
	state := &connection.connection_state
	empty_payload: []u8
	return tina.shard_maintenance_send_local_with_correlation(
		ctx,
		state.self_handle,
		state.deadline_tag,
		empty_payload,
		state.deadline_correlation,
	)
}

@(private = "package")
_http_deadline_maintenance_task :: proc(
	self: rawptr,
	ctx: tina.Shard_Maintenance_Context,
	work_budget_count: tina.Scheduler_Work_Count,
) -> tina.Shard_Maintenance_Result {
	if self == nil {
		return tina.Shard_Maintenance_Result{}
	}
	runtime := cast(^HTTP_Shard_Runtime)self
	if runtime == nil || len(runtime.deadline_spoke_heads) == 0 {
		return tina.Shard_Maintenance_Result{}
	}
	if runtime.deadline_armed_count == 0 {
		return tina.Shard_Maintenance_Result{}
	}

	current_tick := tina.shard_maintenance_current_tick(ctx)
	work_count: u32 = 0
	work_budget := u32(work_budget_count)
	for runtime.deadline_current_tick < current_tick && work_count < work_budget {
		runtime.deadline_current_tick += 1
		spoke_index := u16(runtime.deadline_current_tick & runtime.deadline_spoke_mask)
		slot_index := runtime.deadline_spoke_heads[spoke_index]

		for slot_index != DEADLINE_SLOT_INDEX_NONE && work_count < work_budget {
			connection := _deadline_connection_at_slot(runtime, slot_index)
			if connection == nil || connection.connection_state.shard_runtime != runtime {
				runtime.deadline_spoke_heads[spoke_index] = DEADLINE_SLOT_INDEX_NONE
				slot_index = DEADLINE_SLOT_INDEX_NONE
				work_count += 1
				continue
			}

			state := &connection.connection_state
			next_index := state.deadline_next_index
			if state.deadline_tick <= current_tick {
				_deadline_unlink(runtime, connection)
				send_result := _deadline_enqueue_timeout(ctx, connection)
				switch send_result {
				case .ok:
					_ = tina.shard_maintenance_wake_if_waiting_for_io(ctx, state.self_handle)
					state.deadline_flags += {.Timeout_Queued}
				case .mailbox_full, .pool_exhausted:
					_deadline_link(runtime, connection, current_tick + 1)
				case .stale_handle:
					_deadline_disarm(runtime, connection)
				}
			}

			slot_index = next_index
			work_count += 1
		}

		if slot_index != DEADLINE_SLOT_INDEX_NONE && work_count >= work_budget {
			runtime.deadline_current_tick -= 1
			break
		}
	}

	return tina.Shard_Maintenance_Result {
		work_count = tina.Scheduler_Work_Count(work_count),
		wants_reschedule = true,
	}
}

@(private = "package")
_http_register_deadline_maintenance_task :: proc(runtime: ^HTTP_Shard_Runtime, ctx: tina.TinaContext) -> bool {
	runtime.deadline_current_tick = tina.ctx_current_tick(ctx)
	task_index := tina.ctx_register_shard_maintenance_task(
		ctx,
		tina.Shard_Maintenance_Descriptor {
			state                 = rawptr(runtime),
			handler               = _http_deadline_maintenance_task,
			cadence_tick_count    = 1,
			budget_weight         = tina.Scheduler_Weight_Count(1),
			work_budget_count_max = tina.Scheduler_Work_Count(runtime.deadline_due_count_max),
		},
	)
	if task_index == tina.MAINTENANCE_TASK_INDEX_NONE {
		return false
	}
	runtime.deadline_task_index = task_index
	return true
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
test_deadline_rearm_replaces_existing_node :: proc(t: ^testing.T) {
	active_slot_indices: [1]u16
	active_connections: [1]^HTTP_Connection
	active_slot_positions: [1]u16
	active_slot_positions[0] = 0
	deadline_spoke_heads: [16]u16
	for index in 0 ..< len(deadline_spoke_heads) {
		deadline_spoke_heads[index] = DEADLINE_SLOT_INDEX_NONE
	}
	runtime := HTTP_Shard_Runtime {
		active_slot_indices   = active_slot_indices[:],
		active_connections    = active_connections[:],
		active_slot_positions = active_slot_positions[:],
		active_count          = 1,
		deadline_spoke_heads  = deadline_spoke_heads[:],
		deadline_spoke_mask   = u64(len(deadline_spoke_heads) - 1),
		deadline_due_count_max = u16(len(deadline_spoke_heads)),
		connection_slot_count = 1,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)
	active_connections[0] = &connection
	Deadline_Rearm_Test_State :: struct {runtime: ^HTTP_Shard_Runtime, connection: ^HTTP_Connection}
	deadline_rearm_test_state := Deadline_Rearm_Test_State {runtime = &runtime, connection = &connection}

	tina.test_with_context(
		tina.Test_Context_Config {
			self_handle         = connection.connection_state.self_handle,
			timer_resolution_ns = 1,
		},
		rawptr(&deadline_rearm_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Deadline_Rearm_Test_State)user_data
			_deadline_arm(
				test_state.runtime,
				ctx,
				test_state.connection,
				5,
				TAG_SEND_TIMEOUT,
				tina.Correlation_Id(1),
			)
			_deadline_arm(
				test_state.runtime,
				ctx,
				test_state.connection,
				9,
				TAG_SEND_TIMEOUT,
				tina.Correlation_Id(2),
			)
		},
	)

	testing.expect_value(t, deadline_spoke_heads[5], DEADLINE_SLOT_INDEX_NONE)
	testing.expect_value(t, deadline_spoke_heads[9], u16(0))
	testing.expect_value(t, connection.connection_state.deadline_tick, u64(9))
	testing.expect_value(t, connection.connection_state.deadline_correlation, tina.Correlation_Id(2))
	testing.expect_value(t, runtime.deadline_armed_count, u16(1))
	testing.expect(t, .Armed in connection.connection_state.deadline_flags, "deadline should remain armed")

	_deadline_disarm(&runtime, &connection)
	testing.expect_value(t, deadline_spoke_heads[9], DEADLINE_SLOT_INDEX_NONE)
	testing.expect_value(t, connection.connection_state.deadline_ns_send, tina.Monotonic_Time_NS(0))
	testing.expect_value(t, runtime.deadline_armed_count, u16(0))
	testing.expect(t, .Armed not_in connection.connection_state.deadline_flags, "deadline should disarm")
}

@(test)
test_deadline_maintenance_disables_when_no_deadlines_are_armed :: proc(t: ^testing.T) {
	Deadline_Maintenance_Idle_Test_State :: struct {
		runtime:                ^HTTP_Shard_Runtime,
		result_work_count:      tina.Scheduler_Work_Count,
		result_wants_reschedule: bool,
	}
	runtime := HTTP_Shard_Runtime {
		deadline_current_tick = 10,
	}
	idle_test_state := Deadline_Maintenance_Idle_Test_State {
		runtime                 = &runtime,
		result_wants_reschedule = true,
	}
	tina.test_with_context(
		tina.Test_Context_Config {
			self_handle         = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_LISTENER), 0, 1),
			monotonic_time_ns   = tina.Monotonic_Time_NS(10),
			timer_resolution_ns = 1,
		},
		rawptr(&idle_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Deadline_Maintenance_Idle_Test_State)user_data
			result := _http_deadline_maintenance_task(
				rawptr(test_state.runtime),
				tina.Shard_Maintenance_Context(ctx),
				tina.Scheduler_Work_Count(8),
			)
			test_state.result_work_count = result.work_count
			test_state.result_wants_reschedule = result.wants_reschedule
		},
	)

	testing.expect_value(t, idle_test_state.result_work_count, tina.Scheduler_Work_Count(0))
	testing.expect(t, !idle_test_state.result_wants_reschedule, "idle deadline task should disable itself")
}

@(test)
test_deadline_maintenance_wakes_waiting_connection :: proc(t: ^testing.T) {
	active_slot_indices: [1]u16
	active_connections: [1]^HTTP_Connection
	active_slot_positions: [1]u16
	active_slot_positions[0] = 0
	deadline_spoke_heads: [16]u16
	for index in 0 ..< len(deadline_spoke_heads) {
		deadline_spoke_heads[index] = DEADLINE_SLOT_INDEX_NONE
	}
		runtime := HTTP_Shard_Runtime {
			connection_type_id    = 0,
			active_slot_indices   = active_slot_indices[:],
			active_connections    = active_connections[:],
			active_slot_positions = active_slot_positions[:],
			active_count          = 1,
			deadline_spoke_heads  = deadline_spoke_heads[:],
			deadline_spoke_mask   = u64(len(deadline_spoke_heads) - 1),
			deadline_current_tick = 0,
			deadline_armed_count  = 1,
			deadline_due_count_max = u16(len(deadline_spoke_heads)),
			connection_slot_count = 1,
		}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)
	connection.connection_state.state = .Keep_Alive_Idle
	connection.connection_state.request_token = Request_Token(7)
	connection.connection_state.deadline_ns_idle = tina.Monotonic_Time_NS(5)
	connection.connection_state.deadline_tick = 5
	connection.connection_state.deadline_next_index = DEADLINE_SLOT_INDEX_NONE
	connection.connection_state.deadline_previous_index = DEADLINE_SLOT_INDEX_NONE
	connection.connection_state.deadline_spoke_index = 5
	connection.connection_state.deadline_tag = TAG_IDLE_TIMEOUT
	connection.connection_state.deadline_correlation = tina.Correlation_Id(7)
	connection.connection_state.deadline_flags = {.Armed}
	active_connections[0] = &connection
	deadline_spoke_heads[5] = 0
	Deadline_Maintenance_Test_State :: struct {runtime: ^HTTP_Shard_Runtime}
	deadline_maintenance_test_state := Deadline_Maintenance_Test_State {runtime = &runtime}

	message_count, message := tina.test_with_local_context(
		tina.Test_Local_Context_Config {
			self_handle         = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_LISTENER), 0, 1),
			target_handle       = connection.connection_state.self_handle,
			monotonic_time_ns   = tina.Monotonic_Time_NS(10),
			current_tick        = 10,
			flags               = {.Maintenance},
			timer_resolution_ns = 1,
			target_state        = .Waiting_For_Io,
		},
		rawptr(&deadline_maintenance_test_state),
		proc(user_data: rawptr, ctx: tina.TinaContext) {
			test_state := cast(^Deadline_Maintenance_Test_State)user_data
			_ = _http_deadline_maintenance_task(
				rawptr(test_state.runtime),
				tina.Shard_Maintenance_Context(ctx),
				tina.Scheduler_Work_Count(16),
			)
		},
	)

	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, tina.Message_Tag(TAG_IDLE_TIMEOUT))
	testing.expect_value(t, message.correlation, tina.Correlation_Id(7))
	testing.expect(t, .Timeout_Queued in connection.connection_state.deadline_flags, "deadline should queue once")
}
