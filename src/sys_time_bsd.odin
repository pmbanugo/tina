#+build freebsd, openbsd, netbsd
package tina

import "core:sys/posix"

// Returns nanoseconds since an arbitrary epoch.
os_monotonic_time_ns :: proc "contextless" () -> u64 {
	ts: posix.timespec
	// Note: BSDs lack a unified CLOCK_BOOTTIME equivalent that is
	// uniformly supported. MONOTONIC is used as the fallback here.
	// However, MONOTONIC increments in SI	seconds, even while the	system	is  suspended.
	// https://man.freebsd.org/cgi/man.cgi?query=clock_gettime
	posix.clock_gettime(.MONOTONIC, &ts)

	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}
