package tina

import "core:mem"
import "core:testing"

POOL_NONE_INDEX :: 0xFFFF_FFFF

Message_Pool :: struct {
	backing:        []Message_Envelope,
	slot_count:     u32,
	free_count:     u32,
	reserved_count: u32,
	free_head:      u32,
}

Pool_Stats :: struct {
	slot_count: u32,
	used_count: u32,
	free_count: u32,
}

Pool_Error :: enum u8 {
	None,
	Empty,
}

pool_init :: proc(
	p: ^Message_Pool,
	backing: []Message_Envelope,
	reserved_pct: f32 = 0.01,
) {
	p.backing = backing
	p.slot_count = u32(len(backing))
	p.free_count = 0
	p.free_head = POOL_NONE_INDEX

	// Calculate High-Water Mark for System Messages
	p.reserved_count = u32(f32(p.slot_count) * reserved_pct)
	if p.slot_count > 1 && p.reserved_count == 0 {
		p.reserved_count = 1
	}

	// Intrusive push. Slot 0 at the head for sequential cache warmth.
	for i := int(p.slot_count) - 1; i >= 0; i -= 1 {
		slot_pointer := &p.backing[i]
		slot_pointer.next_free_slot = p.free_head
		p.free_head = u32(i)
		p.free_count += 1
	}
}

@(private = "file")
_pool_alloc_unchecked :: #force_inline proc "contextless" (p: ^Message_Pool) -> u32 {
	slot_index := p.free_head
	slot_pointer := &p.backing[slot_index]
	p.free_head = slot_pointer.next_free_slot
	p.free_count -= 1
	mem.zero(slot_pointer, size_of(Message_Envelope))
	return slot_index
}

// User traffic Path (Respects High-Water Mark)
pool_alloc_user :: #force_inline proc "contextless" (p: ^Message_Pool) -> (u32, Pool_Error) {
	if p.free_count <= p.reserved_count do return POOL_NONE_INDEX, .Empty
	return _pool_alloc_unchecked(p), .None
}

// System traffic Path (Drains to zero)
pool_alloc_system :: #force_inline proc "contextless" (p: ^Message_Pool) -> (u32, Pool_Error) {
	if p.free_count == 0 do return POOL_NONE_INDEX, .Empty
	return _pool_alloc_unchecked(p), .None
}

// Frees a slot by its index. O(1).
pool_free :: proc(p: ^Message_Pool, index: u32) {
	assert(index < p.slot_count, "Message pool free index out of bounds")
	pool_free_unchecked(p, index)
}

// index validity is structurally guaranteed by the pool alloc/free lifecycle.
// Must remain contextless (no assert/fmt/make/default-allocator calls).
// intended use in hot path and guaranteed safety
pool_free_unchecked :: #force_inline proc "contextless" (p: ^Message_Pool, index: u32) {
	slot_pointer := &p.backing[index]
	slot_pointer.next_free_slot = p.free_head
	p.free_head = index
	p.free_count += 1
}

@(private = "package")
pool_reset :: proc "contextless" (p: ^Message_Pool) {
	p.free_count = p.slot_count
	p.free_head = POOL_NONE_INDEX
	for i := int(p.slot_count) - 1; i >= 0; i -= 1 {
		index := u32(i)
		slot_pointer := &p.backing[index]
		slot_pointer.next_free_slot = p.free_head
		p.free_head = index
	}
}

@(private = "package")
pool_init_tina_owned :: proc(
	p: ^Message_Pool,
	backing: []Message_Envelope,
	reserved_pct: f32 = 0.01,
) {
	pool_init(p, backing, reserved_pct)
	for index in 0 ..< p.slot_count {
		_sanitizer_address_poison_message_slot_payload(p, index)
	}
}

@(private = "package")
pool_alloc_user_tina_owned :: #force_inline proc "contextless" (p: ^Message_Pool) -> (u32, Pool_Error) {
	if p.free_count <= p.reserved_count do return POOL_NONE_INDEX, .Empty
	return pool_alloc_unchecked_tina_owned(p), .None
}

@(private = "package")
pool_alloc_system_tina_owned :: #force_inline proc "contextless" (p: ^Message_Pool) -> (u32, Pool_Error) {
	if p.free_count == 0 do return POOL_NONE_INDEX, .Empty
	return pool_alloc_unchecked_tina_owned(p), .None
}

