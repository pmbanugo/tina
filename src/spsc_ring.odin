package tina

import "base:sanitizer"
import "core:sync"
import "core:testing"

_ :: sanitizer

SPSC_Ring :: struct #align(CACHE_LINE_SIZE) {
    // PRODUCER CACHE LINE -------------------------------------------------
    write_sequence:       u64, // ATOMIC: The sequence up to which data is fully written and visible
    local_write_sequence: u64, // LOCAL: The sequence of the next item to enqueue
    cached_read_sequence: u64, // LOCAL: Cached read sequence to avoid hitting the atomic
    _padding1:            [CACHE_LINE_SIZE - 3 * size_of(u64)]u8,

    // CONSUMER CACHE LINE -------------------------------------------------
    read_sequence:         u64, // ATOMIC: The sequence up to which data is fully consumed
    local_read_sequence:   u64, // LOCAL: The sequence of the next item to consume
    cached_write_sequence: u64, // LOCAL: Cached write sequence to avoid hitting the atomic
    _padding2:             [CACHE_LINE_SIZE - 3 * size_of(u64)]u8,

    // COLD DATA. Read-only after initialization ---------------------------
    capacity:      u64,
    capacity_mask: u64,
    buffer:        [^]Message_Envelope,
}

// Producer and consumer fields must sit on separate cache lines so the
// spatial prefetcher (Intel/AMD fetches 128-byte pairs) never pulls the
// other thread's line into the current core. Cold data starts on a third line.
#assert(offset_of(SPSC_Ring, read_sequence) == CACHE_LINE_SIZE, "SPSC_Ring consumer section must start on the second cache line")
#assert(offset_of(SPSC_Ring, capacity) == 2 * CACHE_LINE_SIZE, "SPSC_Ring cold section must start on the third cache line")
#assert(size_of(SPSC_Ring) == 3 * CACHE_LINE_SIZE, "SPSC_Ring must occupy exactly three cache lines")
#assert(align_of(SPSC_Ring) == CACHE_LINE_SIZE, "SPSC_Ring alignment must match CACHE_LINE_SIZE")

// Initializes the ring with pre-allocated memory (from process bootstrapper).
spsc_ring_init :: proc(ring: ^SPSC_Ring, capacity: u64, buffer: []Message_Envelope) {
    assert(capacity > 0 && (capacity & (capacity - 1)) == 0, "SPSC ring capacity must be a power of 2")
    assert(u64(len(buffer)) >= capacity, "Buffer length must be at least capacity")

    ring.write_sequence = 0
    ring.local_write_sequence = 0
    ring.cached_read_sequence = 0

    ring.read_sequence = 0
    ring.local_read_sequence = 0
    ring.cached_write_sequence = 0

    ring.capacity = capacity
    ring.capacity_mask = capacity - 1
    ring.buffer = raw_data(buffer)
}

// Enqueues a message into the ring but DOES NOT publish it yet.
// no atomic barrier unless cached capacity is exhausted.
spsc_ring_enqueue :: #force_inline proc "contextless" (ring: ^SPSC_Ring, envelope: ^Message_Envelope) -> Enqueue_Result {
    // Check if full using local cache
    if ring.local_write_sequence - ring.cached_read_sequence >= ring.capacity {
        // Cache says full, fetch the actual read_sequence via Acquire load
        ring.cached_read_sequence = sync.atomic_load_explicit(&ring.read_sequence, sync.Atomic_Memory_Order.Acquire)

        // Re-check
        if ring.local_write_sequence - ring.cached_read_sequence >= ring.capacity {
            return .Full
        }
    }

    // Write data directly to the ring buffer
    index := ring.local_write_sequence & ring.capacity_mask
    ring.buffer[index] = envelope^

    ring.local_write_sequence += 1
    return .Success
}

// Publishes all enqueued messages to the consumer simultaneously.
// Executed once per tick in Step 5.
spsc_ring_flush_producer :: #force_inline proc "contextless" (ring: ^SPSC_Ring) {
    if ring.write_sequence != ring.local_write_sequence {
        sync.atomic_store_explicit(&ring.write_sequence, ring.local_write_sequence, sync.Atomic_Memory_Order.Release)
    }
}

// Consumer API -----------------------------------------------------

// Returns how many items are currently available to read.
// Executed once per tick in Step 1.
spsc_ring_available_to_read :: #force_inline proc "contextless" (ring: ^SPSC_Ring) -> u64 {
    if ring.cached_write_sequence <= ring.local_read_sequence {
        ring.cached_write_sequence = sync.atomic_load_explicit(&ring.write_sequence, sync.Atomic_Memory_Order.Acquire)
    }
    return ring.cached_write_sequence - ring.local_read_sequence
}

// Gets a pointer to the message at the given offset from the current read cursor.
spsc_ring_get_read_ptr :: #force_inline proc "contextless" (ring: ^SPSC_Ring, offset: u64) -> ^Message_Envelope {
    index := (ring.local_read_sequence + offset) & ring.capacity_mask
    return &ring.buffer[index]
}

