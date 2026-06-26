package tina

import "core:mem"

@(private = "package")
Staged_Call :: struct {
	envelope:   Message_Envelope,
	timeout_ns: u64,
}

// Mutually exclusive control-plane staging for the current turn.
@(private = "package")
Staged_Effect_Kind :: enum u8 {
	None,
	Call,
	IO,
}

@(private = "package")
Staged_IO :: struct {
	operation:      IoOp,
	data_source:    IO_Data_Source,
	payload_offset: u16,
	payload_size:   u32,
}

@(private = "package")
Staged_Effect :: struct {
	kind: Staged_Effect_Kind,
	call: Staged_Call,
	io:   Staged_IO,
}

@(private = "package")
Isolate_Turn_Phase :: enum u8 {
	User_Code,
	Scheduler_Commit,
}

@(private = "package")
Isolate_Turn_Frame :: struct {
	previous_isolate_turn_frame: ^Isolate_Turn_Frame,
	staged_effect:               Staged_Effect,
	working_arena:               mem.Arena,
	scratch_arena:               mem.Arena,
	previous_allocator:          mem.Allocator,
	previous_temp_allocator:     mem.Allocator,
	isolate_handle:              Isolate_Handle,
	message_source_handle:       Isolate_Handle,
	message_correlation_id:      Correlation_Id,
	transfer_read_handle:        Transfer_Handle,
	current_tick:                u64,
	timer_resolution_ns:         u64,
	message_pool_index:          u32,
	isolate_slot_index:          Isolate_Slot_Index,
	isolate_type_id:             Isolate_Type_Id,
	staging_slot_index:          IO_Slot_Index,
	turn_flags:                  Isolate_Turn_Flags,
	phase:                       Isolate_Turn_Phase,
	reply_sent:                  bool,
}

// Read the active staging claim slot index. Returns IO_SLOT_INDEX_NONE if
// no claim is active.
@(require_results)
_staging_claim_read :: #force_inline proc(frame: ^Isolate_Turn_Frame) -> IO_Slot_Index {
	return frame.staging_slot_index
}

// Set or clear the active staging claim. Pass IO_SLOT_INDEX_NONE to clear.
_staging_claim_write :: #force_inline proc(frame: ^Isolate_Turn_Frame, value: IO_Slot_Index) {
	frame.staging_slot_index = value
}

@(private = "package")
_current_isolate_turn_frame :: #force_inline proc() -> (^Shard, ^Isolate_Turn_Frame) {
	shard := g_current_shard_pointer
	when TINA_RUNTIME_ASSERTIONS {
		assert(shard != nil, "ctx_* called outside Tina shard thread")
	}

	frame := shard.current_isolate_turn_frame
	when TINA_RUNTIME_ASSERTIONS {
		assert(frame != nil, "ctx_* called outside active Tina isolate turn")
		assert(frame.phase == .User_Code, "ctx_* called outside user-code phase")
	}

	return shard, frame
}

@(private = "file")
_send_result_to_reply_result :: #force_inline proc "contextless" (
	result: Send_Result,
) -> Reply_Result {
	switch result {
	case .ok:
		return .ok
	case .mailbox_full:
		return .mailbox_full
	case .pool_exhausted:
		return .pool_exhausted
	case .stale_handle:
		return .stale_handle
	}
	return .stale_handle
}

@(private = "package")
_current_isolate_turn_frame_require_handle :: #force_inline proc(
) -> (
	^Shard,
	^Isolate_Turn_Frame,
) {
	shard, frame := _current_isolate_turn_frame()
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			frame.isolate_handle != ISOLATE_HANDLE_NONE,
			"_current_isolate_turn_frame_require_handle API requires a live Isolate handle.",
		)
	}
	return shard, frame
}

@(require_results)
ctx_send_raw :: #force_inline proc(
	to: Isolate_Handle,
	$tag: Message_Tag,
	payload: []u8,
) -> Send_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_send: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	shard, frame := _current_isolate_turn_frame_require_handle()

	envelope: Message_Envelope
	envelope.source = frame.isolate_handle
	envelope.destination = to
	envelope.tag = tag
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	response := _route_envelope_user(shard, to, &envelope)
	return response
}

