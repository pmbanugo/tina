package http_server

import tina "../../.."

@(private = "package")
_http_dispatcher_init :: proc(self: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	dispatcher := cast(^HTTP_Dispatcher)self
	if len(args) < size_of(HTTP_Dispatcher_Init_Args) {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	init_args := (cast(^HTTP_Dispatcher_Init_Args)raw_data(args))^
	runtime_allocator := tina.ctx_working_arena(ctx)

	runtime_storage := make([]HTTP_Shard_Runtime, 1, runtime_allocator)
	dispatcher.shard_runtime = &runtime_storage[0]
	idle_slot_indices := make([]u16, int(init_args.connection_slot_count), runtime_allocator)
	idle_slot_handles := make([]tina.Handle, int(init_args.connection_slot_count), runtime_allocator)
	idle_slot_positions := make([]u16, int(init_args.connection_slot_count), runtime_allocator)
	for index in 0 ..< len(idle_slot_positions) {
		idle_slot_positions[index] = u16(IDLE_ARRAY_INDEX_NONE)
	}
	dispatcher.shard_runtime^ = HTTP_Shard_Runtime {
		server               = init_args.server^,
		router               = init_args.router,
		connection_type_id   = init_args.connection_type_id,
		keepalive_reserve    = init_args.server.keepalive.reserve_slots,
		idle_slot_indices    = idle_slot_indices,
		idle_slot_handles    = idle_slot_handles,
		idle_slot_positions  = idle_slot_positions,
		idle_count           = 0,
		free_count           = init_args.connection_slot_count,
		connection_slot_count = init_args.connection_slot_count,
		accept_backoff_ns    = 50_000_000,
	}

	return tina.Effect_Receive{}
}

@(private = "package")
_http_dispatcher_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	dispatcher := cast(^HTTP_Dispatcher)self
	if dispatcher == nil || dispatcher.shard_runtime == nil {
		return tina.Effect_Receive{}
	}

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		dispatcher.shard_runtime.draining = true
		return tina.Effect_Receive{}

	case tina.IO_TAG_ACCEPT_COMPLETE:
		client_fd := message.io.fd
		if client_fd == tina.FD_HANDLE_NONE {
			return tina.Effect_Receive{}
		}
		if dispatcher.shard_runtime.draining {
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = client_fd}}
		}
		if _spawn_connection_local(dispatcher.shard_runtime, ctx, client_fd) {
			return tina.Effect_Receive{}
		}
		_ = _runtime_evict_idle_connection(dispatcher.shard_runtime, ctx)
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = client_fd}}

	case:
		return tina.Effect_Receive{}
	}
}
