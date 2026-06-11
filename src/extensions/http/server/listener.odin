package http_server

import tina "../../.."
import "core:fmt"
import "core:testing"

@(private = "package")
HTTP_TCP_NOTSENT_LOWAT_BYTES :: #config(HTTP_TCP_NOTSENT_LOWAT_BYTES, 16 * 1024)

@(private = "file")
Listener_Dispatch_Result :: enum u8 {
	Local_Spawned,
	Handoff_Offered,
	Local_Capacity_Full,
}

@(private = "file")
_listener_log_startup_failure :: proc(
	stage: string,
	address: tina.Socket_Address,
	error_label: string,
	advice: string,
) {
	message := fmt.tprintf(
		"HTTP listener startup failed during %s for %v (%s). %s",
		stage,
		address,
		error_label,
		advice,
	)
	tina.ctx_log(
		tina.Log_Level.ERROR,
		tina.USER_LOG_TAG_BASE,
		transmute([]u8)message,
	)
}

@(private = "package")
_http_listener_init :: proc(self: rawptr, args: []u8) -> tina.Isolate_Transition {
	listener := cast(^HTTP_Listener)self
	if len(args) < size_of(HTTP_Listener_Init_Args) {
		return tina.transition_to_crash(.Init_Failed)
	}

	init_args := (cast(^HTTP_Listener_Init_Args)raw_data(args))^
	runtime_allocator := tina.ctx_working_arena()

	listener.shard_runtime = _make_shard_runtime(
		runtime_allocator,
		init_args.server,
		init_args.router,
		init_args.connection_slot_count,
		init_args.connection_type_id,
	)
	topology, topology_error := _derive_http_ingress_topology(
		init_args.dispatcher_shard_count,
		init_args.server.ingress_mode,
	)
	if topology_error != .None {
		return tina.transition_to_crash(.Init_Failed)
	}

	if topology.coordinator_mode_enabled {
		dispatcher_handles := make([]tina.Isolate_Handle, int(init_args.dispatcher_shard_count), runtime_allocator)
		for shard_index in 0 ..< len(dispatcher_handles) {
			dispatcher_handles[shard_index] = tina.make_handle(
				tina.Shard_Id(u8(shard_index)),
				init_args.dispatcher_type_id,
				0,
				1,
			)
		}
		listener.dispatcher_handles = dispatcher_handles
	}

	listener.listen_fd = _listener_open_listen_socket(listener.shard_runtime, topology.bind_mode)
	if listener.listen_fd == tina.FD_HANDLE_NONE {
		return tina.transition_to_crash(.Init_Failed)
	}

	return _listener_accept_effect(listener)
}

