#+build windows

package tina

import "core:sys/posix"
import win "core:sys/windows"

// Windows: No POSIX signal waiting. Use a Sleep-based poll that returns EAGAIN (no signal).
// The watchdog graceful shutdown path relies on os_wait_for_signal returning (nil, false)
// on timeout, so heartbeat monitoring still works. Ctrl+C is handled separately by
// SetConsoleCtrlHandler at process level.
os_wait_for_signal :: proc(timeout_ms: u32) -> (sig: posix.Signal, ok: bool) {
	win.Sleep(win.DWORD(timeout_ms))
	return nil, false
}