@(require_results)
ctx_reply_raw :: #force_inline proc(
	$tag: Message_Tag,
	payload: []u8,
	caller_location := #caller_location,
) -> Reply_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_reply: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			len(payload) <= MAX_PAYLOAD_SIZE,
			"ctx_reply payload exceeds MAX_PAYLOAD_SIZE",
			caller_location,
		)
	}

	shard, frame := _current_isolate_turn_frame_require_handle()
	if frame.reply_sent {
		return .already_replied
	}
	if .Is_Call not_in frame.turn_flags {
		return .not_call_context
	}

	envelope: Message_Envelope
	envelope.source = frame.isolate_handle
	envelope.destination = frame.message_source_handle
	envelope.correlation = frame.message_correlation_id
	envelope.flags += {.Is_Reply}
	envelope.tag = tag
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	result := _send_result_to_reply_result(
		_route_envelope_reply(shard, frame.message_source_handle, &envelope),
	)
	if result == .ok {
		frame.reply_sent = true
	}
	return result
}

@(require_results)
ctx_reply_typed :: #force_inline proc(
	$tag: Message_Tag,
	message: ^$T,
	caller_location := #caller_location,
) -> Reply_Result where size_of(T) <=
	MAX_PAYLOAD_SIZE {
	return ctx_reply_raw(tag, mem.byte_slice(message, size_of(T)), caller_location)
}

ctx_reply :: proc {
	ctx_reply_raw,
	ctx_reply_typed,
}

// Reserves a shard-local correlation id for a logical parked wait.
@(require_results)
ctx_reserve_correlation_id :: #force_inline proc() -> Correlation_Id {
	shard, _ := _current_isolate_turn_frame()
	shard.next_correlation_id += 1
	if shard.next_correlation_id == 0 do shard.next_correlation_id = 1
	return Correlation_Id(shard.next_correlation_id)
}

// Sends an inline message with an explicit correlation id.
@(require_results)
ctx_send_with_correlation :: #force_inline proc(
	to: Isolate_Handle,
	$tag: Message_Tag,
	payload: []u8,
	correlation_id: Correlation_Id,
	caller_location := #caller_location,
) -> Send_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_send_with_correlation: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			len(payload) <= MAX_PAYLOAD_SIZE,
			"ctx_send_with_correlation payload exceeds MAX_PAYLOAD_SIZE",
			caller_location,
		)
	}
	shard, frame := _current_isolate_turn_frame_require_handle()

	envelope: Message_Envelope
	envelope.source = frame.isolate_handle
	envelope.destination = to
	envelope.tag = tag
	envelope.correlation = correlation_id
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	return _route_envelope_user(shard, to, &envelope)
}

// Sends an inline transfer-buffer handle with an explicit correlation id.
@(require_results)
ctx_transfer_send_with_correlation :: #force_inline proc(
	to: Isolate_Handle,
	handle: Transfer_Handle,
	correlation_id: Correlation_Id,
) -> Send_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()
	envelope: Message_Envelope
	envelope.source = frame.isolate_handle
	envelope.destination = to
	envelope.tag = TAG_TRANSFER
	envelope.correlation = correlation_id
	envelope.payload_size = size_of(Transfer_Handle)

	(cast(^Transfer_Handle)&envelope.payload[0])^ = handle

	return _route_envelope_user(shard, to, &envelope)
}

// Stages a request-reply call. The scheduler commits the staged envelope only if
// the handler returns Isolate_Transition{kind = .Wait_Reply}.
@(require_results)
ctx_call_raw :: #force_inline proc(
	to: Isolate_Handle,
	$tag: Message_Tag,
	payload: []u8,
	timeout_ns: u64,
	caller_location := #caller_location,
) -> Call_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_call: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			len(payload) <= MAX_PAYLOAD_SIZE,
			"ctx_call payload exceeds MAX_PAYLOAD_SIZE",
			caller_location,
		)
		assert(timeout_ns > 0, "ctx_call timeout_ns must be > 0", caller_location)
	}

	shard, frame := _current_isolate_turn_frame_require_handle()
	if frame.staged_effect.kind != .None {
		return .already_staged
	}

	target_shard_id := extract_shard_id(to)
	if target_shard_id != shard.id {
		if target_shard_id >= Shard_Id(shard.shard_count) {
			return .stale_handle
		}
		if !shard_mask_contains(&shard.peer_alive_mask, target_shard_id) {
			return .target_quarantined
		}
	} else {
		target_type_id := extract_type_id(to)
		target_slot_index := extract_slot(to)
		if int(target_type_id) >= len(shard.metadata) {
			return .stale_handle
		}
		target_meta := shard.metadata[target_type_id]
		if int(target_slot_index) >= len(target_meta) {
			return .stale_handle
		}
		if target_meta[target_slot_index].generation != extract_generation(to) {
			return .stale_handle
		}
		if target_meta[target_slot_index].inbox_count >=
		   shard.type_descriptors[target_type_id].mailbox_capacity {
			return .mailbox_full
		}
	}

	correlation_id := ctx_reserve_correlation_id()
	frame.staged_effect.kind = .Call
	frame.staged_effect.call.timeout_ns = timeout_ns
	frame.staged_effect.call.envelope = {}
	frame.staged_effect.call.envelope.destination = to
	frame.staged_effect.call.envelope.correlation = correlation_id
	frame.staged_effect.call.envelope.tag = tag
	frame.staged_effect.call.envelope.payload_size = u16(len(payload))
	copy(frame.staged_effect.call.envelope.payload[:], payload)
	return .ok
}

