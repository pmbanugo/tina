package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {

	// ============================================================================
	// Harness-level tests: termination reason, final checkers, user checkers
	// ============================================================================

	HARNESS_NOOP_TYPE_ID: u8 : 0

	HarnessNoopIsolate :: struct {}

	harness_noop_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	harness_noop_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	// Helper: build a minimal simulation with one noop isolate
	@(private = "file")
	_make_harness_test_spec :: proc(
		sim_config: ^SimulationConfig,
		types: []TypeDescriptor,
		shard_specs: []ShardSpec,
	) -> SystemSpec {
		return SystemSpec {
			shard_count               = 1,
			types                     = types,
			shard_specs               = shard_specs,
			simulation                = sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_spoke_count         = 64,
			timer_entry_count         = 64,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 4,
			scratch_arena_size        = 8192,
		}
	}

	@(test)
	test_termination_reason_quiescent :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]TypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10_000,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 100,
		}

		spec := _make_harness_test_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		simulator_run(&sim)

		testing.expect_value(t, sim.termination_reason, Termination_Reason.Quiescent)
		testing.expect(t, sim.final_round < 10_000, "Should terminate early via quiescence")
	}

	@(test)
	test_termination_reason_ticks_max :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]TypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 5,
			terminate_on_quiescent = false,
		}

		spec := _make_harness_test_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		simulator_run(&sim)

		testing.expect_value(t, sim.termination_reason, Termination_Reason.Ticks_Max)
		testing.expect_value(t, sim.final_round, u64(5))
	}

	@(test)
	test_user_checker_violation_stops_simulation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]TypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		// User checker that fires a violation after round 3
		always_fail_after_3 :: proc(shards: []Shard, tick: u64) -> Check_Result {
			if tick >= 3 {
				return Check_Violation{message = "test violation at round 3"}
			}
			return nil
		}

		user_checkers := [1]Checker_Fn{always_fail_after_3}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 1000,
			terminate_on_quiescent = false,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			user_checkers          = user_checkers[:],
			checker_interval_ticks = 1,
		}

		spec := _make_harness_test_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		simulator_run(&sim)

		testing.expect_value(t, sim.termination_reason, Termination_Reason.Checker_Violation)
		testing.expect(t, sim.final_round <= 3, "Should stop at or before round 3 due to checker violation")
	}

	@(test)
	test_final_checkers_run_on_quiescent_termination :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]TypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		// User checker that always fires — should be caught by the final checker run
		// even though checker_interval_ticks is 0 (no periodic checks)
		always_fail :: proc(shards: []Shard, tick: u64) -> Check_Result {
			return Check_Violation{message = "final checker caught this"}
		}

		user_checkers := [1]Checker_Fn{always_fail}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10_000,
			terminate_on_quiescent = true,
			user_checkers          = user_checkers[:],
			checker_interval_ticks = 0, // No periodic checks — only final
		}

		spec := _make_harness_test_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		simulator_run(&sim)

		// The loop exits via quiescence, but the final checker run should catch the violation
		testing.expect_value(t, sim.termination_reason, Termination_Reason.Checker_Violation)
	}

	@(test)
	test_disabled_builtin_checkers_do_not_fire :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]TypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		// User checker that always passes
		always_ok :: proc(shards: []Shard, tick: u64) -> Check_Result {
			return nil
		}

		user_checkers := [1]Checker_Fn{always_ok}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 5,
			terminate_on_quiescent = false,
			builtin_checkers       = CHECKER_FLAGS_NONE,
			user_checkers          = user_checkers[:],
			checker_interval_ticks = 1,
		}

		spec := _make_harness_test_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		// Corrupt message pool to trigger Pool_Integrity if it were enabled
		sim.shards[0].message_pool.free_count = sim.shards[0].message_pool.slot_count + 1

		simulator_run(&sim)

		testing.expect_value(t, sim.termination_reason, Termination_Reason.Ticks_Max)
	}
}
