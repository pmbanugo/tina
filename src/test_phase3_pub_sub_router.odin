package tina

import "core:mem"
import "core:testing"
import "core:fmt"

// --- Tags & Messages ---

TAG_I_AM_ALIVE : Message_Tag : USER_MESSAGE_TAG_BASE + 1
TAG_DO_WORK    : Message_Tag : USER_MESSAGE_TAG_BASE + 2

// --- 1. Observer Isolate ---
// Tracks how many times the Worker has successfully booted and reported for duty.

Observer_Isolate :: struct {
    alive_count: int,
}

observer_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    state := cast(^Observer_Isolate)self
    state.alive_count = 0
    return Effect_Receive{}
}

observer_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    state := cast(^Observer_Isolate)self

    if message.tag == TAG_I_AM_ALIVE {
        state.alive_count += 1

        // Once the worker has successfully restarted and checked in 20 times, we are done!
        if state.alive_count >= 20 {
            return Effect_Done{}
        }

        // Command the worker to do its volatile work
        ctx_send(ctx, message.body.user.source, TAG_DO_WORK, nil)
    }

    return Effect_Receive{}
}

// --- 2. Volatile Worker Isolate ---
// Purposely unstable. Triggers Tier 1 and Tier 2 faults to test the Immune System.

Worker_Isolate :: struct {}

worker_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    // The Observer is spawned as the very first static child, so its handle is deterministic:
    // Shard 0, Type 0, Slot 0, Generation 1
    observer_handle := make_handle(0, 0, 0, 1)

    // Check in with the observer
    ctx_send(ctx, observer_handle, TAG_I_AM_ALIVE, nil)

    return Effect_Receive{}
}

worker_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    if message.tag == TAG_DO_WORK {
        // Toggle between Voluntary Crashes (Tier 1) and Hard Panics (Tier 2)
        if ctx.shard.clock.current_tick % 2 == 0 {
            // TIER 2 FAULT: This instantly unwinds the stack via siglongjmp!
            trigger_tier2_panic(ctx.shard)
        } else {
            // TIER 1 FAULT: Clean voluntary crash
            return Effect_Crash{ reason = .Unimplemented_Effect }
        }
    }
    return Effect_Receive{}
}


// --- The DST Harness ---

@(test)
test_phase3_immune_system :: proc(t: ^testing.T) {
    allocator := context.allocator

    types := [2]TypeDescriptor{
        {id = 0, slot_count = 10, stride = size_of(Observer_Isolate), init_fn = observer_init, handler_fn = observer_handler},
        {id = 1, slot_count = 10, stride = size_of(Worker_Isolate),   init_fn = worker_init,   handler_fn = worker_handler},
    }

    // Run 100 seeds to prove the Trap Boundary is perfectly stable
    for seed in 0..<100 {
        sim_config := SimulationConfig {
            seed = u64(seed),
            max_ticks = 1000,
            shuffle_shard_order = true,
            faults = FaultConfig {}, // Network faults disabled to isolate supervisor testing
        }

        sim_environment := Simulation_Environment {
            config = &sim_config,
            shard_count = 1,
        }

        prng_tree_init(&sim_environment.prng_tree, sim_config.seed, int(sim_environment.shard_count), allocator)

        // Dummy network just to satisfy Shard dependencies
        ring_sizes := compute_ring_sizes(sim_environment.shard_count, 128, nil, allocator)
        sim_network_init(&sim_environment.network, sim_environment.shard_count, ring_sizes, &sim_environment.prng_tree.network_drop, allocator)

        sim_environment.fault_engine = FaultEngine {
            partition_prng = &sim_environment.prng_tree.partition,
            fault_config   = &sim_config.faults,
            network        = &sim_environment.network,
            shard_count    = sim_environment.shard_count,
        }

        // --- 1. Define the Static Boot Spec ---

        children :=[?]Child_Spec{
            Static_Child_Spec{ type_id = 0, restart_type = .temporary, args_size = 0 }, // Observer
            Static_Child_Spec{ type_id = 1, restart_type = .permanent, args_size = 0 }, // Worker
        }

        root_group := Group_Spec{
            strategy = .One_For_One,
            restart_count_max = 500, // Massive allowance so we don't trigger Level 2 Escalation
            window_duration_ticks = 100000,
            children = children[:],
            dynamic_child_count_max = 0,
        }

        // --- 2. Boot the Shard ---

        sim_environment.shards = make([]Shard, sim_environment.shard_count, allocator)
        shard_ptr := &sim_environment.shards[0]
        shard_ptr.id = 0

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
                shard_ptr.metadata[idx][s].generation = 1
                shard_ptr.metadata[idx][s].inbox_head = POOL_NONE_INDEX
                shard_ptr.metadata[idx][s].inbox_tail = POOL_NONE_INDEX
            }
            shard_ptr.isolate_memory[idx] = make([]u8, type_desc.slot_count * type_desc.stride, allocator)
        }

        shard_ptr.sim_network = &sim_environment.network
        shard_ptr.fault_config = &sim_config.faults

        // Initialize Supervision Array and Boot the Tree!
        shard_ptr.supervision_groups = make([]Supervision_Group, 16, allocator)
        shard_build_supervision_tree(shard_ptr, &root_group, allocator)

        // --- 3. Run Simulation ---
        sim_run(&sim_environment)

        // --- 4. Verification ---

        // The Observer should have completed its task (state = Unallocated due to .temporary)
        observer_meta := sim_environment.shards[0].metadata[0]
        testing.expect_value(t, observer_meta[0].state, Isolate_State.Unallocated)

        // The Worker crashed 19 times. Because teardown Step 5 (freeing the slot)
        // happens AFTER Step 4 (supervision restart), the inline restart will grab the
        // *next* available slot. This means the Worker oscillates between slot 0 and slot 1.
        // We sum the generation bumps across all slots to get the total restart count!
        worker_meta := sim_environment.shards[0].metadata[1]
        total_bumps := 0
        for s in 0..<10 {
            total_bumps += int(worker_meta[s].generation) - 1
        }
        testing.expect(t, total_bumps >= 19, "Worker should have been restarted 19+ times")

        // THE ULTIMATE PROOF: Did we leak memory during those 20 panics?
        stats := pool_stats(&sim_environment.shards[0].message_pool)
        if stats.used != 0 {
            fmt.eprintf("Leak detected on seed %v: %v slots used\n", seed, stats.used)
        }
        testing.expect_value(t, stats.used, 0)

        // --- Cleanup Memory ---
        for i in 0..<int(sim_environment.shard_count) {
            delete(sim_environment.shards[i].message_pool.buffer)
            delete(sim_environment.shards[i].timer_wheel.entries)

            // Clean up the dynamically allocated arrays inside the built supervision groups
            for g in 0..<16 {
                if sim_environment.shards[i].supervision_groups[g].children_handles != nil {
                    delete(sim_environment.shards[i].supervision_groups[g].children_handles)
                }
            }
            delete(sim_environment.shards[i].supervision_groups)

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
