package tina

import "core:sync"
import "core:sys/posix"
import "core:time"

// Cross-platform watchdog events, translated from OS signals by os_poll_watchdog_events.
Watchdog_Event :: enum u8 {
	None,
	Shutdown,
	Recover_Quarantine,
	Reload_Config,
}

Watchdog_Tracker :: struct {
	last_seen_heartbeat: [MAX_SHARDS]u64,
	stall_count:         [MAX_SHARDS]u8,
}

watchdog_loop :: proc(configs: []Shard_Config, spec: ^SystemSpec) {
	interval_ms := spec.watchdog.check_interval_ms
	if interval_ms == 0 do interval_ms = 500

	phase_2_threshold := spec.watchdog.phase_2_threshold
	if phase_2_threshold == 0 do phase_2_threshold = 2

	tracker: Watchdog_Tracker

	{
		buf: [128]u8
		position := _sig_append_str(buf[:], 0, "[SYSTEM] Process running. Watchdog active (interval: ")
		position = _sig_append_u64(buf[:], position, u64(interval_ms))
		position = _sig_append_str(buf[:], position, " ms).\n")
		_write_stderr(buf[:position])
	}

	for {
		event := os_poll_watchdog_events(interval_ms)

		switch event {
		case .Shutdown:
			_write_stderr(transmute([]u8)string("\n[WATCHDOG] Initiating Graceful Shutdown...\n"))
			_execute_graceful_shutdown(configs, spec)
			return

		case .Recover_Quarantine:
			_write_stderr(transmute([]u8)string("[WATCHDOG] Recovering quarantined Shards.\n"))
			for i in 0 ..< spec.shard_count {
				state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
				if state == .Quarantined {
					tracker.stall_count[i] = 0
					configs[i].shard_restart_count = 0
					configs[i].shard_restart_window_ns = os_monotonic_time_ns()
					sync.atomic_store_explicit(&configs[i].watchdog_state, u8(Shard_State.Running), .Release)
					buf: [64]u8
					position := _sig_append_str(buf[:], 0, "[WATCHDOG] Shard ")
					position = _sig_append_u64(buf[:], position, u64(i))
					position = _sig_append_str(buf[:], position, " recovered from quarantine.\n")
					_write_stderr(buf[:position])
				}
			}

		case .Reload_Config:
			_write_stderr(transmute([]u8)string("[WATCHDOG] Reload config requested. (Reserved for future use).\n"))

		case .None:
			// Timeout (EAGAIN) — No OS signal received. Do periodic heartbeat work.
			for i in 0 ..< spec.shard_count {
				state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
				if state != .Running do continue

				shard := configs[i].shard_pointer
				if shard == nil do continue

				current_heartbeat := sync.atomic_load_explicit(&shard.heartbeat_tick, .Relaxed)

				if current_heartbeat == tracker.last_seen_heartbeat[i] {
					tracker.stall_count[i] += 1

					if tracker.stall_count[i] == 1 {
						// Phase 1: Cooperative Escalation
						sync.atomic_store_explicit(
							cast(^u8)&shard.control_signal,
							u8(Control_Signal.Kill),
							.Relaxed,
						)
						buf: [96]u8
						position := _sig_append_str(buf[:], 0, "[WATCHDOG] Shard ")
						position = _sig_append_u64(buf[:], position, u64(i))
						position = _sig_append_str(buf[:], position, " stalled. Phase 1 (Cooperative Kill) requested.\n")
						_write_stderr(buf[:position])

					} else if tracker.stall_count[i] >= phase_2_threshold {
						// Phase 2: Forced Recovery (SIGUSR1)
						buf: [96]u8
						position := _sig_append_str(buf[:], 0, "[WATCHDOG] Shard ")
						position = _sig_append_u64(buf[:], position, u64(i))
						position = _sig_append_str(buf[:], position, " hard-stalled. Phase 2 (Forced SIGUSR1) dispatched.\n")
						_write_stderr(buf[:position])
						os_signal_thread(configs[i].os_thread_handle, posix.Signal.SIGUSR1)
						tracker.stall_count[i] = 0
					}
				} else {
					// Progress made! Reset tracker.
					tracker.last_seen_heartbeat[i] = current_heartbeat
					tracker.stall_count[i] = 0
				}
			}
		}
	}
}

