#+build darwin, freebsd, openbsd, netbsd
#+private
package tina

// ============================================================================
// kqueue-based POSIX Platform Backend (§6.6.2)
// ============================================================================
//
// Emulates completion semantics on top of kqueue readiness notifications:
//   Submit:  try syscall immediately (optimistic). EWOULDBLOCK → register ONESHOT.
//   Collect: drain immediates, then kevent() for readiness, retry syscall.
//   Cancel:  remove pending by token (swap-with-last).
//   Wake:    trigger EVFILT_USER.
//
// Active when TINA_SIM is false (default) on Darwin/FreeBSD/OpenBSD/NetBSD.

import "core:c"
import kq "core:sys/kqueue"
import "core:sys/posix"

when !TINA_SIMULATION_MODE {

	// Token-based correlation requires 64-bit udata in kqueue's kevent struct.
	// On 32-bit platforms, the Submission_Token (u64) would be truncated during
	// the rawptr round-trip, causing silent completion mis-routing.
	#assert(size_of(uintptr) == 8, "POSIX kqueue backend requires 64-bit uintptr for token packing")

	MAX_POSIX_PENDING :: 1024

	// Derivation: up to MAX_POSIX_PENDING (1024) submissions may complete immediately
	// during _backend_submit, but the all-or-error pre-check caps each batch to
	// available completed slots. The overflow risk is in _backend_collect: kevent
	// returns up to 128 events, each producing a completion. 256 (submit headroom)
	// + 128 (kevent batch) = 384.
	// TODO: Consider exposing via Backend_Config if workloads require larger bursts.
	MAX_POSIX_COMPLETED :: 384
	POSIX_WAKE_IDENT :: 69

	// SO_NOSIGPIPE suppresses SIGPIPE on a per-socket basis.
	// Available on Darwin (0x1022), FreeBSD (0x0800), and NetBSD (0x0800).
	// OpenBSD does NOT have SO_NOSIGPIPE — it relies solely on MSG_NOSIGNAL per-send.
	when ODIN_OS == .Darwin {
		_SO_NOSIGPIPE :: 0x1022
		_HAS_SO_NOSIGPIPE :: true
	} else when ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD {
		_SO_NOSIGPIPE :: 0x0800
		_HAS_SO_NOSIGPIPE :: true
	} else {
		// OpenBSD: no SO_NOSIGPIPE. SIGPIPE prevention uses MSG_NOSIGNAL on send/sendto.
		_SO_NOSIGPIPE :: 0
		_HAS_SO_NOSIGPIPE :: false
	}

	Pending_Posix_Op_Flag :: enum u8 {
		Connect_In_Progress,
	}
	Pending_Posix_Op_Flags :: bit_set[Pending_Posix_Op_Flag;u8]

	Pending_Posix_Op :: struct {
		token:     Submission_Token,
		operation: Submission_Operation,
		flags:     Pending_Posix_Op_Flags,
	}

	_Platform_State :: struct {
		kq_fd:           OS_FD,
		pending:         [MAX_POSIX_PENDING]Pending_Posix_Op,
		pending_count:   u16,
		completed:       [MAX_POSIX_COMPLETED]Raw_Completion,
		completed_count: u16,
		completed_read:  u16,
	}

	// ============================================================================
	// Backend API
	// ============================================================================

	@(private = "package")
	_backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
		kq_fd, err := kq.kqueue()
		if err != nil {
			return .System_Error
		}

		backend.kq_fd = OS_FD(kq_fd)
		backend.pending_count = 0
		backend.completed_count = 0
		backend.completed_read = 0

		wake_ev := [1]kq.KEvent {
			{ident = POSIX_WAKE_IDENT, filter = .User, flags = {.Add, .Enable, .Clear}},
		}
		time_spec: posix.timespec
		_, kerr := kq.kevent(kq_fd, wake_ev[:], nil, &time_spec)
		if kerr != nil {
			posix.close(kq_fd)
			return .System_Error
		}

		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		if backend.kq_fd != OS_FD_INVALID {
			posix.close(posix.FD(backend.kq_fd))
			backend.kq_fd = OS_FD_INVALID
		}
		backend.pending_count = 0
		backend.completed_count = 0
		backend.completed_read = 0
	}

	@(private = "package")
	_backend_submit :: proc(
		backend: ^Platform_Backend,
		submissions: []Submission,
	) -> Backend_Error {
		// All-or-error: pre-check worst-case capacity.
		// Each submission may go to either completed or pending.
		submission_count := u16(len(submissions))
		completed_available := MAX_POSIX_COMPLETED - backend.completed_count
		pending_available := MAX_POSIX_PENDING - backend.pending_count
		if submission_count > completed_available || submission_count > pending_available {
			return .Queue_Full
		}

		for &sub in submissions {
			result, immediate := _try_syscall(&sub)

			if immediate {
				backend.completed[backend.completed_count] = result
				backend.completed_count += 1
			} else {
				pending_flags: Pending_Posix_Op_Flags
				if _is_connect_op(&sub.operation) {
					pending_flags = {.Connect_In_Progress}
				}
				backend.pending[backend.pending_count] = Pending_Posix_Op {
					token     = sub.token,
					operation = sub.operation,
					flags     = pending_flags,
				}
				backend.pending_count += 1

				reg_err := _register_kqueue(backend, &sub)
				if reg_err != .None {
					// Registration failed — remove from pending and complete as error.
					// Cannot fail the batch: earlier submissions may have already
					// executed real syscalls (optimistic try) that cannot be rolled back.
					backend.pending_count -= 1
					backend.completed[backend.completed_count] = Raw_Completion {
						token  = sub.token,
						result = -i32(posix.Errno.EIO),
						extra  = nil,
					}
					backend.completed_count += 1
				}
			}
		}
		return .None
	}

	@(private = "package")
	_backend_collect :: proc(
		backend: ^Platform_Backend,
		completions: []Raw_Completion,
		timeout_ns: i64,
	) -> (
		u32,
		Backend_Error,
	) {
		out: u32 = 0
		output_max := u32(len(completions))

		// Drain immediate completions first.
		for backend.completed_read < backend.completed_count && out < output_max {
			completions[out] = backend.completed[backend.completed_read]
			backend.completed_read += 1
			out += 1
		}

		// Reset completed ring when fully drained.
		if backend.completed_read >= backend.completed_count {
			backend.completed_count = 0
			backend.completed_read = 0
		}

		if out >= output_max {
			return out, .None
		}

		// Call kevent for readiness events.
		time_spec: posix.timespec
		time_spec_pointer: ^posix.timespec
		if timeout_ns < 0 {
			// Negative: block indefinitely (nil timespec = wait forever)
			time_spec_pointer = nil
		} else if timeout_ns == 0 {
			// Zero: non-blocking poll
			time_spec_pointer = &time_spec
		} else {
			// Positive: bounded wait
			time_spec = posix.timespec {
				tv_sec  = posix.time_t(timeout_ns / 1_000_000_000),
				tv_nsec = c.long(timeout_ns % 1_000_000_000),
			}
			time_spec_pointer = &time_spec
		}

		events_buf: [128]kq.KEvent

		n, kerr := kq.kevent(
			kq.KQ(backend.kq_fd),
			nil,
			events_buf[:],
			time_spec_pointer,
		)
		if kerr != nil {
			if kerr == .EINTR {
				return out, .None
			}
			return out, .System_Error
		}

		for i in 0 ..< n {
			event := &events_buf[i]

			// Skip wake-up events.
			if event.filter == .User && event.ident == POSIX_WAKE_IDENT {
				continue
			}

			// EV_ERROR: changelist registration error propagated back through kevent.
			// The data field carries the errno specifically when this flag is set.
			if .Error in event.flags {
				token := Submission_Token(u64(uintptr(event.udata)))
				pending_index := _find_pending(backend, token)
				if pending_index >= 0 {
					_posix_deliver_completion(
						backend,
						completions,
						&out,
						output_max,
						Raw_Completion{token = token, result = -i32(posix.Errno(event.data))},
					)
					_remove_pending(backend, u16(pending_index))
				}
				continue
			}

			token := Submission_Token(u64(uintptr(event.udata)))
			pending_index := _find_pending(backend, token)
			if pending_index < 0 {
				continue
			}

			pop := &backend.pending[pending_index]
			event_has_eof := .EOF in event.flags

			// Connect completion: use getsockopt(SO_ERROR) instead of re-calling connect().
			if .Connect_In_Progress in pop.flags {
				conn_result := Raw_Completion {
					token = pop.token,
					extra = nil,
				}
				socket_error: posix.Errno
				socket_error_size := posix.socklen_t(size_of(socket_error))
				connect_fd := pop.operation.(Submission_Op_Connect).socket_fd
				getsockopt_result := posix.getsockopt(
					posix.FD(connect_fd),
					posix.SOL_SOCKET,
					.ERROR,
					&socket_error,
					&socket_error_size,
				)
				if getsockopt_result != .OK {
					conn_result.result = -i32(posix.errno())
				} else if socket_error != nil {
					conn_result.result = -i32(socket_error)
				} else {
					conn_result.result = 0
				}
				_posix_deliver_completion(backend, completions, &out, output_max, conn_result)
				_remove_pending(backend, u16(pending_index))
				continue
			}

			// Non-connect: retry the syscall.
			sub := Submission {
				token     = pop.token,
				operation = pop.operation,
			}
			result, immediate := _try_syscall(&sub)

			if immediate {
				_posix_deliver_completion(backend, completions, &out, output_max, result)
				_remove_pending(backend, u16(pending_index))
			} else if event_has_eof {
				// Peer closed but syscall returned EWOULDBLOCK — complete as EOF.
				// Re-registering would be pointless: no further data will arrive.
				_posix_deliver_completion(
					backend,
					completions,
					&out,
					output_max,
					Raw_Completion{token = pop.token, result = 0},
				)
				_remove_pending(backend, u16(pending_index))
			} else {
				// Still not ready — re-register ONESHOT.
				rearm_error := _register_kqueue(backend, &sub)
				if rearm_error != .None {
					// Re-registration failed — complete as error to avoid stranding
					// this operation in pending forever with no kqueue wakeup.
					_posix_deliver_completion(
						backend,
						completions,
						&out,
						output_max,
						Raw_Completion{token = pop.token, result = -i32(posix.Errno.EIO)},
					)
					_remove_pending(backend, u16(pending_index))
				}
			}
		}

		return out, .None
	}

	@(private = "package")
	_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
		for i: u16 = 0; i < backend.pending_count; i += 1 {
			if backend.pending[i].token == token {
				_remove_pending(backend, i)
				return .None
			}
		}
		return .Not_Found
	}

	@(private = "package")
	_backend_wake :: proc(backend: ^Platform_Backend) {
		ev := [1]kq.KEvent {
			{ident = POSIX_WAKE_IDENT, filter = .User, fflags = {user = {.Trigger}}},
		}
		time_spec: posix.timespec
		kq.kevent(kq.KQ(backend.kq_fd), ev[:], nil, &time_spec)
	}

	// ============================================================================
	// Synchronous Control Operations
	// ============================================================================

	@(private = "package")
	_backend_control_socket :: proc(
		backend: ^Platform_Backend,
		domain: Socket_Domain,
		socket_type: Socket_Type,
		protocol: Socket_Protocol,
	) -> (
		OS_FD,
		Backend_Error,
	) {
		af: posix.AF
		switch domain {
		case .AF_INET:
			af = .INET
		case .AF_INET6:
			af = .INET6
		case .AF_UNIX:
			af = .UNIX
		}

		st: posix.Sock
		switch socket_type {
		case .STREAM:
			st = .STREAM
		case .DGRAM:
			st = .DGRAM
		}

		proto: posix.Protocol
		switch protocol {
		case .DEFAULT:
			proto = .IP
		case .TCP:
			proto = .TCP
		case .UDP:
			proto = .UDP
		}

		fd := posix.socket(af, st, proto)
		if fd < 0 {
			return OS_FD_INVALID, .System_Error
		}

		// Set non-blocking.
		flags := posix.fcntl(fd, .GETFL)
		if flags < 0 {
			posix.close(fd)
			return OS_FD_INVALID, .System_Error
		}
		if posix.fcntl(fd, .SETFL, transmute(posix.O_Flags)(flags) + {.NONBLOCK}) < 0 {
			posix.close(fd)
			return OS_FD_INVALID, .System_Error
		}

		// Set close-on-exec.
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)

		// Suppress SIGPIPE on this socket.
		// On OpenBSD (no SO_NOSIGPIPE), SIGPIPE prevention relies on MSG_NOSIGNAL per-send.
		when _HAS_SO_NOSIGPIPE {
			nosigpipe: c.int = 1
			posix.setsockopt(
				fd,
				posix.SOL_SOCKET,
				transmute(posix.Sock_Option)c.int(_SO_NOSIGPIPE),
				&nosigpipe,
				size_of(nosigpipe),
			)
		}

		return OS_FD(fd), .None
	}

	@(private = "package")
	_backend_control_bind :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		address: Socket_Address,
	) -> Backend_Error {
		sa, sa_len := _socket_address_to_sockaddr(address)
		if sa_len == 0 {
			return .Unsupported
		}
		if posix.bind(posix.FD(fd), (^posix.sockaddr)(&sa), sa_len) != .OK {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_listen :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		backlog: u32,
	) -> Backend_Error {
		if posix.listen(posix.FD(fd), i32(backlog)) != .OK {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_setsockopt :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		level: Socket_Level,
		option: Socket_Option,
		value: Socket_Option_Value,
	) -> Backend_Error {
		plevel: c.int
		switch level {
		case .SOL_SOCKET:
			plevel = c.int(posix.SOL_SOCKET)
		case .IPPROTO_TCP:
			plevel = 6
		case .IPPROTO_UDP:
			plevel = 17
		case .IPPROTO_IPV6:
			plevel = 41
		}

		popt, opt_ok := _map_socket_option(option)
		if !opt_ok {
			return .Unsupported
		}

		switch v in value {
		case bool:
			val: c.int = v ? 1 : 0
			if posix.setsockopt(posix.FD(fd), plevel, popt, &val, size_of(val)) != .OK {
				return .System_Error
			}
		case i32:
			val := c.int(v)
			if posix.setsockopt(posix.FD(fd), plevel, popt, &val, size_of(val)) != .OK {
				return .System_Error
			}
		case Socket_Linger:
			lin := v
			if posix.setsockopt(posix.FD(fd), plevel, popt, &lin, size_of(lin)) != .OK {
				return .System_Error
			}
		case:
			return .Unsupported
		}
		return .None
	}

	@(private = "package")
	_backend_control_getsockopt :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		level: Socket_Level,
		option: Socket_Option,
	) -> (
		Socket_Option_Value,
		Backend_Error,
	) {
		plevel: c.int
		switch level {
		case .SOL_SOCKET:
			plevel = c.int(posix.SOL_SOCKET)
		case .IPPROTO_TCP:
			plevel = 6
		case .IPPROTO_UDP:
			plevel = 17
		case .IPPROTO_IPV6:
			plevel = 41
		}

		popt, opt_ok := _map_socket_option(option)
		if !opt_ok {
			return nil, .Unsupported
		}

		if option == .SO_LINGER {
			lin: Socket_Linger
			lin_len := posix.socklen_t(size_of(lin))
			if posix.getsockopt(posix.FD(fd), plevel, popt, &lin, &lin_len) != .OK {
				return nil, .System_Error
			}
			return lin, .None
		}

		val: c.int
		val_len := posix.socklen_t(size_of(val))
		if posix.getsockopt(posix.FD(fd), plevel, popt, &val, &val_len) != .OK {
			return nil, .System_Error
		}

		#partial switch option {
		case .SO_REUSEADDR, .SO_REUSEPORT, .SO_KEEPALIVE, .TCP_NODELAY, .IPV6_V6ONLY:
			return bool(val != 0), .None
		case:
			return i32(val), .None
		}
	}

	@(private = "package")
	_backend_control_shutdown :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		how: Shutdown_How,
	) -> Backend_Error {
		phow: posix.Shut
		switch how {
		case .SHUT_READER:
			phow = .RD
		case .SHUT_WRITER:
			phow = .WR
		case .SHUT_BOTH:
			phow = .RDWR
		}
		if posix.shutdown(posix.FD(fd), phow) != .OK {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc(backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
		// Sweep pending operations for this FD BEFORE closing it.
		// On BSD/macOS, close() silently removes kevents. Without this sweep,
		// pending operations on this FD would never produce a completion,
		// permanently leaking their reactor buffers. We synthesize -ECANCELED
		// completions so the reactor's stale-path reclamation frees the buffers.
		_sweep_pending_for_fd(backend, fd)

		if posix.close(posix.FD(fd)) != .OK {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_register_fixed_fd :: proc(backend: ^Platform_Backend, slot_index: u16, fd: OS_FD) {
		// No-op: kqueue has no fixed-file table.
	}

	@(private = "package")
	_backend_unregister_fixed_fd :: proc(backend: ^Platform_Backend, slot_index: u16) {
		// No-op: kqueue has no fixed-file table.
	}

	// ============================================================================
	// Internal Helpers
	// ============================================================================

	// Route a completion to the output slice if space remains, otherwise buffer internally.
	// Ensures kevent events are never dropped after kernel consumption.
	@(private = "file")
	_posix_deliver_completion :: proc(
		backend: ^Platform_Backend,
		completions: []Raw_Completion,
		out: ^u32,
		output_max: u32,
		raw: Raw_Completion,
	) {
		if out^ < output_max {
			completions[out^] = raw
			out^ += 1
		} else if backend.completed_count < MAX_POSIX_COMPLETED {
			backend.completed[backend.completed_count] = raw
			backend.completed_count += 1
		}
	}

	// Configure an accepted client socket: non-blocking, close-on-exec, SIGPIPE suppression.
	// Must be called on every FD returned by accept() before it is handed to user code.
	@(private = "file")
	_configure_accepted_socket :: proc(fd: posix.FD) {
		// Set non-blocking.
		flags := posix.fcntl(fd, .GETFL)
		if flags >= 0 {
			posix.fcntl(fd, .SETFL, transmute(posix.O_Flags)(flags) + {.NONBLOCK})
		}
		// Set close-on-exec.
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
		// Suppress SIGPIPE on the accepted socket.
		// On OpenBSD (no SO_NOSIGPIPE), SIGPIPE prevention relies on MSG_NOSIGNAL per-send.
		when _HAS_SO_NOSIGPIPE {
			nosigpipe: c.int = 1
			posix.setsockopt(
				fd,
				posix.SOL_SOCKET,
				transmute(posix.Sock_Option)c.int(_SO_NOSIGPIPE),
				&nosigpipe,
				size_of(nosigpipe),
			)
		}
	}

	@(private = "file")
	_try_syscall :: proc(sub: ^Submission) -> (Raw_Completion, bool) {
		result := Raw_Completion {
			token = sub.token,
			extra = nil,
		}

		switch op in sub.operation {
		case Submission_Op_Read:
			n := posix.pread(
				posix.FD(op.fd),
				([^]byte)(op.buffer),
				uint(op.size),
				posix.off_t(op.offset),
			)
			if n < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = i32(n)
			return result, true

		case Submission_Op_Write:
			n := posix.pwrite(
				posix.FD(op.fd),
				([^]byte)(op.buffer),
				uint(op.size),
				posix.off_t(op.offset),
			)
			if n < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = i32(n)
			return result, true

		case Submission_Op_Accept:
			client_addr: posix.sockaddr_storage
			addr_len := posix.socklen_t(size_of(client_addr))
			client_fd := posix.accept(
				posix.FD(op.listen_fd),
				(^posix.sockaddr)(&client_addr),
				&addr_len,
			)
			if client_fd < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			_configure_accepted_socket(client_fd)
			result.result = 0
			result.extra = Completion_Extra_Accept {
				client_fd      = OS_FD(client_fd),
				client_address = _sockaddr_to_socket_address(&client_addr),
			}
			return result, true

		case Submission_Op_Connect:
			sa, sa_len := _socket_address_to_sockaddr(op.address)
			if posix.connect(posix.FD(op.socket_fd), (^posix.sockaddr)(&sa), sa_len) != .OK {
				errno := posix.errno()
				if errno == .EINPROGRESS || errno == .EWOULDBLOCK {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = 0
			return result, true

		case Submission_Op_Close:
			if posix.close(posix.FD(op.fd)) != .OK {
				result.result = -i32(posix.errno())
			} else {
				result.result = 0
			}
			return result, true

		case Submission_Op_Send:
			n := posix.send(posix.FD(op.socket_fd), rawptr(op.buffer), uint(op.size), {.NOSIGNAL})
			if n < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = i32(n)
			return result, true

		case Submission_Op_Recv:
			n := posix.recv(posix.FD(op.socket_fd), rawptr(op.buffer), uint(op.size), {})
			if n < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = i32(n)
			return result, true

		case Submission_Op_Sendto:
			sa, sa_len := _socket_address_to_sockaddr(op.address)
			n := posix.sendto(
				posix.FD(op.socket_fd),
				rawptr(op.buffer),
				uint(op.size),
				{.NOSIGNAL},
				(^posix.sockaddr)(&sa),
				sa_len,
			)
			if n < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = i32(n)
			return result, true

		case Submission_Op_Recvfrom:
			peer_addr: posix.sockaddr_storage
			addr_len := posix.socklen_t(size_of(peer_addr))
			n := posix.recvfrom(
				posix.FD(op.socket_fd),
				rawptr(op.buffer),
				uint(op.size),
				{},
				(^posix.sockaddr)(&peer_addr),
				&addr_len,
			)
			if n < 0 {
				errno := posix.errno()
				if errno == .EWOULDBLOCK || errno == .EAGAIN {
					return result, false
				}
				result.result = -i32(errno)
				return result, true
			}
			result.result = i32(n)
			result.extra = Completion_Extra_Recvfrom {
				peer_address = _sockaddr_to_socket_address(&peer_addr),
			}
			return result, true

		case:
			result.result = 0
			return result, true
		}
	}

	@(private = "file")
	_register_kqueue :: proc(backend: ^Platform_Backend, sub: ^Submission) -> Backend_Error {
		filter: kq.Filter
		ident: uintptr

		switch op in sub.operation {
		case Submission_Op_Read:
			filter = .Read
			ident = uintptr(op.fd)
		case Submission_Op_Recv:
			filter = .Read
			ident = uintptr(op.socket_fd)
		case Submission_Op_Recvfrom:
			filter = .Read
			ident = uintptr(op.socket_fd)
		case Submission_Op_Accept:
			filter = .Read
			ident = uintptr(op.listen_fd)
		case Submission_Op_Write:
			filter = .Write
			ident = uintptr(op.fd)
		case Submission_Op_Send:
			filter = .Write
			ident = uintptr(op.socket_fd)
		case Submission_Op_Sendto:
			filter = .Write
			ident = uintptr(op.socket_fd)
		case Submission_Op_Connect:
			filter = .Write
			ident = uintptr(op.socket_fd)
		case Submission_Op_Close:
			return .None
		case:
			return .Unsupported
		}

		ev := [1]kq.KEvent {
			{
				ident = ident,
				filter = filter,
				flags = {.Add, .Enable, .One_Shot},
				udata = rawptr(uintptr(u64(sub.token))),
			},
		}
		time_spec: posix.timespec
		_, kerr := kq.kevent(kq.KQ(backend.kq_fd), ev[:], nil, &time_spec)
		if kerr != nil {
			return .System_Error
		}
		return .None
	}

	@(private = "file")
	_find_pending :: proc(backend: ^Platform_Backend, token: Submission_Token) -> i32 {
		for i: u16 = 0; i < backend.pending_count; i += 1 {
			if backend.pending[i].token == token {
				return i32(i)
			}
		}
		return -1
	}

	@(private = "file")
	_remove_pending :: proc(backend: ^Platform_Backend, index: u16) {
		backend.pending_count -= 1
		if index < backend.pending_count {
			backend.pending[index] = backend.pending[backend.pending_count]
		}
	}

	// Sweep pending operations matching a given OS_FD.
	// Synthesizes -ECANCELED completions for each match so the reactor's
	// stale-path reclamation can free their buffers. Called before close()
	// because on kqueue, close() silently removes kevents without firing events.
	@(private = "file")
	_sweep_pending_for_fd :: proc(backend: ^Platform_Backend, fd: OS_FD) {
		i: u16 = 0
		for i < backend.pending_count {
			op_fd := _submission_op_fd(backend.pending[i].operation)
			if op_fd == fd {
				// Synthesize cancellation completion
				if backend.completed_count < MAX_POSIX_COMPLETED {
					backend.completed[backend.completed_count] = Raw_Completion{
						token  = backend.pending[i].token,
						result = -i32(posix.Errno.ECANCELED),
						extra  = nil,
					}
					backend.completed_count += 1
				}
				_remove_pending(backend, i)
				// Don't increment — swapped-in element needs checking
			} else {
				i += 1
			}
		}
	}

	// Extract the OS_FD from a Submission_Operation for FD-based sweep matching.
	@(private = "file")
	_submission_op_fd :: proc(op: Submission_Operation) -> OS_FD {
		switch o in op {
		case Submission_Op_Read:     return o.fd
		case Submission_Op_Write:    return o.fd
		case Submission_Op_Accept:   return o.listen_fd
		case Submission_Op_Connect:  return o.socket_fd
		case Submission_Op_Close:    return o.fd
		case Submission_Op_Send:     return o.socket_fd
		case Submission_Op_Recv:     return o.socket_fd
		case Submission_Op_Sendto:   return o.socket_fd
		case Submission_Op_Recvfrom: return o.socket_fd
		}
		return OS_FD_INVALID
	}

	@(private = "file")
	_socket_address_to_sockaddr :: proc(
		addr: Socket_Address,
	) -> (
		posix.sockaddr_storage,
		posix.socklen_t,
	) {
		sa: posix.sockaddr_storage

		switch a in addr {
		case Socket_Address_Inet4:
			sin := (^posix.sockaddr_in)(&sa)
			sin.sin_family = .INET
			sin.sin_port = u16be(a.port)
			sin.sin_addr = transmute(posix.in_addr)a.address
			sin.sin_len = size_of(posix.sockaddr_in)
			return sa, posix.socklen_t(size_of(posix.sockaddr_in))
		case Socket_Address_Inet6:
			sin6 := (^posix.sockaddr_in6)(&sa)
			sin6.sin6_family = .INET6
			sin6.sin6_port = u16be(a.port)
			sin6.sin6_addr = transmute(posix.in6_addr)a.address
			sin6.sin6_flowinfo = a.flow
			sin6.sin6_scope_id = a.scope
			sin6.sin6_len = size_of(posix.sockaddr_in6)
			return sa, posix.socklen_t(size_of(posix.sockaddr_in6))
		case Socket_Address_Unix:
			sun := (^posix.sockaddr_un)(&sa)
			sun.sun_family = .UNIX
			sun.sun_len = size_of(posix.sockaddr_un)
			for i in 0 ..< len(a.path) {
				sun.sun_path[i] = c.char(a.path[i])
			}
			return sa, posix.socklen_t(size_of(posix.sockaddr_un))
		case:
			return sa, 0
		}
	}

	@(private = "file")
	_sockaddr_to_socket_address :: proc(native: ^posix.sockaddr_storage) -> Socket_Address {
		#partial switch native.ss_family {
		case .INET:
			sin := (^posix.sockaddr_in)(native)
			return Socket_Address_Inet4 {
				address = transmute([4]u8)sin.sin_addr,
				port = u16(u16be(sin.sin_port)),
			}
		case .INET6:
			sin6 := (^posix.sockaddr_in6)(native)
			return Socket_Address_Inet6 {
				address = transmute([16]u8)sin6.sin6_addr,
				port = u16(u16be(sin6.sin6_port)),
				flow = sin6.sin6_flowinfo,
				scope = sin6.sin6_scope_id,
			}
		case:
			return nil
		}
	}

	@(private = "file")
	_is_connect_op :: #force_inline proc(op: ^Submission_Operation) -> bool {
		_, ok := op.(Submission_Op_Connect)
		return ok
	}

	@(private = "file")
	_map_socket_option :: proc(option: Socket_Option) -> (posix.Sock_Option, bool) {
		#partial switch option {
		case .SO_REUSEADDR:
			return .REUSEADDR, true
		case .SO_KEEPALIVE:
			return .KEEPALIVE, true
		case .SO_RCVBUF:
			return .RCVBUF, true
		case .SO_SNDBUF:
			return .SNDBUF, true
		case .SO_LINGER:
			return .LINGER, true
		case:
			return .REUSEADDR, false
		}
	}

} // when !TINA_SIM
