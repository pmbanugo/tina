#+private
package tina

// ============================================================================
// Platform Backend — Common Types & Compile-Time Dispatch (§6.6.2)
// ============================================================================
//
// Two-layer architecture:
//   Layer 1 — Platform Backend: thin kernel interface (this file + platform files)
//   Layer 2 — Reactor: platform-agnostic I/O manager (io_reactor.odin)
//
// The backend exposes a procedural batch interface — no callbacks.
// Completions are returned as data. Token-based correlation replaces pointers.
//
// Platform selection: compile-time via ODIN_OS and TINA_SIM config flag.
// SimulatedIO overrides OS selection when TINA_SIM=true.

// --- Backend Error ---

Backend_Error :: enum u8 {
	None,
	Queue_Full,
	Resource_Exhausted,
	Address_In_Use,
	Address_Not_Available,
	Permission_Denied,
	Invalid_Argument,
	System_Error,
	Not_Found,
	Too_Late,
	Unsupported,
}

Backend_Collect_Fault :: enum u8 {
	None,
	System_Error,
}

Backend_Collect_Result :: struct {
	completion_count: u32,
	fault:            Backend_Collect_Fault,
}

Backend_Quiesce_Result :: enum u8 {
	Quiesced,
	Unproven,
}

Backend_Completion_Store_Result :: enum u8 {
	Stored,
	Capacity_Exhausted,
}

Backend_Fixed_File_Update_Result :: enum u8 {
	Updated,
	Optimization_Disabled,
}

// --- Backend Configuration ---

Backend_Config :: struct {
	queue_size:        u32, // submission/completion queue depth (default 256)
	sim_config:        Simulation_IO_Config, // only used when TINA_SIM=true
	boot_scratch:      []u8, // backend init scratch carved from startup memory
	// Receive-pool memory layout, used for the registered-buffer optimization
	// (io_uring IORING_REGISTER_BUFFERS).
	// Currently consumed ONLY by the Linux backend; the BSD, Windows, and
	// simulated backends ignore these fields (their _Platform_State no longer
	// stores them). They live in the shared config rather
	// than a Linux-only struct because they describe the receive pool itself,
	// not a Linux concept: a future backend (e.g. Windows RIO) could register
	// the same layout. Reactor populates them from the receive pool on every
	// platform; non-Linux backends simply do not read them.
	backing_memory_base:          [^]u8,
	backing_memory_slot_size:     u32,
	backing_memory_slot_count:    u16,
	fd_slot_count:     u16, // number of fixed-file slots
}

DEFAULT_BACKEND_QUEUE_SIZE :: 256

backend_boot_scratch_size :: #force_inline proc "contextless" (
	receive_slot_count: int,
	fd_slot_count: int,
) -> int {
	return _backend_boot_scratch_size(receive_slot_count, fd_slot_count)
}

// --- SimulatedIO Configuration (§6.6.2 §5.4) ---

Error_Weight :: struct {
	error_code: i32, // OS-level error result (e.g., -104 for ECONNRESET)
	weight:     u32, // relative probability weight
}

Simulation_IO_Config :: struct {
	fault_rate:         Ratio, // probability of fault per operation (0/N = never)
	delay_range_ticks:  [2]u32, // [min, max] simulated delay in ticks
	reorder:            bool, // whether completions can be reordered
	seed:               u64, // deterministic seed (from Prng_Tree.shard_io)
	error_distribution: []Error_Weight, // varied error codes for fault injection
	world:              rawptr, // ^Sim_IO_World in simulation mode; ignored in non-sim
}

// --- Platform Backend Struct ---
// Embeds platform-specific state defined in platform files.

Platform_Backend :: struct {
	using platform: _Platform_State,
}

// ============================================================================
// Public API — delegates to platform-specific _backend_* procs
// ============================================================================
//
// Each platform file (io_backend_simulated.odin, io_backend_posix.odin,
// io_backend_linux.odin, io_backend_windows.odin) defines:
//   _Platform_State              struct
//   _backend_init                proc
//   _backend_deinit              proc
//   _backend_submit              proc
//   _backend_collect             proc
//   _backend_cancel              proc
//   _backend_wake                proc
//   _backend_control_socket      proc
//   _backend_control_bind        proc
//   _backend_control_listen      proc
//   _backend_control_setsockopt  proc
//   _backend_control_getsockopt  proc
//   _backend_control_shutdown    proc
//   _backend_control_dup         proc

backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
	return _backend_init(backend, config)
}

backend_deinit :: proc(backend: ^Platform_Backend) {
	_backend_deinit(backend)
}

// Ends every backend-owned memory access after an unrecoverable collect fault.
// Callers may reclaim accepted-operation memory only after Quiesced.
backend_quiesce_after_collect_fault :: proc(
	backend: ^Platform_Backend,
) -> Backend_Quiesce_Result {
	return _backend_quiesce_after_collect_fault(backend)
}

