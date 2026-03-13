package tina

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Ensure we are compiling for a 64-bit architecture, which the explicit padding relies on.
// #assert(size_of(rawptr) == 8, "Tina requires a 64-bit architecture.")

MAX_SHARDS :: 256

// Passed to each Shard thread upon creation.
Shard_Config :: struct {
	// Shard_Config :: struct #align(CACHE_LINE_SIZE) {
	// Massive inline arrays (256 * 8 = 2048 bytes each)
	outbound_rings:    [MAX_SHARDS]^SPSC_Ring,
	inbound_rings:     [MAX_SHARDS]^SPSC_Ring,
	grand_arena_base:  []u8,
	system_spec:       ^SystemSpec,
	shard_spec:        ^ShardSpec,
	barrier:           ^sync.Barrier,
	shard_ptr:         ^Shard,
	watchdog_state:    ^u8,
	os_thread_handle:  rawptr,
	total_memory_size: int,
	shard_id:          u16,
	target_core:       u8,
}

// #assert(size_of(Shard_Config) == 4160, "Shard_Config alignment/size drifted.")

// The single entry point for the Tina process.
tina_start :: proc(spec: ^SystemSpec) {
	// ========================================================================
	// PHASE: BOOTSTRAP (single-threaded)
	// ========================================================================
	set_process_phase(.Bootstrap)
	os_set_current_thread_name("tina-watchdog")

	// 1. Parse boot spec and validate
	err := validate_system_spec(spec)
	if err != .None {
		fmt.eprintfln("[FATAL] Boot spec validation failed: %v", err)
		os.exit(1)
	}

	// Evaluate SPSC ring matrix via painter's algorithm. Returns counts (items), not sizes (bytes).
	ring_counts := compute_ring_sizes(
		spec.shard_count,
		spec.default_ring_size,
		spec.ring_overrides,
		context.allocator,
	)
	defer {
		for row in ring_counts do delete(row)
		delete(ring_counts)
	}

	// 5. Initialize coordination structures
	shard_configs := make([]Shard_Config, spec.shard_count)
	watchdog_states := make([]u8, spec.shard_count)

	barrier := new(sync.Barrier)
	sync.barrier_init(barrier, int(spec.shard_count)) // Main thread does NOT wait on this

	// 3. Reserve Grand Arena VA for each Shard WITH guard pages
	shard_memory_size := compute_shard_memory_total(spec)
	total_system_memory_size := int(spec.shard_count) * shard_memory_size

	for i in 0 ..< spec.shard_count {
		arena_mem, mem_err := os_reserve_arena_with_guard(uint(shard_memory_size))
		if mem_err != .None {
			fmt.eprintfln("[FATAL] Failed to reserve Grand Arena for Shard %v", i)
			os.exit(1)
		}

		config := &shard_configs[i]
		config.grand_arena_base = arena_mem
		config.system_spec = spec
		if int(i) < len(spec.shard_specs) {
			config.shard_spec = &spec.shard_specs[i]
		}
		config.barrier = barrier
		config.watchdog_state = &watchdog_states[i]
		config.total_memory_size = shard_memory_size
		config.shard_id = i
		config.target_core = u8(i) // Mapped directly to shard_id by default
	}

	// 2. Allocate SPSC ring buffers (outside Grand Arena)
	spsc_memory_size: int = 0

	for src in 0 ..< spec.shard_count {
		for dst in 0 ..< spec.shard_count {
			// Shards don't talk to themselves via SPSC rings
			if src == dst do continue

			ring_count := ring_counts[src][dst]
			if ring_count == 0 do continue

			ring_memory_size := size_of(SPSC_Ring) + int(ring_count) * size_of(Message_Envelope)
			spsc_memory_size += ring_memory_size

			// TODO (Production): mbind to the writer's (src) NUMA node here.
			raw_mem, alloc_err := os_reserve_arena_with_guard(uint(ring_memory_size))
			if alloc_err != .None {
				fmt.eprintfln("[FATAL] Failed to allocate SPSC ring %v->%v", src, dst)
				os.exit(1)
			}

			// Map the struct to the start, and the buffer right after it
			ring := cast(^SPSC_Ring)raw_data(raw_mem)
			buffer_ptr := cast([^]Message_Envelope)(uintptr(raw_data(raw_mem)) +
				size_of(SPSC_Ring))
			spsc_ring_init(ring, u64(ring_count), buffer_ptr[:ring_count])

			os_apply_memory_policy(raw_mem, i32(src), spec.memory_init_mode)
			// Wire directly into the pre-allocated configs
			shard_configs[src].outbound_rings[dst] = ring
			shard_configs[dst].inbound_rings[src] = ring
		}
	}

	total_system_memory_size += spsc_memory_size
	fmt.printfln(
		"[SYSTEM] Total requested memory: %v bytes (%.2f MB)",
		total_system_memory_size,
		f64(total_system_memory_size) / 1024.0 / 1024.0,
	)

	// 4. Install signal handlers and set signal mask
	_bootstrap_signals()

	// ========================================================================
	// PHASE: SHARD_INIT (multi-threaded, pre-scheduler)
	// ========================================================================
	set_process_phase(.Shard_Init)

	// 6. Spawn Shard threads
	threads := make([]^thread.Thread, spec.shard_count)
	for i in 0 ..< spec.shard_count {
		t := thread.create(shard_thread_entry)
		t.data = &shard_configs[i]
		thread.start(t)
		threads[i] = t
	}

	// TODO: 7. Spawn DIO thread (if enabled). For v1, this feature isn't implemented.

	// 8. Main thread: poll-wait for all Shards to hit RUNNING (with timeout)
	timeout_duration :=
		time.Millisecond * time.Duration(spec.init_timeout_ms == 0 ? 30_000 : spec.init_timeout_ms)

	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)

	init_loop: for {
		all_running := true
		for index in 0 ..< spec.shard_count {
			state := cast(Shard_State)sync.atomic_load_explicit(&watchdog_states[index], .Relaxed)
			if state != .Running {
				all_running = false
				break
			}
		}

		if all_running do break init_loop

		if time.stopwatch_duration(stopwatch) > timeout_duration {
			for index in 0 ..< spec.shard_count {
				state := cast(Shard_State)sync.atomic_load_explicit(
					&watchdog_states[index],
					.Relaxed,
				)
				if state == .Init {
					fmt.eprintfln(
						"[FATAL] Shard %d failed to initialize within %v",
						index,
						timeout_duration,
					)
				}
			}
			os.exit(1)
		}
		time.sleep(10 * time.Millisecond) // Coarse polling
	}

	// ========================================================================
	// PHASE: RUNNING
	// ========================================================================
	set_process_phase(.Running)

	// 10. Enter Watchdog loop (sigtimedwait / kqueue)
	watchdog_loop(shard_configs, watchdog_states, spec)

	// Await graceful termination
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	set_process_phase(.Terminated)
	fmt.printfln("[SYSTEM] Process Terminated Cleanly.")
}

