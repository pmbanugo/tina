package http_server

import tina "../../.."

// Listener control-plane tags stay package-private and never leave the HTTP
// extension boundary.
@(private = "package")
TAG_ACCEPT_BACKOFF :: tina.Message_Tag(0xFFFD)

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
	listener.shard_runtime^ = HTTP_Shard_Runtime {
		server                = init_args.server^,
		router                = init_args.router,
		keepalive_reserve     = init_args.server.keepalive.reserve_slots,
		idle_slot_indices     = make([]u16, int(init_args.connection_slot_count), runtime_allocator),
		idle_count            = 0,
		free_count            = init_args.connection_slot_count,
		connection_slot_count = init_args.connection_slot_count,
		accept_backoff_ns     = 50_000_000,
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
		return tina.Effect_Done{}

	case tina.IO_TAG_ACCEPT_COMPLETE:
		result := message.io.result
		if result >= 0 {
			client_fd := message.io.fd
			if client_fd != tina.FD_HANDLE_NONE {
				success := _listener_spawn_connection(listener, ctx, client_fd)
				if success {
					listener.shard_runtime.accept_backoff_ns = 50_000_000
					if listener.shard_runtime.free_count > 0 {
						listener.shard_runtime.free_count -= 1
					}
					return _listener_accept_effect(listener)
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
			return tina.Effect_Receive{}
		}

		return _listener_accept_effect(listener)

	case TAG_ACCEPT_BACKOFF:
		return _listener_accept_effect(listener)

	case tina.IO_TAG_CLOSE_COMPLETE:
		return _listener_accept_effect(listener)

	case:
		return tina.Effect_Receive{}
	}
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
_listener_spawn_connection :: proc(listener: ^HTTP_Listener, ctx: ^tina.TinaContext, client_fd: tina.FD_Handle) -> bool {
	init_args := HTTP_Connection_Init_Args {
		shard_runtime = listener.shard_runtime,
		client_fd     = client_fd,
	}
	args_payload, args_size := tina.init_args_of(&init_args)
	spawn_spec := tina.Spawn_Spec {
		group_id     = tina.ctx_supervision_group_id(ctx),
		type_id      = HTTP_TYPE_ID_CONNECTION,
		restart_type = .temporary,
		args_payload = args_payload,
		args_size    = args_size,
		handoff_mode = .Full,
		handoff_fd   = client_fd,
	}

	spawn_result := tina.ctx_spawn(ctx, spawn_spec)
	if _, ok := spawn_result.(tina.Handle); ok {
		return true
	}
	return false
}

@(private = "file")
_listener_accept_fd_exhausted :: #force_inline proc "contextless" (error_code: i32) -> bool {
	when ODIN_OS == .Windows {
		return false
	}
	return error_code == -23 || error_code == -24
}
