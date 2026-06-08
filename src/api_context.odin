package tina

import "core:mem"
import "core:sync"

@(private = "package")
Staged_Call :: struct {
	envelope:   Message_Envelope,
	timeout_ns: u64,
}

@(private = "package")
Isolate_Invocation :: struct {
	previous:               ^Isolate_Invocation,
	shard:                  ^Shard,
	context_token:          TinaContext,
	self_handle:            Isolate_Handle,
	current_message_source: Isolate_Handle,
	current_correlation:    Correlation_Id,
	staged_call:            Staged_Call,
	staged_io_operation:    IoOp,
	flags:                  Context_Flags,
	working_arena:          mem.Arena,
	scratch_arena:          mem.Arena,
	timer_resolution_ns:    u64,
	current_tick:           u64,
	type_id:                u16,
	slot_index:             u32,
	shard_id:               Shard_Id,
	staged_call_active:        bool,
	staged_io_active:          bool,
	reply_sent:                bool,
	staged_io_data_source:     IO_Data_Source, // Where write data comes from
	staged_io_payload_offset:  u16,            // Offset within Isolate struct
	staged_io_payload_size:    u32,            // Byte count of payload
}

// Read the active staging claim slot index. Returns IO_SLOT_INDEX_NONE if
// no claim is active. The single source of truth is the metadata field;
// the accessor exists to give the read a single canonical name and to make
// the indirection searchable.
@(require_results)
_staging_claim_read :: #force_inline proc(ctx: TinaContext) -> IO_Slot_Index {
	inv := ctx_invocation(ctx)
	return inv.shard.metadata[inv.type_id][inv.slot_index].staging_slot_index
}

// Set or clear the active staging claim. Pass IO_SLOT_INDEX_NONE to clear.
_staging_claim_write :: #force_inline proc(ctx: TinaContext, value: IO_Slot_Index) {
	inv := ctx_invocation(ctx)
	inv.shard.metadata[inv.type_id][inv.slot_index].staging_slot_index = value
}

@(thread_local)
g_current_isolate_invocation: ^Isolate_Invocation

@(private = "package")
make_tina_context_token :: #force_inline proc "contextless" (shard: ^Shard) -> TinaContext {
	shard.next_context_token += 1
	if shard.next_context_token == 0 do shard.next_context_token = 1
	sequence := shard.next_context_token & 0x00FF_FFFF_FFFF_FFFF
	return TinaContext((u64(shard.id) + 1) << 56 | sequence)
}

@(private = "package")
ctx_invocation :: #force_inline proc(ctx: TinaContext) -> ^Isolate_Invocation {
	invocation := g_current_isolate_invocation
	when TINA_RUNTIME_ASSERTIONS {
		assert(invocation != nil, "TinaContext used outside active Tina callback")
		assert(ctx == invocation.context_token, "stale or foreign TinaContext")
	}
	return invocation
}

@(private = "file")
_send_result_to_reply_result :: #force_inline proc "contextless" (result: Send_Result) -> Reply_Result {
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
ctx_invocation_require_self_handle :: #force_inline proc(ctx: TinaContext) -> ^Isolate_Invocation {
	invocation := ctx_invocation(ctx)
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			invocation.self_handle != ISOLATE_HANDLE_NONE,
			"ctx_invocation_require_self_handle API requires a live Isolate handle.",
		)
	}
	return invocation
}

@(require_results)
ctx_send_raw :: #force_inline proc(
	ctx: TinaContext,
	to: Isolate_Handle,
	$tag: Message_Tag,
	payload: []u8,
) -> Send_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_send: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard

	envelope: Message_Envelope
	envelope.source = invocation.self_handle
	envelope.destination = to
	envelope.tag = tag
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	response := _route_envelope_user(shard, to, &envelope)
	return response
}

@(require_results)
ctx_reply_raw :: #force_inline proc(
	ctx: TinaContext,
	$tag: Message_Tag,
	payload: []u8,
	caller_location := #caller_location,
) -> Reply_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_reply: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	when TINA_RUNTIME_ASSERTIONS {
		assert(len(payload) <= MAX_PAYLOAD_SIZE, "ctx_reply payload exceeds MAX_PAYLOAD_SIZE", caller_location)
	}

	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.reply_sent {
		return .already_replied
	}
	if .Is_Call not_in invocation.flags {
		return .not_call_context
	}

	envelope: Message_Envelope
	envelope.source = invocation.self_handle
	envelope.destination = invocation.current_message_source
	envelope.correlation = invocation.current_correlation
	envelope.flags += {.Is_Reply}
	envelope.tag = tag
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	result := _send_result_to_reply_result(
		_route_envelope_user(invocation.shard, invocation.current_message_source, &envelope),
	)
	if result == .ok {
		invocation.reply_sent = true
	}
	return result
}

