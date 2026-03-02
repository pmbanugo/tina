package tina

import "core:mem"
import "core:testing"

// POOL_NONE_INDEX is a sentinel value representing the end of an index-based linked list.
// Because index 0 is a valid array position,
// we use max(u32) to explicitly mean "empty" or "no next item". It is shared across
// the Message Pool free-list, the Isolate Mailbox queues, and the Timer Wheel spokes.
POOL_NONE_INDEX :: 0xFFFF_FFFF

Message_Pool :: struct {
    buffer: []u8,
    chunk_size: int,
    head_index: u32,
    total_slots: int,
    free_slots: int,
}

Pool_Stats :: struct {
    total: int,
    used: int,
    free: int,
}

Pool_Error :: enum u8 {
    None,
    Empty,
    Out_Of_Bounds,
    Unaligned_Pointer,
}

pool_init :: proc(p: ^Message_Pool, backing: []u8, chunk_size: int) {
    p.buffer = backing
    p.chunk_size = chunk_size
    p.total_slots = len(backing) / chunk_size
    p.free_slots = 0
    p.head_index = POOL_NONE_INDEX

    // Intrusive push. We loop backwards so that slot 0 is at the head of the list,
    // pointing to slot 1, which points to 2, etc. This should improve initial cache locality.
    for i := p.total_slots - 1; i >= 0; i -= 1 {
        ptr := &p.buffer[i * p.chunk_size]

        // Write the previous head_index directly into the first 4 bytes of the chunk
        next_index_pointer := cast(^u32)ptr
        next_index_pointer^ = p.head_index

        p.head_index = u32(i)
        p.free_slots += 1
    }
}

pool_alloc :: proc(p: ^Message_Pool) -> (rawptr, Pool_Error) {
    if p.head_index == POOL_NONE_INDEX {
        return nil, .Empty
    }

    // Get the slot index and calculate its pointer
    slot_index := p.head_index
    ptr := rawptr(&p.buffer[int(slot_index) * p.chunk_size])

    // Read the next index from the first 4 bytes of the slot
    p.head_index = (cast(^u32)ptr)^
    p.free_slots -= 1

    mem.zero(ptr, p.chunk_size)
    return ptr, .None
}

pool_free :: proc(p: ^Message_Pool, ptr: rawptr) -> Pool_Error {
    if ptr == nil {
        return .None
    }

    // Bounds and mathematical alignment check!
    buffer_base_address := uintptr(raw_data(p.buffer))
    pointer_address := uintptr(ptr)

    if pointer_address < buffer_base_address || pointer_address >= buffer_base_address + uintptr(len(p.buffer)) {
        return .Out_Of_Bounds
    }

    offset := pointer_address - buffer_base_address
    if offset % uintptr(p.chunk_size) != 0 {
        return .Unaligned_Pointer // User tried to free an address in the middle of a chunk
    }

    slot_index := u32(offset / uintptr(p.chunk_size))

    // Intrusive push back onto the free list
    next_index_pointer := cast(^u32)ptr
    next_index_pointer^ = p.head_index
    p.head_index = slot_index
    p.free_slots += 1

    return .None
}

pool_stats :: proc(p: ^Message_Pool) -> Pool_Stats {
    return Pool_Stats{
        total = p.total_slots,
        free = p.free_slots,
        used = p.total_slots - p.free_slots,
    }
}

// === TESTS ===
@(test)
test_message_pool :: proc(t: ^testing.T) {
    // Stack allocate backing buffer for the test. 10 slots of 128 bytes.
    backing: [1280]u8
    pool: Message_Pool
    pool_init(&pool, backing[:], 128)

    stats := pool_stats(&pool)
    testing.expect_value(t, stats.total, 10)
    testing.expect_value(t, stats.free, 10)
    testing.expect_value(t, stats.used, 0)

    // Allocate all slots
    ptrs: [10]rawptr
    for i in 0..<10 {
        ptr, err := pool_alloc(&pool)
        testing.expect_value(t, err, Pool_Error.None)
        ptrs[i] = ptr
    }

    // Pool should now be empty
    _, empty_err := pool_alloc(&pool)
    testing.expect_value(t, empty_err, Pool_Error.Empty)

    stats_full := pool_stats(&pool)
    testing.expect_value(t, stats_full.used, 10)
    testing.expect_value(t, stats_full.free, 0)

    // Test Bounds checking
    dummy_val: u64
    oob_err := pool_free(&pool, &dummy_val)
    testing.expect_value(t, oob_err, Pool_Error.Out_Of_Bounds)

    unaligned_ptr := rawptr(uintptr(ptrs[0]) + 1)
    unalign_err := pool_free(&pool, unaligned_ptr)
    testing.expect_value(t, unalign_err, Pool_Error.Unaligned_Pointer)

    // Free them all back
    for i in 0..<10 {
        err := pool_free(&pool, ptrs[i])
        testing.expect_value(t, err, Pool_Error.None)
    }

    stats_freed := pool_stats(&pool)
    testing.expect_value(t, stats_freed.used, 0)
    testing.expect_value(t, stats_freed.free, 10)
}
