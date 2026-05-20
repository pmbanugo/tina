package tina

import "core:mem"
import "core:sync"

@(private = "package")
Isolate_Invocation :: struct {
	previous:               ^Isolate_Invocation,
	shard:                  ^Shard,
	context_token:          TinaContext,
	self_handle:            Handle,
	current_message_source: Handle,
	current_correlation:    Correlation_Id,
	flags:                  Context_Flags,
	working_arena:          mem.Arena,
	scratch_arena:          mem.Arena,
	timer_resolution_ns:    u64,
	current_tick:           u64,
	current_time_ns:        u64,
	type_id:                u16,
	slot_index:             u32,
	shard_id:               Shard_Id,
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

@(private = "package")
ctx_invocation_require_self_handle :: #force_inline proc(ctx: TinaContext) -> ^Isolate_Invocation {
	invocation := ctx_invocation(ctx)
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			invocation.self_handle != HANDLE_NONE,
			"ctx_invocation_require_self_handle API requires a live Isolate handle.",
		)
	}
	return invocation
}

@(require_results)
ctx_send_raw :: #force_inline proc(
	ctx: TinaContext,
	to: Handle,
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
	to: Handle,
	$tag: Message_Tag,
	payload: []u8,
	correlation_id: Correlation_Id,
) -> Send_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_send_with_correlation: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			len(payload) <= MAX_PAYLOAD_SIZE,
			"ctx_send_with_correlation payload exceeds MAX_PAYLOAD_SIZE",
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
	to: Handle,
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

ctx_transfer_send :: #force_inline proc(
	ctx: TinaContext,
	to: Handle,
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

	child_handle, ok := res.(Handle)
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
	to: Handle,
	fd: FD_Handle,
) -> FD_Handoff_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard

	if to == HANDLE_NONE || extract_shard_id(to) == shard.id {
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

ctx_self_handle :: #force_inline proc(ctx: TinaContext) -> Handle {
	return ctx_invocation(ctx).self_handle
}

// Acquire a pre-allocated renewable deadline slot. Returns a handle.
// Strictly zero-dynamic allocation.
@(require_results)
ctx_acquire_renewable_deadline :: #force_inline proc(
	ctx: TinaContext,
) -> Timer_Handle {
	invocation := ctx_invocation_require_self_handle(ctx)
	return timer_acquire_renewable(&invocation.shard.timer_wheel, invocation.self_handle)
}

// Release an acquired renewable deadline slot back to the pool.
ctx_release_renewable_deadline :: #force_inline proc(
	ctx: TinaContext,
	handle: Timer_Handle,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	timer_release_renewable(&invocation.shard.timer_wheel, handle)
}

// Re-arm an existing renewable deadline with a new duration. O(1) field update.
ctx_rearm_renewable_deadline :: #force_inline proc(
	ctx: TinaContext,
	handle: Timer_Handle,
	duration_ns: u64,
	tag: Message_Tag,
	correlation: Correlation_Id,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	timer_rearm_renewable(
		&invocation.shard.timer_wheel,
		handle,
		invocation.current_time_ns + duration_ns,
		tag,
		correlation,
	)
}

// Cancel (disarm) a renewable deadline. O(1) bit clear.
ctx_cancel_renewable_deadline :: #force_inline proc(
	ctx: TinaContext,
	handle: Timer_Handle,
) {
	invocation := ctx_invocation_require_self_handle(ctx)
	timer_cancel_renewable(&invocation.shard.timer_wheel, handle)
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
	index, err := reactor_buffer_pool_alloc(&shard.transfer_pool)
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

	if index >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
		return .Stale_Handle
	}

	if u32(len(data)) > shard.transfer_pool.slot_size {
		return .Bounds_Violation
	}

	reactor_buffer_pool_write_bytes(&shard.transfer_pool, index, data)
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
) -> Transfer_Read_Result {
	invocation := ctx_invocation_require_self_handle(ctx)
	shard := invocation.shard
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if index >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
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
		)
	}
	shard.metadata[type_id][slot].pending_transfer_read = handle

	return reactor_buffer_pool_write_slice(&shard.transfer_pool, index)
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

ctx_read_buffer :: #force_inline proc(ctx: TinaContext, buffer_index: u16, size: u32) -> []u8 {
	shard := ctx_invocation(ctx).shard
	if size <= 0 do return nil
	return reactor_buffer_pool_read_slice(&shard.reactor.buffer_pool, buffer_index, size)
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
_transfer_pool_free :: #force_inline proc(shard: ^Shard, index: u16) {
	reactor_buffer_pool_free(&shard.transfer_pool, index)
	shard.transfer_generations[index] += 1
	if shard.transfer_generations[index] == 0 do shard.transfer_generations[index] = 1
}