@(require_results)
ctx_reply_typed :: #force_inline proc(
	ctx: TinaContext,
	$tag: Message_Tag,
	message: ^$T,
	caller_location := #caller_location,
) -> Reply_Result where size_of(T) <=
	MAX_PAYLOAD_SIZE {
	return ctx_reply_raw(ctx, tag, mem.byte_slice(message, size_of(T)), caller_location)
}

ctx_reply :: proc {
	ctx_reply_raw,
	ctx_reply_typed,
}

// Reserves a shard-local correlation id for a logical parked wait.
@(require_results)
ctx_reserve_correlation_id :: #force_inline proc(ctx: TinaContext) -> Correlation_Id {
	shard := ctx_invocation(ctx).shard
	shard.next_correlation_id += 1
	if shard.next_correlation_id == 0 do shard.next_correlation_id = 1
	return Correlation_Id(shard.next_correlation_id)
}

// Sends an inline message with an explicit correlation id.
@(require_results)
ctx_send_with_correlation :: #force_inline proc(
	ctx: TinaContext,
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
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard

	envelope: Message_Envelope
	envelope.source = invocation.self_handle
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
	ctx: TinaContext,
	to: Isolate_Handle,
	handle: Transfer_Handle,
	correlation_id: Correlation_Id,
) -> Send_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard
	envelope: Message_Envelope
	envelope.source = invocation.self_handle
	envelope.destination = to
	envelope.tag = TAG_TRANSFER
	envelope.correlation = correlation_id
	envelope.payload_size = size_of(Transfer_Handle)

	(cast(^Transfer_Handle)&envelope.payload[0])^ = handle

	return _route_envelope_system(shard, to, &envelope)
}

// Stages a request-reply call. The scheduler commits the staged envelope only if
// the handler returns Isolate_Transition{kind = .Wait_Reply}.
@(require_results)
ctx_call_raw :: #force_inline proc(
	ctx: TinaContext,
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
		assert(len(payload) <= MAX_PAYLOAD_SIZE, "ctx_call payload exceeds MAX_PAYLOAD_SIZE", caller_location)
		assert(timeout_ns > 0, "ctx_call timeout_ns must be > 0", caller_location)
	}

	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active {
		return .already_staged
	}

	shard := invocation.shard
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
		if target_meta[target_slot_index].inbox_count >= shard.type_descriptors[target_type_id].mailbox_capacity {
			return .mailbox_full
		}
	}

	correlation_id := ctx_reserve_correlation_id(ctx)
	invocation.staged_call_active = true
	invocation.staged_call.timeout_ns = timeout_ns
	invocation.staged_call.envelope = {}
	invocation.staged_call.envelope.destination = to
	invocation.staged_call.envelope.correlation = correlation_id
	invocation.staged_call.envelope.tag = tag
	invocation.staged_call.envelope.payload_size = u16(len(payload))
	copy(invocation.staged_call.envelope.payload[:], payload)
	return .ok
}

@(require_results)
ctx_call_typed :: #force_inline proc(
	ctx: TinaContext,
	to: Isolate_Handle,
	$tag: Message_Tag,
	message: ^$T,
	timeout_ns: u64,
	caller_location := #caller_location,
) -> Call_Result where size_of(T) <=
	MAX_PAYLOAD_SIZE {
	return ctx_call_raw(ctx, to, tag, mem.byte_slice(message, size_of(T)), timeout_ns, caller_location)
}

ctx_call :: proc {
	ctx_call_raw,
	ctx_call_typed,
}

ctx_transfer_send :: #force_inline proc(
	ctx: TinaContext,
	to: Isolate_Handle,
	handle: Transfer_Handle,
) -> Send_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard
	envelope: Message_Envelope
	envelope.source = invocation.self_handle
	envelope.destination = to
	envelope.tag = TAG_TRANSFER
	envelope.payload_size = size_of(Transfer_Handle)

	(cast(^Transfer_Handle)&envelope.payload[0])^ = handle

	return _route_envelope_system(shard, to, &envelope)
}

