#+build linux
package tina

// ============================================================================
// io_uring Linux Backend (§6.6.2) — Batch SQE Submission & CQE Harvesting
// ============================================================================
//
// Active when ODIN_OS == .Linux and TINA_SIM == false.
// Uses io_uring for async I/O with token-based correlation.
//
// Design:
//   Submit: map each Submission to an io_uring SQE, store token as user_data.
//           If SQ is full, buffer in overflow array.
//   Collect: harvest CQEs, construct Raw_Completion from each. Flush overflow.
//   Cancel: IORING_OP_ASYNC_CANCEL.
//   Wake: write to eventfd.

import "core:sys/linux"
import "core:sys/linux/uring"

when !#config(TINA_SIM, false) {

MAX_LINUX_UNQUEUED     :: 256
MAX_LINUX_PENDING_ADDRS :: 64

// Persistent storage for io_uring operations that need stable pointers
// (accept, connect, sendto, recvfrom). Allocated on submit, freed on CQE.
Pending_Addr_Entry :: struct {
	token:        Submission_Token,
	sockaddr:     linux.Sock_Addr_Any,
	sockaddr_len: i32,
	msghdr:       linux.Msg_Hdr,
	iovec:        linux.IO_Vec,
	active:       bool,
}

_Platform_State :: struct {
	ring:           uring.Ring,
	wake_fd:        OS_FD,
	unqueued:       [MAX_LINUX_UNQUEUED]Submission,
	unqueued_count: u16,
	addr_entries:   [MAX_LINUX_PENDING_ADDRS]Pending_Addr_Entry,
}

// ============================================================================
// Backend Procedures
// ============================================================================

@(private = "package")
_backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
	queue_size := config.queue_size
	if queue_size == 0 {
		queue_size = DEFAULT_BACKEND_QUEUE_SIZE
	}

	params := uring.DEFAULT_PARAMS
	params.flags += {.SUBMIT_ALL, .COOP_TASKRUN, .SINGLE_ISSUER}

	uerr := uring.init(&backend.ring, &params, queue_size)
	if uerr != nil {
		return .System_Error
	}

	wakefd, wakefd_err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if wakefd_err != nil {
		uring.destroy(&backend.ring)
		return .System_Error
	}
	backend.wake_fd = OS_FD(wakefd)
	backend.unqueued_count = 0

	for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
		backend.addr_entries[i].active = false
	}

	return .None
}

@(private = "package")
_backend_deinit :: proc(backend: ^Platform_Backend) {
	linux.close(linux.Fd(backend.wake_fd))
	uring.destroy(&backend.ring)
	backend.unqueued_count = 0
}

@(private = "package")
_backend_submit :: proc(backend: ^Platform_Backend, submissions: []Submission) -> Backend_Error {
	for &sub in submissions {
		if !_linux_submit_one(backend, &sub) {
			if backend.unqueued_count >= MAX_LINUX_UNQUEUED {
				return .Queue_Full
			}
			backend.unqueued[backend.unqueued_count] = sub
			backend.unqueued_count += 1
		}
	}

	// Flush SQEs to kernel
	_, err := uring.submit(&backend.ring, 0, nil)
	if err != nil && err != .NONE {
		return .System_Error
	}

	return .None
}