@(require_results)
ctx_call_typed :: #force_inline proc(
	to: Isolate_Handle,
	$tag: Message_Tag,
	message: ^$T,
	timeout_ns: u64,
	caller_location := #caller_location,
) -> Call_Result where size_of(T) <=
	MAX_PAYLOAD_SIZE {
	return ctx_call_raw(to, tag, mem.byte_slice(message, size_of(T)), timeout_ns, caller_location)
}

ctx_call :: proc {
	ctx_call_raw,
	ctx_call_typed,
}

ctx_transfer_send :: #force_inline proc(
	to: Isolate_Handle,
	handle: Transfer_Handle,
) -> Send_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()
	envelope: Message_Envelope
	envelope.source = frame.isolate_handle
	envelope.destination = to
	envelope.tag = TAG_TRANSFER
	envelope.payload_size = size_of(Transfer_Handle)

	(cast(^Transfer_Handle)&envelope.payload[0])^ = handle

	return _route_envelope_user(shard, to, &envelope)
}

// Spawns a new Isolate and attaches it to the specified supervision group.
@(require_results)
ctx_spawn :: #force_inline proc(spec: Spawn_Spec) -> Spawn_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()

	if int(spec.type_id) >= len(shard.type_descriptors) {
		return Spawn_Error.type_not_allocated
	}

	group: ^Supervision_Group = nil
	child_index_reserved: u16
	if spec.group_id != SUPERVISION_GROUP_ID_NONE {
		if int(spec.group_id) >= len(shard.supervision_groups) {
			return Spawn_Error.group_not_allocated
		}

		group = &shard.supervision_groups[u16(spec.group_id)]
		if group.boot_spec == nil || group.group_id != spec.group_id {
			return Spawn_Error.group_not_allocated
		}

		_assert_group_layout(group)
		if group.child_count_dynamic >= u16(len(group.dynamic_specs)) {
			return Spawn_Error.group_full
		}

		child_index_reserved = group.child_count_static + group.child_count_dynamic
		group.children_handles[child_index_reserved] = ISOLATE_HANDLE_NONE

		dyn := &group.dynamic_specs[group.child_count_dynamic]
		dyn.type_id = spec.type_id
		dyn.restart_type = spec.restart_type
		dyn.args_size = spec.args_size
		dyn.args_payload = spec.args_payload
		group.child_count_dynamic += 1
	}

	spawn_result := _make_isolate(shard, spec, frame.isolate_handle)

	child_handle, ok := spawn_result.(Isolate_Handle)
	if !ok {
		if group != nil {
			_remove_child_at(group, child_index_reserved)
		}
		return spawn_result
	}

	if group != nil {
		_assert_group_layout(group)
		group.children_handles[child_index_reserved] = child_handle
	}

	return child_handle
}

