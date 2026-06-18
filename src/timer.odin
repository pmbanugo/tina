package tina

import "base:intrinsics"
import "core:testing"

TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT :: #config(TINA_TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT, 256)

Timer_Handle :: distinct u32
TIMER_HANDLE_NONE :: Timer_Handle(0xFFFF_FFFF)

// Marks an unarmed or never-expiring slot.
TIMER_DEADLINE_NONE :: max(u64)

// High bit of the deadline distinguishes reserved (renewable) from one-shot.
// When set, the slot survives expiration (the caller must release it explicitly).
// When clear, the slot is auto-freed on expiration.
TIMER_RESERVED_BIT :: u64(1 << 63)

// Masks out the reserved bit to extract the actual deadline for comparison.
TIMER_DEADLINE_MASK :: ~TIMER_RESERVED_BIT


Timer_Wheel :: struct {
	// SoA parallel arrays — indexed by slot index
	deadlines:         []u64,
	targets:           []Isolate_Handle,
	tags:              []Message_Tag,
	correlations:      []Correlation_Id,

	// Bitmap: bit N = slot N is armed
	armed_words:       []u64,

	// Lifecycle
	free_head:         u32,
	capacity:          u32,
	armed_count:       u32,
	earliest_deadline: u64,
}

timer_wheel_init :: proc(
	wheel: ^Timer_Wheel,
	deadline_backing: []u64,
	target_backing: []Isolate_Handle,
	tag_backing: []Message_Tag,
	correlation_backing: []Correlation_Id,
	armed_words_backing: []u64,
) {
	wheel.deadlines = deadline_backing
	wheel.targets = target_backing
	wheel.tags = tag_backing
	wheel.correlations = correlation_backing
	wheel.armed_words = armed_words_backing
	wheel.capacity = u32(len(deadline_backing))
	wheel.armed_count = 0
	wheel.earliest_deadline = max(u64)
	wheel.free_head = POOL_NONE_INDEX

	// Zero the armed bitmap
	for i in 0 ..< len(armed_words_backing) {
		wheel.armed_words[i] = 0
	}

	// Build intrusive LIFO free list through deadlines[].
	// Iterate backwards so slot 0 ends up as the head.
	for i := int(wheel.capacity) - 1; i >= 0; i -= 1 {
		wheel.deadlines[i] = u64(wheel.free_head)
		wheel.free_head = u32(i)
	}
}

@(private = "package")
timer_wheel_reset :: proc(wheel: ^Timer_Wheel) {
	// Zero the armed bitmap
	for i in 0 ..< len(wheel.armed_words) {
		wheel.armed_words[i] = 0
	}
	wheel.armed_count = 0
	wheel.earliest_deadline = max(u64)

	// Rebuild intrusive LIFO free list through deadlines[]
	wheel.free_head = POOL_NONE_INDEX
	for i := int(wheel.capacity) - 1; i >= 0; i -= 1 {
		wheel.deadlines[i] = u64(wheel.free_head)
		wheel.free_head = u32(i)
	}
}

// Reserve a slot for a renewable timer. The slot is allocated but not armed.
// The caller must later call timer_rearm to arm it, and timer_release to free it.
@(private = "package")
timer_acquire :: proc(
	wheel: ^Timer_Wheel,
	target: Isolate_Handle,
) -> Timer_Handle {
	if wheel.free_head == POOL_NONE_INDEX {
		return TIMER_HANDLE_NONE
	}

	index := wheel.free_head
	wheel.free_head = u32(wheel.deadlines[index])

	// Mark as reserved but not armed (TIMER_DEADLINE_NONE already has bit 63 set)
	wheel.deadlines[index] = TIMER_DEADLINE_NONE | TIMER_RESERVED_BIT
	wheel.targets[index] = target
	wheel.tags[index] = Message_Tag(0)
	wheel.correlations[index] = Correlation_Id(0)

	// Ensure armed bit is cleared
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	wheel.armed_words[word_index] &= ~bit_mask

	return Timer_Handle(index)
}

