package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {
	Supervisor :: struct {}
	Exiter :: struct {}
	Bystander :: struct {}

	supervisor_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		bystander_spec := Spawn_Spec {
			type_id      = BYSTANDER_TYPE_ID,
			group_id     = ctx_supervision_group_id(ctx),
			restart_type = .temporary,
		}
		_ = assert_spawn_success(ctx_spawn(ctx, bystander_spec), "Bystander")

		exiter_spec := Spawn_Spec {
			type_id      = EXITER_TYPE_ID,
			group_id     = ctx_supervision_group_id(ctx),
			restart_type = .temporary,
		}
		_ = assert_spawn_success(ctx_spawn(ctx, exiter_spec), "Exiter")

		return Effect_Receive{}
	}

	supervisor_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	exiter_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	exiter_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Done{}
	}

	bystander_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	bystander_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	@(test)
	test_temporary_child_exit_no_escalation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [6]TypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Coordinator),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = coordinator_init,
				handler_fn = coordinator_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(PingIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = ping_init,
				handler_fn = ping_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(PongIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = pong_init,
				handler_fn = pong_handler,
			},
			{
				id = SUPERVISOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Supervisor),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = supervisor_init,
				handler_fn = supervisor_handler,
			},
			{
				id = EXITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Exiter),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = exiter_init,
				handler_fn = exiter_handler,
			},
			{
				id = BYSTANDER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Bystander),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = bystander_init,
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
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_arena_size        = 65536,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		shard := &sim.shards[0]

		// Send a message to Exiter to trigger its handler (which returns Effect_Done)
		exiter_handle := make_handle(
			0,
			u16(EXITER_TYPE_ID),
			0,
			shard.metadata[EXITER_TYPE_ID].generation[0],
		)
		ctx := TinaContext {
			_shard      = shard,
			self_handle = HANDLE_NONE,
		}
		_ = ctx_send(&ctx, exiter_handle, APP_TAG_PING, &PingMsg{seq = 0})

		simulator_run(&sim)

		// Exiter should be torn down (temporary + normal exit = no restart)
		exiter_state := shard.metadata[EXITER_TYPE_ID].state[0]
		testing.expect_value(t, exiter_state, Isolate_State.Unallocated)

		// Bystander must still be alive — no escalation should have occurred
		bystander_state := shard.metadata[BYSTANDER_TYPE_ID].state[0]
		testing.expect_value(t, bystander_state, Isolate_State.Waiting)
	}

	@(test)
	test_mixed_static_subgroup_and_dynamic_children :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [6]TypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Coordinator),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = coordinator_init,
				handler_fn = coordinator_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(PingIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = ping_init,
				handler_fn = ping_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(PongIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = pong_init,
				handler_fn = pong_handler,
			},
			{
				id = SUPERVISOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Supervisor),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = supervisor_init,
				handler_fn = supervisor_handler,
			},
			{
				id = EXITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Exiter),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = exiter_init,
				handler_fn = exiter_handler,
			},
			{
				id = BYSTANDER_TYPE_ID,
				slot_count = 2,
				stride = size_of(Bystander),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = bystander_init,
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
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_arena_size        = 65536,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		shard := &sim.shards[0]
		root := &shard.supervision_groups[0]

		testing.expect_value(t, root.child_count_static, u16(2))
		testing.expect_value(t, root.child_count_dynamic, u16(2))
		testing.expect_value(
			t,
			extract_type_id(root.children_handles[0]),
			u16(SUPERVISION_SUBGROUP_TYPE_ID),
		)
		testing.expect_value(t, extract_slot(root.children_handles[0]), u32(1))

		exiter_handle := make_handle(
			0,
			u16(EXITER_TYPE_ID),
			0,
			shard.metadata[EXITER_TYPE_ID].generation[0],
		)
		ctx := TinaContext {
			_shard      = shard,
			self_handle = HANDLE_NONE,
		}
		_ = ctx_send(&ctx, exiter_handle, APP_TAG_PING, &PingMsg{seq = 0})

		simulator_run(&sim)

		testing.expect_value(t, root.child_count_static, u16(2))
		testing.expect_value(t, root.child_count_dynamic, u16(1))
		testing.expect_value(
			t,
			extract_type_id(root.children_handles[0]),
			u16(SUPERVISION_SUBGROUP_TYPE_ID),
		)
		testing.expect_value(t, extract_slot(root.children_handles[0]), u32(1))

		subgroup_bystander_state := shard.metadata[BYSTANDER_TYPE_ID].state[0]
		dynamic_bystander_state := shard.metadata[BYSTANDER_TYPE_ID].state[1]
		exiter_state := shard.metadata[EXITER_TYPE_ID].state[0]

		testing.expect_value(t, subgroup_bystander_state, Isolate_State.Waiting)
		testing.expect_value(t, dynamic_bystander_state, Isolate_State.Waiting)
		testing.expect_value(t, exiter_state, Isolate_State.Unallocated)
	}

	@(test)
	test_shard_restart_intensity_window :: proc(t: ^testing.T) {
		spec := SystemSpec {
			quarantine_policy = .Quarantine,
			watchdog = Watchdog_Config {
				check_interval_ms       = 100,
				shard_restart_window_ms = 1_000,
				shard_restart_max       = 2,
				phase_2_threshold       = 2,
			},
		}

		config := Shard_Config {
			system_spec = &spec,
		}

		exceeded := _check_and_record_shard_restart(&config, 100)
		testing.expect_value(t, exceeded, false)
		testing.expect_value(t, config.shard_restart_count, u16(1))

		exceeded = _check_and_record_shard_restart(&config, 500_000_000)
		testing.expect_value(t, exceeded, false)
		testing.expect_value(t, config.shard_restart_count, u16(2))

		exceeded = _check_and_record_shard_restart(&config, 900_000_000)
		testing.expect_value(t, exceeded, true)
		testing.expect_value(t, config.shard_restart_count, u16(3))

		exceeded = _check_and_record_shard_restart(&config, 1_500_000_000)
		testing.expect_value(t, exceeded, false)
		testing.expect_value(t, config.shard_restart_count, u16(1))
		testing.expect_value(t, config.shard_restart_window_ns, u64(1_500_000_000))
	}
}
