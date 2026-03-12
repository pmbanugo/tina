#+build linux
package tina

import "core:sys/posix"

TINA_SIGALTSTACK_SIZE :: 65536

foreign import libc "system:c"

cpu_set_t :: struct {
	bits: [16]u64, // 1024 bits total
}

@(default_calling_convention = "c")
foreign libc {
	sched_setaffinity :: proc(pid: posix.pid_t, cpusetsize: uint, mask: ^cpu_set_t) -> i32 ---
}

os_pin_thread_to_core :: proc(core_id: i32) -> bool {
	if core_id < 0 do return true // No affinity requested

	mask: cpu_set_t
	idx := core_id / 64
	bit := u64(1) << u64(core_id % 64)
	mask.bits[idx] |= bit

	return sched_setaffinity(0, size_of(cpu_set_t), &mask) == 0
}

os_install_sigaltstack :: proc(memory: []u8) -> bool {
	if len(memory) < TINA_SIGALTSTACK_SIZE do return false
	ss := posix.stack_t {
		ss_sp    = raw_data(memory),
		ss_size  = uint(len(memory)),
		ss_flags = {},
	}
	return posix.sigaltstack(&ss, nil) == .OK
}

// Linux-specific madvise flags
MADV_HUGEPAGE :: 14
MADV_POPULATE_WRITE :: 23

os_apply_memory_policy :: proc(memory: []u8, node_id: i32, mode: Memory_Init_Mode) -> bool {
	if mode != .Production || len(memory) == 0 do return true

	addr := raw_data(memory)
	size := uint(len(memory))

	// 1. NUMA bind (mbind) is deferred to prevent hard -lnuma linkage issues in v1.
	// Thread pinning handles local faulting allocation adequately for now.

	// 2. Advise huge pages
	posix.madvise(addr, size, MADV_HUGEPAGE)

	// 3. Pre-fault: Try MADV_POPULATE_WRITE (Linux 5.14+)
	if posix.madvise(addr, size, MADV_POPULATE_WRITE) != .OK {
		// Fallback: Sequential touch loop to force physical allocation
		page_size := 4096
		for i := 0; i < len(memory); i += page_size {
			memory[i] = 0
		}
	}

	return true
}

foreign import pthread "system:pthread"
@(default_calling_convention = "c")
foreign pthread {
	pthread_setname_np :: proc(thread: posix.pthread_t, name: cstring) -> c.int ---
	pthread_self :: proc() -> posix.pthread_t ---
}

// Zero-allocation thread naming using a stack buffer
os_set_current_thread_name :: proc "contextless" (name: string) {
	buf: [16]u8
	length := min(len(name), 15)

	// Copy bytes manually to avoid standard library dependencies
	for i in 0 ..< length {
		buf[i] = name[i]
	}
	buf[length] = 0 // Null terminator

	pthread_setname_np(pthread_self(), cast(cstring)&buf[0])
}

// Returns the OS-specific thread handle (pthread_t on POSIX)
os_get_current_thread_handle :: proc "contextless" () -> rawptr {
	return rawptr(pthread_self())
}

// Sends a signal directly to a specific thread (for Watchdog forced recovery)
os_signal_thread :: proc "contextless" (thread_handle: rawptr, sig: posix.Signal) {
	// pthread_kill requires the pthread_t and the signal number
	posix.pthread_kill(posix.pthread_t(thread_handle), c.int(sig))
}

// Fast kernel process teardown (bypasses atexit handlers)
os_force_exit :: proc "contextless" (status: c.int) -> ! {
	posix._exit(status)
}