// Schedule a one-shot timer. The slot is auto-freed on expiration.
@(private = "package")
timer_schedule :: proc(
	wheel: ^Timer_Wheel,
	deadline: u64,
	target: Isolate_Handle,
	tag: Message_Tag,
	correlation: Correlation_Id,
) -> Timer_Handle {
	if wheel.free_head == POOL_NONE_INDEX {
		return TIMER_HANDLE_NONE
	}

	index := wheel.free_head
	wheel.free_head = u32(wheel.deadlines[index])

	// Store deadline without TIMER_RESERVED_BIT — marks this as one-shot (auto-free on expiration)
	wheel.deadlines[index] = deadline & TIMER_DEADLINE_MASK
	wheel.targets[index] = target
	wheel.tags[index] = tag
	wheel.correlations[index] = correlation

	// Set armed bit
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	wheel.armed_words[word_index] |= bit_mask
	wheel.armed_count += 1

	if deadline < wheel.earliest_deadline {
		wheel.earliest_deadline = deadline
	}

	return Timer_Handle(index)
}

// Re-arm a reserved timer with a new deadline, tag, and correlation.
@(private = "package")
timer_rearm :: proc(
	wheel: ^Timer_Wheel,
	handle: Timer_Handle,
	deadline: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	if handle == TIMER_HANDLE_NONE {
		return
	}
	index := u32(handle)
	if index >= wheel.capacity {
		return
	}

	// Preserve the RESERVED_BIT so the slot survives expiration
	wheel.deadlines[index] = deadline | TIMER_RESERVED_BIT
	wheel.tags[index] = tag
	wheel.correlations[index] = correlation

	// Set armed bit if not already set
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	if (wheel.armed_words[word_index] & bit_mask) == 0 {
		wheel.armed_words[word_index] |= bit_mask
		wheel.armed_count += 1
	}

	masked_deadline := deadline & TIMER_DEADLINE_MASK
	if masked_deadline < wheel.earliest_deadline {
		wheel.earliest_deadline = masked_deadline
	}
}

// Disarm a reserved timer without releasing the slot.
@(private = "package")
timer_cancel :: proc(
	wheel: ^Timer_Wheel,
	handle: Timer_Handle,
) {
	if handle == TIMER_HANDLE_NONE {
		return
	}
	index := u32(handle)
	if index >= wheel.capacity {
		return
	}

	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	if (wheel.armed_words[word_index] & bit_mask) != 0 {
		wheel.armed_words[word_index] &= ~bit_mask
		wheel.armed_count -= 1
	}
}

// Release a reserved slot back to the free list.
// If the timer was armed, it is disarmed first.
@(private = "package")
timer_release :: proc(
	wheel: ^Timer_Wheel,
	handle: Timer_Handle,
) {
	if handle == TIMER_HANDLE_NONE {
		return
	}
	index := u32(handle)
	if index >= wheel.capacity {
		return
	}

	// Disarm if armed
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	if (wheel.armed_words[word_index] & bit_mask) != 0 {
		wheel.armed_words[word_index] &= ~bit_mask
		wheel.armed_count -= 1
	}

	// Clear fields
	wheel.targets[index] = ISOLATE_HANDLE_NONE
	wheel.tags[index] = Message_Tag(0)
	wheel.correlations[index] = Correlation_Id(0)

	// Push index onto free list
	wheel.deadlines[index] = u64(wheel.free_head)
	wheel.free_head = index
}

// Cancel and release a one-shot timer in a single operation.
@(private = "package")
timer_cancel_and_release :: proc(
	wheel: ^Timer_Wheel,
	handle: Timer_Handle,
) {
	if handle == TIMER_HANDLE_NONE {
		return
	}
	index := u32(handle)
	if index >= wheel.capacity {
		return
	}

	// Disarm if armed
	word_index := bitmap_word_index_from_bit_index(index)
	bit_mask := bitmap_mask_from_bit_index(index)
	if (wheel.armed_words[word_index] & bit_mask) != 0 {
		wheel.armed_words[word_index] &= ~bit_mask
		wheel.armed_count -= 1
	}

	// Push index onto free list
	wheel.deadlines[index] = u64(wheel.free_head)
	wheel.free_head = index
}

