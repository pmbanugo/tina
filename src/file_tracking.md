* odin test src -strict-style 
* Anywhere we need to branch between simulation and production (like the Shard struct holding a pointer to the network), we will use when #config(TINA_SIM, false). You can pass -define:TINA_SIM=true when running odin test or odin run.

---
- config.odin: Defines the `SystemSpec`, `ShardSpec`, and `TypeDescriptor` along with memory projection utilities.
- handle.odin: Implements the 64-bit packed handle referencing Isolates and cross-shard resources.
- allocator_arena.odin: Implements the fixed `mmap` backing that all shard resources will be carved from sequentially.
- allocator_msg_pool.odin: A Gingerbill Part 4 strictly fixed intrusive free-list allocator implementation, designed for zero-fragmentation constant time pool acquisitions.
- prng.odin: Permuted Congruential Generator logic for fully deterministic, tree-derived shard entropy mapping.
- api.odin: contains the top-level API surface: Context, Effects, and public Enums.
- mailbox.odin: Defines the Message structures and the 128-byte Message_Envelope.
- logging.odin: Tina's logger.
- timer.odin: Fixed increment clock and array-backed wheel.
- shard.odin: The core scheduler loop, SOA implementation (via #soa), and the Active Context API (ctx_send, ctx_spawn).
- sim_network.odin: contains the delay queue, the network structure, and the fault engine that injects chaos deterministically.
- tina_phase1_test.odin:  A ping-pong test verifying the implementation details for milestone in phase 1 (based on roadmap).
- io_types.odin: Core I/O subsystem types — FD_Handle (generational index), IoOp sub-union, Socket_Address, Submission_Token (64-bit packed correlation), Submission/Raw_Completion backend types, IO_Completion_Tag, FD_Entry with direction-partitioned ownership, Peer_Address (28-byte compact SOA), IO_Error codes, OS_FD platform type.
- allocator_io_fd_table.odin: FD Table — Shard-owned fixed-size registry mapping FD_Handle to OS file descriptors. LIFO free list with u16 indices, generational stale detection, direction-aware affinity validation, handoff for ownership transfer, close-on-completion marking.
- allocator_io_buffer_pool.odin: Reactor Buffer Pool — pre-allocated contiguous buffer slots for I/O data transfer. LIFO free list with u16 indices, copy-on-submit support, read-slice accessor for handlers.
- io_backend.odin: Platform Backend common types (Backend_Error, Backend_Config, Platform_Backend) and public API that delegates to platform-specific _backend_* procs via compile-time dispatch. Procedural batch interface — no callbacks.
- io_backend_simulated.odin: SimulatedIO backend (TINA_SIM=true) — deterministic testing with PRNG-driven delays, fault injection, reordering. No kernel interaction. Same seed + same submit/collect sequence = same completions.
- io_backend_posix.odin: kqueue backend (Darwin/FreeBSD/OpenBSD/NetBSD, TINA_SIM=false) — emulates completion semantics on top of readiness notifications. Optimistic syscall strategy with ONESHOT fallback. EVFILT_USER for cross-shard wake.
- io_backend_linux.odin: io_uring backend (Linux, TINA_SIM=false) — batch SQE submission with CQE harvesting. SUBMIT_ALL|COOP_TASKRUN|SINGLE_ISSUER flags. Persistent addr entry pool for stable pointers. Eventfd for cross-shard wake.
- io_backend_windows.odin: IOCP backend (Windows, TINA_SIM=false) — overlapped I/O with completion port. Pre-allocated overlapped entry pool. AcceptEx/ConnectEx via WSAIoctl. PostQueuedCompletionStatus for cross-shard wake.