@(private = "package")
_http_listener_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
) -> tina.Isolate_Transition {
	listener := cast(^HTTP_Listener)self
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(listener != nil, "_http_listener_handler: listener is nil")
		assert(listener.shard_runtime != nil, "_http_listener_handler: shard runtime is nil")
	}

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		listener.shard_runtime.draining = true
		return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = listener.listen_fd}))

	case tina.IO_TAG_ACCEPT_COMPLETE:
		client_fd := message.io.fd
		if listener.shard_runtime.draining {
			if client_fd != tina.FD_HANDLE_NONE {
				return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = client_fd}))
			}
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}

		result := message.io.result
		if result >= 0 {
			if client_fd != tina.FD_HANDLE_NONE {
				dispatch_result := _listener_dispatch_connection(listener, client_fd)
				if dispatch_result == .Local_Spawned || dispatch_result == .Handoff_Offered {
					listener.shard_runtime.accept_backoff_ns = 50_000_000
					return _listener_accept_effect(listener)
				}
				if dispatch_result == .Local_Capacity_Full {
					_ = _listener_evict_idle_connection(listener)
				}
				return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = client_fd}))
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
			tina.ctx_log_raw(
				tina.Log_Level.WARN,
				tina.USER_LOG_TAG_BASE,
				transmute([]u8)string("accept FD exhaustion (EMFILE/ENFILE); backing off"),
			)
			tina.ctx_register_timer( listener.shard_runtime.accept_backoff_ns, TAG_ACCEPT_BACKOFF)
			_ = _listener_evict_idle_connection(listener)
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}

		return _listener_accept_effect(listener)

	case TAG_ACCEPT_BACKOFF:
		if listener.shard_runtime.draining {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		return _listener_accept_effect(listener)

	case tina.IO_TAG_CLOSE_COMPLETE:
		if message.io.fd == listener.listen_fd {
			return tina.ISOLATE_TRANSITION_DONE
		}
		if listener.shard_runtime.draining {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		return _listener_accept_effect(listener)

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

@(private = "package")
_spawn_connection_local :: proc(runtime: ^HTTP_Shard_Runtime, client_fd: tina.FD_Handle) -> bool {
	if runtime == nil {
		return false
	}

	init_args := HTTP_Connection_Init_Args {
		shard_runtime = runtime,
		client_fd     = client_fd,
	}
	args_payload, args_size := tina.init_args_of(&init_args)
	spawn_spec := tina.Spawn_Spec {
		group_id     = tina.ctx_supervision_group_id(),
		type_id      = runtime.connection_type_id,
		restart_type = .temporary,
		args_payload = args_payload,
		args_size    = args_size,
		handoff_mode = .Full,
		handoff_fd   = client_fd,
	}

	spawn_result := tina.ctx_spawn(spawn_spec)
	if _, ok := spawn_result.(tina.Isolate_Handle); ok {
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
	client_fd: tina.FD_Handle,
) -> Listener_Dispatch_Result {
	if len(listener.dispatcher_handles) == 0 {
		if _spawn_connection_local(listener.shard_runtime, client_fd) {
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

	if tina.extract_shard_id(target_handle) == tina.extract_shard_id(tina.ctx_self_handle()) {
		if _spawn_connection_local(listener.shard_runtime, client_fd) {
			return .Local_Spawned
		}
		return .Local_Capacity_Full
	}

	handoff_result := tina.ctx_fd_handoff( target_handle, client_fd)
	if handoff_result == .ok {
		return .Handoff_Offered
	}

	if _spawn_connection_local(listener.shard_runtime, client_fd) {
		return .Local_Spawned
	}

	tina.ctx_log_raw(
		tina.Log_Level.WARN,
		tina.USER_LOG_TAG_BASE,
		transmute([]u8)string("HTTP listener: FD handoff failed; closing accepted socket"),
	)
	return .Local_Capacity_Full
}

@(private = "file")
_listener_open_listen_socket :: proc(
	runtime: ^HTTP_Shard_Runtime,
	bind_mode: Listener_Bind_Mode,
) -> tina.FD_Handle {
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

	listen_fd, socket_error := tina.ctx_socket(domain, .STREAM, .TCP)
	if socket_error != .None {
		error_label := "backend error"
		advice := "Inspect the platform socket configuration and prior system logs."
		#partial switch socket_error {
		case .FD_Table_Full:
			error_label = "fd table full"
			advice = "Increase Tina's fd table capacity for this shard."
		case .Resource_Exhausted:
			error_label = "resource exhausted"
			advice = "Check process file-descriptor limits and kernel socket resources."
		case .Permission_Denied:
			error_label = "permission denied"
			advice = "Check the process privileges and security policy for socket creation."
		case .Invalid_Argument:
			error_label = "invalid argument"
			advice = "Check the configured address family, socket type, and protocol."
		case .Unsupported:
			error_label = "unsupported"
			advice = "Check whether this socket family/protocol is supported on the current platform."
		}
		_listener_log_startup_failure(
			"socket",
			server.address,
			error_label,
			advice,
		)
		return tina.FD_HANDLE_NONE
	}

	when ODIN_OS == .Windows {
		if bind_mode == .Exclusive {
			_ = tina.ctx_setsockopt_bool(listen_fd, .SOL_SOCKET, .SO_EXCLUSIVEADDRUSE, true)
		}
	} else {
		_ = tina.ctx_setsockopt_bool(listen_fd, .SOL_SOCKET, .SO_REUSEADDR, true)
		if bind_mode == .Reuse_Port {
			_ = tina.ctx_setsockopt_bool(listen_fd, .SOL_SOCKET, .SO_REUSEPORT, true)
		}
	}

	bind_error := tina.ctx_bind(listen_fd, server.address)
	if bind_error != .None {
		error_label := "system error"
		advice := "Inspect the platform socket configuration and prior system logs."
		#partial switch bind_error {
		case .Address_In_Use:
			error_label = "address already in use"
			advice = "Stop the process already using this address or choose a different host/port."
		case .Address_Not_Available:
			error_label = "address not available"
			advice = "Bind only to an address configured on this host."
		case .Permission_Denied:
			error_label = "permission denied"
			advice = "Check the process privileges and whether this port/address requires elevated access."
		case .Invalid_Argument:
			error_label = "invalid argument"
			advice = "Check the listener address configuration."
		case .Resource_Exhausted:
			error_label = "resource exhausted"
			advice = "Check process file-descriptor limits and kernel socket resources."
		case .Unsupported:
			error_label = "unsupported"
		}
		_ = tina.ctx_close_fd(listen_fd)
		_listener_log_startup_failure(
			"bind",
			server.address,
			error_label,
			advice,
		)
		return tina.FD_HANDLE_NONE
	}

	listen_error := tina.ctx_listen(listen_fd, server.backlog)
	if listen_error != .None {
		error_label := "system error"
		advice := "Inspect the platform socket configuration and prior system logs."
		#partial switch listen_error {
		case .Invalid_Argument:
			error_label = "invalid argument"
			advice = "Check the configured listen backlog and socket state."
		case .Permission_Denied:
			error_label = "permission denied"
			advice = "Check the process privileges and network policy for listen()."
		case .Resource_Exhausted:
			error_label = "resource exhausted"
			advice = "Check process file-descriptor limits and kernel socket resources."
		case .Address_In_Use:
			error_label = "address already in use"
			advice = "Stop the process already using this address or choose a different host/port."
		case .Address_Not_Available:
			error_label = "address not available"
			advice = "Bind only to an address configured on this host."
		case .Unsupported:
			error_label = "unsupported"
		}
		_ = tina.ctx_close_fd(listen_fd)
		_listener_log_startup_failure(
			"listen",
			server.address,
			error_label,
			advice,
		)
		return tina.FD_HANDLE_NONE
	}

	// Inherited by accepted connections to ensure zero setsockopt syscalls on each connections.
	_ = tina.ctx_setsockopt_bool(listen_fd, .IPPROTO_TCP, .TCP_NODELAY, true)
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		_ = tina.ctx_setsockopt_i32(listen_fd, .IPPROTO_TCP, .TCP_NOTSENT_LOWAT, i32(HTTP_TCP_NOTSENT_LOWAT_BYTES))
	}
	when ODIN_OS == .Linux {
		_ = tina.ctx_setsockopt_i32(listen_fd, .IPPROTO_TCP, .TCP_DEFER_ACCEPT, 1)
	}
	// The following features are intentionally rejected/untouched (left as OS defaults):
	// - TCP_CORK / TCP_NOPUSH (rejected in favor of Application equivalent)
	// - SO_KEEPALIVE (rejected in favor of Tina's timer wheel)
	// - SO_RCVBUF / SO_SNDBUF (untouched, leave to kernel auto-tuning)
	// - TCP_FASTOPEN (deferred)

	return listen_fd
}

@(private = "file")
_listener_accept_effect :: #force_inline proc(listener: ^HTTP_Listener) -> tina.Isolate_Transition {
	return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Accept{listen_fd = listener.listen_fd}))
}

