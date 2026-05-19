package http_server

import tina "../../.."

@(private = "package")
_http_dispatcher_init :: proc(self: rawptr, args: []u8, ctx: tina.TinaContext) -> tina.Effect {
	dispatcher := cast(^HTTP_Dispatcher)self
	if len(args) < size_of(HTTP_Dispatcher_Init_Args) {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	init_args := (cast(^HTTP_Dispatcher_Init_Args)raw_data(args))^
	runtime_allocator := tina.ctx_working_arena(ctx)

	dispatcher.shard_runtime = _make_shard_runtime(
		runtime_allocator,
		init_args.server,
		init_args.router,
		init_args.connection_slot_count,
		init_args.connection_type_id,
	)

	return tina.Effect_Receive{}
}

@(private = "package")
_http_dispatcher_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
	ctx: tina.TinaContext,
) -> tina.Effect {
	dispatcher := cast(^HTTP_Dispatcher)self
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(dispatcher != nil, "_http_dispatcher_handler: dispatcher is nil")
		assert(dispatcher.shard_runtime != nil, "_http_dispatcher_handler: shard runtime is nil")
	}

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		dispatcher.shard_runtime.draining = true
		return tina.Effect_Done{}

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
