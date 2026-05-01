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

@(private = "package")
load_watchdog_state :: #force_inline proc "contextless" (runtime_state: ^Shard_Runtime_State) -> Shard_State {
	return cast(Shard_State)sync.atomic_load_explicit(&runtime_state.watchdog_state, .Relaxed)
}

@(private = "package")
store_watchdog_state :: proc {
	_store_watchdog_state_runtime,
	_store_watchdog_state_shard,
}

@(private = "package")
_store_watchdog_state_runtime :: #force_inline proc "contextless" (
	runtime_state: ^Shard_Runtime_State,
	state: Shard_State,
) {
	sync.atomic_store_explicit(&runtime_state.watchdog_state, u8(state), .Release)
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

@(private = "package")
_store_watchdog_state_shard :: #force_inline proc "contextless" (shard: ^Shard, state: Shard_State) {
	sync.atomic_store_explicit(shard.watchdog_state_pointer, u8(state), .Release)
}

// Atomically read the current process phase.
load_process_phase :: #force_inline proc "contextless" () -> Process_Phase {
	return cast(Process_Phase)sync.atomic_load_explicit(cast(^u8)&g_process_phase, .Relaxed)
}

// Atomically set the process phase. (Called primarily by the watchdog/main thread).
store_process_phase :: #force_inline proc "contextless" (phase: Process_Phase) {
	sync.atomic_store_explicit(cast(^u8)&g_process_phase, u8(phase), .Relaxed)
}
