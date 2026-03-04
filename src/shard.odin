package tina

import "core:mem"
import "core:c"

// --- Trap Boundary Platform Bindings ---

when ODIN_OS == .Linux {
    sigjmp_buf :: distinct [64]c.long // 512 bytes on x64, safe margin

    foreign import libc "system:c"
    @(default_calling_convention="c")
    foreign libc {
        @(link_name="__sigsetjmp")
        _sigsetjmp :: proc(env: ^sigjmp_buf, savesigs: c.int) -> c.int ---
        siglongjmp :: proc(env: ^sigjmp_buf, val: c.int) -> ! ---
    }

    sigsetjmp :: proc(env: ^sigjmp_buf, savesigs: c.int) -> c.int {
        return _sigsetjmp(env, savesigs)
    }
} else when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
    sigjmp_buf :: distinct [256]c.long // 2048 bytes on 64-bit, covers all BSD/Darwin targets (Safe margin)

    foreign import libc "system:c"
    @(default_calling_convention="c")
    foreign libc {
        sigsetjmp :: proc(env: ^sigjmp_buf, savesigs: c.int) -> c.int ---
        siglongjmp :: proc(env: ^sigjmp_buf, val: c.int) -> ! ---
    }
} else when ODIN_OS == .Windows {
    // Windows lacks POSIX signals. Polyfill with standard setjmp for development/Simulation mode.
    sigjmp_buf :: distinct [64]c.long

    foreign import libc "system:c"
    @(default_calling_convention="c")
    foreign libc {
        @(link_name="_setjmp")
        _setjmp :: proc(env: ^sigjmp_buf) -> c.int ---
        longjmp :: proc(env: ^sigjmp_buf, val: c.int) -> ! ---
    }

    sigsetjmp :: proc(env: ^sigjmp_buf, savesigs: c.int) -> c.int {
        return _setjmp(env)
    }
    siglongjmp :: proc(env: ^sigjmp_buf, val: c.int) -> ! {
        longjmp(env, val)
    }
} else {
    #panic("Unsupported OS for Trap Boundary bindings")
}

// Expose a way to manually trigger a Tier 2 panic for simulation testing
trigger_tier2_panic :: proc(shard: ^Shard) {
    siglongjmp(&shard.trap_environment, 1)
}

// --- Enums & Constants ---

Shard_State :: enum u8 {
    Init = 0,
    Running = 1,
    Quarantined = 2,
}

Isolate_State :: enum u8 { Unallocated = 0, Runnable, Waiting, Waiting_For_Reply, Waiting_For_Io, Crashed }

SUPERVISION_GROUP_NONE  :: 0xFFFF
HANDLE_TYPE_ID_SUBGROUP :: 0xFFFF

// --- Core Data Structures ---

// Metadata struct for Odin's #soa slice (usually referred to as SOA metadata in my design notes)
Isolate_Metadata :: struct {
    inbox_head: u32,
    inbox_tail: u32,
    pending_correlation: u32,
    generation: u16,
    inbox_count: u16,
    group_index: u16,      // Index into the Shard's supervision_groups table
    state: Isolate_State,
    shutdown_pending: u8,  // For Graceful Shutdown
}

Shard_Counters :: struct {
    stale_delivery_drops:  u64,
    ring_full_drops:       u64,
    quarantine_drops:      u64,
    pool_exhaustion_drops: u64,
    mailbox_full_drops:    u64,
}

Dynamic_Child_Spec :: struct {
    args_payload: [MAX_INIT_ARGS_SIZE]u8,
    type_id: u8,
    restart_type: Restart_Type,
    args_size: u8,
    _padding: [5]u8,                      // 5 bytes padding to hit 72 bytes
}

