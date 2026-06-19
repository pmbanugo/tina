package tina

import "base:sanitizer"
import "core:mem"

_ :: sanitizer

TINA_ASAN_POISONING :: .Address in ODIN_SANITIZER_FLAGS

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

		payload_pointer := rawptr(uintptr(slot_pointer) + uintptr(free_word_size))
		payload_size := slot_size - free_word_size
		sanitizer.address_poison_rawptr(payload_pointer, payload_size)
	}
}

@(private = "package")
_sanitizer_address_poison_message_slot_payload :: #force_inline proc "contextless" (
	pool: ^Message_Pool,
	index: u32,
) {
	when TINA_ASAN_POISONING {
		slot_pointer := rawptr(&pool.buffer[index << pool.slot_shift])
		_sanitizer_address_poison_free_slot_payload(
			slot_pointer,
			int(pool.slot_size),
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
		slot_pointer := rawptr(&pool.buffer[index << pool.slot_shift])
		sanitizer.address_unpoison_rawptr(slot_pointer, int(pool.slot_size))
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
			size_of(IO_Slot_Index),
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

@(private = "package")
_sanitizer_address_poison_isolate_slot :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	when TINA_ASAN_POISONING {
		descriptor := shard.type_descriptors[type_id]
		if descriptor.stride > 0 {
			memory := shard.isolate_memory[type_id]
			// The fixture builder may fail after setting a type descriptor but before
			// carving its backing memory. Guarding len() here prevents a nil-slice
			// indexing panic during teardown unpoison while keeping the success path
			// a single compare+branch.
			if len(memory) > 0 {
				start_index := int(slot_index) * descriptor.stride
				sanitizer.address_poison_rawptr(rawptr(&memory[start_index]), descriptor.stride)
			}
		}

		if descriptor.working_memory_size > 0 {
			memory := shard.working_memory[type_id]
			if len(memory) > 0 {
				start_index := int(slot_index) * descriptor.working_memory_size
				sanitizer.address_poison_rawptr(
					rawptr(&memory[start_index]),
					descriptor.working_memory_size,
				)
			}
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
		descriptor := shard.type_descriptors[type_id]
		if descriptor.stride > 0 {
			memory := shard.isolate_memory[type_id]
			// See the matching guard in _sanitizer_address_poison_isolate_slot.
			if len(memory) > 0 {
				start_index := int(slot_index) * descriptor.stride
				sanitizer.address_unpoison_rawptr(rawptr(&memory[start_index]), descriptor.stride)
			}
		}

		if descriptor.working_memory_size > 0 {
			memory := shard.working_memory[type_id]
			if len(memory) > 0 {
				start_index := int(slot_index) * descriptor.working_memory_size
				sanitizer.address_unpoison_rawptr(
					rawptr(&memory[start_index]),
					descriptor.working_memory_size,
				)
			}
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
	}
}
