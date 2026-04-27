package tina
import "core:mem"

when TINA_SIMULATION_MODE {
	// --- Delay Queue (Bounded FIFO) ---

	DelayedEnvelope :: struct {
		envelope:   Message_Envelope,
		deliver_at: u64,
	}

	DelayQueue :: struct {
		buffer:   []DelayedEnvelope,
		head:     u32,
		tail:     u32,
		count:    u32,
		capacity: u32,
	}

	delay_queue_init :: proc(q: ^DelayQueue, capacity: u32, allocator: mem.Allocator) {
		assert(
			(capacity != 0) && ((capacity & (capacity - 1)) == 0),
			"DelayQueue capacity must be a power of 2",
		)
		q.buffer = make([]DelayedEnvelope, capacity, allocator)
		q.capacity = capacity
		q.head = 0
		q.tail = 0
		q.count = 0
	}

	delay_queue_push :: #force_inline proc "contextless" (
		q: ^DelayQueue,
		item: DelayedEnvelope,
	) -> Enqueue_Result {
		if q.count >= q.capacity do return .Full
		q.buffer[q.tail] = item
		q.tail = (q.tail + 1) & (q.capacity - 1)
		q.count += 1
		return .Success
	}

	delay_queue_pop :: #force_inline proc "contextless" (
		q: ^DelayQueue,
	) -> (
		DelayedEnvelope,
		bool,
	) {
		if q.count == 0 do return DelayedEnvelope{}, false
		item := q.buffer[q.head]
		q.head = (q.head + 1) & (q.capacity - 1)
		q.count -= 1
		return item, true
	}

	delay_queue_peek :: #force_inline proc "contextless" (
		q: ^DelayQueue,
	) -> (
		^DelayedEnvelope,
		bool,
	) {
		if q.count == 0 do return nil, false
		return &q.buffer[q.head], true
	}

	// --- Simulated Network ---

	Channel :: struct {
		delay_queue: DelayQueue,
		delay_ticks: u32,
	}

	SimulatedNetwork :: struct {
		channels:         [][]Channel,
		partition_matrix: []Shard_Mask,
		drop_prng:        ^Prng,
		shard_count:      u8,
	}

	sim_network_init :: proc(
		net: ^SimulatedNetwork,
		shard_count: u8,
		ring_sizes: [][]u32,
		drop_prng: ^Prng,
		allocator: mem.Allocator,
	) {
		net.shard_count = shard_count
		net.drop_prng = drop_prng

		net.channels = make([][]Channel, shard_count, allocator)
		net.partition_matrix = make([]Shard_Mask, shard_count, allocator)

		for i in 0 ..< shard_count {
			net.channels[i] = make([]Channel, shard_count, allocator)
			for j in 0 ..< shard_count {
				if i != j {
					delay_queue_init(&net.channels[i][j].delay_queue, ring_sizes[i][j], allocator)
				}
			}
		}
	}

	// Enqueue: Called by Source Shard
	// must remain contextless (no assert/fmt/make/default-allocator calls).
	sim_network_enqueue :: #force_inline proc "contextless" (
		net: ^SimulatedNetwork,
		source_shard: ^Shard,
		target: Shard_Id,
		envelope: Message_Envelope,
		current_tick: u64,
		fault_config: ^FaultConfig,
	) -> Send_Result {
		source := source_shard.id

		// 1. Partition Check
		if shard_mask_contains(&net.partition_matrix[source], target) {
			source_shard.counters.quarantine_drops += 1
			return .stale_handle
		}

		// 2. Probabilistic Drop Check
		if ratio_chance(fault_config.network_drop_rate, net.drop_prng) {
			source_shard.counters.ring_full_drops += 1 // Logically identical to physical drop
			return .mailbox_full
		}

		// 3. Capacity Check (Simulates SPSC ring full)
		channel := &net.channels[source][target]
		delayed_env := DelayedEnvelope {
			envelope   = envelope,
			deliver_at = current_tick + u64(channel.delay_ticks),
		}

		if delay_queue_push(&channel.delay_queue, delayed_env) == .Full {
			source_shard.counters.ring_full_drops += 1
			return .mailbox_full
		}
		return .ok
	}

	// Drain: Called by Destination Shard (Step 1 drain)
	// must remain contextless (no assert/fmt/make/default-allocator calls).
	sim_network_drain :: #force_inline proc "contextless" (
		net: ^SimulatedNetwork,
		target_shard: ^Shard,
		source: Shard_Id,
		current_tick: u64,
	) {
		target := target_shard.id
		channel := &net.channels[source][target]

		for {
			peeked, ok := delay_queue_peek(&channel.delay_queue)
			if !ok do break

			if peeked.deliver_at > current_tick do break

			item, _ := delay_queue_pop(&channel.delay_queue)

			_process_inbound_envelope(target_shard, source, &item.envelope)
		}
	}
} else {
	SimulatedNetwork :: struct {}
}