// Scheduler-owned structure (64 bytes). Lives in a dense array on the Shard.
Supervision_Group :: struct {
    children_handles:[]Handle, // Mixed Isolate Handles and encoded Subgroup Handles
    dynamic_specs:[]Dynamic_Child_Spec, // Parallel to children_handles for dynamic groups
    boot_spec: ^Group_Spec,
    window_start_tick: u64,
    window_duration_ticks: u32,
    group_index: u16,
    parent_index: u16,
    child_count: u16,
    restart_count: u16,
    restart_count_max: u16,
    strategy: Supervision_Strategy,
    _padding: [3]u8,
}

Shard :: struct {
    // --- Hot Pointers & Slices (8-byte aligned) ---
    // These are accessed frequently during the scheduler loop.
    // Keeping them together maximizes cache line utilization during dispatch.
    // In production this would be an array of *SPSCRing.
    // For now, we inject the SimulatedNetwork.
    // when conditional compilation blocks are not supported inside struct definitions in Odin.
    //
    // Therefore, I'm commenting the when blocks.
    // Second option would be to use condition (when) struct declaration,
    // but then I have to maintain both structs fields. or find a better means
    // when #config(TINA_SIM, false) {
    sim_network:        ^SimulatedNetwork,
    fault_config:       ^FaultConfig,
    // }
    type_descriptors:   []TypeDescriptor,
    isolate_memory:     [][]u8,
    metadata:           []#soa[]Isolate_Metadata,
    supervision_groups: []Supervision_Group,

    // --- Hot Embedded Structs (8-byte aligned) ---
    clock:        Simulated_Clock,
    log_ring:     Log_Ring_Buffer,
    message_pool: Message_Pool,
    counters:     Shard_Counters,

    // --- Hot Scalars (Ordered largest to smallest) ---
    heartbeat_tick:      u64,
    next_correlation_id: u32,
    outbound_count:      u32,
    current_msg_slot:    u32,
    id:                  u16,
    current_type_id:     u16,
    current_slot_index:  u16,
    watchdog_state:      Shard_State,  // 1 byte
    kill_requested:      bool,         // 1 byte
    _padding:            [4]u8,        // 4 bytes explicit padding to hit 8-byte boundary

    // --- Cold / Massive Storage ---
    timer_wheel:      Timer_Wheel,
    outbound_staging: [1024]Message_Envelope,
    trap_environment:         sigjmp_buf,
}

// --- Scheduler Loop ---

