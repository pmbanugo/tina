package http_server

import tina "../../.."

@(private = "file")
Listener_Dispatch_Result :: enum u8 {
	Local_Spawned,
	Handoff_Offered,
	Local_Capacity_Full,
}

@(private = "package")
_http_listener_init :: proc(self: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	listener := cast(^HTTP_Listener)self
	if len(args) < size_of(HTTP_Listener_Init_Args) {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	init_args := (cast(^HTTP_Listener_Init_Args)raw_data(args))^
	runtime_allocator := tina.ctx_working_arena(ctx)

	runtime_storage := make([]HTTP_Shard_Runtime, 1, runtime_allocator)
	listener.shard_runtime = &runtime_storage[0]
	idle_slot_indices := make([]u16, int(init_args.connection_slot_count), runtime_allocator)
	idle_slot_handles := make([]tina.Handle, int(init_args.connection_slot_count), runtime_allocator)
	idle_slot_positions := make([]u16, int(init_args.connection_slot_count), runtime_allocator)
	for index in 0 ..< len(idle_slot_positions) {
		idle_slot_positions[index] = u16(IDLE_ARRAY_INDEX_NONE)
	}
	listener.shard_runtime^ = HTTP_Shard_Runtime {
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

	if init_args.server.distribution == .Coordinator && init_args.dispatcher_shard_count > 1 {
		dispatcher_handles := make([]tina.Handle, int(init_args.dispatcher_shard_count), runtime_allocator)
		for shard_index in 0 ..< len(dispatcher_handles) {
			dispatcher_handles[shard_index] = tina.make_handle(
				tina.Shard_Id(u8(shard_index)),
				u16(init_args.dispatcher_type_id),
				0,
				1,
			)
		}
		listener.dispatcher_handles = dispatcher_handles
	}

	listener.listen_fd = _listener_open_listen_socket(ctx, listener.shard_runtime)
	if listener.listen_fd == tina.FD_HANDLE_NONE {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	return _listener_accept_effect(listener)
}

@(private = "package")
_http_listener_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	listener := cast(^HTTP_Listener)self
	if listener == nil || listener.shard_runtime == nil {
		return tina.Effect_Receive{}
	}

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		listener.shard_runtime.draining = true
		listener.shard_runtime.deadline_ns_drain = Monotonic_Time_NS(
			u64(tina.ctx_monotonic_time_ns(ctx)) + u64(listener.shard_runtime.server.graceful_drain_ms) * 1_000_000,
		)
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = listener.listen_fd}}

	case tina.IO_TAG_ACCEPT_COMPLETE:
		client_fd := message.io.fd
		if listener.shard_runtime.draining {
			if client_fd != tina.FD_HANDLE_NONE {
				return tina.Effect_Io{operation = tina.IoOp_Close{fd = client_fd}}
			}
			return tina.Effect_Receive{}
		}

		result := message.io.result
		if result >= 0 {
			if client_fd != tina.FD_HANDLE_NONE {
				dispatch_result := _listener_dispatch_connection(listener, ctx, client_fd)
				if dispatch_result == .Local_Spawned || dispatch_result == .Handoff_Offered {
					listener.shard_runtime.accept_backoff_ns = 50_000_000
					return _listener_accept_effect(listener)
				}
				if dispatch_result == .Local_Capacity_Full {
					_ = _listener_evict_idle_connection(listener, ctx)
				}
				return tina.Effect_Io{operation = tina.IoOp_Close{fd = client_fd}}
			}
			return _listener_accept_effect(listener)
		}

		if _listener_accept_fd_exhausted(result) {
			if listener.shard_runtime.accept_backoff_ns == 0 {
				listener.shard_runtime.accept_backoff_ns = 50_000_000
			} else if listener.shard_runtime.accept_backoff_ns < 250_000_000 {
				listener.shard_runtime.accept_backoff_ns *= 2
				if listener.shard_runtime.accept_backoff_ns > 250_000_000 {
					listener.shard_runtime.accept_backoff_ns = 250_000_000
				}
			}
			tina.ctx_log(
				ctx,
				tina.Log_Level.WARN,
				tina.USER_LOG_TAG_BASE,
				transmute([]u8)string("accept FD exhaustion (EMFILE/ENFILE); backing off"),
			)
			tina.ctx_register_timer(ctx, listener.shard_runtime.accept_backoff_ns, TAG_ACCEPT_BACKOFF)
			_ = _listener_evict_idle_connection(listener, ctx)
			return tina.Effect_Receive{}
		}

		return _listener_accept_effect(listener)

	case TAG_ACCEPT_BACKOFF:
		if listener.shard_runtime.draining {
			return tina.Effect_Receive{}
		}
		return _listener_accept_effect(listener)

	case tina.IO_TAG_CLOSE_COMPLETE:
		if message.io.fd == listener.listen_fd {
			return tina.Effect_Done{}
		}
		if listener.shard_runtime.draining {
			return tina.Effect_Receive{}
		}
		return _listener_accept_effect(listener)

	case:
		return tina.Effect_Receive{}
	}
}

