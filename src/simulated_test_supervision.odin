package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {
	Supervisor :: struct {}
	Exiter :: struct {}
	Bystander :: struct {}
	Restart_Crash :: struct {}
	Restart_Wait :: struct {}
	Restart_Temporary :: struct {}

	supervisor_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		bystander_spec := Spawn_Spec {
			type_id      = BYSTANDER_TYPE_ID,
			group_id     = ctx_supervision_group_id(),
			restart_type = .temporary,
		}
		_ = assert_spawn_success(ctx_spawn(bystander_spec), "Bystander")

		exiter_spec := Spawn_Spec {
			type_id      = EXITER_TYPE_ID,
			group_id     = ctx_supervision_group_id(),
			restart_type = .temporary,
		}
		_ = assert_spawn_success(ctx_spawn(exiter_spec), "Exiter")

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	supervisor_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	exiter_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	exiter_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_DONE
	}

	bystander_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	bystander_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	restart_wait_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	restart_wait_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	restart_crash_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	restart_crash_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return transition_to_crash(.Contract_Violation)
	}

	@(test)
	test_one_for_all_does_not_respawn_temporary_sibling :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]IsolateTypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Restart_Crash),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = restart_crash_init,
				handler_fn = restart_crash_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(Restart_Temporary),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = restart_wait_init,
				handler_fn = restart_wait_handler,
			},
		}

		children := [2]Child_Spec {
			Static_Child_Spec{type_id = COORDINATOR_TYPE_ID, restart_type = .permanent},
			Static_Child_Spec{type_id = PING_TYPE_ID, restart_type = .temporary},
		}

		root_group := sim_test_make_root_group(children[:], .One_For_All)
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 100,
			terminate_on_quiescent = true,
		}

		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		crash_handle := make_handle(
			0,
			COORDINATOR_TYPE_ID,
			0,
			shard.metadata[COORDINATOR_TYPE_ID].generation[0],
		)
		envelope := Message_Envelope {
			source = ISOLATE_HANDLE_NONE,
			destination = crash_handle,
			tag = APP_TAG_PING,
		}
		_ = _route_envelope_user(shard, crash_handle, &envelope)

		simulator_run(&sim)

		testing.expect_value(t, shard.metadata[COORDINATOR_TYPE_ID]._state[0], Isolate_State.Wait_Message)
		testing.expect_value(t, shard.metadata[PING_TYPE_ID]._state[0], Isolate_State.Unallocated)
		testing.expect_value(t, shard.supervision_groups[0].children_handles[1], ISOLATE_HANDLE_NONE)
	}

	@(test)
	test_rest_for_one_does_not_respawn_temporary_successor :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [3]IsolateTypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Restart_Wait),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = restart_wait_init,
				handler_fn = restart_wait_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(Restart_Crash),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = restart_crash_init,
				handler_fn = restart_crash_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(Restart_Temporary),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = restart_wait_init,
				handler_fn = restart_wait_handler,
			},
		}

		children := [3]Child_Spec {
			Static_Child_Spec{type_id = COORDINATOR_TYPE_ID, restart_type = .permanent},
			Static_Child_Spec{type_id = PING_TYPE_ID, restart_type = .permanent},
			Static_Child_Spec{type_id = PONG_TYPE_ID, restart_type = .temporary},
		}

		root_group := sim_test_make_root_group(children[:], .Rest_For_One)
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 100,
			terminate_on_quiescent = true,
		}

		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		crash_handle := make_handle(
			0,
			PING_TYPE_ID,
			0,
			shard.metadata[PING_TYPE_ID].generation[0],
		)
		envelope := Message_Envelope {
			source = ISOLATE_HANDLE_NONE,
			destination = crash_handle,
			tag = APP_TAG_PING,
		}
		_ = _route_envelope_user(shard, crash_handle, &envelope)

		simulator_run(&sim)

		testing.expect_value(t, shard.metadata[COORDINATOR_TYPE_ID]._state[0], Isolate_State.Wait_Message)
		testing.expect_value(t, shard.metadata[PING_TYPE_ID]._state[0], Isolate_State.Wait_Message)
		testing.expect_value(t, shard.metadata[PONG_TYPE_ID]._state[0], Isolate_State.Unallocated)
		testing.expect_value(t, shard.supervision_groups[0].children_handles[2], ISOLATE_HANDLE_NONE)
	}

	@(test)
	test_temporary_child_exit_no_escalation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [6]IsolateTypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Coordinator),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = coordinator_init,
				handler_fn = coordinator_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(PingIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = ping_init,
				handler_fn = ping_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(PongIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = pong_init,
				handler_fn = pong_handler,
			},
			{
				id = SUPERVISOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Supervisor),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = supervisor_init,
				handler_fn = supervisor_handler,
			},
			{
				id = EXITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Exiter),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = exiter_init,
				handler_fn = exiter_handler,
			},
			{
				id = BYSTANDER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Bystander),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = bystander_init,
				handler_fn = bystander_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = SUPERVISOR_TYPE_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			child_count_dynamic_max = 10,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 100,
			terminate_on_quiescent = true,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 4096,
			transfer_slot_count       = 4,
			transfer_slot_size        = 4096,
			timer_entry_count         = 256,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_memory_size        = 65536,
		}

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]

		// Send a message to Exiter to trigger its handler (which returns DONE)
		exiter_handle := make_handle(
			0,
			EXITER_TYPE_ID,
			0,
			shard.metadata[EXITER_TYPE_ID].generation[0],
		)
		envelope := Message_Envelope {
			source       = ISOLATE_HANDLE_NONE,
			destination  = exiter_handle,
			tag          = APP_TAG_PING,
			payload_size = size_of(PingMsg),
		}
		(cast(^PingMsg)&envelope.payload[0])^ = PingMsg{seq = 0}
		_ = _route_envelope_user(shard, exiter_handle, &envelope)

		simulator_run(&sim)

		// Exiter should be torn down (temporary + normal exit = no restart)
		exiter_state := shard.metadata[EXITER_TYPE_ID]._state[0]
		testing.expect_value(t, exiter_state, Isolate_State.Unallocated)

		// Bystander must still be alive — no escalation should have occurred
		bystander_state := shard.metadata[BYSTANDER_TYPE_ID]._state[0]
		testing.expect_value(t, bystander_state, Isolate_State.Wait_Message)
	}

	@(test)
	test_mixed_static_subgroup_and_dynamic_children :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [6]IsolateTypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Coordinator),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = coordinator_init,
				handler_fn = coordinator_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(PingIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = ping_init,
				handler_fn = ping_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(PongIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = pong_init,
				handler_fn = pong_handler,
			},
			{
				id = SUPERVISOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Supervisor),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = supervisor_init,
				handler_fn = supervisor_handler,
			},
			{
				id = EXITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Exiter),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = exiter_init,
				handler_fn = exiter_handler,
			},
			{
				id = BYSTANDER_TYPE_ID,
				slot_count = 2,
				stride = size_of(Bystander),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = bystander_init,
				handler_fn = bystander_handler,
			},
		}

		subgroup_children := [1]Child_Spec {
			Static_Child_Spec{type_id = BYSTANDER_TYPE_ID, restart_type = .permanent},
		}
		subgroup := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = subgroup_children[:],
		}

		root_children := [2]Child_Spec {
			subgroup,
			Static_Child_Spec{type_id = SUPERVISOR_TYPE_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = root_children[:],
			child_count_dynamic_max = 4,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 100,
			terminate_on_quiescent = true,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 4096,
			transfer_slot_count       = 4,
			transfer_slot_size        = 4096,
			timer_entry_count         = 256,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_memory_size        = 65536,
		}

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		root := &shard.supervision_groups[0]

		testing.expect_value(t, root.child_count_static, u16(2))
		testing.expect_value(t, root.child_count_dynamic, u16(2))
		testing.expect_value(
			t,
			extract_type_id(root.children_handles[0]),
			SUPERVISION_SUBGROUP_TYPE_ID,
		)
		testing.expect_value(t, extract_slot(root.children_handles[0]), Isolate_Slot_Index(1))

		exiter_handle := make_handle(
			0,
			EXITER_TYPE_ID,
			0,
			shard.metadata[EXITER_TYPE_ID].generation[0],
		)
		envelope := Message_Envelope {
			source       = ISOLATE_HANDLE_NONE,
			destination  = exiter_handle,
			tag          = APP_TAG_PING,
			payload_size = size_of(PingMsg),
		}
		(cast(^PingMsg)&envelope.payload[0])^ = PingMsg{seq = 0}
		_ = _route_envelope_user(shard, exiter_handle, &envelope)

		simulator_run(&sim)

		testing.expect_value(t, root.child_count_static, u16(2))
		testing.expect_value(t, root.child_count_dynamic, u16(1))
		testing.expect_value(
			t,
			extract_type_id(root.children_handles[0]),
			SUPERVISION_SUBGROUP_TYPE_ID,
		)
		testing.expect_value(t, extract_slot(root.children_handles[0]), Isolate_Slot_Index(1))

		subgroup_bystander_state := shard.metadata[BYSTANDER_TYPE_ID]._state[0]
		dynamic_bystander_state := shard.metadata[BYSTANDER_TYPE_ID]._state[1]
		exiter_state := shard.metadata[EXITER_TYPE_ID]._state[0]

		testing.expect_value(t, subgroup_bystander_state, Isolate_State.Wait_Message)
		testing.expect_value(t, dynamic_bystander_state, Isolate_State.Wait_Message)
		testing.expect_value(t, exiter_state, Isolate_State.Unallocated)
	}

	@(test)
	test_shard_restart_intensity_window :: proc(t: ^testing.T) {
		spec := SystemSpec {
			quarantine_policy = .Quarantine,
			watchdog = Watchdog_Config {
				check_interval_ms = 100,
				shard_restart_window_ms = 1_000,
				shard_restart_max = 2,
				phase_2_threshold = 2,
			},
		}

		report: Shard_Health_Report

		exceeded := _check_and_record_shard_restart(&report, &spec, 100)
		testing.expect_value(t, exceeded, false)
		testing.expect_value(t, report.restart_count, u16(1))

		exceeded = _check_and_record_shard_restart(&report, &spec, 500_000_000)
		testing.expect_value(t, exceeded, false)
		testing.expect_value(t, report.restart_count, u16(2))

		exceeded = _check_and_record_shard_restart(&report, &spec, 900_000_000)
		testing.expect_value(t, exceeded, true)
		testing.expect_value(t, report.restart_count, u16(3))

		exceeded = _check_and_record_shard_restart(&report, &spec, 1_500_000_000)
		testing.expect_value(t, exceeded, false)
		testing.expect_value(t, report.restart_count, u16(1))
		testing.expect_value(t, report.restart_window_start_ns, u64(1_500_000_000))
	}
}
