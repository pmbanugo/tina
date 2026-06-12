package tina

import "core:mem"

@(private = "package")
_make_isolate :: proc(shard: ^Shard, spec: Spawn_Spec, spawner_handle: Isolate_Handle) -> Spawn_Result {
	type_id := spec.type_id
	if int(type_id) >= len(shard.type_descriptors) {
		return Spawn_Error.type_not_allocated
	}

	// 1. Slot Allocation (Popping the LIFO free list)
	slot_index := shard.isolate_free_heads[type_id]
	if slot_index == POOL_NONE_INDEX {
		return Spawn_Error.arena_full
	}

	soa_meta := shard.metadata[type_id]
	shard.isolate_free_heads[type_id] = soa_meta[slot_index].inbox_head

	child_generation := soa_meta[slot_index].generation
	child_slot_index := Isolate_Slot_Index(slot_index)
	child_handle := make_handle(shard.id, type_id, child_slot_index, child_generation)

	// 2. Validate FD Handoff Affinity
	if spec.handoff_fd != FD_HANDLE_NONE {
		entry_index, fd_error := fd_table_lookup_index(&shard.reactor.fd_table, spec.handoff_fd)
		if fd_error == .None {
			entry := &shard.reactor.fd_table.entries[entry_index]
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
					soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
					shard.isolate_free_heads[type_id] = slot_index
					return Spawn_Error.init_failed
				}
			}
			can_transfer := true
			if spec.handoff_mode == .Full || spec.handoff_mode == .Read_Only {
				if entry.reader_isolate != spawner_handle do can_transfer = false
			}
			if spec.handoff_mode == .Full || spec.handoff_mode == .Write_Only {
				if entry.writer_isolate != spawner_handle do can_transfer = false
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
				soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
				shard.isolate_free_heads[type_id] = slot_index
				return Spawn_Error.init_failed
			}
		} else {
			soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = slot_index
			return Spawn_Error.init_failed
		}
	}

	// 3. Initialize Isolate memory and durable slot metadata.
	soa_meta[slot_index].state = .Runnable
	soa_meta[slot_index].group_id = spec.group_id

	soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
	soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
	soa_meta[slot_index].inbox_count = 0
	soa_meta[slot_index].io_operation_kind = .None
	soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	soa_meta[slot_index].flags -= ISOLATE_FLAGS_CLEARED_ON_ALLOC

	isolate_pointer := _get_isolate_ptr(shard, type_id, child_slot_index)
	stride := shard.type_descriptors[type_id].stride
	if isolate_pointer != nil && stride > 0 {
		mem.zero(isolate_pointer, stride)
	}

	child_turn_frame := Isolate_Turn_Frame {
		previous_isolate_turn_frame = shard.current_isolate_turn_frame,
		isolate_handle             = child_handle,
		message_source_handle      = spawner_handle,
		message_correlation_id     = CORRELATION_ID_NONE,
		transfer_read_handle       = TRANSFER_HANDLE_NONE,
		isolate_type_id            = type_id,
		isolate_slot_index         = child_slot_index,
		message_pool_index         = POOL_NONE_INDEX,
		staging_slot_index         = IO_SLOT_INDEX_NONE,
		timer_resolution_ns        = shard.timer_resolution_ns,
		current_tick               = shard.current_tick,
		phase                      = .User_Code,
	}
	parent_frame := child_turn_frame.previous_isolate_turn_frame
	child_turn_frame.scratch_arena = mem.Arena {
		data   = shard.scratch_memory,
		offset = parent_frame != nil ? parent_frame.scratch_arena.offset : 0,
	}

	working_stride := shard.type_descriptors[type_id].working_memory_size
	if working_stride > 0 {
		start_index := int(slot_index) * working_stride
		working_slice := shard.working_memory[type_id][start_index:start_index + working_stride]
		mem.arena_init(&child_turn_frame.working_arena, working_slice)
	}

	// 4. Execute init_handler
	local_spec := spec

	when TINA_SIMULATION_MODE {
		if ratio_chance(
			shard.sim_state.fault_config.init_failure_rate,
			shard.sim_state.crash_prng,
		) {
			soa_meta[slot_index].state = .Unallocated
			soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = slot_index
			_dispatchable_refresh_slot(shard, type_id, child_slot_index)
			return Spawn_Error.init_failed
		}
	}

	when TINA_SIMULATION_MODE {
		g_current_shard_pointer = shard
	}
	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	previous_trap_environment := shard.current_trap_environment
	child_turn_frame.previous_allocator = previous_allocator
	child_turn_frame.previous_temp_allocator = previous_temp_allocator

	if os_trap_save(&shard.trap_environment_init) != 0 {
		when !TINA_SIMULATION_MODE {
			free_all(context.temp_allocator)
			os_signals_restore_thread_mask()
		}

		context.allocator = child_turn_frame.previous_allocator
		context.temp_allocator = child_turn_frame.previous_temp_allocator
		if child_turn_frame.phase == .Scheduler_Commit {
			shard.current_trap_environment = nil
			shard.current_isolate_turn_frame = nil
			os_trap_restore(&shard.trap_environment_outer, RECOVERY_ROOT_ESCALATE)
		}

		shard.current_trap_environment = previous_trap_environment
		_turn_cleanup_resources(shard, &child_turn_frame)
		shard.current_isolate_turn_frame = child_turn_frame.previous_isolate_turn_frame
		if spec.handoff_fd != FD_HANDLE_NONE {
			fd_table_handoff(
				&shard.reactor.fd_table,
				spec.handoff_fd,
				spawner_handle,
				spec.handoff_mode,
			)
		}
		_teardown_isolate(shard, type_id, child_slot_index, .Crashed)
		return Spawn_Error.init_failed
	}

	shard.current_isolate_turn_frame = &child_turn_frame
	shard.current_trap_environment = &shard.trap_environment_init
	context.allocator = mem.arena_allocator(&child_turn_frame.working_arena)
	context.temp_allocator = mem.arena_allocator(&child_turn_frame.scratch_arena)

	transition := shard.type_descriptors[type_id].init_handler(
		isolate_pointer,
		local_spec.args_payload[:local_spec.args_size],
	)
	child_turn_frame.phase = .Scheduler_Commit
	child_shutdown_pending := load_watchdog_state(shard) == .Shutting_Down

	context.allocator = child_turn_frame.previous_allocator
	context.temp_allocator = child_turn_frame.previous_temp_allocator
	shard.current_trap_environment = previous_trap_environment

	if working_stride > 0 {
		soa_meta[slot_index].working_arena_offset = u32(child_turn_frame.working_arena.offset)
	}

	is_crash := transition.kind == .Crash
	is_done := transition.kind == .Done
	if is_crash {
		reason_str := ISOLATE_FAULT_REASONS_INTERPRETED[transition.fault_reason]
		_shard_log(
			shard,
			child_handle,
			.ERROR,
			LOG_TAG_ISOLATE_CRASHED,
			transmute([]u8)reason_str,
		)
	} else if is_done {
		_shard_log(
			shard,
			child_handle,
			.ERROR,
			LOG_TAG_ISOLATE_CRASHED,
			transmute([]u8)string("Init handler returned Isolate_Transition{kind = .Done}"),
		)
	}
	if is_crash || is_done {
		_turn_cleanup_resources(shard, &child_turn_frame)
		shard.current_isolate_turn_frame = child_turn_frame.previous_isolate_turn_frame
		if spec.handoff_fd != FD_HANDLE_NONE {
			fd_table_handoff(
				&shard.reactor.fd_table,
				spec.handoff_fd,
				spawner_handle,
				spec.handoff_mode,
			)
		}
		_teardown_isolate(shard, type_id, child_slot_index, .Crashed)
		return Spawn_Error.init_failed
	}

	// §11: Spawns during shutdown
	if child_shutdown_pending {
		_slot_add_shutdown_pending(shard, type_id, child_slot_index)
	}

	_interpret_transition(shard, type_id, child_slot_index, transition, &child_turn_frame)
	if soa_meta[slot_index].generation != child_generation || soa_meta[slot_index].state == .Unallocated {
		_turn_cleanup_resources(shard, &child_turn_frame)
		shard.current_isolate_turn_frame = child_turn_frame.previous_isolate_turn_frame
		return Spawn_Error.init_failed
	}
	_turn_cleanup_resources(shard, &child_turn_frame)
	shard.current_isolate_turn_frame = child_turn_frame.previous_isolate_turn_frame
	_dispatchable_refresh_slot(shard, type_id, child_slot_index)
	return child_handle
}

