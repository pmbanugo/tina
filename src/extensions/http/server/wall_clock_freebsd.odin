#+build freebsd
package http_server

import tina "../../.."
import "core:sys/posix"

FREEBSD_CLOCK_REALTIME_FAST :: posix.Clock(5)

when !tina.TINA_SIMULATION_MODE {
wall_clock_unix_epoch_ns :: proc "contextless" (monotonic_ns: u64) -> u64 {
	_ = monotonic_ns
	timestamp: posix.timespec
	if posix.clock_gettime(FREEBSD_CLOCK_REALTIME_FAST, &timestamp) != .OK {
		if posix.clock_gettime(.REALTIME, &timestamp) != .OK {
			return 0
		}
	}

	return u64(timestamp.tv_sec) * NANOSECONDS_PER_SECOND + u64(timestamp.tv_nsec)
}
}
