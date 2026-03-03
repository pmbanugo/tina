package tina

import "core:mem"

MAX_SHARDS :: 256

Simulation_Environment :: struct {
    config:       ^SimulationConfig,
    prng_tree:    Prng_Tree,
    network:      SimulatedNetwork,
    fault_engine: FaultEngine,
    shards:		  []Shard, // Backing array of all shards
    shard_count:  u16,
}

// Fast, zero-allocation Fisher-Yates shuffle using the integer-math PRNG
@(private="package")
_shuffle_shard_order :: proc(order: ^[MAX_SHARDS]u16, shard_count: u16, prng: ^Prng) {
    // Initialize sequential order: 0, 1, 2...
    for i in 0..<shard_count {
        order[i] = i
    }

    // Shuffle
    for i in 0..<shard_count - 1 {
        // range = number of remaining choices
        range := u32(shard_count - i)
        // j is a random index from i to shard_count - 1
        j := i + u16(prng_uint_less_than(prng, range))

        // Swap
        order[i], order[j] = order[j], order[i]
    }
}

// The Global Simulation Loop
sim_run :: proc(env: ^Simulation_Environment) {
    shard_order: [MAX_SHARDS]u16

    for round: u64 = 0; round < env.config.max_ticks; round += 1 {

        // 2. Fault engine: per-round decisions (partitions, heals, jitters)
        fault_engine_tick(&env.fault_engine, round)

        // 3. Determine Shard execution order for this round
        if env.config.shuffle_shard_order {
            _shuffle_shard_order(&shard_order, env.shard_count, &env.prng_tree.scheduling)
        } else {
            for i in 0..<env.shard_count do shard_order[i] = i
        }

        // 4. Tick each Shard exactly once
        made_progress := false
        has_pending_work := false

        for i in 0..<env.shard_count {
            shard_id := shard_order[i]
            shard_ptr := &env.shards[shard_id]

            // Track state for quiescence check
            if shard_ptr.outbound_count > 0 do has_pending_work = true

            // Execute the shard's scheduler loop
            scheduler_tick(shard_ptr)

            // If mailboxes were drained or timers advanced, we made progress
            // (A fully robust liveness checker would inspect inbox counts deeply,
            // but this simple heuristic helps early termination)
        }

        // 5. Quiescence check (optional early exit)
        // If terminate_on_quiescent is true, and no shard has pending cross-shard work,
        // we could theoretically fast-forward the clock to the next timer.
        // For Phase 2, we will just let it run its max_ticks or let the test runner stop it.
    }
}
