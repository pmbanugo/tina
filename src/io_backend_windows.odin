#+build windows
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

import win "core:sys/windows"

when !#config(TINA_SIM, false) {

MAX_WIN_OVERLAPPED :: 512
MAX_WIN_COMPLETED  :: 256

Win_Overlapped_Entry :: struct {
	overlapped: win.OVERLAPPED,
	token:      Submission_Token,
	operation:  Submission_Operation,
	accept_buf: [(size_of(win.sockaddr_in6) + 16) * 2]u8,
	active:     bool,
}

_Platform_State :: struct {
	iocp:            win.HANDLE,
	entries:         [MAX_WIN_OVERLAPPED]Win_Overlapped_Entry,
	completed:       [MAX_WIN_COMPLETED]Raw_Completion,
	completed_count: u16,
	completed_read:  u16,
	accept_ex:       win.LPFN_ACCEPTEX,
	connect_ex:      win.LPFN_CONNECTEX,
	associated:      [MAX_WIN_OVERLAPPED]OS_FD,
	associated_count: u16,
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
	backend.associated_count = 0

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
_backend_submit :: proc(backend: ^Platform_Backend, submissions: []Submission) -> Backend_Error {
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
			_win_associate_handle(backend, win.HANDLE(uintptr(op.fd)))
			entry.overlapped.Offset = win.DWORD(u64(op.offset) & 0xFFFFFFFF)
			entry.overlapped.OffsetHigh = win.DWORD(u64(op.offset) >> 32)
			ok := win.ReadFile(
				win.HANDLE(uintptr(op.fd)),
				op.buffer,
				win.DWORD(op.size),
				nil,
				&entry.overlapped,
			)
			if !ok {
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
			_win_associate_handle(backend, win.HANDLE(uintptr(op.fd)))
			entry.overlapped.Offset = win.DWORD(u64(op.offset) & 0xFFFFFFFF)
			entry.overlapped.OffsetHigh = win.DWORD(u64(op.offset) >> 32)
			ok := win.WriteFile(
				win.HANDLE(uintptr(op.fd)),
				op.buffer,
				win.DWORD(op.size),
				nil,
				&entry.overlapped,
			)
			if !ok {
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
			_win_associate_handle(backend, win.HANDLE(uintptr(op.listen_fd)))
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

			received: win.DWORD
			ok := true
			if backend.accept_ex != nil {
				ok = backend.accept_ex(
					win.SOCKET(uintptr(op.listen_fd)),
					client_sock,
					&entry.accept_buf,
					0,
					size_of(win.sockaddr_in6) + 16,
					size_of(win.sockaddr_in6) + 16,
					&received,
					&entry.overlapped,
				)
			} else {
				_win_push_error_completion(backend, sub.token, i32(IO_ERR_RESOURCE_EXHAUSTED))
				win.closesocket(client_sock)
				entry.active = false
				continue
			}

			if !ok {
				err := win.GetLastError()
				if err == win.ERROR_IO_PENDING {
					continue
				}
				win.closesocket(client_sock)
				_win_push_error_completion(backend, sub.token, i32(err))
				entry.active = false
				continue
			}

		case Submission_Op_Connect:
			_win_associate_handle(backend, win.HANDLE(uintptr(op.socket_fd)))
			// ConnectEx requires the socket to be bound first
			_win_bind_for_connect(op.socket_fd, op.address)

			sockaddr, socklen := _win_socket_address_to_sockaddr(op.address)
			ok := true
			if backend.connect_ex != nil {
				ok = backend.connect_ex(
					win.SOCKET(uintptr(op.socket_fd)),
					(^win.SOCKADDR)(&sockaddr),
					socklen,
					nil,
					0,
					nil,
					&entry.overlapped,
				)
			} else {
				_win_push_error_completion(backend, sub.token, i32(IO_ERR_RESOURCE_EXHAUSTED))
				entry.active = false
				continue
			}

			if !ok {
				err := win.GetLastError()
				if err == win.ERROR_IO_PENDING {
					continue
				}
				_win_push_error_completion(backend, sub.token, i32(err))
				entry.active = false
				continue
			}

		case Submission_Op_Close:
			// Close is synchronous
			result: i32 = 0
			if win.closesocket(win.SOCKET(uintptr(op.fd))) == win.SOCKET_ERROR {
				// Try as a regular handle
				if !win.CloseHandle(win.HANDLE(uintptr(op.fd))) {
					result = i32(IO_ERR_RESOURCE_EXHAUSTED)
				}
			}
			_win_push_completion(backend, sub.token, result, nil)
			entry.active = false

		case Submission_Op_Send:
			_win_associate_handle(backend, win.HANDLE(uintptr(op.socket_fd)))
			wsa_buf := win.WSABUF{
				len = win.ULONG(op.size),
				buf = (^win.CHAR)(op.buffer),
			}
			rc := win.WSASend(
				win.SOCKET(uintptr(op.socket_fd)),
				&wsa_buf,
				1,
				nil,
				0,
				&entry.overlapped,
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
			_win_associate_handle(backend, win.HANDLE(uintptr(op.socket_fd)))
			wsa_buf := win.WSABUF{
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
				&entry.overlapped,
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
			_win_associate_handle(backend, win.HANDLE(uintptr(op.socket_fd)))
			sockaddr, socklen := _win_socket_address_to_sockaddr(op.address)
			wsa_buf := win.WSABUF{
				len = win.ULONG(op.size),
				buf = (^win.CHAR)(op.buffer),
			}
			rc := win.WSASendTo(
				win.SOCKET(uintptr(op.socket_fd)),
				&wsa_buf,
				1,
				nil,
				0,
				(^win.SOCKADDR)(&sockaddr),
				socklen,
				&entry.overlapped,
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
			_win_associate_handle(backend, win.HANDLE(uintptr(op.socket_fd)))
			wsa_buf := win.WSABUF{
				len = win.ULONG(op.size),
				buf = (^win.CHAR)(op.buffer),
			}
			flags: win.DWORD = 0
			rc := win.WSARecvFrom(
				win.SOCKET(uintptr(op.socket_fd)),
				&wsa_buf,
				1,
				nil,
				&flags,
				nil, // peer address extracted separately if needed
				nil,
				&entry.overlapped,
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
		}
	}

	return .None
}

@(private = "package")
_backend_collect :: proc(
	backend: ^Platform_Backend,
	completions: []Raw_Completion,
	timeout_ns: i64,
) -> (u32, Backend_Error) {
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

		if count >= u32(len(completions)) {
			break
		}

		entry := _win_entry_from_overlapped(backend, event.lpOverlapped)
		if entry == nil {
			continue
		}

		completion := &completions[count]
		completion.token = entry.token
		completion.extra = nil

		// Extract result from OVERLAPPED
		bytes_transferred := i32(event.dwNumberOfBytesTransferred)

		if entry.overlapped.Internal != nil {
			// Error — translate NTSTATUS to a negative error code
			completion.result = i32(IO_ERR_RESOURCE_EXHAUSTED)
		} else {
			completion.result = bytes_transferred

			// Handle accept extra data
			switch _ in entry.operation {
			case Submission_Op_Accept:
				op := entry.operation.(Submission_Op_Accept)
				if bytes_transferred >= 0 {
					// The client socket was created during submit
					// We need to get the client FD from the accept buffer
					local_addr: ^win.SOCKADDR
					local_len: win.INT
					remote_addr: ^win.SOCKADDR
					remote_len: win.INT
					win.GetAcceptExSockaddrs(
						&entry.accept_buf,
						0,
						size_of(win.sockaddr_in6) + 16,
						size_of(win.sockaddr_in6) + 16,
						&local_addr,
						&local_len,
						&remote_addr,
						&remote_len,
					)
					client_addr := _win_sockaddr_to_socket_address(
						(^win.SOCKADDR_STORAGE_LH)(remote_addr),
					)
					// Client FD: We don't directly have it here.
					// AcceptEx created the socket in submit. We store it as result=0 (success).
					completion.result = 0
					completion.extra = Completion_Extra_Accept{
						client_fd      = OS_FD_INVALID, // placeholder
						client_address = client_addr,
					}
				}

			case Submission_Op_Connect:
				completion.result = 0

			case Submission_Op_Close:
				completion.result = 0

			case Submission_Op_Read:
			case Submission_Op_Write:
			case Submission_Op_Send:
			case Submission_Op_Recv:
			case Submission_Op_Sendto:
			case Submission_Op_Recvfrom:
			}
		}

		entry.active = false
		count += 1
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
) -> (OS_FD, Backend_Error) {
	af: i32
	switch domain {
	case .AF_INET:  af = win.AF_INET
	case .AF_INET6: af = win.AF_INET6
	case .AF_UNIX:  af = win.AF_UNIX
	}

	st: i32
	switch socket_type {
	case .STREAM: st = win.SOCK_STREAM
	case .DGRAM:  st = win.SOCK_DGRAM
	}

	proto: i32
	switch protocol {
	case .DEFAULT: proto = 0
	case .TCP:     proto = win.IPPROTO_TCP
	case .UDP:     proto = win.IPPROTO_UDP
	}

	sock := win.WSASocketW(af, st, proto, nil, 0, win.WSA_FLAG_OVERLAPPED)
	if sock == win.INVALID_SOCKET {
		return OS_FD_INVALID, .System_Error
	}

	// Associate with IOCP
	_win_associate_handle(backend, win.HANDLE(sock))

	return OS_FD(sock), .None
}

@(private = "package")
_backend_control_bind :: proc(backend: ^Platform_Backend, fd: OS_FD, address: Socket_Address) -> Backend_Error {
	sockaddr, socklen := _win_socket_address_to_sockaddr(address)
	if win.bind(win.SOCKET(uintptr(fd)), (^win.SOCKADDR)(&sockaddr), socklen) == win.SOCKET_ERROR {
		return .System_Error
	}
	return .None
}

@(private = "package")
_backend_control_listen :: proc(backend: ^Platform_Backend, fd: OS_FD, backlog: u32) -> Backend_Error {
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
		) == win.SOCKET_ERROR {
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
		) == win.SOCKET_ERROR {
			return .System_Error
		}
	}

	return .None
}

@(private = "package")
_backend_control_shutdown :: proc(backend: ^Platform_Backend, fd: OS_FD, how: Shutdown_How) -> Backend_Error {
	sd_how: i32
	switch how {
	case .SHUT_READER: sd_how = win.SD_RECEIVE
	case .SHUT_WRITER: sd_how = win.SD_SEND
	case .SHUT_BOTH:   sd_how = win.SD_BOTH
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
	case Submission_Op_Read:      return win.HANDLE(uintptr(op.fd))
	case Submission_Op_Write:     return win.HANDLE(uintptr(op.fd))
	case Submission_Op_Accept:    return win.HANDLE(uintptr(op.listen_fd))
	case Submission_Op_Connect:   return win.HANDLE(uintptr(op.socket_fd))
	case Submission_Op_Close:     return win.HANDLE(uintptr(op.fd))
	case Submission_Op_Send:      return win.HANDLE(uintptr(op.socket_fd))
	case Submission_Op_Recv:      return win.HANDLE(uintptr(op.socket_fd))
	case Submission_Op_Sendto:    return win.HANDLE(uintptr(op.socket_fd))
	case Submission_Op_Recvfrom:  return win.HANDLE(uintptr(op.socket_fd))
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
_win_push_error_completion :: proc(backend: ^Platform_Backend, token: Submission_Token, err: i32) {
	_win_push_completion(backend, token, i32(IO_ERR_RESOURCE_EXHAUSTED), nil)
}

@(private = "file")
_win_push_sync_completion :: proc(backend: ^Platform_Backend, entry: ^Win_Overlapped_Entry) {
	bytes := i32(uintptr(entry.overlapped.InternalHigh))
	_win_push_completion(backend, entry.token, bytes, nil)
	entry.active = false
}

@(private = "file")
_win_associate_handle :: proc(backend: ^Platform_Backend, handle: win.HANDLE) {
	// Check if already associated
	fd := OS_FD(uintptr(handle))
	for i in 0 ..< backend.associated_count {
		if backend.associated[i] == fd {
			return
		}
	}

	iocp := win.CreateIoCompletionPort(handle, backend.iocp, 0, 0)
	if iocp == backend.iocp && backend.associated_count < MAX_WIN_OVERLAPPED {
		backend.associated[backend.associated_count] = fd
		backend.associated_count += 1

		// Enable skip-on-success for synchronous completions
		cmode: u8 = 0
		cmode |= win.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
		cmode |= win.FILE_SKIP_SET_EVENT_ON_HANDLE
		win.SetFileCompletionNotificationModes(handle, cmode)
	}
}

@(private = "file")
_win_is_pending :: proc(err: win.INT) -> bool {
	return err == i32(win.System_Error.IO_PENDING) || err == i32(win.System_Error.WSAEWOULDBLOCK)
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

	win.bind(win.SOCKET(uintptr(fd)), (^win.SOCKADDR)(&bind_addr), bind_len)
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
) -> (win.SOCKADDR_STORAGE_LH, win.INT) {
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
		return Socket_Address_Inet4{
			address = transmute([4]u8)sa.sin_addr,
			port    = u16(u16be(sa.sin_port)),
		}
	case u16(win.AF_INET6):
		sa := (^win.sockaddr_in6)(native)
		return Socket_Address_Inet6{
			address = transmute([16]u8)sa.sin6_addr,
			port    = u16(u16be(sa.sin6_port)),
		}
	}
	return nil
}

@(private = "file")
_win_map_socket_level :: proc(level: Socket_Level) -> i32 {
	switch level {
	case .SOL_SOCKET:   return win.SOL_SOCKET
	case .IPPROTO_TCP:  return win.IPPROTO_TCP
	case .IPPROTO_UDP:  return win.IPPROTO_UDP
	case .IPPROTO_IPV6: return win.IPPROTO_IPV6
	}
	return 0
}

@(private = "file")
_win_map_socket_option :: proc(option: Socket_Option) -> i32 {
	switch option {
	case .SO_REUSEADDR:    return win.SO_REUSEADDR
	case .SO_REUSEPORT:    return win.SO_REUSEADDR // Windows uses REUSEADDR
	case .SO_KEEPALIVE:    return win.SO_KEEPALIVE
	case .SO_RCVBUF:       return win.SO_RCVBUF
	case .SO_SNDBUF:       return win.SO_SNDBUF
	case .SO_LINGER:       return win.SO_LINGER
	case .SO_BINDTODEVICE: return 0 // Not supported on Windows
	case .TCP_NODELAY:     return win.TCP_NODELAY
	case .TCP_CORK:        return 0 // Not supported on Windows
	case .TCP_NOPUSH:      return 0 // Not supported on Windows
	case .TCP_KEEPIDLE:    return 3 // TCP_KEEPIDLE
	case .TCP_KEEPINTVL:   return 17 // TCP_KEEPINTVL
	case .TCP_KEEPCNT:     return 16 // TCP_KEEPCNT
	case .IPV6_V6ONLY:     return win.IPV6_V6ONLY
	}
	return 0
}

} // when !TINA_SIM
