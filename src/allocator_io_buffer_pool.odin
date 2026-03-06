package tina

import "core:mem"
import "core:testing"

// ============================================================================
// Reactor Buffer Pool — Shard-Owned I/O Buffer Region (§6.6.1 §6)
// ============================================================================
//
// Pre-allocated, contiguous array of fixed-size buffer slots used exclusively
// for I/O data transfer. Managed via an intrusive LIFO free list with u16 indices.
//
// - Reads: reactor allocates a slot, kernel writes into it, handler reads via
//   ctx.read_buffer(buffer_index), scheduler frees after handler returns.
// - Writes: scheduler copies payload from Isolate struct into a slot
//   (copy-on-submit), reactor submits write from the slot, scheduler frees
//   after completion.
//
// Same Ginger Bill pool pattern as the message pool (§6.4.2), but with:
// - u16 indices (up to 65535 slots, matching Submission_Token.buffer_index)
// - Configurable slot size (default 4096, vs message pool's fixed 128 bytes)
// - 2-byte intrusive next pointer (u16, not u32)

Reactor_Buffer_Pool :: struct {
	buffer:     []u8,   // contiguous backing memory
	slot_size:  u32,    // bytes per slot (configurable, default 4096)
	slot_count: u16,    // total number of slots
	free_head:  u16,    // LIFO free list head (BUFFER_INDEX_NONE = empty)
	free_count: u16,    // available slots
}

Buffer_Pool_Error :: enum u8 {
	None,
	Empty,
	Out_Of_Bounds,
	Unaligned_Index,
}

// Initialize the reactor buffer pool with pre-allocated backing memory.
// slot_size must be >= 2 (for intrusive next pointer).
// len(backing) must be >= slot_count * slot_size.
reactor_buffer_pool_init :: proc(pool: ^Reactor_Buffer_Pool, backing: []u8, slot_size: u32, slot_count: u16) {
	assert(slot_size >= 2, "slot_size must be >= 2 for intrusive free list")
	assert(len(backing) >= int(slot_count) * int(slot_size), "backing too small")

	pool.buffer = backing
	pool.slot_size = slot_size
	pool.slot_count = slot_count
	pool.free_count = 0
	pool.free_head = BUFFER_INDEX_NONE

	// Build LIFO free list: slot 0 at head for initial cache locality.
	// First 2 bytes of each free slot store the next-free index as u16.
	for i := int(slot_count) - 1; i >= 0; i -= 1 {
		slot_ptr := _buffer_pool_slot_ptr(pool, u16(i))
		(cast(^u16)slot_ptr)^ = pool.free_head
		pool.free_head = u16(i)
		pool.free_count += 1
	}
}

// Allocate a buffer slot from the pool. Returns the slot index.
// O(1) — pops from LIFO free list head.
reactor_buffer_pool_alloc :: proc(pool: ^Reactor_Buffer_Pool) -> (u16, Buffer_Pool_Error) {
	if pool.free_head == BUFFER_INDEX_NONE {
		return BUFFER_INDEX_NONE, .Empty
	}

	index := pool.free_head
	slot_ptr := _buffer_pool_slot_ptr(pool, index)

	// Advance free list: read next-free from first 2 bytes
	pool.free_head = (cast(^u16)slot_ptr)^
	pool.free_count -= 1

	// Zero the slot for safety
	mem.zero(slot_ptr, int(pool.slot_size))

	return index, .None
}

// Free a buffer slot back to the pool.
// O(1) — pushes onto LIFO free list head. Recently freed slots reused first
// for cache warmth.
reactor_buffer_pool_free :: proc(pool: ^Reactor_Buffer_Pool, index: u16) -> Buffer_Pool_Error {
	if index >= pool.slot_count {
		return .Out_Of_Bounds
	}

	slot_ptr := _buffer_pool_slot_ptr(pool, index)

	// Write current head into first 2 bytes (intrusive push)
	(cast(^u16)slot_ptr)^ = pool.free_head
	pool.free_head = index
	pool.free_count += 1

	return .None
}

// Get a pointer to the buffer data for a given slot index.
// Used by the reactor to provide buffers to the kernel, and by the scheduler
// to construct buffer pointers for handlers (ctx.read_buffer).
reactor_buffer_pool_slot_ptr :: #force_inline proc(pool: ^Reactor_Buffer_Pool, index: u16) -> [^]u8 {
	assert(index < pool.slot_count, "buffer index out of bounds")
	return _buffer_pool_slot_ptr(pool, index)
}

// Get a read-only slice of the buffer data for a completed read.
// length is the actual bytes read (from io_result), capped at slot_size.
reactor_buffer_pool_read_slice :: proc(pool: ^Reactor_Buffer_Pool, index: u16, length: u32) -> []u8 {
	assert(index < pool.slot_count, "buffer index out of bounds")
	ptr := _buffer_pool_slot_ptr(pool, index)
	actual_length := min(length, pool.slot_size)
	return ptr[:actual_length]
}

