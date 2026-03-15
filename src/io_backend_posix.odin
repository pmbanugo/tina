#+build darwin, freebsd, openbsd, netbsd
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

	MAX_POSIX_PENDING :: 1024
	MAX_POSIX_COMPLETED :: 256
	POSIX_WAKE_IDENT :: 69

	Pending_Posix_Op :: struct {
		token:     Submission_Token,
		operation: Submission_Operation,
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
		ts: posix.timespec
		_, kerr := kq.kevent(kq_fd, wake_ev[:], nil, &ts)
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
		for &sub in submissions {
			result, immediate := _try_syscall(&sub)

			if immediate {
				if backend.completed_count >= MAX_POSIX_COMPLETED {
					return .Queue_Full
				}
				backend.completed[backend.completed_count] = result
				backend.completed_count += 1
			} else {
				if backend.pending_count >= MAX_POSIX_PENDING {
					return .Queue_Full
				}
				backend.pending[backend.pending_count] = Pending_Posix_Op {
					token     = sub.token,
					operation = sub.operation,
				}
				backend.pending_count += 1

				reg_err := _register_kqueue(backend, &sub)
				if reg_err != .None {
					backend.pending_count -= 1
					return reg_err
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
		max_out := u32(len(completions))

		// Drain immediate completions first.
		for backend.completed_read < backend.completed_count && out < max_out {
			completions[out] = backend.completed[backend.completed_read]
			backend.completed_read += 1
			out += 1
		}

		// Reset completed ring when fully drained.
		if backend.completed_read >= backend.completed_count {
			backend.completed_count = 0
			backend.completed_read = 0
		}

		if out >= max_out {
			return out, .None
		}

		// Call kevent for readiness events.
		ts: posix.timespec
		ts_ptr: ^posix.timespec
		if timeout_ns <= 0 {
			ts_ptr = &ts
		} else {
			ts = posix.timespec {
				tv_sec  = posix.time_t(timeout_ns / 1_000_000_000),
				tv_nsec = c.long(timeout_ns % 1_000_000_000),
			}
			ts_ptr = &ts
		}

		events_buf: [128]kq.KEvent
		remaining := int(max_out - out)
		buf_len := min(remaining, len(events_buf))

		n, kerr := kq.kevent(kq.KQ(backend.kq_fd), nil, events_buf[:buf_len], ts_ptr)
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

			if out >= max_out {
				break
			}

			token := Submission_Token(u64(uintptr(event.udata)))
			pending_idx := _find_pending(backend, token)
			if pending_idx < 0 {
				continue
			}

			pop := &backend.pending[pending_idx]
			sub := Submission {
				token     = pop.token,
				operation = pop.operation,
			}
			result, immediate := _try_syscall(&sub)

			if immediate {
				completions[out] = result
				out += 1
				_remove_pending(backend, u16(pending_idx))
			} else {
				// Still not ready — re-register ONESHOT.
				_register_kqueue(backend, &sub)
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
		ts: posix.timespec
		kq.kevent(kq.KQ(backend.kq_fd), ev[:], nil, &ts)
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
		case:
			return .Unsupported
		}
		return .None
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
		if posix.close(posix.FD(fd)) != .OK {
			return .System_Error
		}
		return .None
	}

	// ============================================================================
	// Internal Helpers
	// ============================================================================

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
			// Set client fd non-blocking.
			flags := posix.fcntl(client_fd, .GETFL)
			if flags >= 0 {
				posix.fcntl(client_fd, .SETFL, transmute(posix.O_Flags)(flags) + {.NONBLOCK})
			}
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
		ts: posix.timespec
		_, kerr := kq.kevent(kq.KQ(backend.kq_fd), ev[:], nil, &ts)
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
	_remove_pending :: proc(backend: ^Platform_Backend, idx: u16) {
		backend.pending_count -= 1
		if idx < backend.pending_count {
			backend.pending[idx] = backend.pending[backend.pending_count]
		}
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
