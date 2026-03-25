#+build windows
package tina

import win "core:sys/windows"

os_signals_init_process :: #force_inline proc "contextless" () {
	// Windows manages process termination via SetConsoleCtrlHandler,
	// which is handled separately or unimplemented for this layer.
}

os_signals_init_thread :: #force_inline proc "contextless" () {
	// No-op on Windows
}

os_signals_restore_thread_mask :: #force_inline proc "contextless" () {
	// No-op on Windows
}

os_abort :: #force_inline proc "contextless" () -> ! {
	win.ExitProcess(1)
}