@(private = "package")
_backend_collect :: proc(
	backend: ^Platform_Backend,
	completions: []Raw_Completion,
	timeout_ns: i64,
) -> (u32, Backend_Error) {
	// Flush any overflow submissions first
	_linux_flush_unqueued(backend)

	// Submit and optionally wait
	wait_nr: u32 = 0
	ts: linux.Time_Spec
	ts_ptr: ^linux.Time_Spec = nil

	if timeout_ns > 0 {
		wait_nr = 1
		NANOSECONDS_PER_SECOND :: 1_000_000_000
		ts.time_sec = uint(timeout_ns / NANOSECONDS_PER_SECOND)
		ts.time_nsec = uint(timeout_ns % NANOSECONDS_PER_SECOND)
		ts_ptr = &ts
	} else if timeout_ns < 0 {
		// Negative = block indefinitely until at least one CQE
		wait_nr = 1
	}

	_, submit_err := uring.submit(&backend.ring, wait_nr, ts_ptr)
	if submit_err != nil && submit_err != .NONE && submit_err != .ETIME && submit_err != .EINTR {
		return 0, .System_Error
	}

	// Harvest CQEs
	max_cqes := u32(len(completions))
	if max_cqes > 256 {
		max_cqes = 256
	}
	cqes: [256]linux.IO_Uring_CQE = ---
	completed, cqe_err := uring.copy_cqes(&backend.ring, cqes[:max_cqes], 0)
	if cqe_err != nil && cqe_err != .NONE && cqe_err != .EINTR {
		return 0, .System_Error
	}

	count: u32 = 0
	for i in 0 ..< completed {
		cqe := &cqes[i]
		token := Submission_Token(cqe.user_data)
		comp := &completions[count]
		comp.token = token
		comp.result = cqe.res
		comp.extra = nil

		// Check for accept completion (res >= 0 means new FD)
		op_tag := submission_token_operation_tag(token)
		if op_tag == u8(IO_TAG_ACCEPT_COMPLETE) && cqe.res >= 0 {
			entry := _linux_find_addr_entry(backend, token)
			if entry != nil {
				comp.extra = Completion_Extra_Accept{
					client_fd      = OS_FD(cqe.res),
					client_address = _linux_sockaddr_to_socket_address(&entry.sockaddr),
				}
				entry.active = false
			} else {
				comp.extra = Completion_Extra_Accept{
					client_fd = OS_FD(cqe.res),
				}
			}
		} else if op_tag == u8(IO_TAG_RECVFROM_COMPLETE) && cqe.res >= 0 {
			entry := _linux_find_addr_entry(backend, token)
			if entry != nil {
				comp.extra = Completion_Extra_Recvfrom{
					peer_address = _linux_sockaddr_to_socket_address(&entry.sockaddr),
				}
				entry.active = false
			}
		} else {
			// Free addr entry for connect/sendto completions
			entry := _linux_find_addr_entry(backend, token)
			if entry != nil {
				entry.active = false
			}
		}

		count += 1
	}

	return count, .None
}

@(private = "package")
_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
	// Use a distinct cancel user_data (token with high bit flipped)
	cancel_ud := u64(token) ~ (1 << 63)
	_, ok := uring.async_cancel(&backend.ring, u64(token), cancel_ud)
	if !ok {
		return .Queue_Full
	}

	_, err := uring.submit(&backend.ring, 0, nil)
	if err != nil && err != .NONE {
		return .System_Error
	}

	return .None
}

@(private = "package")
_backend_wake :: proc(backend: ^Platform_Backend) {
	one: u64 = 1
	linux.write(linux.Fd(backend.wake_fd), ([^]u8)(&one)[:size_of(one)])
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
) -> (OS_FD, Backend_Error) {
	af: linux.Address_Family
	switch domain {
	case .AF_INET:  af = .INET
	case .AF_INET6: af = .INET6
	case .AF_UNIX:  af = .UNIX
	}

	st: linux.Socket_Type
	switch socket_type {
	case .STREAM: st = .STREAM
	case .DGRAM:  st = .DGRAM
	}
	st += {.NONBLOCK, .CLOEXEC}

	proto: linux.Socket_Protocol
	switch protocol {
	case .DEFAULT: proto = {}
	case .TCP:     proto = .TCP
	case .UDP:     proto = .UDP
	}

	fd, err := linux.socket(af, st, proto)
	if err != nil {
		return OS_FD_INVALID, .System_Error
	}
	return OS_FD(fd), .None
}

@(private = "package")
_backend_control_bind :: proc(backend: ^Platform_Backend, fd: OS_FD, address: Socket_Address) -> Backend_Error {
	sockaddr := _linux_socket_address_to_sockaddr(address)
	addr_len := _linux_sockaddr_len(address)

	err := linux.bind(linux.Fd(fd), &sockaddr, addr_len)
	if err != nil {
		return .System_Error
	}
	return .None
}

