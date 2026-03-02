package tina

import "core:mem"

Isolate_State :: enum u8 { Unallocated = 0, Runnable, Waiting, Waiting_For_Reply, Waiting_For_Io, Crashed }

// Metadata struct for Odin's #soa slice (usually referred to as SOA metadata in my design notes)
Isolate_Metadata :: struct {
    inbox_head: u32,
    inbox_tail: u32,
    generation: u16,
    inbox_count: u16,
    state: Isolate_State,
}

Shard :: struct {
    id: u16,
    clock: Simulated_Clock,
    log_ring: Log_Ring_Buffer,
    message_pool: Message_Pool,
    timer_wheel: Timer_Wheel,

    type_descriptors: []TypeDescriptor,
    isolate_memory: [][]u8, // Dense un-typed arenas
    metadata: []#soa[]Isolate_Metadata, // SOA slice per type!
}

// --- Scheduler Loop ---

scheduler_tick :: proc(shard: ^Shard) {
    shard.clock.current_tick += 1

    // Step 3: Budget-limited dispatch
    for type_descriptor in shard.type_descriptors {
        type_id := type_descriptor.id
        soa_meta := shard.metadata[type_id]

        // Safety Check
        assert(type_descriptor.slot_count <= 65535, "Slot count exceeds Handle index bounds!")

        for slot := u16(0); slot < u16(type_descriptor.slot_count); slot += 1 {
            state := soa_meta[slot].state
            if state == .Runnable || (state == .Waiting && soa_meta[slot].inbox_count > 0) {

                msg: Message
                msg_pointer: ^Message = nil

                if soa_meta[slot].inbox_count > 0 {
                    _dequeue(shard, u16(type_id), slot, &msg)
                    msg_pointer = &msg
                }

                ctx := TinaContext{
                    shard = shard,
                    self_handle = make_handle(shard.id, u16(type_id), slot, soa_meta[slot].generation),
                    current_message_source = msg_pointer != nil ? msg.body.user.source : HANDLE_NONE,
                }

                ptr := _get_isolate_ptr(shard, u16(type_id), slot)
                effect := type_descriptor.handler_fn(ptr, msg_pointer, &ctx)
                _interpret_effect(shard, u16(type_id), slot, effect, &ctx)
            }
        }
    }

    // Step 6: Advance Timer Wheel
    _advance_timers(shard)

    // Step 7: Log Flush
    log_flush(shard)
}

@(private="package")
_interpret_effect :: proc(shard: ^Shard, type_id: u16, slot: u16, effect: Effect, ctx: ^TinaContext) {
    soa_meta := shard.metadata[type_id]
    switch e in effect {
        case Effect_Done:
            _teardown_isolate(shard, type_id, slot)
        case Effect_Yield:
            soa_meta[slot].state = .Runnable
        case Effect_Receive:
            soa_meta[slot].state = .Waiting
        case Effect_Crash:
            ctx_log(ctx, .ERROR, LOG_TAG_ISOLATE_CRASHED, transmute([]u8)string("Voluntary crash"))
            _teardown_isolate(shard, type_id, slot)
        case Effect_Call, Effect_Reply, Effect_Io:
            ctx_log(ctx, .ERROR, LOG_TAG_ISOLATE_CRASHED, transmute([]u8)string("Unimplemented Effect"))
            _teardown_isolate(shard, type_id, slot)
    }
}

// --- Active Operations ---

ctx_send :: proc(ctx: ^TinaContext, to: Handle, tag: Message_Tag, payload: []u8) -> Send_Result {
    if len(payload) > MAX_PAYLOAD_SIZE { return .pool_exhausted }

    env: Message_Envelope
    env.source = ctx.self_handle
    env.destination = to
    env.tag = tag
    env.payload_size = u16(len(payload))
    copy(env.payload[:], payload)

    res := _enqueue(ctx.shard, to, &env)
    if res == .mailbox_full {
        ctx_log(ctx, .WARN, LOG_TAG_IO_EXHAUSTION, transmute([]u8)string("Mailbox full"))
    }
    return res
}