@(private = "package")
_teardown_isolate :: proc(shard: ^Shard, type_id: Isolate_Type_Id, slot_index: Isolate_Slot_Index, exit_kind: Exit_Kind) {
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
	has_io_tag := soa_meta[slot_index].io_operation_kind != .None
	is_io_completion_ready := .IO_Completion_Ready in soa_meta[slot_index].flags

	if has_io_tag {
		if is_io_completion_ready && soa_meta[slot_index].io_slot_index != IO_SLOT_INDEX_NONE {
			_io_slot_return_to_pool(
				&shard.reactor,
				io_operation_pool_affinity(soa_meta[slot_index].io_operation_kind),
				soa_meta[slot_index].io_slot_index,
			)
			soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
		}
		if is_io_completion_ready {
			soa_meta[slot_index].io_operation_kind = .None
			soa_meta[slot_index].flags -= {.IO_Completion_Ready}
		}
	}
	// Step 2c: FD Table Cleanup
	handle_to_match := make_handle(shard.id, type_id, slot_index, old_generation)
	in_flight_fd := soa_meta[slot_index].io_fd

		for i in 0 ..< shard.reactor.fd_table.slot_count {
			entry := &shard.reactor.fd_table.entries[i]
			if entry.reader_isolate == ISOLATE_HANDLE_NONE && entry.writer_isolate == ISOLATE_HANDLE_NONE {
				continue
			}
			if entry.reader_isolate == handle_to_match || entry.writer_isolate == handle_to_match {
				fd_h := fd_handle_make(u16(i), entry.generation)

				if has_io_tag && !is_io_completion_ready && fd_h == in_flight_fd {
					io_token := submission_token_pack(
						u8(type_id),
						u32(slot_index),
						u8(old_generation),
						soa_meta[slot_index].io_sequence,
						soa_meta[slot_index].io_slot_index,
						soa_meta[slot_index].io_operation_kind,
					)
					backend_cancel(&shard.reactor.backend, io_token)

					if io_operation_pool_affinity(soa_meta[slot_index].io_operation_kind) == .Receive {
						reactor_internal_close_fd(&shard.reactor, fd_h)
					} else {
						fd_table_mark_close_on_completion(&shard.reactor.fd_table, fd_h)
					}
				} else {
					reactor_internal_close_fd(&shard.reactor, fd_h)
				}
			}
		}

	// Extract supervision metadata BEFORE freeing the slot
	group_id := soa_meta[slot_index].group_id
	old_handle := make_handle(shard.id, type_id, slot_index, old_generation)

	// Step 2d: Deferred slot reuse for zero-copy writes (§5.3)
	if has_io_tag && !is_io_completion_ready {
		existing_op_kind := soa_meta[slot_index].io_operation_kind

		is_struct_source_write :=
			io_operation_pool_affinity(existing_op_kind) == .Staging &&
			soa_meta[slot_index].io_slot_index == IO_SLOT_INDEX_NONE

		if is_struct_source_write {
			_slot_track_io_awaiting_transition(shard, soa_meta[slot_index].state, .Pending_IO_Reuse)
			soa_meta[slot_index].state = .Pending_IO_Reuse
			_dispatchable_refresh_slot(shard, type_id, slot_index)

			_drain_mailbox(shard, soa_meta, slot_index)

			if group_id != SUPERVISION_GROUP_ID_NONE {
				_on_child_exit(shard, group_id, old_handle, exit_kind)
			}
			return
		}
		soa_meta[slot_index].io_operation_kind = .None
		soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	}

	// Step 3: Drain mailbox
	_drain_mailbox(shard, soa_meta, slot_index)

	// Step 4: Free arena slot & push back to free list
	_slot_track_io_awaiting_transition(shard, soa_meta[slot_index].state, .Unallocated)
	soa_meta[slot_index].state = .Unallocated
	soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
	shard.isolate_free_heads[type_id] = u32(slot_index)
	_dispatchable_refresh_slot(shard, type_id, slot_index)

	// Step 5: Invoke supervision subsystem
	if group_id != SUPERVISION_GROUP_ID_NONE {
		_on_child_exit(shard, group_id, old_handle, exit_kind)
	}
}

