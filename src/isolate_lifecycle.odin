package tina

import "core:mem"

@(private = "package")
_make_isolate :: proc(shard: ^Shard, spec: Spawn_Spec, spawner_handle: Isolate_Handle) -> Spawn_Result {
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
		entry_index, fd_err := fd_table_lookup_index(&shard.reactor.fd_table, spec.handoff_fd)
		if fd_err == .None {
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
					soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
					shard.isolate_free_heads[type_id] = slot
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
	soa_meta[slot].io_operation_kind = .None
	soa_meta[slot].io_slot_index = IO_SLOT_INDEX_NONE
	soa_meta[slot].staging_slot_index = IO_SLOT_INDEX_NONE
	soa_meta[slot].flags -= ISOLATE_FLAGS_CLEARED_ON_ALLOC

	isolate_pointer := _get_isolate_ptr(shard, type_id, slot)
	stride := shard.type_descriptors[type_id].stride
	if isolate_pointer != nil && stride > 0 {
		mem.zero(isolate_pointer, stride)
	}

	child_invocation := Isolate_Invocation {
		previous            = g_current_isolate_invocation,
		shard               = shard,
		context_token       = make_tina_context_token(shard),
		self_handle         = child_handle,
		type_id             = type_id,
		slot_index          = slot,
		shard_id            = shard.id,
		timer_resolution_ns = shard.timer_resolution_ns,
		current_tick        = shard.current_tick,
	}
	child_ctx := child_invocation.context_token

	mem.arena_init(&child_invocation.scratch_arena, shard.scratch_memory)

	working_stride := shard.type_descriptors[type_id].working_memory_size
	if working_stride > 0 {
		start_index := int(slot) * working_stride
		working_slice := shard.working_memory[type_id][start_index:start_index + working_stride]
		mem.arena_init(&child_invocation.working_arena, working_slice)
	}

	// 4. Execute init_handler
	local_spec := spec

	when TINA_SIMULATION_MODE {
		if ratio_chance(
			shard.sim_state.fault_config.init_failure_rate,
			shard.sim_state.crash_prng,
		) {
			soa_meta[slot].state = .Unallocated
			soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = slot
			_dispatchable_refresh_slot(shard, type_id, slot)
			return Spawn_Error.init_failed
		}
	}

	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_isolate_invocation = &child_invocation
	context.allocator = mem.arena_allocator(&child_invocation.working_arena)
	context.temp_allocator = mem.arena_allocator(&child_invocation.scratch_arena)

	transition := shard.type_descriptors[type_id].init_handler(
		isolate_pointer,
		local_spec.args_payload[:local_spec.args_size],
		child_ctx,
	)
	child_shutdown_pending := ctx_is_shutting_down(child_ctx)

	context.allocator = previous_allocator
	context.temp_allocator = previous_temp_allocator
	g_current_isolate_invocation = child_invocation.previous

	if working_stride > 0 {
		soa_meta[slot].working_arena_offset = u32(child_invocation.working_arena.offset)
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
	if child_shutdown_pending {
		_slot_add_shutdown_pending(shard, type_id, slot)
	}

	_interpret_transition(shard, type_id, slot, transition, &child_invocation)
	_dispatchable_refresh_slot(shard, type_id, slot)
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
	has_io_tag := soa_meta[slot_index].io_operation_kind != .None
	is_io_completion_ready := .IO_Completion_Ready in soa_meta[slot_index].flags

	if has_io_tag {
		// Completed-but-undispatched slots are owned by the scheduler and can be
		// reclaimed here. In-flight slots are reclaimed by the eventual stale
		// completion, because the token still carries the slot index.
		if is_io_completion_ready && soa_meta[slot_index].io_slot_index != IO_SLOT_INDEX_NONE {
			_io_slot_return_to_pool(
				&shard.reactor,
				io_operation_pool_affinity(soa_meta[slot_index].io_operation_kind),
				soa_meta[slot_index].io_slot_index,
			)
			soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
		}
		// Don't clear io_operation_kind yet if in-flight —
		// needed for deferred reuse check below (§5.3)
		if is_io_completion_ready {
			soa_meta[slot_index].io_operation_kind = .None
			soa_meta[slot_index].flags -= {.IO_Completion_Ready}
		}
	}
	if soa_meta[slot_index].pending_transfer_read != TRANSFER_HANDLE_NONE {
		transfer_index := transfer_handle_index(soa_meta[slot_index].pending_transfer_read)
		_transfer_pool_free(shard, transfer_index)
		soa_meta[slot_index].pending_transfer_read = TRANSFER_HANDLE_NONE
	}

	// Reclaim a claimed-but-uncommitted staging slot (ADR §5.5.3 — every exit
	// path through the handler lifecycle must free the slot). If the slot has
	// already been moved to the in-flight I/O via ctx_io_send_staged, the
	// commit path cleared this field; io_slot_index carries the slot until
	// the eventual completion reclaims it.
	if soa_meta[slot_index].staging_slot_index != IO_SLOT_INDEX_NONE {
		io_slot_pool_free(&shard.reactor.staging_pool, soa_meta[slot_index].staging_slot_index)
		soa_meta[slot_index].staging_slot_index = IO_SLOT_INDEX_NONE
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
						slot_index,
						u8(old_generation),
						soa_meta[slot_index].io_sequence,
						soa_meta[slot_index].io_slot_index,
						soa_meta[slot_index].io_operation_kind,
					)
					// On kqueue, backend_cancel synthesizes a .Synthesized
					// completion into backend.completed. On Linux/Windows
					// the kernel delivers an equivalent cancellation
					// completion (e.g. -ECANCELED CQE). Either way, the
					// next reactor_collect_completions reclaims the
					// buffer via the .Synthesized / stale / slot-gone
					// branches in io_reactor.odin.
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
	// If the Isolate has in-flight write I/O, defer slot reuse until the
	// stale completion arrives — the kernel may still be reading from struct memory.
	if has_io_tag && !is_io_completion_ready {
		existing_op_kind := soa_meta[slot_index].io_operation_kind

		// Struct-source writes are the only in-flight category whose buffer is the
		// Isolate slot itself — the kernel reads directly from struct memory until
		// the stale completion arrives, so slot reuse must be deferred (ADR §5.3).
		// Pool affinity .Staging selects writes (send/write/sendto); io_slot_index
		// == NONE then distinguishes a struct source (no pool slot) from a
		// staging-slot write (pool slot present, reactor-owned). Reads write INTO
		// the receive pool; non-data ops (accept/connect/close/sendfile) move
		// nothing — neither touches struct memory, so both are safe to reuse now.
		is_struct_source_write :=
			io_operation_pool_affinity(existing_op_kind) == .Staging &&
			soa_meta[slot_index].io_slot_index == IO_SLOT_INDEX_NONE

		if is_struct_source_write {
			_slot_track_io_awaiting_transition(shard, soa_meta[slot_index].state, .Pending_IO_Reuse)
			soa_meta[slot_index].state = .Pending_IO_Reuse
			_dispatchable_refresh_slot(shard, type_id, slot_index)

			// Still drain mailbox and invoke supervision, but skip free list push
			_drain_mailbox(shard, soa_meta, slot_index)

			if group_id != SUPERVISION_GROUP_ID_NONE {
				_on_child_exit(shard, group_id, old_handle, exit_kind)
			}
			return // Skip free list push — slot stays reserved until stale write completion
		}
		// No deferred reuse needed for these in-flight categories:
		//   1. Reads (recv/read/recvfrom)       — kernel writes INTO the receive
		//      pool, never the Isolate struct.
		//   2. Staging-slot writes (claim API)  — kernel reads from reactor-owned
		//      pool memory, freed via the token on stale completion.
		//   3. Non-data ops (accept/connect/close/sendfile) — no data movement.
		// In all three, the Isolate struct is never read by the kernel, so the
		// slot is safe to reuse immediately.
		soa_meta[slot_index].io_operation_kind = .None
		soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	}

	// Step 3: Drain mailbox
	_drain_mailbox(shard, soa_meta, slot_index)

	// Step 4: Free arena slot & push back to free list
	_slot_track_io_awaiting_transition(shard, soa_meta[slot_index].state, .Unallocated)
	soa_meta[slot_index].state = .Unallocated
	soa_meta[slot_index].inbox_head = shard.isolate_free_heads[type_id]
	shard.isolate_free_heads[type_id] = slot_index
	_dispatchable_refresh_slot(shard, type_id, slot_index)

	// Step 5: Invoke supervision subsystem (can now safely execute inline restarts)
	if group_id != SUPERVISION_GROUP_ID_NONE {
		_on_child_exit(shard, group_id, old_handle, exit_kind)
	}
}

// Drain all messages from an Isolate's mailbox, freeing transfer buffers.
@(private = "file")
_drain_mailbox :: proc(shard: ^Shard, soa_meta: #soa[]Isolate_Metadata, slot_index: u32) {
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
_get_isolate_ptr :: proc(shard: ^Shard, type_id: u16, slot: u32) -> rawptr {
	stride := shard.type_descriptors[type_id].stride
	if stride == 0 {return nil}

	assert(int(type_id) < len(shard.isolate_memory), "type_id out of bounds")
	assert(int(slot) * stride < len(shard.isolate_memory[type_id]), "slot out of bounds")

	return rawptr(&shard.isolate_memory[type_id][int(slot) * stride])
}
