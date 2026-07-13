package tina

import "base:sanitizer"
import "core:mem"

_ :: sanitizer

TINA_ASAN_POISONING :: .Address in ODIN_SANITIZER_FLAGS
ASAN_POISON_GRANULE_SIZE :: 8

@(private = "package")
_sanitizer_address_poison_raw :: #force_inline proc "contextless" (pointer: rawptr, size: int) {
	when TINA_ASAN_POISONING {
		if pointer != nil && size > 0 {
			sanitizer.address_poison_rawptr(pointer, size)
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_raw :: #force_inline proc "contextless" (pointer: rawptr, size: int) {
	when TINA_ASAN_POISONING {
		if pointer != nil && size > 0 {
			sanitizer.address_unpoison_rawptr(pointer, size)
		}
	}
}

// Poison the portion of a working arena that has been allocated since the last
// reset. This makes stale pointers into logically-freed working arena
// allocations visible to ASan. The unpoison side is handled by the ASan-aware
// working-arena allocator wrapper, which unpoisons each freshly-allocated
// range before returning it to the caller.
@(private = "package")
_sanitizer_address_poison_working_arena :: #force_inline proc "contextless" (arena: ^mem.Arena) {
	when TINA_ASAN_POISONING {
		if arena != nil && arena.offset > 0 {
			_sanitizer_address_poison_raw(raw_data(arena.data), arena.offset)
		}
	}
}

@(private = "package")
_sanitizer_address_poison_free_slot_payload :: #force_inline proc "contextless" (
	slot_pointer: rawptr,
	slot_size: int,
	free_word_size: int,
) {
	when TINA_ASAN_POISONING {
		if slot_pointer == nil || slot_size <= free_word_size {
			return
		}

		slot_bytes := mem.byte_slice(slot_pointer, slot_size)
		payload := slot_bytes[free_word_size:]
		sanitizer.address_poison_rawptr(raw_data(payload), len(payload))
	}
}

@(private = "package")
_sanitizer_address_poison_message_slot_payload :: #force_inline proc "contextless" (
	pool: ^Message_Pool,
	index: u32,
) {
	when TINA_ASAN_POISONING {
		slot_pointer := rawptr(&pool.backing[index])
		_sanitizer_address_poison_free_slot_payload(
			slot_pointer,
			size_of(Message_Envelope),
			size_of(u32),
		)
	}
}

@(private = "package")
_sanitizer_address_unpoison_message_slot :: #force_inline proc "contextless" (
	pool: ^Message_Pool,
	index: u32,
) {
	when TINA_ASAN_POISONING {
		slot_pointer := rawptr(&pool.backing[index])
		sanitizer.address_unpoison_rawptr(slot_pointer, size_of(Message_Envelope))
	}
}

@(private = "package")
_sanitizer_address_poison_io_slot_payload :: #force_inline proc "contextless" (
	pool: ^IO_Slot_Pool,
	index: IO_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		slot_pointer := rawptr(_io_slot_pool_pointer(pool, index))
		_sanitizer_address_poison_free_slot_payload(
			slot_pointer,
			int(pool.slot_size),
			size_of(IO_Slot_Link),
		)
	}
}

@(private = "package")
_sanitizer_address_poison_io_slot :: #force_inline proc "contextless" (
	pool: ^IO_Slot_Pool,
	index: IO_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		slot_pointer := rawptr(_io_slot_pool_pointer(pool, index))
		sanitizer.address_poison_rawptr(slot_pointer, int(pool.slot_size))
	}
}

@(private = "package")
_sanitizer_address_unpoison_io_slot :: #force_inline proc "contextless" (
	pool: ^IO_Slot_Pool,
	index: IO_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		slot_pointer := rawptr(_io_slot_pool_pointer(pool, index))
		sanitizer.address_unpoison_rawptr(slot_pointer, int(pool.slot_size))
	}
}

// Poison a pool-backed I/O buffer that has left handler ownership and is now
// owned by the backend/kernel until completion. The return-to-pool path
// unpoisons the intrusive free-list word before writing it, so in-flight slots
// can be fully poisoned and stale first-word accesses are still caught.
@(private = "package")
_sanitizer_address_poison_inflight_io_slot :: #force_inline proc "contextless" (
	reactor: ^Reactor,
	affinity: IO_Slot_Pool_Affinity,
	index: IO_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		switch affinity {
		case .Receive:
			_sanitizer_address_poison_io_slot(&reactor.receive_pool, index)
		case .Staging:
			_sanitizer_address_poison_io_slot(&reactor.staging_pool, index)
		case .None:
		}
	}
}