// Registers a one-shot timer that will enqueue a message with the specified tag
// back to this Isolate. The duration is specified in nanoseconds.
ctx_register_timer :: proc(duration_ns: u64, tag: Message_Tag) {
	shard, frame := _current_isolate_turn_frame_require_handle()
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		_shard_log(
			shard,
			frame.isolate_handle,
			.ERROR,
			USER_LOG_TAG_BASE,
			transmute([]u8)string("Timer pool exhausted"),
		)
		return
	}
	timer_schedule(wheel, shard.current_tick + _duration_ns_to_ticks(duration_ns, shard.timer_resolution_ns), frame.isolate_handle, tag, CORRELATION_ID_NONE)
}

// Registers a one-shot timer with an explicit correlation token so the receiver
// can reject stale lazy-cancelled expirations in O(1).
ctx_register_timer_with_correlation :: proc(
	duration_ns: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	shard, frame := _current_isolate_turn_frame_require_handle()
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		_shard_log(
			shard,
			frame.isolate_handle,
			.ERROR,
			USER_LOG_TAG_BASE,
			transmute([]u8)string("Timer pool exhausted"),
		)
		return
	}
	timer_schedule(wheel, shard.current_tick + _duration_ns_to_ticks(duration_ns, shard.timer_resolution_ns), frame.isolate_handle, tag, correlation)
}

@(private = "package")
_register_system_timer :: proc(
	shard: ^Shard,
	target: Isolate_Handle,
	delay_ticks: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	wheel := &shard.timer_wheel
	if wheel.free_head == POOL_NONE_INDEX {
		panic("[PANIC] Timer pool exhausted! Isolate will deadlock.")
	}
	deadline_tick := shard.current_tick + delay_ticks
	timer_schedule(wheel, deadline_tick, target, tag, correlation)
}

// Unified timer sweep: scans the armed bitmap for expired deadlines.
// One-shot slots (RESERVED_BIT clear) are auto-freed on expiration.
// Reserved slots (RESERVED_BIT set) survive expiration — the caller must release them.
@(private = "package")
_advance_timers :: proc(
	shard: ^Shard,
	expirations_max: u32 = TIMER_EXPIRATIONS_PER_TICK_MAX_DEFAULT,
) {
	wheel := &shard.timer_wheel
	now_tick := shard.current_tick

	if wheel.armed_count == 0 {
		return
	}

	if now_tick < (wheel.earliest_deadline & TIMER_DEADLINE_MASK) {
		return
	}

	expirations: u32 = 0
	next_earliest_deadline: u64 = max(u64)
	finished := true

	for word_index in 0 ..< len(wheel.armed_words) {
		word := wheel.armed_words[word_index]
		for word != 0 {
			if expirations >= expirations_max {
				finished = false
				break
			}

			bit_index := u32(intrinsics.count_trailing_zeros(word))
			slot_index := bitmap_bit_index_from_word_index_and_word_bit_index(word_index, bit_index)

			raw_deadline := wheel.deadlines[slot_index]
			masked_deadline := raw_deadline & TIMER_DEADLINE_MASK

			if masked_deadline <= now_tick {
				// Expired — clear bit in the backing array and decrement count
				bit_mask := bitmap_mask_from_word_bit_index(bit_index)
				wheel.armed_words[word_index] &= ~bit_mask
				wheel.armed_count -= 1

				target := wheel.targets[slot_index]

				// Wake-if-waiting-for-io (same pattern as before):
				// Any timer expiration targeting an Isolate in Wait_Io
				// wakes it via io_sequence bump.
				{
					target_type := extract_type_id(target)
					target_slot := extract_slot(target)
					target_gen := extract_generation(target)

					if int(target_type) < len(shard.metadata) &&
					   int(target_slot) < len(shard.metadata[target_type]) &&
					   shard.metadata[target_type][target_slot].generation == target_gen {
						soa_meta := shard.metadata[target_type]
						if soa_meta[target_slot]._state == .Wait_Io {
							soa_meta[target_slot].io_sequence += 1
							_slot_set_state(shard, target_type, target_slot, .Runnable)
						}
					}
				}

				envelope: Message_Envelope
				envelope.source = ISOLATE_HANDLE_NONE
				envelope.destination = target
				envelope.tag = wheel.tags[slot_index]
				envelope.correlation = wheel.correlations[slot_index]

				_enqueue_system_msg(shard, target, &envelope)
				expirations += 1

				// Auto-free check: if not reserved (one-shot), push slot to free list
				if (raw_deadline & TIMER_RESERVED_BIT) == 0 {
					wheel.deadlines[slot_index] = u64(wheel.free_head)
					wheel.free_head = slot_index
				}

				word &= word - 1
			} else {
				// Not expired — track next earliest deadline
				if masked_deadline < next_earliest_deadline {
					next_earliest_deadline = masked_deadline
				}
				word &= word - 1
			}
		}
		if !finished {
			break
		}
	}

	if finished {
		wheel.earliest_deadline = next_earliest_deadline
	} else {
		// Budget exhausted before finishing scan. Force a rescan on the next tick.
		wheel.earliest_deadline = now_tick
	}

	when TINA_RUNTIME_ASSERTIONS {
		expected_armed_count: u32 = 0
		for w in wheel.armed_words {
			expected_armed_count += u32(intrinsics.count_ones(w))
		}
		assert(
			wheel.armed_count == expected_armed_count,
			"armed_count drift detected: armed_count does not match bitmap popcount",
		)
	}
}

