package tina

import "base:sanitizer"

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
			start_index := int(slot_index) * descriptor.stride
			sanitizer.address_poison_rawptr(rawptr(&memory[start_index]), descriptor.stride)
		}

		if descriptor.working_memory_size > 0 {
			memory := shard.working_memory[type_id]
			start_index := int(slot_index) * descriptor.working_memory_size
			sanitizer.address_poison_rawptr(
				rawptr(&memory[start_index]),
				descriptor.working_memory_size,
			)
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
			start_index := int(slot_index) * descriptor.stride
			sanitizer.address_unpoison_rawptr(rawptr(&memory[start_index]), descriptor.stride)
		}

		if descriptor.working_memory_size > 0 {
			memory := shard.working_memory[type_id]
			start_index := int(slot_index) * descriptor.working_memory_size
			sanitizer.address_unpoison_rawptr(
				rawptr(&memory[start_index]),
				descriptor.working_memory_size,
			)
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
