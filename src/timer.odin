package tina

TIMER_DEFAULT_SPOKE_COUNT :: 4096
TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT :: 256

Timer_Entry :: struct {
	deliver_at:  u64,
	next:        u32,
	correlation: u32,
	target:      Handle,
	tag:         Message_Tag,
}

Timer_Wheel :: struct {
	spokes:         []u32,
	entries:        []Timer_Entry,
	spoke_mask:     u64,
	last_tick:      u64,
	free_head:      u32,
	resident_count: u32,
}

timer_wheel_init :: proc(
	wheel: ^Timer_Wheel,
	spoke_backing: []u32,
	entry_backing: []Timer_Entry,
	initial_tick: u64 = 0,
) {
	wheel.spokes = spoke_backing
	wheel.spoke_mask = u64(len(spoke_backing) - 1)
	wheel.entries = entry_backing
	wheel.last_tick = initial_tick
	wheel.free_head = POOL_NONE_INDEX
	wheel.resident_count = 0

	for i in 0 ..< len(spoke_backing) {
		wheel.spokes[i] = POOL_NONE_INDEX
	}

	// Intrusive LIFO pool setup
	for i := len(entry_backing) - 1; i >= 0; i -= 1 {
		wheel.entries[i].next = wheel.free_head
		wheel.free_head = u32(i)
	}
}

@(private = "package")
timer_wheel_reset :: proc(wheel: ^Timer_Wheel, current_tick: u64) {
	for i in 0 ..< len(wheel.spokes) {
		wheel.spokes[i] = POOL_NONE_INDEX
	}
	wheel.last_tick = current_tick
	wheel.free_head = POOL_NONE_INDEX
	wheel.resident_count = 0

	for i := len(wheel.entries) - 1; i >= 0; i -= 1 {
		wheel.entries[i].next = wheel.free_head
		wheel.free_head = u32(i)
	}
}

// Registers a timer that will enqueue a message with the specified tag back to this Isolate.
// The duration is specified in nanoseconds.
ctx_register_timer :: proc(ctx: ^TinaContext, duration_ns: u64, tag: Message_Tag) {
	shard := _ctx_extract_shard(ctx)
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		_shard_log(
			_ctx_extract_shard(ctx),
			ctx.self_handle,
			.ERROR,
			USER_LOG_TAG_BASE,
			transmute([]u8)string("Timer pool exhausted"),
		)
		return
	}
	// Convert nanoseconds to ticks
	delay_ticks := (duration_ns + shard.timer_resolution_ns - 1) / shard.timer_resolution_ns
	_timer_wheel_insert(wheel, shard.current_tick + delay_ticks, ctx.self_handle, tag, 0)
}

@(private = "package")
_register_system_timer :: proc(
	shard: ^Shard,
	target: Handle,
	delay_ticks: u64,
	tag: Message_Tag,
	correlation: u32,
) {
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		panic("[PANIC] Timer pool exhausted! Isolate will deadlock.")
	}
	_timer_wheel_insert(wheel, shard.current_tick + delay_ticks, target, tag, correlation)
}

@(private = "package")
_timer_wheel_insert :: #force_inline proc "contextless" (
	wheel: ^Timer_Wheel,
	deliver_at: u64,
	target: Handle,
	tag: Message_Tag,
	correlation: u32,
) {
	index := wheel.free_head
	wheel.free_head = wheel.entries[index].next

	wheel.entries[index] = Timer_Entry {
		deliver_at  = deliver_at,
		target      = target,
		tag         = tag,
		correlation = correlation,
		next        = POOL_NONE_INDEX,
	}

	spoke_index := deliver_at & wheel.spoke_mask
	wheel.entries[index].next = wheel.spokes[spoke_index]
	wheel.spokes[spoke_index] = index
	wheel.resident_count += 1
}