scheduler_tick :: proc(shard: ^Shard) {
    // Step 0: Watchdog Check
    if shard.kill_requested {
        shard_mass_teardown(shard)
        return
    }

    shard.heartbeat_tick += 1
    shard.clock.current_tick += 1
    now := shard.clock.current_tick

    when #config(TINA_SIM, false) {
        // Step 1: Drain Inbound Cross-Shard Rings
        if shard.sim_network != nil {
            for src in u16(0)..<shard.sim_network.shard_count {
                if src != shard.id {
                    sim_network_drain(shard.sim_network, shard, src, now)
                }
            }
        }
    }

    // Step 3: Budget-limited dispatch (With Trap Boundary)
    for type_descriptor in shard.type_descriptors {
        type_id := type_descriptor.id
        soa_meta := shard.metadata[type_id]

        shard.current_type_id = u16(type_id)
        start_slot: u16 = 0

        // Trap Boundary: Catches Tier 2 panics natively
        if sigsetjmp(&shard.trap_environment, 0) != 0 {
            // Recovery path — panic occurred inside handler
            if shard.current_msg_slot != POOL_NONE_INDEX {
                env_ptr := rawptr(&shard.message_pool.buffer[shard.current_msg_slot * MESSAGE_ENVELOPE_SIZE])
                pool_free(&shard.message_pool, env_ptr)
                shard.current_msg_slot = POOL_NONE_INDEX
            }
            _teardown_isolate(shard, shard.current_type_id, shard.current_slot_index, .Crashed)
            start_slot = shard.current_slot_index + 1 // Resume seamlessly
        }

        for slot := start_slot; slot < u16(type_descriptor.slot_count); slot += 1 {
            state := soa_meta[slot].state
            if state == .Runnable || (state == .Waiting && soa_meta[slot].inbox_count > 0) {
                shard.current_slot_index = slot
                shard.current_msg_slot = POOL_NONE_INDEX

                message: Message
                message_pointer: ^Message = nil
                correlation: u32 = 0
                flags: u16 = 0

                if soa_meta[slot].inbox_count > 0 {
                    shard.current_msg_slot = _dequeue(shard, u16(type_id), slot, &message, &correlation, &flags)
                    if shard.current_msg_slot != POOL_NONE_INDEX {
                        message_pointer = &message
                    }
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

                // Normal path: Free message slot BEFORE interpreting the effect
                if shard.current_msg_slot != POOL_NONE_INDEX {
                    env_ptr := rawptr(&shard.message_pool.buffer[shard.current_msg_slot * MESSAGE_ENVELOPE_SIZE])
                    pool_free(&shard.message_pool, env_ptr)
                    shard.current_msg_slot = POOL_NONE_INDEX
                }

                _interpret_effect(shard, u16(type_id), slot, effect, &ctx)
            }
        }
    }

    when #config(TINA_SIM, false) {
        // Step 5: Flush Outbound Cross-Shard Rings
        if shard.sim_network != nil {
            for i in 0..<shard.outbound_count {
                env := shard.outbound_staging[i]
                dest_shard := extract_shard_id(env.destination)
                sim_network_enqueue(shard.sim_network, shard, dest_shard, env, now, shard.fault_config)
            }
            shard.outbound_count = 0
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
    soa_meta[slot].group_index = spec.group_index

    ptr := _get_isolate_ptr(shard, type_id, slot)
    stride := shard.type_descriptors[type_id].stride
    if ptr != nil && stride > 0 {
        mem.zero(ptr, stride)
    }

    child_ctx := TinaContext{
        shard = shard,
        self_handle = make_handle(shard.id, type_id, slot, soa_meta[slot].generation),
    }

    local_spec := spec
    effect := shard.type_descriptors[type_id].init_fn(ptr, local_spec.args_payload[:local_spec.args_size], &child_ctx)

    // If init fails, simply free the slot directly. Do not call full teardown.
    if _, is_crash := effect.(Effect_Crash); is_crash {
        soa_meta[slot].state = .Unallocated
        soa_meta[slot].group_index = SUPERVISION_GROUP_NONE
        return Spawn_Error.init_failed
    }
    if _, is_done := effect.(Effect_Done); is_done {
        soa_meta[slot].state = .Unallocated
        soa_meta[slot].group_index = SUPERVISION_GROUP_NONE
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
        return _enqueue(shard, to, envelope)
    } else {
        when #config(TINA_SIM, false) {
            if shard.outbound_count < len(shard.outbound_staging) {
                shard.outbound_staging[shard.outbound_count] = envelope^
                shard.outbound_count += 1
                return .ok
            } else {
                shard.counters.ring_full_drops += 1
                return .mailbox_full
            }
        } else {
            return .ok
        }
    }
}

@(private="package")
_get_isolate_ptr :: proc(shard: ^Shard, type_id: u16, slot: u16) -> rawptr {
    stride := shard.type_descriptors[type_id].stride
    if stride == 0 { return nil }

    assert(int(type_id) < len(shard.isolate_memory), "type_id out of bounds")
    assert(int(slot) * stride < len(shard.isolate_memory[type_id]), "slot out of bounds")

    return rawptr(&shard.isolate_memory[type_id][int(slot) * stride])
}

