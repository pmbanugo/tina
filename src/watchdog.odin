package tina

import "core:c"
import "core:fmt"
import "core:sync"
import "core:sys/posix"
import "core:time"

// Structure of Arrays (SoA) for maximum cache locality during the EAGAIN heartbeat loop
Watchdog_Tracker :: struct {
	last_seen_heartbeat: [MAX_SHARDS]u64,
	stall_count:         [MAX_SHARDS]u8,
	restart_count:       [MAX_SHARDS]u16,
	window_start:        [MAX_SHARDS]time.Tick,
}

watchdog_loop :: proc(configs: []Shard_Config, states: []u8, spec: ^SystemSpec) {
	interval_ms := spec.watchdog.check_interval_ms
	if interval_ms == 0 do interval_ms = 500

	phase_2_threshold := spec.watchdog.phase_2_threshold
	if phase_2_threshold == 0 do phase_2_threshold = 2

	tracker: Watchdog_Tracker
	for i in 0 ..< spec.shard_count {
		tracker.window_start[i] = time.tick_now()
	}

	fmt.printfln("[SYSTEM] Process running. Watchdog active (interval: %v ms).", interval_ms)

	for {
		sig, sig_ok := os_wait_for_signal(interval_ms)

		if sig_ok {
			#partial switch sig {
			case .SIGTERM, .SIGINT:
				fmt.printfln(
					"\n[WATCHDOG] Received signal %v. Initiating Graceful Shutdown...",
					sig,
				)
				_execute_graceful_shutdown(configs, states, spec)
				return

			case .SIGUSR2:
				fmt.printfln("[WATCHDOG] Received SIGUSR2. Recovering quarantined Shards.")
				for i in 0 ..< spec.shard_count {
					state := cast(Shard_State)sync.atomic_load_explicit(&states[i], .Relaxed)
					if state == .Quarantined {
						// Reset tracking and unquarantine
						tracker.stall_count[i] = 0
						tracker.restart_count[i] = 0
						tracker.window_start[i] = time.tick_now()
						// Release the quarantine lock
						sync.atomic_store_explicit(&states[i], u8(Shard_State.Running), .Release)
						fmt.printfln("[WATCHDOG] Shard %d recovered from quarantine.", i)
					}
				}

			case .SIGHUP:
				fmt.printfln("[WATCHDOG] Received SIGHUP. (Reserved for future use).")
			}
		} else {
			// Timeout (EAGAIN) — No OS signal received. Do periodic heartbeat work.
			for i in 0 ..< spec.shard_count {
				state := cast(Shard_State)sync.atomic_load_explicit(&states[i], .Relaxed)
				if state != .Running do continue

				// We need access to the actual Shard pointer to read heartbeat_tick and control_signal.
				// In our architecture, the Shard struct is on the heap. We assume `configs[i]` can
				// give us what we need, but for brevity, we'll simulate the pointer access.
				// (If Shard pointer isn't directly in config, it should be passed back to the main thread during boot).

				// HACK: For demonstration, we'll assume we have a pointer.
				// You should ensure `Shard_Config` holds `shard_ptr: ^Shard` set during `shard_thread_entry`.
				shard := _get_shard_from_config(&configs[i])
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
						_handle_forced_recovery(shard, &configs[i], &states[i], &tracker, spec)
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
_handle_forced_recovery :: proc(
	shard: ^Shard,
	config: ^Shard_Config,
	state: ^u8,
	tracker: ^Watchdog_Tracker,
	spec: ^SystemSpec,
) {
	shard_id := shard.id
	now := time.tick_now()

	// ADR §6.5.5.2 Quarantine Window Calculation
	// Use root group spec for shard-level restart tracking (or default)
	window_duration :=
		time.Duration(spec.shard_specs[shard_id].root_group.window_duration_ticks) *
		time.Millisecond
	if window_duration == 0 do window_duration = 30 * time.Second

	max_restarts := spec.shard_specs[shard_id].root_group.restart_count_max
	if max_restarts == 0 do max_restarts = 3

	if time.tick_diff(tracker.window_start[shard_id], now) >= window_duration {
		// Outside window, reset tracking
		tracker.window_start[shard_id] = now
		tracker.restart_count[shard_id] = 1
	} else {
		tracker.restart_count[shard_id] += 1
	}

	if tracker.restart_count[shard_id] > max_restarts {
		if spec.quarantine_policy == .Abort {
			fmt.eprintfln(
				"[FATAL] Shard %d exceeded restart limits. Policy: Abort. Force Killing Process.",
				shard_id,
			)
			os_force_exit(1)
		} else {
			fmt.eprintfln("[QUARANTINE] Shard %d exceeded restart limits. Quarantining.", shard_id)
			sync.atomic_store_explicit(state, u8(Shard_State.Quarantined), .Release)

			// Broadcast SHARD_QUARANTINED to other shards via outbound rings
			for ring in shard.outbound_rings {
				if ring != nil {
					env := Message_Envelope {
						tag = TAG_SHUTDOWN,
					} // Reusing for quarantine signaling
					spsc_ring_enqueue(ring, &env)
					spsc_ring_flush_producer(ring)
				}
			}
			return
		}
	}

	// Not quarantined, send the violent SIGUSR1
	fmt.printfln(
		"[WATCHDOG] Shard %d hard-stalled. Phase 2 (Forced SIGUSR1) dispatched.",
		shard_id,
	)
	os_signal_thread(config.os_thread_handle, posix.Signal.SIGUSR1)
	tracker.stall_count[shard_id] = 0
}

@(private = "file")
_execute_graceful_shutdown :: proc(configs: []Shard_Config, states: []u8, spec: ^SystemSpec) {
	set_process_phase(.Shutting_Down)

	// Notify all running shards
	for i in 0 ..< spec.shard_count {
		state := cast(Shard_State)sync.atomic_load_explicit(&states[i], .Relaxed)
		if state == .Running {
			shard := _get_shard_from_config(&configs[i])
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

	// Phase 2: Monitor Drain
	for {
		// Wait for second SIGTERM (Immediate Force Kill Escallation)
		sig, sig_ok := os_wait_for_signal(100)
		if sig_ok && (sig == .SIGTERM || sig == .SIGINT) {
			fmt.eprintfln("[FATAL] Second SIGTERM received. Executing Phase 3 Force-Kill.")
			break
		}

		// Check if all shards have cleanly transitioned to Terminated
		all_terminated := true
		for i in 0 ..< spec.shard_count {
			state := cast(Shard_State)sync.atomic_load_explicit(&states[i], .Relaxed)
			if state != .Terminated && state != .Quarantined {
				all_terminated = false
				break
			}
		}

		if all_terminated {
			fmt.printfln("[SYSTEM] All Shards gracefully drained. Shutting down.")
			return
		}

		// Phase 3 Deadline Check
		if time.tick_diff(deadline, time.tick_now()) >
		   (time.Duration(timeout_ms) * time.Millisecond) {
			fmt.eprintfln(
				"[FATAL] Graceful shutdown timeout expired (%v ms). Executing Phase 3 Force-Kill.",
				timeout_ms,
			)
			break
		}
	}

	// Phase 3 Force-Kill
	os_force_exit(1)
}

// Helper: Needs to be set during thread init.
@(private = "file")
_get_shard_from_config :: proc(config: ^Shard_Config) -> ^Shard {
	return g_current_shard_ptr
}
