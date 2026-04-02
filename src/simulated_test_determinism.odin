package tina

import "core:testing"

when TINA_SIMULATION_MODE {
	Ping_Pong_Run_Result :: struct {
		ping_state:             Isolate_State,
		pong_state:             Isolate_State,
		ping_count:             u32,
		io_stale_completions:   u64,
		ring_full_drops:        u64,
		quarantine_drops:       u64,
		termination_reason:     Termination_Reason,
		final_round:            u64,
	}

	run_ping_pong_simulation_once :: proc(seed: u64) -> Ping_Pong_Run_Result {
		types := [3]TypeDescriptor {
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
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = COORDINATOR_TYPE_ID, restart_type = .permanent},
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
			seed                   = seed,
			ticks_max              = 10_000,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 100,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 1024,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 4096,
			transfer_slot_count       = 4,
			transfer_slot_size        = 4096,
			timer_spoke_count         = 1024,
			timer_entry_count         = 1024,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_arena_size        = 65536,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		if err != .None {
			panic("simulator_init failed in run_ping_pong_simulation_once")
		}

		simulator_run(&sim)

		shard := &sim.shards[0]
		ping_pointer := _get_isolate_ptr(shard, u16(PING_TYPE_ID), 0)
		ping_memory := cast(^PingIsolate)ping_pointer

		return Ping_Pong_Run_Result {
			ping_state           = shard.metadata[PING_TYPE_ID].state[0],
			pong_state           = shard.metadata[PONG_TYPE_ID].state[0],
			ping_count           = ping_memory.count,
			io_stale_completions = shard.counters.io_stale_completions,
			ring_full_drops      = shard.counters.ring_full_drops,
			quarantine_drops     = shard.counters.quarantine_drops,
			termination_reason   = sim.termination_reason,
			final_round          = sim.final_round,
		}
	}

	@(test)
	test_simulation_replay_ping_pong_is_deterministic :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		result1 := run_ping_pong_simulation_once(t.seed)
		result2 := run_ping_pong_simulation_once(t.seed)

		testing.expect_value(t, result1.ping_state, result2.ping_state)
		testing.expect_value(t, result1.pong_state, result2.pong_state)
		testing.expect_value(t, result1.ping_count, result2.ping_count)
		testing.expect_value(t, result1.io_stale_completions, result2.io_stale_completions)
		testing.expect_value(t, result1.ring_full_drops, result2.ring_full_drops)
		testing.expect_value(t, result1.quarantine_drops, result2.quarantine_drops)
		testing.expect_value(t, result1.termination_reason, result2.termination_reason)
		testing.expect_value(t, result1.final_round, result2.final_round)
		testing.expect_value(t, result1.ping_count, 100)
	}

	// Verifies that same seed replays identically even under fault injection,
	// and that a different seed diverges in at least one observable counter.
	@(test)
	test_different_seed_diverges_under_faults :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		run_with_faults :: proc(seed: u64) -> Ping_Pong_Run_Result {
			types := [3]TypeDescriptor {
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
			}

			children := [1]Child_Spec {
				Static_Child_Spec{type_id = COORDINATOR_TYPE_ID, restart_type = .permanent},
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
				seed                   = seed,
				ticks_max              = 10_000,
				terminate_on_quiescent = true,
				builtin_checkers       = CHECKER_FLAGS_ALL,
				checker_interval_ticks = 100,
				faults = FaultConfig {
					isolate_crash_rate = Ratio{1, 10}, // 10% crash rate per handler
				},
			}

			spec := SystemSpec {
				shard_count               = 1,
				types                     = types[:],
				shard_specs               = shard_specs[:],
				simulation                = &sim_config,
				pool_slot_count           = 1024,
				reactor_buffer_slot_count = 4,
				reactor_buffer_slot_size  = 4096,
				transfer_slot_count       = 4,
				transfer_slot_size        = 4096,
				timer_spoke_count         = 1024,
				timer_entry_count         = 1024,
				fd_table_slot_count       = 16,
				fd_entry_size             = size_of(FD_Entry),
				log_ring_size             = 4096,
				supervision_groups_max    = 16,
				scratch_arena_size        = 65536,
			}

			sim: Simulator
			err := simulator_init(&sim, &spec, context.temp_allocator)
			if err != .None {
				panic("simulator_init failed in run_with_faults")
			}

			simulator_run(&sim)

			shard := &sim.shards[0]
			ping_pointer := _get_isolate_ptr(shard, u16(PING_TYPE_ID), 0)
			ping_memory := cast(^PingIsolate)ping_pointer

			return Ping_Pong_Run_Result {
				ping_state           = shard.metadata[PING_TYPE_ID].state[0],
				pong_state           = shard.metadata[PONG_TYPE_ID].state[0],
				ping_count           = ping_memory.count,
				io_stale_completions = shard.counters.io_stale_completions,
				ring_full_drops      = shard.counters.ring_full_drops,
				quarantine_drops     = shard.counters.quarantine_drops,
				termination_reason   = sim.termination_reason,
				final_round          = sim.final_round,
			}
		}

		// Same seed must replay identically
		r1a := run_with_faults(0xAAAA)
		r1b := run_with_faults(0xAAAA)
		testing.expect_value(t, r1a.final_round, r1b.final_round)
		testing.expect_value(t, r1a.ping_count, r1b.ping_count)
		testing.expect_value(t, r1a.termination_reason, r1b.termination_reason)

		// Different seeds should diverge in at least one counter
		r2 := run_with_faults(0xBBBB)
		differs :=
			r1a.ping_count != r2.ping_count ||
			r1a.final_round != r2.final_round ||
			r1a.termination_reason != r2.termination_reason

		testing.expect(t, differs, "Different seeds with fault injection should produce observably different runs")
	}
}
