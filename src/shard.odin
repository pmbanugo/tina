package tina

import "core:testing"
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

Isolate_Metadata :: struct {
    io_peer_address:       Peer_Address,        // 28 bytes
    inbox_head:            u32,                 // 4 bytes
    inbox_tail:            u32,                 // 4 bytes
    pending_correlation:   u32,                 // 4 bytes
    io_fd:                 FD_Handle,           // 4 bytes
    io_result:             i32,                 // 4 bytes
    pending_transfer_read: Transfer_Handle,     // 4 bytes
    generation:            u32,                 // 4 bytes
    working_arena_offset:  u32,                 // 4 bytes
    inbox_count:           u16,                 // 2 bytes
    group_index:           u16,                 // 2 bytes
    io_completion_tag:     IO_Completion_Tag,   // 2 bytes
    io_buffer_index:       u16,                 // 2 bytes
    state:                 Isolate_State,       // 1 byte
    shutdown_pending:      u8,                  // 1 byte
    io_sequence:           u8,                  // 1 byte
    _padding:              [1]u8,               // (Packs exactly to 72 bytes)
}

Shard_Counters :: struct {
    stale_delivery_drops:      u64,
    ring_full_drops:           u64,
    quarantine_drops:          u64,
    pool_exhaustion_drops:     u64,
    mailbox_full_drops:        u64,
    io_buffer_exhaustions:     u64,
    io_submission_exhaustions: u64,
    io_stale_completions:      u64,
    transfer_exhaustions:      u64,
    transfer_stale_reads:      u64,
}

Dynamic_Child_Spec :: struct {
    args_payload:[MAX_INIT_ARGS_SIZE]u8,
    type_id: u8,
    restart_type: Restart_Type,
    args_size: u8,
    _padding: [5]u8,
}

Supervision_Group :: struct {
    children_handles:[]Handle,
    dynamic_specs:[]Dynamic_Child_Spec,
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
    sim_network:          ^SimulatedNetwork,
    fault_config:         ^FaultConfig,
    outbound_rings:       []^SPSC_Ring,
    inbound_rings:        []^SPSC_Ring,
    type_descriptors:[]TypeDescriptor,
    isolate_memory:       [][]u8,
    working_memory:       [][]u8,   // Base slices for working memory
    scratch_memory:[]u8,     // Base slice for scratch arena
    transfer_generations:[]u16,    // Generations for transfer buffer stale-reference detection
    metadata:             []#soa[]Isolate_Metadata,
    supervision_groups:[]Supervision_Group,

    // --- Hot Embedded Structs (8-byte aligned) ---
    clock:         Simulated_Clock,
    log_ring:      Log_Ring_Buffer,
    message_pool:  Message_Pool,
    transfer_pool: Reactor_Buffer_Pool,
    counters:      Shard_Counters,

    // --- Hot Scalars (Ordered largest to smallest) ---
    heartbeat_tick:      u64,
    next_correlation_id: u32,
    outbound_count:      u32,
    current_msg_slot:    u32,
    current_slot_index:  u32,
    id:                  u16,
    current_type_id:     u16,
    watchdog_state:      Shard_State,
    kill_requested:      bool,
    shutdown_requested:  bool,
    _padding:            [1]u8,

    // --- Cold / Massive Storage ---
    timer_wheel:      Timer_Wheel,
    outbound_staging: [1024]Message_Envelope,
    trap_environment: sigjmp_buf,
    reactor:          Reactor,
}

// --- Scheduler Loop ---

