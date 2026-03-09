package tina

TIMER_WHEEL_SPOKE_COUNT :: 4096
TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT :: 256

Simulated_Clock :: struct {
    current_tick: u64,
}

Timer_Entry :: struct {
    deliver_at: u64,
    next: u32,
    correlation: u32,
    target: Handle,
    tag: Message_Tag,
}

Timer_Wheel :: struct {
    spokes:[TIMER_WHEEL_SPOKE_COUNT]u32,
    entries:[]Timer_Entry,
    last_tick: u64,
    free_head: u32,
}

timer_wheel_init :: proc(wheel: ^Timer_Wheel, backing:[]Timer_Entry) {
    for i in 0..<TIMER_WHEEL_SPOKE_COUNT {
        wheel.spokes[i] = POOL_NONE_INDEX
    }
    wheel.entries = backing
    wheel.free_head = POOL_NONE_INDEX

    // Intrusive LIFO pool setup
    for i := len(backing)-1; i >= 0; i -= 1 {
        wheel.entries[i].next = wheel.free_head
        wheel.free_head = u32(i)
    }
}

ctx_register_timer :: proc(ctx: ^TinaContext, delay_ticks: u64, tag: Message_Tag) {
    wheel := &ctx.shard.timer_wheel
    if wheel.free_head == POOL_NONE_INDEX {
        ctx_log(ctx, .ERROR, USER_LOG_TAG_BASE, transmute([]u8)string("Timer pool exhausted"))
        return
    }

    index := wheel.free_head
    wheel.free_head = wheel.entries[index].next

    deliver_at := ctx.shard.clock.current_tick + delay_ticks
    wheel.entries[index] = Timer_Entry{
        deliver_at = deliver_at,
        target = ctx.self_handle,
        tag = tag,
        next = POOL_NONE_INDEX,
    }

    // Fast power-of-two modulo
    spoke_index := deliver_at & (TIMER_WHEEL_SPOKE_COUNT - 1)
    wheel.entries[index].next = wheel.spokes[spoke_index]
    wheel.spokes[spoke_index] = index
}

@(private="package")
_register_system_timer :: proc(shard: ^Shard, target: Handle, delay_ticks: u64, tag: Message_Tag, correlation: u32) {
    wheel := &shard.timer_wheel
    // SAFETY CHECK: If timer pool is exhausted, we MUST not fail silently.
    // In production, we might drop, but for this test, we expect capacity.
    if wheel.free_head == POOL_NONE_INDEX {
        // Force a panic or error log to make debugging obvious
        // fmt.eprintln("[PANIC] Timer pool exhausted! Isolate will deadlock.")
        // return
        panic("[PANIC] Timer pool exhausted! Isolate will deadlock.")
    }

    index := wheel.free_head
    wheel.free_head = wheel.entries[index].next

    deliver_at := shard.clock.current_tick + delay_ticks
    wheel.entries[index] = Timer_Entry{
        deliver_at = deliver_at,
        target = target,
        tag = tag,
        correlation = correlation,
        next = POOL_NONE_INDEX,
    }

    spoke_index := deliver_at & (TIMER_WHEEL_SPOKE_COUNT - 1)
    wheel.entries[index].next = wheel.spokes[spoke_index]
    wheel.spokes[spoke_index] = index
}

@(private="package")
_advance_timers :: proc(shard: ^Shard, max_expirations: u32 = TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT) {
    now := shard.clock.current_tick
    expirations: u32 = 0

    tick_loop: for shard.timer_wheel.last_tick < now {
        if expirations >= max_expirations do break

        tick := shard.timer_wheel.last_tick + 1
        spoke_index := tick & (TIMER_WHEEL_SPOKE_COUNT - 1)
        curr := shard.timer_wheel.spokes[spoke_index]
        prev: u32 = POOL_NONE_INDEX

        spoke_finished := true

        for curr != POOL_NONE_INDEX {
            entry := &shard.timer_wheel.entries[curr]
            next := entry.next

            if entry.deliver_at > tick {
                prev = curr
                curr = next
                continue
            }

            if expirations >= max_expirations {
                spoke_finished = false
                break
            }

            // --- Timerwheel WAITING_FOR_IO Integration (§6.6.3 §12) ---
            target_type := extract_type_id(entry.target)
            target_slot := extract_slot(entry.target)
            target_gen  := extract_generation(entry.target)

            is_valid_target := int(target_type) < len(shard.metadata) &&
                               int(target_slot) < len(shard.metadata[target_type]) &&
                               shard.metadata[target_type][target_slot].generation == target_gen

            if is_valid_target {
                soa_meta := shard.metadata[target_type]
                if soa_meta[target_slot].state == .Waiting_For_Io {
                    // 1. Issue best-effort cancel to the reactor
                    reactor_cancel_active_io(&shard.reactor, shard, target_type, target_slot)

                    // 2. Increment io_sequence to structurally invalidate the in-flight completion
                    soa_meta[target_slot].io_sequence += 1

                    // 3. Transition to Runnable so it receives the timeout message
                    soa_meta[target_slot].state = .Runnable
                }
            }

            envelope: Message_Envelope
            envelope.source = HANDLE_NONE
            envelope.destination = entry.target
            envelope.tag = entry.tag
            envelope.correlation = entry.correlation

            // Deliver the timeout message
            _enqueue(shard, entry.target, &envelope)
            expirations += 1

            // Unlink from spoke
            if prev == POOL_NONE_INDEX {
                shard.timer_wheel.spokes[spoke_index] = next
            } else {
                shard.timer_wheel.entries[prev].next = next
            }

            // Push back onto the free list
            entry.next = shard.timer_wheel.free_head
            shard.timer_wheel.free_head = curr
            curr = next
        }

        if spoke_finished {
            shard.timer_wheel.last_tick = tick
        } else {
	        // Budget exhausted before we could finish evaluating this spoke.
	        // Do not advance last_tick so we resume this spoke on the next scheduler loop.
            break tick_loop
        }
    }
}