// Copy payload from an Isolate's struct into a buffer slot (copy-on-submit for writes).
// Returns the buffer slot pointer for backend submission.
// Bounds check: payload_size must fit within slot_size.
reactor_buffer_pool_copy_in :: proc(pool: ^Reactor_Buffer_Pool, index: u16, source: rawptr, payload_size: u32) -> [^]u8 {
	assert(index < pool.slot_count, "buffer index out of bounds")
	assert(payload_size <= pool.slot_size, "payload exceeds slot size")

	dst := _buffer_pool_slot_ptr(pool, index)
	mem.copy(dst, source, int(payload_size))
	return dst
}

// --- Internal ---

@(private = "file")
_buffer_pool_slot_ptr :: #force_inline proc(pool: ^Reactor_Buffer_Pool, index: u16) -> [^]u8 {
	offset := int(index) * int(pool.slot_size)
	return raw_data(pool.buffer[offset:])
}

// ============================================================================
// Tests
// ============================================================================

@(test)
test_reactor_buffer_pool_init :: proc(t: ^testing.T) {
	backing: [4096 * 4]u8  // 4 slots of 4096 bytes
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 4096, 4)

	testing.expect_value(t, pool.slot_count, 4)
	testing.expect_value(t, pool.free_count, 4)
	testing.expect(t, pool.free_head != BUFFER_INDEX_NONE, "free list should not be empty")
}

@(test)
test_reactor_buffer_pool_alloc_free :: proc(t: ^testing.T) {
	backing: [64 * 8]u8  // 8 slots of 64 bytes
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 64, 8)

	// Allocate all slots
	indices: [8]u16
	for i in 0..<8 {
		idx, err := reactor_buffer_pool_alloc(&pool)
		testing.expect_value(t, err, Buffer_Pool_Error.None)
		testing.expect(t, idx != BUFFER_INDEX_NONE, "should get valid index")
		indices[i] = idx
	}
	testing.expect_value(t, pool.free_count, 0)

	// Pool should be empty now
	_, empty_err := reactor_buffer_pool_alloc(&pool)
	testing.expect_value(t, empty_err, Buffer_Pool_Error.Empty)

	// Free all back
	for i in 0..<8 {
		err := reactor_buffer_pool_free(&pool, indices[i])
		testing.expect_value(t, err, Buffer_Pool_Error.None)
	}
	testing.expect_value(t, pool.free_count, 8)
}

@(test)
test_reactor_buffer_pool_lifo :: proc(t: ^testing.T) {
	backing: [64 * 4]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 64, 4)

	// Allocate 3 slots
	i0, _ := reactor_buffer_pool_alloc(&pool)
	i1, _ := reactor_buffer_pool_alloc(&pool)
	i2, _ := reactor_buffer_pool_alloc(&pool)

	// Free i1 then i0 — LIFO means next alloc should return i0
	reactor_buffer_pool_free(&pool, i1)
	reactor_buffer_pool_free(&pool, i0)

	reuse, _ := reactor_buffer_pool_alloc(&pool)
	testing.expect_value(t, reuse, i0)

	reuse2, _ := reactor_buffer_pool_alloc(&pool)
	testing.expect_value(t, reuse2, i1)

	// i2 is still allocated, free it
	reactor_buffer_pool_free(&pool, i2)
}

@(test)
test_reactor_buffer_pool_copy_in :: proc(t: ^testing.T) {
	backing: [64 * 2]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 64, 2)

	idx, _ := reactor_buffer_pool_alloc(&pool)

	// Write some data via copy_in
	source_data := [4]u8{0xDE, 0xAD, 0xBE, 0xEF}
	ptr := reactor_buffer_pool_copy_in(&pool, idx, &source_data, 4)

	// Verify via read_slice
	slice := reactor_buffer_pool_read_slice(&pool, idx, 4)
	testing.expect_value(t, slice[0], 0xDE)
	testing.expect_value(t, slice[1], 0xAD)
	testing.expect_value(t, slice[2], 0xBE)
	testing.expect_value(t, slice[3], 0xEF)

	// Verify ptr matches
	testing.expect_value(t, ptr[0], 0xDE)

	reactor_buffer_pool_free(&pool, idx)
}

@(test)
test_reactor_buffer_pool_out_of_bounds :: proc(t: ^testing.T) {
	backing: [64 * 2]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 64, 2)

	err := reactor_buffer_pool_free(&pool, 99)
	testing.expect_value(t, err, Buffer_Pool_Error.Out_Of_Bounds)
}

@(test)
test_reactor_buffer_pool_read_slice_capped :: proc(t: ^testing.T) {
	backing: [32 * 2]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 32, 2)

	idx, _ := reactor_buffer_pool_alloc(&pool)

	// Request more bytes than slot_size — should be capped
	slice := reactor_buffer_pool_read_slice(&pool, idx, 9999)
	testing.expect_value(t, u32(len(slice)), pool.slot_size)

	reactor_buffer_pool_free(&pool, idx)
}
