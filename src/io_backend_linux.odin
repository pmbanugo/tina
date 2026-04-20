#+build linux
#+private
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

import "core:fmt"
import "core:sys/linux"
import "core:sys/linux/uring"
import "core:testing"

when !TINA_SIMULATION_MODE {

	MAX_LINUX_UNQUEUED :: 256
	MAX_LINUX_PENDING_ADDRS :: 64
	MAX_LINUX_SENDFILE_ENTRIES :: 16

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

	// io_uring splice state machine for zero-copy file→socket transfer.
	// Two-phase: (1) file→pipe via IORING_OP_SPLICE, (2) pipe→socket via IORING_OP_SPLICE.
	// One dedicated pipe pair per entry, pre-created at init.
	// Internal SQEs use high-bit-tagged user_data (filtered from user completions).
	Sendfile_Phase :: enum u8 {
		File_To_Pipe,
		Pipe_To_Socket,
	}

	Sendfile_Entry :: struct {
		token:             Submission_Token,
		fd_file:           OS_FD,
		fd_socket:         OS_FD,
		socket_fixed_index: u16,
		pipe_read_fd:      linux.Fd,
		pipe_write_fd:     linux.Fd,
		source_offset:     u64,
		size_remaining:    u32,
		bytes_in_pipe:     u32,
		bytes_sent_total:  u32,
		phase:             Sendfile_Phase,
		active:            bool,
	}

	// Internal user_data encoding for sendfile splice SQEs.
	// High bit set = internal (filtered by CQE loop). Bits 0..3 = entry index. Bit 4 = phase.
	SENDFILE_UD_FLAG :: u64(0x8000_0000_0000_0002) // high bit + bit 1 to distinguish from wake/cancel
	SENDFILE_UD_PHASE_BIT :: u64(1 << 4)

	_Platform_State :: struct {
		ring:               uring.Ring,
		wake_fd:            OS_FD,
		wake_buffer:        u64,
		unqueued:           [MAX_LINUX_UNQUEUED]Submission,
		unqueued_count:     u16,
		buffers_registered: bool,
		files_registered:   bool,
		fixed_fd_count:     u16,
		addr_entries:       [MAX_LINUX_PENDING_ADDRS]Pending_Addr_Entry,
		sendfile_entries:   [MAX_LINUX_SENDFILE_ENTRIES]Sendfile_Entry,
	}

	// Internal user_data for wake eventfd reads. High bit marks it as internal (filtered from user completions).
	LINUX_WAKE_UD :: u64(0x8000_0000_0000_0001)

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
		backend.buffers_registered = false

		for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
			backend.addr_entries[i].active = false
		}

		// Pre-create pipe pairs for sendfile splice state machine.
		// Each entry gets a dedicated pipe so concurrent sendfile ops never mix data.
		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			backend.sendfile_entries[i].active = false
			pipes: [2]linux.Fd
			pipe_err := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
			if pipe_err != nil {
				// Clean up already-created pipes and fail init
				for j in 0 ..< i {
					linux.close(backend.sendfile_entries[j].pipe_read_fd)
					linux.close(backend.sendfile_entries[j].pipe_write_fd)
				}
				linux.close(linux.Fd(backend.wake_fd))
				uring.destroy(&backend.ring)
				return .System_Error
			}
			backend.sendfile_entries[i].pipe_read_fd = pipes[0]
			backend.sendfile_entries[i].pipe_write_fd = pipes[1]
		}

		_linux_arm_wake(backend)

		// Registered buffers (§6.6.2 §8): register buffer pool memory with io_uring.
		// This eliminates get_user_pages per-operation cost for pre-allocated pool buffers.
		// The reactor's buffer pool is pre-allocated at Shard init and stable for the
		// Shard's lifetime, making it an ideal fit for kernel page-pinning.
		if config.buffer_base != nil && config.buffer_slot_count > 0 {
			backend.buffers_registered = _linux_register_buffers(
				backend,
				config.buffer_base,
				config.buffer_slot_size,
				config.buffer_slot_count,
			)
			if !backend.buffers_registered {
				fmt.eprintfln(
					"[WARN] io_uring buffer registration failed for %d slots. Falling back to standard READ/WRITE ops.",
					config.buffer_slot_count,
				)
			}
		}

		// register a sparse fixed-file table with io_uring.
		if config.fd_slot_count > 0 {
			backend.files_registered = _linux_register_fixed_files(backend, config.fd_slot_count)
			if !backend.files_registered {
				fmt.eprintfln(
					"[WARN] io_uring fixed file registration failed for %d slots. Falling back to standard FD ops.",
					config.fd_slot_count,
				)
			} else {
				backend.fixed_fd_count = config.fd_slot_count
			}
		}

		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		if backend.files_registered {
			linux.io_uring_register(backend.ring.fd, .UNREGISTER_FILES, nil, 0)
			backend.files_registered = false
		}
		if backend.buffers_registered {
			linux.io_uring_register(backend.ring.fd, .UNREGISTER_BUFFERS, nil, 0)
			backend.buffers_registered = false
		}
		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			linux.close(backend.sendfile_entries[i].pipe_read_fd)
			linux.close(backend.sendfile_entries[i].pipe_write_fd)
			backend.sendfile_entries[i].active = false
		}
		linux.close(linux.Fd(backend.wake_fd))
		uring.destroy(&backend.ring)
		backend.unqueued_count = 0
	}

	@(private = "package")
	_backend_submit :: proc(
		backend: ^Platform_Backend,
		submissions: []Submission,
	) -> Backend_Error {
		// All-or-error: pre-check worst-case capacity.
		// In the worst case, every submission overflows to unqueued.
		if int(backend.unqueued_count) + len(submissions) > MAX_LINUX_UNQUEUED {
			return .Queue_Full
		}

		for &submission in submissions {
			if !_linux_submit_one(backend, &submission) {
				backend.unqueued[backend.unqueued_count] = submission
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
	) -> (
		u32,
		Backend_Error,
	) {
		// Flush any overflow submissions first
		_linux_flush_unqueued(backend)

		// Submit and optionally wait
		wait_number: u32 = 0
		time_spec: linux.Time_Spec
		time_spec_pointer: ^linux.Time_Spec = nil

		if timeout_ns > 0 {
			wait_number = 1
			NANOSECONDS_PER_SECOND :: 1_000_000_000
			time_spec.time_sec = uint(timeout_ns / NANOSECONDS_PER_SECOND)
			time_spec.time_nsec = uint(timeout_ns % NANOSECONDS_PER_SECOND)
			time_spec_pointer = &time_spec
		} else if timeout_ns < 0 {
			// Negative = block indefinitely until at least one CQE
			wait_number = 1
		}

		_, submit_err := uring.submit(&backend.ring, wait_number, time_spec_pointer)
		if submit_err != nil &&
		   submit_err != .NONE &&
		   submit_err != .ETIME &&
		   submit_err != .EINTR {
			return 0, .System_Error
		}

		// Harvest CQEs
		cqes_max := u32(len(completions))
		if cqes_max > 256 {
			cqes_max = 256
		}
		cqes: [256]linux.IO_Uring_CQE = ---
		completed, cqe_err := uring.copy_cqes(&backend.ring, cqes[:cqes_max], 0)
		if cqe_err != nil && cqe_err != .NONE && cqe_err != .EINTR {
			return 0, .System_Error
		}

		count: u32 = 0
		for i in 0 ..< completed {
			cqe := &cqes[i]

			// Filter internal CQEs: cancel results (high bit set), wake reads, and sendfile splices
			if cqe.user_data & (1 << 63) != 0 {
				if cqe.user_data == LINUX_WAKE_UD {
					_linux_arm_wake(backend)
				} else if (cqe.user_data & SENDFILE_UD_FLAG) == SENDFILE_UD_FLAG {
					// Internal sendfile splice CQE — advance the state machine.
					// May produce a user-visible completion pushed to the output slice.
					_linux_handle_sendfile_cqe(backend, cqe, completions, &count, u32(len(completions)))
				}
				continue
			}

			token := Submission_Token(cqe.user_data)
			completion := &completions[count]
			completion.token = token
			completion.result = cqe.res
			completion.extra = nil

			// Check for accept completion (res >= 0 means new FD)
			op_tag := submission_token_operation_tag(token)
			if op_tag == u8(IO_TAG_ACCEPT_COMPLETE) && cqe.res >= 0 {
				entry := _linux_find_addr_entry(backend, token)
				if entry != nil {
					completion.extra = Completion_Extra_Accept {
						client_fd      = OS_FD(cqe.res),
						client_address = _linux_sockaddr_to_socket_address(&entry.sockaddr),
					}
					entry.active = false
				} else {
					completion.extra = Completion_Extra_Accept {
						client_fd = OS_FD(cqe.res),
					}
				}
			} else if op_tag == u8(IO_TAG_RECVFROM_COMPLETE) && cqe.res >= 0 {
				entry := _linux_find_addr_entry(backend, token)
				if entry != nil {
					completion.extra = Completion_Extra_Recvfrom {
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

		cancelled_any := false
		is_sendfile := false

		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			if backend.sendfile_entries[i].active && backend.sendfile_entries[i].token == token {
				is_sendfile = true

				ud_fp := _linux_sendfile_ud(u64(i), .File_To_Pipe)
				ud_ps := _linux_sendfile_ud(u64(i), .Pipe_To_Socket)

				_, ok1 := uring.async_cancel(&backend.ring, ud_fp, cancel_ud)
				_, ok2 := uring.async_cancel(&backend.ring, ud_ps, cancel_ud)

				cancelled_any = cancelled_any || ok1 || ok2
				break
			}
		}

		if !is_sendfile {
			_, ok := uring.async_cancel(&backend.ring, u64(token), cancel_ud)
			cancelled_any = cancelled_any || ok
		}

		if !cancelled_any {
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
	) -> (
		OS_FD,
		Backend_Error,
	) {
		af: linux.Address_Family
		switch domain {
		case .AF_INET:
			af = .INET
		case .AF_INET6:
			af = .INET6
		case .AF_UNIX:
			af = .UNIX
		}

		st: linux.Socket_Type
		switch socket_type {
		case .STREAM:
			st = .STREAM
		case .DGRAM:
			st = .DGRAM
		}
		sf: linux.Socket_FD_Flags = {.NONBLOCK, .CLOEXEC}

		proto: linux.Protocol
		switch protocol {
		case .DEFAULT:
			proto = {}
		case .TCP:
			proto = .TCP
		case .UDP:
			proto = .UDP
		}

		fd, err := linux.socket(af, st, sf, proto)
		if err != nil {
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
		sockaddr := _linux_socket_address_to_sockaddr(address)
		addr_len := _linux_sockaddr_len(address)

		err := linux.bind(linux.Fd(fd), &sockaddr)
		if err != nil {
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
		case .SOL_SOCKET:
			sol = 1 // SOL_SOCKET
		case .IPPROTO_TCP:
			sol = 6 // IPPROTO_TCP
		case .IPPROTO_UDP:
			sol = 17 // IPPROTO_UDP
		case .IPPROTO_IPV6:
			sol = 41 // IPPROTO_IPV6
		}

		opt: i32
		switch option {
		case .SO_REUSEADDR:
			opt = 2 // SO_REUSEADDR
		case .SO_REUSEPORT:
			opt = 15 // SO_REUSEPORT
		case .SO_KEEPALIVE:
			opt = 9 // SO_KEEPALIVE
		case .SO_RCVBUF:
			opt = 8 // SO_RCVBUF
		case .SO_SNDBUF:
			opt = 7 // SO_SNDBUF
		case .SO_LINGER:
			opt = 13 // SO_LINGER
		case .SO_BINDTODEVICE:
			opt = 25 // SO_BINDTODEVICE
		case .TCP_NODELAY:
			opt = 1 // TCP_NODELAY
		case .TCP_CORK:
			opt = 3 // TCP_CORK
		case .TCP_NOPUSH:
			opt = 3 // TCP_NOPUSH (alias for CORK on Linux)
		case .TCP_KEEPIDLE:
			opt = 4 // TCP_KEEPIDLE
		case .TCP_KEEPINTVL:
			opt = 5 // TCP_KEEPINTVL
		case .TCP_KEEPCNT:
			opt = 6 // TCP_KEEPCNT
		case .IPV6_V6ONLY:
			opt = 26 // IPV6_V6ONLY
		}

		switch v in value {
		case bool:
			int_val: i32 = 1 if v else 0
			err := linux.setsockopt_base(linux.Fd(fd), int(sol), int(opt), &int_val)
			if err != nil do return .System_Error
		case i32:
			int_val := v
			err := linux.setsockopt_base(linux.Fd(fd), int(sol), int(opt), &int_val)
			if err != nil do return .System_Error
		case Socket_Linger:
			lin := v
			err := linux.setsockopt_base(linux.Fd(fd), int(sol), int(opt), &lin)
			if err != nil do return .System_Error
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
		sol: i32
		switch level {
		case .SOL_SOCKET:
			sol = 1 // SOL_SOCKET
		case .IPPROTO_TCP:
			sol = 6 // IPPROTO_TCP
		case .IPPROTO_UDP:
			sol = 17 // IPPROTO_UDP
		case .IPPROTO_IPV6:
			sol = 41 // IPPROTO_IPV6
		}

		opt: i32
		switch option {
		case .SO_REUSEADDR:
			opt = 2 // SO_REUSEADDR
		case .SO_REUSEPORT:
			opt = 15 // SO_REUSEPORT
		case .SO_KEEPALIVE:
			opt = 9 // SO_KEEPALIVE
		case .SO_RCVBUF:
			opt = 8 // SO_RCVBUF
		case .SO_SNDBUF:
			opt = 7 // SO_SNDBUF
		case .SO_LINGER:
			opt = 13 // SO_LINGER
		case .SO_BINDTODEVICE:
			opt = 25 // SO_BINDTODEVICE
		case .TCP_NODELAY:
			opt = 1 // TCP_NODELAY
		case .TCP_CORK:
			opt = 3 // TCP_CORK
		case .TCP_NOPUSH:
			opt = 3 // TCP_NOPUSH (alias for CORK on Linux)
		case .TCP_KEEPIDLE:
			opt = 4 // TCP_KEEPIDLE
		case .TCP_KEEPINTVL:
			opt = 5 // TCP_KEEPINTVL
		case .TCP_KEEPCNT:
			opt = 6 // TCP_KEEPCNT
		case .IPV6_V6ONLY:
			opt = 26 // IPV6_V6ONLY
		}

		// SO_LINGER requires an 8-byte struct; route it separately to avoid stack overflow
		if option == .SO_LINGER {
			lin: Socket_Linger
			_, err := linux.getsockopt_base(linux.Fd(fd), int(sol), linux.Socket_Option(opt), &lin)
			if err != nil do return nil, .System_Error
			return lin, .None
		}

		val: i32
		_, err := linux.getsockopt_base(linux.Fd(fd), int(sol), linux.Socket_Option(opt), &val)
		if err != nil {
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
		shutdown_how: linux.Shutdown_How
		switch how {
		case .SHUT_READER:
			shutdown_how = .RD
		case .SHUT_WRITER:
			shutdown_how = .WR
		case .SHUT_BOTH:
			shutdown_how = .RDWR
		}

		err := linux.shutdown(linux.Fd(fd), shutdown_how)
		if err != nil {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc "contextless" (
		backend: ^Platform_Backend,
		fd: OS_FD,
	) -> Backend_Error {
		err := linux.close(linux.Fd(fd))
		if err != nil {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_dup :: proc "contextless" (
		backend: ^Platform_Backend,
		fd: OS_FD,
	) -> (
		OS_FD,
		Backend_Error,
	) {
		dup_fd, err := linux.fcntl_dupfd_cloexec(linux.Fd(fd), .DUPFD_CLOEXEC, 0)
		if err != nil {
			return OS_FD_INVALID, .System_Error
		}
		return OS_FD(dup_fd), .None
	}

	// ============================================================================
	// Internal Helpers
	// ============================================================================

	// Submit a single operation to the uring. Returns true if enqueued, false if ring full.
	@(private = "file")
	_linux_submit_one :: proc(backend: ^Platform_Backend, submission: ^Submission) -> bool {
		ud := u64(submission.token)
		ffi := submission.fixed_file_index
		use_fixed := backend.files_registered && ffi != FIXED_FILE_INDEX_NONE

		switch op in submission.operation {
		case Submission_Op_Read:
			buffer_index := submission_token_buffer_index(submission.token)

			// When the buffer belongs to the registered pool, use READ_FIXED to
			// bypass the kernel's per-operation get_user_pages cost (§6.6.2 §8).
			if backend.buffers_registered && buffer_index != BUFFER_INDEX_NONE {
				return _linux_submit_read_fixed(backend, ud, op, buffer_index, use_fixed, ffi)
			}
			sqe, ok := uring.read(
				&backend.ring,
				ud,
				linux.Fd(op.fd),
				op.buffer[:op.size],
				u64(op.offset),
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Write:
			buffer_index := submission_token_buffer_index(submission.token)

			if backend.buffers_registered && buffer_index != BUFFER_INDEX_NONE {
				return _linux_submit_write_fixed(backend, ud, op, buffer_index, use_fixed, ffi)
			}
			sqe, ok := uring.write(
				&backend.ring,
				ud,
				linux.Fd(op.fd),
				op.buffer[:op.size],
				u64(op.offset),
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Accept:
			entry := _linux_alloc_addr_entry(backend, submission.token)
			if entry != nil {
				entry.sockaddr_len = size_of(entry.sockaddr)
				sqe, ok := uring.accept(
					&backend.ring,
					ud,
					linux.Fd(op.listen_fd),
					&entry.sockaddr,
					&entry.sockaddr_len,
					linux.Socket_FD_Flags{},
				)
				if !ok {
					entry.active = false
				}
				if ok && use_fixed {
					_linux_apply_fixed_file(sqe, ffi)
				}
				return ok
			}
			// No addr slot available, accept without sockaddr
			sqe, ok := uring.accept(
				&backend.ring,
				ud,
				linux.Fd(op.listen_fd),
				(^linux.Sock_Addr_Any)(nil),
				nil,
				linux.Socket_FD_Flags{},
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Connect:
			entry := _linux_alloc_addr_entry(backend, submission.token)
			if entry != nil {
				entry.sockaddr = _linux_socket_address_to_sockaddr(op.address)
				sqe, ok := uring.connect(
					&backend.ring,
					ud,
					linux.Fd(op.fd_socket),
					&entry.sockaddr,
				)
				if !ok {
					entry.active = false
				}
				if ok && use_fixed {
					_linux_apply_fixed_file(sqe, ffi)
				}
				return ok
			}
			return false // connect requires persistent sockaddr

		case Submission_Op_Close:
			_, ok := uring.close(&backend.ring, ud, linux.Fd(op.fd))
			return ok

		case Submission_Op_Send:
			sqe, ok := uring.send(
				&backend.ring,
				ud,
				linux.Fd(op.fd_socket),
				op.buffer[:op.size],
				{.NOSIGNAL},
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Recv:
			sqe, ok := uring.recv(
				&backend.ring,
				ud,
				linux.Fd(op.fd_socket),
				op.buffer[:op.size],
				{.NOSIGNAL},
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Sendto:
			entry := _linux_alloc_addr_entry(backend, submission.token)
			if entry == nil {
				return false
			}
			entry.sockaddr = _linux_socket_address_to_sockaddr(op.address)
			entry.iovec = linux.IO_Vec {
				base = op.buffer,
				len  = uint(op.size),
			}
			entry.msghdr = linux.Msg_Hdr {
				name    = &entry.sockaddr,
				namelen = _linux_sockaddr_len(op.address),
				iov     = ([^]linux.IO_Vec)(&entry.iovec)[:1],
			}
			sqe, ok := uring.sendmsg(
				&backend.ring,
				ud,
				linux.Fd(op.fd_socket),
				&entry.msghdr,
				{.NOSIGNAL},
			)
			if !ok {
				entry.active = false
			}
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Recvfrom:
			entry := _linux_alloc_addr_entry(backend, submission.token)
			if entry == nil {
				return false
			}
			entry.sockaddr_len = size_of(entry.sockaddr)
			entry.iovec = linux.IO_Vec {
				base = op.buffer,
				len  = uint(op.size),
			}
			entry.msghdr = linux.Msg_Hdr {
				name    = &entry.sockaddr,
				namelen = size_of(entry.sockaddr),
				iov     = ([^]linux.IO_Vec)(&entry.iovec)[:1],
			}
			sqe, ok := uring.recvmsg(
				&backend.ring,
				ud,
				linux.Fd(op.fd_socket),
				&entry.msghdr,
				{.NOSIGNAL},
			)
			if !ok {
				entry.active = false
			}
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Sendfile:
			entry := _linux_alloc_sendfile_entry(backend)
			if entry == nil {
				return false
			}
			entry.token = submission.token
			entry.fd_file = op.fd_file
			entry.fd_socket = op.fd_socket
			entry.socket_fixed_index = submission.fixed_file_index
			entry.source_offset = op.source_offset
			entry.size_remaining = op.size
			entry.bytes_in_pipe = 0
			entry.bytes_sent_total = 0
			entry.phase = .File_To_Pipe
			entry.active = true

			return _linux_submit_splice_file_to_pipe(backend, entry)
		}

		return false
	}

	// ============================================================================
	// Sendfile Splice State Machine
	// ============================================================================

	@(private = "file")
	_linux_alloc_sendfile_entry :: proc(backend: ^Platform_Backend) -> ^Sendfile_Entry {
		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			if !backend.sendfile_entries[i].active {
				return &backend.sendfile_entries[i]
			}
		}
		return nil
	}

	@(private = "file")
	_linux_sendfile_entry_index :: proc(backend: ^Platform_Backend, entry: ^Sendfile_Entry) -> u64 {
		base := uintptr(&backend.sendfile_entries[0])
		return u64(uintptr(entry) - base) / u64(size_of(Sendfile_Entry))
	}

	// Encode internal user_data for a sendfile splice SQE.
	// High bit set = internal. Bit 1 = sendfile marker. Bits 8..11 = entry index. Bit 4 = phase.
	@(private = "file")
	_linux_sendfile_ud :: proc(entry_index: u64, phase: Sendfile_Phase) -> u64 {
		ud := SENDFILE_UD_FLAG | (entry_index << 8)
		if phase == .Pipe_To_Socket {
			ud |= SENDFILE_UD_PHASE_BIT
		}
		return ud
	}

	// Decode entry index and phase from internal user_data.
	@(private = "file")
	_linux_sendfile_ud_decode :: proc(ud: u64) -> (entry_index: u16, phase: Sendfile_Phase) {
		entry_index = u16((ud >> 8) & 0xF)
		phase = .Pipe_To_Socket if (ud & SENDFILE_UD_PHASE_BIT) != 0 else .File_To_Pipe
		return
	}

	// Phase 1: splice file → pipe. Reads from file at source_offset into the pipe write end.
	@(private = "file")
	_linux_submit_splice_file_to_pipe :: proc(backend: ^Platform_Backend, entry: ^Sendfile_Entry) -> bool {
		idx := _linux_sendfile_entry_index(backend, entry)
		ud := _linux_sendfile_ud(idx, .File_To_Pipe)
		chunk := min(entry.size_remaining, 1024 * 1024) // 1MB max per splice to keep granularity

		_, ok := uring.splice(
			&backend.ring,
			ud,
			linux.Fd(entry.fd_file),       // fd_in = file
			i64(entry.source_offset),       // off_in = file offset
			entry.pipe_write_fd,            // fd_out = pipe write end
			-1,                             // off_out = -1 (NULL, pipe has no offset)
			chunk,
			{.NONBLOCK, .MORE},
		)
		return ok
	}

	// Phase 2: splice pipe → socket. Drains pipe contents into the destination socket.
	@(private = "file")
	_linux_submit_splice_pipe_to_socket :: proc(backend: ^Platform_Backend, entry: ^Sendfile_Entry) -> bool {
		idx := _linux_sendfile_entry_index(backend, entry)
		ud := _linux_sendfile_ud(idx, .Pipe_To_Socket)

		use_fixed := backend.files_registered && entry.socket_fixed_index != FIXED_FILE_INDEX_NONE
		splice_flags: linux.IO_Uring_Splice_Flags = {.NONBLOCK}
		if entry.size_remaining > 0 {
			splice_flags += {.MORE} // hint: more data coming after this
		}

		sqe, ok := uring.splice(
			&backend.ring,
			ud,
			entry.pipe_read_fd,            // fd_in = pipe read end
			-1,                            // off_in = -1 (NULL, pipe has no offset)
			linux.Fd(entry.fd_socket),     // fd_out = socket
			-1,                            // off_out = -1 (NULL for sockets)
			entry.bytes_in_pipe,
			splice_flags,
		)
		if ok && use_fixed {
			_linux_apply_fixed_file(sqe, entry.socket_fixed_index)
		}
		return ok
	}

	// Handle a CQE from an internal sendfile splice SQE.
	// Advances the state machine and may produce a user-visible completion.
	@(private = "file")
	_linux_handle_sendfile_cqe :: proc(
		backend: ^Platform_Backend,
		cqe: ^linux.IO_Uring_CQE,
		completions: []Raw_Completion,
		count: ^u32,
		output_max: u32,
	) {
		entry_index, phase := _linux_sendfile_ud_decode(cqe.user_data)
		if int(entry_index) >= MAX_LINUX_SENDFILE_ENTRIES {
			return
		}
		entry := &backend.sendfile_entries[entry_index]
		if !entry.active {
			return
		}

		// Error on any splice phase → complete with error (only if no bytes already sent to socket)
		if cqe.res < 0 {
			result: i32
			if entry.bytes_sent_total > 0 {
				// Partial progress already made — report bytes sent so far
				result = i32(entry.bytes_sent_total)
			} else {
				result = cqe.res
			}

			if entry.bytes_in_pipe > 0 {
				linux.close(entry.pipe_read_fd)
				linux.close(entry.pipe_write_fd)
				pipes: [2]linux.Fd
				linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
				entry.pipe_read_fd = pipes[0]
				entry.pipe_write_fd = pipes[1]
				entry.bytes_in_pipe = 0
			}

			_linux_complete_sendfile(entry, completions, count, output_max, result)
			return
		}

		bytes := u32(cqe.res)

		switch phase {
		case .File_To_Pipe:
			if bytes == 0 {
				// EOF — file shorter than expected at this offset
				if entry.bytes_in_pipe > 0 {
					// Drain remaining pipe contents to socket first
					entry.phase = .Pipe_To_Socket
					if !_linux_submit_splice_pipe_to_socket(backend, entry) {
						_linux_complete_sendfile(entry, completions, count, output_max, i32(entry.bytes_sent_total))
					}
				} else {
					_linux_complete_sendfile(entry, completions, count, output_max, i32(entry.bytes_sent_total))
				}
				return
			}

			entry.source_offset += u64(bytes)
			entry.size_remaining -= bytes
			entry.bytes_in_pipe += bytes

			// Now drain pipe → socket
			entry.phase = .Pipe_To_Socket
			if !_linux_submit_splice_pipe_to_socket(backend, entry) {
				_linux_complete_sendfile(entry, completions, count, output_max, i32(entry.bytes_sent_total))
			}

		case .Pipe_To_Socket:
			entry.bytes_in_pipe -= bytes
			entry.bytes_sent_total += bytes

			if entry.bytes_in_pipe > 0 {
				// Pipe not fully drained — keep draining before advancing
				if !_linux_submit_splice_pipe_to_socket(backend, entry) {
					_linux_complete_sendfile(entry, completions, count, output_max, i32(entry.bytes_sent_total))
				}
				return
			}

			// Pipe fully drained. More file data to transfer?
			if entry.size_remaining > 0 {
				entry.phase = .File_To_Pipe
				if !_linux_submit_splice_file_to_pipe(backend, entry) {
					_linux_complete_sendfile(entry, completions, count, output_max, i32(entry.bytes_sent_total))
				}
			} else {
				// All done — emit user completion
				_linux_complete_sendfile(entry, completions, count, output_max, i32(entry.bytes_sent_total))
			}
		}
	}

	// Emit the final user-visible completion for a sendfile operation and release the entry.
	@(private = "file")
	_linux_complete_sendfile :: proc(
		entry: ^Sendfile_Entry,
		completions: []Raw_Completion,
		count: ^u32,
		output_max: u32,
		result: i32,
	) {
		if count^ < output_max {
			completions[count^] = Raw_Completion {
				token  = entry.token,
				result = result,
				extra  = nil,
			}
			count^ += 1
		}
		entry.active = false
	}

	// Register the reactor's pre-allocated buffer pool with io_uring.
	// Builds a temporary iovec array on the stack, one entry per slot, and passes it
	// to the io_uring_register syscall. Returns true if registration succeeded.
	// On failure the backend falls back to standard READ/WRITE ops.
	@(private = "file")
	_linux_register_buffers :: proc(
		backend: ^Platform_Backend,
		buffer_base: [^]u8,
		buffer_slot_size: u32,
		buffer_slot_count: u16,
	) -> bool {
		// The iovec array is only needed for the duration of the register syscall.
		// Stack-allocate up to the maximum supported slot count (4094, from the
		// 12-bit buffer_index field in Submission_Token with 0x0FFF as NONE sentinel).
		iovecs: [4094]linux.IO_Vec = ---
		slot_size := int(buffer_slot_size)
		for i in 0 ..< int(buffer_slot_count) {
			iovecs[i] = linux.IO_Vec {
				base = buffer_base[i * slot_size:],
				len  = uint(buffer_slot_size),
			}
		}
		err := linux.io_uring_register(
			backend.ring.fd,
			.REGISTER_BUFFERS,
			&iovecs[0],
			u32(buffer_slot_count),
		)
		return err == .NONE
	}

	// Register a sparse fixed-file table with io_uring (§6.6.2 §8).
	// All slots initialized to -1 (empty). Updated incrementally via
	// _backend_register_fixed_fd / _backend_unregister_fixed_fd.
	@(private = "file")
	_linux_register_fixed_files :: proc(backend: ^Platform_Backend, fd_slot_count: u16) -> bool {
		fds: [65534]linux.Fd = ---
		for i in 0 ..< int(fd_slot_count) {
			fds[i] = linux.Fd(-1)
		}
		err := linux.io_uring_register(
			backend.ring.fd,
			.REGISTER_FILES,
			&fds[0],
			u32(fd_slot_count),
		)
		return err == .NONE
	}

	// Internal struct matching kernel's io_uring_rsrc_update for FILES_UPDATE.
	_IO_Uring_Files_Update :: struct {
		offset: u32,
		resv:   u32,
		data:   u64,
	}

	// Update a single slot in the kernel's fixed-file table.
	// Called by reactor on fd_table_alloc (new FD enters a slot).
	@(private = "package")
	_backend_register_fixed_fd :: proc "contextless" (
		backend: ^Platform_Backend,
		slot_index: u16,
		fd: OS_FD,
	) {
		if !backend.files_registered do return

		new_fd := linux.Fd(fd)
		update := _IO_Uring_Files_Update {
			offset = u32(slot_index),
			resv   = 0,
			data   = u64(uintptr(&new_fd)),
		}
		linux.io_uring_register(backend.ring.fd, .REGISTER_FILES_UPDATE, &update, 1)
	}

	// Clear a single slot in the kernel's fixed-file table.
	// Called by reactor on fd_table_free (FD leaves a slot).
	@(private = "package")
	_backend_unregister_fixed_fd :: proc "contextless" (
		backend: ^Platform_Backend,
		slot_index: u16,
	) {
		if !backend.files_registered do return

		empty_fd := linux.Fd(-1)
		update := _IO_Uring_Files_Update {
			offset = u32(slot_index),
			resv   = 0,
			data   = u64(uintptr(&empty_fd)),
		}
		linux.io_uring_register(backend.ring.fd, .REGISTER_FILES_UPDATE, &update, 1)
	}

	// Apply fixed-file optimization to an SQE if registered files are available.
	// Called after the uring helper has filled the SQE with the raw OS_FD.
	@(private = "file")
	_linux_apply_fixed_file :: #force_inline proc(
		sqe: ^linux.IO_Uring_SQE,
		fixed_file_index: u16,
	) {
		sqe.fd = linux.Fd(i32(fixed_file_index))
		sqe.flags += {.FIXED_FILE}
	}

	// Submit a READ_FIXED SQE. The kernel uses pre-pinned pages for the buffer
	@(private = "file")
	_linux_submit_read_fixed :: proc(
		backend: ^Platform_Backend,
		user_data: u64,
		op: Submission_Op_Read,
		buffer_index: u16,
		use_fixed_file: bool,
		fixed_file_index: u16,
	) -> bool {
		sqe := uring.get_sqe(&backend.ring) or_return
		sqe.opcode = .READ_FIXED
		sqe.fd = linux.Fd(op.fd)
		sqe.addr = u64(uintptr(op.buffer))
		sqe.len = op.size
		sqe.off = op.offset
		sqe.user_data = user_data
		sqe.buf_index = buffer_index
		if use_fixed_file {
			_linux_apply_fixed_file(sqe, fixed_file_index)
		}
		return true
	}

	// Submit a WRITE_FIXED SQE. Same kernel page-pinning benefit as READ_FIXED.
	@(private = "file")
	_linux_submit_write_fixed :: proc(
		backend: ^Platform_Backend,
		user_data: u64,
		op: Submission_Op_Write,
		buffer_index: u16,
		use_fixed_file: bool,
		fixed_file_index: u16,
	) -> bool {
		sqe := uring.get_sqe(&backend.ring) or_return
		sqe.opcode = .WRITE_FIXED
		sqe.fd = linux.Fd(op.fd)
		sqe.addr = u64(uintptr(op.buffer))
		sqe.len = op.size
		sqe.off = op.offset
		sqe.user_data = user_data
		sqe.buf_index = buffer_index
		if use_fixed_file {
			_linux_apply_fixed_file(sqe, fixed_file_index)
		}
		return true
	}

	@(private = "file")
	_linux_arm_wake :: proc(backend: ^Platform_Backend) {
		_, ok := uring.read(
			&backend.ring,
			LINUX_WAKE_UD,
			linux.Fd(backend.wake_fd),
			([^]u8)(&backend.wake_buffer)[:size_of(u64)],
			0,
		)
		if ok {
			uring.submit(&backend.ring, 0, nil)
		}
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
	_linux_alloc_addr_entry :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
	) -> ^Pending_Addr_Entry {
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
	_linux_find_addr_entry :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
	) -> ^Pending_Addr_Entry {
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
			return Socket_Address_Inet4{address = addr.sin_addr, port = u16(addr.sin_port)}
		case .INET6:
			return Socket_Address_Inet6 {
				address = transmute([16]u8)addr.sin6_addr,
				port = u16(addr.sin6_port),
				flow = addr.sin6_flowinfo,
				scope = addr.sin6_scope_id,
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
			sa.sin_port = u16be(addr.port)
			sa.sin_addr = addr.address
		case Socket_Address_Inet6:
			sa.sin6_family = .INET6
			sa.sin6_port = u16be(addr.port)
			sa.sin6_addr = transmute([16]u8)addr.address
			sa.sin6_flowinfo = addr.flow
			sa.sin6_scope_id = addr.scope
		case Socket_Address_Unix:
			sa.sun_family = .UNIX
			sa.sun_path = addr.path
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

	// ============================================================================
	// Tests (Linux-only, real io_uring)
	// ============================================================================

	@(test)
	test_linux_backend_control_dup_sets_cloexec_and_returns_distinct_fd :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 4,
		}
		backend_init_error := backend_init(&backend, config)
		testing.expect_value(t, backend_init_error, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, socket_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, socket_error, Backend_Error.None)

		dup_fd, dup_error := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_error, Backend_Error.None)
		testing.expect(t, dup_fd != fd, "dup must return a distinct descriptor")

		flags, flags_err := linux.fcntl_getfd(linux.Fd(dup_fd), .GETFD)
		testing.expect_value(t, flags_err, linux.Errno(0))
		testing.expect(t, flags != 0, "dup fd must have close-on-exec set")

		close_error := backend_control_close(&backend, fd)
		testing.expect_value(t, close_error, Backend_Error.None)
		close_dup_error := backend_control_close(&backend, dup_fd)
		testing.expect_value(t, close_dup_error, Backend_Error.None)
	}

	@(test)
	test_linux_fixed_files_register_and_deinit :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 8,
		}

		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		testing.expect(t, backend.files_registered, "fixed files should be registered")
		testing.expect_value(t, backend.fixed_fd_count, 8)

		backend_deinit(&backend)
		testing.expect(t, !backend.files_registered, "should be unregistered after deinit")
	}

	@(test)
	test_linux_fixed_files_disabled_when_zero :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 0,
		}

		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		testing.expect(t, !backend.files_registered, "should not register with 0 slots")

		backend_deinit(&backend)
	}

	@(test)
	test_linux_fixed_file_update_round_trip :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 4,
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		// Create a real socket
		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		// Register it in slot 0
		_backend_register_fixed_fd(&backend, 0, fd)

		// Submit a recv using IOSQE_FIXED_FILE on slot 0
		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_RECV_COMPLETE))
		buf: [64]u8
		submissions := [1]Submission {
			{
				token = token,
				fixed_file_index = 0,
				operation = Submission_Op_Recv{fd_socket = fd, buffer = &buf[0], size = 64},
			},
		}
		sub_err := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_err, Backend_Error.None)
		// If IOSQE_FIXED_FILE was applied incorrectly, the kernel would return EBADF
		// on the CQE. The submit succeeding means the SQE was accepted.

		// Unregister slot 0
		_backend_unregister_fixed_fd(&backend, 0)

		// Cancel the in-flight recv so we don't leak
		backend_cancel(&backend, token)

		// Clean up the socket
		backend_control_close(&backend, fd)
	}

	@(test)
	test_linux_close_sqe_uses_raw_fd :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 4,
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, _ := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		_backend_register_fixed_fd(&backend, 0, fd)

		// Submit a close with fixed_file_index = 0.
		// _linux_submit_one must NOT apply IOSQE_FIXED_FILE for close.
		// If it did, the close would target the fixed-file slot, not the raw FD.
		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CLOSE_COMPLETE))
		submissions := [1]Submission {
			{
				token = token,
				fixed_file_index = 0, // deliberately set — backend must ignore for close
				operation = Submission_Op_Close{fd = fd},
			},
		}
		sub_err := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_err, Backend_Error.None)

		// Collect the close completion — should succeed (not EBADF)
		completions: [4]Raw_Completion
		count, _ := backend_collect(&backend, completions[:], 100_000_000) // 100ms timeout
		testing.expect(t, count >= 1, "close should complete")
		testing.expect(t, completions[0].result >= 0, "close should succeed (not EBADF)")

		_backend_unregister_fixed_fd(&backend, 0)
	}

}
