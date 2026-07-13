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
import "base:sanitizer"

_ :: sanitizer

when !TINA_SIMULATION_MODE {

	BACKEND_POOL_BUFFER_OWNED_AFTER_SUBMIT :: true
	MAX_WIN_OVERLAPPED :: 512

	// Derivation: up to REACTOR_SUBMISSION_BATCH_COUNT completions may arrive
	// synchronously during submit, and one IOCP harvest can dequeue up to
	// REACTOR_COMPLETION_BATCH_COUNT entries. Keep the staging capacity derived from
	// those configured bounds so the backend does not silently clamp the reactor.
	// The overflow path in _backend_collect buffers excess completions here when the
	// caller's output slice is smaller than the IOCP batch.
	// TODO: Consider exposing via Backend_Config if workloads require larger bursts.
	MAX_WIN_COMPLETED :: REACTOR_SUBMISSION_BATCH_COUNT + REACTOR_COMPLETION_BATCH_COUNT
	#assert(REACTOR_SUBMISSION_BATCH_COUNT <= MAX_WIN_OVERLAPPED)

	@(private = "package")
	_backend_boot_scratch_size :: #force_inline proc "contextless" (
		receive_slot_count: int,
		fd_slot_count: int,
	) -> int {
		return 0
	}
	#assert(REACTOR_SUBMISSION_BATCH_COUNT <= MAX_WIN_COMPLETED)

	@(private = "file")
	_win_map_socket_startup_error :: #force_inline proc "contextless" (error: i32) -> Backend_Error {
		switch error {
		case win.WSAEACCES:
			return .Permission_Denied
		case win.WSAEINVAL:
			return .Invalid_Argument
		case win.WSAEADDRINUSE:
			return .Address_In_Use
		case win.WSAEADDRNOTAVAIL:
			return .Address_Not_Available
		case win.WSAEAFNOSUPPORT, win.WSAEPROTONOSUPPORT, win.WSAESOCKTNOSUPPORT, win.WSAEOPNOTSUPP:
			return .Unsupported
		case win.WSAEMFILE, win.WSAENOBUFS:
			return .Resource_Exhausted
		case:
			return .System_Error
		}
	}
	#assert(REACTOR_COMPLETION_BATCH_COUNT <= MAX_WIN_COMPLETED)

	// TransmitFile (sendfile) — not in core:sys/windows, define locally.
	WSAID_TRANSMITFILE :: win.GUID{0xb5367df0, 0xcbac, 0x11cf, {0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92}}

	LPFN_TRANSMITFILE :: #type proc "stdcall" (
		hSocket: win.SOCKET,
		hFile: win.HANDLE,
		nNumberOfBytesToWrite: win.DWORD,
		nNumberOfBytesPerSend: win.DWORD,
		lpOverlapped: ^win.OVERLAPPED,
		lpTransmitBuffers: rawptr,
		dwReserved: win.DWORD,
	) -> win.BOOL

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
	Win_Overlapped_State :: enum u8 {
		Free,
		Prepared,
		In_Flight,
	}

	// The entry payload has one free-slot lifetime, while OVERLAPPED and op_data
	// gain a narrower kernel-owned lifetime after an operation becomes pending.
	Win_Overlapped_Entry_Payload :: struct {
		overlapped: win.OVERLAPPED,
		token:      Submission_Token,
		operation:  Submission_Operation,
		op_data:    Win_Op_Data,
	}

	Win_Overlapped_Entry :: struct {
		using payload: Win_Overlapped_Entry_Payload,
		state:         Win_Overlapped_State,
	}
	#assert(offset_of(Win_Overlapped_Entry, payload) == 0)
	#assert(offset_of(Win_Overlapped_Entry_Payload, overlapped) == 0)
	#assert(size_of(Win_Overlapped_Entry_Payload) % ASAN_POISON_GRANULE_SIZE == 0)
	#assert(offset_of(Win_Overlapped_Entry, state) >= size_of(Win_Overlapped_Entry_Payload))
	#assert(offset_of(Win_Overlapped_Entry_Payload, op_data) % ASAN_POISON_GRANULE_SIZE == 0)
	#assert(size_of(Win_Op_Data) % ASAN_POISON_GRANULE_SIZE == 0)

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
		accept_ex_ipv4:       win.LPFN_ACCEPTEX,
		accept_ex_ipv6:       win.LPFN_ACCEPTEX,
		connect_ex_ipv4:      win.LPFN_CONNECTEX,
		connect_ex_ipv6:      win.LPFN_CONNECTEX,
		transmit_file_ipv4:   LPFN_TRANSMITFILE,
		transmit_file_ipv6:   LPFN_TRANSMITFILE,
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
		backend.accept_ex_ipv4 = nil
		backend.accept_ex_ipv6 = nil
		backend.connect_ex_ipv4 = nil
		backend.connect_ex_ipv6 = nil
		backend.transmit_file_ipv4 = nil
		backend.transmit_file_ipv6 = nil

		for i in 0 ..< MAX_WIN_OVERLAPPED {
			backend.entries[i].state = .Free
		}

		// Extension pointers are provider-specific. Load each address-family
		// provider once at boot rather than issuing WSAIoctl on the data path.
		_win_load_extension_functions(backend, win.AF_INET)
		_win_load_extension_functions(backend, win.AF_INET6)
		when TINA_ASAN_POISONING {
			for i in 0 ..< MAX_WIN_OVERLAPPED {
				_sanitizer_address_poison_raw(
					rawptr(&backend.entries[i].payload),
					size_of(backend.entries[i].payload),
				)
			}
		}

		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			assert(backend.entries[i].state == .Free, "Windows backend teardown requires every entry release")
			when TINA_ASAN_POISONING {
				_sanitizer_address_unpoison_raw(
					rawptr(&backend.entries[i].payload),
					size_of(backend.entries[i].payload),
				)
			}
		}
		if backend.iocp != nil {
			win.CloseHandle(backend.iocp)
			backend.iocp = nil
		}
	}

	@(private = "package")
	_backend_quiesce_after_collect_fault :: proc(
		backend: ^Platform_Backend,
	) -> Backend_Quiesce_Result {
		// Closing IOCP does not prove that Windows has stopped touching each
		// OVERLAPPED and its buffers. Recovery is process-fatal while any such
		// ownership remains; reclaiming arena memory would permit corruption.
		for &entry in backend.entries {
			if entry.state == .In_Flight {
				return .Unproven
			}
		}
		_backend_deinit(backend)
		return .Quiesced
	}

	@(private = "package")
	_backend_submit :: proc(
		backend: ^Platform_Backend,
		submissions: []Submission,
	) -> Backend_Submit_Result {
		// All-or-error: pre-check overlapped entry capacity. Close is synchronous
		// and completes through backend.completed, so it must not consume an
		// OVERLAPPED entry or be rejected because the async entry pool is full.
		async_submission_count: i32 = 0
		for sub in submissions {
			switch _ in sub.operation {
			case Submission_Op_Close:
			case Submission_Op_Read,
			     Submission_Op_Write,
			     Submission_Op_Accept,
			     Submission_Op_Connect,
			     Submission_Op_Send,
			     Submission_Op_Recv,
			     Submission_Op_Sendto,
			     Submission_Op_Recvfrom,
			     Submission_Op_Sendfile:
				async_submission_count += 1
			}
		}

		available: i32 = 0
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			if backend.entries[i].state == .Free {
				available += 1
			}
		}
		if available < async_submission_count {
			return backend_submit_rejected(.Queue_Full)
		}
		// Every operation can complete immediately once ownership transfers.
		// Reserve that worst case before issuing the first kernel operation.
		if int(MAX_WIN_COMPLETED - backend.completed_count) < len(submissions) {
			return backend_submit_rejected(.Queue_Full)
		}

		for &sub in submissions {
			switch op in sub.operation {
			case Submission_Op_Close:
				_win_store_completion_assert(backend, sub.token, _win_close_fd_result(op.fd), nil)
				continue
			case Submission_Op_Read,
			     Submission_Op_Write,
			     Submission_Op_Accept,
			     Submission_Op_Connect,
			     Submission_Op_Send,
			     Submission_Op_Recv,
			     Submission_Op_Sendto,
			     Submission_Op_Recvfrom,
			     Submission_Op_Sendfile:
			}

			entry_index := _win_alloc_entry(backend)
			assert(entry_index >= 0, "Windows entry preflight must guarantee allocation")

			entry := &backend.entries[entry_index]
			assert(entry.state == .Prepared, "allocated Windows entry must be prepared")
			entry.token = sub.token
			entry.operation = sub.operation
			entry.overlapped = {}

			switch op in sub.operation {
			case Submission_Op_Read:
				entry.overlapped.Offset = win.DWORD(u64(op.offset) & 0xFFFFFFFF)
				entry.overlapped.OffsetHigh = win.DWORD(u64(op.offset) >> 32)
				ok := win.ReadFile(
					win.HANDLE(uintptr(op.fd)),
					sub.data_pointer,
					win.DWORD(sub.data_size),
					nil,
					&entry.overlapped,
				)
				if ok == win.FALSE {
					error := win.GetLastError()
					if error == win.ERROR_IO_PENDING {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				// Synchronous success with FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Write:
				entry.overlapped.Offset = win.DWORD(u64(op.offset) & 0xFFFFFFFF)
				entry.overlapped.OffsetHigh = win.DWORD(u64(op.offset) >> 32)
				ok := win.WriteFile(
					win.HANDLE(uintptr(op.fd)),
					sub.data_pointer,
					win.DWORD(sub.data_size),
					nil,
					&entry.overlapped,
				)
				if ok == win.FALSE {
					error := win.GetLastError()
					if error == win.ERROR_IO_PENDING {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Accept:
				is_pending := _win_submit_accept(backend, entry, &sub)
				if !is_pending do continue
				assert(entry.state == .Prepared, "pending AcceptEx must retain its prepared entry")
				_win_mark_entry_in_flight(entry)

			case Submission_Op_Connect:
				is_pending := _win_submit_connect(backend, entry, &sub)
				if !is_pending do continue
				assert(entry.state == .Prepared, "pending ConnectEx must retain its prepared entry")
				_win_mark_entry_in_flight(entry)

			case Submission_Op_Close:
				assert(false, "Close submissions complete synchronously before Win_Overlapped_Entry allocation")
				_win_release_entry(entry)
				continue

			case Submission_Op_Send:
				wsa_buf := win.WSABUF {
					len = win.ULONG(sub.data_size),
					buf = (^win.CHAR)(sub.data_pointer),
				}
				rc := win.WSASend(
					win.SOCKET(uintptr(op.fd_socket)),
					&wsa_buf,
					1,
					nil,
					0,
					(^win.WSAOVERLAPPED)(&entry.overlapped),
					nil,
				)
				if rc == win.SOCKET_ERROR {
					error := win.WSAGetLastError()
					if _win_is_pending(error) {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Recv:
				wsa_buf := win.WSABUF {
					len = win.ULONG(sub.data_size),
					buf = (^win.CHAR)(sub.data_pointer),
				}
				flags: win.DWORD = 0
				rc := win.WSARecv(
					win.SOCKET(uintptr(op.fd_socket)),
					&wsa_buf,
					1,
					nil,
					&flags,
					(^win.WSAOVERLAPPED)(&entry.overlapped),
					nil,
				)
				if rc == win.SOCKET_ERROR {
					error := win.WSAGetLastError()
					if _win_is_pending(error) {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Sendto:
				sockaddr, socklen := _win_socket_address_to_sockaddr(op.address)
				wsa_buf := win.WSABUF {
					len = win.ULONG(sub.data_size),
					buf = (^win.CHAR)(sub.data_pointer),
				}
				rc := win.WSASendTo(
					win.SOCKET(uintptr(op.fd_socket)),
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
					error := win.WSAGetLastError()
					if _win_is_pending(error) {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				_win_push_sync_completion(backend, entry)

			case Submission_Op_Recvfrom:
				wsa_buf := win.WSABUF {
					len = win.ULONG(sub.data_size),
					buf = (^win.CHAR)(sub.data_pointer),
				}
				flags: win.DWORD = 0
				entry.op_data.recvfrom.peer_address = {}
				entry.op_data.recvfrom.peer_address_len = win.INT(size_of(win.SOCKADDR_STORAGE_LH))
				rc := win.WSARecvFrom(
					win.SOCKET(uintptr(op.fd_socket)),
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
					error := win.WSAGetLastError()
					if _win_is_pending(error) {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				// Synchronous success — peer address is already in entry.op_data.recvfrom
				bytes := i32(uintptr(entry.overlapped.InternalHigh))
				_win_store_completion_assert(
					backend,
					entry.token,
					bytes,
					Completion_Extra_Recvfrom {
						peer_address = _win_sockaddr_to_socket_address(&entry.op_data.recvfrom.peer_address),
					},
				)
				_win_release_entry(entry)

			case Submission_Op_Sendfile:
				if op.size == 0 {
					_win_store_completion_assert(backend, sub.token, 0, nil)
					_win_release_entry(entry)
					continue
				}

				nbytes_to_send := op.size
				if op.size == SENDFILE_ALL_BYTES {
					nbytes_to_send = 0
				}

				entry.overlapped.Offset = win.DWORD(op.source_offset & 0xFFFFFFFF)
				entry.overlapped.OffsetHigh = win.DWORD(op.source_offset >> 32)

				transmit_file: LPFN_TRANSMITFILE
				socket_family := _win_socket_family(op.fd_socket)
				if socket_family == win.AF_INET {
					transmit_file = backend.transmit_file_ipv4
				} else if socket_family == win.AF_INET6 {
					transmit_file = backend.transmit_file_ipv6
				}
				if transmit_file == nil {
					_win_store_completion_assert(
						backend,
						sub.token,
						i32(IO_ERR_RESOURCE_EXHAUSTED),
						nil,
					)
					_win_release_entry(entry)
					continue
				}

				ok := transmit_file(
					win.SOCKET(uintptr(op.fd_socket)),
					win.HANDLE(uintptr(op.fd_file)),
					win.DWORD(nbytes_to_send),
					0,
					&entry.overlapped,
					nil,
					0,
				)
				if ok == win.FALSE {
					error := win.GetLastError()
					if error == win.ERROR_IO_PENDING {
						_win_mark_entry_in_flight(entry)
						continue
					}
					_win_push_error_completion(backend, sub.token, i32(error))
					_win_release_entry(entry)
					continue
				}
				_win_push_sync_completion(backend, entry)
			}
		}

		return backend_submit_accepted()
	}

	@(private = "package")
	_backend_collect :: proc(
		backend: ^Platform_Backend,
		completions: []Raw_Completion,
		timeout_ns: i64,
	) -> Backend_Collect_Result {
		count: u32 = 0

		// 1. Drain immediate completions
		for backend.completed_read < backend.completed_count {
			if count >= u32(len(completions)) {
				return Backend_Collect_Result{completion_count = count}
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
			return Backend_Collect_Result{completion_count = count}
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

		events: [REACTOR_COMPLETION_BATCH_COUNT]win.OVERLAPPED_ENTRY
		entries_removed: win.ULONG
		if !win.GetQueuedCompletionStatusEx(
			backend.iocp,
			&events[0],
			win.ULONG(len(events)),
			&entries_removed,
			timeout_ms,
			false,
		) {
			error := win.GetLastError()
			if error == win.WAIT_TIMEOUT || error == win.WAIT_IO_COMPLETION {
				return Backend_Collect_Result{completion_count = count}
			}
			return Backend_Collect_Result{completion_count = count, fault = .System_Error}
		}

		for i in 0 ..< entries_removed {
			event := &events[i]
			if event.lpOverlapped == nil {
				// Wake-up sentinel — skip
				continue
			}

			entry := _win_entry_from_overlapped(event.lpOverlapped)
			assert(entry.state == .In_Flight, "IOCP completion must reference an in-flight entry")
			_win_reclaim_entry(entry)

			raw: Raw_Completion
			raw.token = entry.token
			raw.extra = nil

			// Query the owning API so cancellation, connection, handle, and
			// permission failures remain distinguishable negative OS codes.
			bytes_transferred := i32(event.dwNumberOfBytesTransferred)
			raw.result = _win_overlapped_result(entry, event.dwNumberOfBytesTransferred)

			if raw.result >= 0 {

				// Handle operation-specific completion data
				switch _ in entry.operation {
				case Submission_Op_Accept:
					when TINA_RUNTIME_ASSERTIONS { _, da_ok := entry.operation.(Submission_Op_Accept); assert(da_ok, "Win_Op_Data.accept variant read on non-Accept entry — raw union would return corrupt client_fd/sockaddr from overlapping Recvfrom memory") }
					op := entry.operation.(Submission_Op_Accept)
					accept_fd := entry.op_data.accept.client_fd
					assert(accept_fd != OS_FD_INVALID, "completed accept entry must own a client socket")

					if bytes_transferred >= 0 {
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

						// The socket ownership transfers to the completion.
						entry.op_data.accept.client_fd = OS_FD_INVALID
					} else {
						// Error path: close the pre-created socket. The entry release
						// below will finish cleanup.
						win.closesocket(win.SOCKET(uintptr(accept_fd)))
						entry.op_data.accept.client_fd = OS_FD_INVALID
					}

				case Submission_Op_Connect:
					// Enable full socket API on ConnectEx-completed socket
					win.setsockopt(
						win.SOCKET(uintptr(
							entry.operation.(Submission_Op_Connect).fd_socket,
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
					when TINA_RUNTIME_ASSERTIONS { _, dr_ok := entry.operation.(Submission_Op_Recvfrom); assert(dr_ok, "Win_Op_Data.recvfrom variant read on non-Recvfrom entry — raw union would return corrupt peer_address from overlapping Accept memory") }
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
				case Submission_Op_Sendfile:
				}
			}

			_win_release_entry(entry)

			// Deliver to output slice, or buffer internally if output is full
			if count < u32(len(completions)) {
				completions[count] = raw
				count += 1
			} else {
				store_result := _win_push_completion(backend, raw.token, raw.result, raw.extra)
				assert(store_result == .Stored, "IOCP overflow capacity preflight is insufficient")
			}
		}

		return Backend_Collect_Result{completion_count = count}
	}

	@(private = "package")
	_backend_set_current_tick :: proc "contextless" (backend: ^Platform_Backend, tick_count: u64) {}

	@(private = "package")
	_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			entry := &backend.entries[i]
			if entry.state == .In_Flight && entry.token == token {
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
			return OS_FD_INVALID, _win_map_socket_startup_error(win.WSAGetLastError())
		}

		// Associate with IOCP at creation time — before any I/O submission.
		// If association fails, the socket cannot be used safely with this backend.
		associate_error := _win_associate_with_iocp(backend, win.HANDLE(sock))
		if associate_error != .None {
			win.closesocket(sock)
			return OS_FD_INVALID, associate_error
		}

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
			return _win_map_socket_startup_error(win.WSAGetLastError())
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
			return _win_map_socket_startup_error(win.WSAGetLastError())
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
		if opt == 0 {
			return .Unsupported
		}

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
		case Socket_Linger:
			lin := v
			if win.setsockopt(
				   win.SOCKET(uintptr(fd)),
				   sol,
				   opt,
				   (^win.CHAR)(&lin),
				   size_of(lin),
			   ) ==
			   win.SOCKET_ERROR {
				return .System_Error
			}
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
		sol := _win_map_socket_level(level)
		opt := _win_map_socket_option(option)

		// SO_LINGER requires an 8-byte struct; route separately to avoid buffer overflow
		if option == .SO_LINGER {
			lin: Socket_Linger
			lin_len := win.c_int(size_of(lin))
			if win.getsockopt(
				   win.SOCKET(uintptr(fd)),
				   sol,
				   opt,
				   (^win.CHAR)(&lin),
				   &lin_len,
			   ) ==
			   win.SOCKET_ERROR {
				return nil, .System_Error
			}
			return lin, .None
		}

		val: win.DWORD
		val_len := win.c_int(size_of(val))
		if win.getsockopt(
			   win.SOCKET(uintptr(fd)),
			   sol,
			   opt,
			   (^win.CHAR)(&val),
			   &val_len,
		   ) ==
		   win.SOCKET_ERROR {
			return nil, .System_Error
		}

		// Boolean options return bool, others return i32
		#partial switch option {
		case .SO_REUSEADDR, .SO_KEEPALIVE, .TCP_NODELAY, .IPV6_V6ONLY, .SO_EXCLUSIVEADDRUSE:
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
	_backend_control_close :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
		flags: win.DWORD
		if !win.GetHandleInformation(win.HANDLE(uintptr(fd)), &flags) {
			return .Invalid_Argument
		}
		if win.closesocket(win.SOCKET(uintptr(fd))) == win.SOCKET_ERROR {
			if !win.CloseHandle(win.HANDLE(uintptr(fd))) {
				return .System_Error
			}
		}
		return .None
	}

	@(private = "package")
	_backend_control_dup :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> (
		OS_FD,
		Backend_Error,
	) {
		return OS_FD_INVALID, .Unsupported
	}

	@(private = "package")
	_backend_register_fixed_fd :: proc "contextless" (backend: ^Platform_Backend, slot_index: u16, fd: OS_FD) -> Backend_Fixed_File_Update_Result {
		// No-op: IOCP has no fixed-file table.
		return .Optimization_Disabled
	}

	@(private = "package")
	_backend_unregister_fixed_fd :: proc "contextless" (backend: ^Platform_Backend, slot_index: u16) -> Backend_Fixed_File_Update_Result {
		// No-op: IOCP has no fixed-file table.
		return .Optimization_Disabled
	}

	@(test)
	test_windows_backend_control_dup_unsupported :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {queue_size = DEFAULT_BACKEND_QUEUE_SIZE}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		dup_fd, dup_error := backend_control_dup(&backend, OS_FD(42))
		testing.expect_value(t, dup_fd, OS_FD_INVALID)
		testing.expect_value(t, dup_error, Backend_Error.Unsupported)
	}

	// ============================================================================
	// Accept/Connect Submit Helpers
	// ============================================================================

	// Create the accept socket and start AcceptEx. Pending operations retain the
	// prepared entry; every synchronous result releases it before returning.
	@(private = "file")
	_win_submit_accept :: proc(
		backend: ^Platform_Backend,
		entry: ^Win_Overlapped_Entry,
		sub: ^Submission,
	) -> bool {
		op := sub.operation.(Submission_Op_Accept)
		entry.op_data.accept.client_fd = OS_FD_INVALID
		address_family := _win_socket_family(op.listen_fd)
		accept_ex: win.LPFN_ACCEPTEX
		if address_family == win.AF_INET {
			accept_ex = backend.accept_ex_ipv4
		} else if address_family == win.AF_INET6 {
			accept_ex = backend.accept_ex_ipv6
		}

		client_sock := win.WSASocketW(
			address_family,
			win.SOCK_STREAM,
			win.IPPROTO_TCP,
			nil,
			0,
			win.WSA_FLAG_OVERLAPPED,
		)
		if client_sock == win.INVALID_SOCKET {
			_win_push_error_completion(backend, sub.token, i32(win.WSAGetLastError()))
			_win_release_entry(entry)
			return false
		}
		entry.op_data.accept.client_fd = OS_FD(client_sock)

		associate_error := _win_associate_with_iocp(backend, win.HANDLE(client_sock))
		if associate_error != .None {
			win.closesocket(client_sock)
			entry.op_data.accept.client_fd = OS_FD_INVALID
			_win_push_error_completion(backend, sub.token, i32(associate_error))
			_win_release_entry(entry)
			return false
		}

		if accept_ex == nil {
			_win_store_completion_assert(backend, sub.token, i32(IO_ERR_RESOURCE_EXHAUSTED), nil)
			win.closesocket(client_sock)
			entry.op_data.accept.client_fd = OS_FD_INVALID
			_win_release_entry(entry)
			return false
		}

		received: win.DWORD
		ok := accept_ex(
			win.SOCKET(uintptr(op.listen_fd)),
			client_sock,
			&entry.op_data.accept.buf,
			0,
			size_of(win.sockaddr_in6) + 16,
			size_of(win.sockaddr_in6) + 16,
			&received,
			&entry.overlapped,
		)

		if ok == win.FALSE {
			error := win.GetLastError()
			if error == win.ERROR_IO_PENDING {
				return true
			}
			win.closesocket(client_sock)
			entry.op_data.accept.client_fd = OS_FD_INVALID
			_win_push_error_completion(backend, sub.token, i32(error))
			_win_release_entry(entry)
			return false
		}

		_win_complete_accept_success(backend, entry)
		return false
	}

	// Bind the socket for ConnectEx if needed, then start ConnectEx.
	@(private = "file")
	_win_submit_connect :: proc(
		backend: ^Platform_Backend,
		entry: ^Win_Overlapped_Entry,
		sub: ^Submission,
	) -> bool {
		op := sub.operation.(Submission_Op_Connect)
		connect_ex := backend.connect_ex_ipv4
		#partial switch _ in op.address {
		case Socket_Address_Inet6:
			connect_ex = backend.connect_ex_ipv6
		}

		// ConnectEx requires the socket to be bound first
		_win_bind_for_connect(op.fd_socket, op.address)

		sockaddr, socklen := _win_socket_address_to_sockaddr(op.address)
		if connect_ex == nil {
			_win_store_completion_assert(backend, sub.token, i32(IO_ERR_RESOURCE_EXHAUSTED), nil)
			_win_release_entry(entry)
			return false
		}

		ok := connect_ex(
			win.SOCKET(uintptr(op.fd_socket)),
			&sockaddr,
			socklen,
			nil,
			0,
			nil,
			&entry.overlapped,
		)

		if ok == win.FALSE {
			error := win.GetLastError()
			if error == win.ERROR_IO_PENDING {
				return true
			}
			_win_push_error_completion(backend, sub.token, i32(error))
			_win_release_entry(entry)
			return false
		}

		_win_complete_connect_success(backend, entry)
		return false
	}

	// Release an overlapped entry and any resources it owns. For accept entries,
	// close the client socket if it was not transferred to a completion.
	@(private = "file")
	_win_release_entry :: proc(entry: ^Win_Overlapped_Entry) {
		assert(entry.state == .Prepared, "only a prepared Windows entry can be released")

		switch _ in entry.operation {
		case Submission_Op_Accept:
			if entry.op_data.accept.client_fd != OS_FD_INVALID {
				win.closesocket(win.SOCKET(uintptr(entry.op_data.accept.client_fd)))
				entry.op_data.accept.client_fd = OS_FD_INVALID
			}
		case Submission_Op_Read,
		     Submission_Op_Write,
		     Submission_Op_Connect,
		     Submission_Op_Close,
		     Submission_Op_Send,
		     Submission_Op_Recv,
		     Submission_Op_Sendto,
		     Submission_Op_Recvfrom,
		     Submission_Op_Sendfile:
			// No platform resources to release beyond the entry itself.
		}

		entry.state = .Free
		_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))
	}

	// ============================================================================
	// Internal Helpers
	// ============================================================================

	@(private = "file")
	_win_alloc_entry :: proc(backend: ^Platform_Backend) -> i32 {
		for i in 0 ..< MAX_WIN_OVERLAPPED {
			if backend.entries[i].state == .Free {
				_sanitizer_address_unpoison_raw(
					rawptr(&backend.entries[i].payload),
					size_of(backend.entries[i].payload),
				)
				backend.entries[i].state = .Prepared
				return i32(i)
			}
		}
		return -1
	}

	@(private = "file")
	_win_mark_entry_in_flight :: #force_inline proc "contextless" (entry: ^Win_Overlapped_Entry) {
		_sanitizer_address_poison_raw(rawptr(&entry.overlapped), size_of(entry.overlapped))
		// Freezing the raw union for every operation keeps one ownership rule;
		// AcceptEx and WSARecvFrom are the variants the kernel actually writes.
		_sanitizer_address_poison_raw(rawptr(&entry.op_data), size_of(entry.op_data))
		entry.state = .In_Flight
	}

	@(private = "file")
	_win_reclaim_entry :: #force_inline proc "contextless" (entry: ^Win_Overlapped_Entry) {
		_sanitizer_address_unpoison_raw(rawptr(&entry.overlapped), size_of(entry.overlapped))
		_sanitizer_address_unpoison_raw(rawptr(&entry.op_data), size_of(entry.op_data))
		entry.state = .Prepared
	}

	@(private = "file")
	_win_entry_from_overlapped :: proc(
		overlapped: ^win.OVERLAPPED,
	) -> ^Win_Overlapped_Entry {
		return cast(^Win_Overlapped_Entry)overlapped
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
			return win.HANDLE(uintptr(op.fd_socket))
		case Submission_Op_Close:
			assert(false, "Close submissions do not have IOCP entry handles")
			return win.INVALID_HANDLE_VALUE
		case Submission_Op_Send:
			return win.HANDLE(uintptr(op.fd_socket))
		case Submission_Op_Recv:
			return win.HANDLE(uintptr(op.fd_socket))
		case Submission_Op_Sendto:
			return win.HANDLE(uintptr(op.fd_socket))
		case Submission_Op_Recvfrom:
			return win.HANDLE(uintptr(op.fd_socket))
		case Submission_Op_Sendfile:
			return win.HANDLE(uintptr(op.fd_socket))
		}
		return win.INVALID_HANDLE_VALUE
	}

	@(private = "file")
	_win_overlapped_result :: proc(
		entry: ^Win_Overlapped_Entry,
		bytes_transferred_event: win.DWORD,
	) -> i32 {
		bytes_transferred := bytes_transferred_event
		switch op in entry.operation {
		case Submission_Op_Read:
			handle := win.HANDLE(uintptr(op.fd))
			if win.GetOverlappedResult(
				handle,
				&entry.overlapped,
				&bytes_transferred,
				win.FALSE,
			) != win.FALSE {
				return i32(bytes_transferred)
			}
			return -i32(win.GetLastError())
		case Submission_Op_Write:
			handle := win.HANDLE(uintptr(op.fd))
			if win.GetOverlappedResult(
				handle,
				&entry.overlapped,
				&bytes_transferred,
				win.FALSE,
			) != win.FALSE {
				return i32(bytes_transferred)
			}
			return -i32(win.GetLastError())
		case Submission_Op_Accept,
		     Submission_Op_Connect,
		     Submission_Op_Send,
		     Submission_Op_Recv,
		     Submission_Op_Sendto,
		     Submission_Op_Recvfrom,
		     Submission_Op_Sendfile:
			flags: win.DWORD
			socket := win.SOCKET(uintptr(_win_entry_handle(entry)))
			if win.WSAGetOverlappedResult(
				socket,
				&entry.overlapped,
				&bytes_transferred,
				win.FALSE,
				&flags,
			) != win.FALSE {
				return i32(bytes_transferred)
			}
			return -i32(win.WSAGetLastError())
		case Submission_Op_Close:
			assert(false, "close submissions never own an OVERLAPPED entry")
			return i32(IO_ERR_BACKEND_FAILURE)
		}
		return i32(IO_ERR_BACKEND_FAILURE)
	}

	@(private = "file")
	_win_close_fd_result :: proc "contextless" (fd: OS_FD) -> i32 {
		if win.closesocket(win.SOCKET(uintptr(fd))) != win.SOCKET_ERROR {
			return 0
		}

		socket_error := win.WSAGetLastError()
		handle := win.HANDLE(uintptr(fd))
		flags: win.DWORD
		if win.GetHandleInformation(handle, &flags) == win.FALSE {
			if socket_error != win.WSAENOTSOCK {
				return -i32(socket_error)
			}
			return -i32(win.ERROR_INVALID_HANDLE)
		}

		if win.CloseHandle(handle) == win.FALSE {
			return -i32(win.GetLastError())
		}

		return 0
	}

	@(private = "file")
	_win_push_completion :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
		result: i32,
		extra: Completion_Extra,
	) -> Backend_Completion_Store_Result {
		if backend.completed_count < MAX_WIN_COMPLETED {
			c := &backend.completed[backend.completed_count]
			c.token = token
			c.result = result
			c.extra = extra
			backend.completed_count += 1
			return .Stored
		}
		return .Capacity_Exhausted
	}

	@(private = "file")
	_win_store_completion_assert :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
		result: i32,
		extra: Completion_Extra,
	) {
		store_result := _win_push_completion(backend, token, result, extra)
		assert(store_result == .Stored, "immediate completion capacity was preflighted")
	}

	@(private = "file")
	_win_push_error_completion :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
		error: i32,
	) {
		result := _win_push_completion(backend, token, -error, nil)
		assert(result == .Stored, "immediate error completion capacity was preflighted")
	}

	@(private = "file")
	_win_push_sync_completion :: proc(backend: ^Platform_Backend, entry: ^Win_Overlapped_Entry) {
		bytes := i32(uintptr(entry.overlapped.InternalHigh))
		result := _win_push_completion(backend, entry.token, bytes, nil)
		assert(result == .Stored, "immediate completion capacity was preflighted")
		_win_release_entry(entry)
	}

	// Synchronous AcceptEx success. The accepted socket was already associated
	// with IOCP in _win_submit_accept before AcceptEx was issued, so no
	// re-association is needed here. The invariant is: associate once at
	// creation time, never again.
	@(private = "file")
	_win_complete_accept_success :: proc(backend: ^Platform_Backend, entry: ^Win_Overlapped_Entry) {
		op := entry.operation.(Submission_Op_Accept)
		accept_fd := entry.op_data.accept.client_fd
		listen_socket := win.SOCKET(uintptr(op.listen_fd))
		win.setsockopt(
			win.SOCKET(uintptr(accept_fd)), win.SOL_SOCKET, win.SO_UPDATE_ACCEPT_CONTEXT,
			(^win.CHAR)(&listen_socket), size_of(listen_socket),
		)
		local_address, remote_address: ^win.sockaddr
		local_size, remote_size: win.INT
		win.GetAcceptExSockaddrs(
			&entry.op_data.accept.buf, 0, size_of(win.sockaddr_in6) + 16,
			size_of(win.sockaddr_in6) + 16, &local_address, &local_size,
			&remote_address, &remote_size,
		)
		result := _win_push_completion(backend, entry.token, 0, Completion_Extra_Accept {
			client_fd = accept_fd,
			client_address = _win_sockaddr_to_socket_address((^win.SOCKADDR_STORAGE_LH)(remote_address)),
		})
		assert(result == .Stored, "immediate accept completion capacity was preflighted")
		entry.op_data.accept.client_fd = OS_FD_INVALID
		_win_release_entry(entry)
	}

	@(private = "file")
	_win_complete_connect_success :: proc(backend: ^Platform_Backend, entry: ^Win_Overlapped_Entry) {
		op := entry.operation.(Submission_Op_Connect)
		win.setsockopt(
			win.SOCKET(uintptr(op.fd_socket)), win.SOL_SOCKET,
			win.SO_UPDATE_CONNECT_CONTEXT, nil, 0,
		)
		result := _win_push_completion(backend, entry.token, 0, nil)
		assert(result == .Stored, "immediate connect completion capacity was preflighted")
		_win_release_entry(entry)
	}

	// Associate a handle with IOCP and enable skip-on-success.
	// Called exactly once per FD at creation time (control_socket or accept completion).
	// Invariant: never called on an already-associated handle.
	//
	// Returns an error if either association or skip-on-success mode fails.
	// Skip-on-success is a semantic requirement of this backend: synchronous
	// completion paths in _backend_submit push the completion immediately, so
	// an IOCP completion for the same operation must not arrive later.
	@(private = "file")
	_win_associate_with_iocp :: proc(backend: ^Platform_Backend, handle: win.HANDLE) -> Backend_Error {
		if backend.iocp == nil {
			return .System_Error
		}

		port := win.CreateIoCompletionPort(handle, backend.iocp, 0, 0)
		if port == nil {
			return .System_Error
		}

		cmode: u8 = win.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS | win.FILE_SKIP_SET_EVENT_ON_HANDLE
		if win.SetFileCompletionNotificationModes(handle, cmode) == win.FALSE {
			return .System_Error
		}

		return .None
	}

	@(private = "file")
	_win_is_pending :: proc(error: win.INT) -> bool {
		return(
			error == i32(win.System_Error.IO_PENDING) ||
			error == i32(win.System_Error.WSAEWOULDBLOCK) \
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
	_win_load_extension_functions :: proc(backend: ^Platform_Backend, address_family: i32) {
		dummy := win.WSASocketW(
			address_family,
			win.SOCK_STREAM,
			win.IPPROTO_TCP,
			nil,
			0,
			win.WSA_FLAG_OVERLAPPED,
		)
		if dummy == win.INVALID_SOCKET {
			return
		}
		defer win.closesocket(dummy)

		if address_family == win.AF_INET {
			_win_load_socket_fn(dummy, win.WSAID_ACCEPTEX, &backend.accept_ex_ipv4)
			_win_load_socket_fn(dummy, win.WSAID_CONNECTEX, &backend.connect_ex_ipv4)
			_win_load_socket_fn(dummy, WSAID_TRANSMITFILE, &backend.transmit_file_ipv4)
		} else if address_family == win.AF_INET6 {
			_win_load_socket_fn(dummy, win.WSAID_ACCEPTEX, &backend.accept_ex_ipv6)
			_win_load_socket_fn(dummy, win.WSAID_CONNECTEX, &backend.connect_ex_ipv6)
			_win_load_socket_fn(dummy, WSAID_TRANSMITFILE, &backend.transmit_file_ipv6)
		}
	}

	@(private = "file")
	_win_socket_family :: proc "contextless" (fd: OS_FD) -> i32 {
		address: win.SOCKADDR_STORAGE_LH
		address_size := win.c_int(size_of(address))
		result := win.getsockname(win.SOCKET(uintptr(fd)), &address, &address_size)
		if result == win.SOCKET_ERROR {
			return 0
		}
		return i32(address.ss_family)
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
			return 0 // Windows has no SO_REUSEPORT equivalent
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
		case .SO_EXCLUSIVEADDRUSE:
			return win.SO_EXCLUSIVEADDRUSE
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
		case .TCP_DEFER_ACCEPT:
			return 0 // Linux-only; LSP noop on Windows
		case .TCP_NOTSENT_LOWAT:
			return 0 // POSIX-only; LSP noop on Windows
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
		error := backend_init(backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer { backend_deinit(backend); free(backend) }

		// Create a socket — IOCP association happens here
		fd, sock_error := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)
		testing.expect(t, fd != OS_FD_INVALID, "should get a valid socket")

		// Submit close — exercises the IOCP path (close is synchronous but goes through submit)
		token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Close_Complete)
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Close{fd = fd}},
		}
		sub_error := backend_submit(backend, submissions[:])
		testing.expect_value(t, sub_error.status, Backend_Submit_Status.Accepted)

		// Collect the close completion
		completions: [4]Raw_Completion
		collect_result := backend_collect(backend, completions[:], 0)
		count := collect_result.completion_count
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
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
			0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Accept_Complete,
		)
		accept_submissions := [1]Submission {
			{token = accept_token, operation = Submission_Op_Accept{listen_fd = listen_fd}},
		}
		backend_submit(backend, accept_submissions[:])

		// Connect a client socket to trigger the accept
		client_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		connect_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = bound_port}
		connect_token := submission_token_pack(
			0, 1, 0, 0, IO_SLOT_INDEX_NONE, .Connect_Complete,
		)
		connect_submissions := [1]Submission {
			{
				token = connect_token,
				operation = Submission_Op_Connect{fd_socket = client_fd, address = connect_address},
			},
		}
		backend_submit(backend, connect_submissions[:])

		// Collect both completions (accept + connect)
		completions: [8]Raw_Completion
		collected: u32 = 0
		accept_found := false
		connect_found := false

		for _ in 0 ..< 20 {
			collect_result := backend_collect(backend, completions[collected:], 50_000_000) // 50ms
			collected += collect_result.completion_count
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
			0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Connect_Complete,
		)
		submissions := [1]Submission {
			{
				token = token,
				operation = Submission_Op_Connect{fd_socket = client_fd, address = connect_address},
			},
		}
		backend_submit(backend, submissions[:])

		// Collect
		completions: [4]Raw_Completion
		collected: u32 = 0
		for _ in 0 ..< 10 {
			collect_result := backend_collect(backend, completions[collected:], 50_000_000)
			collected += collect_result.completion_count
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
		buffer_backing: [64 * 2]u8
		config := Backend_Config {
			queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
		}
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
			0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Accept_Complete,
		)
		accept_sub := [1]Submission {
			{token = accept_token, operation = Submission_Op_Accept{listen_fd = listen_fd}},
		}
		backend_submit(backend, accept_sub[:])

		// Connect
		client_fd, _ := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		connect_address := Socket_Address_Inet4{address = {127, 0, 0, 1}, port = bound_port}
		connect_token := submission_token_pack(
			0, 1, 0, 0, IO_SLOT_INDEX_NONE, .Connect_Complete,
		)
		connect_sub := [1]Submission {
			{
				token = connect_token,
				operation = Submission_Op_Connect{
					fd_socket = client_fd,
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
			collect_result := backend_collect(backend, completions[collected:], 50_000_000)
			collected += collect_result.completion_count
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
		copy(buffer_backing[0:4], send_data[:])
		send_token := submission_token_pack(
			0, 2, 0, 0, 0, .Send_Complete,
		)
		send_sub := [1]Submission {
			{
				token = send_token,
				data_pointer = &buffer_backing[0],
				data_size = 4,
				operation = Submission_Op_Send{
					fd_socket = client_fd,
				},
			},
		}

		recv_token := submission_token_pack(
			0, 3, 0, 0, 1, .Recv_Complete,
		)
		recv_sub := [1]Submission {
			{
				token = recv_token,
				data_pointer = &buffer_backing[64],
				data_size = 64,
				operation = Submission_Op_Recv{
					fd_socket = server_fd,
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
			collect_result := backend_collect(backend, completions[collected:], 50_000_000)
			collected += collect_result.completion_count
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
		testing.expect_value(t, buffer_backing[64], 0xDE)
		testing.expect_value(t, buffer_backing[65], 0xAD)
		testing.expect_value(t, buffer_backing[66], 0xBE)
		testing.expect_value(t, buffer_backing[67], 0xEF)

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
				0, u32(i), 0, 0, IO_SLOT_INDEX_NONE, .Close_Complete,
			)
			submissions := [1]Submission {
				{token = tokens[i], operation = Submission_Op_Close{fd = fd}},
			}
			backend_submit(backend, submissions[:])
		}

		// Collect with a 1-slot output slice — only 1 should be returned
		completions_small: [1]Raw_Completion
		result_first := backend_collect(backend, completions_small[:], 0)
		count_first := result_first.completion_count
		testing.expect_value(t, result_first.fault, Backend_Collect_Fault.None)
		testing.expect_value(t, count_first, 1)

		// Collect again — the remaining 2 should come from the internal buffer
		completions_rest: [4]Raw_Completion
		result_rest := backend_collect(backend, completions_rest[:], 0)
		count_rest := result_rest.completion_count
		testing.expect_value(t, result_rest.fault, Backend_Collect_Fault.None)
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

		// Submit close of an invalid FD — it must complete with a negative result
		// without using CloseHandle as a probe for random garbage handles.
		token := submission_token_pack(
			0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Close_Complete,
		)
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Close{fd = OS_FD(uintptr(0xDEADBEEF))}},
		}
		sub_error := backend_submit(backend, submissions[:])
		if !testing.expect_value(t, sub_error.status, Backend_Submit_Status.Accepted) do return
		if !testing.expect_value(t, backend.completed_count, u16(1)) do return
		testing.expect_value(t, backend.completed_read, u16(0))

		completions: [4]Raw_Completion
		count := backend_collect(backend, completions[:], 0).completion_count
		if !testing.expect(t, count >= 1, "close should produce a completion") do return
		testing.expect(t, completions[0].result < 0, "close of invalid FD should yield negative result")
	}

	when TINA_ASAN_POISONING {
		@(test)
		test_windows_overlapped_entry_lifetime_is_poisoned :: proc(t: ^testing.T) {
			backend: Platform_Backend
			entry := &backend.entries[0]
			entry.state = .Free
			_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))

			entry_index := _win_alloc_entry(&backend)
			testing.expect_value(t, entry_index, i32(0))
			entry.token = Submission_Token(1)
			entry.operation = Submission_Op_Read{}
			entry.overlapped = {}
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&entry.payload),
					size_of(entry.payload),
				) == nil,
				"prepared Windows entry payload must be addressable",
			)

			_win_mark_entry_in_flight(entry)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&entry.overlapped),
					size_of(entry.overlapped),
				) != nil,
				"kernel-owned OVERLAPPED must be poisoned",
			)
			testing.expect_value(t, entry.state, Win_Overlapped_State.In_Flight)

			_win_reclaim_entry(entry)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&entry.overlapped),
					size_of(entry.overlapped),
				) == nil,
				"completed OVERLAPPED must be addressable before result decoding",
			)
			_win_release_entry(entry)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&entry.payload),
					size_of(entry.payload),
				) != nil,
				"free Windows entry payload must be poisoned",
			)
			_sanitizer_address_unpoison_raw(rawptr(&entry.payload), size_of(entry.payload))
		}
	}

} // when !TINA_SIM