@(private = "package")
pool_alloc_unchecked_tina_owned :: #force_inline proc "contextless" (p: ^Message_Pool) -> u32 {
	slot_index := p.free_head
	slot_pointer := &p.backing[slot_index]
	p.free_head = slot_pointer.next_free_slot
	_sanitizer_address_unpoison_message_slot(p, slot_index)
	p.free_count -= 1
	mem.zero(slot_pointer, size_of(Message_Envelope))
	return slot_index
}

@(private = "package")
pool_free_unchecked_tina_owned :: #force_inline proc "contextless" (p: ^Message_Pool, index: u32) {
	slot_pointer := &p.backing[index]
	slot_pointer.next_free_slot = p.free_head
	p.free_head = index
	p.free_count += 1
	_sanitizer_address_poison_message_slot_payload(p, index)
}

@(private = "package")
pool_reset_tina_owned :: proc "contextless" (p: ^Message_Pool) {
	p.free_count = p.slot_count
	p.free_head = POOL_NONE_INDEX
	for i := int(p.slot_count) - 1; i >= 0; i -= 1 {
		index := u32(i)
		_sanitizer_address_unpoison_message_slot(p, index)
		slot_pointer := &p.backing[index]
		slot_pointer.next_free_slot = p.free_head
		p.free_head = index
		_sanitizer_address_poison_message_slot_payload(p, index)
	}
}

// Resolves a pool index to its message envelope.
pool_get_ptr :: #force_inline proc(p: ^Message_Pool, index: u32) -> ^Message_Envelope {
	assert(index < p.slot_count, "Message pool ptr index out of bounds")
	return pool_get_ptr_unchecked(p, index)
}

// index validity is structurally guaranteed by prior alloc or mailbox traversal.
// Must remain contextless (no assert/fmt/make/default-allocator calls).
// intended use in hot path and guaranteed safety
pool_get_ptr_unchecked :: #force_inline proc "contextless" (
	p: ^Message_Pool,
	index: u32,
) -> ^Message_Envelope {
	return &p.backing[index]
}

pool_stats :: proc(p: ^Message_Pool) -> Pool_Stats {
	return Pool_Stats {
		slot_count = p.slot_count,
		free_count = p.free_count,
		used_count = p.slot_count - p.free_count,
	}
}

// === TESTS ===
@(test)
test_message_pool :: proc(t: ^testing.T) {
	backing: [10]Message_Envelope
	pool: Message_Pool
	pool_init(&pool, backing[:])

	stats := pool_stats(&pool)
	testing.expect_value(t, stats.slot_count, 10)
	testing.expect_value(t, pool.reserved_count, 1)

	testing.expect_value(t, stats.free_count, 10)
	testing.expect_value(t, stats.used_count, 0)

	// User traffic must stop at the system reserve.
	indices: [10]u32
	for i in 0 ..< 9 {
		index, error := pool_alloc_user(&pool)
		testing.expect_value(t, error, Pool_Error.None)
		indices[i] = index
	}

	_, user_empty_error := pool_alloc_user(&pool)
	testing.expect_value(t, user_empty_error, Pool_Error.Empty)

	index_system, system_error := pool_alloc_system(&pool)
	testing.expect_value(t, system_error, Pool_Error.None)
	indices[9] = index_system

	_, empty_error := pool_alloc_system(&pool)
	testing.expect_value(t, empty_error, Pool_Error.Empty)

	stats_full := pool_stats(&pool)
	testing.expect_value(t, stats_full.used_count, 10)

	// Test pointer resolution
	slot_pointer := pool_get_ptr(&pool, indices[0])
	testing.expect(
		t,
		uintptr(slot_pointer) == uintptr(raw_data(backing[:])),
		"Index 0 should map to backing buffer start",
	)

	// Free them all back
	for i in 0 ..< 10 {
		pool_free(&pool, indices[i])
	}

	stats_freed := pool_stats(&pool)
	testing.expect_value(t, stats_freed.used_count, 0)
	testing.expect_value(t, stats_freed.free_count, 10)

}

@(test)
test_message_pool_small_pool_keeps_system_reserve :: proc(t: ^testing.T) {
	backing: [2]Message_Envelope
	pool: Message_Pool
	pool_init(&pool, backing[:])

	testing.expect_value(t, pool.slot_count, u32(2))
	testing.expect_value(t, pool.reserved_count, u32(1))

	_, user_error := pool_alloc_user(&pool)
	testing.expect_value(t, user_error, Pool_Error.None)
	_, user_empty_error := pool_alloc_user(&pool)
	testing.expect_value(t, user_empty_error, Pool_Error.Empty)
	_, system_error := pool_alloc_system(&pool)
	testing.expect_value(t, system_error, Pool_Error.None)
}
