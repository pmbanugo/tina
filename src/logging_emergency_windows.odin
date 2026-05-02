#+build windows
package tina

import win "core:sys/windows"

// ============================================================================
// Emergency Log Sink — Windows
// ============================================================================
// Only the byte sink is platform-specific. The record walk lives in
// logging_emergency.odin so POSIX and Windows share one layout-aware path.
// WriteFile on STD_ERROR_HANDLE is the closest analogue to write(2) and is
// safe to invoke from a top-level exception filter / vectored handler.

@(private = "package")
_write_stderr :: proc "contextless" (data: []u8) {
	if len(data) == 0 do return
	h := win.GetStdHandle(win.STD_ERROR_HANDLE)
	if h == win.INVALID_HANDLE_VALUE do return
	written: win.DWORD
	win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &written, nil)
}
