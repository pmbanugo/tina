package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {

	// ============================================================================
	// Scheduling contract tests (§B in Plan 05)
	// ============================================================================

	// Verifies every shard ticks exactly once per round by using a user checker
	// that inspects shard.current_tick progression across rounds.

	SCHED_NOOP_TYPE_ID: u8 : 0

	SchedNoopIsolate :: struct {}

	sched_noop_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Yield{}
	}

	sched_noop_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Yield{}
	}

	@(test)
	test_every_shard_ticks_once_per_round :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		SHARD_COUNT :: 3
		TICKS :: 10

		types := [1]TypeDescriptor {
			{
				id                = SCHED_NOOP_TYPE_ID,
				slot_count        = 1,
				stride            = size_of(SchedNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn           = sched_noop_init,
				handler_fn        = sched_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = SCHED_NOOP_TYPE_ID, restart_type = .permanent},
		}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [3]ShardSpec {
			{shard_id = 0, root_group = root_group},
			{shard_id = 1, root_group = root_group},
			{shard_id = 2, root_group = root_group},
		}

		// Checker that verifies all shards observed the same current_tick value,
		// confirming the harness ticked every shard in this round.
		verify_tick_uniformity :: proc(shards: []Shard, tick: u64) -> Check_Result {
			if len(shards) < 2 do return nil
			expected := shards[0].current_tick
			for i in 1 ..< len(shards) {
				if shards[i].current_tick != expected {
					return Check_Violation {
						message = "Shard current_tick values are not uniform across shards",
					}
				}
			}
			return nil
		}

		user_checkers := [1]Checker_Fn{verify_tick_uniformity}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = TICKS,
			terminate_on_quiescent = false,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			user_checkers          = user_checkers[:],
			checker_interval_ticks = 1, // Check every round
		}

		spec := SystemSpec {
			shard_count               = SHARD_COUNT,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
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
			default_ring_size         = 16,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		simulator_run(&sim)

		// If any shard had a tick mismatch, the checker would have fired
		testing.expect_value(t, sim.termination_reason, Termination_Reason.Ticks_Max)
		testing.expect_value(t, sim.final_round, u64(TICKS))

		// All shards should have ended on the last round value
		for i in 0 ..< SHARD_COUNT {
			testing.expect_value(t, sim.shards[i].current_tick, u64(TICKS - 1))
		}
	}
}
