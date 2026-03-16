package tina

import "core:mem"
import "core:testing"

Reactor_Buffer_Pool :: struct {
	buffer:	    []u8,   // contiguous backing memory
	slot_size:  u32,    // bytes per slot
	slot_shift: u32,
	slot_count: u16,    // total number of slots
	free_head:  u16,    // LIFO free list head (BUFFER_INDEX_NONE = empty)
	free_count: u16,    // available slots
}

Buffer_Pool_Error :: enum u8 {
    None,
    Empty,
}

reactor_buffer_pool_init :: proc(pool: ^Reactor_Buffer_Pool, backing:[]u8, slot_size: u32, slot_count: u16) {
    assert(slot_size >= 2, "slot_size must be >= 2 for intrusive free list")
    assert((slot_size & (slot_size - 1)) == 0, "slot_size must be a power of 2")
    assert(len(backing) >= int(slot_count) * int(slot_size), "backing too small")

    pool.buffer = backing
    pool.slot_size = slot_size

    shift: u32 = 0
    for temp := slot_size; temp > 1; temp >>= 1 {
        shift += 1
    }
    pool.slot_shift = shift

    pool.slot_count = slot_count
    pool.free_count = 0
    pool.free_head = BUFFER_INDEX_NONE

    for i := int(slot_count) - 1; i >= 0; i -= 1 {
        slot_ptr := _buffer_pool_slot_ptr(pool, u16(i))
        (cast(^u16)slot_ptr)^ = pool.free_head
        pool.free_head = u16(i)
        pool.free_count += 1
    }
}

reactor_buffer_pool_alloc :: proc(pool: ^Reactor_Buffer_Pool) -> (u16, Buffer_Pool_Error) {
    if pool.free_head == BUFFER_INDEX_NONE {
        return BUFFER_INDEX_NONE, .Empty
    }

    index := pool.free_head
    slot_ptr := _buffer_pool_slot_ptr(pool, index)

    pool.free_head = (cast(^u16)slot_ptr)^
    pool.free_count -= 1

    mem.zero(slot_ptr, int(pool.slot_size))

    return index, .None
}

reactor_buffer_pool_free :: proc(pool: ^Reactor_Buffer_Pool, index: u16) {
    assert(index < pool.slot_count, "buffer index out of bounds")

    slot_ptr := _buffer_pool_slot_ptr(pool, index)

    (cast(^u16)slot_ptr)^ = pool.free_head
    pool.free_head = index
    pool.free_count += 1
}

// Get a pointer to the buffer data for a given slot index.
reactor_buffer_pool_slot_ptr :: #force_inline proc(pool: ^Reactor_Buffer_Pool, index: u16) -> [^]u8 {
    assert(index < pool.slot_count, "buffer index out of bounds")
    return _buffer_pool_slot_ptr(pool, index)
}

// Get a read-only slice of the buffer data for a completed read.
reactor_buffer_pool_read_slice :: proc(pool: ^Reactor_Buffer_Pool, index: u16, size: u32) ->[]u8 {
    assert(index < pool.slot_count, "buffer index out of bounds")
    ptr := _buffer_pool_slot_ptr(pool, index)
    actual_size := min(size, pool.slot_size)
    return ptr[:actual_size]
}

// Copy payload from an Isolate's struct into a buffer slot (copy-on-submit for writes).
reactor_buffer_pool_copy_in :: proc(pool: ^Reactor_Buffer_Pool, index: u16, source: rawptr, payload_size: u32) -> [^]u8 {
    assert(index < pool.slot_count, "buffer index out of bounds")
    assert(payload_size <= pool.slot_size, "payload exceeds slot size")

    target := _buffer_pool_slot_ptr(pool, index)
    mem.copy(target, source, int(payload_size))
    return target
}

@(private = "file")
_buffer_pool_slot_ptr :: #force_inline proc(pool: ^Reactor_Buffer_Pool, index: u16) -> [^]u8 {
    offset := u32(index) << pool.slot_shift
    return raw_data(pool.buffer[offset:])
}

// =====
// Tests
// =====

@(test)
test_reactor_buffer_pool_init :: proc(t: ^testing.T) {
	backing: [4096 * 4]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 4096, 4)

	testing.expect_value(t, pool.slot_count, 4)
	testing.expect_value(t, pool.free_count, 4)
	testing.expect(t, pool.free_head != BUFFER_INDEX_NONE, "free list should not be empty")
}

@(test)
test_reactor_buffer_pool_alloc_free :: proc(t: ^testing.T) {
	backing:[64 * 8]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 64, 8)

	indices: [8]u16
	for i in 0..<8 {
		index, err := reactor_buffer_pool_alloc(&pool)
		testing.expect_value(t, err, Buffer_Pool_Error.None)
		testing.expect(t, index != BUFFER_INDEX_NONE, "should get valid index")
		indices[i] = index
	}
	testing.expect_value(t, pool.free_count, 0)

	_, empty_err := reactor_buffer_pool_alloc(&pool)
	testing.expect_value(t, empty_err, Buffer_Pool_Error.Empty)

	for i in 0..<8 {
		reactor_buffer_pool_free(&pool, indices[i])
	}
	testing.expect_value(t, pool.free_count, 8)
}

@(test)
test_reactor_buffer_pool_lifo :: proc(t: ^testing.T) {
	backing: [64 * 4]u8
	pool: Reactor_Buffer_Pool
	reactor_buffer_pool_init(&pool, backing[:], 64, 4)

	i0, _ := reactor_buffer_pool_alloc(&pool)
	i1, _ := reactor_buffer_pool_alloc(&pool)
	i2, _ := reactor_buffer_pool_alloc(&pool)

	reactor_buffer_pool_free(&pool, i1)
	reactor_buffer_pool_free(&pool, i0)

	reuse, _ := reactor_buffer_pool_alloc(&pool)
	testing.expect_value(t, reuse, i0)

	reuse2, _ := reactor_buffer_pool_alloc(&pool)
	testing.expect_value(t, reuse2, i1)

	reactor_buffer_pool_free(&pool, i2)
}
