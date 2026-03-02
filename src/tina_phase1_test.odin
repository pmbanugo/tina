package tina

import "core:mem"
import "core:testing"

COORD_TYPE_ID : u8 : 0
PING_TYPE_ID  : u8 : 1
PONG_TYPE_ID  : u8 : 2

PingMsg :: struct { seq: u32 }
PongMsg :: struct { seq: u32 }
PingInitArgs :: struct { pong_handle: Handle }

Coordinator :: struct {}
PingIsolate :: struct { count: u32, pong_handle: Handle }
PongIsolate :: struct {}

coord_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    pong_spec := Spawn_Spec{ type_id = PONG_TYPE_ID, restart_type = .temporary }
    pong_res := ctx_spawn(ctx, pong_spec)

    ping_args := PingInitArgs{ pong_handle = pong_res.(Handle) }
    ping_spec := Spawn_Spec{
        type_id = PING_TYPE_ID,
        restart_type = .temporary,
        args_size = size_of(PingInitArgs),
    }
    copy(ping_spec.args_payload[:], mem.byte_slice(cast(^u8)&ping_args, size_of(PingInitArgs)))

    ctx_spawn(ctx, ping_spec)
    return Effect_Receive{}
}
coord_handler :: proc(self: rawptr, msg: ^Message, ctx: ^TinaContext) -> Effect { return Effect_Receive{} }

ping_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    p := cast(^PingIsolate)self
    init_args := cast(^PingInitArgs)raw_data(args)
    p.pong_handle = init_args.pong_handle
    p.count = 0

    first_ping := PingMsg{ seq = 0 }
    ctx_send(ctx, p.pong_handle, USER_MESSAGE_TAG_BASE, mem.byte_slice(cast(^u8)&first_ping, size_of(PingMsg)))
    return Effect_Receive{}
}
ping_handler :: proc(self: rawptr, msg: ^Message, ctx: ^TinaContext) -> Effect {
    p := cast(^PingIsolate)self
    pong := cast(^PongMsg)&msg.body.user.payload
    p.count += 1

    if p.count >= 1_000_000 {
        ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)string("1M ping-pong complete"))
        return Effect_Done{} // Cascade teardown via test
    }

    next_ping := PingMsg{ seq = pong.seq + 1 }
    ctx_send(ctx, p.pong_handle, USER_MESSAGE_TAG_BASE, mem.byte_slice(cast(^u8)&next_ping, size_of(PingMsg)))
    return Effect_Receive{}
}

pong_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect { return Effect_Receive{} }
pong_handler :: proc(self: rawptr, msg: ^Message, ctx: ^TinaContext) -> Effect {
    ping := cast(^PingMsg)&msg.body.user.payload
    next_pong := PongMsg{ seq = ping.seq }
    ctx_send(ctx, msg.body.user.source, Message_Tag(USER_MESSAGE_TAG_BASE + 1), mem.byte_slice(cast(^u8)&next_pong, size_of(PongMsg)))
    return Effect_Receive{}
}

@(test)
test_phase1_milestone :: proc(t: ^testing.T) {
    shard: Shard
    shard.id = 0

    // Allocate pool
    msg_backing:[MESSAGE_ENVELOPE_SIZE * 100]u8
    pool_init(&shard.message_pool, msg_backing[:], MESSAGE_ENVELOPE_SIZE)

    // Allocate logging
    log_backing:[65536]u8
    log_init(&shard.log_ring, log_backing[:])

    // Allocate Timers
    timer_backing: [100]Timer_Entry
    timer_wheel_init(&shard.timer_wheel, timer_backing[:])

    // Type Descriptors
    t_desc :=[]TypeDescriptor{
        { id = COORD_TYPE_ID, slot_count = 1, stride = size_of(Coordinator), init_fn = coord_init, handler_fn = coord_handler },
        { id = PING_TYPE_ID,  slot_count = 1, stride = size_of(PingIsolate), init_fn = ping_init,  handler_fn = ping_handler },
        { id = PONG_TYPE_ID,  slot_count = 1, stride = size_of(PongIsolate), init_fn = pong_init,  handler_fn = pong_handler },
    }
    shard.type_descriptors = t_desc

    // Allocating the SOA Metadata slices and Dense byte blocks manually for the test
    shard.metadata = make([]#soa[]Isolate_Metadata, 3)
    shard.isolate_memory = make([][]u8, 3)
    defer { delete(shard.metadata); delete(shard.isolate_memory) }

    for td in t_desc {
        // Odin handles the internal memory layout of the #soa slice automatically
        shard.metadata[td.id] = make(#soa[]Isolate_Metadata, td.slot_count)
        for i in 0..<td.slot_count {
            shard.metadata[td.id][i].inbox_head = POOL_NONE_INDEX
            shard.metadata[td.id][i].inbox_tail = POOL_NONE_INDEX
            shard.metadata[td.id][i].state = .Unallocated
        }
        shard.isolate_memory[td.id] = make([]u8, td.slot_count * td.stride)
    }

    // Spawn Coordinator to kick off Ping-Pong
    ctx := TinaContext{ shard = &shard, self_handle = HANDLE_NONE }
    coord_spec := Spawn_Spec{ type_id = COORD_TYPE_ID, restart_type = .permanent }
    ctx_spawn(&ctx, coord_spec)

    // Run the Simulator until quiescence (message pool empty), with a generous upper bound.
    // 1M ping-pongs = 2M ticks. We bound at 3M to prevent infinite loops if a bug exists.
    for i in 0..<3_000_000 {
        scheduler_tick(&shard)

        // If the pool is entirely free, Ping has finished and returned Effect_Done{}
        if pool_stats(&shard.message_pool).used == 0 {
            break
        }
    }

    // Verify all messages are cleared, no pool leaks
    stats := pool_stats(&shard.message_pool)
    testing.expect_value(t, stats.used, 0)
    testing.expect_value(t, stats.free, 100)

    // Clean up arrays
    for td in t_desc {
        delete(shard.metadata[td.id])
        delete(shard.isolate_memory[td.id])
    }
}
