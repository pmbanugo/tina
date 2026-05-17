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
shard_maintenance_invocation :: #force_inline proc(
	ctx: Shard_Maintenance_Context,
) -> ^Isolate_Invocation {
	invocation := ctx_invocation(TinaContext(ctx))
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			.Maintenance in invocation.flags,
			"Shard_Maintenance_Context used outside active maintenance callback",
		)
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

ctx_register_shard_maintenance_task :: proc(
	ctx: TinaContext,
	descriptor: Shard_Maintenance_Descriptor,
) -> Maintenance_Task_Index {
	shard := ctx_invocation(ctx).shard
	if int(shard.maintenance_task_count) >= len(shard.maintenance_tasks) {
		return MAINTENANCE_TASK_INDEX_NONE
	}

	task_index := Maintenance_Task_Index(shard.maintenance_task_count)
	task := descriptor
	if task.cadence_tick_count == 0 {
		task.cadence_tick_count = 1
	}
	if task.budget_weight == 0 {
		task.budget_weight = Scheduler_Weight_Count(1)
	}
	if task.work_budget_count_max == 0 {
		task.work_budget_count_max = Scheduler_Work_Count(SCHEDULER_MAINTENANCE_TURN_WORK_BUDGET_COUNT)
	}
	task_position := int(task_index)
	shard.maintenance_tasks[task_position] = Shard_Maintenance_Task {
		state                 = task.state,
		handler               = task.handler,
		next_tick             = shard.current_tick,
		cadence_tick_count    = task.cadence_tick_count,
		budget_weight         = task.budget_weight,
		work_budget_count_max = task.work_budget_count_max,
	}
	shard.maintenance_task_count += 1
	return task_index
}

ctx_reschedule_shard_maintenance_task :: proc(
	ctx: TinaContext,
	task_index: Maintenance_Task_Index,
	next_tick: u64,
) -> bool {
	if task_index == MAINTENANCE_TASK_INDEX_NONE {
		return false
	}
	shard := ctx_invocation(ctx).shard
	if int(task_index) >= int(shard.maintenance_task_count) {
		return false
	}
	task := &shard.maintenance_tasks[int(task_index)]
	if task.handler == nil {
		return false
	}
	task.next_tick = next_tick
	return true
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

ctx_type_config :: #force_inline proc(ctx: TinaContext) -> ^TypeDescriptor {
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
@(require_results)
shard_maintenance_send_local_with_correlation :: #force_inline proc(
	ctx: Shard_Maintenance_Context,
	to: Handle,
	tag: Message_Tag,
	payload: []u8,
	correlation: Correlation_Id,
) -> Send_Result {
	when TINA_RUNTIME_ASSERTIONS {
		assert(
			tag >= USER_MESSAGE_TAG_BASE,
			"shard_maintenance_send_local_with_correlation: Tag must be >= 0x0040.",
		)
		assert(
			len(payload) <= MAX_PAYLOAD_SIZE,
			"shard_maintenance_send_local_with_correlation payload exceeds MAX_PAYLOAD_SIZE",
		)
	}
	invocation := shard_maintenance_invocation(ctx)
	shard := invocation.shard
	if extract_shard_id(to) != invocation.shard_id {
		return .stale_handle
	}

	envelope: Message_Envelope
	envelope.source = HANDLE_NONE
	envelope.destination = to
	envelope.tag = tag
	envelope.correlation = correlation
	envelope.payload_size = u16(len(payload))
	copy(envelope.payload[:], payload)

	return _enqueue_system_msg(shard, to, &envelope)
}

@(require_results)
shard_maintenance_send_local :: #force_inline proc(
	ctx: Shard_Maintenance_Context,
	to: Handle,
	tag: Message_Tag,
	payload: []u8,
) -> Send_Result {
	return shard_maintenance_send_local_with_correlation(
		ctx,
		to,
		tag,
		payload,
		CORRELATION_ID_NONE,
	)
}

// Wakes a same-shard target if it is currently blocked on I/O. This mirrors
// the timer wheel's stale-completion protocol: bump io_sequence so the
// abandoned completion is discarded later, then make the slot runnable so a
// queued timeout/control message can be dispatched.
@(require_results)
shard_maintenance_wake_if_waiting_for_io :: #force_inline proc(
	ctx: Shard_Maintenance_Context,
	target: Handle,
) -> bool {
	invocation := shard_maintenance_invocation(ctx)
	if extract_shard_id(target) != invocation.shard_id {
		return false
	}

	shard := invocation.shard
	type_id := extract_type_id(target)
	if int(type_id) >= len(shard.metadata) {
		return false
	}

	slot_index := extract_slot(target)
	soa_meta := shard.metadata[type_id]
	if int(slot_index) >= len(soa_meta) {
		return false
	}
	if soa_meta[slot_index].generation != extract_generation(target) {
		return false
	}
	if soa_meta[slot_index].state != .Waiting_For_Io {
		return false
	}

	soa_meta[slot_index].io_sequence += 1
	_slot_set_state(shard, type_id, slot_index, .Runnable)
	return true
}

@(private = "package")
_transfer_pool_free :: #force_inline proc(shard: ^Shard, index: u16) {
	reactor_buffer_pool_free(&shard.transfer_pool, index)
	shard.transfer_generations[index] += 1
	if shard.transfer_generations[index] == 0 do shard.transfer_generations[index] = 1
}
