package tina

import "core:mem"
import "core:testing"

POOL_NONE_INDEX :: 0xFFFF_FFFF

Message_Pool :: struct {
	buffer:         []u8,
	slot_size:      u32,
	slot_shift:     u32, // Power-of-2 exponent for bit-shifting
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

pool_init :: proc(p: ^Message_Pool, backing: []u8, slot_size: u32, reserved_pct: f32 = 0.01) {
	assert(slot_size >= 4, "slot_size must be >= 4 bytes for intrusive free list")
	assert((slot_size & (slot_size - 1)) == 0, "slot_size must be a power of 2")

	p.buffer = backing
	p.slot_size = slot_size

	// Calculate log2(slot_size) to get the shift amount
	shift: u32 = 0
	for temp := slot_size; temp > 1; temp >>= 1 {
		shift += 1
	}
	p.slot_shift = shift

	// Total capacity via bit-shift division
	p.slot_count = u32(len(backing)) >> shift
	p.free_count = 0
	p.free_head = POOL_NONE_INDEX

	// Calculate High-Water Mark for System Messages
	p.reserved_count = u32(f32(p.slot_count) * reserved_pct)

	// Intrusive push. Slot 0 at the head for sequential cache warmth.
	for i := int(p.slot_count) - 1; i >= 0; i -= 1 {
		ptr := cast(^Message_Envelope)&p.buffer[u32(i) << p.slot_shift]
		ptr.next_in_mailbox = p.free_head
		p.free_head = u32(i)
		p.free_count += 1
	}
}

@(private = "file")
_pool_alloc_unchecked :: #force_inline proc(p: ^Message_Pool) -> u32 {
	slot_index := p.free_head
	ptr := cast(^Message_Envelope)&p.buffer[slot_index << p.slot_shift]
	p.free_head = ptr.next_in_mailbox
	p.free_count -= 1
	mem.zero(ptr, int(p.slot_size))
	return slot_index
}

// User traffic Path (Respects High-Water Mark)
pool_alloc_user :: #force_inline proc(p: ^Message_Pool) -> (u32, Pool_Error) {
	if p.free_count <= p.reserved_count do return POOL_NONE_INDEX, .Empty
	return _pool_alloc_unchecked(p), .None
}

// System traffic Path (Drains to zero)
pool_alloc_system :: #force_inline proc(p: ^Message_Pool) -> (u32, Pool_Error) {
	if p.free_count == 0 do return POOL_NONE_INDEX, .Empty
	return _pool_alloc_unchecked(p), .None
}

// Frees a slot by its index. O(1).
pool_free :: proc(p: ^Message_Pool, index: u32) {
	assert(index < p.slot_count, "Message pool free index out of bounds")
	ptr := cast(^Message_Envelope)&p.buffer[index << p.slot_shift]
	// Type-aware intrusive push back onto the free list
	ptr.next_in_mailbox = p.free_head
	p.free_head = index
	p.free_count += 1
}

// Resolves a pool index to its memory pointer.
pool_get_ptr :: #force_inline proc(p: ^Message_Pool, index: u32) -> rawptr {
	assert(index < p.slot_count, "Message pool ptr index out of bounds")
	return rawptr(&p.buffer[index << p.slot_shift])
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
	backing: [1280]u8
	pool: Message_Pool
	pool_init(&pool, backing[:], 128)

	stats := pool_stats(&pool)
	testing.expect_value(t, stats.slot_count, 10)
	testing.expect_value(t, pool.slot_shift, 7) // log2(128) == 7

	testing.expect_value(t, stats.free_count, 10)
	testing.expect_value(t, stats.used_count, 0)

	// Allocate all slots
	indices: [10]u32
	for i in 0 ..< 10 {
		index, err := pool_alloc_user(&pool)
		testing.expect_value(t, err, Pool_Error.None)
		indices[i] = index
	}

	// Pool should now be empty
	_, empty_err := pool_alloc_user(&pool)
	testing.expect_value(t, empty_err, Pool_Error.Empty)

	stats_full := pool_stats(&pool)
	testing.expect_value(t, stats_full.used_count, 10)

	// Test pointer resolution
	ptr := pool_get_ptr(&pool, indices[0])
	testing.expect(t, ptr == raw_data(backing[:]), "Index 0 should map to backing buffer start")

	// Free them all back
	for i in 0 ..< 10 {
		pool_free(&pool, indices[i])
	}

	stats_freed := pool_stats(&pool)
	testing.expect_value(t, stats_freed.used_count, 0)
	testing.expect_value(t, stats_freed.free_count, 10)

}
