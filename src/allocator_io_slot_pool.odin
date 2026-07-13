package tina

import "core:math/bits"
import "core:mem"
import "core:testing"

IO_Slot_Link :: struct {
	next_free: IO_Slot_Index,
}

IO_Slot_Pool :: struct {
	backing_memory:     []u8,
	slot_size:  u32, // bytes per slot
	slot_shift: u32,
	slot_count: u16, // total number of slots
	free_head:  IO_Slot_Index, // LIFO free list head (IO_SLOT_INDEX_NONE = empty)
	free_count: u16, // available slots
}

IO_Slot_Pool_Error :: enum u8 {
	None,
	Empty,
}

IO_Slot_Pool_Config :: struct {
	backing_memory:    []u8,
	slot_size:  u32,
	slot_count: u16,
}

io_slot_pool_init :: proc(
	pool: ^IO_Slot_Pool,
	backing_memory: []u8,
	slot_size: u32,
	slot_count: u16,
) {
	assert(
		int(slot_count) <= IO_SLOT_COUNT_MAX,
		"IO slot count exceeds Submission_Token buffer_index capacity",
	)
	if slot_count == 0 {
		pool.backing_memory = backing_memory
		pool.slot_size = slot_size
		pool.slot_shift = 0
		pool.slot_count = 0
		pool.free_count = 0
		pool.free_head = IO_SLOT_INDEX_NONE
		return
	}

	assert(slot_size >= size_of(IO_Slot_Link), "slot_size must fit IO_Slot_Link")
	assert((slot_size & (slot_size - 1)) == 0, "slot_size must be a power of 2")
	assert(len(backing_memory) >= int(slot_count) * int(slot_size), "backing memory too small")

	pool.backing_memory = backing_memory
	pool.slot_size = slot_size

	// slot_size is structurally guaranteed by assert to be a power of 2
	pool.slot_shift = bits.trailing_zeros(slot_size)

	pool.slot_count = slot_count
	pool.free_count = 0
	pool.free_head = IO_SLOT_INDEX_NONE

	for i := int(slot_count) - 1; i >= 0; i -= 1 {
		slot_pointer := _io_slot_pool_pointer(pool, IO_Slot_Index(i))
		slot_link := cast(^IO_Slot_Link)slot_pointer
		slot_link.next_free = pool.free_head
		pool.free_head = IO_Slot_Index(i)
		pool.free_count += 1
	}
}

io_slot_pool_alloc :: #force_inline proc(pool: ^IO_Slot_Pool) -> (IO_Slot_Index, IO_Slot_Pool_Error) {
	if pool.free_head == IO_SLOT_INDEX_NONE {
		return IO_SLOT_INDEX_NONE, .Empty
	}

	index := pool.free_head
	slot_pointer := _io_slot_pool_pointer(pool, index)
	slot_link := cast(^IO_Slot_Link)slot_pointer

	pool.free_head = slot_link.next_free
	pool.free_count -= 1

	mem.zero(slot_pointer, int(pool.slot_size))

	return index, .None
}

io_slot_pool_alloc_unzeroed :: #force_inline proc(
	pool: ^IO_Slot_Pool,
) -> (IO_Slot_Index, IO_Slot_Pool_Error) {
	if pool.free_head == IO_SLOT_INDEX_NONE {
		return IO_SLOT_INDEX_NONE, .Empty
	}
	index := pool.free_head
	slot_pointer := _io_slot_pool_pointer(pool, index)
	slot_link := cast(^IO_Slot_Link)slot_pointer
	pool.free_head = slot_link.next_free
	pool.free_count -= 1
	// No mem.zero — caller guarantees the region will be fully written before read.
	return index, .None
}

io_slot_pool_free :: #force_inline proc(pool: ^IO_Slot_Pool, index: IO_Slot_Index) {
	assert(u16(index) < pool.slot_count, "IO_Slot Pool index out of bounds")

	slot_pointer := _io_slot_pool_pointer(pool, index)
	slot_link := cast(^IO_Slot_Link)slot_pointer

	slot_link.next_free = pool.free_head
	pool.free_head = index
	pool.free_count += 1
}

