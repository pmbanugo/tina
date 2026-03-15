#+build linux
package tina

import "core:sys/linux"

// CLOCK_BOOTTIME (7) includes time spent in suspend/sleep states,
// unlike CLOCK_MONOTONIC (1).
CLOCK_BOOTTIME :: 7

// Returns nanoseconds since an arbitrary epoch (boot).
// Guaranteed to include suspend time. Expected fast VDSO call.
os_monotonic_time_ns :: proc "contextless" () -> u64 {
	ts: linux.Time_Spec
	linux.clock_gettime(CLOCK_BOOTTIME, &ts)

	return u64(ts.time_sec) * 1_000_000_000 + u64(ts.time_nsec)
}