@(private="package")
_teardown_isolate :: proc(shard: ^Shard, type_id: u16, slot_index: u16, exit_kind: Exit_Kind) {
    soa_meta := shard.metadata[type_id]

    // Step 1: Bump generation (seal the Isolate)
    old_gen := soa_meta[slot_index].generation
    soa_meta[slot_index].generation = old_gen + 1

    // Step 2: Clear pending .call state
    soa_meta[slot_index].pending_correlation = 0

    // Step 3: Drain mailbox
    curr := soa_meta[slot_index].inbox_head
    for curr != POOL_NONE_INDEX {
        env_ptr := rawptr(&shard.message_pool.buffer[curr * MESSAGE_ENVELOPE_SIZE])
        next := (cast(^Message_Envelope)env_ptr).next_in_mailbox
        pool_free(&shard.message_pool, env_ptr)
        curr = next
    }
    soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
    soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
    soa_meta[slot_index].inbox_count = 0

    // Step 4: Invoke supervision subsystem
    group_index := soa_meta[slot_index].group_index
    if group_index != SUPERVISION_GROUP_NONE {
        old_handle := make_handle(shard.id, type_id, slot_index, old_gen)
        _on_child_exit(shard, group_index, old_handle, exit_kind)
    }

    // Step 5: Free arena slot
    soa_meta[slot_index].state = .Unallocated
}

@(private="package")
_enqueue :: proc(shard: ^Shard, to: Handle, env: ^Message_Envelope) -> Send_Result {
    type_id := extract_type_id(to)
    slot := extract_slot(to)
    soa_meta := shard.metadata[type_id]

    if soa_meta[slot].generation != extract_generation(to) { return .stale_handle }

    is_reply := (env.flags & ENVELOPE_FLAG_IS_REPLY) != 0
    is_timeout := env.tag == TAG_CALL_TIMEOUT

    if is_reply || is_timeout {
        if soa_meta[slot].state != .Waiting_For_Reply { return .stale_handle }
        if soa_meta[slot].pending_correlation != env.correlation { return .stale_handle }

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

    if soa_meta[slot].state == .Waiting { soa_meta[slot].state = .Runnable }
    return .ok
}

@(private="package")
_dequeue :: proc(shard: ^Shard, type_id: u16, slot: u16, out_message: ^Message, out_correlation: ^u32, out_flags: ^u16) -> u32 {
    soa_meta := shard.metadata[type_id]
    head_index := soa_meta[slot].inbox_head
    if head_index == POOL_NONE_INDEX { return POOL_NONE_INDEX }

    envelope_ptr := rawptr(&shard.message_pool.buffer[head_index * MESSAGE_ENVELOPE_SIZE])
    envelope := cast(^Message_Envelope)envelope_ptr

    out_message.tag = envelope.tag
    out_message.body.user.source = envelope.source
    out_message.body.user.payload_size = envelope.payload_size
    copy(out_message.body.user.payload[:], envelope.payload[:])

    out_correlation^ = envelope.correlation
    out_flags^ = envelope.flags

    next_index := envelope.next_in_mailbox
    soa_meta[slot].inbox_head = next_index
    if next_index == POOL_NONE_INDEX { soa_meta[slot].inbox_tail = POOL_NONE_INDEX }
    soa_meta[slot].inbox_count -= 1

    // DO NOT FREE YET. Let scheduler own it during handler execution.
    return head_index
}

@(private="package")
_interpret_effect :: proc(shard: ^Shard, type_id: u16, slot: u16, effect: Effect, ctx: ^TinaContext) {
    soa_meta := shard.metadata[type_id]
    switch e in effect {
        case Effect_Done:
            _teardown_isolate(shard, type_id, slot, .Normal)
        case Effect_Yield:
            soa_meta[slot].state = .Runnable
        case Effect_Receive:
            soa_meta[slot].state = .Waiting
        case Effect_Crash:
            ctx_log(ctx, .ERROR, LOG_TAG_ISOLATE_CRASHED, transmute([]u8)string("Voluntary crash"))
            _teardown_isolate(shard, type_id, slot, .Crashed)
        case Effect_Call:
            shard.next_correlation_id += 1
            if shard.next_correlation_id == 0 do shard.next_correlation_id = 1
            corr := shard.next_correlation_id

            soa_meta[slot].pending_correlation = corr
            soa_meta[slot].state = .Waiting_For_Reply

            _register_system_timer(shard, ctx.self_handle, e.timeout, TAG_CALL_TIMEOUT, corr)

            local_msg := e.message // Make "e.message" it addressable
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
                _teardown_isolate(shard, type_id, slot, .Crashed)
                return
            }
            soa_meta[slot].state = .Waiting

            local_msg := e.message // Make "e.message" it addressable
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
            _teardown_isolate(shard, type_id, slot, .Crashed)
    }
}