// Get a read-only slice of the buffer data for a completed read.
io_slot_pool_read_slice :: #force_inline proc(pool: ^IO_Slot_Pool, index: IO_Slot_Index, size: u32) -> []u8 {
	assert(u16(index) < pool.slot_count, "buffer index out of bounds")
	slot_pointer := _io_slot_pool_pointer(pool, index)
	actual_size := min(size, pool.slot_size)
	return slot_pointer[:actual_size]
}

// Get a writable slice view of a buffer slot.
io_slot_pool_write_slice :: #force_inline proc(pool: ^IO_Slot_Pool, index: IO_Slot_Index) -> []u8 {
	assert(u16(index) < pool.slot_count, "IO_Slot Pool index out of bounds")
	slot_pointer := _io_slot_pool_pointer(pool, index)
	return slot_pointer[:pool.slot_size]
}

// Copy byte slice contents into a buffer slot.
io_slot_pool_write_bytes :: #force_inline proc(
	pool: ^IO_Slot_Pool,
	index: IO_Slot_Index,
	source: []u8,
) {
	assert(u16(index) < pool.slot_count, "IO_Slot Pool index out of bounds")
	assert(len(source) <= int(pool.slot_size), "payload exceeds slot size")
	target := _io_slot_pool_pointer(pool, index)
	mem.copy(target, raw_data(source), len(source))
}

// Rebuild the pool's free list and mark every slot free.
io_slot_pool_reset :: #force_inline proc(pool: ^IO_Slot_Pool) {
	pool.free_count = pool.slot_count
	pool.free_head = IO_SLOT_INDEX_NONE
	for i := int(pool.slot_count) - 1; i >= 0; i -= 1 {
		slot_pointer := _io_slot_pool_pointer(pool, IO_Slot_Index(i))
		slot_link := cast(^IO_Slot_Link)slot_pointer
		slot_link.next_free = pool.free_head
		pool.free_head = IO_Slot_Index(i)
	}
}

@(private = "package")
io_slot_pool_init_tina_owned :: proc(
	pool: ^IO_Slot_Pool,
	backing_memory: []u8,
	slot_size: u32,
	slot_count: u16,
) {
	io_slot_pool_init(pool, backing_memory, slot_size, slot_count)
	for index in 0 ..< pool.slot_count {
		_sanitizer_address_poison_io_slot_payload(pool, IO_Slot_Index(index))
	}
}

@(private = "package")
io_slot_pool_alloc_tina_owned :: #force_inline proc(
	pool: ^IO_Slot_Pool,
) -> (IO_Slot_Index, IO_Slot_Pool_Error) {
	if pool.free_head == IO_SLOT_INDEX_NONE {
		return IO_SLOT_INDEX_NONE, .Empty
	}

	index := pool.free_head
	slot_pointer := _io_slot_pool_pointer(pool, index)

	// A logically freed slot has a poisoned payload, including the intrusive
	// link word, so ownership must be restored before reading the link.
	_sanitizer_address_unpoison_raw(rawptr(slot_pointer), size_of(IO_Slot_Link))
	slot_link := cast(^IO_Slot_Link)slot_pointer
	pool.free_head = slot_link.next_free
	_sanitizer_address_unpoison_io_slot(pool, index)
	pool.free_count -= 1

	mem.zero(slot_pointer, int(pool.slot_size))

	return index, .None
}

@(private = "package")
io_slot_pool_alloc_unzeroed_tina_owned :: #force_inline proc(
	pool: ^IO_Slot_Pool,
) -> (IO_Slot_Index, IO_Slot_Pool_Error) {
	if pool.free_head == IO_SLOT_INDEX_NONE {
		return IO_SLOT_INDEX_NONE, .Empty
	}
	index := pool.free_head
	slot_pointer := _io_slot_pool_pointer(pool, index)
	_sanitizer_address_unpoison_raw(rawptr(slot_pointer), size_of(IO_Slot_Link))
	slot_link := cast(^IO_Slot_Link)slot_pointer
	pool.free_head = slot_link.next_free
	_sanitizer_address_unpoison_io_slot(pool, index)
	pool.free_count -= 1
	return index, .None
}

