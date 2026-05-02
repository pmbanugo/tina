#+build linux, darwin, freebsd, openbsd, netbsd

package tina

import "core:sys/posix"

// ============================================================================
// Emergency Log Sink — POSIX
// ============================================================================
// Only the byte sink is platform-specific. The record walk lives in
// logging_emergency.odin so POSIX and Windows share one layout-aware path.
// posix.write is async-signal-safe (POSIX.1-2017 §2.4.3).

STDERR_FD :: posix.FD(2)

@(private = "package")
_write_stderr :: proc "contextless" (data: []u8) {
	if len(data) == 0 do return
	posix.write(STDERR_FD, raw_data(data), uint(len(data)))
}
