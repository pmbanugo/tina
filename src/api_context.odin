package tina

import "core:mem"
import "core:sync"

ctx_send :: #force_inline proc(
	ctx: ^TinaContext,
	to: Handle,
	tag: Message_Tag,
	payload: []u8,
) -> Send_Result {
	assert(tag >= USER_MESSAGE_TAG_BASE, "User code must not send system tags via ctx_send")
	assert(len(payload) <= MAX_PAYLOAD_SIZE, "Payload exceeds MAX_PAYLOAD_SIZE")

	envelope: Message_Envelope
	envelope.source = ctx.self_handle
	envelope.destination = to
	envelope.tag = tag
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	response := _route_envelope_user(ctx.shard, to, &envelope)
	return response
}

ctx_transfer_send :: #force_inline proc(
	ctx: ^TinaContext,
	to: Handle,
	handle: Transfer_Handle,
) -> Send_Result {
	envelope: Message_Envelope
	envelope.source = ctx.self_handle
	envelope.destination = to
	envelope.tag = TAG_TRANSFER
	envelope.payload_size = size_of(Transfer_Handle)

	(cast(^Transfer_Handle)&envelope.payload[0])^ = handle

	return _route_envelope_system(ctx.shard, to, &envelope)
}

ctx_spawn :: #force_inline proc(ctx: ^TinaContext, spec: Spawn_Spec) -> Spawn_Result {
	shard := ctx.shard

	// 1. Group Capacity Check (Fail early!)
	group: ^Supervision_Group = nil
	if spec.group_id != SUPERVISION_GROUP_ID_NONE {
		group = &shard.supervision_groups[u16(spec.group_id)]
		if group.child_count >= u16(len(group.children_handles)) {
			return Spawn_Error.group_full
		}
	}

	// 2. Delegate to internal allocation and init
	res := _make_isolate(shard, spec, ctx.self_handle)

	child_handle, ok := res.(Handle)
	if !ok {
		return res
	}

	// 3. Register with Supervision Group (Always Appends)
	if group != nil {
		group.children_handles[group.child_count] = child_handle

		if len(group.dynamic_specs) > 0 {
			dyn := &group.dynamic_specs[group.child_count]
			dyn.type_id = spec.type_id
			dyn.restart_type = spec.restart_type
			dyn.args_size = spec.args_size
			dyn.args_payload = spec.args_payload
		}
		group.child_count += 1
	}

	return child_handle
}

// =================================
// Memory Management APIs (§6.9 §9)
// =================================

ctx_working_arena :: #force_inline proc(ctx: ^TinaContext) -> mem.Allocator {
	return mem.arena_allocator(&ctx.working_arena)
}

ctx_working_arena_reset :: #force_inline proc(ctx: ^TinaContext) {
	ctx.working_arena.offset = 0
}

ctx_scratch_arena :: #force_inline proc(ctx: ^TinaContext) -> mem.Allocator {
	return mem.arena_allocator(&ctx.scratch_arena)
}

ctx_transfer_alloc :: #force_inline proc(ctx: ^TinaContext) -> Transfer_Alloc_Result {
	index, err := reactor_buffer_pool_alloc(&ctx.shard.transfer_pool)
	if err != .None {
		ctx.shard.counters.transfer_exhaustions += 1
		return Transfer_Alloc_Error.Pool_Exhausted
	}
	gen := ctx.shard.transfer_generations[index]
	return transfer_handle_make(index, gen)
}

ctx_transfer_write :: #force_inline proc(
	ctx: ^TinaContext,
	handle: Transfer_Handle,
	data: []u8,
) -> Transfer_Write_Error {
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if index >= ctx.shard.transfer_pool.slot_count ||
	   ctx.shard.transfer_generations[index] != gen {
		return .Stale_Handle
	}

	if u32(len(data)) > ctx.shard.transfer_pool.slot_size {
		return .Bounds_Violation
	}

	target := reactor_buffer_pool_slot_ptr(&ctx.shard.transfer_pool, index)
	mem.copy(target, raw_data(data), len(data))
	return .None
}