@(private = "file")
_listener_accept_fd_exhausted :: #force_inline proc "contextless" (error_code: i32) -> bool {
	when ODIN_OS == .Windows {
		return false
	}
	return error_code == -23 || error_code == -24
}

@(test)
test_listener_shutdown_close_completion_terminates_listener :: proc(t: ^testing.T) {
	runtime := HTTP_Shard_Runtime{}
	listener := HTTP_Listener {
		listen_fd     = tina.FD_Handle(41),
		shard_runtime = &runtime,
	}

	Listener_Shutdown_Test_State :: struct {
		listener: ^HTTP_Listener,
		t:        ^testing.T,
	}
	test_state := Listener_Shutdown_Test_State {
		listener = &listener,
		t        = t,
	}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle         = tina.make_handle(0, HTTP_TYPE_OFFSET_LISTENER, 0, 1),
			timer_resolution_ns = 1,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Listener_Shutdown_Test_State)user_data
			shutdown_message: tina.Message
			shutdown_message.tag = tina.TAG_SHUTDOWN
			effect := _http_listener_handler(rawptr(state.listener), &shutdown_message)
			testing.expect_value(state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			#partial switch close_op in tina.ctx_staged_io_operation() {
			case tina.IoOp_Close:
				testing.expect_value(state.t, close_op.fd, state.listener.listen_fd)
			case:
				testing.expect(state.t, false, "listener shutdown must close the listen socket")
			}

			close_complete: tina.Message
			close_complete.tag = tina.IO_TAG_CLOSE_COMPLETE
			close_complete.io.fd = state.listener.listen_fd
			effect = _http_listener_handler(rawptr(state.listener), &close_complete)
			if effect.kind != tina.Isolate_Transition_Kind.Done {
				testing.expect(state.t, false, "listener must terminate when its listen socket close completes")
			}
		},
	)

	testing.expect(t, runtime.draining, "listener shutdown must mark the shard runtime draining")
}