// Configures process-wide signal dispositions before any threads are spawned.
@(private = "file")
_bootstrap_signals :: proc() {
	when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		// 4a. Ignore SIGPIPE process-wide.
		posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

		// 4b. Install SIGSEGV, SIGBUS, SIGFPE, SIGUSR1 handlers with SA_ONSTACK
		sa_fatal: posix.sigaction_t
		sa_fatal.sa_sigaction = fatal_signal_handler
		sa_fatal.sa_flags = {.SIGINFO, .ONSTACK}
		posix.sigemptyset(&sa_fatal.sa_mask)

		posix.sigaction(.SIGSEGV, &sa_fatal, nil)
		posix.sigaction(.SIGBUS, &sa_fatal, nil)
		posix.sigaction(.SIGFPE, &sa_fatal, nil)

		sa_usr1: posix.sigaction_t
		sa_usr1.sa_sigaction = sigusr1_handler
		sa_usr1.sa_flags = {.SIGINFO, .ONSTACK}
		posix.sigemptyset(&sa_usr1.sa_mask)

		posix.sigaction(.SIGUSR1, &sa_usr1, nil)

		// 4c. Block signals that will be handled synchronously via sigtimedwait by the watchdog.
		blocked: posix.sigset_t
		posix.sigemptyset(&blocked)
		posix.sigaddset(&blocked, .SIGTERM)
		posix.sigaddset(&blocked, .SIGINT)
		posix.sigaddset(&blocked, .SIGUSR1)
		posix.sigaddset(&blocked, .SIGUSR2)
		posix.sigaddset(&blocked, .SIGHUP)

		sig_err := posix.pthread_sigmask(.BLOCK, &blocked, nil)
		if sig_err != .NONE {
			fmt.eprintfln("[FATAL] Failed to set pthread_sigmask: %v", posix.strerror(sig_err))
			os.exit(1)
		}
	}
}

