package tina

import "core:mem"

@(private = "package")
_make_isolate :: proc(shard: ^Shard, spec: Spawn_Spec, spawner_handle: Handle) -> Spawn_Result {
	type_id := u16(spec.type_id)

	// 1. Slot Allocation (Popping the LIFO free list)
	slot := shard.isolate_free_heads[type_id]
	if slot == POOL_NONE_INDEX {
		return Spawn_Error.arena_full
	}

	soa_meta := shard.metadata[type_id]
	shard.isolate_free_heads[type_id] = soa_meta[slot].inbox_head

	child_generation := soa_meta[slot].generation
	child_handle := make_handle(shard.id, type_id, slot, child_generation)

	// 2. Validate FD Handoff Affinity
	if spec.handoff_fd != FD_HANDLE_NONE {
		entry, fd_err := fd_table_lookup(&shard.reactor.fd_table, spec.handoff_fd)
		if fd_err == .None {
			group: ^Supervision_Group = nil
			if spec.group_id != SUPERVISION_GROUP_ID_NONE {
				group = &shard.supervision_groups[u16(spec.group_id)]
			}

			if spec.handoff_mode == .Read_Only || spec.handoff_mode == .Write_Only {
				if group == nil || group.strategy != .One_For_All {
					_shard_log(
						shard,
						spawner_handle,
						.ERROR,
						LOG_TAG_ISOLATE_CRASHED,
						transmute([]u8)string("Split-FD handoff requires one_for_all group"),
					)
					soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
					shard.isolate_free_heads[type_id] = slot
					return Spawn_Error.init_failed
				}
			}
			can_transfer := true
			if spec.handoff_mode == .Full || spec.handoff_mode == .Read_Only {
				if entry.read_owner != spawner_handle do can_transfer = false
			}
			if spec.handoff_mode == .Full || spec.handoff_mode == .Write_Only {
				if entry.write_owner != spawner_handle do can_transfer = false
			}

			if can_transfer {
				fd_table_handoff(
					&shard.reactor.fd_table,
					spec.handoff_fd,
					child_handle,
					spec.handoff_mode,
				)
			} else {
				_shard_log(
					shard,
					spawner_handle,
					.ERROR,
					LOG_TAG_ISOLATE_CRASHED,
					transmute([]u8)string("FD handoff affinity violation"),
				)
				soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
				shard.isolate_free_heads[type_id] = slot
				return Spawn_Error.init_failed
			}
		} else {
			soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = slot
			return Spawn_Error.init_failed
		}
	}

	// 3. Initialize Isolate Memory & Context
	soa_meta[slot].state = .Runnable
	soa_meta[slot].group_id = spec.group_id
	soa_meta[slot].pending_transfer_read = TRANSFER_HANDLE_NONE

	soa_meta[slot].inbox_head = POOL_NONE_INDEX
	soa_meta[slot].inbox_tail = POOL_NONE_INDEX
	soa_meta[slot].inbox_count = 0
	soa_meta[slot].io_completion_tag = IO_TAG_NONE

	ptr := _get_isolate_ptr(shard, type_id, slot)
	stride := shard.type_descriptors[type_id].stride
	if ptr != nil && stride > 0 {
		mem.zero(ptr, stride)
	}

	child_ctx := TinaContext {
		_shard      = shard,
		self_handle = child_handle,
	}

	mem.arena_init(&child_ctx.scratch_arena, shard.scratch_memory)

	working_stride := shard.type_descriptors[type_id].working_memory_size
	if working_stride > 0 {
		start_idx := int(slot) * working_stride
		working_slice := shard.working_memory[type_id][start_idx:start_idx + working_stride]
		mem.arena_init(&child_ctx.working_arena, working_slice)
	}

	// 4. Execute init_fn
	local_spec := spec

	when TINA_SIMULATION_MODE {
		if ratio_chance(
			shard.sim_state.fault_config.init_failure_rate,
			shard.sim_state.crash_prng,
		) {
			soa_meta[slot].state = .Unallocated
			soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = slot
			return Spawn_Error.init_failed
		}
	}

	// Set up the implicit context for the user init_fn
	context.allocator = mem.arena_allocator(&child_ctx.scratch_arena)
	context.temp_allocator = mem.arena_allocator(&child_ctx.scratch_arena)

	effect := shard.type_descriptors[type_id].init_fn(
		ptr,
		local_spec.args_payload[:local_spec.args_size],
		&child_ctx,
	)

	if working_stride > 0 {
		soa_meta[slot].working_arena_offset = u32(child_ctx.working_arena.offset)
	}

	_, is_crash := effect.(Effect_Crash)
	_, is_done := effect.(Effect_Done)
	if is_crash || is_done {
		if spec.handoff_fd != FD_HANDLE_NONE {
			fd_table_handoff(
				&shard.reactor.fd_table,
				spec.handoff_fd,
				spawner_handle,
				spec.handoff_mode,
			)
		}
		_teardown_isolate(shard, type_id, slot, .Crashed)
		return Spawn_Error.init_failed
	}

	// §11: Spawns during shutdown
	if ctx_is_shutting_down(&child_ctx) {
		soa_meta[slot].flags += {.Shutdown_Pending}
	}

	_interpret_effect(shard, type_id, slot, effect, &child_ctx)
	return child_handle
}

