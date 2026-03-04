package tina

import "core:mem"
import "core:testing"
import "core:fmt"

// --- Tags & Messages ---

TAG_PING : Message_Tag : USER_MESSAGE_TAG_BASE + 1
TAG_PONG : Message_Tag : USER_MESSAGE_TAG_BASE + 2

Ping_Msg :: struct { seq: u32 }
Pong_Msg :: struct { seq: u32 }
Ping_Init_Args :: struct { pong_handle: Handle }

// --- 1. Pong Isolate (Callee) ---
Pong_Isolate :: struct {}

pong_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    return Effect_Receive{}
}

pong_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    if message.tag == TAG_PING {
        ping_msg := cast(^Ping_Msg)&message.body.user.payload[0]

        pong_msg := Pong_Msg{ seq = ping_msg.seq }
        reply_msg: Message
        reply_msg.tag = TAG_PONG
        reply_msg.body.user.payload_size = size_of(Pong_Msg)
        copy(reply_msg.body.user.payload[:], mem.byte_slice(&pong_msg, size_of(Pong_Msg)))

        // Immediately reply and park
        return Effect_Reply{ message = reply_msg }
    }
    return Effect_Receive{}
}

// --- 2. Ping Isolate (Caller) ---
Ping_Isolate :: struct {
    pong_handle: Handle,
    seq: u32,
    success_count: u32,
}

ping_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    init_args := cast(^Ping_Init_Args)&args[0]

    state := cast(^Ping_Isolate)self
    state.pong_handle = init_args.pong_handle
    state.seq = 0
    state.success_count = 0

    // Construct request
    ping_msg := Ping_Msg{ seq = state.seq }
    req_msg: Message
    req_msg.tag = TAG_PING
    req_msg.body.user.payload_size = size_of(Ping_Msg)
    copy(req_msg.body.user.payload[:], mem.byte_slice(&ping_msg, size_of(Ping_Msg)))

    // Call with a 10-tick timeout
    return Effect_Call{ to = state.pong_handle, message = req_msg, timeout = 10 }
}

ping_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    state := cast(^Ping_Isolate)self

    if message.tag == TAG_CALL_TIMEOUT {
        // A network drop occurred! The timeout fired. We must retry.
        ping_msg := Ping_Msg{ seq = state.seq }
        req_msg: Message
        req_msg.tag = TAG_PING
        req_msg.body.user.payload_size = size_of(Ping_Msg)
        copy(req_msg.body.user.payload[:], mem.byte_slice(&ping_msg, size_of(Ping_Msg)))

        return Effect_Call{ to = state.pong_handle, message = req_msg, timeout = 10 }

    } else if message.tag == TAG_PONG {
        pong_msg := cast(^Pong_Msg)&message.body.user.payload[0]

        // Assert ordering is preserved
        if pong_msg.seq == state.seq {
            state.success_count += 1
            state.seq += 1
        }

        if state.success_count >= 100 {
            // Reached our goal despite the chaotic network. Shut down.
            return Effect_Done{}
        }

        // Send next ping
        ping_msg := Ping_Msg{ seq = state.seq }
        req_msg: Message
        req_msg.tag = TAG_PING
        req_msg.body.user.payload_size = size_of(Ping_Msg)
        copy(req_msg.body.user.payload[:], mem.byte_slice(&ping_msg, size_of(Ping_Msg)))

        return Effect_Call{ to = state.pong_handle, message = req_msg, timeout = 10 }
    }

    return Effect_Receive{}
}

// --- The DST Harness ---

@(test)
test_phase3_ping_pong :: proc(t: ^testing.T) {
    allocator := context.allocator

    types :=[2]TypeDescriptor{
        {id = 0, slot_count = 10, stride = size_of(Ping_Isolate), init_fn = ping_init, handler_fn = ping_handler},
        {id = 1, slot_count = 10, stride = size_of(Pong_Isolate), init_fn = pong_init, handler_fn = pong_handler},
    }

    // Run 1000 seeds to prove deterministic execution over chaotic networks
    for seed in 0..<1000 {
        sim_config := SimulationConfig {
            seed = u64(seed),
            max_ticks = 20000,
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

        prng_tree_init(&sim_environment.prng_tree, sim_config.seed, int(sim_environment.shard_count), allocator)

        ring_sizes := compute_ring_sizes(sim_environment.shard_count, 128, nil, allocator)
        sim_network_init(&sim_environment.network, sim_environment.shard_count, ring_sizes, &sim_environment.prng_tree.network_drop, allocator)

        sim_environment.fault_engine = FaultEngine {
            partition_prng = &sim_environment.prng_tree.partition,
            fault_config   = &sim_config.faults,
            network        = &sim_environment.network,
            shard_count    = sim_environment.shard_count,
        }

        // --- 1. Define Boot Specs ---

        // Because Pong is the first static child on Shard 1, we know exactly what its handle will be!
        // Shard = 1, Type = 1, Slot = 0, Generation = 1
        expected_pong_handle := make_handle(1, 1, 0, 1)

        ping_args := Ping_Init_Args{ pong_handle = expected_pong_handle }
        ping_payload:[MAX_INIT_ARGS_SIZE]u8
        copy(ping_payload[:], mem.byte_slice(&ping_args, size_of(Ping_Init_Args)))

        children_shard0 := [?]Child_Spec{
            Static_Child_Spec{ type_id = 0, restart_type = .temporary, args_size = size_of(Ping_Init_Args), args_payload = ping_payload },
        }
        root_group_shard0 := Group_Spec{
            strategy = .One_For_One,
            restart_count_max = 500,
            window_duration_ticks = 100000,
            children = children_shard0[:],
            dynamic_child_count_max = 0,
        }

        children_shard1 := [?]Child_Spec{
            Static_Child_Spec{ type_id = 1, restart_type = .permanent, args_size = 0 },
        }
        root_group_shard1 := Group_Spec{
            strategy = .One_For_One,
            restart_count_max = 500,
            window_duration_ticks = 100000,
            children = children_shard1[:],
            dynamic_child_count_max = 0,
        }

        // --- 2. Boot the Shards ---

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
                    shard_ptr.metadata[idx][s].generation = 1
                    shard_ptr.metadata[idx][s].inbox_head = POOL_NONE_INDEX
                    shard_ptr.metadata[idx][s].inbox_tail = POOL_NONE_INDEX
                }
                shard_ptr.isolate_memory[idx] = make([]u8, type_desc.slot_count * type_desc.stride, allocator)
            }

            shard_ptr.sim_network = &sim_environment.network
            shard_ptr.fault_config = &sim_config.faults

            shard_ptr.supervision_groups = make([]Supervision_Group, 16, allocator)

            if i == 0 {
                shard_build_supervision_tree(shard_ptr, &root_group_shard0, allocator)
            } else {
                shard_build_supervision_tree(shard_ptr, &root_group_shard1, allocator)
            }
        }

        // --- 3. Run Simulation ---
        sim_run(&sim_environment)

        // --- 4. Verification ---

        // Ensure Ping finished 100 round trips and cleanly exited
        // Because Ping's restart type is `.temporary`, it should be completely removed!
        ping_meta := sim_environment.shards[0].metadata[0]
        testing.expect_value(t, ping_meta[0].state, Isolate_State.Unallocated)

        // Zero Pool Leaks check to guarantee clean execution
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