// --- Supervision & Control Plane ---

@(private="package")
_find_child_index :: proc(group: ^Supervision_Group, handle: Handle) -> (u16, bool) {
    for i in 0..<group.child_count {
        if group.children_handles[i] == handle do return i, true
    }
    return 0, false
}

@(private="package")
_remove_child_at :: proc(group: ^Supervision_Group, index: u16) {
    for i in index..<group.child_count - 1 {
        group.children_handles[i] = group.children_handles[i + 1]
        if len(group.dynamic_specs) > 0 {
            group.dynamic_specs[i] = group.dynamic_specs[i + 1]
        }
    }
    group.child_count -= 1
}

@(private="package")
_get_child_restart_type :: proc(group: ^Supervision_Group, index: u16) -> Restart_Type {
    if len(group.dynamic_specs) > 0 {
        return group.dynamic_specs[index].restart_type
    } else {
        child_spec_ptr := &group.boot_spec.children[index]
        #partial switch &s in child_spec_ptr {
            case Static_Child_Spec: return s.restart_type
            case Group_Spec: return .permanent // Subgroups are permanent
        }
    }
    return .temporary
}

@(private="package")
_check_and_record_restart :: proc(shard: ^Shard, group: ^Supervision_Group) -> bool {
    now := shard.clock.current_tick
    if now - group.window_start_tick >= u64(group.window_duration_ticks) {
        group.window_start_tick = now
        group.restart_count = 1
        return false
    }
    group.restart_count += 1
    return group.restart_count > group.restart_count_max
}

@(private="package")
_escalate :: proc(shard: ^Shard, group: ^Supervision_Group) {
    // Tear down all remaining children in reverse start order
    for i := group.child_count; i > 0; i -= 1 {
        handle := group.children_handles[i - 1]
        if handle != HANDLE_NONE {
            if extract_type_id(handle) != HANDLE_TYPE_ID_SUBGROUP {
                _teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
            } else {
                _teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
            }
        }
    }
    group.child_count = 0

    if group.parent_index == SUPERVISION_GROUP_NONE {
        // Force Level 2 Shard Restart
        shard.kill_requested = true
    } else {
        group_handle := make_handle(shard.id, HANDLE_TYPE_ID_SUBGROUP, group.group_index, 0)
        _on_child_exit(shard, group.parent_index, group_handle, .Crashed)
    }
}

@(private="package")
_teardown_subgroup :: proc(shard: ^Shard, group: ^Supervision_Group) {
    for i := group.child_count; i > 0; i -= 1 {
        handle := group.children_handles[i - 1]
        if handle != HANDLE_NONE {
            if extract_type_id(handle) != HANDLE_TYPE_ID_SUBGROUP {
                _teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
            } else {
                _teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
            }
        }
    }
    group.restart_count = 0
    group.window_start_tick = shard.clock.current_tick
}