@(private = "package")
_teardown_isolate :: proc(shard: ^Shard, type_id: u16, slot_index: u32, exit_kind: Exit_Kind) {
	soa_meta := shard.metadata[type_id]

	// Step 1: Bump generation (seal the Isolate) - 28-bit mask
	old_generation := soa_meta[slot_index].generation
	new_generation := (old_generation + 1) & 0x0FFFFFFF
	if new_generation == 0 do new_generation = 1
	soa_meta[slot_index].generation = new_generation

	// Step 2: Clear pending .call state & working arena offset
	soa_meta[slot_index].pending_correlation = 0
	soa_meta[slot_index].working_arena_offset = 0

	// Step 2b: Reclaim pending I/O and Transfer buffers
	if soa_meta[slot_index].io_completion_tag != IO_TAG_NONE {
		if soa_meta[slot_index].io_buffer_index != BUFFER_INDEX_NONE {
			reactor_buffer_pool_free(
				&shard.reactor.buffer_pool,
				soa_meta[slot_index].io_buffer_index,
			)
		}
		soa_meta[slot_index].io_completion_tag = IO_TAG_NONE
		soa_meta[slot_index].io_buffer_index = BUFFER_INDEX_NONE
	}
	if soa_meta[slot_index].pending_transfer_read != TRANSFER_HANDLE_NONE {
		idx := transfer_handle_index(soa_meta[slot_index].pending_transfer_read)
		_transfer_pool_free(shard, idx)
		soa_meta[slot_index].pending_transfer_read = TRANSFER_HANDLE_NONE
	}

	// Step 2c: FD Table Cleanup
	handle_to_match := make_handle(shard.id, type_id, slot_index, old_generation)
	in_flight_fd := soa_meta[slot_index].io_fd
	is_waiting_for_io := soa_meta[slot_index].state == .Waiting_For_Io

	for i in 0 ..< shard.reactor.fd_table.slot_count {
		entry := &shard.reactor.fd_table.entries[i]
		if entry.read_owner == HANDLE_NONE && entry.write_owner == HANDLE_NONE {
			continue
		}
		if entry.read_owner == handle_to_match || entry.write_owner == handle_to_match {
			fd_h := fd_handle_make(u16(i), entry.generation)

			if is_waiting_for_io && fd_h == in_flight_fd {
				fd_table_mark_close_on_completion(&shard.reactor.fd_table, fd_h)
			} else {
				reactor_internal_close_fd(&shard.reactor, fd_h)
			}
		}
	}

	// Step 3: Drain mailbox
	curr := soa_meta[slot_index].inbox_head
	for curr != POOL_NONE_INDEX {
		envelope := cast(^Message_Envelope)pool_get_ptr_unchecked(&shard.message_pool, curr)
		next := envelope.next_in_mailbox

		if envelope.tag == TAG_TRANSFER && envelope.payload_size >= size_of(Transfer_Handle) {
			t_handle := (cast(^Transfer_Handle)&envelope.payload[0])^
			index := transfer_handle_index(t_handle)
			generation := transfer_handle_generation(t_handle)

			if index < shard.transfer_pool.slot_count &&
			   shard.transfer_generations[index] == generation {
				_transfer_pool_free(shard, index)
			}
		}

		pool_free_unchecked(&shard.message_pool, curr)
		curr = next
	}
	soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
	soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
	soa_meta[slot_index].inbox_count = 0

	// Step 4: Invoke supervision subsystem
	group_id := soa_meta[slot_index].group_id
	if group_id != SUPERVISION_GROUP_ID_NONE {
		old_handle := make_handle(shard.id, type_id, slot_index, old_generation)
		_on_child_exit(shard, group_id, old_handle, exit_kind)
	}

	// Step 5: Free arena slot & push back to free list
	soa_meta[slot_index].state = .Unallocated
	soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
	shard.isolate_free_heads[type_id] = slot_index
}

@(private = "package")
_get_isolate_ptr :: proc(shard: ^Shard, type_id: u16, slot: u32) -> rawptr {
	stride := shard.type_descriptors[type_id].stride
	if stride == 0 {return nil}

	assert(int(type_id) < len(shard.isolate_memory), "type_id out of bounds")
	assert(int(slot) * stride < len(shard.isolate_memory[type_id]), "slot out of bounds")

	return rawptr(&shard.isolate_memory[type_id][int(slot) * stride])
}
