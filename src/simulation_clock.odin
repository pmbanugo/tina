package tina

when TINA_SIMULATION_MODE {
	// Clock-adjacent helpers live here so later work can grow this into a real
	// SimulatedClock subsystem without reopening the main harness loop.

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

		// Check if any SimulatedNetwork channel has delayed messages in flight
		net := &sim.network
		for source in 0 ..< net.shard_count {
			for target in 0 ..< net.shard_count {
				if source != target {
					if net.channels[source][target].delay_queue.count > 0 do return false
				}
			}
		}

		return true
	}
}