backend_error_label :: #force_inline proc "contextless" (error: Backend_Error) -> string {
	@(static, rodata)
	labels := [Backend_Error]string {
		.None                 = "none",
		.Queue_Full           = "queue full",
		.Resource_Exhausted   = "resource exhausted",
		.Address_In_Use       = "address already in use",
		.Address_Not_Available = "address not available",
		.Permission_Denied    = "permission denied",
		.Invalid_Argument     = "invalid argument",
		.System_Error         = "system error",
		.Not_Found            = "not found",
		.Too_Late             = "too late",
		.Unsupported          = "unsupported",
	}
	return labels[error]
}

// A `.None` result transfers ownership of the whole batch to the backend;
// every other result rejects the whole batch before ownership transfers.
backend_submit :: proc(backend: ^Platform_Backend, submissions: []Submission) -> Backend_Error {
	if len(submissions) == 0 {
		return .None
	}
	return _backend_submit(backend, submissions)
}

// Collect completed operations into the output slice. Non-blocking when timeout_ns == 0.
backend_collect :: proc(
	backend: ^Platform_Backend,
	completions: []Raw_Completion,
	timeout_ns: i64,
) -> Backend_Collect_Result {
	completion_capacity := len(completions)
	if completion_capacity == 0 {
		return Backend_Collect_Result{}
	}
	result := _backend_collect(backend, completions, timeout_ns)
	when TINA_RUNTIME_ASSERTIONS {
		assert(result.completion_count <= u32(completion_capacity), "backend reported more completions than caller capacity")
	}
	return result
}

backend_set_current_tick :: #force_inline proc "contextless" (backend: ^Platform_Backend, tick_count: u64) {
	_backend_set_current_tick(backend, tick_count)
}

// Best-effort cancellation. Correctness does not depend on cancel succeeding.
backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
	return _backend_cancel(backend, token)
}

// Interrupt a blocking backend_collect from another thread.
backend_wake :: proc(backend: ^Platform_Backend) {
	_backend_wake(backend)
}

// --- Synchronous Control Operations (§6.6.3 §4) ---
// Non-batched, non-blocking. Called during handler execution (scheduler step 3).
// Route through backend for SimulatedIO simulation seam.

backend_control_socket :: proc(
	backend: ^Platform_Backend,
	domain: Socket_Domain,
	socket_type: Socket_Type,
	protocol: Socket_Protocol,
) -> (
	OS_FD,
	Backend_Error,
) {
	return _backend_control_socket(backend, domain, socket_type, protocol)
}

backend_control_bind :: proc(
	backend: ^Platform_Backend,
	fd: OS_FD,
	address: Socket_Address,
) -> Backend_Error {
	return _backend_control_bind(backend, fd, address)
}

backend_control_listen :: proc(
	backend: ^Platform_Backend,
	fd: OS_FD,
	backlog: u32,
) -> Backend_Error {
	return _backend_control_listen(backend, fd, backlog)
}

backend_control_setsockopt :: proc(
	backend: ^Platform_Backend,
	fd: OS_FD,
	level: Socket_Level,
	option: Socket_Option,
	value: Socket_Option_Value,
) -> Backend_Error {
	return _backend_control_setsockopt(backend, fd, level, option, value)
}

backend_control_getsockopt :: proc(
	backend: ^Platform_Backend,
	fd: OS_FD,
	level: Socket_Level,
	option: Socket_Option,
) -> (
	Socket_Option_Value,
	Backend_Error,
) {
	return _backend_control_getsockopt(backend, fd, level, option)
}

backend_control_shutdown :: proc(
	backend: ^Platform_Backend,
	fd: OS_FD,
	how: Shutdown_How,
) -> Backend_Error {
	return _backend_control_shutdown(backend, fd, how)
}

backend_control_close :: #force_inline proc "contextless" (
	backend: ^Platform_Backend,
	fd: OS_FD,
) -> Backend_Error {
	return _backend_control_close(backend, fd)
}

backend_control_dup :: #force_inline proc "contextless" (
	backend: ^Platform_Backend,
	fd: OS_FD,
) -> (
	OS_FD,
	Backend_Error,
) {
	return _backend_control_dup(backend, fd)
}

// --- Fixed File Hooks (§6.6.2 §8) ---
// Called by reactor on FD table alloc/free to synchronize kernel fixed-file table (Linux only).
// No-op on non-Linux backends.

backend_register_fixed_fd :: #force_inline proc "contextless" (
	backend: ^Platform_Backend,
	slot_index: u16,
	fd: OS_FD,
) -> Backend_Fixed_File_Update_Result {
	return _backend_register_fixed_fd(backend, slot_index, fd)
}

backend_unregister_fixed_fd :: #force_inline proc "contextless" (
	backend: ^Platform_Backend,
	slot_index: u16,
) -> Backend_Fixed_File_Update_Result {
	return _backend_unregister_fixed_fd(backend, slot_index)
}
