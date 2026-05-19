package tina

import "base:intrinsics"
import "core:testing"

TIMER_DEFAULT_SPOKE_COUNT :: 4096 // TODO: make this configuration via compile/build flag
TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT :: 256 // TODO: make this configuration via compile/build flag

Timer_Handle :: distinct u32
TIMER_HANDLE_NONE :: Timer_Handle(0xFFFF_FFFF)

Timer_Entry :: struct {
	deliver_at:  u64,
	next:        u32,
	correlation: Correlation_Id,
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

	// --- Renewable deadlines ---
	renewable_deliver_at:  []u64,
	renewable_target:      []Handle,
	renewable_tag:         []Message_Tag,
	renewable_correlation: []Correlation_Id,
	renewable_armed_words: []u64,          // bit N = slot N is armed
	renewable_free_head:   u32,
	renewable_capacity:    u32,
	renewable_armed_count: u32,
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
	wheel.renewable_free_head = POOL_NONE_INDEX
	wheel.renewable_capacity = 0
	wheel.renewable_armed_count = 0

	for i in 0 ..< len(spoke_backing) {
		wheel.spokes[i] = POOL_NONE_INDEX
	}

	// Intrusive LIFO pool setup
	for i := len(entry_backing) - 1; i >= 0; i -= 1 {
		wheel.entries[i].next = wheel.free_head
		wheel.free_head = u32(i)
	}
}

timer_wheel_init_renewable :: proc(
	wheel: ^Timer_Wheel,
	deliver_at_backing: []u64,
	target_backing: []Handle,
	tag_backing: []Message_Tag,
	correlation_backing: []Correlation_Id,
	armed_words_backing: []u64,
) {
	capacity := u32(len(deliver_at_backing))
	wheel.renewable_deliver_at = deliver_at_backing
	wheel.renewable_target = target_backing
	wheel.renewable_tag = tag_backing
	wheel.renewable_correlation = correlation_backing
	wheel.renewable_armed_words = armed_words_backing
	wheel.renewable_capacity = capacity
	wheel.renewable_armed_count = 0
	wheel.renewable_free_head = POOL_NONE_INDEX

	// Zero the armed bitmap
	for i in 0 ..< len(armed_words_backing) {
		wheel.renewable_armed_words[i] = 0
	}

	// Build intrusive LIFO free list through deliver_at field
	for i := int(capacity) - 1; i >= 0; i -= 1 {
		wheel.renewable_deliver_at[i] = u64(wheel.renewable_free_head)
		wheel.renewable_free_head = u32(i)
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

	// Reset renewable deadlines
	for i in 0 ..< len(wheel.renewable_armed_words) {
		wheel.renewable_armed_words[i] = 0
	}
	wheel.renewable_armed_count = 0
	wheel.renewable_free_head = POOL_NONE_INDEX
	for i := int(wheel.renewable_capacity) - 1; i >= 0; i -= 1 {
		wheel.renewable_deliver_at[i] = u64(wheel.renewable_free_head)
		wheel.renewable_free_head = u32(i)
	}
}

// Registers a timer that will enqueue a message with the specified tag back to this Isolate.
// The duration is specified in nanoseconds.
ctx_register_timer :: proc(ctx: TinaContext, duration_ns: u64, tag: Message_Tag) {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		_shard_log(
			shard,
			invocation.self_handle,
			.ERROR,
			USER_LOG_TAG_BASE,
			transmute([]u8)string("Timer pool exhausted"),
		)
		return
	}
	// Convert nanoseconds to ticks
	delay_ticks := (duration_ns + shard.timer_resolution_ns - 1) / shard.timer_resolution_ns
	_timer_wheel_insert(wheel, shard.current_tick + delay_ticks, invocation.self_handle, tag, CORRELATION_ID_NONE)
}