@(private = "file")
_execute_graceful_shutdown :: proc(configs: []Shard_Config, spec: ^SystemSpec) {
	set_process_phase(.Shutting_Down)

	// Notify all running shards via control signal
	for i in 0 ..< spec.shard_count {
		state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
		if state == .Running {
			shard := configs[i].shard_pointer
			if shard != nil {
				sync.atomic_store_explicit(
					cast(^u8)&shard.control_signal,
					u8(Control_Signal.Shutdown),
					.Relaxed,
				)
			}
		}
	}

	timeout_ms := spec.shutdown_timeout_ms
	if timeout_ms == 0 do timeout_ms = 30_000
	deadline := time.tick_now()

	interval_ms := spec.watchdog.check_interval_ms
	if interval_ms == 0 do interval_ms = 500

	phase_2_threshold := spec.watchdog.phase_2_threshold
	if phase_2_threshold == 0 do phase_2_threshold = 2

	tracker: Watchdog_Tracker

	// Phase 2: Monitor drain with continued heartbeat checking
	for {
		// Check for second SIGTERM (immediate force-kill escalation, §5.4)
		event := os_poll_watchdog_events(100)
		if event == .Shutdown {
			_write_stderr(transmute([]u8)string("[FATAL] Second signal received. Executing Phase 3 Force-Kill.\n"))
			_execute_phase3_force_kill(configs, spec)
		}

		// Check if all shards have cleanly terminated
		all_terminated := true
		for i in 0 ..< spec.shard_count {
			state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
			if state != .Terminated && state != .Quarantined {
				all_terminated = false
				break
			}
		}

		if all_terminated {
			_write_stderr(transmute([]u8)string("[SYSTEM] All Shards gracefully drained. Shutting down.\n"))
			return
		}

		// Heartbeat monitoring during drain (§5.2 — watchdog remains active)
		for i in 0 ..< spec.shard_count {
			state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
			if state != .Shutting_Down do continue

			shard := configs[i].shard_pointer
			if shard == nil do continue

			current_heartbeat := sync.atomic_load_explicit(&shard.heartbeat_tick, .Relaxed)
			if current_heartbeat == tracker.last_seen_heartbeat[i] {
				tracker.stall_count[i] += 1
				if tracker.stall_count[i] >= phase_2_threshold {
					{
						buf: [96]u8
						position := _sig_append_str(buf[:], 0, "[WATCHDOG] Shard ")
						position = _sig_append_u64(buf[:], position, u64(i))
						position = _sig_append_str(buf[:], position, " stalled during shutdown drain. Sending SIGUSR1.\n")
						_write_stderr(buf[:position])
					}
					os_signal_thread(configs[i].os_thread_handle, posix.Signal.SIGUSR1)
					tracker.stall_count[i] = 0
				}
			} else {
				tracker.last_seen_heartbeat[i] = current_heartbeat
				tracker.stall_count[i] = 0
			}
		}

		// Phase 3 deadline check
		if time.tick_diff(deadline, time.tick_now()) >
		   (time.Duration(timeout_ms) * time.Millisecond) {
			buf: [96]u8
			position := _sig_append_str(buf[:], 0, "[FATAL] Graceful shutdown timeout expired (")
			position = _sig_append_u64(buf[:], position, u64(timeout_ms))
			position = _sig_append_str(buf[:], position, " ms). Executing Phase 3 Force-Kill.\n")
			_write_stderr(buf[:position])
			_execute_phase3_force_kill(configs, spec)
		}
	}
}

@(private = "file")
_execute_phase3_force_kill :: proc(configs: []Shard_Config, spec: ^SystemSpec) -> ! {
	// Step 1: Log diagnostic
	alive_count := 0
	for i in 0 ..< spec.shard_count {
		state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
		if state != .Terminated && state != .Quarantined {
			alive_count += 1
		}
	}
	{
		buf: [96]u8
		position := _sig_append_str(buf[:], 0, "[FATAL] Phase 3 force-kill: ")
		position = _sig_append_u64(buf[:], position, u64(alive_count))
		position = _sig_append_str(buf[:], position, " shard(s) still alive. Emergency log flush.\n")
		_write_stderr(buf[:position])
	}

	// Step 2: Emergency log flush for all shards (best-effort, accepts data race)
	for i in 0 ..< spec.shard_count {
		shard := configs[i].shard_pointer
		if shard != nil {
			when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD || ODIN_OS == .Windows {
				emergency_log_flush_snapshot(shard)
				emergency_print_stalled_io_snapshot(shard)
			}
		}
	}

	// Step 3: Terminate (kernel reclaims all resources in O(1))
	os_force_exit(0)
}
