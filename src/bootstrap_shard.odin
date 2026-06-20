package tina

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

@(private = "package")
_check_and_record_shard_restart :: proc(
	runtime_state: ^Shard_Runtime_State,
	spec: ^SystemSpec,
	wall_now_ns: u64,
) -> bool {
	window_duration_ns := u64(spec.watchdog.shard_restart_window_ms) * 1_000_000
	if window_duration_ns == 0 do window_duration_ns = 30 * u64(time.Second)

	restart_count_max := spec.watchdog.shard_restart_max
	if restart_count_max == 0 do restart_count_max = 3

	if runtime_state.restart_window_start_ns == 0 ||
	   wall_now_ns - runtime_state.restart_window_start_ns >= window_duration_ns {
		runtime_state.restart_window_start_ns = wall_now_ns
		runtime_state.restart_count = 1
		return false
	}

	runtime_state.restart_count += 1
	return runtime_state.restart_count > restart_count_max
}

// Custom assertion handler that routes Odin software panics into Tina's Trap Boundary.
// Uses only async-signal-safe operations (stack buffer + write(2)). No fmt, no allocator.
tina_assertion_failure_proc :: proc(
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) -> ! {
	shard := g_current_shard_pointer
	if shard != nil {
		buf: [1024]u8
		n := _sig_append_str(buf[:], 0, "[SOFTWARE PANIC] Shard ")
		n = _sig_append_u64(buf[:], n, u64(shard.id))
		n = _sig_append_str(buf[:], n, ": ")
		n = _sig_append_str(buf[:], n, prefix)
		n = _sig_append_str(buf[:], n, message)
		n = _sig_append_str(buf[:], n, " at ")
		n = _sig_append_str(buf[:], n, loc.file_path)
		n = _sig_append_str(buf[:], n, ":")
		n = _sig_append_u64(buf[:], n, u64(loc.line))
		n = _sig_append_str(buf[:], n, ":")
		n = _sig_append_u64(buf[:], n, u64(loc.column))
		n = _sig_append_str(buf[:], n, " in ")
		n = _sig_append_str(buf[:], n, loc.procedure)
		n = _sig_append_str(buf[:], n, "\n")
		_write_stderr(buf[:n])
		trigger_tier2_panic(shard)
	} else {
		buf: [1024]u8
		n := _sig_append_str(buf[:], 0, "[FATAL PANIC] Non-shard thread: ")
		n = _sig_append_str(buf[:], n, prefix)
		n = _sig_append_str(buf[:], n, message)
		n = _sig_append_str(buf[:], n, " at ")
		n = _sig_append_str(buf[:], n, loc.file_path)
		n = _sig_append_str(buf[:], n, ":")
		n = _sig_append_u64(buf[:], n, u64(loc.line))
		n = _sig_append_str(buf[:], n, ":")
		n = _sig_append_u64(buf[:], n, u64(loc.column))
		n = _sig_append_str(buf[:], n, " in ")
		n = _sig_append_str(buf[:], n, loc.procedure)
		n = _sig_append_str(buf[:], n, "\n")
		_write_stderr(buf[:n])
		os_abort()
	}
}