// Registers a timer with an explicit correlation token so the receiver can
// reject stale lazy-cancelled expirations in O(1).
ctx_register_timer_with_correlation :: proc(
	ctx: TinaContext,
	duration_ns: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		_shard_log(
			shard,
			invocation.self_handle,
			.ERROR,
			USER_LOG_TAG_BASE,
			transmute([]u8)string("Timer pool exhausted"),
		)
		return
	}

	// Convert nanoseconds to ticks.
	delay_ticks := (duration_ns + shard.timer_resolution_ns - 1) / shard.timer_resolution_ns
	_timer_wheel_insert(wheel, shard.current_tick + delay_ticks, invocation.self_handle, tag, correlation)
}

@(private = "package")
_register_system_timer :: proc(
	shard: ^Shard,
	target: Handle,
	delay_ticks: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
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
	correlation: Correlation_Id,
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

@(private = "package")
timer_arm_renewable :: proc(
	wheel: ^Timer_Wheel,
	target: Handle,
	deliver_at: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) -> Timer_Handle {
	if wheel.renewable_free_head == POOL_NONE_INDEX {
		return TIMER_HANDLE_NONE
	}

	index := wheel.renewable_free_head
	wheel.renewable_free_head = u32(wheel.renewable_deliver_at[index])

	wheel.renewable_deliver_at[index] = deliver_at
	wheel.renewable_target[index] = target
	wheel.renewable_tag[index] = tag
	wheel.renewable_correlation[index] = correlation

	// Set bit in armed bitmap
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	wheel.renewable_armed_words[word_index] |= bit_mask
	wheel.renewable_armed_count += 1

	return Timer_Handle(index)
}

@(private = "package")
timer_rearm_renewable :: proc(
	wheel: ^Timer_Wheel,
	handle: Timer_Handle,
	deliver_at: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	index := u32(handle)
	wheel.renewable_deliver_at[index] = deliver_at
	wheel.renewable_tag[index] = tag
	wheel.renewable_correlation[index] = correlation
	// Target does not change — same connection.
	// Bit is already set in renewable_armed_words — no bitmap manipulation.
}

@(private = "package")
timer_cancel_renewable :: proc(
	wheel: ^Timer_Wheel,
	handle: Timer_Handle,
) {
	index := u32(handle)

	// Clear bit in armed bitmap
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	wheel.renewable_armed_words[word_index] &= ~bit_mask
	wheel.renewable_armed_count -= 1

	// Push index onto free list
	wheel.renewable_deliver_at[index] = u64(wheel.renewable_free_head)
	wheel.renewable_free_head = index
}

// POSSIBLE OPTIMISATION: The envelope construction (128 bytes on stack) + _enqueue copy could be
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
						_slot_set_state(shard, target_type, target_slot, .Runnable)
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

	// --- Renewable deadline sweep ---
	// Scans the armed bitmap for expired renewable deadlines.
	// Shares the expirations_max budget with the one-shot tick loop above.
	if wheel.renewable_armed_count == 0 || expirations >= expirations_max {
		return
	}

	now_ns := shard.current_time_ns

	for word_index in 0 ..< len(wheel.renewable_armed_words) {
		word := wheel.renewable_armed_words[word_index]
		for word != 0 {
			if expirations >= expirations_max do return

			bit_index := u32(intrinsics.count_trailing_zeros(word))
			slot_index := bitmap_bit_index_from_word_index_and_word_bit_index(word_index, bit_index)

			if wheel.renewable_deliver_at[slot_index] <= now_ns {
				// Clear bit in word and in the backing array
				word &= word - 1
				wheel.renewable_armed_words[word_index] = word
				wheel.renewable_armed_count -= 1

				target := wheel.renewable_target[slot_index]

				// Wake-if-waiting-for-io (same pattern as one-shot timers)
				{
					target_type := extract_type_id(target)
					target_slot := extract_slot(target)
					target_gen := extract_generation(target)

					if int(target_type) < len(shard.metadata) &&
					   int(target_slot) < len(shard.metadata[target_type]) &&
					   shard.metadata[target_type][target_slot].generation == target_gen {
						soa_meta := shard.metadata[target_type]
						if soa_meta[target_slot].state == .Waiting_For_Io {
							soa_meta[target_slot].io_sequence += 1
							_slot_set_state(shard, target_type, target_slot, .Runnable)
						}
					}
				}

				envelope: Message_Envelope
				envelope.source = HANDLE_NONE
				envelope.destination = target
				envelope.tag = wheel.renewable_tag[slot_index]
				envelope.correlation = wheel.renewable_correlation[slot_index]

				_enqueue_system_msg(shard, target, &envelope)
				expirations += 1

				// Push slot onto free list
				wheel.renewable_deliver_at[slot_index] = u64(wheel.renewable_free_head)
				wheel.renewable_free_head = slot_index
			} else {
				// Not expired — clear this bit from the local word to continue scanning
				word &= word - 1
			}
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

	@(private = "package")
	timer_renewable_earliest_deadline :: proc(wheel: ^Timer_Wheel) -> u64 {
		if wheel.renewable_armed_count == 0 do return max(u64)

		earliest: u64 = max(u64)
		for word_index in 0 ..< len(wheel.renewable_armed_words) {
			word := wheel.renewable_armed_words[word_index]
			for word != 0 {
				bit_index := u32(intrinsics.count_trailing_zeros(word))
				slot_index := bitmap_bit_index_from_word_index_and_word_bit_index(word_index, bit_index)
				if wheel.renewable_deliver_at[slot_index] < earliest {
					earliest = wheel.renewable_deliver_at[slot_index]
				}
				word &= word - 1
			}
		}
		return earliest
	}
}

@(test)
test_renewable_deadline_arms_and_expires :: proc(t: ^testing.T) {
	Arm_And_Expire_Test_State :: struct {
		t:      ^testing.T,
		handle: Handle,
	}
	test_state := Arm_And_Expire_Test_State {
		t      = t,
		handle = make_handle(0, 1, 0, 1),
	}

	message_count, message := test_with_local_context(
		Test_Local_Context_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 5,
			timer_resolution_ns = 1,
			target_state        = .Waiting,
		},
		rawptr(&test_state),
		proc(user_data: rawptr, ctx: TinaContext) {
			state := cast(^Arm_And_Expire_Test_State)user_data
			invocation := ctx_invocation(ctx)
			timer_handle := ctx_arm_renewable_deadline(
				ctx,
				5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(7),
			)
			testing.expect(
				state.t,
				timer_handle != TIMER_HANDLE_NONE,
				"renewable deadline should arm",
			)

			invocation.shard.current_tick = 9
			invocation.shard.current_time_ns = 9
			_advance_timers(invocation.shard)
			soa_meta := invocation.shard.metadata[extract_type_id(state.handle)]
			testing.expect_value(
				state.t,
				soa_meta[extract_slot(state.handle)].inbox_count,
				u16(0),
			)

			invocation.shard.current_tick = 10
			invocation.shard.current_time_ns = 10
			_advance_timers(invocation.shard)
		},
	)

	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, Message_Tag(USER_MESSAGE_TAG_BASE))
	testing.expect_value(t, message.correlation, Correlation_Id(7))
	testing.expect_value(t, message.user.source, HANDLE_NONE)
}

