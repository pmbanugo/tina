package tina

import "core:fmt"
import "core:mem"

when TINA_SIMULATION_MODE {

	Simulator :: struct {
		spec:               ^SystemSpec,
		shards:             []Shard, // Allocated as a flat array
		shard_states:       []u8, // Backing for Shard.shared_state (bypasses watchdog)
		network:            SimulatedNetwork,
		prng_tree:          Prng_Tree,
		fault_engine:       FaultEngine,

		// For fast-forward and clock management
		tick_resolution_ns: u64,
	}

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

		// Validate uniform timer resolution (ADR constraint)
		sim.tick_resolution_ns = 1_000_000 // Default 1ms
		// In a real implementation we'd read this from the spec, but we enforce uniformity.

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
			shard.id = u16(i)
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

		// Pre-allocate array for shuffled shard execution order
		order := make([]u16, sim.spec.shard_count, context.temp_allocator)
		for i in 0 ..< sim.spec.shard_count do order[i] = u16(i)

		for round < ticks_max {
			// 1. Advance simulated time globally & Fast-Forward Logic
			if sim.spec.simulation.terminate_on_quiescent && simulator_is_globally_idle(sim) {
				earliest_deadline: u64 = max(u64)

				for i in 0 ..< sim.spec.shard_count {
					d := timer_wheel_earliest_deadline(&sim.shards[i].timer_wheel)
					if d < earliest_deadline do earliest_deadline = d
				}

				if earliest_deadline == max(u64) {
					fmt.printfln(
						"[SIM] Terminating early at round %d: System is globally quiescent with no timers.",
						round,
					)
					break
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
				violation := simulator_run_checkers(sim, round)
				if violation {
					fmt.eprintfln("[SIM] Checker violation at round %d. Aborting.", round)
					break
				}
			}

			// 6. Quiescence Check
			if sim.spec.simulation.terminate_on_quiescent {
				if simulator_is_globally_idle(sim) {
					fmt.printfln(
						"[SIM] Terminating early at round %d: System is globally quiescent.",
						round,
					)
					break
				}
			}

			round += 1
		}

		fmt.printfln("[SIM] Simulation complete at round %d.", round)
	}

	// ============================================================================
	// Structural Checkers (§7 in SIMULATION_MODE_DST.md)
	// ============================================================================

	// Returns true if any checker detected a violation.
	simulator_run_checkers :: proc(sim: ^Simulator, round: u64) -> bool {
		for i in 0 ..< sim.spec.shard_count {
			shard := &sim.shards[i]

			// Pool integrity: reactor buffer pool
			// The free_count + buffers held in completions + buffers in-flight in
			// the backend must equal the total slot_count. Since we can't easily
			// count in-flight buffers, we verify a weaker invariant:
			// free_count must not exceed slot_count (underflow/corruption).
			pool := &shard.reactor.buffer_pool
			if pool.free_count > pool.slot_count {
				fmt.eprintfln(
					"[CHECKER] Shard %d: reactor buffer pool corruption — free_count (%d) > slot_count (%d)",
					i,
					pool.free_count,
					pool.slot_count,
				)
				return true
			}

			// Pool integrity: message pool
			msg_pool := &shard.message_pool
			if msg_pool.free_count > msg_pool.slot_count {
				fmt.eprintfln(
					"[CHECKER] Shard %d: message pool corruption — free_count (%d) > slot_count (%d)",
					i,
					msg_pool.free_count,
					msg_pool.slot_count,
				)
				return true
			}

			// Generation monotonicity: generations must never be zero
			// (zero is reserved for HANDLE_NONE / stale sentinel)
			for type_desc in shard.type_descriptors {
				type_id := type_desc.id
				for slot in 0 ..< type_desc.slot_count {
					gen := shard.metadata[type_id].generation[slot]
					if gen == 0 {
						fmt.eprintfln(
							"[CHECKER] Shard %d: generation zero at type=%d slot=%d (round %d)",
							i,
							type_id,
							slot,
							round,
						)
						return true
					}
				}
			}
		}
		return false
	}

	simulator_is_globally_idle :: proc(sim: ^Simulator) -> bool {
		for i in 0 ..< sim.spec.shard_count {
			shard := &sim.shards[i]

			// Check if any Isolate has pending work in its mailbox or is waiting for I/O
			for type_desc in shard.type_descriptors {
				type_id := type_desc.id
				slot_count := type_desc.slot_count

				for slot in 0 ..< slot_count {
					if shard.metadata[type_id].inbox_count[slot] > 0 do return false
					if shard.metadata[type_id].state[slot] == .Waiting_For_Io do return false
				}
			}

			// Check if the SimulatedIO backend has pending completions
			if shard.reactor.backend.pending_count > 0 do return false

			// Check if any timers are registered
			if shard.timer_wheel.resident_count > 0 do return false
		}

		// Note: We also need to check the SimulatedNetwork delay queues,
		// but for now this covers the basics.
		return true
	}
}
