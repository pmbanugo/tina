package tina

import "core:mem"

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
    assert((capacity != 0) && ((capacity & (capacity - 1)) == 0), "DelayQueue capacity must be a power of 2")
    q.buffer = make([]DelayedEnvelope, capacity, allocator)
    q.capacity = capacity
    q.head = 0
    q.tail = 0
    q.count = 0
}

delay_queue_push :: proc(q: ^DelayQueue, item: DelayedEnvelope) -> bool {
    if q.count >= q.capacity do return false
    q.buffer[q.tail] = item
    q.tail = (q.tail + 1) & (q.capacity - 1)
    q.count += 1
    return true
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
    partition_matrix: [][]bool,
    drop_prng:        ^Prng,
    shard_count:      u16,
}

sim_network_init :: proc(net: ^SimulatedNetwork, shard_count: u16, ring_sizes: [][]u32, drop_prng: ^Prng, allocator: mem.Allocator) {
    net.shard_count = shard_count
    net.drop_prng = drop_prng

    net.channels = make([][]Channel, shard_count, allocator)
    net.partition_matrix = make([][]bool, shard_count, allocator)

    for i in 0..<shard_count {
        net.channels[i] = make([]Channel, shard_count, allocator)
        net.partition_matrix[i] = make([]bool, shard_count, allocator)
        for j in 0..<shard_count {
            if i != j {
                delay_queue_init(&net.channels[i][j].delay_queue, ring_sizes[i][j], allocator)
            }
            net.partition_matrix[i][j] = false
        }
    }
}

// Enqueue: Called by Source Shard (Step 5 flush)
sim_network_enqueue :: proc(net: ^SimulatedNetwork, src_shard: ^Shard, dst: u16, envelope: Message_Envelope, current_tick: u64, fault_config: ^FaultConfig) {
    src := src_shard.id

    // 1. Partition Check
    if net.partition_matrix[src][dst] {
        src_shard.counters.quarantine_drops += 1
        return
    }

    // 2. Probabilistic Drop Check
    if ratio_chance(fault_config.network_drop_rate, net.drop_prng) {
        src_shard.counters.ring_full_drops += 1 // Logically identical to physical drop
        return
    }

    // 3. Capacity Check (Simulates SPSC ring full)
    channel := &net.channels[src][dst]
    delayed_env := DelayedEnvelope{
        envelope = envelope,
        deliver_at = current_tick + u64(channel.delay_ticks),
    }

    if !delay_queue_push(&channel.delay_queue, delayed_env) {
        src_shard.counters.ring_full_drops += 1
    }
}

// Drain: Called by Destination Shard (Step 1 drain)
// We pass in the dst_shard so we can enqueue directly into the local mailboxes
sim_network_drain :: proc(net: ^SimulatedNetwork, dst_shard: ^Shard, src: u16, current_tick: u64) {
    dst := dst_shard.id
    channel := &net.channels[src][dst]

    for {
        peeked, ok := delay_queue_peek(&channel.delay_queue)
        if !ok do break

        // FIFO preservation: if the head isn't ready, nothing behind it is ready either
        if peeked.deliver_at > current_tick do break

        item, _ := delay_queue_pop(&channel.delay_queue)

        // Enqueue into local mailbox.
        // Note: _enqueue handles allocating from the destination shard's pool,
        // effectively executing the memory ownership transfer!
        res := _enqueue(dst_shard, item.envelope.destination, &item.envelope)
        if res == .mailbox_full {
            dst_shard.counters.mailbox_full_drops += 1
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
    for src in 0..<engine.shard_count {
        for dst in 0..<engine.shard_count {
            if src == dst do continue
            if engine.network.partition_matrix[src][dst] {
                if ratio_chance(engine.fault_config.network_partition_heal_rate, engine.partition_prng) {
                    engine.network.partition_matrix[src][dst] = false
                }
            }
        }
    }

    // 2. Create new partitions probabilistically
    if ratio_chance(engine.fault_config.network_partition_rate, engine.partition_prng) {
        // Select a random victim Shard to completely partition from the rest of the network
        victim := u16(prng_uint_less_than(engine.partition_prng, u32(engine.shard_count)))
        for other in 0..<engine.shard_count {
            if other == victim do continue
            engine.network.partition_matrix[victim][other] = true
            engine.network.partition_matrix[other][victim] = true
        }
    }

    // 3. Update per-channel delays (jitter)
    for src in 0..<engine.shard_count {
        for dst in 0..<engine.shard_count {
            if src == dst do continue
            range := engine.fault_config.network_delay_range_ticks
            if range[1] > 0 {
                diff := range[1] - range[0]
                engine.network.channels[src][dst].delay_ticks = range[0] + prng_uint_less_than(engine.partition_prng, diff + 1)
            } else {
                engine.network.channels[src][dst].delay_ticks = 0
            }
        }
    }
}