@(test)
test_renewable_deadline_rearm_updates_deadline_and_payload :: proc(t: ^testing.T) {
	Rearm_Test_State :: struct {
		t:      ^testing.T,
		handle: Handle,
	}
	test_state := Rearm_Test_State {
		t      = t,
		handle = make_handle(0, 1, 0, 1),
	}

	message_count, message := test_with_local_context(
		Test_Local_Context_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 20,
			timer_resolution_ns = 1,
			target_state        = .Waiting,
		},
		rawptr(&test_state),
		proc(user_data: rawptr, ctx: TinaContext) {
			state := cast(^Rearm_Test_State)user_data
			invocation := ctx_invocation(ctx)
			timer_handle := ctx_arm_renewable_deadline(
				ctx,
				5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(1),
			)
			ctx_rearm_renewable_deadline(
				ctx,
				timer_handle,
				10,
				Message_Tag(USER_MESSAGE_TAG_BASE + 1),
				Correlation_Id(9),
			)

			invocation.shard.current_tick = 25
			invocation.shard.current_time_ns = 25
			_advance_timers(invocation.shard)
			soa_meta := invocation.shard.metadata[extract_type_id(state.handle)]
			testing.expect_value(
				state.t,
				soa_meta[extract_slot(state.handle)].inbox_count,
				u16(0),
			)

			invocation.shard.current_tick = 30
			invocation.shard.current_time_ns = 30
			_advance_timers(invocation.shard)
		},
	)

	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, Message_Tag(USER_MESSAGE_TAG_BASE + 1))
	testing.expect_value(t, message.correlation, Correlation_Id(9))
}