@(private="package")
_respawn_child_at :: proc(shard: ^Shard, group: ^Supervision_Group, index: u16) {
    spec: Spawn_Spec
    spec.group_index = group.group_index

    if len(group.dynamic_specs) > 0 {
        dyn := &group.dynamic_specs[index]
        spec.type_id = dyn.type_id
        spec.restart_type = dyn.restart_type
        spec.args_size = dyn.args_size
        spec.args_payload = dyn.args_payload
    } else {
        child_spec_ptr := &group.boot_spec.children[index]
        #partial switch &s in child_spec_ptr {
            case Static_Child_Spec:
                spec.type_id = s.type_id
                spec.restart_type = s.restart_type
                spec.args_size = s.args_size
                spec.args_payload = s.args_payload
            case Group_Spec:
                sub_handle := group.children_handles[index]
                sub_index := extract_slot(sub_handle)
                _rebuild_subgroup(shard, &shard.supervision_groups[sub_index])
                return
        }
    }

    ctx := TinaContext{ shard = shard, self_handle = HANDLE_NONE }
    res := ctx_spawn(&ctx, spec)

    if handle, ok := res.(Handle); ok {
        group.children_handles[index] = handle
    } else {
        _escalate(shard, group)
    }
}

@(private="package")
_apply_strategy :: proc(shard: ^Shard, group: ^Supervision_Group, crashed_index: u16) {
    start_index: u16 = group.strategy == .Rest_For_One ? crashed_index + 1 : 0

    if group.strategy == .One_For_All || group.strategy == .Rest_For_One {
        for i := group.child_count; i > start_index; i -= 1 {
            target_index := i - 1
            if target_index == crashed_index do continue

            handle := group.children_handles[target_index]
            if handle != HANDLE_NONE {
                if extract_type_id(handle) != HANDLE_TYPE_ID_SUBGROUP {
                    _teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
                    group.children_handles[target_index] = HANDLE_NONE
                } else {
                    _teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
                }
            }
        }
    }

    restart_start: u16
    restart_end: u16

    switch group.strategy {
        case .One_For_One:  restart_start = crashed_index; restart_end = crashed_index + 1
        case .One_For_All:  restart_start = 0;             restart_end = group.child_count
        case .Rest_For_One: restart_start = crashed_index; restart_end = group.child_count
    }

    for i in restart_start..<restart_end {
        _respawn_child_at(shard, group, i)
    }
}

@(private="package")
_on_child_exit :: proc(shard: ^Shard, group_index: u16, child_handle: Handle, exit_kind: Exit_Kind) {
    group := &shard.supervision_groups[group_index]

    if exit_kind == .Shutdown {
        index, found := _find_child_index(group, child_handle)
        if found do _remove_child_at(group, index)
        return
    }

    index, found := _find_child_index(group, child_handle)
    if !found do return

    restart_type := _get_child_restart_type(group, index)

    should_restart := false
    switch exit_kind {
        case .Normal:   should_restart = (restart_type == .permanent)
        case .Crashed:  should_restart = (restart_type != .temporary)
        case .Shutdown:
    }

    if !should_restart {
        _remove_child_at(group, index)
        return
    }

    if _check_and_record_restart(shard, group) {
        _escalate(shard, group)
        return
    }

    _apply_strategy(shard, group, index)
}

// Boot Initialization
shard_build_supervision_tree :: proc(shard: ^Shard, root_spec: ^Group_Spec, allocator: mem.Allocator) {
    next_group_index: u16 = 0
    _build_group(shard, root_spec, SUPERVISION_GROUP_NONE, &next_group_index, allocator)
}

