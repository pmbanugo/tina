package tina

import "core:sync"

Process_Phase :: enum u8 {
	Bootstrap     = 0, // main() entry → Shard threads spawned
	Shard_Init    = 1, // Shard threads initializing (pin, fault, carve, build tree)
	Running       = 2, // All Shards in scheduler loops, watchdog active
	Shutting_Down = 3, // Graceful shutdown in progress
	Terminated    = 4, // All threads joined, process exiting
}

// The global process lifecycle state.
// Modified by the main/watchdog thread, read asynchronously by Shards (e.g. during exit).
g_process_phase: Process_Phase = .Bootstrap

// The shard's lifecycle state. The owning shard is the sole writer; the
// watchdog and bootstrap thread only read it (as untrusted health input).
// Watchdog-to-shard commands use the Control_Signal channel, not this state.
// Both the shard and the watchdog reach the state through the canonical
// Shard_Health_Report, so there is one source of truth.
// Shard-side callers pass shard.health_report.
@(private = "package")
load_reported_state :: #force_inline proc "contextless" (report: ^Shard_Health_Report) -> Shard_State {
	return cast(Shard_State)sync.atomic_load_explicit(&report.reported_state, .Relaxed)
}

// Acquire load pairs with the shard's Release store of .Running, publishing the
// shard_pointer / os_thread_handle the shard wrote into its report beforehand.
@(private = "package")
load_reported_state_acquire :: #force_inline proc "contextless" (report: ^Shard_Health_Report) -> Shard_State {
	return cast(Shard_State)sync.atomic_load_explicit(&report.reported_state, .Acquire)
}

shard_state_label :: #force_inline proc "contextless" (state: Shard_State) -> string {
	@(static, rodata)
	labels := [Shard_State]string {
		.Init          = "Init",
		.Running       = "Running",
		.Quarantined   = "Quarantined",
		.Shutting_Down = "Shutting_Down",
		.Terminated    = "Terminated",
	}
	return labels[state]
}

@(private = "package")
store_reported_state :: #force_inline proc "contextless" (
	report: ^Shard_Health_Report,
	state: Shard_State,
) {
	sync.atomic_store_explicit(&report.reported_state, u8(state), .Release)
}

@(private = "package")
load_shard_control_signal :: #force_inline proc "contextless" (shard: ^Shard) -> Control_Signal {
	return cast(Control_Signal)sync.atomic_load_explicit(cast(^u8)&shard.control_signal, .Relaxed)
}

@(private = "package")
store_shard_control_signal :: #force_inline proc "contextless" (
	shard: ^Shard,
	signal: Control_Signal,
) {
	sync.atomic_store_explicit(cast(^u8)&shard.control_signal, u8(signal), .Relaxed)
}

// Atomically read the current process phase.
load_process_phase :: #force_inline proc "contextless" () -> Process_Phase {
	return cast(Process_Phase)sync.atomic_load_explicit(cast(^u8)&g_process_phase, .Relaxed)
}

// Atomically set the process phase. (Called primarily by the watchdog/main thread).
store_process_phase :: #force_inline proc "contextless" (phase: Process_Phase) {
	sync.atomic_store_explicit(cast(^u8)&g_process_phase, u8(phase), .Relaxed)
}
