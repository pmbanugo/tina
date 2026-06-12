package tina

import "core:math/bits"
import "core:testing"

// Transport layer abstraction: physical SPSC rings vs. simulated network.
//
// Contract:
// - scheduler and mailbox code should not need to care which transport backs it
// - simulation may inject delay/drop/partition, but must preserve per-channel FIFO
// - same-round visibility differences come from shard execution order, not from a
//   different mailbox contract

@(private = "package")
remote_route_index_from_shard_id :: #force_inline proc "contextless" (
	self_id: Shard_Id,
	peer_id: Shard_Id,
) -> int {
	route_index := int(peer_id)
	if peer_id > self_id {
		route_index -= 1
	}
	return route_index
}

@(private = "package")
shard_id_from_remote_route_index :: #force_inline proc "contextless" (
	self_id: Shard_Id,
	route_index: int,
) -> Shard_Id {
	peer_id := route_index
	if peer_id >= int(self_id) {
		peer_id += 1
	}
	return Shard_Id(peer_id)
}

@(test)
test_dense_remote_route_index_round_trips :: proc(t: ^testing.T) {
	for shard_count in 1 ..< MAX_SHARD_COUNT + 1 {
		for self in 0 ..< shard_count {
			route_count := 0
			for peer in 0 ..< shard_count {
				if peer == self do continue

				route_index := remote_route_index_from_shard_id(Shard_Id(self), Shard_Id(peer))
				testing.expect_value(t, route_index, route_count)
				testing.expect_value(
					t,
					shard_id_from_remote_route_index(Shard_Id(self), route_index),
					Shard_Id(peer),
				)
				route_count += 1
			}
			testing.expect_value(t, route_count, shard_count - 1)
		}
	}
}

@(private = "package")
transport_drain_inbound :: #force_inline proc "contextless" (shard: ^Shard, now: u64) {
	when !TINA_SIMULATION_MODE {
		for ring, route_index in shard.inbound_rings {
			source_shard := shard_id_from_remote_route_index(shard.id, route_index)
			available := spsc_ring_available_to_read(ring)
			for offset in 0 ..< available {
				envelope := spsc_ring_get_read_ptr(ring, offset)
				_process_inbound_envelope(shard, source_shard, envelope)
			}

			if available > 0 {
				spsc_ring_commit_read(ring, available)
			}
		}
	} else {
		if shard.sim_state.network != nil {
			// Drain sources in ascending shard order. This keeps delivery order
			// stable and matches the fixed ordered-drain discipline expected by
			// the simulation ADR.
			for source in 0 ..< shard.sim_state.network.shard_count {
				if Shard_Id(source) != shard.id {
					sim_network_drain(shard.sim_state.network, shard, Shard_Id(source), now)
				}
			}
		}
	}
}

@(private = "package")
transport_drain_control_inbound :: #force_inline proc(shard: ^Shard) {
	channel := shard.inbound_control_channel
	if channel == nil do return
	when TINA_RUNTIME_ASSERTIONS {
		assert(channel.source_count >= int(shard.shard_count), "Shard control channel source count must cover shard count")
	}

	for word_index in 0 ..< SHARD_CONTROL_READY_WORD_COUNT {
		ready_word := shard_control_channel_take_ready_word(channel, word_index)
		for ready_word != 0 {
			word_bit_index := u32(bits.trailing_zeros(ready_word))
			source_index := bitmap_bit_index_from_word_index_and_word_bit_index(word_index, word_bit_index)
			ready_word &= ready_word - 1

			if source_index >= u32(shard.shard_count) do continue
			source_shard := Shard_Id(source_index)
			if source_shard == shard.id do continue

			event := shard_control_channel_load_event(channel, source_shard)
			_process_inbound_control_event(shard, source_shard, &event)
		}
	}
}

@(private = "package")
transport_flush_outbound :: #force_inline proc "contextless" (shard: ^Shard) {
	when !TINA_SIMULATION_MODE {
		for ring in shard.outbound_rings {
			spsc_ring_flush_producer(ring)
		}
	}
}

@(private = "package")
transport_flush_control_outbound :: #force_inline proc "contextless" (shard: ^Shard) {
	_ = shard
	// MPSC control channels publish source cells immediately; this no-op keeps
	// recovery call sites symmetric with the batched data-plane transport.
}

@(private = "package")
transport_retry_liveness_broadcast :: #force_inline proc(shard: ^Shard) {
	if len(shard.outbound_control_channels) == 0 do return
	when TINA_RUNTIME_ASSERTIONS {
		assert(int(shard.id) < int(shard.shard_count), "Shard id must be within shard count before liveness publish")
		assert(len(shard.outbound_control_channels) == int(shard.shard_count) - 1, "Outbound control channels must cover every peer shard")
	}
	if shard.liveness_broadcast_pending_mask[0] == 0 &&
	   shard.liveness_broadcast_pending_mask[1] == 0 &&
	   shard.liveness_broadcast_pending_mask[2] == 0 &&
	   shard.liveness_broadcast_pending_mask[3] == 0 {
		return
	}

	event := Shard_Control_Event {
		epoch  = shard.liveness_broadcast_epoch,
		source = shard.id,
		state  = shard.liveness_broadcast_state,
		kind   = .Liveness,
	}

	for target_index in 0 ..< int(shard.shard_count) {
		target_shard := Shard_Id(target_index)
		if target_shard == shard.id do continue
		if !shard_mask_contains(&shard.liveness_broadcast_pending_mask, target_shard) do continue

		route_index := remote_route_index_from_shard_id(shard.id, target_shard)
		channel := shard.outbound_control_channels[route_index]
		shard_control_channel_publish(channel, shard.id, &event)
		shard.counters.liveness_control_publish_count += 1
		shard_mask_exclude(&shard.liveness_broadcast_pending_mask, target_shard)
	}
}

@(private = "package")
transport_route_envelope :: #force_inline proc "contextless" (
	source_shard: ^Shard,
	destination_shard: Shard_Id,
	msg_envelope: ^Message_Envelope,
) -> Send_Result {
	when !TINA_SIMULATION_MODE {
		if destination_shard >= Shard_Id(source_shard.shard_count) {
			source_shard.counters.stale_delivery_drops += 1
			return .stale_handle
		}
		if destination_shard == source_shard.id {
			source_shard.counters.stale_delivery_drops += 1
			return .stale_handle
		}
		if !shard_mask_contains(&source_shard.peer_alive_mask, destination_shard) {
			source_shard.counters.quarantine_drops += 1
			return .stale_handle
		}

		route_index := remote_route_index_from_shard_id(source_shard.id, destination_shard)
		ring := source_shard.outbound_rings[route_index]
		if spsc_ring_enqueue(ring, msg_envelope) == .Full {
			source_shard.counters.ring_full_drops += 1
			return .mailbox_full
		}
		return .ok
	} else {
		if !shard_mask_contains(&source_shard.peer_alive_mask, destination_shard) {
			source_shard.counters.quarantine_drops += 1
			return .stale_handle
		}
		return sim_network_enqueue(
			source_shard.sim_state.network,
			source_shard,
			destination_shard,
			msg_envelope^,
			source_shard.current_tick,
			source_shard.sim_state.fault_config,
		)
	}
}
