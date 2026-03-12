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

// Atomically read the current process phase.
get_process_phase :: #force_inline proc "contextless" () -> Process_Phase {
	return cast(Process_Phase)sync.atomic_load_explicit(cast(^u8)&g_process_phase, .Relaxed)
}

// Atomically set the process phase. (Called primarily by the watchdog/main thread).
set_process_phase :: #force_inline proc "contextless" (phase: Process_Phase) {
	sync.atomic_store_explicit(cast(^u8)&g_process_phase, u8(phase), .Relaxed)
}
