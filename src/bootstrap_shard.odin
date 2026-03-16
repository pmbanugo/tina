package tina

import "core:fmt"
import "core:sync"
import "core:sys/posix"
import "core:thread"

// The entry point for every Shard OS thread.
shard_thread_entry :: proc(t: ^thread.Thread) {
	config := cast(^Shard_Config)t.data
	// Name the thread for observability (htop, perf, gdb)
	name_bufffer: [32]u8
	name_string := fmt.bprintf(name_bufffer[:], "tina-shard-%d", config.shard_id)
	os_set_current_thread_name(name_string)

	// PUBLISH THREAD HANDLE FOR WATCHDOG
	config.os_thread_handle = os_get_current_thread_handle()

	// Allocate the Shard struct on the heap.
	// It must survive Trap Boundaries and Level 2 recoveries.
	shard := new(Shard)
	defer free(shard)

	// PUBLISH SHARD POINTER BACK TO WATCHDOG
	config.shard_ptr = shard

	g_current_shard_ptr = shard
	shard.id = config.shard_id
	shard.shared_state = config.watchdog_state

	// S1. Pin to target core
	os_pin_thread_to_core(i32(config.target_core))

	// S2. Unblock SIGUSR1 (POSIX only) so the Watchdog can force recovery
	when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		unblock_sig: posix.sigset_t
		posix.sigemptyset(&unblock_sig)
		posix.sigaddset(&unblock_sig, .SIGUSR1)
		posix.pthread_sigmask(.UNBLOCK, &unblock_sig, nil)
	}

	// S3. Allocate + install sigaltstack (NUMA-local because thread is pinned)
	sigstack_mem, sigstack_err := os_reserve_arena_with_guard(TINA_SIGALTSTACK_SIZE)
	if sigstack_err == .None {
		os_install_sigaltstack(sigstack_mem)
	}

	// S4-S6. Apply NUMA policy, THP, and Pre-faulting
	os_apply_memory_policy(config.grand_arena_base, -1, config.system_spec.memory_init_mode)

	// S7-S13: Initialization inside the Level 2 Recovery Loop
	for {
		// Initialize the Grand Arena allocator
		arena := Grand_Arena{}
		grand_arena_init(&arena, config.total_memory_size)
		arena.base = config.grand_arena_base // Override base since it's pre-allocated

		// S8-S10. Hydrate the Shard struct and initialize all sub-systems
		if err := hydrate_shard(&arena, config.system_spec, shard); err != .None {
			fmt.eprintfln("[FATAL] Shard %d failed to hydrate memory: %v", config.shard_id, err)
			return // Will trigger the main thread's Init Timeout
		}
		// S9. Set up SPSC ring metadata (Slices directly over the config arrays)
		shard.outbound_rings = config.outbound_rings[:]
		shard.inbound_rings = config.inbound_rings[:]

		// S11. Install shard-level sigsetjmp recovery point (Level 2/3 Boundary)
		recovery_reason := sigsetjmp(&shard.trap_environment, 0)
		if recovery_reason != 0 {
			// We just caught a SIGSEGV/SIGBUS/SIGFPE or Watchdog SIGUSR1!
			fmt.eprintfln(
				"[RECOVERY] Shard %d performing Level 2 recovery (Reason: %d)",
				shard.id,
				recovery_reason,
			)
			shard_mass_teardown(shard)
			continue // Restart initialization loop
		}

		// S12. Build Supervision Tree
		alloc_data := Grand_Arena_Allocator_Data {
			arena = &arena,
		}
		arena_alloc := grand_arena_allocator(&alloc_data)
		shard_build_supervision_tree(
			shard,
			&config.shard_spec.root_group,
			arena_alloc,
			&alloc_data,
		)

		// S13. Log memory breakdown
		if config.shard_id == 0 {
			arena_print_layout(&arena)
		}

		// S14. Synchronize with all Shards
		sync.barrier_wait(config.barrier)

		// S15. Mark as Running for the Watchdog
		sync.atomic_store_explicit(config.watchdog_state, u8(Shard_State.Running), .Release)

		// S16. Enter scheduler loop
		for {
			state := cast(Shard_State)sync.atomic_load_explicit(config.watchdog_state, .Relaxed)
			if state == .Shutting_Down {
				// Phase 2 Drain: Only break when all Isolates have gracefully returned .done
				if !shard_has_live_isolates(shard) {
					break
				}
			}

			// Execute the single tick
			scheduler_tick(shard)
		}

		// Break out of recovery loop if we gracefully shut down
		break
	}

	// Clean exit after graceful drain
	// §13: Final synchronous log flush — last operation before shard thread exits
	log_flush(shard)

	// Mark as Terminated so the Watchdog knows the drain is complete
	sync.atomic_store_explicit(config.watchdog_state, u8(Shard_State.Terminated), .Release)
}
