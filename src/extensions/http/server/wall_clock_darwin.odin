#+build darwin
package http_server

import tina "../../.."
import "core:sys/posix"

when !tina.TINA_SIMULATION_MODE {
wall_clock_unix_epoch_ns :: proc "contextless" (monotonic_ns: u64) -> u64 {
	_ = monotonic_ns
	timestamp: posix.timespec
	if posix.clock_gettime(.REALTIME, &timestamp) != .OK {
		return 0
	}

	return u64(timestamp.tv_sec) * NANOSECONDS_PER_SECOND + u64(timestamp.tv_nsec)
}
}
