package tina

import "core:fmt"

when TINA_SIMULATION_MODE {
	// Structural checkers are kept separate from the harness loop so later work
	// can add checker flags, user-defined checkers, and final summary reporting
	// without reopening bootstrap or scheduling logic.

	// Returns true if any checker detected a violation.
	simulator_run_checkers :: proc(sim: ^Simulator, round: u64) -> bool {
		flags := sim.spec.simulation.builtin_checkers

		for i in 0 ..< sim.spec.shard_count {
			shard := &sim.shards[i]

			// Pool integrity checks (reactor buffer pool, message pool, transfer pool)
			if .Pool_Integrity in flags {
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

				t_pool := &shard.transfer_pool
				if t_pool.free_count > t_pool.slot_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: transfer pool corruption — free_count (%d) > slot_count (%d)",
						i,
						t_pool.free_count,
						t_pool.slot_count,
					)
					return true
				}
			}

			// Generation monotonicity: generations must never be zero
			// (zero is reserved for HANDLE_NONE / stale sentinel)
			if .Generation_Monotonic in flags {
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
		}

		// Run user-defined checkers
		for checker_fn in sim.spec.simulation.user_checkers {
			result := checker_fn(sim.shards, round)
			if v, ok := result.(Check_Violation); ok {
				fmt.eprintfln("[CHECKER] User checker violation at round %d: %s", round, v.message)
				return true
			}
		}

		return false
	}
}