// Spawns a new Isolate and attaches it to the specified supervision group.
@(require_results)
ctx_spawn :: #force_inline proc(ctx: TinaContext, spec: Spawn_Spec) -> Spawn_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard

	// 1. Group Capacity Check (Fail early!)
	group: ^Supervision_Group = nil
	if spec.group_id != SUPERVISION_GROUP_ID_NONE {
		group = &shard.supervision_groups[u16(spec.group_id)]
		_assert_group_layout(group)
		if group.child_count_dynamic >= u16(len(group.dynamic_specs)) {
			return Spawn_Error.group_full
		}
	}

	// 2. Delegate to internal allocation and init
	res := _make_isolate(shard, spec, invocation.self_handle)

	child_handle, ok := res.(Isolate_Handle)
	if !ok {
		return res
	}

	// 3. Register with Supervision Group (Always Appends)
	if group != nil {
		_assert_group_layout(group)
		child_index := group.child_count_static + group.child_count_dynamic
		group.children_handles[child_index] = child_handle

		dyn := &group.dynamic_specs[group.child_count_dynamic]
		dyn.type_id = spec.type_id
		dyn.restart_type = spec.restart_type
		dyn.args_size = spec.args_size
		dyn.args_payload = spec.args_payload
		group.child_count_dynamic += 1
	}

	return child_handle
}

@(require_results)
ctx_fd_handoff :: #force_inline proc(
	ctx: TinaContext,
	to: Isolate_Handle,
	fd: FD_Handle,
) -> FD_Handoff_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard

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
		invocation.self_handle,
	)
	if export_result != .ok {
		return export_result
	}

	deadline_tick := shard.current_tick + FD_HANDOFF_TIMEOUT_TICKS
	handoff_ref, handoff_alloc_err := fd_handoff_table_alloc(
		&shard.handoff_table,
		to,
		cleanup_fd,
		peer_address,
		deadline_tick,
		shard.id,
	)
	if handoff_alloc_err != .None {
		_ = backend_control_close(&shard.reactor.backend, cleanup_fd)
		shard.counters.handoff_exhaustions += 1
		return .handoff_table_full
	}

	msg_envelope: Message_Envelope
	msg_envelope.source = invocation.self_handle
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

ctx_self_handle :: #force_inline proc(ctx: TinaContext) -> Isolate_Handle {
	return ctx_invocation(ctx).self_handle
}

// Acquire a pre-allocated timer slot. Returns a handle.
// Strictly zero-dynamic allocation.
@(require_results)
ctx_timer_acquire :: #force_inline proc(
	ctx: TinaContext,
) -> Timer_Handle {
	invocation := ctx_invocation_require_self_handle(ctx)
	return timer_acquire(&invocation.shard.timer_wheel, invocation.self_handle)
}

// Release an acquired timer slot back to the pool.
ctx_timer_release :: #force_inline proc(
	ctx: TinaContext,
	handle: Timer_Handle,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	timer_release(&invocation.shard.timer_wheel, handle)
}

// Re-arm an existing timer with a new duration.
ctx_timer_rearm :: #force_inline proc(
	ctx: TinaContext,
	handle: Timer_Handle,
	duration_ns: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	timer_rearm(
		&invocation.shard.timer_wheel,
		handle,
		invocation.current_tick + _duration_ns_to_ticks(duration_ns, invocation.timer_resolution_ns),
		tag,
		correlation,
	)
}

// Cancel (disarm) a timer.
ctx_timer_cancel :: #force_inline proc(
	ctx: TinaContext,
	handle: Timer_Handle,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	timer_cancel(&invocation.shard.timer_wheel, handle)
}

// =================================
// Memory Management APIs (§6.9 §9)
// =================================

ctx_working_arena :: #force_inline proc(ctx: TinaContext) -> mem.Allocator {
	return mem.arena_allocator(&ctx_invocation_require_self_handle(ctx).working_arena)
}

ctx_working_arena_reset :: #force_inline proc(ctx: TinaContext) {
	ctx_invocation_require_self_handle(ctx).working_arena.offset = 0
}

ctx_scratch_arena :: #force_inline proc(ctx: TinaContext) -> mem.Allocator {
	return mem.arena_allocator(&ctx_invocation(ctx).scratch_arena)
}

ctx_scratch_arena_bytes :: #force_inline proc(ctx: TinaContext) -> []u8 {
	return ctx_invocation(ctx).scratch_arena.data
}

ctx_working_arena_bytes :: #force_inline proc(ctx: TinaContext) -> []u8 {
	return ctx_invocation_require_self_handle(ctx).working_arena.data
}