// O(N) bitmap scan to find the earliest armed deadline.
// Simulation-only — erased from production to prevent accidental hot-path usage.
when TINA_SIMULATION_MODE {
	@(private = "package")
	timer_earliest_deadline :: proc(wheel: ^Timer_Wheel) -> u64 {
		if wheel.armed_count == 0 do return max(u64)

		earliest: u64 = max(u64)
		for word_index in 0 ..< len(wheel.armed_words) {
			word := wheel.armed_words[word_index]
			for word != 0 {
				bit_index := u32(intrinsics.count_trailing_zeros(word))
				slot_index := bitmap_bit_index_from_word_index_and_word_bit_index(word_index, bit_index)
				raw_deadline := wheel.deadlines[slot_index] & TIMER_DEADLINE_MASK
				if raw_deadline < earliest {
					earliest = raw_deadline
				}
				word &= word - 1
			}
		}
		return earliest
	}
}

// ===========================================================================
// Tests
// ===========================================================================

@(test)
test_renewable_deadline_arms_and_expires :: proc(t: ^testing.T) {
	Arm_And_Expire_Test_State :: struct {
		t:      ^testing.T,
		handle: Isolate_Handle,
	}
	test_state := Arm_And_Expire_Test_State {
		t      = t,
		handle = make_handle(0, 1, 0, 1),
	}

	message_count, message := test_with_local_turn_frame(
		Test_Local_Turn_Frame_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 5,
			timer_resolution_ns = 1,
			target_state        = .Wait_Message,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Arm_And_Expire_Test_State)user_data
			shard, frame := _current_isolate_turn_frame()
			wheel := &shard.timer_wheel

			timer_handle := timer_acquire(wheel, frame.isolate_handle)
			testing.expect(
				state.t,
				timer_handle != TIMER_HANDLE_NONE,
				"timer should acquire",
			)
			timer_rearm(
				wheel,
				timer_handle,
				frame.current_tick + 5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(7),
				)

				shard.current_tick = 9
				_advance_timers(shard)
				soa_meta := shard.metadata[extract_type_id(state.handle)]
				testing.expect_value(
				state.t,
				soa_meta[extract_slot(state.handle)].inbox_count,
				u16(0),
				)

				shard.current_tick = 10
			_advance_timers(shard)

			timer_release(wheel, timer_handle)
		},
	)

	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, Message_Tag(USER_MESSAGE_TAG_BASE))
	testing.expect_value(t, message.correlation, Correlation_Id(7))
	testing.expect_value(t, message.user.source, ISOLATE_HANDLE_NONE)
}