@(require_results)
ctx_fd_handoff :: #force_inline proc(to: Isolate_Handle, fd: FD_Handle) -> FD_Handoff_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()

	if to == ISOLATE_HANDLE_NONE || extract_shard_id(to) == shard.id {
		return .not_remote_target
	}

	when !TINA_SIMULATION_MODE {
		when ODIN_OS == .Windows {
			return .unsupported
		}
	}

	cleanup_fd, peer_address, export_result := reactor_export_fd_handoff(
		&shard.reactor,
		fd,
		frame.isolate_handle,
	)
	if export_result != .ok {
		return export_result
	}

	deadline_tick := shard.current_tick + FD_HANDOFF_TIMEOUT_TICKS
	handoff_ref, handoff_alloc_error := fd_handoff_table_alloc(
		&shard.handoff_table,
		to,
		cleanup_fd,
		peer_address,
		deadline_tick,
		shard.id,
	)
	if handoff_alloc_error != .None {
		_ = backend_control_close(&shard.reactor.backend, cleanup_fd)
		shard.counters.handoff_exhaustions += 1
		return .handoff_table_full
	}

	msg_envelope: Message_Envelope
	msg_envelope.source = frame.isolate_handle
	msg_envelope.destination = to
	msg_envelope.tag = TAG_FD_HANDOFF_OFFER
	msg_envelope.payload_size = u16(size_of(FD_Handoff_Offer))
	(cast(^FD_Handoff_Offer)&msg_envelope.payload[0])^ = FD_Handoff_Offer {
		handoff      = handoff_ref,
		os_fd        = cleanup_fd,
		peer_address = peer_address,
	}

	route_result := _route_envelope_system(shard, to, &msg_envelope)
	if route_result != .ok {
		_ = _fd_handoff_close_entry(shard, handoff_ref)
		switch route_result {
		case .ok:
			return .ok
		case .mailbox_full:
			return .transport_full
		case .stale_handle:
			return .transport_unavailable
		case .pool_exhausted:
			return .transport_full
		}
	}

	return .ok
}

ctx_self_handle :: #force_inline proc() -> Isolate_Handle {
	_, frame := _current_isolate_turn_frame()
	return frame.isolate_handle
}

when TINA_SIMULATION_MODE {
	// Write a scalar diagnostic fact for the currently executing isolate.
	// This is a simulation-only control-plane observation API; handlers use it
	// to record facts while payload memory is live so tests can assert on dense
	// scalar records instead of reading freed isolate slots.
	ctx_test_diagnostic_write_u64 :: #force_inline proc(field_id: Diagnostic_Field_Id, value: u64) {
		shard, frame := _current_isolate_turn_frame_require_handle()
		shard_diagnostic_write(
			shard,
			frame.isolate_type_id,
			frame.isolate_slot_index,
			field_id,
			value,
		)
	}
}

// Acquire a pre-allocated timer slot. Returns a handle.
@(require_results)
ctx_timer_acquire :: #force_inline proc() -> Timer_Handle {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return timer_acquire(&shard.timer_wheel, frame.isolate_handle)
}

// Release an acquired timer slot back to the pool.
ctx_timer_release :: #force_inline proc(handle: Timer_Handle) {
	shard, _ := _current_isolate_turn_frame_require_handle()
	timer_release(&shard.timer_wheel, handle)
}

// Re-arm an existing timer with a new duration.
ctx_timer_rearm :: #force_inline proc(
	handle: Timer_Handle,
	duration_ns: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	shard, frame := _current_isolate_turn_frame_require_handle()
	timer_rearm(
		&shard.timer_wheel,
		handle,
		frame.current_tick + _duration_ns_to_ticks(duration_ns, frame.timer_resolution_ns),
		tag,
		correlation,
	)
}

// Cancel (disarm) a timer.
ctx_timer_cancel :: #force_inline proc(handle: Timer_Handle) {
	shard, _ := _current_isolate_turn_frame_require_handle()
	timer_cancel(&shard.timer_wheel, handle)
}

// =================================
// Memory Management APIs (§6.9 §9)
// =================================

