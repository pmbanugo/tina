package tina

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"

// Custom assertion handler that routes Odin software panics into Tina's Trap Boundary.
// Uses only async-signal-safe operations (stack buffer + write(2)). No fmt, no allocator.
tina_assertion_failure_proc :: proc(
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) -> ! {
	shard := g_current_shard_ptr
	if shard != nil {
		buf: [256]u8
		n := _sig_append_str(buf[:], 0, "[SOFTWARE PANIC] Shard ")
		n = _sig_append_u64(buf[:], n, u64(shard.id))
		n = _sig_append_str(buf[:], n, ": ")
		n = _sig_append_str(buf[:], n, prefix)
		n = _sig_append_str(buf[:], n, message)
		n = _sig_append_str(buf[:], n, "\n")
		_write_stderr(buf[:n])
		trigger_tier2_panic(shard)
	} else {
		buf: [256]u8
		n := _sig_append_str(buf[:], 0, "[FATAL PANIC] Non-shard thread: ")
		n = _sig_append_str(buf[:], n, prefix)
		n = _sig_append_str(buf[:], n, message)
		n = _sig_append_str(buf[:], n, "\n")
		_write_stderr(buf[:n])
		os_abort()
	}
}

// The entry point for every Shard OS thread.
shard_thread_entry :: proc(t: ^thread.Thread) {
	config := cast(^Shard_Config)t.data
	name_bufffer: [32]u8
	name_string := fmt.bprintf(name_bufffer[:], "tina-shard-%d", config.shard_id)
	os_set_current_thread_name(name_string)

	config.os_thread_handle = os_get_current_thread_handle()

	// Hook Odin's software panics into the Tina Trap Boundary
	context.assertion_failure_proc = tina_assertion_failure_proc

	shard := new(Shard)
	defer free(shard)

	config.shard_ptr = shard
	g_current_shard_ptr = shard
	shard.id = config.shard_id
	shard.shared_state = config.watchdog_state

	os_pin_thread_to_core(i32(config.target_core))

	when !TINA_SIMULATION_MODE {
		os_signals_init_thread()
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
		recovery_reason := os_trap_save(&shard.trap_environment_outer)

		if recovery_reason != 0 {
			// CRASH PATH: We caught a SIGSEGV/SIGBUS/SIGFPE or Watchdog SIGUSR1
			fmt.eprintfln(
				"[RECOVERY] Shard %d performing Level 2 recovery (Reason: %d)",
				shard.id,
				recovery_reason,
			)

			when !TINA_SIMULATION_MODE {
				// siglongjmp bypasses defer statements; sweep temp allocations
				// orphaned by panic string formatting before full teardown.
				free_all(context.temp_allocator)
				// Unblock signals masked by the OS during handler execution.
				os_signals_restore_thread_mask()
			}

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