@(test)
test_renewable_deadline_cancel_frees_slot_and_prevents_expiration :: proc(t: ^testing.T) {
	Cancel_Test_State :: struct {
		t:                   ^testing.T,
		handle:              Handle,
		timer_handle_first:  Timer_Handle,
		timer_handle_second: Timer_Handle,
	}
	test_state := Cancel_Test_State {
		t                  = t,
		handle             = make_handle(0, 1, 0, 1),
		timer_handle_first = TIMER_HANDLE_NONE,
		timer_handle_second = TIMER_HANDLE_NONE,
	}

	message_count, _ := test_with_local_context(
		Test_Local_Context_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 100,
			timer_resolution_ns = 1,
			target_state        = .Waiting,
		},
		rawptr(&test_state),
		proc(user_data: rawptr, ctx: TinaContext) {
			state := cast(^Cancel_Test_State)user_data
			invocation := ctx_invocation(ctx)
			state.timer_handle_first = ctx_arm_renewable_deadline(
				ctx,
				5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(3),
			)
			ctx_cancel_renewable_deadline(ctx, state.timer_handle_first)
			state.timer_handle_second = ctx_arm_renewable_deadline(
				ctx,
				7,
				Message_Tag(USER_MESSAGE_TAG_BASE + 2),
				Correlation_Id(4),
			)

			invocation.shard.current_tick = 106
			invocation.shard.current_time_ns = 106
			_advance_timers(invocation.shard)
			soa_meta := invocation.shard.metadata[extract_type_id(state.handle)]
			testing.expect_value(
				state.t,
				soa_meta[extract_slot(state.handle)].inbox_count,
				u16(0),
			)

			invocation.shard.current_tick = 107
			invocation.shard.current_time_ns = 107
			_advance_timers(invocation.shard)
		},
	)

	testing.expect_value(t, test_state.timer_handle_first, test_state.timer_handle_second)
	testing.expect_value(t, message_count, u16(1))
}

@(test)
test_renewable_deadline_wakes_waiting_for_io_target :: proc(t: ^testing.T) {
	Wake_Test_State :: struct {
		handle:             Handle,
		target_state:       Isolate_State,
		target_io_sequence: u8,
	}
	test_state := Wake_Test_State {
		handle = make_handle(0, 1, 0, 1),
	}

	message_count, _ := test_with_local_context(
		Test_Local_Context_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 50,
			timer_resolution_ns = 1,
			target_state        = .Waiting_For_Io,
		},
		rawptr(&test_state),
		proc(user_data: rawptr, ctx: TinaContext) {
			state := cast(^Wake_Test_State)user_data
			invocation := ctx_invocation(ctx)
			_ = ctx_arm_renewable_deadline(
				ctx,
				5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(11),
			)

			invocation.shard.current_tick = 55
			invocation.shard.current_time_ns = 55
			_advance_timers(invocation.shard)

			soa_meta := invocation.shard.metadata[extract_type_id(state.handle)]
			state.target_state = soa_meta[extract_slot(state.handle)].state
			state.target_io_sequence = soa_meta[extract_slot(state.handle)].io_sequence
		},
	)

	testing.expect_value(t, test_state.target_state, Isolate_State.Runnable)
	testing.expect_value(t, test_state.target_io_sequence, u8(1))
	testing.expect_value(t, message_count, u16(1))
}