// ASan-aware allocator wrapper for the working arena. In ASan builds every
// allocation unpoisons the returned range so that allocations after a
// ctx_working_arena_reset can still be used, while stale pointers into ranges
// that were reset remain poisoned. Non-ASan builds compile to the plain
// mem.arena_allocator.
when TINA_ASAN_POISONING {
	@(private = "package")
	_working_arena_allocator_procedure_sanitizer :: proc(
		allocator_data: rawptr,
		mode: mem.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		loc := #caller_location,
	) -> ([]byte, mem.Allocator_Error) {
		arena := cast(^mem.Arena)allocator_data

		_alloc_unpoison_zero :: proc(
			a: ^mem.Arena,
			size, alignment: int,
			zero: bool,
			loc := #caller_location,
		) -> ([]byte, mem.Allocator_Error) {
			result, error := mem.arena_alloc_bytes_non_zeroed(a, size, alignment, loc)
			if error == .None && result != nil {
				// The arena may be backed by ASan-poisoned memory (e.g., after
				// ctx_working_arena_reset). Unpoison before any write.
				_sanitizer_address_unpoison_raw(raw_data(result), len(result))
				if zero {
					mem.zero(raw_data(result), len(result))
				}
			}
			return result, error
		}

		_resize_and_unpoison :: proc(
			arena: ^mem.Arena,
			old_memory: rawptr,
			old_size, size, alignment: int,
			zero: bool,
			loc := #caller_location,
		) -> ([]byte, mem.Allocator_Error) {
			if old_memory == nil do return _alloc_unpoison_zero(arena, size, alignment, zero, loc)

			// Preserve mem.arena_allocator's contract: arena allocations cannot be
			// individually freed, so resize-to-zero is not implemented.
			if size == 0 do return nil, .Mode_Not_Implemented

			if size == old_size && mem.is_aligned(old_memory, alignment) {
				return mem.byte_slice(old_memory, old_size), .None
			}

			new_memory, error := _alloc_unpoison_zero(arena, size, alignment, zero, loc)
			if error != .None || new_memory == nil {
				return new_memory, error
			}
			copy_count := min(old_size, size)
			if copy_count > 0 {
				mem.copy(raw_data(new_memory), old_memory, copy_count)
			}
			return new_memory, .None
		}

		#partial switch mode {
		case .Alloc:
			return _alloc_unpoison_zero(arena, size, alignment, true, loc)
		case .Alloc_Non_Zeroed:
			return _alloc_unpoison_zero(arena, size, alignment, false, loc)
		case .Resize:
			return _resize_and_unpoison(arena, old_memory, old_size, size, alignment, true, loc)
		case .Resize_Non_Zeroed:
			return _resize_and_unpoison(arena, old_memory, old_size, size, alignment, false, loc)
		case .Free:
			return nil, .Mode_Not_Implemented
		case .Free_All:
			_sanitizer_address_poison_working_arena(arena)
			mem.arena_free_all(arena)
			return nil, .None
		case:
			return mem.arena_allocator_proc(arena, mode, size, alignment, old_memory, old_size, loc)
	}
	}
}

@(private = "package")
_working_arena_allocator :: #force_inline proc(arena: ^mem.Arena) -> mem.Allocator {
	when TINA_ASAN_POISONING {
		return mem.Allocator{procedure = _working_arena_allocator_procedure_sanitizer, data = arena}
	} else {
		return mem.arena_allocator(arena)
	}
}

ctx_working_arena :: #force_inline proc() -> mem.Allocator {
	_, frame := _current_isolate_turn_frame_require_handle()
	return _working_arena_allocator(&frame.working_arena)
}

ctx_working_arena_reset :: #force_inline proc() {
	_, frame := _current_isolate_turn_frame_require_handle()
	_sanitizer_address_poison_working_arena(&frame.working_arena)
	frame.working_arena.offset = 0
}

ctx_scratch_arena :: #force_inline proc() -> mem.Allocator {
	_, frame := _current_isolate_turn_frame()
	return mem.arena_allocator(&frame.scratch_arena)
}

ctx_scratch_arena_bytes :: #force_inline proc() -> []u8 {
	_, frame := _current_isolate_turn_frame()
	return frame.scratch_arena.data
}

ctx_working_arena_bytes :: #force_inline proc() -> []u8 {
	_, frame := _current_isolate_turn_frame_require_handle()
	return frame.working_arena.data
}

@(require_results)
ctx_transfer_alloc :: #force_inline proc() -> Transfer_Alloc_Result {
	shard, _ := _current_isolate_turn_frame()
	index: IO_Slot_Index
	error: IO_Slot_Pool_Error
	when TINA_ASAN_POISONING {
		index, error = io_slot_pool_alloc_tina_owned(&shard.transfer_pool)
	} else {
		index, error = io_slot_pool_alloc(&shard.transfer_pool)
	}
	if error != .None {
		shard.counters.transfer_exhaustions += 1
		return Transfer_Alloc_Error.Pool_Exhausted
	}
	gen := shard.transfer_generations[index]
	return transfer_handle_make(index, gen)
}