// FUTURE OPT: The envelope construction (128 bytes on stack) + _enqueue copy could be
// eliminated by allocating the pool slot first and writing directly into it. This avoids
// a 128-byte stack write + 128-byte memcpy per expiration. Requires changing _enqueue's
// interface to return a writable slot pointer, which has wider implications across the
// messaging subsystem. Measure timer expiration throughput before pursuing.
@(private = "package")
_advance_timers :: proc(
	shard: ^Shard,
	expirations_max: u32 = TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT,
) {
	wheel := &shard.timer_wheel
	now := shard.current_tick

	if wheel.resident_count == 0 {
		wheel.last_tick = now
		return
	}

	expirations: u32 = 0

	tick_loop: for wheel.last_tick < now {
		if expirations >= expirations_max do break

		tick := wheel.last_tick + 1
		spoke_index := tick & wheel.spoke_mask
		curr := wheel.spokes[spoke_index]
		prev: u32 = POOL_NONE_INDEX

		spoke_finished := true

		for curr != POOL_NONE_INDEX {
			entry := &wheel.entries[curr]
			next := entry.next

			if entry.deliver_at > tick {
				prev = curr
				curr = next
				continue
			}

			if expirations >= expirations_max {
				spoke_finished = false
				break
			}

			// --- WAITING_FOR_IO Integration (§6.6.3 §12) ---
			// Any timer expiration targeting an Isolate in Waiting_For_Io
			// wakes it via io_sequence bump. Not gated on tag —
			// user timers (e.g., CONNECT_TIMEOUT) must also wake I/O waiters.
			//
			// DESIGN NOTE — Why no backend_cancel:
			// The io_sequence field is the structural safety guarantee for stale
			// I/O completions. When we bump io_sequence here, the abandoned
			// operation's completion will eventually arrive at
			// reactor_collect_completions, fail the sequence check, and have
			// its buffer freed by the stale-path reclamation. This is
			// structurally safe regardless of platform cancel semantics:
			//   - io_uring: kernel delivers CQE (success or -ECANCELED) → stale path frees buffer
			//   - kqueue:   close() silently removes kevents, so _backend_control_close sweeps pending
			//               operations and synthesizes -ECANCELED completions → stale path frees buffers
			//   - SimulatedIO: operation completes on next tick_count advancement → stale path
			//
			// Explicit cancel was removed because it adds per-slot state
			// (stored token) to the hot Isolate metadata for a control-plane
			// operation that the existing structural guarantee already handles.
			// The only cost: the buffer stays allocated until the backend
			// naturally completes the stale operation (bounded, typically
			// sub-millisecond). This is consistent with the ADR's statement:
			// "structural safety does not depend on [backend_cancel]" (§6.6.3 §12, GRACEFUL_SHUTDOWN §3.4).
			{
				target_type := extract_type_id(entry.target)
				target_slot := extract_slot(entry.target)
				target_gen := extract_generation(entry.target)

				if int(target_type) < len(shard.metadata) &&
				   int(target_slot) < len(shard.metadata[target_type]) &&
				   shard.metadata[target_type][target_slot].generation == target_gen {
					soa_meta := shard.metadata[target_type]
					if soa_meta[target_slot].state == .Waiting_For_Io {
						soa_meta[target_slot].io_sequence += 1
						soa_meta[target_slot].state = .Runnable
					}
				}
			}

			envelope: Message_Envelope
			envelope.source = HANDLE_NONE
			envelope.destination = entry.target
			envelope.tag = entry.tag
			envelope.correlation = entry.correlation

			_enqueue_system_msg(shard, entry.target, &envelope)
			expirations += 1

			// Unlink from spoke
			if prev == POOL_NONE_INDEX {
				wheel.spokes[spoke_index] = next
			} else {
				wheel.entries[prev].next = next
			}

			// Push back onto the free list
			entry.next = wheel.free_head
			wheel.free_head = curr
			wheel.resident_count -= 1
			curr = next
		}

		if spoke_finished {
			wheel.last_tick = tick
		} else {
			// Budget exhausted before we could finish evaluating this spoke.
			// Do not advance last_tick so we resume this spoke on the next scheduler loop.
			break tick_loop
		}
	}
}

// O(N) scan to find the earliest deadline across the hashed wheel.
// Erased from production to prevent accidental hot-path usage.
when TINA_SIMULATION_MODE {
	@(private = "package")
	timer_wheel_earliest_deadline :: proc(wheel: ^Timer_Wheel) -> u64 {
		if wheel.resident_count == 0 do return max(u64)

		earliest: u64 = max(u64)
		for spoke in wheel.spokes {
			current := spoke
			for current != POOL_NONE_INDEX {
				entry := &wheel.entries[current]
				if entry.deliver_at < earliest {
					earliest = entry.deliver_at
				}
				current = entry.next
			}
		}
		return earliest
	}
}