scheduler_tick :: proc(shard: ^Shard) {
    if shard.kill_requested {
        shard_mass_teardown(shard)
        return
    }

    shard.heartbeat_tick += 1
    shard.clock.current_tick += 1
    now := shard.clock.current_tick

    // Step 1: Drain inbound cross-shard rings → deliver to local mailboxes ---
    when #config(TINA_SIM, false) {
        if shard.sim_network != nil {
            for src in u16(0)..<shard.sim_network.shard_count {
                if src != shard.id {
                    sim_network_drain(shard.sim_network, shard, src, now)
                }
            }
        }
    } else {
        if len(shard.inbound_rings) > 0 {
            for ring in shard.inbound_rings {
                if ring == nil do continue

                available := spsc_ring_available_to_read(ring)
                for i in 0..<available {
                    envelope := spsc_ring_get_read_ptr(ring, i)
                    res := _enqueue(shard, envelope.destination, envelope)

                    if res == .mailbox_full {
                        shard.counters.mailbox_full_drops += 1
                    } else if res == .stale_handle {
                        shard.counters.stale_delivery_drops += 1
                    }
                }

                if available > 0 {
                    spsc_ring_commit_read(ring, available)
                }
            }
        }
    }

    // Step 2: Collect I/O completions
	reactor_collect_completions(&shard.reactor, shard, 0)

	// Step 3: Isolate Dispatch
    for type_descriptor in shard.type_descriptors {
        type_id := type_descriptor.id
        soa_meta := shard.metadata[type_id]

        shard.current_type_id = u16(type_id)
        start_slot: u32 = 0

        if sigsetjmp(&shard.trap_environment, 0) != 0 {
            if shard.current_msg_slot != POOL_NONE_INDEX {
                pool_free(&shard.message_pool, shard.current_msg_slot)
                shard.current_msg_slot = POOL_NONE_INDEX
            }
            _teardown_isolate(shard, shard.current_type_id, shard.current_slot_index, .Crashed)
            start_slot = shard.current_slot_index + 1
        }

        for slot : u32 = start_slot; slot < u32(type_descriptor.slot_count); slot += 1 {
            state := soa_meta[slot].state

            has_work := (state == .Runnable) ||
                        (state == .Waiting && soa_meta[slot].inbox_count > 0) ||
                        (soa_meta[slot].io_completion_tag != IO_TAG_NONE) ||
                        (soa_meta[slot].shutdown_pending != 0)

            if has_work {
                shard.current_slot_index = slot
                shard.current_msg_slot = POOL_NONE_INDEX

                message: Message
                message_pointer: ^Message = nil
                correlation: u32 = 0
                flags: Envelope_Flags

                is_io_completion := false
                buffer_to_free: u16 = BUFFER_INDEX_NONE

                if soa_meta[slot].io_completion_tag != IO_TAG_NONE {
                    message.tag = Message_Tag(soa_meta[slot].io_completion_tag)
                    message.body.io.result = soa_meta[slot].io_result
                    message.body.io.fd = soa_meta[slot].io_fd
                    message.body.io.buffer_index = soa_meta[slot].io_buffer_index
                    message.body.io.peer_address = soa_meta[slot].io_peer_address

                    message_pointer = &message
                    is_io_completion = true
                    buffer_to_free = soa_meta[slot].io_buffer_index
                } else if soa_meta[slot].shutdown_pending != 0 {
                    message.tag = TAG_SHUTDOWN
                    message.body.user.source = HANDLE_NONE
                    message.body.user.payload_size = 0

                    message_pointer = &message
                    soa_meta[slot].shutdown_pending = 0
                } else if soa_meta[slot].inbox_count > 0 {
                    shard.current_msg_slot = _dequeue(shard, u16(type_id), slot, &message, &correlation, &flags)
                    if shard.current_msg_slot != POOL_NONE_INDEX {
                        message_pointer = &message
                    }
                }

                ctx := TinaContext{
                    shard = shard,
                    self_handle = make_handle(shard.id, u16(type_id), slot, soa_meta[slot].generation),
                    current_message_source = message_pointer != nil && !is_io_completion && message.tag != TAG_SHUTDOWN ? message.body.user.source : HANDLE_NONE,
                    current_correlation = correlation,
                    is_call = .Is_Call in flags,
                }

                // Initialize Context Arenas (§6.9)
                mem.arena_init(&ctx.scratch_arena, shard.scratch_memory) // Implicitly resets offset to 0

                working_stride := type_descriptor.working_memory_size
                if working_stride > 0 {
                    start_idx := int(slot) * working_stride
                    working_slice := shard.working_memory[type_id][start_idx : start_idx + working_stride]
                    // Working Arena: Do NOT use mem.arena_init
                    // Constructing it manually preserves the ASAN unpoisoned state of previously allocated bytes.
                    ctx.working_arena = mem.Arena{
                        data = working_slice,
                        offset = int(soa_meta[slot].working_arena_offset),
                    }
                }

                ptr := _get_isolate_ptr(shard, u16(type_id), slot)
                effect := type_descriptor.handler_fn(ptr, message_pointer, &ctx)

                // Write back working arena offset
                if working_stride > 0 {
                    soa_meta[slot].working_arena_offset = u32(ctx.working_arena.offset)
                }

                if is_io_completion {
                    soa_meta[slot].io_completion_tag = IO_TAG_NONE
                    if buffer_to_free != BUFFER_INDEX_NONE {
                        reactor_buffer_pool_free(&shard.reactor.buffer_pool, buffer_to_free)
                    }
                }

                // Transfer Buffer Auto-Free (§6.9 §8.3)
                if soa_meta[slot].pending_transfer_read != TRANSFER_HANDLE_NONE {
                    t_handle := soa_meta[slot].pending_transfer_read
                    _transfer_pool_free(shard, transfer_handle_index(t_handle))
                    soa_meta[slot].pending_transfer_read = TRANSFER_HANDLE_NONE
                }

                if shard.current_msg_slot != POOL_NONE_INDEX {
                    pool_free(&shard.message_pool, shard.current_msg_slot)
                    shard.current_msg_slot = POOL_NONE_INDEX
                }

                _interpret_effect(shard, u16(type_id), slot, effect, &ctx)
            }
        }
    }

    // Step 4: Flush I/O submissions
	reactor_flush_submissions(&shard.reactor, shard)

	// Step 5: Flush outbound cross-shard rings
    when #config(TINA_SIM, false) {
        if shard.sim_network != nil {
            for i in 0..<shard.outbound_count {
                env := shard.outbound_staging[i]
                dest_shard := extract_shard_id(env.destination)
                sim_network_enqueue(shard.sim_network, shard, dest_shard, env, now, shard.fault_config)
            }
            shard.outbound_count = 0
        }
    } else {
        if len(shard.outbound_rings) > 0 {
            for ring in shard.outbound_rings {
                if ring != nil {
                    spsc_ring_flush_producer(ring)
                }
            }
        }
    }

    // Step 6 & 7: Advance timers and Flush logs
    _advance_timers(shard)
    log_flush(shard)
}

