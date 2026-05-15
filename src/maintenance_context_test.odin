package tina

import "core:testing"

@(test)
test_shard_maintenance_context_exposes_time_and_local_enqueue :: proc(t: ^testing.T) {
	Maintenance_Context_Test_State :: struct {
		t:            ^testing.T,
		current_tick: u64,
		shard_id:     Shard_Id,
	}
	test_state := Maintenance_Context_Test_State {
		t        = t,
		shard_id = Shard_Id(255),
	}

	message_count: u16
	message: Message

	message_count, message = test_with_local_context(
		Test_Local_Context_Config {
			self_handle         = make_handle(0, 1, 0, 1),
			target_handle       = make_handle(0, 2, 0, 1),
			monotonic_time_ns   = Monotonic_Time_NS(42),
			current_tick        = 42,
			flags               = {.Maintenance},
			timer_resolution_ns = 1,
			target_state        = .Waiting,
		},
		rawptr(&test_state),
		proc(user_data: rawptr, ctx: TinaContext) {
			state := cast(^Maintenance_Context_Test_State)user_data
			maintenance_ctx := Shard_Maintenance_Context(ctx)
			state.current_tick = shard_maintenance_current_tick(maintenance_ctx)
			state.shard_id = shard_maintenance_shard_id(maintenance_ctx)
			empty_payload: []u8
			send_result := shard_maintenance_send_local_with_correlation(
				maintenance_ctx,
				make_handle(0, 2, 0, 1),
				Message_Tag(USER_MESSAGE_TAG_BASE),
				empty_payload,
				Correlation_Id(77),
			)
			testing.expect_value(state.t, send_result, Send_Result.ok)
		},
	)

	testing.expect_value(t, test_state.current_tick, u64(42))
	testing.expect_value(t, test_state.shard_id, Shard_Id(0))
	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, Message_Tag(USER_MESSAGE_TAG_BASE))
	testing.expect_value(t, message.correlation, Correlation_Id(77))
	testing.expect_value(t, message.user.source, HANDLE_NONE)
}

@(test)
test_shard_maintenance_wake_if_waiting_for_io_wakes_target :: proc(t: ^testing.T) {
	Wake_Test_State :: struct {
		t:                  ^testing.T,
		target_handle:      Handle,
		wake_result:        bool,
		target_state:       Isolate_State,
		target_io_sequence: u8,
	}
	target_handle := make_handle(0, 2, 0, 1)
	test_state := Wake_Test_State {
		t             = t,
		target_handle = target_handle,
	}

	message_count, _ := test_with_local_context(
		Test_Local_Context_Config {
			self_handle         = make_handle(0, 1, 0, 1),
			target_handle       = target_handle,
			current_tick        = 7,
			flags               = {.Maintenance},
			timer_resolution_ns = 1,
			target_state        = .Waiting_For_Io,
		},
		rawptr(&test_state),
		proc(user_data: rawptr, ctx: TinaContext) {
			state := cast(^Wake_Test_State)user_data
			maintenance_ctx := Shard_Maintenance_Context(ctx)
			state.wake_result = shard_maintenance_wake_if_waiting_for_io(
				maintenance_ctx,
				state.target_handle,
			)

			invocation := ctx_invocation(ctx)
			soa_meta := invocation.shard.metadata[extract_type_id(state.target_handle)]
			state.target_state = soa_meta[extract_slot(state.target_handle)].state
			state.target_io_sequence = soa_meta[extract_slot(state.target_handle)].io_sequence
		},
	)

	testing.expect_value(t, test_state.wake_result, true)
	testing.expect_value(t, test_state.target_state, Isolate_State.Runnable)
	testing.expect_value(t, test_state.target_io_sequence, u8(1))
	testing.expect_value(t, message_count, u16(0))
}
