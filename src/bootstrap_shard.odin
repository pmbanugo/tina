package tina

import "core:fmt"
import "core:sync"
import "core:sys/posix"
import "core:thread"

// The entry point for every Shard OS thread.
shard_thread_entry :: proc(t: ^thread.Thread) {
	config := cast(^Shard_Config)t.data
	name_bufffer: [32]u8
	name_string := fmt.bprintf(name_bufffer[:], "tina-shard-%d", config.shard_id)
	os_set_current_thread_name(name_string)

	config.os_thread_handle = os_get_current_thread_handle()

	shard := new(Shard)
	defer free(shard)

	config.shard_ptr = shard
	g_current_shard_ptr = shard
	shard.id = config.shard_id
	shard.shared_state = config.watchdog_state

	os_pin_thread_to_core(i32(config.target_core))

	when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		unblock_sig: posix.sigset_t
		posix.sigemptyset(&unblock_sig)
		posix.sigaddset(&unblock_sig, .SIGUSR1)
		posix.pthread_sigmask(.UNBLOCK, &unblock_sig, nil)
	}

	sigstack_mem, sigstack_err := os_reserve_arena_with_guard(TINA_SIGALTSTACK_SIZE)
	if sigstack_err == .None {
		os_install_sigaltstack(sigstack_mem)
	}

	os_apply_memory_policy(config.grand_arena_base, -1, config.system_spec.memory_init_mode)

	// ==========================================================
	// S7-S10: Hydrate ONCE. Do not put this in a recovery loop.
	// ==========================================================
	arena := Grand_Arena{}
	grand_arena_init(&arena, config.total_memory_size)
	arena.base = config.grand_arena_base

	if err := hydrate_shard(&arena, config.system_spec, shard); err != .None {
		fmt.eprintfln("[FATAL] Shard %d failed to hydrate memory: %v", config.shard_id, err)
		return
	}

	shard.outbound_rings = config.outbound_rings[:]
	shard.inbound_rings = config.inbound_rings[:]

	// S11. Install shard-level sigsetjmp recovery point
	for {
		recovery_reason := sigsetjmp(&shard.trap_environment, 0)

		if recovery_reason != 0 {
			// CRASH PATH: We caught a SIGSEGV/SIGBUS/SIGFPE or Watchdog SIGUSR1
			fmt.eprintfln(
				"[RECOVERY] Shard %d performing Level 2 recovery (Reason: %d)",
				shard.id,
				recovery_reason,
			)
			// This performs the in-place reset and rebuilds the tree.
			shard_mass_teardown(shard)

			// Skip the barrier and go straight back into the scheduler.
		} else {
			// FIRST-TIME BOOT PATH:
			when !TINA_SIMULATION_MODE {
				now_ns := os_monotonic_time_ns()
				shard.current_tick = now_ns / shard.timer_resolution_ns
				shard.timer_wheel.last_tick = shard.current_tick
				sync.atomic_store_explicit(&shard.heartbeat_tick, shard.current_tick, .Relaxed)
			}

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

			if config.shard_id == 0 {
				arena_print_layout(&arena)
			}

			// Synchronize with all Shards (First boot only)
			sync.barrier_wait(config.barrier)
		}

		sync.atomic_store_explicit(config.watchdog_state, u8(Shard_State.Running), .Release)

		// S16. Enter scheduler loop
		for {
			state := cast(Shard_State)sync.atomic_load_explicit(config.watchdog_state, .Relaxed)
			if state == .Shutting_Down {
				if !shard_has_live_isolates(shard) {
					break
				}
			}
			scheduler_tick(shard)
		}

		// Break out of recovery loop if we gracefully shut down
		break
	}

	when TINA_DEBUG_ASSERTS {
		// Clean exit after graceful drain.
		// After all Isolates returned .done and the last scheduler_tick drained
		// any remaining stale I/O completions, every reactor buffer should be back
		// in the free pool. A mismatch means a buffer leaked — either the
		// io_sequence stale-path failed to free it, or teardown step 2b missed one.
		assert(
			shard.reactor.buffer_pool.free_count == shard.reactor.buffer_pool.slot_count,
			"Reactor buffer pool leak: not all buffers reclaimed after shutdown drain",
		)
	}

	log_flush(shard)
	sync.atomic_store_explicit(config.watchdog_state, u8(Shard_State.Terminated), .Release)
}