@(private = "package")
_spawn_connection_local :: proc(runtime: ^HTTP_Shard_Runtime, ctx: ^tina.TinaContext, client_fd: tina.FD_Handle) -> bool {
	if runtime == nil {
		return false
	}

	init_args := HTTP_Connection_Init_Args {
		shard_runtime = runtime,
		client_fd     = client_fd,
	}
	args_payload, args_size := tina.init_args_of(&init_args)
	spawn_spec := tina.Spawn_Spec {
		group_id     = tina.ctx_supervision_group_id(ctx),
		type_id      = runtime.connection_type_id,
		restart_type = .temporary,
		args_payload = args_payload,
		args_size    = args_size,
		handoff_mode = .Full,
		handoff_fd   = client_fd,
	}

	spawn_result := tina.ctx_spawn(ctx, spawn_spec)
	if _, ok := spawn_result.(tina.Handle); ok {
		if runtime.free_count > 0 {
			runtime.free_count -= 1
		}
		return true
	}
	return false
}

@(private = "file")
_listener_dispatch_connection :: proc(
	listener: ^HTTP_Listener,
	ctx: ^tina.TinaContext,
	client_fd: tina.FD_Handle,
) -> Listener_Dispatch_Result {
	if len(listener.dispatcher_handles) == 0 {
		if _spawn_connection_local(listener.shard_runtime, ctx, client_fd) {
			return .Local_Spawned
		}
		return .Local_Capacity_Full
	}

	target_index := int(listener.next_dispatcher_shard_index)
	target_handle := listener.dispatcher_handles[target_index]
	target_index += 1
	if target_index >= len(listener.dispatcher_handles) {
		target_index = 0
	}
	listener.next_dispatcher_shard_index = u8(target_index)

	if tina.extract_shard_id(target_handle) == tina.extract_shard_id(ctx.self_handle) {
		if _spawn_connection_local(listener.shard_runtime, ctx, client_fd) {
			return .Local_Spawned
		}
		return .Local_Capacity_Full
	}

	handoff_result := tina.ctx_fd_handoff(ctx, target_handle, client_fd)
	if handoff_result == .ok {
		return .Handoff_Offered
	}

	if _spawn_connection_local(listener.shard_runtime, ctx, client_fd) {
		return .Local_Spawned
	}

	tina.ctx_log(
		ctx,
		tina.Log_Level.WARN,
		tina.USER_LOG_TAG_BASE,
		transmute([]u8)string("HTTP listener: FD handoff failed; closing accepted socket"),
	)
	return .Local_Capacity_Full
}

@(private = "file")
_listener_open_listen_socket :: proc(ctx: ^tina.TinaContext, runtime: ^HTTP_Shard_Runtime) -> tina.FD_Handle {
	server := &runtime.server
	domain := tina.Socket_Domain.AF_INET
	#partial switch address in server.address {
	case tina.Socket_Address_Inet4:
		domain = .AF_INET
	case tina.Socket_Address_Inet6:
		domain = .AF_INET6
	case tina.Socket_Address_Unix:
		domain = .AF_UNIX
	}

	listen_fd, socket_error := tina.ctx_socket(ctx, domain, .STREAM, .TCP)
	if socket_error != .None {
		return tina.FD_HANDLE_NONE
	}

	_ = tina.ctx_setsockopt_bool(ctx, listen_fd, .SOL_SOCKET, .SO_REUSEADDR, true)
	when ODIN_OS != .Windows {
		if server.distribution == .Reuse_Port {
			_ = tina.ctx_setsockopt_bool(ctx, listen_fd, .SOL_SOCKET, .SO_REUSEPORT, true)
		}
	}

	bind_error := tina.ctx_bind(ctx, listen_fd, server.address)
	if bind_error != .None {
		return tina.FD_HANDLE_NONE
	}

	listen_error := tina.ctx_listen(ctx, listen_fd, server.backlog)
	if listen_error != .None {
		return tina.FD_HANDLE_NONE
	}

	return listen_fd
}

@(private = "file")
_listener_accept_effect :: #force_inline proc "contextless" (listener: ^HTTP_Listener) -> tina.Effect {
	return tina.Effect_Io{operation = tina.IoOp_Accept{listen_fd = listener.listen_fd}}
}

@(private = "file")
_listener_accept_fd_exhausted :: #force_inline proc "contextless" (error_code: i32) -> bool {
	when ODIN_OS == .Windows {
		return false
	}
	return error_code == -23 || error_code == -24
}
