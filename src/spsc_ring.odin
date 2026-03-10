package tina

import "core:sync"
import "core:testing"

SPSC_Ring :: struct #align(CACHE_LINE_SIZE) {
    // PRODUCER CACHE LINE -------------------------------------------------
    write_sequence:       u64, // ATOMIC: The sequence up to which data is fully written and visible
    local_write_sequence: u64, // LOCAL: The sequence of the next item to enqueue
    cached_read_sequence: u64, // LOCAL: Cached read sequence to avoid hitting the atomic
    _padding1:            [104]u8, // 128 - (3 * 8) = 104 bytes padding to reach next cache line

    // CONSUMER CACHE LINE -------------------------------------------------
    read_sequence:         u64, // ATOMIC: The sequence up to which data is fully consumed
    local_read_sequence:   u64, // LOCAL: The sequence of the next item to consume
    cached_write_sequence: u64, // LOCAL: Cached write sequence to avoid hitting the atomic
    _padding2:             [104]u8, // 128 - (3 * 8) = 104 bytes padding

    // COLD DATA. Read-only after initialization ---------------------------
    capacity:      u64,
    capacity_mask: u64,
    buffer:        [^]Message_Envelope,
}

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
spsc_ring_enqueue :: #force_inline proc(ring: ^SPSC_Ring, envelope: ^Message_Envelope) -> bool {
    // Check if full using local cache
    if ring.local_write_sequence - ring.cached_read_sequence >= ring.capacity {
        // Cache says full, fetch the actual read_sequence via Acquire load
        ring.cached_read_sequence = sync.atomic_load_explicit(&ring.read_sequence, sync.Atomic_Memory_Order.Acquire)

        // Re-check
        if ring.local_write_sequence - ring.cached_read_sequence >= ring.capacity {
            return false // Ring is completely full
        }
    }

    // Write data directly to the ring buffer
    idx := ring.local_write_sequence & ring.capacity_mask
    ring.buffer[idx] = envelope^

    ring.local_write_sequence += 1
    return true
}

// Publishes all enqueued messages to the consumer simultaneously.
// Executed once per tick in Step 5.
spsc_ring_flush_producer :: #force_inline proc(ring: ^SPSC_Ring) {
    if ring.write_sequence != ring.local_write_sequence {
        sync.atomic_store_explicit(&ring.write_sequence, ring.local_write_sequence, sync.Atomic_Memory_Order.Release)
    }
}

// Consumer API -----------------------------------------------------

// Returns how many items are currently available to read.
// Executed once per tick in Step 1.
spsc_ring_available_to_read :: #force_inline proc(ring: ^SPSC_Ring) -> u64 {
    if ring.cached_write_sequence <= ring.local_read_sequence {
        ring.cached_write_sequence = sync.atomic_load_explicit(&ring.write_sequence, sync.Atomic_Memory_Order.Acquire)
    }
    return ring.cached_write_sequence - ring.local_read_sequence
}

// Gets a pointer to the message at the given offset from the current read cursor.
spsc_ring_get_read_ptr :: #force_inline proc(ring: ^SPSC_Ring, offset: u64) -> ^Message_Envelope {
    idx := (ring.local_read_sequence + offset) & ring.capacity_mask
    return &ring.buffer[idx]
}

// Advances the read sequence, freeing the slots for the producer.
// Executed after consuming the available batch.
spsc_ring_commit_read :: #force_inline proc(ring: ^SPSC_Ring, count: u64) {
    if count == 0 do return
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

    // Enqueue 2 items (staged, not published)
    testing.expect(t, spsc_ring_enqueue(&ring, &env))
    testing.expect(t, spsc_ring_enqueue(&ring, &env))

    // Consumer should see 0 because they are not flushed
    testing.expect_value(t, spsc_ring_available_to_read(&ring), 0)

    // Publish
    spsc_ring_flush_producer(&ring)

    // Consumer should now see 2
    avail := spsc_ring_available_to_read(&ring)
    testing.expect_value(t, avail, 2)

    // Commit read. The ring is now 100% EMPTY (2 written, 2 read).
    spsc_ring_commit_read(&ring, avail)

    // Since capacity is 4, and the ring is empty, we should be able to enqueue exactly 4 items.
    testing.expect(t, spsc_ring_enqueue(&ring, &env)) // LWS = 3
    testing.expect(t, spsc_ring_enqueue(&ring, &env)) // LWS = 4
    testing.expect(t, spsc_ring_enqueue(&ring, &env)) // LWS = 5 (Forces atomic read of RS)
    testing.expect(t, spsc_ring_enqueue(&ring, &env)) // LWS = 6

    // The 5th enqueue MUST fail.
    // LWS (6) - CRS (2) == 4. 4 >= capacity (4).
    testing.expect(t, !spsc_ring_enqueue(&ring, &env), "5th enqueue on a capacity 4 ring must fail")

    // Publish the 4 successfully enqueued items
    spsc_ring_flush_producer(&ring)

    // Consumer should see exactly 4 items available
    testing.expect_value(t, spsc_ring_available_to_read(&ring), 4)
}