@(require_results)
ctx_transfer_alloc :: #force_inline proc(ctx: TinaContext) -> Transfer_Alloc_Result {
	shard := ctx_invocation(ctx).shard
	index, err := io_slot_pool_alloc(&shard.transfer_pool)
	if err != .None {
		shard.counters.transfer_exhaustions += 1
		return Transfer_Alloc_Error.Pool_Exhausted
	}
	gen := shard.transfer_generations[index]
	return transfer_handle_make(index, gen)
}

ctx_transfer_write_raw :: #force_inline proc(
	ctx: TinaContext,
	handle: Transfer_Handle,
	data: []u8,
) -> Transfer_Write_Error {
	shard := ctx_invocation(ctx).shard
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
	ctx: TinaContext,
	handle: Transfer_Handle,
	message: ^$T,
) -> Transfer_Write_Error {
	return ctx_transfer_write_raw(ctx, handle, mem.byte_slice(message, size_of(T)))
}

ctx_transfer_write :: proc {
	ctx_transfer_write_raw,
	ctx_transfer_write_typed,
}

// Reads large payload data from a transfer buffer slot.
// MUST only be called ONCE per handler invocation to prevent buffer leaks.
@(require_results)
ctx_transfer_read :: #force_inline proc(
	ctx: TinaContext,
	handle: Transfer_Handle,
	caller_location := #caller_location,
) -> Transfer_Read_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if u16(index) >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
		shard.counters.transfer_stale_reads += 1
		return Transfer_Read_Error.Stale_Handle
	}

	// Track auto-free lifecycle.
	type_id := invocation.type_id
	slot := invocation.slot_index
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			shard.metadata[type_id][slot].pending_transfer_read == TRANSFER_HANDLE_NONE,
			"ctx_transfer_read can only be called ONCE per handler invocation to prevent buffer leaks.",
			caller_location,
		)
	}
	shard.metadata[type_id][slot].pending_transfer_read = handle

	return io_slot_pool_write_slice(&shard.transfer_pool, index)
}

// Stages one asynchronous I/O submission. The scheduler commits it only if the
// handler returns Isolate_Transition{kind = .Wait_Io}.
@(require_results)
ctx_submit_io :: #force_inline proc(ctx: TinaContext, operation: IoOp) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active {
		return .already_staged
	}
	invocation.staged_io_operation = operation
	invocation.staged_io_data_source = .None
	invocation.staged_io_active = true
	return .ok
}

ctx_staged_io_operation :: #force_inline proc(ctx: TinaContext) -> IoOp {
	return ctx_invocation(ctx).staged_io_operation
}

ctx_staged_io_payload_size :: #force_inline proc(ctx: TinaContext) -> u32 {
	return ctx_invocation(ctx).staged_io_payload_size
}

ctx_staged_io_payload_offset :: #force_inline proc(ctx: TinaContext) -> u16 {
	return ctx_invocation(ctx).staged_io_payload_offset
}

// Computes the byte offset of a data slice within an Isolate struct, with bounds validation.
payload_offset_of :: #force_inline proc(self: ^$T, data: []u8) -> u16 {
	base := uintptr(self)
	data_start := uintptr(raw_data(data))
	offset := data_start - base
	when TINA_RUNTIME_ASSERTIONS {
		assert(data_start >= base, "data must point within Isolate struct")
		assert(offset + uintptr(len(data)) <= uintptr(size_of(T)), "data must not exceed Isolate struct bounds")
	}
	return u16(offset)
}

// Zero-copy send from Isolate struct. A previously-claimed staging slot must
// be committed via ctx_io_send_staged or released first — otherwise the
// struct-source path returns .already_staged so the handler cannot accidentally
// leak the staging claim into a different I/O.
@(require_results)
ctx_io_send :: #force_inline proc(
	ctx: TinaContext,
	self: ^$Isolate,
	fd: FD_Handle,
	data: []u8,
) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active || _staging_claim_read(ctx) != IO_SLOT_INDEX_NONE {
		return .already_staged
	}
	//if _staging_claim_read(ctx) != IO_SLOT_INDEX_NONE {
		//return .already_staged
	//}
	invocation.staged_io_operation = IoOp_Send{fd = fd}
	invocation.staged_io_data_source = .Isolate_Struct
	invocation.staged_io_payload_offset = payload_offset_of(self, data)
	invocation.staged_io_payload_size = u32(len(data))
	invocation.staged_io_active = true
	return .ok
}

