#+build darwin, freebsd, openbsd, netbsd
package tina

import "core:c"
import "core:sys/posix"

TINA_SIGALTSTACK_SIZE :: 65536

os_pin_thread_to_core :: proc(core_id: i32) -> bool {
	// macOS thread pinning (mach thread_policy_set) is notoriously hostile.
	// Since macOS is the Development target, we treat pinning as a best-effort no-op.
	return true
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

os_apply_memory_policy :: proc(memory: []u8, node_id: i32, mode: Memory_Init_Mode) -> bool {
	if mode != .Production || len(memory) == 0 do return true

	// macOS lacks THP and MADV_POPULATE_WRITE.
	// Fall back to manual touch loop to pre-fault pages.
	page_size := 4096
	for i := 0; i < len(memory); i += page_size {
		memory[i] = 0
	}
	return true
}

when ODIN_OS == .Darwin {
	foreign import pthread "system:pthread"
	@(default_calling_convention = "c")
	foreign pthread {
		pthread_setname_np :: proc(name: cstring) -> c.int ---
		pthread_self :: proc() -> posix.pthread_t ---
	}

	os_set_current_thread_name :: proc "contextless" (name: string) {
		buf: [64]u8
		length := min(len(name), 63)
		for i in 0 ..< length do buf[i] = name[i]
		buf[length] = 0
		pthread_setname_np(cast(cstring)&buf[0])
	}

	// Returns the OS-specific thread handle (pthread_t on POSIX)
	os_get_current_thread_handle :: proc "contextless" () -> rawptr {
		return rawptr(pthread_self())
	}

	// Sends a signal directly to a specific thread (for Watchdog forced recovery)
	os_signal_thread :: proc "contextless" (thread_handle: rawptr, sig: posix.Signal) {
		// pthread_kill requires the pthread_t and the signal number
		posix.pthread_kill(posix.pthread_t(thread_handle), sig)
	}
} else {
	// FreeBSD, OpenBSD, NetBSD
	foreign import pthread "system:pthread"
	@(default_calling_convention = "c")
	foreign pthread {
		pthread_set_name_np :: proc(thread: posix.pthread_t, name: cstring) ---
		pthread_self :: proc() -> posix.pthread_t ---
	}

	os_set_current_thread_name :: proc "contextless" (name: string) {
		buf: [32]u8
		length := min(len(name), 31)
		for i in 0 ..< length do buf[i] = name[i]
		buf[length] = 0
		pthread_set_name_np(pthread_self(), cast(cstring)&buf[0])
	}

	// Returns the OS-specific thread handle (pthread_t on POSIX)
	os_get_current_thread_handle :: proc "contextless" () -> rawptr {
		return rawptr(pthread_self())
	}

	// Sends a signal directly to a specific thread (for Watchdog forced recovery)
	os_signal_thread :: proc "contextless" (thread_handle: rawptr, sig: posix.Signal) {
		// pthread_kill requires the pthread_t and the signal number
		posix.pthread_kill(posix.pthread_t(thread_handle), sig)
	}
}

// Fast kernel process teardown (bypasses atexit handlers)
os_force_exit :: proc "contextless" (status: c.int) -> ! {
	posix._exit(status)
}