@(test)
test_renewable_deadline_rearm_updates_deadline_and_payload :: proc(t: ^testing.T) {
	Rearm_Test_State :: struct {
		t:      ^testing.T,
		handle: Isolate_Handle,
	}
	test_state := Rearm_Test_State {
		t      = t,
		handle = make_handle(0, 1, 0, 1),
	}

	message_count, message := test_with_local_turn_frame(
		Test_Local_Turn_Frame_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 20,
			timer_resolution_ns = 1,
			target_state        = .Wait_Message,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Rearm_Test_State)user_data
			shard, frame := _current_isolate_turn_frame()
			wheel := &shard.timer_wheel

			timer_handle := timer_acquire(wheel, frame.isolate_handle)
			timer_rearm(
				wheel,
				timer_handle,
				frame.current_tick + 5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(1),
				)
				timer_rearm(
				wheel,
				timer_handle,
				frame.current_tick + 10,
				Message_Tag(USER_MESSAGE_TAG_BASE + 1),
				Correlation_Id(9),
				)

				shard.current_tick = 25
				_advance_timers(shard)
				soa_meta := shard.metadata[extract_type_id(state.handle)]
				testing.expect_value(
				state.t,
				soa_meta[extract_slot(state.handle)].inbox_count,
				u16(0),
				)

				shard.current_tick = 30
			_advance_timers(shard)

			timer_release(wheel, timer_handle)
		},
	)

	testing.expect_value(t, message_count, u16(1))
	testing.expect_value(t, message.tag, Message_Tag(USER_MESSAGE_TAG_BASE + 1))
	testing.expect_value(t, message.correlation, Correlation_Id(9))
}

@(test)
test_renewable_deadline_release_frees_slot_and_prevents_expiration :: proc(t: ^testing.T) {
	Release_Test_State :: struct {
		t:                   ^testing.T,
		handle:              Isolate_Handle,
		timer_handle_first:  Timer_Handle,
		timer_handle_second: Timer_Handle,
	}
	test_state := Release_Test_State {
		t                   = t,
		handle              = make_handle(0, 1, 0, 1),
		timer_handle_first  = TIMER_HANDLE_NONE,
		timer_handle_second = TIMER_HANDLE_NONE,
	}

	message_count, _ := test_with_local_turn_frame(
		Test_Local_Turn_Frame_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 100,
			timer_resolution_ns = 1,
			target_state        = .Wait_Message,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Release_Test_State)user_data
			shard, frame := _current_isolate_turn_frame()
			wheel := &shard.timer_wheel

			state.timer_handle_first = timer_acquire(wheel, frame.isolate_handle)
			timer_rearm(
				wheel,
				state.timer_handle_first,
				frame.current_tick + 5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(3),
				)
				timer_release(wheel, state.timer_handle_first)
				state.timer_handle_second = timer_acquire(wheel, frame.isolate_handle)
				timer_rearm(
				wheel,
				state.timer_handle_second,
				frame.current_tick + 7,
				Message_Tag(USER_MESSAGE_TAG_BASE + 2),
				Correlation_Id(4),
				)

				shard.current_tick = 106
				_advance_timers(shard)
				soa_meta := shard.metadata[extract_type_id(state.handle)]
				testing.expect_value(
				state.t,
				soa_meta[extract_slot(state.handle)].inbox_count,
				u16(0),
				)

				shard.current_tick = 107
			_advance_timers(shard)

			timer_release(wheel, state.timer_handle_second)
		},
	)

	testing.expect_value(t, test_state.timer_handle_first, test_state.timer_handle_second)
	testing.expect_value(t, message_count, u16(1))
}

