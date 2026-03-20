#+build linux
package tina

import "core:sys/linux"

// Returns nanoseconds since an arbitrary epoch (boot).
// BOOTTIME includes time spent in suspend/sleep states,
// unlike MONOTONIC. Guaranteed to include suspend time. Expected fast VDSO call.
os_monotonic_time_ns :: proc "contextless" () -> u64 {
	ts, _ := linux.clock_gettime(.BOOTTIME)

	return u64(ts.time_sec) * 1_000_000_000 + u64(ts.time_nsec)
}