// --- Active Operations ---

ctx_send :: proc(ctx: ^TinaContext, to: Handle, tag: Message_Tag, payload:[]u8) -> Send_Result {
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

    slot: u32 = 0xFFFF_FFFF
    for i in 0..<len(soa_meta) {
        if soa_meta[i].state == .Unallocated {
            slot = u32(i); break
        }
    }
    if slot == 0xFFFF_FFFF { return Spawn_Error.arena_full }

    child_generation := soa_meta[slot].generation
    child_handle := make_handle(shard.id, type_id, slot, child_generation)

    if spec.handoff_fd != FD_HANDLE_NONE {
        entry, fd_err := fd_table_lookup(&shard.reactor.fd_table, spec.handoff_fd)
        if fd_err == .None {
            can_transfer := true
            if spec.handoff_mode == .Full || spec.handoff_mode == .Read_Only {
                if entry.read_owner != ctx.self_handle do can_transfer = false
            }
            if spec.handoff_mode == .Full || spec.handoff_mode == .Write_Only {
                if entry.write_owner != ctx.self_handle do can_transfer = false
            }

            if can_transfer {
                fd_table_handoff(&shard.reactor.fd_table, spec.handoff_fd, child_handle, spec.handoff_mode)
            } else {
                ctx_log(ctx, .ERROR, LOG_TAG_ISOLATE_CRASHED, transmute([]u8)string("FD handoff affinity violation"))
                return Spawn_Error.init_failed
            }
        } else {
            return Spawn_Error.init_failed
        }
    }

    soa_meta[slot].state = .Runnable
    soa_meta[slot].group_index = spec.group_index
    soa_meta[slot].pending_transfer_read = TRANSFER_HANDLE_NONE

    ptr := _get_isolate_ptr(shard, type_id, slot)
    stride := shard.type_descriptors[type_id].stride
    if ptr != nil && stride > 0 {
        mem.zero(ptr, stride)
    }

    child_ctx := TinaContext{
        shard = shard,
        self_handle = child_handle,
    }

    mem.arena_init(&child_ctx.scratch_arena, shard.scratch_memory)

    working_stride := shard.type_descriptors[type_id].working_memory_size
    if working_stride > 0 {
        start_idx := int(slot) * working_stride
        working_slice := shard.working_memory[type_id][start_idx : start_idx + working_stride]
        // On spawn, it is brand new, so we DO want to wipe/poison it.
        mem.arena_init(&child_ctx.working_arena, working_slice)
    }

    local_spec := spec
    effect := shard.type_descriptors[type_id].init_fn(ptr, local_spec.args_payload[:local_spec.args_size], &child_ctx)

    if working_stride > 0 {
        soa_meta[slot].working_arena_offset = u32(child_ctx.working_arena.offset)
    }

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
    return child_handle
}

