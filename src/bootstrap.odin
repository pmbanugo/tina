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

OS_Thread_Handle :: distinct uintptr

// Shared control-plane state scanned by the watchdog and mutated by the shard thread.
Shard_Runtime_State :: struct #align (CACHE_LINE_SIZE) {
	shard_pointer:            ^Shard,
	os_thread_handle:         OS_Thread_Handle,
	restart_window_start_ns:  u64,
	watchdog_state:           u8,
	restart_count:            u16,
	_padding:                 [5]u8,
}

#assert(size_of(Shard_Runtime_State) == CACHE_LINE_SIZE)

// Passed to each Shard thread upon creation.
Shard_Config :: struct {
	// Dense remote routes in ascending shard-id order, excluding self.
	outbound_rings:    [REMOTE_SHARD_COUNT_MAX]^SPSC_Ring,
	inbound_rings:     [REMOTE_SHARD_COUNT_MAX]^SPSC_Ring,
	grand_arena_base:  []u8,
	system_spec:       ^SystemSpec,
	shard_spec:        ^ShardSpec,
	barrier:           ^sync.Barrier,
	runtime_state:     ^Shard_Runtime_State,
	total_memory_size: int,
	shard_id:          Shard_Id,
	target_core:       u8,
}

// #assert(size_of(Shard_Config) == 4160, "Shard_Config alignment/size drifted.")

// The single entry point to start the Tina process.
// Validates the boot specification, allocates the Grand Arenas, and spawns Shard threads.
tina_start :: proc(spec: ^SystemSpec) {
	// ========================================================================
	// PHASE: BOOTSTRAP (single-threaded)
	// ========================================================================
	store_process_phase(.Bootstrap)
	os_set_current_thread_name("tina-watchdog")

	// 1. Parse boot spec and validate
	err := validate_system_spec(spec)
	if err != .None {
		fmt.eprintfln("[FATAL] Boot spec validation failed: %v", err)
		os.exit(1)
	}

	when TINA_SIMULATION_MODE {
		if spec.simulation != nil {
			simulator, simulator_err := new(Simulator)
			if simulator_err != .None {
				fmt.eprintfln("[FATAL] Failed to allocate simulator: %v", simulator_err)
				os.exit(1)
			}
			defer free(simulator)

			if init_err := simulator_init(simulator, spec, context.allocator); init_err != .None {
				fmt.eprintfln("[FATAL] Simulator init failed: %v", init_err)
				os.exit(1)
			}
			defer simulator_deinit(simulator)

			store_process_phase(.Running)
			simulator_run(simulator)
			store_process_phase(.Terminated)
			return // End process cleanly, bypassing production setup
		}
	}

	// Evaluate SPSC ring matrix via painter's algorithm. Returns counts (items), not sizes (bytes).
	ring_counts, ring_counts_err := compute_ring_sizes(
		spec.shard_count,
		spec.default_ring_size,
		spec.ring_overrides,
		context.allocator,
	)
	if ring_counts_err != .None {
		fmt.eprintfln("[FATAL] Failed to compute SPSC ring sizes: %v", ring_counts_err)
		os.exit(1)
	}
	defer {
		for row in ring_counts do delete(row)
		delete(ring_counts)
	}

	// 5. Initialize coordination structures
	shard_configs := make([]Shard_Config, spec.shard_count)
	shard_runtime_states := make([]Shard_Runtime_State, spec.shard_count)
	remote_shard_count := int(spec.shard_count) - 1

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
		config.runtime_state = &shard_runtime_states[i]
		config.total_memory_size = shard_memory_size
		config.shard_id = Shard_Id(i)
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
			buffer_pointer := cast([^]Message_Envelope)(uintptr(raw_data(raw_mem)) +
				size_of(SPSC_Ring))
			spsc_ring_init(ring, u64(ring_count), buffer_pointer[:ring_count])

			os_apply_memory_policy(raw_mem, i32(source), spec.memory_init_mode)
			// Wire directly into the pre-allocated configs
			outbound_index := remote_route_index_from_shard_id(Shard_Id(source), Shard_Id(target))
			inbound_index := remote_route_index_from_shard_id(Shard_Id(target), Shard_Id(source))
			shard_configs[source].outbound_rings[outbound_index] = ring
			shard_configs[target].inbound_rings[inbound_index] = ring
		}
	}

	for shard_index in 0 ..< spec.shard_count {
		for route_index in 0 ..< remote_shard_count {
			assert(shard_configs[shard_index].outbound_rings[route_index] != nil)
			assert(shard_configs[shard_index].inbound_rings[route_index] != nil)
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
	store_process_phase(.Shard_Init)

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
		when !TINA_SIMULATION_MODE {
			event := os_poll_watchdog_events(0)
			if event == .Shutdown {
				fmt.eprintfln("[FATAL] Shutdown requested during shard initialization. Force exiting bootstrap.")
				os_force_exit(130)
			}
		}

		all_running := true
		failed_shard_index := -1
		failed_state := Shard_State.Init
		for index in 0 ..< spec.shard_count {
			state := load_watchdog_state_acquire(&shard_runtime_states[index])
			if state == .Running {
				continue
			}

			all_running = false
			if state != .Init {
				failed_shard_index = int(index)
				failed_state = state
				break
			}
		}

		if all_running do break init_loop
		if failed_shard_index >= 0 {
			fmt.eprintfln(
				"[FATAL] Shard %d entered %s during initialization before watchdog startup. Inspect prior logs for the root cause.",
				failed_shard_index,
				shard_state_label(failed_state),
			)
			os_force_exit(1)
		}

		if time.stopwatch_duration(stopwatch) > timeout_duration {
			for index in 0 ..< spec.shard_count {
				state := load_watchdog_state(&shard_runtime_states[index])
				fmt.eprintfln(
					"[FATAL] Shard %d failed to initialize within %v (state: %s)",
					index,
					timeout_duration,
					shard_state_label(state),
				)
			}
			os_force_exit(1)
		}
		time.sleep(10 * time.Millisecond) // Coarse polling
	}

	watchdog_shards := make([]^Shard, spec.shard_count)
	defer delete(watchdog_shards)
	watchdog_runtime_states := make([]^Shard_Runtime_State, spec.shard_count)
	defer delete(watchdog_runtime_states)
	for index in 0 ..< spec.shard_count {
		runtime_state := &shard_runtime_states[index]
		state := load_watchdog_state_acquire(runtime_state)
		if state != .Running || runtime_state.shard_pointer == nil {
			fmt.eprintfln("[FATAL] Shard %d reached watchdog startup without a published shard pointer", index)
			os.exit(1)
		}
		watchdog_shards[index] = runtime_state.shard_pointer
		watchdog_runtime_states[index] = runtime_state
	}
	watchdog_view := Watchdog_View {
		shards = watchdog_shards,
		runtime_states = watchdog_runtime_states,
	}

	// ========================================================================
	// PHASE: RUNNING
	// ========================================================================
	store_process_phase(.Running)

	// 10. Enter Watchdog loop (sigtimedwait / kqueue)
	watchdog_loop(&watchdog_view, spec)

	// Await graceful termination
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	store_process_phase(.Terminated)
	fmt.printfln("[SYSTEM] Process Terminated Cleanly.")
}