@(private = "package")
_backend_control_listen :: proc(backend: ^Platform_Backend, fd: OS_FD, backlog: u32) -> Backend_Error {
	err := linux.listen(linux.Fd(fd), i32(backlog))
	if err != nil {
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
	sol: i32
	switch level {
	case .SOL_SOCKET:   sol = 1   // SOL_SOCKET
	case .IPPROTO_TCP:  sol = 6   // IPPROTO_TCP
	case .IPPROTO_UDP:  sol = 17  // IPPROTO_UDP
	case .IPPROTO_IPV6: sol = 41  // IPPROTO_IPV6
	}

	opt: i32
	switch option {
	case .SO_REUSEADDR:    opt = 2    // SO_REUSEADDR
	case .SO_REUSEPORT:    opt = 15   // SO_REUSEPORT
	case .SO_KEEPALIVE:    opt = 9    // SO_KEEPALIVE
	case .SO_RCVBUF:       opt = 8    // SO_RCVBUF
	case .SO_SNDBUF:       opt = 7    // SO_SNDBUF
	case .SO_LINGER:       opt = 13   // SO_LINGER
	case .SO_BINDTODEVICE: opt = 25   // SO_BINDTODEVICE
	case .TCP_NODELAY:     opt = 1    // TCP_NODELAY
	case .TCP_CORK:        opt = 3    // TCP_CORK
	case .TCP_NOPUSH:      opt = 3    // TCP_NOPUSH (alias for CORK on Linux)
	case .TCP_KEEPIDLE:    opt = 4    // TCP_KEEPIDLE
	case .TCP_KEEPINTVL:   opt = 5    // TCP_KEEPINTVL
	case .TCP_KEEPCNT:     opt = 6    // TCP_KEEPCNT
	case .IPV6_V6ONLY:     opt = 26   // IPV6_V6ONLY
	}

	int_val: i32
	switch v in value {
	case bool: int_val = 1 if v else 0
	case i32:  int_val = v
	}

	err := linux.setsockopt(linux.Fd(fd), sol, opt, &int_val, size_of(int_val))
	if err != nil {
		return .System_Error
	}
	return .None
}

@(private = "package")
_backend_control_shutdown :: proc(backend: ^Platform_Backend, fd: OS_FD, how: Shutdown_How) -> Backend_Error {
	sh: linux.Shut_How
	switch how {
	case .SHUT_READER: sh = .RD
	case .SHUT_WRITER: sh = .WR
	case .SHUT_BOTH:   sh = .RDWR
	}

	err := linux.shutdown(linux.Fd(fd), sh)
	if err != nil {
		return .System_Error
	}
	return .None
}

@(private = "package")
_backend_control_close :: proc(backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
	err := linux.close(linux.Fd(fd))
	if err != nil {
		return .System_Error
	}
	return .None
}

// ============================================================================
// Internal Helpers
// ============================================================================

// Submit a single operation to the uring. Returns true if enqueued, false if ring full.
@(private = "file")
_linux_submit_one :: proc(backend: ^Platform_Backend, sub: ^Submission) -> bool {
	ud := u64(sub.token)

	switch op in sub.operation {
	case Submission_Op_Read:
		_, ok := uring.read(
			&backend.ring, ud,
			linux.Fd(op.fd), op.buffer[:op.size], i64(op.offset),
		)
		return ok

	case Submission_Op_Write:
		_, ok := uring.write(
			&backend.ring, ud,
			linux.Fd(op.fd), op.buffer[:op.size], i64(op.offset),
		)
		return ok

	case Submission_Op_Accept:
		entry := _linux_alloc_addr_entry(backend, sub.token)
		if entry != nil {
			entry.sockaddr_len = size_of(entry.sockaddr)
			_, ok := uring.accept(
				&backend.ring, ud,
				linux.Fd(op.listen_fd),
				&entry.sockaddr, &entry.sockaddr_len, {},
			)
			if !ok {
				entry.active = false
			}
			return ok
		}
		// No addr slot available, accept without sockaddr
		_, ok := uring.accept(
			&backend.ring, ud,
			linux.Fd(op.listen_fd), nil, nil, {},
		)
		return ok

	case Submission_Op_Connect:
		entry := _linux_alloc_addr_entry(backend, sub.token)
		if entry != nil {
			entry.sockaddr = _linux_socket_address_to_sockaddr(op.address)
			_, ok := uring.connect(
				&backend.ring, ud,
				linux.Fd(op.socket_fd), &entry.sockaddr,
			)
			if !ok {
				entry.active = false
			}
			return ok
		}
		return false // connect requires persistent sockaddr

	case Submission_Op_Close:
		_, ok := uring.close(&backend.ring, ud, linux.Fd(op.fd))
		return ok

	case Submission_Op_Send:
		_, ok := uring.send(
			&backend.ring, ud,
			linux.Fd(op.socket_fd), op.buffer[:op.size], {.NOSIGNAL},
		)
		return ok

	case Submission_Op_Recv:
		_, ok := uring.recv(
			&backend.ring, ud,
			linux.Fd(op.socket_fd), op.buffer[:op.size], {.NOSIGNAL},
		)
		return ok

	case Submission_Op_Sendto:
		entry := _linux_alloc_addr_entry(backend, sub.token)
		if entry == nil {
			return false
		}
		entry.sockaddr = _linux_socket_address_to_sockaddr(op.address)
		entry.iovec = linux.IO_Vec{
			base = op.buffer,
			len  = uint(op.size),
		}
		entry.msghdr = linux.Msg_Hdr{
			name    = &entry.sockaddr,
			namelen = _linux_sockaddr_len(op.address),
			iov     = (&entry.iovec)[:1],
		}
		_, ok := uring.sendmsg(
			&backend.ring, ud,
			linux.Fd(op.socket_fd), &entry.msghdr, {.NOSIGNAL},
		)
		if !ok {
			entry.active = false
		}
		return ok

	case Submission_Op_Recvfrom:
		entry := _linux_alloc_addr_entry(backend, sub.token)
		if entry == nil {
			return false
		}
		entry.sockaddr_len = size_of(entry.sockaddr)
		entry.iovec = linux.IO_Vec{
			base = op.buffer,
			len  = uint(op.size),
		}
		entry.msghdr = linux.Msg_Hdr{
			name    = &entry.sockaddr,
			namelen = size_of(entry.sockaddr),
			iov     = (&entry.iovec)[:1],
		}
		_, ok := uring.recvmsg(
			&backend.ring, ud,
			linux.Fd(op.socket_fd), &entry.msghdr, {.NOSIGNAL},
		)
		if !ok {
			entry.active = false
		}
		return ok
	}

	return false
}

// Flush buffered unqueued submissions into the ring.
@(private = "file")
_linux_flush_unqueued :: proc(backend: ^Platform_Backend) {
	if backend.unqueued_count == 0 {
		return
	}

	remaining: u16 = 0
	for i in 0 ..< backend.unqueued_count {
		if _linux_submit_one(backend, &backend.unqueued[i]) {
			continue
		}
		// Still can't enqueue — keep in overflow
		if remaining != i {
			backend.unqueued[remaining] = backend.unqueued[i]
		}
		remaining += 1
	}
	backend.unqueued_count = remaining

	if remaining == 0 {
		uring.submit(&backend.ring, 0, nil)
	}
}

// Allocate a persistent addr entry. Returns nil if full.
@(private = "file")
_linux_alloc_addr_entry :: proc(backend: ^Platform_Backend, token: Submission_Token) -> ^Pending_Addr_Entry {
	for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
		if !backend.addr_entries[i].active {
			entry := &backend.addr_entries[i]
			entry.active = true
			entry.token = token
			entry.sockaddr = {}
			entry.sockaddr_len = 0
			entry.msghdr = {}
			entry.iovec = {}
			return entry
		}
	}
	return nil
}