@(private="package")
_build_group :: proc(shard: ^Shard, group_spec: ^Group_Spec, parent_index: u16, next_group_index: ^u16, allocator: mem.Allocator) -> u16 {
    group_index := next_group_index^
    next_group_index^ += 1

    group := &shard.supervision_groups[group_index]
    group.group_index = group_index
    group.parent_index = parent_index
    group.strategy = group_spec.strategy
    group.boot_spec = group_spec
    group.window_duration_ticks = group_spec.window_duration_ticks
    group.restart_count_max = group_spec.restart_count_max
    group.restart_count = 0
    group.window_start_tick = shard.clock.current_tick

    capacity: int
    if group_spec.dynamic_child_count_max > 0 {
        capacity = int(group_spec.dynamic_child_count_max)
    } else {
        capacity = len(group_spec.children)
    }

    group.children_handles = make([]Handle, capacity, allocator)
    if group_spec.dynamic_child_count_max > 0 {
        group.dynamic_specs = make([]Dynamic_Child_Spec, capacity, allocator)
    }

    group.child_count = 0
    for i in 0..<len(group_spec.children) {
        child_spec_ptr := &group_spec.children[i]
        #partial switch &s in child_spec_ptr {
            case Static_Child_Spec:
                spec := Spawn_Spec{
                    args_payload = s.args_payload,
                    group_index = group_index,
                    type_id = s.type_id,
                    restart_type = s.restart_type,
                    args_size = s.args_size,
                }
                ctx := TinaContext{ shard = shard, self_handle = HANDLE_NONE }
                if handle, ok := ctx_spawn(&ctx, spec).(Handle); ok {
                    group.children_handles[group.child_count] = handle
                    group.child_count += 1
                } else {
                    panic("Failed to spawn static child during boot initialization")
                }

            case Group_Spec:
                sub_index := _build_group(shard, &s, group_index, next_group_index, allocator)
                sub_handle := make_handle(shard.id, HANDLE_TYPE_ID_SUBGROUP, sub_index, 0)
                group.children_handles[group.child_count] = sub_handle
                group.child_count += 1
        }
    }

    return group_index
}

@(private="package")
_rebuild_subgroup :: proc(shard: ^Shard, group: ^Supervision_Group) {
    group.child_count = 0
    for i in 0..<len(group.boot_spec.children) {
        _respawn_child_at(shard, group, u16(i))
        group.child_count += 1
    }
    group.restart_count = 0
    group.window_start_tick = shard.clock.current_tick
}

// Level 2 Shard Mass Teardown
@(private="package")
shard_mass_teardown :: proc(shard: ^Shard) {
    log_flush(shard)

    for type_desc in shard.type_descriptors {
        type_id := type_desc.id
        soa_meta := shard.metadata[type_id]
        for slot in 0..<type_desc.slot_count {
            soa_meta[slot].generation += 1
        }
    }

    shard.message_pool.free_slots = shard.message_pool.total_slots
    shard.message_pool.head_index = POOL_NONE_INDEX
    for i := shard.message_pool.total_slots - 1; i >= 0; i -= 1 {
        ptr := &shard.message_pool.buffer[i * shard.message_pool.chunk_size]
        next_index_pointer := cast(^u32)ptr
        next_index_pointer^ = shard.message_pool.head_index
        shard.message_pool.head_index = u32(i)
    }

    for type_desc in shard.type_descriptors {
        type_id := type_desc.id
        soa_meta := shard.metadata[type_id]
        for slot in 0..<type_desc.slot_count {
            soa_meta[slot].state = .Unallocated
            soa_meta[slot].inbox_count = 0
            soa_meta[slot].inbox_head = POOL_NONE_INDEX
            soa_meta[slot].inbox_tail = POOL_NONE_INDEX
            soa_meta[slot].pending_correlation = 0
        }
    }

    for i in 0..<TIMER_WHEEL_SPOKE_COUNT {
        shard.timer_wheel.spokes[i] = POOL_NONE_INDEX
    }
    shard.timer_wheel.free_head = POOL_NONE_INDEX
    for i := len(shard.timer_wheel.entries) - 1; i >= 0; i -= 1 {
        shard.timer_wheel.entries[i].next = shard.timer_wheel.free_head
        shard.timer_wheel.free_head = u32(i)
    }

    shard.outbound_count = 0
    shard.next_correlation_id = 0

    shard.kill_requested = false

    root_group_spec := shard.supervision_groups[0].boot_spec
    shard_build_supervision_tree(shard, root_group_spec, context.allocator)
}
