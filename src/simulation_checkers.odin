package tina

import "base:sanitizer"
import "core:fmt"

_ :: sanitizer

when TINA_SIMULATION_MODE {

	// Helper for during-run payload inspection by user checkers.
	// It verifies the slot is live before reading its payload so that user
	// checkers do not trigger ASan reports on free slots.
	sim_checker_get_live_isolate_ptr :: proc(
		shard: ^Shard,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
	) -> rawptr {
		if int(type_id) >= len(shard.metadata) {
			return nil
		}
		soa_meta := shard.metadata[type_id]
		if int(slot_index) >= len(soa_meta) {
			return nil
		}
		if soa_meta[slot_index]._state == .Unallocated {
			return nil
		}
		return _get_isolate_ptr(shard, type_id, slot_index, _state_check = false)
	}

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
				pool := &shard.reactor.receive_pool
				if pool.free_count > pool.slot_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: reactor buffer pool corruption — free_count (%d) > slot_count (%d)",
						i,
						pool.free_count,
						pool.slot_count,
					)
					return true
				}

				stage_pool := &shard.reactor.staging_pool
				if stage_pool.free_count > stage_pool.slot_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: staging pool corruption — free_count (%d) > slot_count (%d)",
						i,
						stage_pool.free_count,
						stage_pool.slot_count,
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

				free_by_state: u16 = 0
				for slot in 0 ..< int(fd_table.slot_count) {
					entry := &fd_table.entries[slot]

					switch entry.state {
					case .Free:
						free_by_state += 1
						when TINA_ASAN_POISONING {
							if sanitizer.address_region_is_poisoned_rawptr(
								rawptr(&entry.payload),
								size_of(entry.payload),
							) == nil {
								fmt.eprintfln(
									"[CHECKER] Shard %d: free FD entry lifetime is addressable at slot %d",
									i, slot,
								)
								return true
							}
						} else {
							if entry.reader_isolate != ISOLATE_HANDLE_NONE {
								fmt.eprintfln(
									"[CHECKER] Shard %d: free FD entry has reader_isolate at slot %d",
									i, slot,
								)
								return true
							}
							if entry.writer_isolate != ISOLATE_HANDLE_NONE {
								fmt.eprintfln(
									"[CHECKER] Shard %d: free FD entry has writer_isolate at slot %d",
									i, slot,
								)
								return true
							}
						}
					case .Open, .Close_After_Current_IO, .Close_Queued, .Close_In_Flight:
						if entry.generation == 0 {
							fmt.eprintfln(
								"[CHECKER] Shard %d: fd table non-free entry has generation zero at slot %d (state=%v)",
								i, slot, entry.state,
							)
							return true
						}
						if entry.os_fd == OS_FD_INVALID {
							fmt.eprintfln(
								"[CHECKER] Shard %d: fd table non-free entry has invalid os fd at slot %d (state=%v)",
								i, slot, entry.state,
							)
							return true
						}
						if entry.reader_isolate == ISOLATE_HANDLE_NONE &&
						   entry.writer_isolate == ISOLATE_HANDLE_NONE {
							fmt.eprintfln(
								"[CHECKER] Shard %d: non-free fd entry has no owners at slot %d (state=%v)",
								i, slot, entry.state,
							)
							return true
						}
					}
				}

				if free_by_state != fd_table.free_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: fd table free_count mismatch (free_count=%d free_by_state=%d)",
						i, fd_table.free_count, free_by_state,
					)
					return true
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
						if entry.generation == 0 ||
						   entry.target_handle == ISOLATE_HANDLE_NONE ||
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
				descriptor_refs := make([]u16, MAX_SIMULATED_OBJECTS, context.temp_allocator)
				pending_refs := make([]u16, MAX_SIMULATED_OBJECTS, context.temp_allocator)

				for descriptor_index in 0 ..< MAX_SIMULATED_DESCRIPTORS {
					descriptor := &sim.sim_io_world.descriptors[descriptor_index]
					if descriptor.state == .Free {
						if descriptor.fd_number != OS_FD_INVALID {
							fmt.eprintfln(
								"[CHECKER] free simulated descriptor has a live fd number at index %d",
								descriptor_index,
							)
							return true
						}
						if descriptor.object_index != SIM_OBJECT_NONE_INDEX {
							fmt.eprintfln(
								"[CHECKER] free simulated descriptor references an object at index %d",
								descriptor_index,
							)
							return true
						}
						continue
					}
					if descriptor.fd_number == OS_FD_INVALID ||
					   descriptor.object_index >= MAX_SIMULATED_OBJECTS {
						fmt.eprintfln(
							"[CHECKER] Shard %d: invalid simulated descriptor state at index %d",
							i,
							descriptor_index,
						)
						return true
					}
					object := &sim.sim_io_world.objects[descriptor.object_index]
					if object.state == .Free {
						fmt.eprintfln(
							"[CHECKER] simulated descriptor points to dead object at index %d",
							descriptor.object_index,
						)
						return true
					}
					descriptor_refs[descriptor.object_index] += 1
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
						object := &sim.sim_io_world.objects[op.object_index]
						if object.state == .Free {
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
					object := &sim.sim_io_world.objects[object_index]
					if object.state == .Free {
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
			if .State_Transition_Integrity in flags {
				expected_io_awaiting: u64 = 0

				for type_desc in shard.type_descriptors {
					type_id := type_desc.id
					soa_meta := shard.metadata[type_id]
					expected_dispatchable_slot_count: u32 = 0

					for slot in 0 ..< type_desc.slot_count {
						state := soa_meta[slot]._state
						if state == .Wait_Io || state == .Pending_IO_Reuse {
							expected_io_awaiting += 1
						}

						expected_dispatchable := _slot_should_be_dispatchable(
							shard,
							type_id,
							Isolate_Slot_Index(slot),
						)
						actual_dispatchable := _bitset_is_set(
							shard.dispatchable_slot_words[type_id],
							u32(slot),
						)
						if expected_dispatchable != actual_dispatchable {
							fmt.eprintfln(
								"[CHECKER] Shard %d: dispatchable bitmap mismatch at type=%d slot=%d (expected=%v actual=%v, round %d)",
								i,
								type_id,
								slot,
								expected_dispatchable,
								actual_dispatchable,
								round,
							)
							return true
						}

						if expected_dispatchable {
							expected_dispatchable_slot_count += 1
						}
					}

					if expected_dispatchable_slot_count !=
					   shard.dispatchable_slot_counts[type_id] {
						fmt.eprintfln(
							"[CHECKER] Shard %d: dispatchable_slot_counts mismatch for type=%d (expected=%d actual=%d, round %d)",
							i,
							type_id,
							expected_dispatchable_slot_count,
							shard.dispatchable_slot_counts[type_id],
							round,
						)
						return true
					}
				}

				if expected_io_awaiting != shard.counters.io_awaiting_count {
					fmt.eprintfln(
						"[CHECKER] Shard %d: io_awaiting_count mismatch (expected=%d actual=%d, round %d)",
						i,
						expected_io_awaiting,
						shard.counters.io_awaiting_count,
						round,
					)
					return true
				}

				// Completion accounting invariant (§2.2): every accepted
				// operation increments io_in_flight_count exactly once, and
				// every reactor-visible completion decrements it exactly once.
				// The simulated backend's obligation ledger (pending +
				// completed) must match the reactor's in-flight count.
				backend := &shard.reactor.backend
				expected_in_flight := u32(backend.pending_count) + u32(backend.completed_count)
				if shard.reactor.io_in_flight_count != expected_in_flight {
					fmt.eprintfln(
						"[CHECKER] Shard %d: io_in_flight_count ledger mismatch (in_flight=%d pending=%d completed=%d, round %d)",
						i,
						shard.reactor.io_in_flight_count,
						backend.pending_count,
						backend.completed_count,
						round,
					)
					return true
				}

				// Recompute type summary words from the now-validated per-type counts.
				for type_desc in shard.type_descriptors {
					type_id := type_desc.id
					has_dispatchable := shard.dispatchable_slot_counts[type_id] > 0
					has_ready := has_dispatchable && shard.dispatch_credit_counts[type_id] > 0

					actual_type_bit := _bitset_is_set(shard.dispatchable_type_words, u32(type_id))
					if has_dispatchable != actual_type_bit {
						fmt.eprintfln(
							"[CHECKER] Shard %d: dispatchable_type_words mismatch for type=%d (expected=%v actual=%v, round %d)",
							i,
							type_id,
							has_dispatchable,
							actual_type_bit,
							round,
						)
						return true
					}

					actual_ready_bit := _bitset_is_set(
						shard.dispatch_ready_type_words,
						u32(type_id),
					)
					if has_ready != actual_ready_bit {
						fmt.eprintfln(
							"[CHECKER] Shard %d: dispatch_ready_type_words mismatch for type=%d (expected=%v actual=%v, round %d)",
							i,
							type_id,
							has_ready,
							actual_ready_bit,
							round,
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
