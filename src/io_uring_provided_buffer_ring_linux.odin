#+build linux
#+private
package tina

import "base:intrinsics"
import "core:mem"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// Kernel-facing structs mirroring <linux/io_uring.h> provided buffer ring ABI.
// ---------------------------------------------------------------------------

IO_Uring_Buffer_Entry :: struct {
	address:   u64,
	length:    u32,
	buffer_id: u16,
	reserved:  u16, // entry[0].reserved doubles as the ring tail counter (kernel convention)
}

IO_Uring_Buffer_Ring_Register :: struct {
	ring_address:     u64,
	ring_entry_count: u32,
	group_id:         u16,
	flags:            u16,
	_reserved:        [3]u64,
}

#assert(size_of(IO_Uring_Buffer_Entry) == 16)
#assert(size_of(IO_Uring_Buffer_Ring_Register) == 40)

// Tracks the state of a provided buffer ring for receive operations.
Provided_Buffer_Ring_State :: struct {
	ring_address:   uintptr, // page-aligned mmap'd ring memory address
	ring_byte_size: uint, // total byte size of the mmap'd region
	slot_size:      u32, // bytes per buffer slot
	slot_count:     u16, // number of entries in the ring (must be power of 2)
	group_id:       u16, // buffer group ID for this shard
	mask:           u16, // slot_count - 1 (for ring index wrapping)
	active:         bool, // true if kernel registration succeeded
}

IORING_CQE_BUFFER_SHIFT :: u32(16)
PROVIDED_BUFFER_RING_TAIL_OFFSET :: uintptr(14)

// ---------------------------------------------------------------------------
// Inline helpers — all contextless so they can be called from hot paths
// without requiring an Odin context.
// ---------------------------------------------------------------------------

// The kernel stores the ring tail in the `reserved` field of entry[0],
// which sits at byte offset 14 within the ring memory.
@(require_results)
_provided_buffer_ring_tail :: #force_inline proc "contextless" (state: ^Provided_Buffer_Ring_State) -> u16 {
	tail := cast(^u16)(rawptr(state.ring_address + PROVIDED_BUFFER_RING_TAIL_OFFSET))
	return tail^
}

// Writes a single buffer entry into the ring without advancing the tail.
// The caller accumulates multiple adds then publishes them all at once via
// _provided_buffer_ring_advance — this mirrors io_uring_buf_ring_add from liburing.
_provided_buffer_ring_add :: #force_inline proc "contextless" (
	state: ^Provided_Buffer_Ring_State,
	buffer_address: uintptr,
	buffer_length: u32,
	buffer_id: u16,
	tail_relative_index: u16,
) {
	tail := _provided_buffer_ring_tail(state)
	index := (tail + tail_relative_index) & state.mask
	entry := cast(^IO_Uring_Buffer_Entry)(rawptr(state.ring_address + uintptr(index) * size_of(IO_Uring_Buffer_Entry)))
	entry.address = u64(buffer_address)
	entry.length = buffer_length
	entry.buffer_id = buffer_id
}

// Atomically publishes `count` new entries by release-storing the updated tail.
// The release fence ensures the kernel observes fully written entries before
// seeing the advanced tail.
_provided_buffer_ring_advance :: #force_inline proc "contextless" (
	state: ^Provided_Buffer_Ring_State,
	count: u16,
) {
	tail := cast(^u16)(rawptr(state.ring_address + PROVIDED_BUFFER_RING_TAIL_OFFSET))
	new_tail := tail^ + count
	intrinsics.atomic_store_explicit(tail, new_tail, .Release)
}

// ---------------------------------------------------------------------------
// Lifecycle — init / deinit
// ---------------------------------------------------------------------------

_provided_buffer_ring_init :: proc(
	state: ^Provided_Buffer_Ring_State,
	ring_fd: linux.Fd,
	backing_memory_base: uintptr,
	slot_size: u32,
	slot_count: u16,
	group_id: u16,
) -> bool {
	if slot_count == 0 {
		return false
	}
	// Power-of-two check
	if (slot_count & (slot_count - 1)) != 0 {
		return false
	}

	// No hardcoded page size: mmap(2) with addr=NULL returns a page-aligned
	// address on all Linux page configurations (4K, 16K, 64K). The kernel
	// maps in multiples of the page size internally. munmap(2) requires addr
	// to be page-aligned (guaranteed by mmap) but "length need not be — all
	// pages containing a part of the indicated range are unmapped" (mmap(2)).
	ring_byte_size := uint(slot_count) * size_of(IO_Uring_Buffer_Entry)

	mapped, mmap_error := linux.mmap(
		0,
		ring_byte_size,
		{.READ, .WRITE},
		{.PRIVATE, .ANONYMOUS},
	)

	if mmap_error != .NONE {
		return false
	}

	ring_address := uintptr(mapped)
	mem.zero(mapped, int(ring_byte_size))

	register_arg := IO_Uring_Buffer_Ring_Register {
		ring_address     = u64(ring_address),
		ring_entry_count = u32(slot_count),
		group_id         = group_id,
		flags            = 0,
	}

	register_error := linux.io_uring_register(ring_fd, .REGISTER_PBUF_RING, &register_arg, 1)
	if register_error != .NONE {
		linux.munmap(mapped, ring_byte_size)
		return false
	}

	state.ring_address = ring_address
	state.ring_byte_size = ring_byte_size
	state.slot_size = slot_size
	state.slot_count = slot_count
	state.group_id = group_id
	state.mask = slot_count - 1
	state.active = true

	// Pre-fill every slot so the kernel can immediately consume buffers.
	for i in u16(0) ..< slot_count {
		slot_address := backing_memory_base + uintptr(i) * uintptr(slot_size)
		_provided_buffer_ring_add(state, slot_address, slot_size, i, i)
	}
	_provided_buffer_ring_advance(state, slot_count)

	return true
}

_provided_buffer_ring_deinit :: proc(state: ^Provided_Buffer_Ring_State, ring_fd: linux.Fd) {
	if !state.active {
		return
	}

	unregister_arg := IO_Uring_Buffer_Ring_Register {
		group_id = state.group_id,
	}
	linux.io_uring_register(ring_fd, .UNREGISTER_PBUF_RING, &unregister_arg, 1)
	linux.munmap(rawptr(state.ring_address), state.ring_byte_size)
	state.active = false
}
