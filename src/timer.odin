package tina

TIMER_WHEEL_SPOKE_COUNT :: 4096

Simulated_Clock :: struct {
    current_tick: u64,
}

Timer_Entry :: struct {
    deliver_at: u64,
    target: Handle,
    next: u32,
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
_advance_timers :: proc(shard: ^Shard) {
    now := shard.clock.current_tick
    for shard.timer_wheel.last_tick < now {
        shard.timer_wheel.last_tick += 1
        tick := shard.timer_wheel.last_tick

        spoke_index := tick & (TIMER_WHEEL_SPOKE_COUNT - 1)
        curr := shard.timer_wheel.spokes[spoke_index]
        prev: u32 = POOL_NONE_INDEX

        for curr != POOL_NONE_INDEX {
            entry := &shard.timer_wheel.entries[curr]
            next := entry.next

            if entry.deliver_at <= tick {
                env: Message_Envelope
                env.source = HANDLE_NONE
                env.destination = entry.target
                env.tag = entry.tag
                _enqueue(shard, entry.target, &env)

                if prev == POOL_NONE_INDEX {
                    shard.timer_wheel.spokes[spoke_index] = next
                } else {
                    shard.timer_wheel.entries[prev].next = next
                }

                entry.next = shard.timer_wheel.free_head
                shard.timer_wheel.free_head = curr
                curr = next
            } else {
                prev = curr; curr = next
            }
        }
    }
}