// ============================================================================
// Memory Management APIs (§6.9 §9)
// ============================================================================

ctx_working_arena :: #force_inline proc(ctx: ^TinaContext) -> mem.Allocator {
    return mem.arena_allocator(&ctx.working_arena)
}

ctx_working_arena_reset :: #force_inline proc(ctx: ^TinaContext) {
    ctx.working_arena.offset = 0
}

ctx_scratch_arena :: #force_inline proc(ctx: ^TinaContext) -> mem.Allocator {
    return mem.arena_allocator(&ctx.scratch_arena)
}

ctx_transfer_alloc :: proc(ctx: ^TinaContext) -> Transfer_Alloc_Result {
    idx, err := reactor_buffer_pool_alloc(&ctx.shard.transfer_pool)
    if err != .None {
        ctx.shard.counters.transfer_exhaustions += 1
        return Transfer_Alloc_Error.Pool_Exhausted
    }
    gen := ctx.shard.transfer_generations[idx]
    return transfer_handle_make(idx, gen)
}

ctx_transfer_write :: proc(ctx: ^TinaContext, handle: Transfer_Handle, data:[]u8) -> Transfer_Write_Error {
    idx := transfer_handle_index(handle)
    gen := transfer_handle_generation(handle)

    if idx >= ctx.shard.transfer_pool.slot_count || ctx.shard.transfer_generations[idx] != gen {
        return .Stale_Handle
    }

    if u32(len(data)) > ctx.shard.transfer_pool.slot_size {
        return .Bounds_Violation
    }

    dst := reactor_buffer_pool_slot_ptr(&ctx.shard.transfer_pool, idx)
    mem.copy(dst, raw_data(data), len(data))
    return .None
}

ctx_transfer_read :: proc(ctx: ^TinaContext, handle: Transfer_Handle) -> Transfer_Read_Result {
    idx := transfer_handle_index(handle)
    gen := transfer_handle_generation(handle)

    if idx >= ctx.shard.transfer_pool.slot_count || ctx.shard.transfer_generations[idx] != gen {
        ctx.shard.counters.transfer_stale_reads += 1
        return Transfer_Read_Error.Stale_Handle
    }

    // Track auto-free lifecycle. The scheduler frees this automatically on handler return.
    type_id := extract_type_id(ctx.self_handle)
    slot := extract_slot(ctx.self_handle)
    ctx.shard.metadata[type_id][slot].pending_transfer_read = handle

    ptr := reactor_buffer_pool_slot_ptr(&ctx.shard.transfer_pool, idx)
    return ptr[:ctx.shard.transfer_pool.slot_size]
}

// ============================================================================
// Synchronous I/O Control Operations (§6.6.3 §4.1)
// ============================================================================

ctx_socket :: #force_inline proc(
	ctx: ^TinaContext,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (FD_Handle, Reactor_Socket_Error) {
	return reactor_control_socket(&ctx.shard.reactor, ctx.self_handle, domain, socket_type, protocol)
}