ctx_transfer_write_raw :: #force_inline proc(
	handle: Transfer_Handle,
	data: []u8,
) -> Transfer_Write_Error {
	shard, _ := _current_isolate_turn_frame()
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if u16(index) >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
		return .Stale_Handle
	}

	if u32(len(data)) > shard.transfer_pool.slot_size {
		return .Bounds_Violation
	}

	io_slot_pool_write_bytes(&shard.transfer_pool, index, data)
	return .None
}

ctx_transfer_write_typed :: #force_inline proc(
	handle: Transfer_Handle,
	message: ^$T,
) -> Transfer_Write_Error {
	return ctx_transfer_write_raw(handle, mem.byte_slice(message, size_of(T)))
}

ctx_transfer_write :: proc {
	ctx_transfer_write_raw,
	ctx_transfer_write_typed,
}

// Reads large payload data from a transfer buffer slot.
// MUST only be called ONCE per turn to prevent buffer leaks.
@(require_results)
ctx_transfer_read :: #force_inline proc(
	handle: Transfer_Handle,
	caller_location := #caller_location,
) -> Transfer_Read_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if u16(index) >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
		shard.counters.transfer_stale_reads += 1
		return Transfer_Read_Error.Stale_Handle
	}

	// Track auto-free lifecycle.
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			frame.transfer_read_handle == TRANSFER_HANDLE_NONE,
			"ctx_transfer_read can only be called ONCE per turn to prevent buffer leaks.",
			caller_location,
		)
	}
	frame.transfer_read_handle = handle

	return io_slot_pool_write_slice(&shard.transfer_pool, index)
}

// Stages one asynchronous I/O submission. The scheduler commits it only if the
// handler returns Isolate_Transition{kind = .Wait_Io}.
@(require_results)
ctx_submit_io :: #force_inline proc(operation: IoOp) -> Io_Submit_Result {
	_, frame := _current_isolate_turn_frame_require_handle()
	if frame.staged_effect.kind != .None {
		return .already_staged
	}
	frame.staged_effect.kind = .IO
	frame.staged_effect.io.operation = operation
	frame.staged_effect.io.data_source = .None
	frame.staged_effect.io.payload_offset = 0
	frame.staged_effect.io.payload_size = 0
	return .ok
}

ctx_staged_io_operation :: #force_inline proc() -> IoOp {
	_, frame := _current_isolate_turn_frame()
	return frame.staged_effect.io.operation
}

ctx_staged_io_payload_size :: #force_inline proc() -> u32 {
	_, frame := _current_isolate_turn_frame()
	return frame.staged_effect.io.payload_size
}

ctx_staged_io_payload_offset :: #force_inline proc() -> u16 {
	_, frame := _current_isolate_turn_frame()
	return frame.staged_effect.io.payload_offset
}

// Computes the byte offset of a data slice within an Isolate struct, with bounds validation.
payload_offset_of :: #force_inline proc(self: ^$T, data: []u8) -> u16 {
	base := cast(^u8)self
	data_start := cast(^u8)raw_data(data)
	offset := mem.ptr_sub(data_start, base)
	when TINA_RUNTIME_ASSERTIONS {
		assert(offset >= 0, "data must point within Isolate struct")
		assert(
			offset + len(data) <= size_of(T),
			"data must not exceed Isolate struct bounds",
		)
	}
	return u16(offset)
}

// Commits a struct-sourced zero-copy I/O stage. Shared body for ctx_io_send /
// ctx_io_write / ctx_io_sendto: only the IoOp variant differs, so each public
// proc builds its operation (the decision pushed up to the caller) and this
// helper holds the one guard-and-commit path (the work pushed down).
@(require_results, private = "file")
_ctx_stage_io_from_struct :: #force_inline proc(
	operation: IoOp,
	payload_offset: u16,
	payload_size: u32,
) -> Io_Submit_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()
	if frame.staged_effect.kind != .None || _staging_claim_read(frame) != IO_SLOT_INDEX_NONE {
		return .already_staged
	}
	frame.staged_effect.kind = .IO
	frame.staged_effect.io.operation = operation
	frame.staged_effect.io.data_source = .Isolate_Struct
	frame.staged_effect.io.payload_offset = payload_offset
	frame.staged_effect.io.payload_size = payload_size
	return .ok
}

