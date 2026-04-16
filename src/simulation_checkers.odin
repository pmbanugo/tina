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

			if .FD_Table_Integrity in flags {
				fd_table := &shard.reactor.fd_table
				if fd_table.free_count > fd_table.slot_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: fd table corruption — free_count (%d) > slot_count (%d)",
						i,
						fd_table.free_count,
						fd_table.slot_count,
					)
					return true
				}

				for slot in 0 ..< int(fd_table.slot_count) {
					entry := &fd_table.entries[slot]
					active := entry.read_owner != HANDLE_NONE || entry.write_owner != HANDLE_NONE
					if active {
						if entry.generation == 0 {
							fmt.eprintfln(
								"[CHECKER] Shard %d: fd table active entry has generation zero at slot %d",
								i,
								slot,
							)
							return true
						}
						if entry.os_fd == OS_FD_INVALID {
							fmt.eprintfln(
								"[CHECKER] Shard %d: fd table active entry has invalid os fd at slot %d",
								i,
								slot,
							)
							return true
						}
					}
				}
			}

			if .FD_Handoff_Integrity in flags {
				table := &shard.handoff_table
				if table.free_count > table.entry_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: fd handoff table corruption — free_count (%d) > entry_count (%d)",
						i,
						table.free_count,
						table.entry_count,
					)
					return true
				}

				in_flight_count: u16 = 0
				for handoff_index in 0 ..< int(table.entry_count) {
					entry := &table.entries[handoff_index]
					if entry.state == .In_Flight {
						in_flight_count += 1
						if entry.generation == 0 || entry.target_handle == HANDLE_NONE ||
						   entry.cleanup_fd == OS_FD_INVALID ||
						   entry.deadline_tick == 0 {
							fmt.eprintfln(
								"[CHECKER] Shard %d: invalid in-flight fd handoff entry at index %d",
								i,
								handoff_index,
							)
							return true
						}
					}
				}

				if in_flight_count + table.free_count != table.entry_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: fd handoff table accounting mismatch — free=%d inflight=%d entry_count=%d",
						i,
						table.free_count,
						in_flight_count,
						table.entry_count,
					)
					return true
				}
			}

			if .Sim_FD_Integrity in flags && i == 0 {
				descriptor_refs: [MAX_SIMULATED_OBJECTS]u16
				pending_refs: [MAX_SIMULATED_OBJECTS]u16

				for descriptor_index in 0 ..< MAX_SIMULATED_DESCRIPTORS {
					desc := &g_sim_fd_state.descriptors[descriptor_index]
					if !desc.active {
						continue
					}
					if desc.fd_number == OS_FD_INVALID || desc.object_index >= MAX_SIMULATED_OBJECTS {
						fmt.eprintfln(
							"[CHECKER] Shard %d: invalid simulated descriptor state at index %d",
							i,
						descriptor_index,
						)
						return true
					}
					object := &g_sim_fd_state.objects[desc.object_index]
					if !object.alive {
						fmt.eprintfln(
							"[CHECKER] simulated descriptor points to dead object at index %d",
							desc.object_index,
						)
						return true
					}
					descriptor_refs[desc.object_index] += 1
				}

				for shard_index in 0 ..< sim.spec.shard_count {
					backend := &sim.shards[shard_index].reactor.backend
					for pending_index in 0 ..< int(backend.pending_count) {
						op := &backend.pending[pending_index]
						if op.object_index >= MAX_SIMULATED_OBJECTS {
							fmt.eprintfln(
								"[CHECKER] pending simulated op has invalid object index at shard %d pending slot %d",
								shard_index,
								pending_index,
							)
							return true
						}
						object := &g_sim_fd_state.objects[op.object_index]
						if !object.alive {
							fmt.eprintfln(
								"[CHECKER] pending simulated op points to dead object at shard %d pending slot %d",
								shard_index,
								pending_index,
							)
							return true
						}
						pending_refs[op.object_index] += 1
					}
				}

				for object_index in 0 ..< MAX_SIMULATED_OBJECTS {
					object := &g_sim_fd_state.objects[object_index]
					if !object.alive {
						continue
					}
					if object.ref_count != descriptor_refs[object_index] ||
					   object.inflight_count != pending_refs[object_index] {
						fmt.eprintfln(
							"[CHECKER] simulated fd object accounting mismatch at object %d (ref_count=%d descriptors=%d inflight=%d pending=%d)",
							object_index,
							object.ref_count,
							descriptor_refs[object_index],
							object.inflight_count,
							pending_refs[object_index],
						)
						return true
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
