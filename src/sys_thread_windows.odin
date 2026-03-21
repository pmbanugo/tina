#+build windows
package tina

import "core:c"
import "core:sys/posix"
import win "core:sys/windows"

TINA_SIGALTSTACK_SIZE :: 65536

os_pin_thread_to_core :: proc(core_id: i32) -> bool {
	if core_id < 0 do return true
	thread := win.GetCurrentThread()
	mask := cast(win.DWORD_PTR)(1 << u64(core_id))
	return win.SetThreadAffinityMask(thread, mask) != 0
}

os_install_sigaltstack :: proc(memory: []u8) -> bool {
	// Windows does not use POSIX sigaltstack; it uses SEH/VEH for structured exception handling.
	// We treat this as a successful no-op.
	return true
}

os_apply_memory_policy :: proc(memory: []u8, node_id: i32, mode: Memory_Init_Mode) -> bool {
	if mode != .Production || len(memory) == 0 do return true

	// Windows commits on allocation, but a manual touch loop forces
	// physical page instantiation into the working set.
	page_size := 4096
	for i := 0; i < len(memory); i += page_size {
		memory[i] = 0
	}
	return true
}
// Windows requires UTF-16, so we use the thread-local temp allocator
// and immediately clear it to remain strictly "no persistent malloc"
os_set_current_thread_name :: proc(name: string) {
	w_name := win.utf8_to_wstring(name, context.temp_allocator)
	win.SetThreadDescription(win.GetCurrentThread(), w_name)
	free_all(context.temp_allocator)
}

os_get_current_thread_handle :: proc "contextless" () -> rawptr {
	// A pseudo-handle or ID is enough since we no-op the signaling
	return rawptr(uintptr(win.GetCurrentThreadId()))
}

os_signal_thread :: proc "contextless" (thread_handle: rawptr, sig: posix.Signal) {
	// No-op on Windows. Windows uses IOCP/SEH instead of POSIX signals.
	// Forced recovery via cross-thread interruption requires QueueUserAPC
	// or SuspendThread. I should tackle this later since it's (Tier 4).
}

os_force_exit :: proc "contextless" (status: c.int) -> ! {
	win.ExitProcess(u32(status))
}