// Commits a staging-slot-sourced zero-copy I/O stage. Shared body for
// ctx_io_send_staged / ctx_io_write_staged / ctx_io_sendto_staged.
@(require_results, private = "file")
_ctx_stage_io_from_staging :: #force_inline proc(operation: IoOp, size: u32) -> Io_Submit_Result {
	shard, frame := _current_isolate_turn_frame_require_handle()
	if frame.staged_effect.kind != .None {
		return .already_staged
	}
	if _staging_claim_read(frame) == IO_SLOT_INDEX_NONE {
		return .no_staging_slot
	}
	if size > shard.reactor.staging_pool.slot_size {
		return .payload_too_large
	}
	frame.staged_effect.kind = .IO
	frame.staged_effect.io.operation = operation
	frame.staged_effect.io.data_source = .Staging_Slot
	frame.staged_effect.io.payload_size = size
	return .ok
}

// Zero-copy send from Isolate struct. A previously-claimed staging slot must
// be committed via ctx_io_send_staged or released first — otherwise the
// struct-source path returns .already_staged so the handler cannot accidentally
// leak the staging claim into a different I/O.
@(require_results)
ctx_io_send :: #force_inline proc(self: ^$Isolate, fd: FD_Handle, data: []u8) -> Io_Submit_Result {
	return _ctx_stage_io_from_struct(
		IoOp_Send{fd = fd},
		payload_offset_of(self, data),
		u32(len(data)),
	)
}

// Zero-copy write from Isolate struct (file I/O). A previously-claimed
// staging slot must be committed via ctx_io_send_staged first.
@(require_results)
ctx_io_write :: #force_inline proc(
	self: ^$Isolate,
	fd: FD_Handle,
	data: []u8,
	offset: u64 = 0,
) -> Io_Submit_Result {
	return _ctx_stage_io_from_struct(
		IoOp_Write{fd = fd, offset = offset},
		payload_offset_of(self, data),
		u32(len(data)),
	)
}

// Zero-copy sendto from Isolate struct. A previously-claimed staging slot
// must be committed via ctx_io_send_staged first.
@(require_results)
ctx_io_sendto :: #force_inline proc(
	self: ^$Isolate,
	fd: FD_Handle,
	data: []u8,
	address: Socket_Address,
) -> Io_Submit_Result {
	return _ctx_stage_io_from_struct(
		IoOp_Sendto{fd = fd, address = address},
		payload_offset_of(self, data),
		u32(len(data)),
	)
}

// Returns a writable slice from the I/O staging pool.
// Returns nil if the staging pool is exhausted.
// At most one staging slot can be claimed per turn.
@(require_results)
ctx_claim_send_slot :: #force_inline proc() -> []u8 {
	shard, frame := _current_isolate_turn_frame_require_handle()
	if _staging_claim_read(frame) != IO_SLOT_INDEX_NONE {
		return nil // Already claimed
	}
	index: IO_Slot_Index
	error: IO_Slot_Pool_Error
	when TINA_ASAN_POISONING {
		index, error = io_slot_pool_alloc_tina_owned(&shard.reactor.staging_pool)
	} else {
		index, error = io_slot_pool_alloc(&shard.reactor.staging_pool)
	}
	if error != .None {
		shard.counters.io_staging_exhaustions += 1
		return nil
	}
	_staging_claim_write(frame, index)
	return io_slot_pool_write_slice(&shard.reactor.staging_pool, index)
}

// Zero-copy send from staging slot
@(require_results)
ctx_io_send_staged :: #force_inline proc(fd: FD_Handle, size: u32) -> Io_Submit_Result {
	return _ctx_stage_io_from_staging(IoOp_Send{fd = fd}, size)
}

// Zero-copy write (file I/O) from a previously-claimed staging slot.
// Size of the write must be <= staging_slot_size of the system.
@(require_results)
ctx_io_write_staged :: #force_inline proc(
	fd: FD_Handle,
	size: u32,
	offset: u64 = 0,
) -> Io_Submit_Result {
	return _ctx_stage_io_from_staging(IoOp_Write{fd = fd, offset = offset}, size)
}

// Zero-copy sendto (UDP / connected datagram) from a previously-claimed
// staging slot.
@(require_results)
ctx_io_sendto_staged :: #force_inline proc(
	fd: FD_Handle,
	size: u32,
	address: Socket_Address,
) -> Io_Submit_Result {
	return _ctx_stage_io_from_staging(IoOp_Sendto{fd = fd, address = address}, size)
}