@(private = "package")
_sanitizer_address_poison_io_pool_slots :: proc "contextless" (pool: ^IO_Slot_Pool) {
	when TINA_ASAN_POISONING {
		for index in 0 ..< pool.slot_count {
			_sanitizer_address_poison_io_slot(pool, IO_Slot_Index(index))
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_message_pool_slots :: proc "contextless" (pool: ^Message_Pool) {
	when TINA_ASAN_POISONING {
		for index in 0 ..< pool.slot_count {
			_sanitizer_address_unpoison_message_slot(pool, index)
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_io_pool_slots :: proc "contextless" (pool: ^IO_Slot_Pool) {
	when TINA_ASAN_POISONING {
		for index in 0 ..< pool.slot_count {
			_sanitizer_address_unpoison_io_slot(pool, IO_Slot_Index(index))
		}
	}
}

@(private = "file")
_sanitizer_address_get_isolate_memory_row_if_backed :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) -> []u8 {
	when TINA_ASAN_POISONING {
		if shard == nil {
			return {}
		}

		type_index := int(type_id)
		if type_index >= len(shard.type_descriptors) || type_index >= len(shard.isolate_memory) {
			return {}
		}

		descriptor := shard.type_descriptors[type_index]
		if descriptor.slot_count <= 0 || descriptor.stride <= 0 || int(slot_index) >= descriptor.slot_count {
			return {}
		}

		memory := shard.isolate_memory[type_index]
		if descriptor.stride > len(memory) / descriptor.slot_count {
			return {}
		}

		start_index := int(slot_index) * descriptor.stride
		return memory[start_index:start_index + descriptor.stride]
	}

	return {}
}

@(private = "file")
_sanitizer_address_get_isolate_working_memory_row_if_backed :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) -> []u8 {
	when TINA_ASAN_POISONING {
		if shard == nil {
			return {}
		}

		type_index := int(type_id)
		if type_index >= len(shard.type_descriptors) || type_index >= len(shard.working_memory) {
			return {}
		}

		descriptor := shard.type_descriptors[type_index]
		if descriptor.slot_count <= 0 ||
		   descriptor.working_memory_size <= 0 ||
		   int(slot_index) >= descriptor.slot_count {
			return {}
		}

		memory := shard.working_memory[type_index]
		if descriptor.working_memory_size > len(memory) / descriptor.slot_count {
			return {}
		}

		start_index := int(slot_index) * descriptor.working_memory_size
		return memory[start_index:start_index + descriptor.working_memory_size]
	}

	return {}
}

@(private = "package")
_sanitizer_address_poison_isolate_slot :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		// The fixture builder may fail after setting a type descriptor but before
		// carving its backing memory. These ASan hooks therefore use a cleanup-only
		// optional row accessor. normal row accessors assert on broken geometry.
		memory := _sanitizer_address_get_isolate_memory_row_if_backed(shard, type_id, slot_index)
		if len(memory) > 0 {
			sanitizer.address_poison_rawptr(raw_data(memory), len(memory))
		}

		working_memory := _sanitizer_address_get_isolate_working_memory_row_if_backed(shard, type_id, slot_index)
		if len(working_memory) > 0 {
			sanitizer.address_poison_rawptr(raw_data(working_memory), len(working_memory))
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_isolate_slot :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		memory := _sanitizer_address_get_isolate_memory_row_if_backed(shard, type_id, slot_index)
		if len(memory) > 0 {
			sanitizer.address_unpoison_rawptr(raw_data(memory), len(memory))
		}

		working_memory := _sanitizer_address_get_isolate_working_memory_row_if_backed(shard, type_id, slot_index)
		if len(working_memory) > 0 {
			sanitizer.address_unpoison_rawptr(raw_data(working_memory), len(working_memory))
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_reactor_io_slot :: #force_inline proc "contextless" (
	reactor: ^Reactor,
	affinity: IO_Slot_Pool_Affinity,
	index: IO_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		if index == IO_SLOT_INDEX_NONE {
			return
		}

		switch affinity {
		case .Receive:
			_sanitizer_address_unpoison_io_slot(&reactor.receive_pool, index)
		case .Staging:
			_sanitizer_address_unpoison_io_slot(&reactor.staging_pool, index)
		case .None:
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_shard_memory :: proc "contextless" (shard: ^Shard) {
	when TINA_ASAN_POISONING {
		if shard == nil {
			return
		}

		// address_unpoison is idempotent on already-clean memory, so iterating
		// all slots — including active ones — is correct and keeps teardown simple.
		for descriptor in shard.type_descriptors {
			for slot in 0 ..< descriptor.slot_count {
				_sanitizer_address_unpoison_isolate_slot(
					shard,
					descriptor.id,
					Isolate_Slot_Index(slot),
				)
			}
		}

		_sanitizer_address_unpoison_message_pool_slots(&shard.message_pool)
		_sanitizer_address_unpoison_io_pool_slots(&shard.transfer_pool)
		_sanitizer_address_unpoison_io_pool_slots(&shard.reactor.receive_pool)
		_sanitizer_address_unpoison_io_pool_slots(&shard.reactor.staging_pool)
		for &entry in shard.reactor.fd_table.entries {
			_sanitizer_address_unpoison_raw(rawptr(&entry.payload), size_of(entry.payload))
		}
		_sanitizer_address_unpoison_log_ring(&shard.log_ring)
	}
}

@(private = "package")
_sanitizer_address_poison_spsc_ring_slots :: proc "contextless" (
	ring: ^SPSC_Ring,
	sequence_start: u64,
	count: u64,
) {
	when TINA_ASAN_POISONING {
		if ring == nil || ring.buffer == nil || count == 0 {
			return
		}

		slot_size := size_of(Message_Envelope)
		for offset in 0 ..< count {
			slot_index := (sequence_start + offset) & ring.capacity_mask
			slot_pointer := rawptr(&ring.buffer[slot_index])
			sanitizer.address_poison_rawptr(slot_pointer, slot_size)
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_spsc_ring_slot :: #force_inline proc "contextless" (
	ring: ^SPSC_Ring,
	index: u64,
) {
	when TINA_ASAN_POISONING {
		if ring == nil || ring.buffer == nil {
			return
		}

		slot_index := index & ring.capacity_mask
		slot_pointer := rawptr(&ring.buffer[slot_index])
		sanitizer.address_unpoison_rawptr(slot_pointer, size_of(Message_Envelope))
	}
}

@(private = "package")
_sanitizer_address_unpoison_spsc_ring_slots :: proc "contextless" (ring: ^SPSC_Ring) {
	when TINA_ASAN_POISONING {
		if ring == nil || ring.buffer == nil {
			return
		}

		for index in 0 ..< ring.capacity {
			_sanitizer_address_unpoison_spsc_ring_slot(ring, index)
		}
	}
}

// Log-ring byte lifetime helpers.
//
// A log-ring byte is reusable while it is outside the committed live interval
// (read_cursor, write_cursor). Poison marks reusable bytes; unpoison makes live
// records visible to ASan. Region helpers split at the physical ring edge so
// monotonic cursor arithmetic can address the circular buffer directly.

@(private = "package")
_sanitizer_address_poison_log_ring_region :: proc "contextless" (
	ring: ^Log_Ring_Buffer,
	offset: u64,
	size: u64,
) {
	when TINA_ASAN_POISONING {
		if ring == nil || len(ring.buffer) == 0 || size == 0 {
			return
		}

		capacity := ring.capacity_mask + 1
		start := offset & ring.capacity_mask

		if start + size <= capacity {
			sanitizer.address_poison_rawptr(rawptr(&ring.buffer[start]), int(size))
		} else {
			first_size := capacity - start
			sanitizer.address_poison_rawptr(rawptr(&ring.buffer[start]), int(first_size))
			sanitizer.address_poison_rawptr(
				rawptr(&ring.buffer[0]),
				int(size - first_size),
			)
		}
	}
}

@(private = "package")
_sanitizer_address_unpoison_log_ring_region :: proc "contextless" (
	ring: ^Log_Ring_Buffer,
	offset: u64,
	size: u64,
) {
	when TINA_ASAN_POISONING {
		if ring == nil || len(ring.buffer) == 0 || size == 0 {
			return
		}

		capacity := ring.capacity_mask + 1
		start := offset & ring.capacity_mask

		if start + size <= capacity {
			sanitizer.address_unpoison_rawptr(rawptr(&ring.buffer[start]), int(size))
		} else {
			first_size := capacity - start
			sanitizer.address_unpoison_rawptr(rawptr(&ring.buffer[start]), int(first_size))
			sanitizer.address_unpoison_rawptr(
				rawptr(&ring.buffer[0]),
				int(size - first_size),
			)
		}
	}
}

// Recompute the log-ring poison state from the current cursors. Used at
// non-signal recovery safe points after emergency_log_flush_signal advances
// read_cursor from a signal handler.
@(private = "package")
_sanitizer_address_refresh_log_ring_poison :: proc "contextless" (ring: ^Log_Ring_Buffer) {
	when TINA_ASAN_POISONING {
		if ring == nil || len(ring.buffer) == 0 {
			return
		}

		capacity := ring.capacity_mask + 1
		sanitizer.address_poison_rawptr(raw_data(ring.buffer), int(capacity))

		if ring.write_cursor > ring.read_cursor {
			_sanitizer_address_unpoison_log_ring_region(
				ring,
				ring.read_cursor,
				ring.write_cursor - ring.read_cursor,
			)
		}
	}
}

// Unpoison the whole backing buffer before the containing allocation is freed.
@(private = "package")
_sanitizer_address_unpoison_log_ring :: proc "contextless" (ring: ^Log_Ring_Buffer) {
	when TINA_ASAN_POISONING {
		if ring == nil || len(ring.buffer) == 0 {
			return
		}

		sanitizer.address_unpoison_rawptr(raw_data(ring.buffer), len(ring.buffer))
	}
}