// Advances the read sequence, freeing the slots for the producer.
// Executed after consuming the available batch.
spsc_ring_commit_read :: #force_inline proc "contextless" (ring: ^SPSC_Ring, count: u64) {
    if count == 0 do return
    ring.local_read_sequence += count
    sync.atomic_store_explicit(&ring.read_sequence, ring.local_read_sequence, sync.Atomic_Memory_Order.Release)
}

spsc_ring_init_tina_owned :: proc(
    ring: ^SPSC_Ring,
    capacity: u64,
    buffer: []Message_Envelope,
) {
    spsc_ring_init(ring, capacity, buffer)

    when TINA_ASAN_POISONING {
        _sanitizer_address_poison_spsc_ring_slots(ring, 0, capacity)
    }
}

spsc_ring_enqueue_tina_owned :: #force_inline proc "contextless" (
    ring: ^SPSC_Ring,
    envelope: ^Message_Envelope,
) -> Enqueue_Result {
    when TINA_ASAN_POISONING {
        if ring.local_write_sequence - ring.cached_read_sequence >= ring.capacity {
            ring.cached_read_sequence = sync.atomic_load_explicit(&ring.read_sequence, sync.Atomic_Memory_Order.Acquire)
            if ring.local_write_sequence - ring.cached_read_sequence >= ring.capacity {
                return .Full
            }
        }

        index := ring.local_write_sequence & ring.capacity_mask
        _sanitizer_address_unpoison_spsc_ring_slot(ring, index)
        ring.buffer[index] = envelope^
        ring.local_write_sequence += 1
        return .Success
    } else {
        return spsc_ring_enqueue(ring, envelope)
    }
}

// Slots are poisoned before read_sequence is published so a producer cannot
// claim and write a slot ASan still considers free.
spsc_ring_commit_read_tina_owned :: #force_inline proc "contextless" (ring: ^SPSC_Ring, count: u64) {
    if count == 0 do return

    when TINA_ASAN_POISONING {
        _sanitizer_address_poison_spsc_ring_slots(ring, ring.local_read_sequence, count)
    }

    ring.local_read_sequence += count
    sync.atomic_store_explicit(&ring.read_sequence, ring.local_read_sequence, sync.Atomic_Memory_Order.Release)
}

// ======
// Tests
// ======

@(test)
test_spsc_ring_batching :: proc(t: ^testing.T) {
    buffer: [4]Message_Envelope
    ring: SPSC_Ring
    spsc_ring_init(&ring, 4, buffer[:])

    env := Message_Envelope{ tag = TAG_TIMER }

    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Success)
    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Success)

    testing.expect_value(t, spsc_ring_available_to_read(&ring), 0)
    spsc_ring_flush_producer(&ring)

    avail := spsc_ring_available_to_read(&ring)
    testing.expect_value(t, avail, 2)

    spsc_ring_commit_read(&ring, avail)

    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Success)
    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Success)
    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Success)
    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Success)

    // The 5th enqueue MUST fail.
    testing.expect(t, spsc_ring_enqueue(&ring, &env) == .Full, "5th enqueue on a capacity 4 ring must fail")

    spsc_ring_flush_producer(&ring)
    testing.expect_value(t, spsc_ring_available_to_read(&ring), 4)
}

when TINA_ASAN_POISONING {

@(test)
test_spsc_ring_tina_owned_slot_poisoning :: proc(t: ^testing.T) {
    buffer: [4]Message_Envelope
    ring: SPSC_Ring
    spsc_ring_init_tina_owned(&ring, 4, buffer[:])

    slot_pointer := rawptr(&buffer[0])
    slot_size := size_of(Message_Envelope)

    testing.expect(
        t,
        sanitizer.address_region_is_poisoned_rawptr(slot_pointer, slot_size) != nil,
        "initially free SPSC ring slot must be poisoned",
    )

    envelope := Message_Envelope{ tag = TAG_TIMER }
    testing.expect_value(t, spsc_ring_enqueue_tina_owned(&ring, &envelope), Enqueue_Result.Success)

    testing.expect(
        t,
        sanitizer.address_region_is_poisoned_rawptr(slot_pointer, slot_size) == nil,
        "enqueued SPSC ring slot must be unpoisoned",
    )

    spsc_ring_flush_producer(&ring)
    testing.expect_value(t, spsc_ring_available_to_read(&ring), 1)
    testing.expect(t, spsc_ring_get_read_ptr(&ring, 0) != nil)

    spsc_ring_commit_read_tina_owned(&ring, 1)

    testing.expect(
        t,
        sanitizer.address_region_is_poisoned_rawptr(slot_pointer, slot_size) != nil,
        "committed SPSC ring slot must be re-poisoned",
    )

    _sanitizer_address_unpoison_spsc_ring_slots(&ring)
}

}