// ============================================================================
// Synchronous I/O Control Operations (§6.6.3 §4.1)
// ============================================================================

@(require_results)
ctx_socket :: #force_inline proc(
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	FD_Handle,
	Reactor_Socket_Error,
) {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return reactor_control_socket(
		&shard.reactor,
		frame.isolate_handle,
		domain,
		socket_type,
		protocol,
	)
}

ctx_bind :: #force_inline proc(fd: FD_Handle, address: Socket_Address) -> Backend_Error {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return reactor_control_bind(&shard.reactor, fd, frame.isolate_handle, address)
}

ctx_listen :: #force_inline proc(fd: FD_Handle, backlog: u32) -> Backend_Error {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return reactor_control_listen(&shard.reactor, fd, frame.isolate_handle, backlog)
}

ctx_setsockopt_raw :: #force_inline proc(
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return reactor_control_setsockopt(
		&shard.reactor,
		fd,
		frame.isolate_handle,
		level,
		option,
		value,
	)
}

ctx_setsockopt_bool :: #force_inline proc(
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: bool,
) -> Backend_Error {
	return ctx_setsockopt_raw(fd, level, option, value)
}

ctx_setsockopt_i32 :: #force_inline proc(
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: i32,
) -> Backend_Error {
	return ctx_setsockopt_raw(fd, level, option, value)
}

ctx_setsockopt_linger :: #force_inline proc(
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Linger,
) -> Backend_Error {
	return ctx_setsockopt_raw(fd, level, option, value)
}

ctx_setsockopt :: proc {
	ctx_setsockopt_raw,
	ctx_setsockopt_bool,
	ctx_setsockopt_i32,
	ctx_setsockopt_linger,
}

ctx_shutdown :: #force_inline proc(fd: FD_Handle, how: Shutdown_How) -> Backend_Error {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return reactor_control_shutdown(&shard.reactor, fd, frame.isolate_handle, how)
}

ctx_close_fd :: #force_inline proc(fd: FD_Handle) -> Backend_Error {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return reactor_control_close(&shard.reactor, fd, frame.isolate_handle)
}

ctx_read_io_slot :: #force_inline proc(slot_index: IO_Slot_Index, size: u32) -> []u8 {
	shard, _ := _current_isolate_turn_frame()
	if size <= 0 do return nil
	return io_slot_pool_read_slice(&shard.reactor.receive_pool, slot_index, size)
}

ctx_is_shutting_down :: #force_inline proc() -> bool {
	shard, _ := _current_isolate_turn_frame()
	return load_watchdog_state(shard) == .Shutting_Down
}

ctx_supervision_group_id :: #force_inline proc() -> Supervision_Group_Id {
	shard, frame := _current_isolate_turn_frame_require_handle()
	return shard.metadata[frame.isolate_type_id][frame.isolate_slot_index].group_id
}

ctx_root_supervision_group_id :: #force_inline proc() -> Supervision_Group_Id {
	return SUPERVISION_GROUP_ID_ROOT
}

ctx_type_config :: #force_inline proc() -> ^IsolateTypeDescriptor {
	shard, frame := _current_isolate_turn_frame()
	return &shard.type_descriptors[frame.isolate_type_id]
}

ctx_isolate_type_id :: #force_inline proc() -> Isolate_Type_Id {
	_, frame := _current_isolate_turn_frame()
	return frame.isolate_type_id
}

ctx_shard_id :: #force_inline proc() -> Shard_Id {
	shard, _ := _current_isolate_turn_frame()
	return shard.id
}

ctx_getsockopt :: #force_inline proc(
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
) -> (
	Socket_Option_Value,
	Backend_Error,
) {
	shard, _ := _current_isolate_turn_frame()
	return reactor_control_getsockopt(&shard.reactor, fd, level, option)
}

@(private = "package")
_transfer_pool_free :: #force_inline proc(shard: ^Shard, index: IO_Slot_Index) {
	when TINA_ASAN_POISONING {
		io_slot_pool_free_tina_owned(&shard.transfer_pool, index)
	} else {
		io_slot_pool_free(&shard.transfer_pool, index)
	}
	shard.transfer_generations[index] += 1
	if shard.transfer_generations[index] == 0 do shard.transfer_generations[index] = 1
}
