package tina

import "core:mem"
import "core:testing"
import "core:fmt"

@(test)
test_phase2_milestone :: proc(t: ^testing.T) {
    allocator := context.allocator

    // We only need Ping and Pong for this test
    types := [3]TypeDescriptor{
        {id = 0, slot_count = 10, stride = 0, init_fn = nil, handler_fn = nil}, // Unused Coordinator
        {id = 1, slot_count = 10, stride = size_of(Ping_Isolate), init_fn = ping_init, handler_fn = ping_handler},
        {id = 2, slot_count = 10, stride = size_of(Pong_Isolate), init_fn = pong_init, handler_fn = pong_handler},
    }

    // Run 1000 seeds to prove absolute determinism and stability
    for seed in 0..<1000 {
        sim_config := SimulationConfig {
            seed = u64(seed),
            max_ticks = 20000, // Generous upper bound for network drops
            shuffle_shard_order = true,
            faults = FaultConfig {
                network_drop_rate = Ratio{numerator = 10, denominator = 100}, // 10% packet loss!
                network_delay_range_ticks = {0, 5},                           // 0 to 5 ticks jitter
            },
        }

        sim_environment := Simulation_Environment {
            config = &sim_config,
            shard_count = 2,
        }

        // Initialize PRNG Tree
        prng_tree_init(&sim_environment.prng_tree, sim_config.seed, int(sim_environment.shard_count), allocator)

        // Initialize Network
        ring_sizes := compute_ring_sizes(sim_environment.shard_count, 128, nil, allocator)
        sim_network_init(&sim_environment.network, sim_environment.shard_count, ring_sizes, &sim_environment.prng_tree.network_drop, allocator)

        // Initialize Fault Engine
        sim_environment.fault_engine = FaultEngine {
            partition_prng = &sim_environment.prng_tree.partition,
            fault_config   = &sim_config.faults,
            network        = &sim_environment.network,
            shard_count    = sim_environment.shard_count,
        }

        // Initialize Shards
        sim_environment.shards = make([]Shard, sim_environment.shard_count, allocator)
        for i in 0..<int(sim_environment.shard_count) {
            shard_ptr := &sim_environment.shards[i]
            shard_ptr.id = u16(i)

            pool_backing := make([]u8, 1024 * MESSAGE_ENVELOPE_SIZE, allocator)
            pool_init(&shard_ptr.message_pool, pool_backing, MESSAGE_ENVELOPE_SIZE)

            timer_backing := make([]Timer_Entry, 1024, allocator)
            timer_wheel_init(&shard_ptr.timer_wheel, timer_backing)

            shard_ptr.type_descriptors = types[:]
            shard_ptr.metadata = make([]#soa[]Isolate_Metadata, len(types), allocator)
            shard_ptr.isolate_memory = make([][]u8, len(types), allocator)

            for type_desc, idx in types {
                shard_ptr.metadata[idx] = make(#soa[]Isolate_Metadata, type_desc.slot_count, allocator)
                for s in 0..<type_desc.slot_count {
                    shard_ptr.metadata[idx][s].state = .Unallocated
                    shard_ptr.metadata[idx][s].generation = 1 // Start at 1 to invalidate HANDLE_NONE
                    shard_ptr.metadata[idx][s].inbox_head = POOL_NONE_INDEX
                    shard_ptr.metadata[idx][s].inbox_tail = POOL_NONE_INDEX
                }
                shard_ptr.isolate_memory[idx] = make([]u8, type_desc.slot_count * type_desc.stride, allocator)
            }

            shard_ptr.sim_network = &sim_environment.network
            shard_ptr.fault_config = &sim_config.faults
            shard_ptr.next_correlation_id = 0
            shard_ptr.outbound_count = 0
        }

        // --- Bootstrap the Topology ---

        // 1. Spawn Pong on Shard 1
        ctx1 := TinaContext{ shard = &sim_environment.shards[1], self_handle = HANDLE_NONE }
        pong_spec := Spawn_Spec{ type_id = 2, group = 0, restart_type = .temporary, args_size = 0 }
        pong_handle := ctx_spawn(&ctx1, pong_spec).(Handle)

        // 2. Spawn Ping on Shard 0 (Passing Pong's handle)
        ping_args := Ping_Init_Args{ pong_handle = pong_handle }
        ctx0 := TinaContext{ shard = &sim_environment.shards[0], self_handle = HANDLE_NONE }
        ping_spec := Spawn_Spec{
            type_id = 1,
            group = 0,
            restart_type = .temporary,
            args_size = size_of(Ping_Init_Args),
        }
        copy(ping_spec.args_payload[:], mem.byte_slice(&ping_args, size_of(Ping_Init_Args)))
        ping_handle := ctx_spawn(&ctx0, ping_spec).(Handle)

        // --- Run Simulation ---
        sim_run(&sim_environment)

        // --- Verification ---

        // Ensure Ping actually finished its 100 round trips and deallocated itself
        ping_meta := sim_environment.shards[0].metadata[1]
        ping_slot := extract_slot(ping_handle)
        testing.expect_value(t, ping_meta[ping_slot].state, Isolate_State.Unallocated)

        // The ultimate structural invariant: Zero Pool Leaks!
        for i in 0..<int(sim_environment.shard_count) {
            stats := pool_stats(&sim_environment.shards[i].message_pool)
            if stats.used != 0 {
                fmt.eprintf("Leak detected on seed %v shard %v: %v slots used\n", seed, i, stats.used)
            }
            testing.expect_value(t, stats.used, 0)
        }

        // --- Cleanup Memory ---
        for i in 0..<int(sim_environment.shard_count) {
            delete(sim_environment.shards[i].message_pool.buffer)
            delete(sim_environment.shards[i].timer_wheel.entries)
            for j in 0..<len(types) {
                delete(sim_environment.shards[i].metadata[j])
                delete(sim_environment.shards[i].isolate_memory[j])
            }
            delete(sim_environment.shards[i].metadata)
            delete(sim_environment.shards[i].isolate_memory)
        }
        delete(sim_environment.shards)
        for i in 0..<int(sim_environment.shard_count) {
            for j in 0..<int(sim_environment.shard_count) {
                if i != j { delete(sim_environment.network.channels[i][j].delay_queue.buffer) }
            }
            delete(sim_environment.network.channels[i])
            delete(sim_environment.network.partition_matrix[i])
            delete(ring_sizes[i])
        }
        delete(sim_environment.network.channels)
        delete(sim_environment.network.partition_matrix)
        delete(ring_sizes)
        delete(sim_environment.prng_tree.shard_io)
        delete(sim_environment.prng_tree.shard_crash)
    }
}
