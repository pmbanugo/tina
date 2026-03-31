package tina

import "core:fmt"
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

	fmt.printfln("[SYSTEM] Process running. Watchdog active (interval: %v ms).", interval_ms)

	for {
		event := os_poll_watchdog_events(interval_ms)

		switch event {
		case .Shutdown:
			fmt.printfln("\n[WATCHDOG] Initiating Graceful Shutdown...")
			_execute_graceful_shutdown(configs, spec)
			return

		case .Recover_Quarantine:
			fmt.printfln("[WATCHDOG] Recovering quarantined Shards.")
			for i in 0 ..< spec.shard_count {
				state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
				if state == .Quarantined {
					tracker.stall_count[i] = 0
					sync.atomic_store_explicit(&configs[i].watchdog_state, u8(Shard_State.Running), .Release)
					fmt.printfln("[WATCHDOG] Shard %d recovered from quarantine.", i)
				}
			}

		case .Reload_Config:
			fmt.printfln("[WATCHDOG] Reload config requested. (Reserved for future use).")

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
						fmt.printfln(
							"[WATCHDOG] Shard %d stalled. Phase 1 (Cooperative Kill) requested.",
							i,
						)

					} else if tracker.stall_count[i] >= phase_2_threshold {
						// Phase 2: Forced Recovery (SIGUSR1)
						fmt.printfln("[WATCHDOG] Shard %d hard-stalled. Phase 2 (Forced SIGUSR1) dispatched.", i)
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
			fmt.eprintfln("[FATAL] Second signal received. Executing Phase 3 Force-Kill.")
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
			fmt.printfln("[SYSTEM] All Shards gracefully drained. Shutting down.")
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
					fmt.eprintfln(
						"[WATCHDOG] Shard %d stalled during shutdown drain. Sending SIGUSR1.",
						i,
					)
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
			fmt.eprintfln(
				"[FATAL] Graceful shutdown timeout expired (%v ms). Executing Phase 3 Force-Kill.",
				timeout_ms,
			)
			_execute_phase3_force_kill(configs, spec)
		}
	}
}

@(private = "file")
_execute_phase3_force_kill :: proc(configs: []Shard_Config, spec: ^SystemSpec) -> ! {
	// Step 1: Log diagnostic
	alive := 0
	for i in 0 ..< spec.shard_count {
		state := cast(Shard_State)sync.atomic_load_explicit(&configs[i].watchdog_state, .Relaxed)
		if state != .Terminated && state != .Quarantined {
			alive += 1
		}
	}
	fmt.eprintfln(
		"[FATAL] Phase 3 force-kill: %d shard(s) still alive. Emergency log flush.",
		alive,
	)

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
