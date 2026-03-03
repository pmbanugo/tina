package tina

import "core:mem"

Isolate_State :: enum u8 { Unallocated = 0, Runnable, Waiting, Waiting_For_Reply, Waiting_For_Io, Crashed }

// Metadata struct for Odin's #soa slice (usually referred to as SOA metadata in my design notes)
Isolate_Metadata :: struct {
    inbox_head: u32,
    inbox_tail: u32,
    pending_correlation: u32,
    generation: u16,
    inbox_count: u16,
    state: Isolate_State,
}

Shard_Counters :: struct {
    stale_delivery_drops:  u64,
    ring_full_drops:       u64,
    quarantine_drops:      u64,
    pool_exhaustion_drops: u64,
    mailbox_full_drops:    u64,
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

    counters: Shard_Counters,

    // In production this would be an array of *SPSCRing.
    // For now, we inject the SimulatedNetwork.
    // when conditional compilation blocks are not supported inside struct definitions in Odin.
    // Therefore, I'm commenting the when blocks.
    // Second option would be to use condition (when) struct declaration,
    // but then I have to maintain both structs fields. or find a better means
    // when #config(TINA_SIM, false) {
        sim_network: ^SimulatedNetwork,
        fault_config: ^FaultConfig, // Passed down for enqueue drops
    // }

    // Staging array for outbound messages generated during Step 3.
    // We use a simple bounded array. The capacity should theoretically
    // match the sum of all outbound ring capacities, but for now a flat max works.
    outbound_staging: [1024]Message_Envelope,
    outbound_count: u32,
    next_correlation_id: u32,
}

// --- Scheduler Loop ---

scheduler_tick :: proc(shard: ^Shard) {
    shard.clock.current_tick += 1
    now := shard.clock.current_tick

    when #config(TINA_SIM, false) {
        // --- Step 1: Drain Inbound Cross-Shard Rings ---
        // We iterate over all N-1 source shards and drain their channels into our mailboxes
        if shard.sim_network != nil {
            for src in u16(0)..<shard.sim_network.shard_count {
                if src != shard.id {
                    sim_network_drain(shard.sim_network, shard, src, now)
                }
            }
        }
    }

    // Step 3: Budget-limited dispatch
    for type_descriptor in shard.type_descriptors {
        type_id := type_descriptor.id
        soa_meta := shard.metadata[type_id]

        assert(type_descriptor.slot_count <= MAX_ISOLATES_PER_TYPE, "Slot count exceeds Handle index bounds!")

        for slot := u16(0); slot < u16(type_descriptor.slot_count); slot += 1 {
            state := soa_meta[slot].state
            if state == .Runnable || (state == .Waiting && soa_meta[slot].inbox_count > 0) {

	            message: Message
	            message_pointer: ^Message = nil
	            correlation: u32 = 0
	            flags: u16 = 0

	            if soa_meta[slot].inbox_count > 0 {
	                _dequeue(shard, u16(type_id), slot, &message, &correlation, &flags)
	                message_pointer = &message
	            }

	            ctx := TinaContext{
	                shard = shard,
	                self_handle = make_handle(shard.id, u16(type_id), slot, soa_meta[slot].generation),
	                current_message_source = message_pointer != nil ? message.body.user.source : HANDLE_NONE,
	                current_correlation = correlation,
	                is_call = (flags & ENVELOPE_FLAG_IS_CALL) != 0,
	            }

                ptr := _get_isolate_ptr(shard, u16(type_id), slot)
                effect := type_descriptor.handler_fn(ptr, message_pointer, &ctx)
                _interpret_effect(shard, u16(type_id), slot, effect, &ctx)
            }
        }
    }

    when #config(TINA_SIM, false) {
        // --- Step 5: Flush Outbound Cross-Shard Rings ---
        if shard.sim_network != nil {
            for i in 0..<shard.outbound_count {
                env := shard.outbound_staging[i]
                dest_shard := extract_shard_id(env.destination)
                sim_network_enqueue(shard.sim_network, shard, dest_shard, env, now, shard.fault_config)
            }
            shard.outbound_count = 0 // Reset staging buffer
        }
    }

    // Step 6: Advance Timer Wheel
    _advance_timers(shard)

    // Step 7: Log Flush
    log_flush(shard)
}

// --- Active Operations ---

ctx_send :: proc(ctx: ^TinaContext, to: Handle, tag: Message_Tag, payload: []u8) -> Send_Result {
    if len(payload) > MAX_PAYLOAD_SIZE { return .pool_exhausted }

    envelope: Message_Envelope
    envelope.source = ctx.self_handle
    envelope.destination = to
    envelope.tag = tag
    envelope.payload_size = u16(len(payload))
    copy(envelope.payload[:], payload)

    response := _route_envelope(ctx.shard, to, &envelope)
    if response == .mailbox_full {
        ctx_log(ctx, .WARN, LOG_TAG_IO_EXHAUSTION, transmute([]u8)string("Mailbox full"))
    }
    return response
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
_route_envelope :: proc(shard: ^Shard, to: Handle, envelope: ^Message_Envelope) -> Send_Result {
    destination := extract_shard_id(to)

    if destination == shard.id {
    	// INTRA-SHARD: Direct enqueue
        return _enqueue(shard, to, envelope)
    } else {
        when #config(TINA_SIM, false) {
        	// CROSS-SHARD: Stage for outbound flush (Step 5)
            if shard.outbound_count < len(shard.outbound_staging) {
                shard.outbound_staging[shard.outbound_count] = envelope^
                shard.outbound_count += 1
                return .ok
            } else {
            	// Staging full acts exactly like ring full / mailbox full
                shard.counters.ring_full_drops += 1
                return .mailbox_full
            }
        } else {
            return .ok // Phase 4 real rings
        }
    }
}

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
    soa_meta[slot].pending_correlation = 0
    soa_meta[slot].generation += 1
    soa_meta[slot].state = .Unallocated
}

