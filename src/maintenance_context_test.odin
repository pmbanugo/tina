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
