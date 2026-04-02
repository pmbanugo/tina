package tina

import "core:fmt"
import "core:mem"

when TINA_SIMULATION_MODE {

	Termination_Reason :: enum u8 {
		Ticks_Max,
		Quiescent,
		Checker_Violation,
	}

	Simulator :: struct {
		spec:               ^SystemSpec,
		shards:             []Shard, // Allocated as a flat array
		shard_states:       []u8, // Backing for Shard.shared_state (bypasses watchdog)
		network:            SimulatedNetwork,
		prng_tree:          Prng_Tree,
		fault_engine:       FaultEngine,

		// For fast-forward and clock management
		tick_resolution_ns: u64,

		// Post-run observable state
		final_round:        u64,
		termination_reason: Termination_Reason,
	}

	// Simulation is a structural overlay over the production runtime, not a
	// separate scheduler architecture. The harness may replace the clock,
	// transport, and backend implementations, but it must preserve the
	// scheduler-facing contracts those subsystems expose.

	// ============================================================================
	// Simulation Bootstrap (§10.1 in SIMULATION_MODE_DST.md)
	// ============================================================================
	simulator_init :: proc(
		sim: ^Simulator,
		spec: ^SystemSpec,
		allocator: mem.Allocator,
	) -> mem.Allocator_Error {
		sim.spec = spec
		sim.shards = make([]Shard, spec.shard_count, allocator)
		sim.shard_states = make([]u8, spec.shard_count, allocator)

		// Use the validated timer resolution from the spec (uniform across all shards)
		sim.tick_resolution_ns = spec.timer_resolution_ns

		// SI-1: Initialize PRNG Tree
		seed := spec.simulation.seed
		prng_tree_init(&sim.prng_tree, seed, int(spec.shard_count), allocator)

		// SI-3: Initialize Simulated Network
		// Calculate ring sizes using painter's algorithm
		ring_counts := compute_ring_sizes(
			spec.shard_count,
			spec.default_ring_size,
			spec.ring_overrides,
			allocator,
		)
		sim_network_init(
			&sim.network,
			spec.shard_count,
			ring_counts,
			&sim.prng_tree.network_drop,
			allocator,
		)

		// SI-5: Initialize Fault Engine
		sim.fault_engine = FaultEngine {
			partition_prng = &sim.prng_tree.partition,
			fault_config   = &spec.simulation.faults,
			network        = &sim.network,
			shard_count    = spec.shard_count,
		}

		// SI-4: Allocate Grand Arenas and Hydrate Shards sequentially (No OS threads!)
		shard_memory_size := compute_shard_memory_total(spec)

		for i in 0 ..< spec.shard_count {
			shard := &sim.shards[i]
			shard.id = u8(i)
			shard.sim_state.network = &sim.network
			shard.sim_state.fault_config = &spec.simulation.faults
			shard.sim_state.crash_prng = &sim.prng_tree.shard_crash[i]

			// Use standard memory allocation for the Grand Arena in simulation
			// (we bypass mmap/guard pages because we are single-threaded and testing logic)
			arena_mem := make([]u8, shard_memory_size, allocator)

			arena := Grand_Arena{}
			grand_arena_init(&arena, shard_memory_size)
			arena.base = arena_mem // Override with our slice

			// Hydrate the Shard
			if err := hydrate_shard(&arena, spec, shard); err != .None {
				fmt.eprintfln("[SIM FATAL] Failed to hydrate Shard %d: %v", i, err)
				return err
			}

			// Wire up shared_state before tree building (ctx_spawn reads it)
			sim.shard_states[i] = u8(Shard_State.Running)
			shard.shared_state = &sim.shard_states[i]

			// Initialize Supervision Tree
			alloc_data := Grand_Arena_Allocator_Data {
				arena = &arena,
			}
			arena_alloc := grand_arena_allocator(&alloc_data)

			if int(i) < len(spec.shard_specs) {
				shard_build_supervision_tree(
					shard,
					&spec.shard_specs[i].root_group,
					arena_alloc,
					&alloc_data,
				)
			}
		}

		// Clean up temporary ring sizing array
		for row in ring_counts do delete(row, allocator)
		delete(ring_counts, allocator)

		return .None
	}

	// ============================================================================
	// Global Simulation Loop (§3 in SIMULATION_MODE_DST.md)
	// ============================================================================
	simulator_run :: proc(sim: ^Simulator) {
		fmt.printfln(
			"[SIM] Starting deterministic simulation. Seed: 0x%16X",
			sim.spec.simulation.seed,
		)

		round: u64 = 0
		ticks_max := sim.spec.simulation.ticks_max
		reason := Termination_Reason.Ticks_Max

		// Pre-allocate array for shuffled shard execution order
		order := make([]u8, sim.spec.shard_count, context.temp_allocator)
		for i in 0 ..< sim.spec.shard_count do order[i] = u8(i)

		loop: for round < ticks_max {
			// Round contract:
			// - every shard ticks exactly once
			// - interleaving diversity comes from execution order, not skipping
			// - all shards observe the same simulated "now" for the round
			// 1. Advance simulated time globally & Fast-Forward Logic
			if sim.spec.simulation.terminate_on_quiescent && simulator_is_globally_idle(sim) {
				earliest_deadline: u64 = max(u64)

				for i in 0 ..< sim.spec.shard_count {
					d := timer_wheel_earliest_deadline(&sim.shards[i].timer_wheel)
					if d < earliest_deadline do earliest_deadline = d
				}

				if earliest_deadline == max(u64) {
					reason = .Quiescent
					break loop
				} else if earliest_deadline > round {
					// Time Travel: Instantly fast-forward to the exact tick the next timer fires
					round = earliest_deadline
				}
			}
			// 2. Fault engine: per-round decisions (partitions, heals, jitter)
			fault_engine_tick(&sim.fault_engine, round)

			// 3. Determine Shard execution order for this round
			if sim.spec.simulation.shuffle_shard_order {
				// Fisher-Yates shuffle using the scheduling PRNG
				for i := u32(sim.spec.shard_count) - 1; i > 0; i -= 1 {
					j := prng_uint_less_than(&sim.prng_tree.scheduling, i + 1)
					order[i], order[j] = order[j], order[i]
				}
			}

			// 4. Tick each Shard exactly once
			for shard_id in order {
				shard := &sim.shards[shard_id]
				// The clock advances synchronously for all shards in the sim
				shard.current_tick = round
				scheduler_tick(shard)
			}

			// 5. Run structural checkers at interval
			if sim.spec.simulation.checker_interval_ticks > 0 &&
			   round % u64(sim.spec.simulation.checker_interval_ticks) == 0 {
				if simulator_run_checkers(sim, round) {
					reason = .Checker_Violation
					break loop
				}
			}

			// 6. Quiescence Check
			if sim.spec.simulation.terminate_on_quiescent {
				if simulator_is_globally_idle(sim) {
					reason = .Quiescent
					break loop
				}
			}

			round += 1
		}

		sim.final_round = round
		sim.termination_reason = reason

		// Unconditional final checker run at simulation end
		if reason != .Checker_Violation {
			if simulator_run_checkers(sim, round) {
				sim.termination_reason = .Checker_Violation
			}
		}

		simulator_print_summary(sim)
	}

	// ============================================================================
	// End-of-Simulation Summary
	// ============================================================================
	@(private = "file")
	simulator_print_summary :: proc(sim: ^Simulator) {
		reason_label: string
		switch sim.termination_reason {
		case .Ticks_Max:
			reason_label = "maximum ticks reached"
		case .Quiescent:
			reason_label = "quiescent (no pending work or timers)"
		case .Checker_Violation:
			reason_label = "checker violation"
		}

		fmt.printfln(
			"[SIM] Simulation complete: seed=0x%16X, rounds=%d, termination=%s",
			sim.spec.simulation.seed,
			sim.final_round,
			reason_label,
		)

		// Aggregate counters across shards
		total_stale_delivery: u64 = 0
		total_ring_full: u64 = 0
		total_quarantine: u64 = 0
		total_pool_exhaustion: u64 = 0
		total_mailbox_full: u64 = 0
		total_io_buffer_exhaustion: u64 = 0
		total_io_stale: u64 = 0
		total_transfer_exhaustion: u64 = 0
		total_transfer_stale: u64 = 0

		for i in 0 ..< sim.spec.shard_count {
			c := &sim.shards[i].counters
			total_stale_delivery += c.stale_delivery_drops
			total_ring_full += c.ring_full_drops
			total_quarantine += c.quarantine_drops
			total_pool_exhaustion += c.pool_exhaustion_drops
			total_mailbox_full += c.mailbox_full_drops
			total_io_buffer_exhaustion += c.io_buffer_exhaustions
			total_io_stale += c.io_stale_completions
			total_transfer_exhaustion += c.transfer_exhaustions
			total_transfer_stale += c.transfer_stale_reads
		}

		fmt.printfln(
			"[SIM] Backpressure: mailbox_full=%d, pool_exhaustion=%d, ring_full=%d, stale_delivery=%d, quarantine=%d",
			total_mailbox_full,
			total_pool_exhaustion,
			total_ring_full,
			total_stale_delivery,
			total_quarantine,
		)
		fmt.printfln(
			"[SIM] I/O: stale_completions=%d, buffer_exhaustions=%d, transfer_exhaustions=%d, transfer_stale=%d",
			total_io_stale,
			total_io_buffer_exhaustion,
			total_transfer_exhaustion,
			total_transfer_stale,
		)
	}
}
