#+build darwin
package tina

import "core:c"

foreign import libc "system:c"

mach_timebase_info_data_t :: struct {
	numer: u32,
	denom: u32,
}

@(default_calling_convention = "c")
foreign libc {
	// mach_continuous_time includes sleep/suspend time,
	// unlike mach_absolute_time.
	mach_continuous_time :: proc() -> u64 ---
	mach_timebase_info :: proc(info: ^mach_timebase_info_data_t) -> c.int ---
}

// Returns nanoseconds since an arbitrary epoch (boot).
// Guaranteed to include suspend time.
os_monotonic_time_ns :: proc "contextless" () -> u64 {
	@(thread_local)
	timebase: mach_timebase_info_data_t
	@(thread_local)
	initialized := false

	if !initialized {
		mach_timebase_info(&timebase)
		initialized = true
	}

	ticks := mach_continuous_time()

	// Cast to u128 to prevent overflow during multiplication before division
	return u64((u128(ticks) * u128(timebase.numer)) / u128(timebase.denom))
}