// The entry point for every Shard OS thread.
shard_thread_entry :: proc(t: ^thread.Thread) {
	config := cast(^Shard_Config)t.data
	runtime_state := config.runtime_state
	name_bufffer: [32]u8
	name_string := fmt.bprintf(name_bufffer[:], "tina-shard-%d", config.shard_id)
	os_set_current_thread_name(name_string)

	runtime_state.os_thread_handle = os_get_current_thread_handle()

	// Hook Odin's software panics into the Tina Trap Boundary
	context.assertion_failure_proc = tina_assertion_failure_proc

	shard := new(Shard)
	defer free(shard)

	runtime_state.shard_pointer = shard
	g_current_shard_pointer = shard
	shard.id = config.shard_id
	shard.shard_count = config.system_spec.shard_count
	shard.watchdog_state_pointer = &runtime_state.watchdog_state

	os_pin_thread_to_core(i32(config.target_core))

	when !TINA_SIMULATION_MODE {
		os_signals_init_thread()
	}

	sigstack_mem, sigstack_error := os_reserve_arena_with_guard(TINA_SIGALTSTACK_SIZE)
	if sigstack_error == .None {
		os_install_sigaltstack(sigstack_mem)
	}

	os_apply_memory_policy(config.grand_arena_base, -1, config.system_spec.memory_init_mode)

	// ==========================================================
	// S7-S10: Hydrate ONCE. Do not put this in a recovery loop.
	// ==========================================================
	arena := Grand_Arena{}
	if error := grand_arena_init_from_memory(
		&arena,
		config.grand_arena_base,
		config.total_memory_size,
	); error != .None {
		fmt.eprintfln("[FATAL] Shard %d Grand Arena backing is too small: %v", config.shard_id, error)
		store_watchdog_state(runtime_state, .Terminated)
		return
	}

	if error := hydrate_shard(&arena, config.system_spec, shard); error != .None {
		fmt.eprintfln("[FATAL] Shard %d failed to hydrate memory: %v", config.shard_id, error)
		store_watchdog_state(runtime_state, .Terminated)
		return
	}

	remote_shard_count := int(config.system_spec.shard_count) - 1
	shard.outbound_rings = config.outbound_rings[:remote_shard_count]
	shard.inbound_rings = config.inbound_rings[:remote_shard_count]
	shard.outbound_control_channels = config.outbound_control_channels[:remote_shard_count]
	shard.inbound_control_channel = config.inbound_control_channel

	assert(len(shard.outbound_rings) == remote_shard_count)
	assert(len(shard.inbound_rings) == remote_shard_count)
	assert(len(shard.outbound_control_channels) == remote_shard_count)
	assert(shard.inbound_control_channel != nil)
	for ring in shard.outbound_rings {
		assert(ring != nil)
	}
	for ring in shard.inbound_rings {
		assert(ring != nil)
	}
	for channel in shard.outbound_control_channels {
		assert(channel != nil)
	}

	// S11. Install shard-level sigsetjmp recovery point
	for {
		recovery_reason := os_trap_save(&shard.trap_environment_outer)

		if recovery_reason != 0 {
			// CRASH PATH: Caught SIGSEGV/BUS/FPE (1), Watchdog SIGUSR1 (2), Root Escalate (3), Soft Kill (4)
			fmt.eprintfln(
				"[RECOVERY] Shard %d performing Level 2 recovery (Reason: %s)",
				shard.id,
				recovery_reason_label(recovery_reason),
			)

			when !TINA_SIMULATION_MODE {
				free_all(context.temp_allocator)
				os_signals_restore_thread_mask()
			}

			// The emergency signal flush may have advanced read_cursor without
			// updating ASan shadow state. Repair the poison invariant at this
			// non-signal recovery safe point before any further logging.
			_sanitizer_address_refresh_log_ring_poison(&shard.log_ring)

			// 1. Evaluate Shard Restart Intensity using watchdog-owned policy.
			wall_now_ns := os_monotonic_time_ns()
			if _check_and_record_shard_restart(runtime_state, config.system_spec, wall_now_ns) {
				if config.system_spec.quarantine_policy == .Abort {
					fmt.eprintfln(
						"[FATAL] Shard %d exceeded restart limits. Policy: Abort. Force Killing Process.",
						shard.id,
					)
					os_force_exit(1)
				} else {
					fmt.eprintfln(
						"[QUARANTINE] Shard %d exceeded restart limits. Quarantining.",
						shard.id,
					)
					store_watchdog_state(runtime_state, .Quarantined)
					_fd_handoff_close_all_entries(shard, false)


					shard_broadcast_liveness_state(shard, .Quarantined)
					transport_flush_control_outbound(shard)
				}
			} else {
				shard_mass_teardown(shard)
			}
		} else {
			// FIRST-TIME BOOT PATH
			when !TINA_SIMULATION_MODE {
				now_ns := os_monotonic_time_ns()
				shard.current_tick = now_ns / shard.timer_resolution_ns
				sync.atomic_store_explicit(&shard.heartbeat_tick, shard.current_tick, .Relaxed)
			}
		}

		// 3. The Dormant Sleep Loop (Fixes Silent Escapes)
		state := load_watchdog_state(runtime_state)
		if state == .Quarantined {
			// Poll interval derived from watchdog cadence — never faster than the watchdog can act.
			poll_ms := config.system_spec.watchdog.check_interval_ms
			if poll_ms == 0 do poll_ms = 500
			poll_interval := time.Duration(poll_ms) * time.Millisecond

			for load_watchdog_state(runtime_state) == .Quarantined {
				transport_retry_liveness_broadcast(shard)
				transport_flush_control_outbound(shard)

				phase := load_process_phase()
				if phase == .Shutting_Down || phase == .Terminated {
					store_watchdog_state(runtime_state, .Terminated)
					return // Safely exit thread to unblock watchdog join
				}
				when !TINA_SIMULATION_MODE {
					time.sleep(poll_interval)
				}
			}

			// Recovered from quarantine! Reset limits and force a clean rebuild.
			runtime_state.restart_count = 0
			runtime_state.restart_window_start_ns = os_monotonic_time_ns()
			shard_mass_teardown(shard)
		}

		// 4. Rebuild & Run
		arena_alloc_data := Grand_Arena_Allocator_Data {
			arena = &arena,
		}
		arena_alloc := grand_arena_allocator(&arena_alloc_data)
		build_result, build_error := shard_build_supervision_tree(
			shard,
			&config.shard_spec.root_group,
			arena_alloc,
			&arena_alloc_data,
		)
		if build_error != .None {
			fmt.eprintfln(
				"[FATAL] Shard %d failed to build supervision tree: %v",
				config.shard_id,
				build_error,
			)
			store_watchdog_state(runtime_state, .Terminated)
			return
		}
		if build_result != .Ok {
			fmt.eprintfln("[FATAL] Shard %d supervision tree build escalated", config.shard_id)
			store_watchdog_state(runtime_state, .Terminated)
			return
		}

		if recovery_reason == 0 {
			if config.shard_id == 0 do arena_print_layout(&arena)
			sync.barrier_wait(config.barrier)
		}

		// Safe transition to Running (Never blindly overwrite a Quarantined state)
		store_watchdog_state(runtime_state, .Running)

		// S16. Enter scheduler loop
		for {
			current_state := load_watchdog_state(runtime_state)
			if current_state == .Shutting_Down && !shard_has_live_isolates(shard) do break
			if current_state != .Running && current_state != .Shutting_Down do break

			scheduler_tick(shard)
		}

		if load_watchdog_state(runtime_state) != .Running do break
	}

	when TINA_RUNTIME_ASSERTIONS {
		// Clean exit after graceful drain.
		// After all Isolates returned .done and the last scheduler_tick drained
		// any remaining stale I/O completions, every reactor buffer should be back
		// in the free pool. A mismatch means a buffer leaked — either the
		// io_sequence stale-path failed to free it, or teardown step 2b missed one.
		assert(
			shard.reactor.receive_pool.free_count == shard.reactor.receive_pool.slot_count,
			"Reactor buffer pool leak: not all buffers reclaimed after shutdown drain",
		)
		assert(
			shard.reactor.staging_pool.free_count == shard.reactor.staging_pool.slot_count,
			"I/O Staging pool leak: not all staging slots reclaimed after shutdown drain",
		)
	}

	log_flush(shard)
	store_watchdog_state(runtime_state, .Terminated)
}
