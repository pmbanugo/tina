package http_server

import tina "../../.."

@(private = "package")
_http_dispatcher_init :: proc(self: rawptr, args: []u8) -> tina.Isolate_Transition {
	dispatcher := cast(^HTTP_Dispatcher)self
	if len(args) < size_of(HTTP_Dispatcher_Init_Args) {
		return tina.transition_to_crash(.Init_Failed)
	}

	init_args := (cast(^HTTP_Dispatcher_Init_Args)raw_data(args))^
	runtime_allocator := tina.ctx_working_arena()

	dispatcher.shard_runtime = _make_shard_runtime(
		runtime_allocator,
		init_args.server,
		init_args.router,
		init_args.connection_slot_count,
		init_args.connection_type_id,
	)

	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

@(private = "package")
_http_dispatcher_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
) -> tina.Isolate_Transition {
	dispatcher := cast(^HTTP_Dispatcher)self
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(dispatcher != nil, "_http_dispatcher_handler: dispatcher is nil")
		assert(dispatcher.shard_runtime != nil, "_http_dispatcher_handler: shard runtime is nil")
	}

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		dispatcher.shard_runtime.draining = true
		return tina.ISOLATE_TRANSITION_DONE

	case tina.IO_TAG_ACCEPT_COMPLETE:
		client_fd := message.io.fd
		if client_fd == tina.FD_HANDLE_NONE {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if dispatcher.shard_runtime.draining {
			return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = client_fd}))
		}
		if _spawn_connection_local(dispatcher.shard_runtime, client_fd) {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		_ = _runtime_evict_idle_connection(dispatcher.shard_runtime)
		return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = client_fd}))

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}