@(test)
test_renewable_deadline_wakes_waiting_for_io_target :: proc(t: ^testing.T) {
	Wake_Test_State :: struct {
		handle:             Isolate_Handle,
		target_state:       Isolate_State,
		target_io_sequence: u8,
	}
	test_state := Wake_Test_State {
		handle = make_handle(0, 1, 0, 1),
	}

	message_count, _ := test_with_local_turn_frame(
		Test_Local_Turn_Frame_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 50,
			timer_resolution_ns = 1,
			target_state        = .Wait_Io,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Wake_Test_State)user_data
			shard, frame := _current_isolate_turn_frame()
			wheel := &shard.timer_wheel

			timer_handle := timer_acquire(wheel, frame.isolate_handle)
			timer_rearm(
				wheel,
				timer_handle,
				frame.current_tick + 5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(11),
				)

				shard.current_tick = 55
			_advance_timers(shard)

			soa_meta := shard.metadata[extract_type_id(state.handle)]
			state.target_state = soa_meta[extract_slot(state.handle)]._state
			state.target_io_sequence = soa_meta[extract_slot(state.handle)].io_sequence

			timer_release(wheel, timer_handle)
		},
	)

	testing.expect_value(t, test_state.target_state, Isolate_State.Runnable)
	testing.expect_value(t, test_state.target_io_sequence, u8(1))
	testing.expect_value(t, message_count, u16(1))
}

@(test)
test_renewable_deadline_same_word_mixed_expiry :: proc(t: ^testing.T) {
	Mixed_Expiry_Test_State :: struct {
		t:                   ^testing.T,
		handle:              Isolate_Handle,
		timer_handle_first:  Timer_Handle,
		timer_handle_second: Timer_Handle,
	}
	test_state := Mixed_Expiry_Test_State {
		t                   = t,
		handle              = make_handle(0, 1, 0, 1),
		timer_handle_first  = TIMER_HANDLE_NONE,
		timer_handle_second = TIMER_HANDLE_NONE,
	}

	message_count, message := test_with_local_turn_frame(
		Test_Local_Turn_Frame_Config {
			self_handle         = test_state.handle,
			target_handle       = test_state.handle,
			current_tick        = 100,
			timer_resolution_ns = 1,
			target_state        = .Wait_Message,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Mixed_Expiry_Test_State)user_data
			shard, frame := _current_isolate_turn_frame()
			wheel := &shard.timer_wheel

			// Both handles will map to the same 64-bit word of armed_words bitmap
			state.timer_handle_first = timer_acquire(wheel, frame.isolate_handle)
			state.timer_handle_second = timer_acquire(wheel, frame.isolate_handle)

			timer_rearm(
				wheel,
				state.timer_handle_first,
				frame.current_tick + 5,
				Message_Tag(USER_MESSAGE_TAG_BASE),
				Correlation_Id(3),
				)
				timer_rearm(
				wheel,
				state.timer_handle_second,
				frame.current_tick + 10,
				Message_Tag(USER_MESSAGE_TAG_BASE + 1),
				Correlation_Id(4),
				)

				// Advance past the first deadline but before the second
				shard.current_tick = 106
			_advance_timers(shard)

			// The first deadline should have fired, but the second must still be armed.
			word := wheel.armed_words[0]
			testing.expect(
				state.t,
				word != 0,
				"Second timer bit in armed_words was incorrectly cleared",
			)
			testing.expect_value(
				state.t,
				wheel.armed_count,
				u32(1),
			)

			// Now advance past the second deadline
			shard.current_tick = 111
			_advance_timers(shard)

			// Verify that the second timer has now also fired and count is zero
			testing.expect_value(
				state.t,
				wheel.armed_words[0],
				u64(0),
			)
			testing.expect_value(
				state.t,
				wheel.armed_count,
				u32(0),
			)

			timer_release(wheel, state.timer_handle_first)
			timer_release(wheel, state.timer_handle_second)
		},
	)

	// Since the callback ran two sweeps, first message is for timer_handle_first
	testing.expect_value(t, message.tag, Message_Tag(USER_MESSAGE_TAG_BASE))
	testing.expect_value(t, message.correlation, Correlation_Id(3))
}