ctx_bind :: #force_inline proc(ctx: ^TinaContext, fd: FD_Handle, address: Socket_Address) -> Backend_Error {
	return reactor_control_bind(&ctx.shard.reactor, fd, address)
}

ctx_listen :: #force_inline proc(ctx: ^TinaContext, fd: FD_Handle, backlog: u32) -> Backend_Error {
	return reactor_control_listen(&ctx.shard.reactor, fd, backlog)
}

ctx_setsockopt :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	return reactor_control_setsockopt(&ctx.shard.reactor, fd, level, option, value)
}

ctx_shutdown :: #force_inline proc(ctx: ^TinaContext, fd: FD_Handle, how: Shutdown_How) -> Backend_Error {
	return reactor_control_shutdown(&ctx.shard.reactor, fd, ctx.self_handle, how)
}

ctx_read_buffer :: #force_inline proc(ctx: ^TinaContext, buffer_index: u16, length: u32) ->[]u8 {
	if length <= 0 do return nil
	return reactor_buffer_pool_read_slice(&ctx.shard.reactor.buffer_pool, buffer_index, length)
}

ctx_is_shutting_down :: #force_inline proc(ctx: ^TinaContext) -> bool {
	return ctx.shard.shutdown_requested
}

ctx_type_config :: #force_inline proc(ctx: ^TinaContext) -> ^TypeDescriptor {
	type_id := extract_type_id(ctx.self_handle)
	return &ctx.shard.type_descriptors[type_id]
}

ctx_shard_id :: #force_inline proc(ctx: ^TinaContext) -> u16 {
	return ctx.shard.id
}

ctx_getsockopt :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
) -> (Socket_Option_Value, Backend_Error) {
	return false, .Unsupported
}

// --- Internal Utilities ---

@(private="package")
_transfer_pool_free :: #force_inline proc(shard: ^Shard, idx: u16) {
    reactor_buffer_pool_free(&shard.transfer_pool, idx)
    shard.transfer_generations[idx] += 1
}

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
            ring := shard.outbound_rings[destination]
            if ring == nil do return .stale_handle
            if !spsc_ring_enqueue(ring, envelope) {
                shard.counters.ring_full_drops += 1
                return .mailbox_full
            }
            return .ok
        }
    }
}

@(private="package")
_get_isolate_ptr :: proc(shard: ^Shard, type_id: u16, slot: u32) -> rawptr {
    stride := shard.type_descriptors[type_id].stride
    if stride == 0 { return nil }

    assert(int(type_id) < len(shard.isolate_memory), "type_id out of bounds")
    assert(int(slot) * stride < len(shard.isolate_memory[type_id]), "slot out of bounds")

    return rawptr(&shard.isolate_memory[type_id][int(slot) * stride])
}

