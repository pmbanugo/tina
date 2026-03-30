package tina

import "core:mem"
import "core:sync"

@(require_results)
ctx_send_raw :: #force_inline proc(
	ctx: ^TinaContext,
	to: Handle,
	$tag: Message_Tag,
	payload: []u8,
) -> Send_Result {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_send: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	shard := _ctx_extract_shard(ctx)

	envelope: Message_Envelope
	envelope.source = ctx.self_handle
	envelope.destination = to
	envelope.tag = tag
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	response := _route_envelope_user(shard, to, &envelope)
	return response
}

ctx_transfer_send :: #force_inline proc(
	ctx: ^TinaContext,
	to: Handle,
	handle: Transfer_Handle,
) -> Send_Result {
	shard := _ctx_extract_shard(ctx)
	envelope: Message_Envelope
	envelope.source = ctx.self_handle
	envelope.destination = to
	envelope.tag = TAG_TRANSFER
	envelope.payload_size = size_of(Transfer_Handle)

	(cast(^Transfer_Handle)&envelope.payload[0])^ = handle

	return _route_envelope_system(shard, to, &envelope)
}

// Spawns a new Isolate and attaches it to the specified supervision group.
@(require_results)
ctx_spawn :: #force_inline proc(ctx: ^TinaContext, spec: Spawn_Spec) -> Spawn_Result {
	shard := _ctx_extract_shard(ctx)

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

@(require_results)
ctx_transfer_alloc :: #force_inline proc(ctx: ^TinaContext) -> Transfer_Alloc_Result {
	shard := _ctx_extract_shard(ctx)
	index, err := reactor_buffer_pool_alloc(&shard.transfer_pool)
	if err != .None {
		shard.counters.transfer_exhaustions += 1
		return Transfer_Alloc_Error.Pool_Exhausted
	}
	gen := shard.transfer_generations[index]
	return transfer_handle_make(index, gen)
}

ctx_transfer_write_raw :: #force_inline proc(
	ctx: ^TinaContext,
	handle: Transfer_Handle,
	data: []u8,
) -> Transfer_Write_Error {
	shard := _ctx_extract_shard(ctx)
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if index >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
		return .Stale_Handle
	}

	if u32(len(data)) > shard.transfer_pool.slot_size {
		return .Bounds_Violation
	}

	target := reactor_buffer_pool_slot_ptr(&shard.transfer_pool, index)
	mem.copy(target, raw_data(data), len(data))
	return .None
}

ctx_transfer_write_typed :: #force_inline proc(
	ctx: ^TinaContext,
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
	ctx: ^TinaContext,
	handle: Transfer_Handle,
) -> Transfer_Read_Result {
	shard := _ctx_extract_shard(ctx)
	index := transfer_handle_index(handle)
	gen := transfer_handle_generation(handle)

	if index >= shard.transfer_pool.slot_count || shard.transfer_generations[index] != gen {
		shard.counters.transfer_stale_reads += 1
		return Transfer_Read_Error.Stale_Handle
	}

	// Track auto-free lifecycle.
	type_id := extract_type_id(ctx.self_handle)
	slot := extract_slot(ctx.self_handle)
	when TINA_DEBUG_ASSERTS {
		assert(
			shard.metadata[type_id][slot].pending_transfer_read == TRANSFER_HANDLE_NONE,
			"ctx_transfer_read can only be called ONCE per handler invocation to prevent buffer leaks.",
		)
	}
	shard.metadata[type_id][slot].pending_transfer_read = handle

	ptr := reactor_buffer_pool_slot_ptr(&shard.transfer_pool, index)
	return ptr[:shard.transfer_pool.slot_size]
}

// ============================================================================
// Synchronous I/O Control Operations (§6.6.3 §4.1)
// ============================================================================

@(require_results)
ctx_socket :: #force_inline proc(
	ctx: ^TinaContext,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	FD_Handle,
	Reactor_Socket_Error,
) {
	shard := _ctx_extract_shard(ctx)
	return reactor_control_socket(&shard.reactor, ctx.self_handle, domain, socket_type, protocol)
}

ctx_bind :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	address: Socket_Address,
) -> Backend_Error {
	shard := _ctx_extract_shard(ctx)
	return reactor_control_bind(&shard.reactor, fd, ctx.self_handle, address)
}

ctx_listen :: #force_inline proc(ctx: ^TinaContext, fd: FD_Handle, backlog: u32) -> Backend_Error {
	shard := _ctx_extract_shard(ctx)
	return reactor_control_listen(&shard.reactor, fd, ctx.self_handle, backlog)
}

ctx_setsockopt_raw :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	shard := _ctx_extract_shard(ctx)
	return reactor_control_setsockopt(&shard.reactor, fd, ctx.self_handle, level, option, value)
}

ctx_setsockopt_bool :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: bool,
) -> Backend_Error {
	return ctx_setsockopt_raw(ctx, fd, level, option, value)
}

ctx_setsockopt_i32 :: #force_inline proc(
	ctx: ^TinaContext,
	fd: FD_Handle,
	level: Socket_Level,
	option: Socket_Option,
	value: i32,
) -> Backend_Error {
	return ctx_setsockopt_raw(ctx, fd, level, option, value)
}

ctx_setsockopt_linger :: #force_inline proc(
	ctx: ^TinaContext,
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
	ctx: ^TinaContext,
	fd: FD_Handle,
	how: Shutdown_How,
) -> Backend_Error {
	shard := _ctx_extract_shard(ctx)
	return reactor_control_shutdown(&shard.reactor, fd, ctx.self_handle, how)
}

ctx_read_buffer :: #force_inline proc(ctx: ^TinaContext, buffer_index: u16, size: u32) -> []u8 {
	shard := _ctx_extract_shard(ctx)
	if size <= 0 do return nil
	return reactor_buffer_pool_read_slice(&shard.reactor.buffer_pool, buffer_index, size)
}

ctx_is_shutting_down :: #force_inline proc(ctx: ^TinaContext) -> bool {
	shard := _ctx_extract_shard(ctx)
	return(
		cast(Shard_State)sync.atomic_load_explicit(shard.shared_state, .Relaxed) ==
		.Shutting_Down \
	)
}

ctx_supervision_group_id :: #force_inline proc(ctx: ^TinaContext) -> Supervision_Group_Id {
	shard := _ctx_extract_shard(ctx)
	type_id := extract_type_id(ctx.self_handle)
	slot := extract_slot(ctx.self_handle)
	return shard.metadata[type_id][slot].group_id
}

ctx_root_supervision_group_id :: #force_inline proc() -> Supervision_Group_Id {
	return SUPERVISION_GROUP_ID_ROOT
}

ctx_type_config :: #force_inline proc(ctx: ^TinaContext) -> ^TypeDescriptor {
	shard := _ctx_extract_shard(ctx)
	type_id := extract_type_id(ctx.self_handle)
	return &shard.type_descriptors[type_id]
}

ctx_shard_id :: #force_inline proc(ctx: ^TinaContext) -> u8 {
	shard := _ctx_extract_shard(ctx)
	return shard.id
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
	shard := _ctx_extract_shard(ctx)
	return reactor_control_getsockopt(&shard.reactor, fd, level, option)
}

@(private = "package")
_transfer_pool_free :: #force_inline proc(shard: ^Shard, index: u16) {
	reactor_buffer_pool_free(&shard.transfer_pool, index)
	shard.transfer_generations[index] += 1
	if shard.transfer_generations[index] == 0 do shard.transfer_generations[index] = 1
}
