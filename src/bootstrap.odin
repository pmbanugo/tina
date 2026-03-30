package tina

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/info"
import "core:thread"
import "core:time"

// Ensure we are compiling for a 64-bit architecture, which the explicit padding relies on.
// #assert(size_of(rawptr) == 8, "Tina requires a 64-bit architecture.")

MAX_SHARDS :: 256

// Passed to each Shard thread upon creation.
Shard_Config :: struct #align (CACHE_LINE_SIZE) {
	// Massive inline arrays (256 * 8 = 2048 bytes each)
	outbound_rings:    [MAX_SHARDS]^SPSC_Ring,
	inbound_rings:     [MAX_SHARDS]^SPSC_Ring,
	grand_arena_base:  []u8,
	system_spec:       ^SystemSpec,
	shard_spec:        ^ShardSpec,
	barrier:           ^sync.Barrier,
	shard_ptr:         ^Shard,
	watchdog_state:    u8,
	os_thread_handle:  rawptr,
	total_memory_size: int,
	shard_id:          u8,
	target_core:       u8,
}

// #assert(size_of(Shard_Config) == 4160, "Shard_Config alignment/size drifted.")

// The single entry point to start the Tina process.
// Validates the boot specification, allocates the Grand Arenas, and spawns Shard threads.
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

	when TINA_SIMULATION_MODE {
		if spec.simulation != nil {
			simulator := new(Simulator)
			defer free(simulator)

			if init_err := simulator_init(simulator, spec, context.allocator); init_err != .None {
				fmt.eprintfln("[FATAL] Simulator init failed: %v", init_err)
				os.exit(1)
			}

			set_process_phase(.Running)
			simulator_run(simulator)
			set_process_phase(.Terminated)
			return // End process cleanly, bypassing production setup
		}
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
		config.total_memory_size = shard_memory_size
		config.shard_id = i
		config.target_core = u8(i) // Mapped directly to shard_id by default
	}

	// 2. Allocate SPSC ring buffers (outside Grand Arena)
	spsc_memory_size: int = 0

	for source in 0 ..< spec.shard_count {
		for target in 0 ..< spec.shard_count {
			// Shards don't talk to themselves via SPSC rings
			if source == target do continue

			ring_count := ring_counts[source][target]
			if ring_count == 0 do continue

			ring_memory_size := size_of(SPSC_Ring) + int(ring_count) * size_of(Message_Envelope)
			spsc_memory_size += ring_memory_size

			// TODO: (Production) mbind to the writer's (source) NUMA node here.
			raw_mem, alloc_err := os_reserve_arena_with_guard(uint(ring_memory_size))
			if alloc_err != .None {
				fmt.eprintfln("[FATAL] Failed to allocate SPSC ring %v->%v", source, target)
				os.exit(1)
			}

			// Map the struct to the start, and the buffer right after it
			ring := cast(^SPSC_Ring)raw_data(raw_mem)
			buffer_ptr := cast([^]Message_Envelope)(uintptr(raw_data(raw_mem)) +
				size_of(SPSC_Ring))
			spsc_ring_init(ring, u64(ring_count), buffer_ptr[:ring_count])

			os_apply_memory_policy(raw_mem, i32(source), spec.memory_init_mode)
			// Wire directly into the pre-allocated configs
			shard_configs[source].outbound_rings[target] = ring
			shard_configs[target].inbound_rings[source] = ring
		}
	}

	total_system_memory_size += spsc_memory_size
	// System Memory Fit Check
	if total_ram, _, _, _, ram_ok := info.ram_stats(); ram_ok {
		safety_margin := spec.safety_margin
		if safety_margin <= 0.0 do safety_margin = 0.9 // Default from ADR

		max_allowed := f64(total_ram) * f64(safety_margin)
		if f64(total_system_memory_size) > max_allowed {
			fmt.eprintfln(
				"[FATAL] Memory budget (%.2f MB) exceeds %.0f%% of available RAM (%.2f MB)",
				f64(total_system_memory_size) / 1024.0 / 1024.0,
				safety_margin * 100.0,
				f64(total_ram) / 1024.0 / 1024.0,
			)
			os.exit(1)
		}
	}

	fmt.printfln(
		"[SYSTEM] Total requested memory: %v bytes (%.2f MB)",
		total_system_memory_size,
		f64(total_system_memory_size) / 1024.0 / 1024.0,
	)

	// 4. Install signal handlers and set signal mask
	when !TINA_SIMULATION_MODE {
		os_signals_init_process()
	}

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
			state := cast(Shard_State)sync.atomic_load_explicit(
				&shard_configs[index].watchdog_state,
				.Relaxed,
			)
			if state != .Running {
				all_running = false
				break
			}
		}

		if all_running do break init_loop

		if time.stopwatch_duration(stopwatch) > timeout_duration {
			for index in 0 ..< spec.shard_count {
				state := cast(Shard_State)sync.atomic_load_explicit(
					&shard_configs[index].watchdog_state,
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
	watchdog_loop(shard_configs, spec)

	// Await graceful termination
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	set_process_phase(.Terminated)
	fmt.printfln("[SYSTEM] Process Terminated Cleanly.")
}