@(private="package")
_teardown_isolate :: proc(shard: ^Shard, type_id: u16, slot_index: u32, exit_kind: Exit_Kind) {
    soa_meta := shard.metadata[type_id]

    // Step 1: Bump generation (seal the Isolate) - 28-bit mask
    old_generation := soa_meta[slot_index].generation
    new_generation := (old_generation + 1) & 0x0FFFFFFF
    if new_generation == 0 do new_generation = 1
    soa_meta[slot_index].generation = new_generation

    // Step 2: Clear pending .call state & working arena offset
    soa_meta[slot_index].pending_correlation = 0
    soa_meta[slot_index].working_arena_offset = 0

    // Step 2b: Reclaim pending I/O and Transfer buffers
    if soa_meta[slot_index].io_completion_tag != IO_TAG_NONE {
        tag := soa_meta[slot_index].io_completion_tag
        if tag == IO_TAG_READ_COMPLETE || tag == IO_TAG_RECV_COMPLETE || tag == IO_TAG_RECVFROM_COMPLETE {
            if soa_meta[slot_index].io_buffer_index != BUFFER_INDEX_NONE {
                reactor_buffer_pool_free(&shard.reactor.buffer_pool, soa_meta[slot_index].io_buffer_index)
            }
        }
        soa_meta[slot_index].io_completion_tag = IO_TAG_NONE
        soa_meta[slot_index].io_buffer_index = BUFFER_INDEX_NONE
    }
    if soa_meta[slot_index].pending_transfer_read != TRANSFER_HANDLE_NONE {
        idx := transfer_handle_index(soa_meta[slot_index].pending_transfer_read)
        _transfer_pool_free(shard, idx)
        soa_meta[slot_index].pending_transfer_read = TRANSFER_HANDLE_NONE
    }

    // Step 2c: FD Table Cleanup
    handle_to_match := make_handle(shard.id, type_id, slot_index, old_generation)
    in_flight_fd := soa_meta[slot_index].io_fd
    is_waiting_for_io := soa_meta[slot_index].state == .Waiting_For_Io

    for i in 0..<shard.reactor.fd_table.slot_count {
        entry := &shard.reactor.fd_table.entries[i]
        if entry.read_owner == HANDLE_NONE && entry.write_owner == HANDLE_NONE {
            continue
        }
        if entry.read_owner == handle_to_match || entry.write_owner == handle_to_match {
            fd_h := fd_handle_make(u16(i), entry.generation)

            if is_waiting_for_io && fd_h == in_flight_fd {
                fd_table_mark_close_on_completion(&shard.reactor.fd_table, fd_h)
            } else {
                reactor_internal_close_fd(&shard.reactor, fd_h)
            }
        }
    }

    // Step 3: Drain mailbox
    curr := soa_meta[slot_index].inbox_head
    for curr != POOL_NONE_INDEX {
        envelope := cast(^Message_Envelope)pool_get_ptr(&shard.message_pool, curr)
        next := envelope.next_in_mailbox

        if envelope.tag == TAG_TRANSFER && envelope.payload_size >= size_of(Transfer_Handle) {
            t_handle := (cast(^Transfer_Handle)&envelope.payload[0])^
            _transfer_pool_free(shard, transfer_handle_index(t_handle))
        }

        pool_free(&shard.message_pool, curr)
        curr = next
    }
    soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
    soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
    soa_meta[slot_index].inbox_count = 0

    // Step 4: Invoke supervision subsystem
    group_index := soa_meta[slot_index].group_index
    if group_index != SUPERVISION_GROUP_NONE {
        old_handle := make_handle(shard.id, type_id, slot_index, old_generation)
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

    is_reply := .Is_Reply in env.flags
    is_timeout := env.tag == TAG_CALL_TIMEOUT

    if is_reply || is_timeout {
        if soa_meta[slot].state != .Waiting_For_Reply { return .stale_handle }
        if soa_meta[slot].pending_correlation != env.correlation { return .stale_handle }

        soa_meta[slot].pending_correlation = 0
        soa_meta[slot].state = .Runnable
    }

    if soa_meta[slot].inbox_count >= 256 { return .mailbox_full }

    pool_index, err := pool_alloc(&shard.message_pool)
    if err != .None { return .pool_exhausted }

    dest_env := cast(^Message_Envelope)pool_get_ptr(&shard.message_pool, pool_index)
    dest_env^ = env^
    dest_env.next_in_mailbox = POOL_NONE_INDEX

    if soa_meta[slot].inbox_head == POOL_NONE_INDEX {
        soa_meta[slot].inbox_head = pool_index
    } else {
        tail_envelope := cast(^Message_Envelope)pool_get_ptr(&shard.message_pool, soa_meta[slot].inbox_tail)
        tail_envelope.next_in_mailbox = pool_index
    }

    soa_meta[slot].inbox_tail = pool_index
    soa_meta[slot].inbox_count += 1

    if soa_meta[slot].state == .Waiting { soa_meta[slot].state = .Runnable }
    return .ok
}

@(private="package")
_dequeue :: proc(shard: ^Shard, type_id: u16, slot: u32, out_message: ^Message, out_correlation: ^u32, out_flags: ^Envelope_Flags) -> u32 {
    soa_meta := shard.metadata[type_id]
    head_index := soa_meta[slot].inbox_head
    if head_index == POOL_NONE_INDEX { return POOL_NONE_INDEX }

    envelope := cast(^Message_Envelope)pool_get_ptr(&shard.message_pool, head_index)

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

    return head_index
}

@(private="package")
_interpret_effect :: proc(shard: ^Shard, type_id: u16, slot: u32, effect: Effect, ctx: ^TinaContext) {
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
        envelope.flags += {.Is_Call}
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
        envelope.flags += {.Is_Reply}
        envelope.tag = local_msg.tag
        envelope.payload_size = local_msg.body.user.payload_size
        copy(envelope.payload[:], local_msg.body.user.payload[:])

        _route_envelope(shard, ctx.current_message_source, &envelope)

    case Effect_Io:
        err := reactor_submit_io(&shard.reactor, shard, ctx.self_handle, e.operation)
        if err != IO_ERR_NONE {
            if err == IO_ERR_RESOURCE_EXHAUSTED do shard.counters.io_buffer_exhaustions += 1
            soa_meta[slot].io_completion_tag = _io_op_to_completion_tag(e.operation)
            soa_meta[slot].io_result = -i32(err)
            soa_meta[slot].io_buffer_index = BUFFER_INDEX_NONE
            soa_meta[slot].state = .Runnable
        } else {
            soa_meta[slot].state = .Waiting_For_Io
        }
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
        shard.kill_requested = true
    } else {
        group_handle := make_handle(shard.id, HANDLE_TYPE_ID_SUBGROUP, u32(group.group_index), 0)
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
    spec.handoff_fd = FD_HANDLE_NONE
    spec.handoff_mode = .Full

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
                    handoff_fd = FD_HANDLE_NONE,
                    handoff_mode = .Full,
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
                sub_handle := make_handle(shard.id, HANDLE_TYPE_ID_SUBGROUP, u32(sub_index), 0)
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

@(private="package")
shard_mass_teardown :: proc(shard: ^Shard) {
    log_flush(shard)

    // 1. Reset Pools (Message & Transfer)
    shard.message_pool.free_count = shard.message_pool.slot_count
    shard.message_pool.free_head = POOL_NONE_INDEX
    for i := int(shard.message_pool.slot_count) - 1; i >= 0; i -= 1 {
        ptr := pool_get_ptr(&shard.message_pool, u32(i))
        (cast(^u32)ptr)^ = shard.message_pool.free_head
        shard.message_pool.free_head = u32(i)
    }

    shard.transfer_pool.free_count = shard.transfer_pool.slot_count
    shard.transfer_pool.free_head = BUFFER_INDEX_NONE
    for i := int(shard.transfer_pool.slot_count) - 1; i >= 0; i -= 1 {
        ptr := reactor_buffer_pool_slot_ptr(&shard.transfer_pool, u16(i))
        (cast(^u16)ptr)^ = shard.transfer_pool.free_head
        shard.transfer_pool.free_head = u16(i)
        shard.transfer_generations[i] += 1
    }

    for i in 0..<shard.reactor.fd_table.slot_count {
        entry := &shard.reactor.fd_table.entries[i]

        if entry.read_owner != HANDLE_NONE || entry.write_owner != HANDLE_NONE {
            backend_control_close(&shard.reactor.backend, entry.os_fd)
            fd_handle := fd_handle_make(u16(i), entry.generation)
            fd_table_free(&shard.reactor.fd_table, fd_handle)
        }
    }

    for type_desc in shard.type_descriptors {
        type_id := type_desc.id
        soa_meta := shard.metadata[type_id]

        for slot in 0..<type_desc.slot_count {
            new_generation := (soa_meta[slot].generation + 1) & 0x0FFFFFFF
            if new_generation == 0 do new_generation = 1

            soa_meta[slot].generation = new_generation
            soa_meta[slot].state = .Unallocated
            soa_meta[slot].inbox_count = 0
            soa_meta[slot].inbox_head = POOL_NONE_INDEX
            soa_meta[slot].inbox_tail = POOL_NONE_INDEX
            soa_meta[slot].pending_correlation = 0
            soa_meta[slot].pending_transfer_read = TRANSFER_HANDLE_NONE
            soa_meta[slot].io_completion_tag = IO_TAG_NONE
            soa_meta[slot].working_arena_offset = 0
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