// Zero-copy write from Isolate struct (file I/O). A previously-claimed
// staging slot must be committed via ctx_io_send_staged first.
@(require_results)
ctx_io_write :: #force_inline proc(
	ctx: TinaContext,
	self: ^$Isolate,
	fd: FD_Handle,
	data: []u8,
	offset: u64 = 0,
) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active || _staging_claim_read(ctx) != IO_SLOT_INDEX_NONE {
		return .already_staged
	}
	invocation.staged_io_operation = IoOp_Write{fd = fd, offset = offset}
	invocation.staged_io_data_source = .Isolate_Struct
	invocation.staged_io_payload_offset = payload_offset_of(self, data)
	invocation.staged_io_payload_size = u32(len(data))
	invocation.staged_io_active = true
	return .ok
}

// Zero-copy sendto from Isolate struct. A previously-claimed staging slot
// must be committed via ctx_io_send_staged first.
@(require_results)
ctx_io_sendto :: #force_inline proc(
	ctx: TinaContext,
	self: ^$Isolate,
	fd: FD_Handle,
	data: []u8,
	address: Socket_Address,
) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active {
		return .already_staged
	}
	if _staging_claim_read(ctx) != IO_SLOT_INDEX_NONE {
		return .already_staged
	}
	invocation.staged_io_operation = IoOp_Sendto{fd = fd, address = address}
	invocation.staged_io_data_source = .Isolate_Struct
	invocation.staged_io_payload_offset = payload_offset_of(self, data)
	invocation.staged_io_payload_size = u32(len(data))
	invocation.staged_io_active = true
	return .ok
}

// Returns a writable slice from the I/O staging pool.
// Returns nil if the staging pool is exhausted.
// At most one staging slot can be claimed per handler invocation.
@(require_results)
ctx_claim_send_slot :: #force_inline proc(ctx: TinaContext) -> []u8 {
	invocation := ctx_invocation_require_self_handle(ctx)
	if _staging_claim_read(ctx) != IO_SLOT_INDEX_NONE {
		return nil // Already claimed
	}
	shard := invocation.shard
	index, err := io_slot_pool_alloc(&shard.reactor.staging_pool)
	if err != .None {
		shard.counters.io_staging_exhaustions += 1
		return nil
	}
	_staging_claim_write(ctx, index)
	return io_slot_pool_write_slice(&shard.reactor.staging_pool, index)
}

// Zero-copy send from staging slot
@(require_results)
ctx_io_send_staged :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	size: u32,
) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active {
		return .already_staged
	}
	if _staging_claim_read(ctx) == IO_SLOT_INDEX_NONE {
		return .no_staging_slot
	}
	if size > invocation.shard.reactor.staging_pool.slot_size {
		return .payload_too_large
	}
	invocation.staged_io_operation = IoOp_Send{fd = fd}
	invocation.staged_io_data_source = .Staging_Slot
	invocation.staged_io_payload_size = size
	invocation.staged_io_active = true
	return .ok
}

// Zero-copy write (file I/O) from a previously-claimed staging slot.
// Size of the write must be <= staging_slot_size of the system.
@(require_results)
ctx_io_write_staged :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	size: u32,
	offset: u64 = 0,
) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active {
		return .already_staged
	}
	if _staging_claim_read(ctx) == IO_SLOT_INDEX_NONE {
		return .no_staging_slot
	}
	if size > invocation.shard.reactor.staging_pool.slot_size {
		return .payload_too_large
	}
	invocation.staged_io_operation = IoOp_Write{fd = fd, offset = offset}
	invocation.staged_io_data_source = .Staging_Slot
	invocation.staged_io_payload_size = size
	invocation.staged_io_active = true
	return .ok
}

// Zero-copy sendto (UDP / connected datagram) from a previously-claimed
// staging slot.
@(require_results)
ctx_io_sendto_staged :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	size: u32,
	address: Socket_Address,
) -> Io_Submit_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	if invocation.staged_call_active || invocation.staged_io_active {
		return .already_staged
	}
	if _staging_claim_read(ctx) == IO_SLOT_INDEX_NONE {
		return .no_staging_slot
	}
	if size > invocation.shard.reactor.staging_pool.slot_size {
		return .payload_too_large
	}
	invocation.staged_io_operation = IoOp_Sendto{fd = fd, address = address}
	invocation.staged_io_data_source = .Staging_Slot
	invocation.staged_io_payload_size = size
	invocation.staged_io_active = true
	return .ok
}

// ============================================================================
// Synchronous I/O Control Operations (§6.6.3 §4.1)
// ============================================================================

