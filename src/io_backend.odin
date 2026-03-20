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
	System_Error,
	Not_Found,
	Too_Late,
	Unsupported,
}

// --- Backend Configuration ---

Backend_Config :: struct {
	queue_size:        u32, // submission/completion queue depth (default 256)
	sim_config:        Simulation_IO_Config, // only used when TINA_SIM=true
	// Buffer pool metadata for io_uring registered buffers (§6.6.2 §8).
	// Set to nil/zero on non-Linux or when registered buffers are not desired.
	buffer_base:       [^]u8, // buffer pool backing memory base address
	buffer_slot_size:  u32, // bytes per slot
	buffer_slot_count: u16, // number of slots
	fd_slot_count:     u16, // number of fixed-file slots
}

DEFAULT_BACKEND_QUEUE_SIZE :: 256

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

backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
	return _backend_init(backend, config)
}

backend_deinit :: proc(backend: ^Platform_Backend) {
	_backend_deinit(backend)
}

// Submit a batch of I/O operations. All-or-error semantics.
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
) -> (
	u32,
	Backend_Error,
) {
	if len(completions) == 0 {
		return 0, .None
	}
	return _backend_collect(backend, completions, timeout_ns)
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

backend_control_close :: proc(backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
	return _backend_control_close(backend, fd)
}

// --- Fixed File Hooks (§6.6.2 §8) ---
// Called by reactor on FD table alloc/free to synchronize kernel fixed-file table (Linux only).
// No-op on non-Linux backends.

backend_register_fixed_fd :: proc(backend: ^Platform_Backend, slot_index: u16, fd: OS_FD) {
	_backend_register_fixed_fd(backend, slot_index, fd)
}

backend_unregister_fixed_fd :: proc(backend: ^Platform_Backend, slot_index: u16) {
	_backend_unregister_fixed_fd(backend, slot_index)
}
