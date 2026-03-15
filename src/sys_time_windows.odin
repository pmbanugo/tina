#+build windows
package tina

import win "core:sys/windows"

// Returns nanoseconds since an arbitrary epoch.
// Uses QueryPerformanceCounter for high-resolution hardware ticks.
os_monotonic_time_ns :: proc "contextless" () -> u64 {
	@(thread_local)
	freq: win.LARGE_INTEGER
	@(thread_local)
	initialized := false

	if !initialized {
		win.QueryPerformanceFrequency(&freq)
		initialized = true
	}

	now: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&now)

	// Cast to u128 to safely multiply by 1_000_000_000 without overflow,
	// then divide by the QPC frequency to get pure nanoseconds.
	return u64((u128(now) * 1_000_000_000) / u128(freq))
}