@(private="package")
_enqueue :: proc(shard: ^Shard, to: Handle, env: ^Message_Envelope) -> Send_Result {
    type_id := extract_type_id(to)
    slot := extract_slot(to)
    soa_meta := shard.metadata[type_id]

    if soa_meta[slot].generation != extract_generation(to) { return .stale_handle }

    // --- Enqueue-Time Correlation Matching ---
    is_reply := (env.flags & ENVELOPE_FLAG_IS_REPLY) != 0
    is_timeout := env.tag == TAG_CALL_TIMEOUT

    if is_reply || is_timeout {
        if soa_meta[slot].state != .Waiting_For_Reply { return .stale_handle } // Drop late reply
        if soa_meta[slot].pending_correlation != env.correlation { return .stale_handle } // Drop mismatch

        // Match! Unpark the isolate.
        // The message is still enqueued below so it is delivered at the head of the line.
        soa_meta[slot].pending_correlation = 0
        soa_meta[slot].state = .Runnable
    }

    if soa_meta[slot].inbox_count >= 256 { return .mailbox_full }

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

    // Normal wakeup
    if soa_meta[slot].state == .Waiting { soa_meta[slot].state = .Runnable }
    return .ok
}

@(private="package")
_dequeue :: proc(shard: ^Shard, type_id: u16, slot: u16, out_message: ^Message, out_correlation: ^u32, out_flags: ^u16) -> bool {
    soa_meta := shard.metadata[type_id]
    head_index := soa_meta[slot].inbox_head
    if head_index == POOL_NONE_INDEX { return false }

    env_ptr := rawptr(&shard.message_pool.buffer[head_index * MESSAGE_ENVELOPE_SIZE])
    env := cast(^Message_Envelope)env_ptr

    out_message.tag = env.tag
    out_message.body.user.source = env.source
    out_message.body.user.payload_size = env.payload_size
    copy(out_message.body.user.payload[:], env.payload[:])

    out_correlation^ = env.correlation  // Export correlation
    out_flags^ = env.flags       // Export flags

    next_index := env.next_in_mailbox
    soa_meta[slot].inbox_head = next_index
    if next_index == POOL_NONE_INDEX { soa_meta[slot].inbox_tail = POOL_NONE_INDEX }
    soa_meta[slot].inbox_count -= 1

    pool_free(&shard.message_pool, env_ptr)
    return true
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
        case Effect_Call:
            shard.next_correlation_id += 1
            if shard.next_correlation_id == 0 do shard.next_correlation_id = 1
            corr := shard.next_correlation_id

            soa_meta[slot].pending_correlation = corr
            soa_meta[slot].state = .Waiting_For_Reply

            _register_system_timer(shard, ctx.self_handle, e.timeout, TAG_CALL_TIMEOUT, corr)

            local_msg := e.message  // Make it addressable
            envelope: Message_Envelope
            envelope.source = ctx.self_handle
            envelope.destination = e.to
            envelope.correlation = corr
            envelope.flags |= ENVELOPE_FLAG_IS_CALL
            envelope.tag = local_msg.tag
            envelope.payload_size = local_msg.body.user.payload_size
            copy(envelope.payload[:], local_msg.body.user.payload[:])

            _route_envelope(shard, e.to, &envelope)

        case Effect_Reply:
            if !ctx.is_call {
                ctx_log(ctx, .ERROR, LOG_TAG_ISOLATE_CRASHED, transmute([]u8)string("Reply effect without call context"))
                _teardown_isolate(shard, type_id, slot)
                return
            }
            soa_meta[slot].state = .Waiting // Park after reply

            local_msg := e.message  // Make it addressable
            envelope: Message_Envelope
            envelope.source = ctx.self_handle
            envelope.destination = ctx.current_message_source
            envelope.correlation = ctx.current_correlation
            envelope.flags |= ENVELOPE_FLAG_IS_REPLY
            envelope.tag = local_msg.tag
            envelope.payload_size = local_msg.body.user.payload_size
            copy(envelope.payload[:], local_msg.body.user.payload[:])

            _route_envelope(shard, ctx.current_message_source, &envelope)

        case Effect_Io:
            ctx_log(ctx, .ERROR, LOG_TAG_ISOLATE_CRASHED, transmute([]u8)string("Unimplemented Effect"))
            _teardown_isolate(shard, type_id, slot)
    }
}