// Find addr entry by token. Returns nil if not found.
@(private = "file")
_linux_find_addr_entry :: proc(backend: ^Platform_Backend, token: Submission_Token) -> ^Pending_Addr_Entry {
	for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
		if backend.addr_entries[i].active && backend.addr_entries[i].token == token {
			return &backend.addr_entries[i]
		}
	}
	return nil
}

// Convert linux.Sock_Addr_Any → Socket_Address
@(private = "file")
_linux_sockaddr_to_socket_address :: proc(addr: ^linux.Sock_Addr_Any) -> Socket_Address {
	#partial switch addr.family {
	case .INET:
		return Socket_Address_Inet4{
			address = addr.sin_addr,
			port    = u16(addr.sin_port),
		}
	case .INET6:
		return Socket_Address_Inet6{
			address = transmute([16]u8)addr.sin6_addr,
			port    = u16(addr.sin6_port),
			flow    = addr.sin6_flowinfo,
			scope   = addr.sin6_scope_id,
		}
	}
	return nil
}

// Convert Socket_Address → linux.Sock_Addr_Any
@(private = "file")
_linux_socket_address_to_sockaddr :: proc(address: Socket_Address) -> linux.Sock_Addr_Any {
	sa: linux.Sock_Addr_Any
	switch addr in address {
	case Socket_Address_Inet4:
		sa.sin_family = .INET
		sa.sin_port   = u16be(addr.port)
		sa.sin_addr   = addr.address
	case Socket_Address_Inet6:
		sa.sin6_family   = .INET6
		sa.sin6_port     = u16be(addr.port)
		sa.sin6_addr     = transmute([16]u8)addr.address
		sa.sin6_flowinfo = addr.flow
		sa.sin6_scope_id = addr.scope
	case Socket_Address_Unix:
		sa.sun_family = .UNIX
		sa.sun_path   = addr.path
	}
	return sa
}

// Return the sockaddr length for bind/connect syscalls.
@(private = "file")
_linux_sockaddr_len :: proc(address: Socket_Address) -> i32 {
	switch _ in address {
	case Socket_Address_Inet4:
		return size_of(linux.Sock_Addr_In)
	case Socket_Address_Inet6:
		return size_of(linux.Sock_Addr_In6)
	case Socket_Address_Unix:
		return size_of(linux.Sock_Addr_Un)
	}
	return size_of(linux.Sock_Addr_Any)
}

} // when !TINA_SIM