when ODIN_OS ==
	.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {

	// --- Async-Signal-Safe Helpers (write(2) only, no fmt/allocator/runtime) ---

	@(private = "file")
	_sig_append_str :: proc "contextless" (dst: []u8, pos: int, src: string) -> int {
		n := min(len(dst) - pos, len(src))
		for i in 0 ..< n do dst[pos + i] = src[i]
		return pos + n
	}

	@(private = "file")
	_sig_append_u64 :: proc "contextless" (dst: []u8, pos: int, value: u64) -> int {
		if pos >= len(dst) do return pos
		if value == 0 {
			dst[pos] = '0'
			return pos + 1
		}
		tmp: [20]u8
		n := 0
		v := value
		for v > 0 {
			tmp[n] = u8('0') + u8(v % 10)
			v /= 10
			n += 1
		}
		written := min(n, len(dst) - pos)
		for i in 0 ..< written {
			dst[pos + i] = tmp[n - 1 - i]
		}
		return pos + written
	}

	// The Tier 3 Fault Trap — async-signal-safe
	@(private = "file")
	fatal_signal_handler :: proc "c" (
		sig: posix.Signal,
		info: ^posix.siginfo_t,
		ucontext: rawptr,
	) {
		shard := g_current_shard_ptr
		if shard == nil {
			// Not a Shard thread. Re-raise with default handler → abort + core dump.
			buf: [64]u8
			n := _sig_append_str(buf[:], 0, "[FATAL] non-shard sig=")
			n = _sig_append_u64(buf[:], n, u64(sig))
			n = _sig_append_str(buf[:], n, "\n")
			_write_stderr(buf[:n])
			posix.signal(sig, auto_cast posix.SIG_DFL)
			posix.raise(sig)
			return
		}

		buf: [96]u8
		n := _sig_append_str(buf[:], 0, "[FATAL] Shard ")
		n = _sig_append_u64(buf[:], n, u64(shard.id))
		n = _sig_append_str(buf[:], n, " caught sig=")
		n = _sig_append_u64(buf[:], n, u64(sig))
		n = _sig_append_str(buf[:], n, ". Level 2 Recovery.\n")
		_write_stderr(buf[:n])

		// Emergency log flush — the "Black Box" (async-signal-safe)
		emergency_log_flush_signal(shard)

		// Warp execution back to the recovery point
		siglongjmp(&shard.trap_environment, RECOVERY_TIER_3)
	}

	// The Watchdog Cooperative Kill Trap — async-signal-safe
	@(private = "file")
	sigusr1_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ucontext: rawptr) {
		shard := g_current_shard_ptr
		if shard == nil do return

		buf: [96]u8
		n := _sig_append_str(buf[:], 0, "[WATCHDOG] Shard ")
		n = _sig_append_u64(buf[:], n, u64(shard.id))
		n = _sig_append_str(buf[:], n, " SIGUSR1 force-kill. Level 2 Recovery.\n")
		_write_stderr(buf[:n])

		// Warp execution back to the recovery point
		siglongjmp(&shard.trap_environment, RECOVERY_WATCHDOG)
	}
}