@(require_results)
ctx_socket :: #force_inline proc(
	ctx: TinaContext,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	FD_Handle,
	Reactor_Socket_Error,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	return reactor_control_socket(
		&invocation.shard.reactor,
		invocation.self_handle,
		domain,
		socket_type,
		protocol,
	)
}

ctx_bind :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	address: Socket_Address,
) -> Backend_Error {
	invocation := ctx_invocation_require_self_handle(ctx)
	return reactor_control_bind(&invocation.shard.reactor, fd, invocation.self_handle, address)
}

ctx_listen :: #force_inline proc(ctx: TinaContext, fd: FD_Handle, backlog: u32) -> Backend_Error {
	invocation := ctx_invocation_require_self_handle(ctx)
	return reactor_control_listen(&invocation.shard.reactor, fd, invocation.self_handle, backlog)
}

ctx_setsockopt_raw :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	invocation := ctx_invocation_require_self_handle(ctx)
	return reactor_control_setsockopt(
		&invocation.shard.reactor,
		fd,
		invocation.self_handle,
		level,
		option,
		value,
	)
}

ctx_setsockopt_bool :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: bool,
) -> Backend_Error {
	return ctx_setsockopt_raw(ctx, fd, level, option, value)
}

ctx_setsockopt_i32 :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: i32,
) -> Backend_Error {
	return ctx_setsockopt_raw(ctx, fd, level, option, value)
}

ctx_setsockopt_linger :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Linger,
) -> Backend_Error {
	return ctx_setsockopt_raw(ctx, fd, level, option, value)
}

ctx_setsockopt :: proc {
	ctx_setsockopt_raw,
	ctx_setsockopt_bool,
	ctx_setsockopt_i32,
	ctx_setsockopt_linger,
}

ctx_shutdown :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	how: Shutdown_How,
) -> Backend_Error {
	invocation := ctx_invocation_require_self_handle(ctx)
	return reactor_control_shutdown(&invocation.shard.reactor, fd, invocation.self_handle, how)
}

ctx_close_fd :: #force_inline proc(ctx: TinaContext, fd: FD_Handle) -> Backend_Error {
	invocation := ctx_invocation_require_self_handle(ctx)
	return reactor_control_close(&invocation.shard.reactor, fd, invocation.self_handle)
}

ctx_read_io_slot :: #force_inline proc(ctx: TinaContext, slot_index: IO_Slot_Index, size: u32) -> []u8 {
	shard := ctx_invocation(ctx).shard
	if size <= 0 do return nil
	return io_slot_pool_read_slice(&shard.reactor.receive_pool, slot_index, size)
}

ctx_is_shutting_down :: #force_inline proc(ctx: TinaContext) -> bool {
	shard := ctx_invocation(ctx).shard
	return(
		cast(Shard_State)sync.atomic_load_explicit(shard.watchdog_state_pointer, .Relaxed) ==
		.Shutting_Down
	)
}

ctx_supervision_group_id :: #force_inline proc(ctx: TinaContext) -> Supervision_Group_Id {
	invocation := ctx_invocation_require_self_handle(ctx)
	return invocation.shard.metadata[invocation.type_id][invocation.slot_index].group_id
}

ctx_root_supervision_group_id :: #force_inline proc() -> Supervision_Group_Id {
	return SUPERVISION_GROUP_ID_ROOT
}

ctx_type_config :: #force_inline proc(ctx: TinaContext) -> ^IsolateTypeDescriptor {
	invocation := ctx_invocation(ctx)
	return &invocation.shard.type_descriptors[invocation.type_id]
}

ctx_isolate_type_id :: #force_inline proc(ctx: TinaContext) -> u16 {
	return ctx_invocation(ctx).type_id
}

ctx_shard_id :: #force_inline proc(ctx: TinaContext) -> Shard_Id {
	return ctx_invocation(ctx).shard_id
}

ctx_getsockopt :: #force_inline proc(
	ctx: TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
) -> (
	Socket_Option_Value,
	Backend_Error,
) {
	shard := ctx_invocation(ctx).shard
	return reactor_control_getsockopt(&shard.reactor, fd, level, option)
}

@(private = "package")
_transfer_pool_free :: #force_inline proc(shard: ^Shard, index: IO_Slot_Index) {
	io_slot_pool_free(&shard.transfer_pool, index)
	shard.transfer_generations[index] += 1
	if shard.transfer_generations[index] == 0 do shard.transfer_generations[index] = 1
}