@(private = "package")
io_slot_pool_free_tina_owned :: #force_inline proc(pool: ^IO_Slot_Pool, index: IO_Slot_Index) {
	assert(u16(index) < pool.slot_count, "IO_Slot Pool index out of bounds")

	slot_pointer := _io_slot_pool_pointer(pool, index)
	slot_link := cast(^IO_Slot_Link)slot_pointer

	_sanitizer_address_unpoison_raw(rawptr(slot_pointer), size_of(IO_Slot_Link))
	slot_link.next_free = pool.free_head
	pool.free_head = index
	pool.free_count += 1
	_sanitizer_address_poison_io_slot_payload(pool, index)
}

@(private = "package")
io_slot_pool_reset_tina_owned :: #force_inline proc(pool: ^IO_Slot_Pool) {
	pool.free_count = pool.slot_count
	pool.free_head = IO_SLOT_INDEX_NONE
	for i := int(pool.slot_count) - 1; i >= 0; i -= 1 {
		slot_index := IO_Slot_Index(i)
		_sanitizer_address_unpoison_io_slot(pool, slot_index)
		slot_pointer := _io_slot_pool_pointer(pool, slot_index)
		slot_link := cast(^IO_Slot_Link)slot_pointer
		slot_link.next_free = pool.free_head
		pool.free_head = slot_index
		_sanitizer_address_poison_io_slot_payload(pool, slot_index)
	}
}

@(private = "package")
_io_slot_pool_pointer :: #force_inline proc "contextless" (pool: ^IO_Slot_Pool, index: IO_Slot_Index) -> [^]u8 {
	offset := u32(index) << pool.slot_shift
	return raw_data(pool.backing_memory[offset:])
}

// =====
// Tests
// =====

@(test)
test_io_slot_pool_init :: proc(t: ^testing.T) {
	backing: [4096 * 4]u8
	pool: IO_Slot_Pool
	io_slot_pool_init(&pool, backing[:], 4096, 4)

	testing.expect_value(t, pool.slot_count, 4)
	testing.expect_value(t, pool.free_count, 4)
	testing.expect(t, pool.free_head != IO_SLOT_INDEX_NONE, "free list should not be empty")
}

@(test)
test_io_slot_pool_alloc_free :: proc(t: ^testing.T) {
	backing: [64 * 8]u8
	pool: IO_Slot_Pool
	io_slot_pool_init(&pool, backing[:], 64, 8)

	indices: [8]IO_Slot_Index
	for i in 0 ..< 8 {
		index, error := io_slot_pool_alloc(&pool)
		testing.expect_value(t, error, IO_Slot_Pool_Error.None)
		testing.expect(t, index != IO_SLOT_INDEX_NONE, "should get valid index")
		indices[i] = index
	}
	testing.expect_value(t, pool.free_count, 0)

	_, empty_error := io_slot_pool_alloc(&pool)
	testing.expect_value(t, empty_error, IO_Slot_Pool_Error.Empty)

	for i in 0 ..< 8 {
		io_slot_pool_free(&pool, indices[i])
	}
	testing.expect_value(t, pool.free_count, 8)
}

@(test)
test_io_slot_pool_lifo :: proc(t: ^testing.T) {
	backing: [64 * 4]u8
	pool: IO_Slot_Pool
	io_slot_pool_init(&pool, backing[:], 64, 4)

	i0, _ := io_slot_pool_alloc(&pool)
	i1, _ := io_slot_pool_alloc(&pool)
	i2, _ := io_slot_pool_alloc(&pool)

	io_slot_pool_free(&pool, i1)
	io_slot_pool_free(&pool, i0)

	reuse, _ := io_slot_pool_alloc(&pool)
	testing.expect_value(t, reuse, i0)

	reuse2, _ := io_slot_pool_alloc(&pool)
	testing.expect_value(t, reuse2, i1)

	io_slot_pool_free(&pool, i2)
}
