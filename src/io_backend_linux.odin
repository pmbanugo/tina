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
import "core:mem"
import "core:sys/linux"
import "core:sys/linux/uring"
import "core:testing"
import "base:sanitizer"

_ :: sanitizer

when !TINA_SIMULATION_MODE {

	BACKEND_POOL_BUFFER_OWNED_AFTER_SUBMIT :: true
	MAX_LINUX_UNQUEUED :: 256
	MAX_LINUX_PENDING_ADDRS :: REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT
	MAX_LINUX_SENDFILE_ENTRIES :: REACTOR_LINUX_SENDFILE_ENTRY_COUNT
	MAX_LINUX_COMPLETED :: REACTOR_SUBMISSION_BATCH_COUNT + REACTOR_COMPLETION_BATCH_COUNT
	LINUX_SENDFILE_CHUNK_SIZE :: 1024 * 1024
	LINUX_SENDFILE_DRAIN_BUFFER_SIZE :: 4096
	LINUX_QUIESCE_POLL_COUNT_MAX :: 4096
	LINUX_QUIESCE_POLL_TIMEOUT_NS :: 1_000_000
	LINUX_ASYNC_CANCEL_ALL :: u32(1 << 0)
	LINUX_ASYNC_CANCEL_ANY :: u32(1 << 2)
	#assert(REACTOR_SUBMISSION_BATCH_COUNT <= MAX_LINUX_UNQUEUED)
	#assert(REACTOR_COMPLETION_BATCH_COUNT <= MAX_LINUX_COMPLETED)
	#assert(REACTOR_LINUX_SENDFILE_ENTRY_COUNT <= int(max(u16)))
	#assert(LINUX_SENDFILE_CHUNK_SIZE % LINUX_SENDFILE_DRAIN_BUFFER_SIZE == 0)

	@(private = "package")
	_backend_boot_scratch_size :: #force_inline proc "contextless" (
		receive_slot_count: int,
		fd_slot_count: int,
	) -> int {
		buffer_scratch_size := receive_slot_count * size_of(linux.IO_Vec)
		fixed_file_count := min(fd_slot_count, REACTOR_LINUX_FIXED_FILE_REGISTER_MAX)
		fixed_file_scratch_size := fixed_file_count * size_of(linux.Fd)
		// Registration calls are sequential, so one region serves whichever
		// platform ABI array has the larger byte requirement.
		return max(buffer_scratch_size, fixed_file_scratch_size)
	}

	@(private = "file")
	_linux_map_socket_startup_error :: #force_inline proc "contextless" (error: linux.Errno) -> Backend_Error {
		#partial switch error {
		case .EACCES, .EPERM:
			return .Permission_Denied
		case .EINVAL:
			return .Invalid_Argument
		case .EADDRINUSE:
			return .Address_In_Use
		case .EADDRNOTAVAIL:
			return .Address_Not_Available
		case .EAFNOSUPPORT, .EPROTONOSUPPORT, .ESOCKTNOSUPPORT, .EOPNOTSUPP:
			return .Unsupported
		case .EMFILE, .ENFILE, .ENOBUFS, .ENOMEM:
			return .Resource_Exhausted
		case:
			return .System_Error
		}
	}

	Linux_Pending_Addr_State :: enum u8 {
		Free,
		In_Use,
	}

	// The kernel-retained fields form one ASan ownership region. Field promotion
	// keeps the syscall construction readable without changing the layout.
	Pending_Addr_Entry_Payload :: struct {
		sockaddr:     linux.Sock_Addr_Any,
		sockaddr_len: i32,
		msghdr:       linux.Msg_Hdr,
		iovec:        linux.IO_Vec,
	}

	// Persistent storage for io_uring operations that need stable pointers
	// (accept, connect, sendto, recvfrom). Allocated on submit, freed on CQE.
	Pending_Addr_Entry :: struct {
		token:         Submission_Token,
		using payload: Pending_Addr_Entry_Payload,
		state:         Linux_Pending_Addr_State,
	}
	#assert(offset_of(Pending_Addr_Entry, payload) % ASAN_POISON_GRANULE_SIZE == 0)
	#assert(size_of(Pending_Addr_Entry_Payload) % ASAN_POISON_GRANULE_SIZE == 0)

	Linux_Sendfile_State :: enum u8 {
		Free,
		File_To_Pipe,
		Pipe_To_Socket,
	}

	Linux_User_Data_Tag :: enum u8 {
		Wake           = 0x80,
		Cancel         = 0x81,
		Sendfile       = 0x82,
		Quiesce_Cancel = 0x83,
	}

	Linux_Sendfile_User_Data_Phase :: enum u8 {
		File_To_Pipe,
		Pipe_To_Socket,
	}

	// Operation fields expire on release, while pipe descriptors and reuse
	// identity remain valid for the full backend lifetime.
	Sendfile_Entry_Payload :: struct {
		token:             Submission_Token,
		fd_file:           OS_FD,
		fd_socket:         OS_FD,
		socket_fixed_index: u16,
		source_offset:     u64,
		size_remaining:    u32,
		bytes_in_pipe:     u32,
		bytes_sent_total:  u32,
	}

	Sendfile_Entry :: struct {
		using payload: Sendfile_Entry_Payload,
		pipe_read_fd:  linux.Fd,
		pipe_write_fd: linux.Fd,
		generation:    u32,
		entry_index:   u16,
		state:         Linux_Sendfile_State,
	}
	#assert(offset_of(Sendfile_Entry, payload) == 0)
	#assert(size_of(Sendfile_Entry_Payload) % ASAN_POISON_GRANULE_SIZE == 0)

	LINUX_USER_DATA_TAG_SHIFT :: 56
	LINUX_USER_DATA_ENTRY_INDEX_SHIFT :: 40
	LINUX_USER_DATA_PHASE_SHIFT :: 32
	LINUX_USER_DATA_LOW_BITS_MASK :: u64(0x00FF_FFFF_FFFF_FFFF)
	_linux_user_data_is_internal :: #force_inline proc "contextless" (user_data: u64) -> bool {
		return u8(user_data >> LINUX_USER_DATA_TAG_SHIFT) >= 0x80
	}

	_linux_user_data_tag :: #force_inline proc "contextless" (user_data: u64) -> Linux_User_Data_Tag {
		return Linux_User_Data_Tag(u8(user_data >> LINUX_USER_DATA_TAG_SHIFT))
	}

	_linux_user_data_pack_wake :: #force_inline proc "contextless" () -> u64 {
		return u64(Linux_User_Data_Tag.Wake) << LINUX_USER_DATA_TAG_SHIFT
	}

	_linux_user_data_pack_cancel :: #force_inline proc "contextless" (token: Submission_Token) -> u64 {
		return (u64(Linux_User_Data_Tag.Cancel) << LINUX_USER_DATA_TAG_SHIFT) |
		       (u64(token) & LINUX_USER_DATA_LOW_BITS_MASK)
	}

	_linux_user_data_pack_sendfile :: #force_inline proc "contextless" (
		entry_index: u16,
		phase: Linux_Sendfile_User_Data_Phase,
		generation: u32,
	) -> u64 {
		return (u64(Linux_User_Data_Tag.Sendfile) << LINUX_USER_DATA_TAG_SHIFT) |
		       (u64(entry_index) << LINUX_USER_DATA_ENTRY_INDEX_SHIFT) |
		       (u64(phase) << LINUX_USER_DATA_PHASE_SHIFT) |
		       u64(generation)
	}

	_linux_user_data_unpack_sendfile :: #force_inline proc "contextless" (
		user_data: u64,
	) -> (
		entry_index: u16,
		phase: Linux_Sendfile_User_Data_Phase,
		generation: u32,
	) {
		entry_index = u16(user_data >> LINUX_USER_DATA_ENTRY_INDEX_SHIFT)
		phase = Linux_Sendfile_User_Data_Phase(u8(user_data >> LINUX_USER_DATA_PHASE_SHIFT))
		generation = u32(user_data)
		return
	}

	_Platform_State :: struct {
		ring:                         uring.Ring,
		backing_memory_base:          [^]u8,
		backing_memory_slot_size:     u32,
		backing_memory_slot_count:    u16,
		fixed_fd_count:               u16,
		wake_fd:                      OS_FD,
		wake_buffer:                  u64,
		unqueued:                     [MAX_LINUX_UNQUEUED]Submission,
		completed:                    [MAX_LINUX_COMPLETED]Raw_Completion,
		unqueued_count:               u16,
		completed_count:              u16,
		completed_read:               u16,
		addr_entry_count_in_use:      u16,
		sendfile_entry_count_in_use:  u16,
		kernel_operation_count:       u32,
		buffers_registered:           bool,
		files_registered:             bool,
		addr_entries:                 [MAX_LINUX_PENDING_ADDRS]Pending_Addr_Entry,
		sendfile_entries:             [MAX_LINUX_SENDFILE_ENTRIES]Sendfile_Entry,
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

		wakefd, wakefd_error := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
		if wakefd_error != nil {
			uring.destroy(&backend.ring)
			return .System_Error
		}
		backend.wake_fd = OS_FD(wakefd)
		backend.backing_memory_base = config.backing_memory_base
		backend.backing_memory_slot_size = config.backing_memory_slot_size
		backend.backing_memory_slot_count = config.backing_memory_slot_count
		backend.unqueued_count = 0
		backend.completed_count = 0
		backend.completed_read = 0
		backend.addr_entry_count_in_use = 0
		backend.sendfile_entry_count_in_use = 0
		backend.kernel_operation_count = 0
		backend.buffers_registered = false

		for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
			backend.addr_entries[i].state = .Free
		}

		// Pre-create pipe pairs for sendfile splice state machine.
		// Each entry gets a dedicated pipe so concurrent sendfile ops never mix data.
		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			backend.sendfile_entries[i].state = .Free
			pipes: [2]linux.Fd
			pipe_error := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
			if pipe_error != nil {
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

		when TINA_ASAN_POISONING {
			for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
				_sanitizer_address_poison_raw(
					rawptr(&backend.addr_entries[i].payload),
					size_of(backend.addr_entries[i].payload),
				)
			}
			for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
				_sanitizer_address_poison_raw(
					rawptr(&backend.sendfile_entries[i].payload),
					size_of(backend.sendfile_entries[i].payload),
				)
			}
		}

		assert(_linux_arm_wake(backend), "linux backend must permanently arm its wake read")

		// Registered buffers (§6.6.2 §8): register buffer pool memory with io_uring.
		// This eliminates get_user_pages per-operation cost for pre-allocated pool buffers.
		// The reactor's buffer pool is pre-allocated at Shard init and stable for the
		// Shard's lifetime, making it an ideal fit for kernel page-pinning.
		buffer_scratch_size := int(config.backing_memory_slot_count) * size_of(linux.IO_Vec)
		if config.backing_memory_base != nil &&
		   config.backing_memory_slot_count > 0 &&
		   len(config.boot_scratch) >= buffer_scratch_size {
			backend.buffers_registered = _linux_register_buffers(
				backend,
				config.backing_memory_base,
				config.backing_memory_slot_size,
				config.backing_memory_slot_count,
				config.boot_scratch[:buffer_scratch_size],
			)
			if !backend.buffers_registered {
				fmt.eprintfln(
					"[WARN] io_uring buffer registration failed for %d slots. Falling back to standard READ/WRITE ops.",
					config.backing_memory_slot_count,
				)
			}
		}

		// Fixed files are optional. Configurations larger than the bounded
		// registration optimization continue with raw descriptors.
		fixed_file_scratch_size := int(config.fd_slot_count) * size_of(linux.Fd)
		fixed_file_count_supported := int(config.fd_slot_count) <= REACTOR_LINUX_FIXED_FILE_REGISTER_MAX
		if config.fd_slot_count > 0 &&
		   fixed_file_count_supported &&
		   len(config.boot_scratch) >= fixed_file_scratch_size {
			backend.files_registered = _linux_register_fixed_files(
				backend,
				config.fd_slot_count,
				config.boot_scratch[:fixed_file_scratch_size],
			)
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
		result := _linux_quiesce_and_deinit(backend)
		assert(result == .Quiesced, "linux backend deinit must prove that kernel ownership ended")
	}

	@(private = "file")
	_linux_deinit_quiesced :: proc(backend: ^Platform_Backend) {
		assert(backend.kernel_operation_count == 0, "io_uring teardown requires every SQE completion")
		assert(backend.addr_entry_count_in_use == 0, "io_uring teardown requires every address entry release")
		assert(backend.sendfile_entry_count_in_use == 0, "io_uring teardown requires every sendfile entry release")
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
			when TINA_ASAN_POISONING {
				_sanitizer_address_unpoison_raw(
					rawptr(&backend.sendfile_entries[i].payload),
					size_of(backend.sendfile_entries[i].payload),
				)
			}
			backend.sendfile_entries[i].state = .Free
		}
		when TINA_ASAN_POISONING {
			for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
				_sanitizer_address_unpoison_raw(
					rawptr(&backend.addr_entries[i].payload),
					size_of(backend.addr_entries[i].payload),
				)
			}
		}
		linux.close(linux.Fd(backend.wake_fd))
		uring.destroy(&backend.ring)
		backend.unqueued_count = 0
		backend.completed_count = 0
		backend.completed_read = 0
		backend.addr_entry_count_in_use = 0
		backend.sendfile_entry_count_in_use = 0
		backend.kernel_operation_count = 0
	}

	@(private = "package")
	_backend_quiesce_after_collect_fault :: proc(
		backend: ^Platform_Backend,
	) -> Backend_Quiesce_Result {
		return _linux_quiesce_and_deinit(backend)
	}

	@(private = "file")
	_linux_account_operation_submitted :: #force_inline proc(
		backend: ^Platform_Backend,
	) {
		when TINA_RUNTIME_ASSERTIONS {
			assert(backend.kernel_operation_count < max(u32), "io_uring operation ledger overflow")
		}
		backend.kernel_operation_count += 1
	}

	@(private = "file")
	_linux_account_operation_completed :: #force_inline proc(
		backend: ^Platform_Backend,
	) {
		when TINA_RUNTIME_ASSERTIONS {
			assert(backend.kernel_operation_count > 0, "io_uring completion has no submitted operation")
		}
		backend.kernel_operation_count -= 1
	}

	@(private = "file")
	_linux_submit_one_accounted :: proc(
		backend: ^Platform_Backend,
		submission: ^Submission,
	) -> bool {
		if !_linux_submit_one(backend, submission) {
			return false
		}
		_linux_account_operation_submitted(backend)
		return true
	}

	@(private = "file")
	_linux_queue_quiesce_cancel :: proc(backend: ^Platform_Backend) -> bool {
		sqe, ok := uring.get_sqe(&backend.ring)
		if !ok {
			return false
		}
		sqe.opcode = .ASYNC_CANCEL
		sqe.addr = 0
		sqe.user_data = u64(Linux_User_Data_Tag.Quiesce_Cancel) << LINUX_USER_DATA_TAG_SHIFT
		sqe.cancel_flags = LINUX_ASYNC_CANCEL_ALL | LINUX_ASYNC_CANCEL_ANY
		_linux_account_operation_submitted(backend)
		return true
	}

	@(private = "file")
	_linux_dispose_quiesce_sendfile_cqe :: proc(
		backend: ^Platform_Backend,
		cqe: ^linux.IO_Uring_CQE,
	) {
		entry_index, phase, generation := _linux_user_data_unpack_sendfile(cqe.user_data)
		assert(int(entry_index) < MAX_LINUX_SENDFILE_ENTRIES, "sendfile CQE entry index exceeds pool capacity")
		entry := &backend.sendfile_entries[entry_index]
		if entry.state == .Free || entry.generation != generation {
			return
		}
		if cqe.res > 0 {
			bytes := u32(cqe.res)
			switch phase {
			case .File_To_Pipe:
				entry.bytes_in_pipe += bytes
			case .Pipe_To_Socket:
				assert(bytes <= entry.bytes_in_pipe, "sendfile completion exceeds pipe byte ledger")
				entry.bytes_in_pipe -= bytes
			}
		}
		if entry.bytes_in_pipe > 0 {
			_linux_discard_sendfile_pipe(entry)
		}
		_linux_release_sendfile_entry(backend, entry)
	}

	@(private = "file")
	_linux_dispose_quiesce_cqe :: proc(
		backend: ^Platform_Backend,
		cqe: ^linux.IO_Uring_CQE,
	) {
		_linux_account_operation_completed(backend)
		if _linux_user_data_is_internal(cqe.user_data) {
			if _linux_user_data_tag(cqe.user_data) == .Sendfile {
				_linux_dispose_quiesce_sendfile_cqe(backend, cqe)
			}
			return
		}

		token := Submission_Token(cqe.user_data)
		if submission_token_operation_kind(token) == .Accept_Complete && cqe.res >= 0 {
			_ = linux.close(linux.Fd(cqe.res))
		}
		entry := _linux_reclaim_addr_entry(backend, token)
		if entry != nil {
			_linux_release_addr_entry(backend, entry)
		}
	}

	@(private = "file")
	_linux_drain_quiesce_cqes :: proc(backend: ^Platform_Backend) {
		cqes: [REACTOR_COMPLETION_BATCH_COUNT]linux.IO_Uring_CQE
		for uring.cq_ready(&backend.ring) > 0 {
			completion_count := uring.copy_cqes_ready(&backend.ring, cqes[:])
			assert(completion_count > 0, "ready io_uring CQ must yield a completion")
			for completion_index in 0 ..< completion_count {
				_linux_dispose_quiesce_cqe(backend, &cqes[completion_index])
			}
		}
	}

	@(private = "file")
	_linux_quiesce_and_deinit :: proc(backend: ^Platform_Backend) -> Backend_Quiesce_Result {
		// Overflow submissions never reached the kernel, so dropping them cannot
		// race memory reclamation. Every SQE is instead retired by its CQE below.
		backend.unqueued_count = 0
		cancel_queued := false
		time_spec := linux.Time_Spec{time_nsec = LINUX_QUIESCE_POLL_TIMEOUT_NS}

		for _ in 0 ..< LINUX_QUIESCE_POLL_COUNT_MAX {
			if backend.kernel_operation_count == 0 {
				_linux_deinit_quiesced(backend)
				return .Quiesced
			}
			if !cancel_queued {
				cancel_queued = _linux_queue_quiesce_cancel(backend)
			}
			fault := _linux_submit_pending(backend, 1, &time_spec)
			if fault != .None {
				continue
			}
			_linux_drain_quiesce_cqes(backend)
			if backend.kernel_operation_count == 0 {
				_linux_deinit_quiesced(backend)
				return .Quiesced
			}
		}
		return .Unproven
	}

	@(private = "file")
	_linux_release_addr_entry :: #force_inline proc(
		backend: ^Platform_Backend,
		entry: ^Pending_Addr_Entry,
	) {
		assert(entry.state == .In_Use, "only an allocated Linux address entry can be released")
		entry.token = {}
		entry.state = .Free
		backend.addr_entry_count_in_use -= 1
		_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))
	}

	@(private = "file")
	_linux_release_sendfile_entry :: #force_inline proc "contextless" (
		backend: ^Platform_Backend,
		entry: ^Sendfile_Entry,
	) {
		if entry.state == .Free {
			return
		}
		entry.state = .Free
		backend.sendfile_entry_count_in_use -= 1
		_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))
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

		required_addr_entry_count := 0
		required_sendfile_entry_count := 0
		for &submission in submissions {
			switch _ in submission.operation {
			case Submission_Op_Accept,
			     Submission_Op_Connect,
			     Submission_Op_Sendto,
			     Submission_Op_Recvfrom:
				required_addr_entry_count += 1
			case Submission_Op_Sendfile:
				required_sendfile_entry_count += 1
			case Submission_Op_Read,
			     Submission_Op_Write,
			     Submission_Op_Close,
			     Submission_Op_Send,
			     Submission_Op_Recv:
			}
		}

		// Unqueued ops released their addr/sendfile entries when the SQ was
		// full, but they still need those entries when retried. Count their
		// demand so the preflight never accepts a batch that starves the
		// unqueued retry path.
		unqueued_addr_needs := 0
		unqueued_sendfile_needs := 0
		for i in 0 ..< backend.unqueued_count {
			switch _ in backend.unqueued[i].operation {
			case Submission_Op_Accept,
			     Submission_Op_Connect,
			     Submission_Op_Sendto,
			     Submission_Op_Recvfrom:
				unqueued_addr_needs += 1
			case Submission_Op_Sendfile:
				unqueued_sendfile_needs += 1
			case Submission_Op_Read,
			     Submission_Op_Write,
			     Submission_Op_Close,
			     Submission_Op_Send,
			     Submission_Op_Recv:
			}
		}
		if int(backend.addr_entry_count_in_use) + unqueued_addr_needs + required_addr_entry_count > MAX_LINUX_PENDING_ADDRS {
			return .Resource_Exhausted
		}
		if int(backend.sendfile_entry_count_in_use) + unqueued_sendfile_needs + required_sendfile_entry_count > MAX_LINUX_SENDFILE_ENTRIES {
			return .Resource_Exhausted
		}

		for &submission in submissions {
			if !_linux_submit_one_accounted(backend, &submission) {
				backend.unqueued[backend.unqueued_count] = submission
				backend.unqueued_count += 1
			}
		}

		// Flush SQEs to kernel
		// Ownership is committed above. A submit syscall fault leaves SQEs in the
		// ring for collect to retry; rejecting here would create dual ownership.
		uring.submit(&backend.ring, 0, nil)
		return .None
	}

	@(private = "file")
	_linux_submit_pending :: proc(
		backend: ^Platform_Backend,
		wait_number: u32,
		time_spec: ^linux.Time_Spec,
	) -> Backend_Collect_Fault {
		if uring.sq_ready(&backend.ring) == 0 && wait_number == 0 {
			return .None
		}

		_, submit_error := uring.submit(&backend.ring, wait_number, time_spec)
		if submit_error == nil ||
		   submit_error == .NONE ||
		   submit_error == .ETIME ||
		   submit_error == .EINTR {
			return .None
		}
		return .System_Error
	}

	@(private = "package")
	_backend_collect :: proc(
		backend: ^Platform_Backend,
		completions: []Raw_Completion,
		timeout_ns: i64,
	) -> Backend_Collect_Result {
		count: u32 = 0
		// Overflow work and SQ entries retained after a failed io_uring_enter
		// are accepted obligations, so expose both before any early return.
		_linux_flush_unqueued(backend)
		for backend.completed_read < backend.completed_count && count < u32(len(completions)) {
			completions[count] = backend.completed[backend.completed_read]
			backend.completed_read += 1
			count += 1
		}
		if backend.completed_read == backend.completed_count {
			backend.completed_read = 0
			backend.completed_count = 0
		}
		if count == u32(len(completions)) {
			fault := _linux_submit_pending(backend, 0, nil)
			return Backend_Collect_Result{completion_count = count, fault = fault}
		}

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

		fault := _linux_submit_pending(backend, wait_number, time_spec_pointer)
		if fault != .None {
			return Backend_Collect_Result{completion_count = count, fault = fault}
		}

		// Harvest CQEs. Keep the temporary harvest buffer aligned with the reactor
		// completion batch configuration so higher batch counts do not silently clamp.
		cqes: [REACTOR_COMPLETION_BATCH_COUNT]linux.IO_Uring_CQE = ---
		completed, cqe_error := uring.copy_cqes(&backend.ring, cqes[:u32(len(completions)) - count], 0)
		if cqe_error != nil && cqe_error != .NONE && cqe_error != .EINTR {
			return Backend_Collect_Result{completion_count = count, fault = .System_Error}
		}

		for i in 0 ..< completed {
			cqe := &cqes[i]
			_linux_account_operation_completed(backend)

			// Filter internal CQEs: cancel results (high bit set), wake reads, and sendfile splices
			if _linux_user_data_is_internal(cqe.user_data) {
				switch _linux_user_data_tag(cqe.user_data) {
				case .Wake:
					_linux_arm_wake(backend)
				case .Sendfile:
					count = _linux_handle_sendfile_cqe(backend, cqe, completions, count, u32(len(completions)))
				case .Cancel:
				case .Quiesce_Cancel:
				}
				continue
			}

			token := Submission_Token(cqe.user_data)

			completion := &completions[count]
			completion.token = token
			completion.flags = {}

			completion.result = cqe.res
			completion.extra = nil

			// Check for accept completion (res >= 0 means new FD)
			op_kind := submission_token_operation_kind(token)
			if op_kind == .Accept_Complete && cqe.res >= 0 {
				entry := _linux_reclaim_addr_entry(backend, token)
				if entry != nil {
					completion.extra = Completion_Extra_Accept {
						client_fd      = OS_FD(cqe.res),
						client_address = _linux_sockaddr_to_socket_address(&entry.sockaddr),
					}
					_linux_release_addr_entry(backend, entry)
				} else {
					completion.extra = Completion_Extra_Accept {
						client_fd = OS_FD(cqe.res),
					}
				}
				completion.result = 0
			} else if op_kind == .Recvfrom_Complete && cqe.res >= 0 {
				entry := _linux_reclaim_addr_entry(backend, token)
				if entry != nil {
					completion.extra = Completion_Extra_Recvfrom {
						peer_address = _linux_sockaddr_to_socket_address(&entry.sockaddr),
					}
					_linux_release_addr_entry(backend, entry)
				}
			} else {
				// Free addr entry for connect/sendto completions
				entry := _linux_reclaim_addr_entry(backend, token)
				if entry != nil {
					_linux_release_addr_entry(backend, entry)
				}
			}

			count += 1
		}

		return Backend_Collect_Result{completion_count = count}
	}

	@(private = "package")
	_backend_set_current_tick :: #force_inline proc "contextless" (backend: ^Platform_Backend, tick_count: u64) {}

	@(private = "package")
	_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
		// SQ-full submissions are accepted obligations but have not reached the
		// kernel. Cancel them locally so teardown cannot submit them afterwards.
		for submission_index: u16 = 0; submission_index < backend.unqueued_count; submission_index += 1 {
			if backend.unqueued[submission_index].token != token {
				continue
			}
			completion := Raw_Completion {
				token  = token,
				result = -i32(linux.Errno.ECANCELED),
				flags  = {.Synthesized},
			}
			if _linux_store_completion(backend, completion) != .Stored {
				return .Resource_Exhausted
			}
			backend.unqueued_count -= 1
			if submission_index < backend.unqueued_count {
				backend.unqueued[submission_index] = backend.unqueued[backend.unqueued_count]
			}
			return .None
		}

		// Use a distinct cancel user_data (token with high bit flipped)
		cancel_ud := _linux_user_data_pack_cancel(token)

		cancelled_any := false
		is_sendfile := false

		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			if backend.sendfile_entries[i].state != .Free && backend.sendfile_entries[i].token == token {
				is_sendfile = true

				generation := backend.sendfile_entries[i].generation
				ud_fp := _linux_user_data_pack_sendfile(u16(i), .File_To_Pipe, generation)
				ud_ps := _linux_user_data_pack_sendfile(u16(i), .Pipe_To_Socket, generation)

				_, ok1 := uring.async_cancel(&backend.ring, ud_fp, cancel_ud)
				if ok1 {
					_linux_account_operation_submitted(backend)
				}
				_, ok2 := uring.async_cancel(&backend.ring, ud_ps, cancel_ud)
				if ok2 {
					_linux_account_operation_submitted(backend)
				}

				cancelled_any = cancelled_any || ok1 || ok2
				break
			}
		}

		if !is_sendfile {
			_, ok := uring.async_cancel(&backend.ring, u64(token), cancel_ud)
			if ok {
				_linux_account_operation_submitted(backend)
			}
			cancelled_any = cancelled_any || ok
		}

		if !cancelled_any {
			return .Queue_Full
		}

		_, error := uring.submit(&backend.ring, 0, nil)
		if error != nil && error != .NONE {
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

		fd, error := linux.socket(af, st, sf, proto)
		if error != nil {
			return OS_FD_INVALID, _linux_map_socket_startup_error(error)
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

		error := linux.bind(linux.Fd(fd), &sockaddr)
		if error != nil {
			return _linux_map_socket_startup_error(error)
		}
		return .None
	}

	@(private = "package")
	_backend_control_listen :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		backlog: u32,
	) -> Backend_Error {
		error := linux.listen(linux.Fd(fd), i32(backlog))
		if error != nil {
			return _linux_map_socket_startup_error(error)
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
			sol = 1
		case .IPPROTO_TCP:
			sol = 6
		case .IPPROTO_UDP:
			sol = 17
		case .IPPROTO_IPV6:
			sol = 41
		}

		opt: i32
		switch option {
		case .SO_REUSEADDR:
			opt = 2
		case .SO_REUSEPORT:
			opt = 15
		case .SO_EXCLUSIVEADDRUSE:
			return .Unsupported
		case .SO_KEEPALIVE:
			opt = 9
		case .SO_RCVBUF:
			opt = 8
		case .SO_SNDBUF:
			opt = 7
		case .SO_LINGER:
			opt = 13
		case .SO_BINDTODEVICE:
			opt = 25
		case .TCP_NODELAY:
			opt = 1
		case .TCP_CORK:
			opt = 3
		case .TCP_NOPUSH:
			opt = 3 // TCP_NOPUSH (alias for CORK on Linux)
		case .TCP_KEEPIDLE:
			opt = 4
		case .TCP_KEEPINTVL:
			opt = 5
		case .TCP_KEEPCNT:
			opt = 6
		case .TCP_DEFER_ACCEPT:
			opt = 9
		case .TCP_NOTSENT_LOWAT:
			opt = 25
		case .IPV6_V6ONLY:
			opt = 26
		}

		switch v in value {
		case bool:
			int_val: i32 = 1 if v else 0
			error := linux.setsockopt_base(linux.Fd(fd), int(sol), int(opt), &int_val)
			if error != nil do return .System_Error
		case i32:
			int_val := v
			error := linux.setsockopt_base(linux.Fd(fd), int(sol), int(opt), &int_val)
			if error != nil do return .System_Error
		case Socket_Linger:
			lin := v
			error := linux.setsockopt_base(linux.Fd(fd), int(sol), int(opt), &lin)
			if error != nil do return .System_Error
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
			sol = 1
		case .IPPROTO_TCP:
			sol = 6
		case .IPPROTO_UDP:
			sol = 17
		case .IPPROTO_IPV6:
			sol = 41
		}

		opt: i32
		switch option {
		case .SO_REUSEADDR:
			opt = 2
		case .SO_REUSEPORT:
			opt = 15
		case .SO_EXCLUSIVEADDRUSE:
			return nil, .Unsupported
		case .SO_KEEPALIVE:
			opt = 9
		case .SO_RCVBUF:
			opt = 8
		case .SO_SNDBUF:
			opt = 7
		case .SO_LINGER:
			opt = 13
		case .SO_BINDTODEVICE:
			opt = 25
		case .TCP_NODELAY:
			opt = 1
		case .TCP_CORK:
			opt = 3
		case .TCP_NOPUSH:
			opt = 3 // TCP_NOPUSH (alias for CORK on Linux)
		case .TCP_KEEPIDLE:
			opt = 4
		case .TCP_KEEPINTVL:
			opt = 5
		case .TCP_KEEPCNT:
			opt = 6
		case .TCP_DEFER_ACCEPT:
			opt = 9
		case .TCP_NOTSENT_LOWAT:
			opt = 25
		case .IPV6_V6ONLY:
			opt = 26
		}

		// SO_LINGER requires an 8-byte struct; route it separately to avoid stack overflow
		if option == .SO_LINGER {
			lin: Socket_Linger
			_, error := linux.getsockopt_base(linux.Fd(fd), int(sol), linux.Socket_Option(opt), &lin)
			if error != nil do return nil, .System_Error
			return lin, .None
		}

		val: i32
		_, error := linux.getsockopt_base(linux.Fd(fd), int(sol), linux.Socket_Option(opt), &val)
		if error != nil {
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

		error := linux.shutdown(linux.Fd(fd), shutdown_how)
		if error != nil {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc "contextless" (
		backend: ^Platform_Backend,
		fd: OS_FD,
	) -> Backend_Error {
		error := linux.close(linux.Fd(fd))
		if error != nil {
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
		dup_fd, error := linux.fcntl_dupfd_cloexec(linux.Fd(fd), .DUPFD_CLOEXEC, 0)
		if error != nil {
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
			if backend.buffers_registered && buffer_index != IO_SLOT_INDEX_NONE {
				return _linux_submit_read_fixed(
					backend,
					ud,
					op,
					submission.data_pointer,
					buffer_index,
					submission.data_size,
					use_fixed,
					ffi,
				)
			}
			sqe, ok := uring.read(
				&backend.ring,
				ud,
				linux.Fd(op.fd),
				submission.data_pointer[:submission.data_size],
				u64(op.offset),
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Write:
			sqe, ok := uring.write(
				&backend.ring,
				ud,
				linux.Fd(op.fd),
				submission.data_pointer[:submission.data_size],
				u64(op.offset),
			)
			if ok && use_fixed {
				_linux_apply_fixed_file(sqe, ffi)
			}
			return ok

		case Submission_Op_Accept:
			entry := _linux_alloc_addr_entry(backend, submission.token)
			when TINA_RUNTIME_ASSERTIONS {
				assert(entry != nil, "linux accept requires a pending addr entry")
			}
			if entry == nil {
				return false
			}
			entry.sockaddr_len = size_of(entry.sockaddr)
			sqe, ok := uring.accept(
				&backend.ring,
				ud,
				linux.Fd(op.listen_fd),
				&entry.sockaddr,
				&entry.sockaddr_len,
				linux.Socket_FD_Flags{.NONBLOCK, .CLOEXEC},
			)
			if !ok {
				_linux_release_addr_entry(backend, entry)
			} else {
				when TINA_ASAN_POISONING {
					_linux_transfer_addr_entry_to_kernel(entry)
				}
			}
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
					_linux_release_addr_entry(backend, entry)
				} else {
					when TINA_ASAN_POISONING {
						_linux_transfer_addr_entry_to_kernel(entry)
					}
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
				submission.data_pointer[:submission.data_size],
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
				submission.data_pointer[:submission.data_size],
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
				base = submission.data_pointer,
				len  = uint(submission.data_size),
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
				_linux_release_addr_entry(backend, entry)
			} else {
				when TINA_ASAN_POISONING {
					_linux_transfer_addr_entry_to_kernel(entry)
				}
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
				base = submission.data_pointer,
				len  = uint(submission.data_size),
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
				_linux_release_addr_entry(backend, entry)
			} else {
				when TINA_ASAN_POISONING {
					_linux_transfer_addr_entry_to_kernel(entry)
				}
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
			entry.state = .File_To_Pipe

			if !_linux_submit_splice_file_to_pipe(backend, entry) {
				_linux_release_sendfile_entry(backend, entry)
				return false
			}
			return true
		}

		return false
	}

	// ============================================================================
	// Sendfile Splice State Machine
	// ============================================================================

	@(private = "file")
	_linux_alloc_sendfile_entry :: proc(backend: ^Platform_Backend) -> ^Sendfile_Entry {
		for i in 0 ..< MAX_LINUX_SENDFILE_ENTRIES {
			if backend.sendfile_entries[i].state == .Free {
				_sanitizer_address_unpoison_raw(
					rawptr(&backend.sendfile_entries[i].payload),
					size_of(backend.sendfile_entries[i].payload),
				)
				backend.sendfile_entries[i].state = .File_To_Pipe
				backend.sendfile_entry_count_in_use += 1
				backend.sendfile_entries[i].entry_index = u16(i)
				backend.sendfile_entries[i].generation += 1
				if backend.sendfile_entries[i].generation == 0 {
					backend.sendfile_entries[i].generation = 1
				}
				return &backend.sendfile_entries[i]
			}
		}
		return nil
	}

	// Phase 1: splice file → pipe. Reads from file at source_offset into the pipe write end.
	@(private = "file")
	_linux_submit_splice_file_to_pipe :: proc(backend: ^Platform_Backend, entry: ^Sendfile_Entry) -> bool {
		ud := _linux_user_data_pack_sendfile(
			entry.entry_index,
			.File_To_Pipe,
			entry.generation,
		)
		chunk := min(entry.size_remaining, LINUX_SENDFILE_CHUNK_SIZE)

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
		ud := _linux_user_data_pack_sendfile(
			entry.entry_index,
			.Pipe_To_Socket,
			entry.generation,
		)

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

	@(private = "file")
	_linux_submit_splice_file_to_pipe_accounted :: proc(
		backend: ^Platform_Backend,
		entry: ^Sendfile_Entry,
	) -> bool {
		if !_linux_submit_splice_file_to_pipe(backend, entry) {
			return false
		}
		_linux_account_operation_submitted(backend)
		return true
	}

	@(private = "file")
	_linux_submit_splice_pipe_to_socket_accounted :: proc(
		backend: ^Platform_Backend,
		entry: ^Sendfile_Entry,
	) -> bool {
		if !_linux_submit_splice_pipe_to_socket(backend, entry) {
			return false
		}
		_linux_account_operation_submitted(backend)
		return true
	}

	// Handle a CQE from an internal sendfile splice SQE.
	// Advances the state machine and may produce a user-visible completion.
	@(private = "file")
	_linux_handle_sendfile_cqe :: proc(
		backend: ^Platform_Backend,
		cqe: ^linux.IO_Uring_CQE,
		completions: []Raw_Completion,
		count: u32,
		output_max: u32,
	) -> u32 {
		entry_index, phase, generation := _linux_user_data_unpack_sendfile(cqe.user_data)
		assert(int(entry_index) < MAX_LINUX_SENDFILE_ENTRIES, "sendfile CQE entry index exceeds pool capacity")
		entry := &backend.sendfile_entries[entry_index]
		if generation != entry.generation {
			when TINA_RUNTIME_ASSERTIONS {
				assert(cqe.res == -i32(linux.Errno.ECANCELED), "stale sendfile CQE must be a cancellation")
			}
			return count
		}
		assert(entry.state != .Free, "sendfile CQE references a free entry")

		state_matches_phase := (entry.state == .File_To_Pipe && phase == .File_To_Pipe) ||
		                       (entry.state == .Pipe_To_Socket && phase == .Pipe_To_Socket)
		if !state_matches_phase {
			// Late cancel CQE for a phase that already completed. The state
			// machine advanced past this phase, so the cancel result is
			// irrelevant. A non-cancel result with a phase mismatch would be a
			// duplicate CQE — an invariant violation.
			when TINA_RUNTIME_ASSERTIONS {
				assert(cqe.res == -i32(linux.Errno.ECANCELED), "non-cancel sendfile CQE with phase mismatch is an invariant violation")
			}
			return count
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

			return _linux_complete_sendfile(backend, entry, completions, count, output_max, result)
		}

		bytes := u32(cqe.res)

		switch phase {
		case .File_To_Pipe:
			if bytes == 0 {
				// EOF — file shorter than expected at this offset
				if entry.bytes_in_pipe > 0 {
					// Drain remaining pipe contents to socket first
					entry.state = .Pipe_To_Socket
					if !_linux_submit_splice_pipe_to_socket_accounted(backend, entry) {
						return _linux_complete_sendfile(
							backend,
							entry,
							completions,
							count,
							output_max,
							i32(entry.bytes_sent_total),
						)
					}
				} else {
					return _linux_complete_sendfile(
						backend,
						entry,
						completions,
						count,
						output_max,
						i32(entry.bytes_sent_total),
					)
				}
				return count
			}

			entry.source_offset += u64(bytes)
			entry.size_remaining -= bytes
			entry.bytes_in_pipe += bytes

			// Now drain pipe → socket
			entry.state = .Pipe_To_Socket
			if !_linux_submit_splice_pipe_to_socket_accounted(backend, entry) {
				return _linux_complete_sendfile(
					backend,
					entry,
					completions,
					count,
					output_max,
					i32(entry.bytes_sent_total),
				)
			}

		case .Pipe_To_Socket:
			entry.bytes_in_pipe -= bytes
			entry.bytes_sent_total += bytes

			if entry.bytes_in_pipe > 0 {
				// Pipe not fully drained — keep draining before advancing
				if !_linux_submit_splice_pipe_to_socket_accounted(backend, entry) {
					return _linux_complete_sendfile(
						backend,
						entry,
						completions,
						count,
						output_max,
						i32(entry.bytes_sent_total),
					)
				}
				return count
			}

			// Pipe fully drained. More file data to transfer?
			if entry.size_remaining > 0 {
				entry.state = .File_To_Pipe
				if !_linux_submit_splice_file_to_pipe_accounted(backend, entry) {
					return _linux_complete_sendfile(
						backend,
						entry,
						completions,
						count,
						output_max,
						i32(entry.bytes_sent_total),
					)
				}
			} else {
				// All done — emit user completion
				return _linux_complete_sendfile(
					backend,
					entry,
					completions,
					count,
					output_max,
					i32(entry.bytes_sent_total),
				)
			}
		}
		return count
	}

	@(private = "file")
	_linux_discard_sendfile_pipe :: proc(entry: ^Sendfile_Entry) {
		discard_buffer: [LINUX_SENDFILE_DRAIN_BUFFER_SIZE]u8
		iteration_count_max :: LINUX_SENDFILE_CHUNK_SIZE / LINUX_SENDFILE_DRAIN_BUFFER_SIZE + 1

		for _ in 0 ..< iteration_count_max {
			if entry.bytes_in_pipe == 0 {
				return
			}
			read_size := min(int(entry.bytes_in_pipe), len(discard_buffer))
			read_count, read_error := linux.read(entry.pipe_read_fd, discard_buffer[:read_size])
			if read_error == .EINTR {
				continue
			}
			assert(read_error == .NONE, "sendfile pipe drain must not fail")
			assert(read_count > 0, "sendfile pipe byte ledger must match readable bytes")
			assert(read_count <= int(entry.bytes_in_pipe), "sendfile pipe read exceeds byte ledger")
			entry.bytes_in_pipe -= u32(read_count)
		}
		assert(entry.bytes_in_pipe == 0, "sendfile pipe drain exceeded bounded work")
	}

	// Emit the final user-visible completion for a sendfile operation and release the entry.
	@(private = "file")
	_linux_complete_sendfile :: proc(
		backend: ^Platform_Backend,
		entry: ^Sendfile_Entry,
		completions: []Raw_Completion,
		count: u32,
		output_max: u32,
		result: i32,
	) -> u32 {
		if entry.bytes_in_pipe > 0 {
			_linux_discard_sendfile_pipe(entry)
		}
		completion := Raw_Completion {
			token  = entry.token,
			result = result,
			extra  = nil,
		}
		count_next := count
		if count < output_max {
			completions[count] = completion
			count_next += 1
		} else {
			store_result := _linux_store_completion(backend, completion)
			assert(store_result == .Stored, "accepted sendfile completion capacity must be guaranteed")
		}
		_linux_release_sendfile_entry(backend, entry)
		return count_next
	}

	@(private = "file")
	_linux_store_completion :: proc "contextless" (
		backend: ^Platform_Backend,
		completion: Raw_Completion,
	) -> Backend_Completion_Store_Result {
		_linux_compact_completed(backend)
		if backend.completed_count < MAX_LINUX_COMPLETED {
			backend.completed[backend.completed_count] = completion
			backend.completed_count += 1
			return .Stored
		}
		return .Capacity_Exhausted
	}

	@(private = "file")
	_linux_compact_completed :: proc "contextless" (backend: ^Platform_Backend) {
		if backend.completed_read == 0 {
			return
		}
		completion_count_unread := backend.completed_count - backend.completed_read
		for completion_index: u16 = 0; completion_index < completion_count_unread; completion_index += 1 {
			backend.completed[completion_index] = backend.completed[backend.completed_read + completion_index]
		}
		backend.completed_count = completion_count_unread
		backend.completed_read = 0
	}

	// Register the reactor's pre-allocated buffer pool with io_uring. The iovec
	// array uses accounted startup scratch and is page-touched while populated.
	@(private = "file")
	_linux_register_buffers :: proc(
		backend: ^Platform_Backend,
		backing_memory_base: [^]u8,
		backing_memory_slot_size: u32,
		backing_memory_slot_count: u16,
		boot_scratch: []u8,
	) -> bool {
		#assert(size_of(linux.IO_Vec) == 2 * size_of(uintptr))
		assert(len(boot_scratch) >= int(backing_memory_slot_count) * size_of(linux.IO_Vec))
		iovecs := mem.slice_ptr(
			cast(^linux.IO_Vec)raw_data(boot_scratch),
			int(backing_memory_slot_count),
		)
		slot_size := int(backing_memory_slot_size)
		for i in 0 ..< int(backing_memory_slot_count) {
			iovecs[i] = linux.IO_Vec {
				base = backing_memory_base[i * slot_size:],
				len  = uint(backing_memory_slot_size),
			}
		}
		error := linux.io_uring_register(
			backend.ring.fd,
			.REGISTER_BUFFERS,
			raw_data(iovecs),
			u32(backing_memory_slot_count),
		)
		return error == .NONE
	}

	// Register a sparse fixed-file table with io_uring (§6.6.2 §8).
	// All slots initialized to -1 (empty). Updated incrementally via
	// _backend_register_fixed_fd / _backend_unregister_fixed_fd.
	// The shared boot scratch is reused after buffer registration completes.
	@(private = "file")
	_linux_register_fixed_files :: proc(
		backend: ^Platform_Backend,
		fd_slot_count: u16,
		boot_scratch: []u8,
	) -> bool {
		assert(int(fd_slot_count) <= REACTOR_LINUX_FIXED_FILE_REGISTER_MAX)
		assert(len(boot_scratch) >= int(fd_slot_count) * size_of(linux.Fd))
		fds := mem.slice_ptr(cast(^linux.Fd)raw_data(boot_scratch), int(fd_slot_count))
		for i in 0 ..< int(fd_slot_count) {
			fds[i] = linux.Fd(-1)
		}
		error := linux.io_uring_register(
			backend.ring.fd,
			.REGISTER_FILES,
			raw_data(fds),
			u32(fd_slot_count),
		)
		return error == .NONE
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
	) -> Backend_Fixed_File_Update_Result {
		if !backend.files_registered do return .Optimization_Disabled

		new_fd := linux.Fd(fd)
		update := _IO_Uring_Files_Update {
			offset = u32(slot_index),
			resv   = 0,
			data   = u64(uintptr(&new_fd)),
		}
		error := linux.io_uring_register(backend.ring.fd, .REGISTER_FILES_UPDATE, &update, 1)
		if error != .NONE {
			_linux_disable_fixed_files(backend)
			return .Optimization_Disabled
		}
		return .Updated
	}

	// Clear a single slot in the kernel's fixed-file table.
	// Called by reactor on fd_table_free (FD leaves a slot).
	@(private = "package")
	_backend_unregister_fixed_fd :: proc "contextless" (
		backend: ^Platform_Backend,
		slot_index: u16,
	) -> Backend_Fixed_File_Update_Result {
		if !backend.files_registered do return .Optimization_Disabled

		empty_fd := linux.Fd(-1)
		update := _IO_Uring_Files_Update {
			offset = u32(slot_index),
			resv   = 0,
			data   = u64(uintptr(&empty_fd)),
		}
		error := linux.io_uring_register(backend.ring.fd, .REGISTER_FILES_UPDATE, &update, 1)
		if error != .NONE {
			_linux_disable_fixed_files(backend)
			return .Optimization_Disabled
		}
		return .Updated
	}

	@(private = "file")
	_linux_disable_fixed_files :: proc "contextless" (backend: ^Platform_Backend) {
		linux.io_uring_register(backend.ring.fd, .UNREGISTER_FILES, nil, 0)
		backend.files_registered = false
		backend.fixed_fd_count = 0
	}

	// Apply fixed-file optimization to an SQE if registered files are available.
	// Called after the uring helper has filled the SQE with the raw OS_FD.
	@(private = "file")
	_linux_apply_fixed_file :: #force_inline proc "contextless" (
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
		buffer_pointer: [^]u8,
		buffer_index: IO_Slot_Index,
		data_size: u32,
		use_fixed_file: bool,
		fixed_file_index: u16,
	) -> bool {
		sqe := uring.get_sqe(&backend.ring) or_return
		sqe.opcode = .READ_FIXED
		sqe.fd = linux.Fd(op.fd)
		sqe.addr = u64(uintptr(buffer_pointer))
		sqe.len = data_size
		sqe.off = op.offset
		sqe.user_data = user_data
		sqe.buf_index = u16(buffer_index)
		if use_fixed_file {
			_linux_apply_fixed_file(sqe, fixed_file_index)
		}
		return true
	}

	@(private = "file")
	_linux_arm_wake :: proc(backend: ^Platform_Backend) -> bool {
		_, ok := uring.read(
			&backend.ring,
			_linux_user_data_pack_wake(),
			linux.Fd(backend.wake_fd),
			([^]u8)(&backend.wake_buffer)[:size_of(u64)],
			0,
		)
		if ok {
			_linux_account_operation_submitted(backend)
			uring.submit(&backend.ring, 0, nil)
		}
		return ok
	}

	// Flush buffered unqueued submissions into the ring.
	@(private = "file")
	_linux_flush_unqueued :: proc(backend: ^Platform_Backend) {
		if backend.unqueued_count == 0 {
			return
		}

		remaining: u16 = 0
		for i in 0 ..< backend.unqueued_count {
			if _linux_submit_one_accounted(backend, &backend.unqueued[i]) {
				continue
			}
			// Still can't enqueue — keep in overflow
			if remaining != i {
				backend.unqueued[remaining] = backend.unqueued[i]
			}
			remaining += 1
		}
		backend.unqueued_count = remaining
	}

	// Allocate a persistent addr entry. Returns nil if full.
	@(private = "file")
	_linux_alloc_addr_entry :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
	) -> ^Pending_Addr_Entry {
		for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
			if backend.addr_entries[i].state == .Free {
				entry := &backend.addr_entries[i]
				_sanitizer_address_unpoison_raw(rawptr(&entry.payload), size_of(entry.payload))
				entry.state = .In_Use
				backend.addr_entry_count_in_use += 1
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

	when TINA_ASAN_POISONING {
		// Transfer the stable address payload to the kernel after SQE construction.
		@(private = "file")
		_linux_transfer_addr_entry_to_kernel :: #force_inline proc(
			entry: ^Pending_Addr_Entry,
		) {
			assert(entry.state == .In_Use, "only an allocated Linux address entry can transfer to the kernel")
			_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))
		}
	}

	// Reclaim the address payload from kernel ownership after its CQE arrives.
	@(private = "file")
	_linux_reclaim_addr_entry :: proc(
		backend: ^Platform_Backend,
		token: Submission_Token,
	) -> ^Pending_Addr_Entry {
		for i in 0 ..< MAX_LINUX_PENDING_ADDRS {
			if backend.addr_entries[i].state == .In_Use && backend.addr_entries[i].token == token {
				entry := &backend.addr_entries[i]
				_sanitizer_address_unpoison_raw(rawptr(&entry.payload), size_of(entry.payload))
				return entry
			}
		}
		return nil
	}

	// Convert linux.Sock_Addr_Any → Socket_Address
	@(private = "file")
	_linux_sockaddr_to_socket_address :: proc "contextless" (native: ^linux.Sock_Addr_Any) -> Socket_Address {
		#partial switch native.family {
		case .INET:
			return Socket_Address_Inet4{address = native.sin_addr, port = u16(native.sin_port)}
		case .INET6:
			return Socket_Address_Inet6 {
				address = transmute([16]u8)native.sin6_addr,
				port = u16(native.sin6_port),
				flow = native.sin6_flowinfo,
				scope = native.sin6_scope_id,
			}
		}
		return nil
	}

	// Convert Socket_Address → linux.Sock_Addr_Any
	@(private = "file")
	_linux_socket_address_to_sockaddr :: proc "contextless" (address: Socket_Address) -> linux.Sock_Addr_Any {
		native: linux.Sock_Addr_Any
		switch socket_address in address {
		case Socket_Address_Inet4:
			native.sin_family = .INET
			native.sin_port = u16be(socket_address.port)
			native.sin_addr = socket_address.address
		case Socket_Address_Inet6:
			native.sin6_family = .INET6
			native.sin6_port = u16be(socket_address.port)
			native.sin6_addr = transmute([16]u8)socket_address.address
			native.sin6_flowinfo = socket_address.flow
			native.sin6_scope_id = socket_address.scope
		case Socket_Address_Unix:
			native.sun_family = .UNIX
			native.sun_path = socket_address.path
		}
		return native
	}

	// Return the sockaddr length for bind/connect syscalls.
	@(private = "file")
	_linux_sockaddr_len :: #force_inline proc "contextless" (address: Socket_Address) -> i32 {
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

		flags, flags_error := linux.fcntl_getfd(linux.Fd(dup_fd), .GETFD)
		testing.expect_value(t, flags_error, linux.Errno(0))
		testing.expect(t, flags != 0, "dup fd must have close-on-exec set")

		close_error := backend_control_close(&backend, fd)
		testing.expect_value(t, close_error, Backend_Error.None)
		close_dup_error := backend_control_close(&backend, dup_fd)
		testing.expect_value(t, close_dup_error, Backend_Error.None)
	}

	@(test)
	test_linux_fixed_files_register_and_deinit :: proc(t: ^testing.T) {
		backend: Platform_Backend
		boot_scratch: [8 * size_of(linux.IO_Vec)]u8
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 8,
			boot_scratch  = boot_scratch[:],
		}

		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
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

		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		testing.expect(t, !backend.files_registered, "should not register with 0 slots")

		backend_deinit(&backend)
	}

	@(test)
	test_linux_fixed_file_update_round_trip :: proc(t: ^testing.T) {
		backend: Platform_Backend
		buffer_backing: [64]u8
		boot_scratch: [4 * size_of(linux.IO_Vec)]u8
		config := Backend_Config {
			queue_size       = DEFAULT_BACKEND_QUEUE_SIZE,
			backing_memory_base      = &buffer_backing[0],
			backing_memory_slot_size = 64,
			backing_memory_slot_count = 1,
			fd_slot_count    = 4,
			boot_scratch     = boot_scratch[:],
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		// Create a real socket
		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		// Register it in slot 0
		_backend_register_fixed_fd(&backend, 0, fd)

		// Submit a recv using IOSQE_FIXED_FILE on slot 0
		token := submission_token_pack(0, 0, 0, 0, 0, .Recv_Complete)
		submissions := [1]Submission {
			{
				token = token,
				fixed_file_index = 0,
				data_size = 64,
				operation = Submission_Op_Recv{fd_socket = fd},
			},
		}
		sub_error := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_error, Backend_Error.None)
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
		boot_scratch: [4 * size_of(linux.IO_Vec)]u8
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = 4,
			boot_scratch  = boot_scratch[:],
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, _ := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		_backend_register_fixed_fd(&backend, 0, fd)

		// Submit a close with fixed_file_index = 0.
		// _linux_submit_one must NOT apply IOSQE_FIXED_FILE for close.
		// If it did, the close would target the fixed-file slot, not the raw FD.
		token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Close_Complete)
		submissions := [1]Submission {
			{
				token = token,
				fixed_file_index = 0, // deliberately set — backend must ignore for close
				operation = Submission_Op_Close{fd = fd},
			},
		}
		sub_error := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_error, Backend_Error.None)

		// Collect the close completion — should succeed (not EBADF)
		completions: [4]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 100_000_000) // 100ms timeout
		testing.expect(t, collect_result.completion_count >= 1, "close should complete")
		testing.expect(t, completions[0].result >= 0, "close should succeed (not EBADF)")

		_backend_unregister_fixed_fd(&backend, 0)
	}

	@(test)
	test_linux_oversized_fixed_file_table_disables_optimization :: proc(t: ^testing.T) {
		backend: Platform_Backend
		boot_scratch: [(REACTOR_LINUX_FIXED_FILE_REGISTER_MAX + 1) * size_of(linux.Fd)]u8
		config := Backend_Config {
			queue_size    = DEFAULT_BACKEND_QUEUE_SIZE,
			fd_slot_count = u16(REACTOR_LINUX_FIXED_FILE_REGISTER_MAX + 1),
			boot_scratch  = boot_scratch[:],
		}

		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		testing.expect(t, !backend.files_registered, "oversized fixed-file table must use raw descriptors")
		backend_deinit(&backend)
	}

	when TINA_ASAN_POISONING {
		@(test)
		test_linux_address_entry_lifetime_is_poisoned :: proc(t: ^testing.T) {
			backend: Platform_Backend
			address_entry := &backend.addr_entries[0]
			address_entry.state = .Free
			_sanitizer_address_poison_raw(rawptr(&address_entry.payload), size_of(address_entry.payload))

			token := Submission_Token(1)
			allocated_address_entry := _linux_alloc_addr_entry(&backend, token)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&allocated_address_entry.payload),
					size_of(allocated_address_entry.payload),
				) == nil,
				"allocated Linux address payload must be addressable",
			)

			_linux_transfer_addr_entry_to_kernel(allocated_address_entry)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&allocated_address_entry.payload),
					size_of(allocated_address_entry.payload),
				) != nil,
				"kernel-owned Linux address payload must be poisoned",
			)

			reclaimed_address_entry := _linux_reclaim_addr_entry(&backend, token)
			testing.expect(t, reclaimed_address_entry == allocated_address_entry, "CQE token must reclaim its address entry")
			_linux_release_addr_entry(&backend, reclaimed_address_entry)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&reclaimed_address_entry.payload),
					size_of(reclaimed_address_entry.payload),
				) != nil,
				"free Linux address payload must be poisoned",
			)
			_sanitizer_address_unpoison_raw(rawptr(&address_entry.payload), size_of(address_entry.payload))
		}

		@(test)
		test_linux_sendfile_entry_lifetime_is_poisoned :: proc(t: ^testing.T) {
			backend: Platform_Backend
			sendfile_entry := &backend.sendfile_entries[0]
			sendfile_entry.state = .Free
			_sanitizer_address_poison_raw(rawptr(&sendfile_entry.payload), size_of(sendfile_entry.payload))
			allocated_sendfile_entry := _linux_alloc_sendfile_entry(&backend)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&allocated_sendfile_entry.payload),
					size_of(allocated_sendfile_entry.payload),
				) == nil,
				"allocated Linux sendfile payload must be addressable",
			)
			_linux_release_sendfile_entry(&backend, allocated_sendfile_entry)
			testing.expect(
				t,
				sanitizer.address_region_is_poisoned_rawptr(
					rawptr(&allocated_sendfile_entry.payload),
					size_of(allocated_sendfile_entry.payload),
				) != nil,
				"free Linux sendfile payload must be poisoned",
			)

			_sanitizer_address_unpoison_raw(rawptr(&sendfile_entry.payload), size_of(sendfile_entry.payload))
		}
	}

}