// Drain all messages from an Isolate's mailbox, freeing transfer buffers.
@(private = "file")
_drain_mailbox :: proc(shard: ^Shard, soa_meta: #soa[]Isolate_Metadata, slot_index: Isolate_Slot_Index) {
	current := soa_meta[slot_index].inbox_head
	for current != POOL_NONE_INDEX {
		envelope := pool_get_ptr_unchecked(&shard.message_pool, current)
		next := envelope.next_in_mailbox

		if envelope.tag == TAG_TRANSFER && envelope.payload_size >= size_of(Transfer_Handle) {
			transfer_handle := (cast(^Transfer_Handle)&envelope.payload[0])^
			index := transfer_handle_index(transfer_handle)
			generation := transfer_handle_generation(transfer_handle)

			if u16(index) < shard.transfer_pool.slot_count &&
			   shard.transfer_generations[index] == generation {
				_transfer_pool_free(shard, index)
			}
		}

		pool_free_unchecked(&shard.message_pool, current)
		current = next
	}
	soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
	soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
	soa_meta[slot_index].inbox_count = 0
}

@(private = "package")
_get_isolate_ptr :: proc(shard: ^Shard, type_id: Isolate_Type_Id, slot_index: Isolate_Slot_Index) -> rawptr {
	stride := shard.type_descriptors[type_id].stride
	if stride == 0 {return nil}

	assert(int(type_id) < len(shard.isolate_memory), "type_id out of bounds")
	assert(int(slot_index) * stride < len(shard.isolate_memory[type_id]), "slot_index out of bounds")

	return rawptr(&shard.isolate_memory[type_id][int(slot_index) * stride])
}
