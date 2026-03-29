package tina

// Transport layer abstraction: physical SPSC rings vs. simulated network.

@(private = "package")
transport_drain_inbound :: #force_inline proc "contextless" (shard: ^Shard, now: u64) {
	when !TINA_SIMULATION_MODE {
		if len(shard.inbound_rings) > 0 {
			for ring, source_shard in shard.inbound_rings {
				if ring == nil do continue

				available := spsc_ring_available_to_read(ring)
				for i in 0 ..< available {
					envelope := spsc_ring_get_read_ptr(ring, i)
					_process_inbound_envelope(shard, u8(source_shard), envelope)
				}

				if available > 0 {
					spsc_ring_commit_read(ring, available)
				}
			}
		}
	} else {
		if shard.sim_state.network != nil {
			for source in u8(0) ..< shard.sim_state.network.shard_count {
				if source != shard.id {
					sim_network_drain(shard.sim_state.network, shard, source, now)
				}
			}
		}
	}
}

@(private = "package")
transport_flush_outbound :: #force_inline proc "contextless" (shard: ^Shard) {
	when !TINA_SIMULATION_MODE {
		if len(shard.outbound_rings) > 0 {
			for ring in shard.outbound_rings {
				if ring != nil {
					spsc_ring_flush_producer(ring)
				}
			}
		}
	}
}

@(private = "package")
transport_route_envelope :: #force_inline proc "contextless" (
	shard: ^Shard,
	dest_shard: u8,
	envelope: ^Message_Envelope,
) -> Send_Result {
	when !TINA_SIMULATION_MODE {
		if !shard_mask_contains(&shard.peer_alive_mask, dest_shard) {
			shard.counters.quarantine_drops += 1
			return .stale_handle
		}

		ring := shard.outbound_rings[dest_shard]
		if ring == nil {
			shard.counters.stale_delivery_drops += 1
			return .stale_handle
		}
		if spsc_ring_enqueue(ring, envelope) == .Full {
			shard.counters.ring_full_drops += 1
			return .mailbox_full
		}
		return .ok
	} else {
		if !shard_mask_contains(&shard.peer_alive_mask, dest_shard) {
			shard.counters.quarantine_drops += 1
			return .stale_handle
		}
		return sim_network_enqueue(
			shard.sim_state.network,
			shard,
			dest_shard,
			envelope^,
			shard.current_tick,
			shard.sim_state.fault_config,
		)
	}
}

@(private = "package")
transport_broadcast_envelope :: #force_inline proc "contextless" (shard: ^Shard, env: ^Message_Envelope) {
	when TINA_SIMULATION_MODE {
		if shard.sim_state.network != nil {
			for target_shard in u8(0) ..< shard.sim_state.network.shard_count {
				if target_shard != shard.id {
					_ = sim_network_enqueue(
						shard.sim_state.network,
						shard,
						target_shard,
						env^,
						shard.current_tick,
						shard.sim_state.fault_config,
					)
				}
			}
		}
	} else {
		if len(shard.outbound_rings) > 0 {
			for outbound_ring in shard.outbound_rings {
				if outbound_ring != nil {
					spsc_ring_enqueue(outbound_ring, env)
				}
			}
		}
	}
}
