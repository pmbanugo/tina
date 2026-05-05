#+build linux
package http_server

import tina "../../.."
import "core:sys/linux"

when !tina.TINA_SIMULATION_MODE {
wall_clock_unix_epoch_ns :: proc "contextless" (monotonic_ns: u64) -> u64 {
	_ = monotonic_ns
	timestamp, error_code := linux.clock_gettime(.REALTIME_COARSE)
	if error_code != .NONE {
		timestamp, error_code = linux.clock_gettime(.REALTIME)
		if error_code != .NONE {
			return 0
		}
	}

	return u64(timestamp.time_sec) * NANOSECONDS_PER_SECOND + u64(timestamp.time_nsec)
}
}