// Reads data from a transfer buffer slot.
// NOTE: To prevent buffer leaks, this must only be called ONCE per handler invocation.
// If you need the data across multiple ticks or operations, you must copy it
// into your Isolate's working arena.
ctx_transfer_read :: #force_inline proc(
	ctx: ^TinaContext,
	handle: Transfer_Handle,
) -> Transfer_Read_Result {
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if index >= ctx.shard.transfer_pool.slot_count ||
	   ctx.shard.transfer_generations[index] != gen {
		ctx.shard.counters.transfer_stale_reads += 1
		return Transfer_Read_Error.Stale_Handle
	}

	// Track auto-free lifecycle.
	type_id := extract_type_id(ctx.self_handle)
	slot := extract_slot(ctx.self_handle)
	when TINA_DEBUG_ASSERTS {
		assert(
			ctx.shard.metadata[type_id][slot].pending_transfer_read == TRANSFER_HANDLE_NONE,
			"ctx_transfer_read can only be called ONCE per handler invocation to prevent buffer leaks.",
		)
	}
	ctx.shard.metadata[type_id][slot].pending_transfer_read = handle

	ptr := reactor_buffer_pool_slot_ptr(&ctx.shard.transfer_pool, index)
	return ptr[:ctx.shard.transfer_pool.slot_size]
}

// ============================================================================
// Synchronous I/O Control Operations (§6.6.3 §4.1)
// ============================================================================

ctx_socket :: #force_inline proc(
	ctx: ^TinaContext,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	FD_Handle,
	Reactor_Socket_Error,
) {
	return reactor_control_socket(
		&ctx.shard.reactor,
		ctx.self_handle,
		domain,
		socket_type,
		protocol,
	)
}

ctx_bind :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	address: Socket_Address,
) -> Backend_Error {
	return reactor_control_bind(&ctx.shard.reactor, fd, ctx.self_handle, address)
}

ctx_listen :: #force_inline proc(ctx: ^TinaContext, fd: FD_Handle, backlog: u32) -> Backend_Error {
	return reactor_control_listen(&ctx.shard.reactor, fd, ctx.self_handle, backlog)
}

ctx_setsockopt :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	return reactor_control_setsockopt(
		&ctx.shard.reactor,
		fd,
		ctx.self_handle,
		level,
		option,
		value,
	)
}

ctx_shutdown :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	how: Shutdown_How,
) -> Backend_Error {
	return reactor_control_shutdown(&ctx.shard.reactor, fd, ctx.self_handle, how)
}

ctx_read_buffer :: #force_inline proc(ctx: ^TinaContext, buffer_index: u16, size: u32) -> []u8 {
	if size <= 0 do return nil
	return reactor_buffer_pool_read_slice(&ctx.shard.reactor.buffer_pool, buffer_index, size)
}

ctx_is_shutting_down :: #force_inline proc(ctx: ^TinaContext) -> bool {
	return(
		cast(Shard_State)sync.atomic_load_explicit(ctx.shard.shared_state, .Relaxed) ==
		.Shutting_Down \
	)
}

ctx_supervision_group_id :: #force_inline proc(ctx: ^TinaContext) -> Supervision_Group_Id {
	type_id := extract_type_id(ctx.self_handle)
	slot := extract_slot(ctx.self_handle)
	return ctx.shard.metadata[type_id][slot].group_id
}

ctx_root_supervision_group_id :: #force_inline proc() -> Supervision_Group_Id {
	return SUPERVISION_GROUP_ID_ROOT
}

ctx_type_config :: #force_inline proc(ctx: ^TinaContext) -> ^TypeDescriptor {
	type_id := extract_type_id(ctx.self_handle)
	return &ctx.shard.type_descriptors[type_id]
}

ctx_shard_id :: #force_inline proc(ctx: ^TinaContext) -> u16 {
	return ctx.shard.id
}

ctx_getsockopt :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
) -> (
	Socket_Option_Value,
	Backend_Error,
) {
	return reactor_control_getsockopt(&ctx.shard.reactor, fd, level, option)
}

@(private = "package")
_transfer_pool_free :: #force_inline proc(shard: ^Shard, index: u16) {
	reactor_buffer_pool_free(&shard.transfer_pool, index)
	shard.transfer_generations[index] += 1
	if shard.transfer_generations[index] == 0 do shard.transfer_generations[index] = 1
}
