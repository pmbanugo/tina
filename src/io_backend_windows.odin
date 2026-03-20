#+build windows
#+private
package tina

// ============================================================================
// IOCP Windows Backend (§6.6.2 §5.3) — Overlapped I/O with Completion Port
// ============================================================================
//
// Active when ODIN_OS == .Windows and TINA_SIM == false.
// Uses I/O Completion Ports (IOCP) for async I/O with token-based correlation.
//
// Design:
//   Submit: start async operation with OVERLAPPED. IO_PENDING → in-flight.
//           Synchronous success → immediate completion.
//   Collect: GetQueuedCompletionStatusEx for batch harvest.
//   Cancel: CancelIoEx on the OVERLAPPED.
//   Wake: PostQueuedCompletionStatus with nil overlapped.

import "core:testing"
import win "core:sys/windows"

when !TINA_SIMULATION_MODE {

	MAX_WIN_OVERLAPPED :: 512

	// Derivation: MAX_WIN_OVERLAPPED (512) synchronous completions from submit
	// + 128 IOCP events dequeued per GetQueuedCompletionStatusEx call = 640.
	// The overflow path in _backend_collect buffers excess completions here when the
	// caller's output slice is smaller than the IOCP batch.
	// TODO: Consider exposing via Backend_Config if workloads require larger bursts.
	MAX_WIN_COMPLETED :: 640

	// Accept and Recvfrom need persistent kernel-writable buffers that survive
	// until CQE harvest. These are mutually exclusive per entry, so we overlap
	// them to reduce per-entry footprint (~96 bytes saved × 512 entries ≈ 48KB).
	Win_Op_Data :: struct #raw_union {
		accept:   Win_Accept_Data,
		recvfrom: Win_Recvfrom_Data,
	}
	Win_Accept_Data :: struct {
		buf:       [(size_of(win.sockaddr_in6) + 16) * 2]u8,
		client_fd: OS_FD,
	}
	Win_Recvfrom_Data :: struct {
		peer_address:     win.SOCKADDR_STORAGE_LH,
		peer_address_len: win.INT,
	}

	Win_Overlapped_Entry :: struct {
		overlapped: win.OVERLAPPED,
		token:      Submission_Token,
		operation:  Submission_Operation,
		op_data:    Win_Op_Data,
		active:     bool,
	}

	// Layout guards: catch silent struct bloat or union mis-sizing at compile time.
	#assert(size_of(Win_Op_Data) == size_of(Win_Recvfrom_Data), "Win_Op_Data must be sized by the larger variant (Recvfrom)")
	#assert(size_of(Win_Accept_Data) <= size_of(Win_Recvfrom_Data), "Accept data grew larger than Recvfrom — update the union size assertion above")
	// AcceptEx requires the output buffer to hold two (sockaddr_in6 + 16) blocks.
	// We validate via the Accept struct total size minus the client_fd field.
	WIN_ACCEPTEX_MIN_BUF :: (size_of(win.sockaddr_in6) + 16) * 2
	#assert(size_of(Win_Accept_Data) >= WIN_ACCEPTEX_MIN_BUF + size_of(OS_FD), "AcceptEx buffer too small for dual sockaddr_in6 + 16 padding")

	_Platform_State :: struct {
		iocp:            win.HANDLE,
		entries:         [MAX_WIN_OVERLAPPED]Win_Overlapped_Entry,
		completed:       [MAX_WIN_COMPLETED]Raw_Completion,
		completed_count: u16,
		completed_read:  u16,
		accept_ex:       win.LPFN_ACCEPTEX,
		connect_ex:      win.LPFN_CONNECTEX,
	}

	// ============================================================================
	// Backend Procs
	// ============================================================================

	@(private = "package")
	_backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
		win.ensure_winsock_initialized()

		iocp := win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, 0, 1)
		if iocp == nil {
			return .System_Error
		}

		backend.iocp = iocp
		backend.completed_count = 0
		backend.completed_read = 0

		for i in 0 ..< MAX_WIN_OVERLAPPED {
			backend.entries[i].active = false
		}

		// Load AcceptEx and ConnectEx function pointers via a dummy socket
		dummy := win.WSASocketW(
			win.AF_INET,
			win.SOCK_STREAM,
			win.IPPROTO_TCP,
			nil,
			0,
			win.WSA_FLAG_OVERLAPPED,
		)
		if dummy != win.INVALID_SOCKET {
			_win_load_socket_fn(dummy, win.WSAID_ACCEPTEX, &backend.accept_ex)
			_win_load_socket_fn(dummy, win.WSAID_CONNECTEX, &backend.connect_ex)
			win.closesocket(dummy)
		}

		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		if backend.iocp != nil {
			win.CloseHandle(backend.iocp)
			backend.iocp = nil
		}
	}

	@(private = "package")
	_backend_submit :: proc(
		backend: ^Platform_Backend,
		submissions: []Submission,
	) -> Backend_Error {
		// All-or-error: pre-check overlapped entry capacity.
		available: i32 = 0
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			if !backend.entries[i].active {
				available += 1
			}
		}
		if available < i32(len(submissions)) {
			return .Queue_Full
		}

		for &sub in submissions {
			entry_idx := _win_alloc_entry(backend)
			if entry_idx < 0 {
				return .Queue_Full
			}

			entry := &backend.entries[entry_idx]
			entry.token = sub.token
			entry.operation = sub.operation
			entry.overlapped = {}

			switch op in sub.operation {
			case Submission_Op_Read:
				entry.overlapped.Offset = win.DWORD(u64(op.offset) & 0xFFFFFFFF)
				entry.overlapped.OffsetHigh = win.DWORD(u64(op.offset) >> 32)
				ok := win.ReadFile(
					win.HANDLE(uintptr(op.fd)),
					op.buffer,
					win.DWORD(op.size),
					nil,
					&entry.overlapped,
				)
				if ok == win.FALSE {
					err := win.GetLastError()
					if err == win.ERROR_IO_PENDING {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}
				// Synchronous success with FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Write:
				entry.overlapped.Offset = win.DWORD(u64(op.offset) & 0xFFFFFFFF)
				entry.overlapped.OffsetHigh = win.DWORD(u64(op.offset) >> 32)
				ok := win.WriteFile(
					win.HANDLE(uintptr(op.fd)),
					op.buffer,
					win.DWORD(op.size),
					nil,
					&entry.overlapped,
				)
				if ok == win.FALSE {
					err := win.GetLastError()
					if err == win.ERROR_IO_PENDING {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}
				_win_push_sync_completion(backend, entry)

				case Submission_Op_Accept:
				// Create the accept socket
				client_sock := win.WSASocketW(
					win.AF_INET,
					win.SOCK_STREAM,
					win.IPPROTO_TCP,
					nil,
					0,
					win.WSA_FLAG_OVERLAPPED,
				)
				if client_sock == win.INVALID_SOCKET {
					_win_push_error_completion(backend, sub.token, i32(win.WSAGetLastError()))
					entry.active = false
					continue
				}
				entry.op_data.accept.client_fd = OS_FD(client_sock)

				received: win.DWORD
				ok := win.TRUE
				if backend.accept_ex != nil {
					ok = backend.accept_ex(
						win.SOCKET(uintptr(op.listen_fd)),
						client_sock,
						&entry.op_data.accept.buf,
						0,
						size_of(win.sockaddr_in6) + 16,
						size_of(win.sockaddr_in6) + 16,
						&received,
						&entry.overlapped,
					)
				} else {
					_win_push_completion(backend, sub.token, i32(IO_ERR_RESOURCE_EXHAUSTED), nil)
					win.closesocket(client_sock)
					entry.op_data.accept.client_fd = OS_FD_INVALID
					entry.active = false
					continue
				}

				if ok == win.FALSE {
					err := win.GetLastError()
					if err == win.ERROR_IO_PENDING {
						continue
					}
					win.closesocket(client_sock)
					entry.op_data.accept.client_fd = OS_FD_INVALID
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}

				case Submission_Op_Connect:
				// ConnectEx requires the socket to be bound first
				_win_bind_for_connect(op.socket_fd, op.address)

				sockaddr, socklen := _win_socket_address_to_sockaddr(op.address)
				ok := win.TRUE
				if backend.connect_ex != nil {
					ok = backend.connect_ex(
						win.SOCKET(uintptr(op.socket_fd)),
						&sockaddr,
						socklen,
						nil,
						0,
						nil,
						&entry.overlapped,
					)
				} else {
					_win_push_completion(backend, sub.token, i32(IO_ERR_RESOURCE_EXHAUSTED), nil)
					entry.active = false
					continue
				}

				if ok == win.FALSE {
					err := win.GetLastError()
					if err == win.ERROR_IO_PENDING {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}

				case Submission_Op_Close:
				// Close is synchronous — no overlapped needed
				result: i32 = 0
				if win.closesocket(win.SOCKET(uintptr(op.fd))) == win.SOCKET_ERROR {
					// Try as a regular handle
					if win.CloseHandle(win.HANDLE(uintptr(op.fd))) == win.FALSE {
						result = i32(IO_ERR_RESOURCE_EXHAUSTED)
					}
				}
				_win_push_completion(backend, sub.token, result, nil)
				entry.active = false

			case Submission_Op_Send:
				wsa_buf := win.WSABUF {
					len = win.ULONG(op.size),
					buf = (^win.CHAR)(op.buffer),
				}
				rc := win.WSASend(
					win.SOCKET(uintptr(op.socket_fd)),
					&wsa_buf,
					1,
					nil,
					0,
					(^win.WSAOVERLAPPED)(&entry.overlapped),
					nil,
				)
				if rc == win.SOCKET_ERROR {
					err := win.WSAGetLastError()
					if _win_is_pending(err) {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Recv:
				wsa_buf := win.WSABUF {
					len = win.ULONG(op.size),
					buf = (^win.CHAR)(op.buffer),
				}
				flags: win.DWORD = 0
				rc := win.WSARecv(
					win.SOCKET(uintptr(op.socket_fd)),
					&wsa_buf,
					1,
					nil,
					&flags,
					(^win.WSAOVERLAPPED)(&entry.overlapped),
					nil,
				)
				if rc == win.SOCKET_ERROR {
					err := win.WSAGetLastError()
					if _win_is_pending(err) {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Sendto:
				sockaddr, socklen := _win_socket_address_to_sockaddr(op.address)
				wsa_buf := win.WSABUF {
					len = win.ULONG(op.size),
					buf = (^win.CHAR)(op.buffer),
				}
				rc := win.WSASendTo(
					win.SOCKET(uintptr(op.socket_fd)),
					&wsa_buf,
					1,
					nil,
					0,
					(^win.sockaddr)(&sockaddr),
					socklen,
					(^win.WSAOVERLAPPED)(&entry.overlapped),
					nil,
				)
				if rc == win.SOCKET_ERROR {
					err := win.WSAGetLastError()
					if _win_is_pending(err) {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Recvfrom:
				wsa_buf := win.WSABUF {
					len = win.ULONG(op.size),
					buf = (^win.CHAR)(op.buffer),
				}
				flags: win.DWORD = 0
				entry.op_data.recvfrom.peer_address = {}
				entry.op_data.recvfrom.peer_address_len = win.INT(size_of(win.SOCKADDR_STORAGE_LH))
				rc := win.WSARecvFrom(
					win.SOCKET(uintptr(op.socket_fd)),
					&wsa_buf,
					1,
					nil,
					&flags,
					(^win.sockaddr)(&entry.op_data.recvfrom.peer_address),
					&entry.op_data.recvfrom.peer_address_len,
					(^win.WSAOVERLAPPED)(&entry.overlapped),
					nil,
				)
				if rc == win.SOCKET_ERROR {
					err := win.WSAGetLastError()
					if _win_is_pending(err) {
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(err))
					entry.active = false
					continue
				}
				// Synchronous success — peer address is already in entry.op_data.recvfrom
				bytes := i32(uintptr(entry.overlapped.InternalHigh))
				_win_push_completion(
					backend,
					entry.token,
					bytes,
					Completion_Extra_Recvfrom {
						peer_address = _win_sockaddr_to_socket_address(&entry.op_data.recvfrom.peer_address),
					},
				)
				entry.active = false
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
		count: u32 = 0

		// 1. Drain immediate completions
		for backend.completed_read < backend.completed_count {
			if count >= u32(len(completions)) {
				return count, .None
			}
			completions[count] = backend.completed[backend.completed_read]
			backend.completed_read += 1
			count += 1
		}
		// Reset ring when fully drained
		if backend.completed_read >= backend.completed_count {
			backend.completed_count = 0
			backend.completed_read = 0
		}

		if count >= u32(len(completions)) {
			return count, .None
		}

		// 2. Harvest from IOCP
		timeout_ms: win.DWORD = 0
		if timeout_ns > 0 {
			timeout_ms = win.DWORD(timeout_ns / 1_000_000)
			if timeout_ms == 0 {
				timeout_ms = 1
			}
		} else if timeout_ns < 0 {
			timeout_ms = win.INFINITE
		}

		events: [128]win.OVERLAPPED_ENTRY
		entries_removed: win.ULONG
		if !win.GetQueuedCompletionStatusEx(
			backend.iocp,
			&events[0],
			win.ULONG(len(events)),
			&entries_removed,
			timeout_ms,
			false,
		) {
			err := win.GetLastError()
			if err == win.WAIT_TIMEOUT || err == win.WAIT_IO_COMPLETION {
				return count, .None
			}
			return count, .System_Error
		}

		for i in 0 ..< entries_removed {
			event := &events[i]
			if event.lpOverlapped == nil {
				// Wake-up sentinel — skip
				continue
			}

			entry := _win_entry_from_overlapped(backend, event.lpOverlapped)
			if entry == nil {
				continue
			}

			raw: Raw_Completion
			raw.token = entry.token
			raw.extra = nil

			// Extract result from OVERLAPPED
			bytes_transferred := i32(event.dwNumberOfBytesTransferred)

			if entry.overlapped.Internal != nil {
				// Error — translate NTSTATUS to a negative error code
				raw.result = i32(IO_ERR_RESOURCE_EXHAUSTED)
			} else {
				raw.result = bytes_transferred

				// Handle operation-specific completion data
				switch _ in entry.operation {
				case Submission_Op_Accept:
					when TINA_DEBUG_ASSERTS { _, da_ok := entry.operation.(Submission_Op_Accept); assert(da_ok, "Win_Op_Data.accept variant read on non-Accept entry — raw union would return corrupt client_fd/sockaddr from overlapping Recvfrom memory") }
					op := entry.operation.(Submission_Op_Accept)
					if bytes_transferred >= 0 {
						accept_fd := entry.op_data.accept.client_fd
						// Associate accepted socket with IOCP at creation time
						_win_associate_with_iocp(backend, win.HANDLE(uintptr(accept_fd)))

						// Inherit listen socket properties on the accepted socket
						listen_sock := win.SOCKET(uintptr(op.listen_fd))
						win.setsockopt(
							win.SOCKET(uintptr(accept_fd)),
							win.SOL_SOCKET,
							win.SO_UPDATE_ACCEPT_CONTEXT,
							(^win.CHAR)(&listen_sock),
							size_of(listen_sock),
						)

						local_addr: ^win.sockaddr
						local_len: win.INT
						remote_addr: ^win.sockaddr
						remote_len: win.INT
						win.GetAcceptExSockaddrs(
							&entry.op_data.accept.buf,
							0,
							size_of(win.sockaddr_in6) + 16,
							size_of(win.sockaddr_in6) + 16,
							&local_addr,
							&local_len,
							&remote_addr,
							&remote_len,
						)
						client_address := _win_sockaddr_to_socket_address(
							(^win.SOCKADDR_STORAGE_LH)(remote_addr),
						)
						raw.result = 0
						raw.extra = Completion_Extra_Accept {
							client_fd      = accept_fd,
							client_address = client_address,
						}
					}

				case Submission_Op_Connect:
					// Enable full socket API on ConnectEx-completed socket
					win.setsockopt(
						win.SOCKET(uintptr(
							entry.operation.(Submission_Op_Connect).socket_fd,
						)),
						win.SOL_SOCKET,
						win.SO_UPDATE_CONNECT_CONTEXT,
						nil,
						0,
					)
					raw.result = 0

				case Submission_Op_Close:
					raw.result = 0

				case Submission_Op_Recvfrom:
					when TINA_DEBUG_ASSERTS { _, dr_ok := entry.operation.(Submission_Op_Recvfrom); assert(dr_ok, "Win_Op_Data.recvfrom variant read on non-Recvfrom entry — raw union would return corrupt peer_address from overlapping Accept memory") }
					if bytes_transferred >= 0 {
						raw.extra = Completion_Extra_Recvfrom {
							peer_address = _win_sockaddr_to_socket_address(
								&entry.op_data.recvfrom.peer_address,
							),
						}
					}

				case Submission_Op_Read:
				case Submission_Op_Write:
				case Submission_Op_Send:
				case Submission_Op_Recv:
				case Submission_Op_Sendto:
				}
			}

			entry.active = false

			// Deliver to output slice, or buffer internally if output is full
			if count < u32(len(completions)) {
				completions[count] = raw
				count += 1
			} else {
				_win_push_completion(backend, raw.token, raw.result, raw.extra)
			}
		}

		return count, .None
	}

	@(private = "package")
	_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			entry := &backend.entries[i]
			if entry.active && entry.token == token {
				// Find the handle for CancelIoEx
				handle := _win_entry_handle(entry)
				if handle != win.INVALID_HANDLE_VALUE {
					win.CancelIoEx(handle, &entry.overlapped)
				}
				return .None
			}
		}
		return .Not_Found
	}

	@(private = "package")
	_backend_wake :: proc(backend: ^Platform_Backend) {
		win.PostQueuedCompletionStatus(backend.iocp, 0, 0, nil)
	}

	// --- Synchronous Control Operations ---

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
		af: i32
		switch domain {
		case .AF_INET:
			af = win.AF_INET
		case .AF_INET6:
			af = win.AF_INET6
		case .AF_UNIX:
			af = 1 // AF_UNIX
		}

		st: i32
		switch socket_type {
		case .STREAM:
			st = win.SOCK_STREAM
		case .DGRAM:
			st = win.SOCK_DGRAM
		}

		proto: i32
		switch protocol {
		case .DEFAULT:
			proto = 0
		case .TCP:
			proto = win.IPPROTO_TCP
		case .UDP:
			proto = win.IPPROTO_UDP
		}

		sock := win.WSASocketW(af, st, proto, nil, 0, win.WSA_FLAG_OVERLAPPED)
		if sock == win.INVALID_SOCKET {
			return OS_FD_INVALID, .System_Error
		}

		// Associate with IOCP at creation time — before any I/O submission
		_win_associate_with_iocp(backend, win.HANDLE(sock))

		return OS_FD(sock), .None
	}

	@(private = "package")
	_backend_control_bind :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		address: Socket_Address,
	) -> Backend_Error {
		sockaddr, socklen := _win_socket_address_to_sockaddr(address)
		if win.bind(win.SOCKET(uintptr(fd)), &sockaddr, socklen) ==
		   win.SOCKET_ERROR {
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
		if win.listen(win.SOCKET(uintptr(fd)), i32(backlog)) == win.SOCKET_ERROR {
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
		sol := _win_map_socket_level(level)
		opt := _win_map_socket_option(option)

		switch v in value {
		case bool:
			val: win.DWORD = 1 if v else 0
			if win.setsockopt(
				   win.SOCKET(uintptr(fd)),
				   sol,
				   opt,
				   (^win.CHAR)(&val),
				   size_of(val),
			   ) ==
			   win.SOCKET_ERROR {
				return .System_Error
			}
		case i32:
			val := v
			if win.setsockopt(
				   win.SOCKET(uintptr(fd)),
				   sol,
				   opt,
				   (^win.CHAR)(&val),
				   size_of(val),
			   ) ==
			   win.SOCKET_ERROR {
				return .System_Error
			}
		}

		return .None
	}

	@(private = "package")
	_backend_control_shutdown :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		how: Shutdown_How,
	) -> Backend_Error {
		sd_how: i32
		switch how {
		case .SHUT_READER:
			sd_how = win.SD_RECEIVE
		case .SHUT_WRITER:
			sd_how = win.SD_SEND
		case .SHUT_BOTH:
			sd_how = win.SD_BOTH
		}
		if win.shutdown(win.SOCKET(uintptr(fd)), sd_how) == win.SOCKET_ERROR {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc(backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
		if win.closesocket(win.SOCKET(uintptr(fd))) == win.SOCKET_ERROR {
			if !win.CloseHandle(win.HANDLE(uintptr(fd))) {
				return .System_Error
			}
		}
		return .None
	}

	@(private = "package")
	_backend_register_fixed_fd :: proc(backend: ^Platform_Backend, slot_index: u16, fd: OS_FD) {
		// No-op: IOCP has no fixed-file table.
	}

	@(private = "package")
	_backend_unregister_fixed_fd :: proc(backend: ^Platform_Backend, slot_index: u16) {
		// No-op: IOCP has no fixed-file table.
	}

	// ============================================================================
	// Internal Helpers
	// ============================================================================

	@(private = "file")
	_win_alloc_entry :: proc(backend: ^Platform_Backend) -> i32 {
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			if !backend.entries[i].active {
				backend.entries[i].active = true
				return i32(i)
			}
		}
		return -1
	}

	@(private = "file")
	_win_entry_from_overlapped :: proc(
		backend: ^Platform_Backend,
		overlapped: ^win.OVERLAPPED,
	) -> ^Win_Overlapped_Entry {
		// Scan entries for matching overlapped address
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			if &backend.entries[i].overlapped == overlapped {
				return &backend.entries[i]
			}
		}
		return nil
	}

	@(private = "file")
	_win_entry_handle :: proc(entry: ^Win_Overlapped_Entry) -> win.HANDLE {
		switch op in entry.operation {
		case Submission_Op_Read:
			return win.HANDLE(uintptr(op.fd))
		case Submission_Op_Write:
			return win.HANDLE(uintptr(op.fd))
		case Submission_Op_Accept:
			return win.HANDLE(uintptr(op.listen_fd))
		case Submission_Op_Connect:
			return win.HANDLE(uintptr(op.socket_fd))
		case Submission_Op_Close:
			return win.HANDLE(uintptr(op.fd))
		case Submission_Op_Send:
			return win.HANDLE(uintptr(op.socket_fd))
		case Submission_Op_Recv:
			return win.HANDLE(uintptr(op.socket_fd))
		case Submission_Op_Sendto:
			return win.HANDLE(uintptr(op.socket_fd))
		case Submission_Op_Recvfrom:
			return win.HANDLE(uintptr(op.socket_fd))
		}
		return win.INVALID_HANDLE_VALUE
	}

	@(private = "file")
	_win_push_completion :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
		result: i32,
		extra: Completion_Extra,
	) {
		if backend.completed_count < MAX_WIN_COMPLETED {
			c := &backend.completed[backend.completed_count]
			c.token = token
			c.result = result
			c.extra = extra
			backend.completed_count += 1
		}
	}

	@(private = "file")
	_win_push_error_completion :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
		err: i32,
	) {
		_win_push_completion(backend, token, -err, nil)
	}

	@(private = "file")
	_win_push_sync_completion :: proc(backend: ^Platform_Backend, entry: ^Win_Overlapped_Entry) {
		bytes := i32(uintptr(entry.overlapped.InternalHigh))
		_win_push_completion(backend, entry.token, bytes, nil)
		entry.active = false
	}

	// Associate a handle with IOCP and enable skip-on-success.
	// Called exactly once per FD at creation time (control_socket or accept completion).
	// Invariant: never called on an already-associated handle.
	@(private = "file")
	_win_associate_with_iocp :: proc(backend: ^Platform_Backend, handle: win.HANDLE) {
		win.CreateIoCompletionPort(handle, backend.iocp, 0, 0)
		cmode: u8 = win.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS | win.FILE_SKIP_SET_EVENT_ON_HANDLE
		win.SetFileCompletionNotificationModes(handle, cmode)
	}

	@(private = "file")
	_win_is_pending :: proc(err: win.INT) -> bool {
		return(
			err == i32(win.System_Error.IO_PENDING) ||
			err == i32(win.System_Error.WSAEWOULDBLOCK) \
		)
	}

	@(private = "file")
	_win_bind_for_connect :: proc(fd: OS_FD, address: Socket_Address) {
		// ConnectEx requires the socket to be bound first (to INADDR_ANY:0)
		bind_addr: win.SOCKADDR_STORAGE_LH
		bind_len: win.INT

		switch _ in address {
		case Socket_Address_Inet4:
			addr := (^win.sockaddr_in)(&bind_addr)
			addr.sin_family = u16(win.AF_INET)
			addr.sin_port = 0
			addr.sin_addr = {}
			bind_len = size_of(win.sockaddr_in)
		case Socket_Address_Inet6:
			addr := (^win.sockaddr_in6)(&bind_addr)
			addr.sin6_family = u16(win.AF_INET6)
			addr.sin6_port = 0
			addr.sin6_addr = {}
			bind_len = size_of(win.sockaddr_in6)
		case Socket_Address_Unix:
			return
		case:
			return
		}

		win.bind(win.SOCKET(uintptr(fd)), &bind_addr, bind_len)
	}

	@(private = "file")
	_win_load_socket_fn :: proc(subject: win.SOCKET, guid: win.GUID, fn: ^$T) {
		guid := guid
		bytes: u32
		win.WSAIoctl(
			subject,
			win.SIO_GET_EXTENSION_FUNCTION_POINTER,
			&guid,
			size_of(guid),
			fn,
			size_of(fn^),
			&bytes,
			nil,
			nil,
		)
	}

	// --- Address Conversion ---

	@(private = "file")
	_win_socket_address_to_sockaddr :: proc(
		address: Socket_Address,
	) -> (
		win.SOCKADDR_STORAGE_LH,
		win.INT,
	) {
		storage: win.SOCKADDR_STORAGE_LH
		switch addr in address {
		case Socket_Address_Inet4:
			sa := (^win.sockaddr_in)(&storage)
			sa.sin_family = u16(win.AF_INET)
			sa.sin_port = u16be(addr.port)
			sa.sin_addr = transmute(win.in_addr)addr.address
			return storage, size_of(win.sockaddr_in)
		case Socket_Address_Inet6:
			sa := (^win.sockaddr_in6)(&storage)
			sa.sin6_family = u16(win.AF_INET6)
			sa.sin6_port = u16be(addr.port)
			sa.sin6_addr = transmute(win.in6_addr)addr.address
			return storage, size_of(win.sockaddr_in6)
		case Socket_Address_Unix:
			return storage, 0
		}
		return storage, 0
	}

	@(private = "file")
	_win_sockaddr_to_socket_address :: proc(native: ^win.SOCKADDR_STORAGE_LH) -> Socket_Address {
		if native == nil {
			return nil
		}
		switch native.ss_family {
		case u16(win.AF_INET):
			sa := (^win.sockaddr_in)(native)
			return Socket_Address_Inet4 {
				address = transmute([4]u8)sa.sin_addr,
				port = u16(u16be(sa.sin_port)),
			}
		case u16(win.AF_INET6):
			sa := (^win.sockaddr_in6)(native)
			return Socket_Address_Inet6 {
				address = transmute([16]u8)sa.sin6_addr,
				port = u16(u16be(sa.sin6_port)),
			}
		}
		return nil
	}

	@(private = "file")
	_win_map_socket_level :: proc(level: Socket_Level) -> i32 {
		switch level {
		case .SOL_SOCKET:
			return win.SOL_SOCKET
		case .IPPROTO_TCP:
			return win.IPPROTO_TCP
		case .IPPROTO_UDP:
			return win.IPPROTO_UDP
		case .IPPROTO_IPV6:
			return win.IPPROTO_IPV6
		}
		return 0
	}

	@(private = "file")
	_win_map_socket_option :: proc(option: Socket_Option) -> i32 {
		switch option {
		case .SO_REUSEADDR:
			return win.SO_REUSEADDR
		case .SO_REUSEPORT:
			return win.SO_REUSEADDR // Windows uses REUSEADDR
		case .SO_KEEPALIVE:
			return win.SO_KEEPALIVE
		case .SO_RCVBUF:
			return win.SO_RCVBUF
		case .SO_SNDBUF:
			return win.SO_SNDBUF
		case .SO_LINGER:
			return win.SO_LINGER
		case .SO_BINDTODEVICE:
			return 0 // Not supported on Windows
		case .TCP_NODELAY:
			return win.TCP_NODELAY
		case .TCP_CORK:
			return 0 // Not supported on Windows
		case .TCP_NOPUSH:
			return 0 // Not supported on Windows
		case .TCP_KEEPIDLE:
			return 3 // TCP_KEEPIDLE
		case .TCP_KEEPINTVL:
			return 17 // TCP_KEEPINTVL
		case .TCP_KEEPCNT:
			return 16 // TCP_KEEPCNT
		case .IPV6_V6ONLY:
			return win.IPV6_V6ONLY
		}
		return 0
	}

	// ============================================================================
	// Tests
	// ============================================================================

	@(test)
	test_windows_socket_creation_and_close :: proc(t: ^testing.T) {
		backend := new(Platform_Backend)
		config := Backend_Config{queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		err := backend_init(backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		defer { backend_deinit(backend); free(backend) }

		// Create a socket — IOCP association happens here
		fd, sock_err := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)
		testing.expect(t, fd != OS_FD_INVALID, "should get a valid socket")

		// Submit close — exercises the IOCP path (close is synchronous but goes through submit)
		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CLOSE_COMPLETE))
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Close{fd = fd}},
		}
		sub_err := backend_submit(backend, submissions[:])
		testing.expect_value(t, sub_err, Backend_Error.None)

		// Collect the close completion
		completions: [4]Raw_Completion
		count, collect_err := backend_collect(backend, completions[:], 0)
		testing.expect_value(t, collect_err, Backend_Error.None)
		testing.expect(t, count >= 1, "close should produce a completion")
		testing.expect_value(t, completions[0].token, token)
		testing.expect(t, completions[0].result >= 0, "close of valid socket should succeed")
	}

	@(test)
	test_windows_tcp_accept_completes :: proc(t: ^testing.T) {
		backend := new(Platform_Backend)
		config := Backend_Config{queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		backend_init(backend, config)
		defer { backend_deinit(backend); free(backend) }

		// Set up a listener on ephemeral port
		listen_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		backend_control_setsockopt(backend, listen_fd, .SOL_SOCKET, .SO_REUSEADDR, bool(true))
		listen_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 0}
		backend_control_bind(backend, listen_fd, listen_address)
		backend_control_listen(backend, listen_fd, 4)

		// Discover the assigned port via getsockname
		bound_addr: win.SOCKADDR_STORAGE_LH
		bound_addr_len := win.c_int(size_of(bound_addr))
		win.getsockname(win.SOCKET(uintptr(listen_fd)), &bound_addr, &bound_addr_len)
		bound_port := u16(u16be((^win.sockaddr_in)(&bound_addr).sin_port))

		// Submit accept
		accept_token := submission_token_pack(
			0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_ACCEPT_COMPLETE),
		)
		accept_submissions := [1]Submission {
			{token = accept_token, operation = Submission_Op_Accept{listen_fd = listen_fd}},
		}
		backend_submit(backend, accept_submissions[:])

		// Connect a client socket to trigger the accept
		client_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		connect_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = bound_port}
		connect_token := submission_token_pack(
			0, 1, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CONNECT_COMPLETE),
		)
		connect_submissions := [1]Submission {
			{
				token = connect_token,
				operation = Submission_Op_Connect{socket_fd = client_fd, address = connect_address},
			},
		}
		backend_submit(backend, connect_submissions[:])

		// Collect both completions (accept + connect)
		completions: [8]Raw_Completion
		collected: u32 = 0
		accept_found := false
		connect_found := false

		for _ in 0 ..< 20 {
			count, _ := backend_collect(backend, completions[collected:], 50_000_000) // 50ms
			collected += count
			// Check what we have
			for i in 0 ..< collected {
				if completions[i].token == accept_token do accept_found = true
				if completions[i].token == connect_token do connect_found = true
			}
			if accept_found && connect_found do break
		}

		testing.expect(t, accept_found, "accept should complete")
		testing.expect(t, connect_found, "connect should complete")

		// Validate the accept completion carries client_fd and address
		for i in 0 ..< collected {
			if completions[i].token == accept_token {
				testing.expect(t, completions[i].result >= 0, "accept should succeed")
				extra, extra_ok := completions[i].extra.(Completion_Extra_Accept)
				testing.expect(t, extra_ok, "accept should have Completion_Extra_Accept")
				if extra_ok {
					testing.expect(
						t,
						extra.client_fd != OS_FD_INVALID,
						"accepted client_fd should be valid",
					)
					// Clean up accepted socket
					backend_control_close(backend, extra.client_fd)
				}
			}
		}

		backend_control_close(backend, client_fd)
		backend_control_close(backend, listen_fd)
	}

	@(test)
	test_windows_tcp_connect_completes :: proc(t: ^testing.T) {
		backend := new(Platform_Backend)
		config := Backend_Config{queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		backend_init(backend, config)
		defer { backend_deinit(backend); free(backend) }

		// Set up listener
		listen_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		backend_control_setsockopt(backend, listen_fd, .SOL_SOCKET, .SO_REUSEADDR, bool(true))
		listen_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 0}
		backend_control_bind(backend, listen_fd, listen_address)
		backend_control_listen(backend, listen_fd, 4)

		bound_addr: win.SOCKADDR_STORAGE_LH
		bound_addr_len := win.c_int(size_of(bound_addr))
		win.getsockname(win.SOCKET(uintptr(listen_fd)), &bound_addr, &bound_addr_len)
		bound_port := u16(u16be((^win.sockaddr_in)(&bound_addr).sin_port))

		// Connect
		client_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		connect_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = bound_port}
		token := submission_token_pack(
			0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CONNECT_COMPLETE),
		)
		submissions := [1]Submission {
			{
				token = token,
				operation = Submission_Op_Connect{socket_fd = client_fd, address = connect_address},
			},
		}
		backend_submit(backend, submissions[:])

		// Collect
		completions: [4]Raw_Completion
		collected: u32 = 0
		for _ in 0 ..< 10 {
			count, _ := backend_collect(backend, completions[collected:], 50_000_000)
			collected += count
			if collected >= 1 do break
		}

		testing.expect(t, collected >= 1, "connect should complete")
		testing.expect_value(t, completions[0].token, token)
		testing.expect_value(t, completions[0].result, 0)

		// Validate SO_UPDATE_CONNECT_CONTEXT was applied:
		// getpeername succeeds only after SO_UPDATE_CONNECT_CONTEXT
		peer_addr: win.SOCKADDR_STORAGE_LH
		peer_addr_len := win.c_int(size_of(peer_addr))
		rc := win.getpeername(win.SOCKET(uintptr(client_fd)), &peer_addr, &peer_addr_len)
		testing.expect(t, rc != win.SOCKET_ERROR, "getpeername should succeed after SO_UPDATE_CONNECT_CONTEXT")

		backend_control_close(backend, client_fd)
		backend_control_close(backend, listen_fd)
	}

	@(test)
	test_windows_send_recv_round_trip :: proc(t: ^testing.T) {
		backend := new(Platform_Backend)
		config := Backend_Config{queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		backend_init(backend, config)
		defer { backend_deinit(backend); free(backend) }

		// Set up listener + accept + connect (loopback pair)
		listen_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		backend_control_setsockopt(backend, listen_fd, .SOL_SOCKET, .SO_REUSEADDR, bool(true))
		listen_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 0}
		backend_control_bind(backend, listen_fd, listen_address)
		backend_control_listen(backend, listen_fd, 4)

		bound_addr: win.SOCKADDR_STORAGE_LH
		bound_addr_len := win.c_int(size_of(bound_addr))
		win.getsockname(win.SOCKET(uintptr(listen_fd)), &bound_addr, &bound_addr_len)
		bound_port := u16(u16be((^win.sockaddr_in)(&bound_addr).sin_port))

		// Submit accept
		accept_token := submission_token_pack(
			0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_ACCEPT_COMPLETE),
		)
		accept_sub := [1]Submission {
			{token = accept_token, operation = Submission_Op_Accept{listen_fd = listen_fd}},
		}
		backend_submit(backend, accept_sub[:])

		// Connect
		client_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		connect_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = bound_port}
		connect_token := submission_token_pack(
			0, 1, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CONNECT_COMPLETE),
		)
		connect_sub := [1]Submission {
			{
				token = connect_token,
				operation = Submission_Op_Connect{
					socket_fd = client_fd,
					address = connect_address,
				},
			},
		}
		backend_submit(backend, connect_sub[:])

		// Collect accept + connect
		completions: [8]Raw_Completion
		collected: u32 = 0
		server_fd := OS_FD_INVALID
		for _ in 0 ..< 20 {
			count, _ := backend_collect(backend, completions[collected:], 50_000_000)
			collected += count
			accept_done := false
			connect_done := false
			for i in 0 ..< collected {
				if completions[i].token == accept_token {
					accept_done = true
					extra, ok := completions[i].extra.(Completion_Extra_Accept)
					if ok do server_fd = extra.client_fd
				}
				if completions[i].token == connect_token do connect_done = true
			}
			if accept_done && connect_done do break
		}
		testing.expect(t, server_fd != OS_FD_INVALID, "accept should yield a valid server FD")

		// Send from client, recv on server
		send_data := [4]u8{0xDE, 0xAD, 0xBE, 0xEF}
		send_token := submission_token_pack(
			0, 2, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_SEND_COMPLETE),
		)
		send_sub := [1]Submission {
			{
				token = send_token,
				operation = Submission_Op_Send{
					socket_fd = client_fd,
					buffer = &send_data[0],
					size = 4,
				},
			},
		}

		recv_buf: [64]u8
		recv_token := submission_token_pack(
			0, 3, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_RECV_COMPLETE),
		)
		recv_sub := [1]Submission {
			{
				token = recv_token,
				operation = Submission_Op_Recv{
					socket_fd = server_fd,
					buffer = &recv_buf[0],
					size = 64,
				},
			},
		}

		backend_submit(backend, send_sub[:])
		backend_submit(backend, recv_sub[:])

		// Collect send + recv
		collected = 0
		send_done := false
		recv_done := false
		recv_byte_count: i32 = 0
		for _ in 0 ..< 20 {
			count, _ := backend_collect(backend, completions[collected:], 50_000_000)
			collected += count
			for i in 0 ..< collected {
				if completions[i].token == send_token do send_done = true
				if completions[i].token == recv_token {
					recv_done = true
					recv_byte_count = completions[i].result
				}
			}
			if send_done && recv_done do break
		}

		testing.expect(t, send_done, "send should complete")
		testing.expect(t, recv_done, "recv should complete")
		testing.expect_value(t, recv_byte_count, 4)
		testing.expect_value(t, recv_buf[0], 0xDE)
		testing.expect_value(t, recv_buf[1], 0xAD)
		testing.expect_value(t, recv_buf[2], 0xBE)
		testing.expect_value(t, recv_buf[3], 0xEF)

		backend_control_close(backend, server_fd)
		backend_control_close(backend, client_fd)
		backend_control_close(backend, listen_fd)
	}

	@(test)
	test_windows_collect_overflow_buffered :: proc(t: ^testing.T) {
		backend := new(Platform_Backend)
		config := Backend_Config{queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		backend_init(backend, config)
		defer { backend_deinit(backend); free(backend) }

		// Create and immediately close 3 sockets — close is synchronous,
		// so 3 completions land in the internal completed queue.
		tokens: [3]Submission_Token
		for i in 0 ..< 3 {
			fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
			tokens[i] = submission_token_pack(
				0, u32(i), 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CLOSE_COMPLETE),
			)
			submissions := [1]Submission {
				{token = tokens[i], operation = Submission_Op_Close{fd = fd}},
			}
			backend_submit(backend, submissions[:])
		}

		// Collect with a 1-slot output slice — only 1 should be returned
		completions_small: [1]Raw_Completion
		count_first, err_first := backend_collect(backend, completions_small[:], 0)
		testing.expect_value(t, err_first, Backend_Error.None)
		testing.expect_value(t, count_first, 1)

		// Collect again — the remaining 2 should come from the internal buffer
		completions_rest: [4]Raw_Completion
		count_rest, err_rest := backend_collect(backend, completions_rest[:], 0)
		testing.expect_value(t, err_rest, Backend_Error.None)
		testing.expect_value(t, count_rest, 2)

		// Verify all 3 tokens were delivered (order may vary)
		delivered: [3]bool
		all_completions := [3]Raw_Completion{completions_small[0], completions_rest[0], completions_rest[1]}
		for c in all_completions {
			for j in 0 ..< 3 {
				if c.token == tokens[j] do delivered[j] = true
			}
		}
		for j in 0 ..< 3 {
			testing.expect(t, delivered[j], "all 3 close completions should be delivered")
		}
	}

	@(test)
	test_windows_close_error_result_negative :: proc(t: ^testing.T) {
		backend := new(Platform_Backend)
		config := Backend_Config{queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		backend_init(backend, config)
		defer { backend_deinit(backend); free(backend) }

		// Submit close of an invalid FD — both closesocket and CloseHandle should fail
		token := submission_token_pack(
			0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_CLOSE_COMPLETE),
		)
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Close{fd = OS_FD(uintptr(0xDEADBEEF))}},
		}
		backend_submit(backend, submissions[:])

		completions: [4]Raw_Completion
		count, _ := backend_collect(backend, completions[:], 0)
		testing.expect(t, count >= 1, "close should produce a completion")
		testing.expect(t, completions[0].result < 0, "close of invalid FD should yield negative result")
	}

} // when !TINA_SIM
