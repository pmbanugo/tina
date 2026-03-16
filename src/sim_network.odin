package tina
import "core:mem"

when TINA_SIMULATION_MODE {

	// 256-bit mask split into two 128-bit halves (Odin bit_set max is 128 bits).
	// lo covers shard IDs 0–127, hi covers 128–255 (stored as id - 128).
	Shard_Mask :: struct {
		lo: bit_set[0 ..= 127],
		hi: bit_set[0 ..= 127],
	}

	shard_mask_contains :: proc(m: Shard_Mask, id: u16) -> bool {
		if id < 128 {return int(id) in m.lo}
		return int(id - 128) in m.hi
	}

	shard_mask_include :: proc(m: ^Shard_Mask, id: u16) {
		if id < 128 {m.lo += {int(id)}} else {m.hi += {int(id - 128)}}
	}

	shard_mask_exclude :: proc(m: ^Shard_Mask, id: u16) {
		if id < 128 {m.lo -= {int(id)}} else {m.hi -= {int(id - 128)}}
	}

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

	delay_queue_push :: proc(q: ^DelayQueue, item: DelayedEnvelope) -> Enqueue_Result {
		if q.count >= q.capacity do return .Full
		q.buffer[q.tail] = item
		q.tail = (q.tail + 1) & (q.capacity - 1)
		q.count += 1
		return .Success
	}

	delay_queue_pop :: proc(q: ^DelayQueue) -> (DelayedEnvelope, bool) {
		if q.count == 0 do return DelayedEnvelope{}, false
		item := q.buffer[q.head]
		q.head = (q.head + 1) & (q.capacity - 1)
		q.count -= 1
		return item, true
	}

	delay_queue_peek :: proc(q: ^DelayQueue) -> (^DelayedEnvelope, bool) {
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
		shard_count:      u16,
	}

	sim_network_init :: proc(
		net: ^SimulatedNetwork,
		shard_count: u16,
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
	sim_network_enqueue :: proc(
		net: ^SimulatedNetwork,
		source_shard: ^Shard,
		target: u16,
		envelope: Message_Envelope,
		current_tick: u64,
		fault_config: ^FaultConfig,
	) {
		source := source_shard.id

		// 1. Partition Check
		if shard_mask_contains(net.partition_matrix[source], target) {
			source_shard.counters.quarantine_drops += 1
			return
		}

		// 2. Probabilistic Drop Check
		if ratio_chance(fault_config.network_drop_rate, net.drop_prng) {
			source_shard.counters.ring_full_drops += 1 // Logically identical to physical drop
			return
		}

		// 3. Capacity Check (Simulates SPSC ring full)
		channel := &net.channels[source][target]
		delayed_env := DelayedEnvelope {
			envelope   = envelope,
			deliver_at = current_tick + u64(channel.delay_ticks),
		}

		if delay_queue_push(&channel.delay_queue, delayed_env) == .Full {
			source_shard.counters.ring_full_drops += 1
		}
	}

	// Drain: Called by Destination Shard (Step 1 drain)
	sim_network_drain :: proc(
		net: ^SimulatedNetwork,
		target_shard: ^Shard,
		source: u16,
		current_tick: u64,
	) {
		target := target_shard.id
		channel := &net.channels[source][target]

		for {
			peeked, ok := delay_queue_peek(&channel.delay_queue)
			if !ok do break

			if peeked.deliver_at > current_tick do break

			item, _ := delay_queue_pop(&channel.delay_queue)

			res := _enqueue_user_msg(target_shard, item.envelope.destination, &item.envelope)
			if res == .mailbox_full {
				target_shard.counters.mailbox_full_drops += 1
			}
		}
	}

	// --- Fault Engine ---

	FaultEngine :: struct {
		partition_prng: ^Prng,
		fault_config:   ^FaultConfig,
		network:        ^SimulatedNetwork,
		shard_count:    u16,
	}

	fault_engine_tick :: proc(engine: ^FaultEngine, round: u64) {
		// 1. Heal existing partitions probabilistically
		heal_rate := engine.fault_config.network_partition_heal_rate
		if heal_rate.numerator > 0 {
			for source in 0 ..< engine.shard_count {
				mask := engine.network.partition_matrix[source]
				for id in mask.lo {
					if ratio_chance(heal_rate, engine.partition_prng) {
						shard_mask_exclude(&engine.network.partition_matrix[source], u16(id))
					}
				}
				for id in mask.hi {
					if ratio_chance(heal_rate, engine.partition_prng) {
						shard_mask_exclude(&engine.network.partition_matrix[source], u16(id) + 128)
					}
				}
			}
		}

		// 2. Create new partitions probabilistically
		part_rate := engine.fault_config.network_partition_rate
		if part_rate.numerator > 0 {
			if ratio_chance(part_rate, engine.partition_prng) {
				victim := u16(prng_uint_less_than(engine.partition_prng, u32(engine.shard_count)))
				for other in 0 ..< engine.shard_count {
					if other != victim {
						shard_mask_include(&engine.network.partition_matrix[victim], other)
						shard_mask_include(&engine.network.partition_matrix[other], victim)
					}
				}
			}
		}

		// 3. Update per-channel delays (jitter)
		range := engine.fault_config.network_delay_range_ticks
		if range[1] > 0 {
			diff := range[1] - range[0]
			for source in 0 ..< engine.shard_count {
				source_channels := engine.network.channels[source]
				for target in 0 ..< engine.shard_count {
					if source != target {
						source_channels[target].delay_ticks =
							range[0] + prng_uint_less_than(engine.partition_prng, diff + 1)
					}
				}
			}
		} else {
			// Fast path for 0-delay simulation
			for source in 0 ..< engine.shard_count {
				source_channels := engine.network.channels[source]
				for target in 0 ..< engine.shard_count {
					if source != target {
						source_channels[target].delay_ticks = 0
					}
				}
			}
		}
	}
} else {
	SimulatedNetwork :: struct {}
}
