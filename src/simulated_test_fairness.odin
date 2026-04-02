package tina

import "core:fmt"
import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {

	// ============================================================================
	// Intra-Type Starvation Prevention (Dispatch Cursor Verification)
	// ============================================================================

	STARVATION_COORD_ID: u8 : 0
	STARVATION_WORKER_ID: u8 : 1

	StarvationWorker :: struct {
		run_count: u32,
	}

	starvation_coord_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		// Spawn 300 workers to exceed the 256 DISPATCH_QUOTA_PER_WEIGHT
		for i in 0 ..< 300 {
			spec := Spawn_Spec {
				type_id      = STARVATION_WORKER_ID,
				group_id     = ctx_supervision_group_id(ctx),
				restart_type = .temporary,
			}
			_ = assert_spawn_success(ctx_spawn(ctx, spec), "StarvationWorker")
		}
		return Effect_Receive{}
	}

	starvation_coord_handler :: proc(
		self: rawptr,
		message: ^Message,
		ctx: ^TinaContext,
	) -> Effect {
		return Effect_Receive{}
	}

	starvation_worker_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Yield{}
	}

	starvation_worker_handler :: proc(
		self: rawptr,
		message: ^Message,
		ctx: ^TinaContext,
	) -> Effect {
		w := cast(^StarvationWorker)self
		w.run_count += 1
		// Yielding keeps us in .Runnable state, ensuring we always consume budget
		return Effect_Yield{}
	}

	@(test)
	test_intra_type_starvation_prevention :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]TypeDescriptor {
			{
				id                = STARVATION_COORD_ID,
				slot_count        = 1,
				stride            = 0, // Zero-sized, purely behavioral
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn           = starvation_coord_init,
				handler_fn        = starvation_coord_handler,
			},
			{
				id                = STARVATION_WORKER_ID,
				slot_count        = 300,
				stride            = size_of(StarvationWorker),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn           = starvation_worker_init,
				handler_fn        = starvation_worker_handler,
				budget_weight     = 1, // Quota = 1 * 256 = 256 dispatches per tick
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = STARVATION_COORD_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			child_count_dynamic_max = 305, // Room for 1 Coord + 300 Workers + padding/wiggle-room
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10, // Exactly 10 ticks. 10 * 256 budget = 2560 dispatches
			terminate_on_quiescent = false, // Never quiescent because workers always yield
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 10,
		}

		spec := SystemSpec {
			shard_count               = 1,
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
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		// Run the 10 ticks
		simulator_run(&sim)

		shard := &sim.shards[0]
		starved_count: u32 = 0
		min_runs: u32 = max(u32)
		max_runs: u32 = 0

		// Verify every single worker got a fair share of the 2,560 total dispatches
		for i in 0 ..< 300 {
			worker_pointer := _get_isolate_ptr(shard, u16(STARVATION_WORKER_ID), u32(i))
			worker := cast(^StarvationWorker)worker_pointer

			if worker.run_count == 0 {
				starved_count += 1
			}

			if worker.run_count < min_runs do min_runs = worker.run_count
			if worker.run_count > max_runs do max_runs = worker.run_count
		}

		// If the bug exists, starved_count will be exactly 44 (slots 256 to 299)
		testing.expect_value(t, starved_count, 0)

		// Mathematical fairness check: 2560 total dispatches / 300 isolates = ~8.5
		// Every isolate should have run 8 or 9 times.
		testing.expect(t, min_runs >= 8, "Fairness violation: some isolates ran too rarely")
		testing.expect(t, max_runs <= 9, "Fairness violation: some isolates ran too often")

		fmt.printfln(
			"\n[TEST SUCCESS] Intra-type starvation prevented. All 300 isolates ran fairly (Min: %d, Max: %d).",
			min_runs,
			max_runs,
		)
	}
}