ctx_spawn :: proc(ctx: ^TinaContext, spec: Spawn_Spec) -> Spawn_Result {
    shard := ctx.shard
    type_id := u16(spec.type_id)
    soa_meta := shard.metadata[type_id]

    slot: u16 = 0xFFFF
    for i in 0..<len(soa_meta) {
        if soa_meta[i].state == .Unallocated {
            slot = u16(i); break
        }
    }
    if slot == 0xFFFF { return Spawn_Error.arena_full }

    soa_meta[slot].state = .Runnable
    ptr := _get_isolate_ptr(shard, type_id, slot)
    stride := shard.type_descriptors[type_id].stride
    if ptr != nil && stride > 0 {
        mem.zero(ptr, stride)
    }

    child_ctx := TinaContext{
        shard = shard,
        self_handle = make_handle(shard.id, type_id, slot, soa_meta[slot].generation),
    }

    // Move spec to local variable so we can take the slice of the array
    local_spec := spec
    effect := shard.type_descriptors[type_id].init_fn(ptr, local_spec.args_payload[:local_spec.args_size], &child_ctx)

    if _, is_crash := effect.(Effect_Crash); is_crash {
        _teardown_isolate(shard, type_id, slot)
        return Spawn_Error.init_failed
    }
    if _, is_done := effect.(Effect_Done); is_done {
        _teardown_isolate(shard, type_id, slot)
        return Spawn_Error.init_failed
    }

    _interpret_effect(shard, type_id, slot, effect, &child_ctx)
    return child_ctx.self_handle
}

// --- Internal Utilities ---

@(private="package")
_get_isolate_ptr :: proc(shard: ^Shard, type_id: u16, slot: u16) -> rawptr {
    stride := shard.type_descriptors[type_id].stride

    // Empty structs (stride == 0) don't need memory addresses.
    // Returning nil prevents index-out-of-bounds panics on length-0 slice allocations.
    if stride == 0 { return nil }

    assert(int(type_id) < len(shard.isolate_memory), "type_id out of bounds in isolate_memory")
    assert(int(slot) * stride < len(shard.isolate_memory[type_id]), "slot index out of bounds in isolate_memory")

    return rawptr(&shard.isolate_memory[type_id][int(slot) * stride])
}

@(private="package")
_teardown_isolate :: proc(shard: ^Shard, type_id: u16, slot: u16) {
    soa_meta := shard.metadata[type_id]
    curr := soa_meta[slot].inbox_head
    for curr != POOL_NONE_INDEX {
        env_ptr := rawptr(&shard.message_pool.buffer[curr * MESSAGE_ENVELOPE_SIZE])
        next := (cast(^Message_Envelope)env_ptr).next_in_mailbox
        pool_free(&shard.message_pool, env_ptr)
        curr = next
    }
    soa_meta[slot].inbox_head = POOL_NONE_INDEX
    soa_meta[slot].inbox_tail = POOL_NONE_INDEX
    soa_meta[slot].inbox_count = 0
    soa_meta[slot].generation += 1
    soa_meta[slot].state = .Unallocated
}

@(private="package")
_enqueue :: proc(shard: ^Shard, to: Handle, env: ^Message_Envelope) -> Send_Result {
    type_id := extract_type_id(to)
    slot := extract_slot(to)
    soa_meta := shard.metadata[type_id]

    if soa_meta[slot].generation != extract_generation(to) { return .stale_handle }
    if soa_meta[slot].inbox_count >= 256 { return .mailbox_full } // Hardcoded limit for demo

    ptr, err := pool_alloc(&shard.message_pool)
    if err != .None { return .pool_exhausted }

    dest_env := cast(^Message_Envelope)ptr
    dest_env^ = env^
    dest_env.next_in_mailbox = POOL_NONE_INDEX

    pool_index := u32((uintptr(ptr) - uintptr(raw_data(shard.message_pool.buffer))) / MESSAGE_ENVELOPE_SIZE)
    if soa_meta[slot].inbox_head == POOL_NONE_INDEX {
        soa_meta[slot].inbox_head = pool_index
    } else {
        tail_ptr := rawptr(&shard.message_pool.buffer[soa_meta[slot].inbox_tail * MESSAGE_ENVELOPE_SIZE])
        (cast(^Message_Envelope)tail_ptr).next_in_mailbox = pool_index
    }

    soa_meta[slot].inbox_tail = pool_index
    soa_meta[slot].inbox_count += 1

    if soa_meta[slot].state == .Waiting { soa_meta[slot].state = .Runnable }
    return .ok
}

@(private="package")
_dequeue :: proc(shard: ^Shard, type_id: u16, slot: u16, out_msg: ^Message) -> bool {
    soa_meta := shard.metadata[type_id]
    head_index := soa_meta[slot].inbox_head
    if head_index == POOL_NONE_INDEX { return false }

    env_ptr := rawptr(&shard.message_pool.buffer[head_index * MESSAGE_ENVELOPE_SIZE])
    env := cast(^Message_Envelope)env_ptr

    out_msg.tag = env.tag
    out_msg.body.user.source = env.source
    out_msg.body.user.payload_size = env.payload_size
    copy(out_msg.body.user.payload[:], env.payload[:])

    next_index := env.next_in_mailbox
    soa_meta[slot].inbox_head = next_index
    if next_index == POOL_NONE_INDEX { soa_meta[slot].inbox_tail = POOL_NONE_INDEX }
    soa_meta[slot].inbox_count -= 1

    pool_free(&shard.message_pool, env_ptr)
    return true
}
