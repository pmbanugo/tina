#+build windows
package http_server

import tina "../../.."
import win "core:sys/windows"

when !tina.TINA_SIMULATION_MODE {
wall_clock_unix_epoch_ns :: proc "contextless" (monotonic_ns: u64) -> u64 {
	_ = monotonic_ns
	file_time := win.FILETIME{}
	win.GetSystemTimeAsFileTime(&file_time)

	unix_epoch_ns := win.FILETIME_as_unix_nanoseconds(file_time)
	if unix_epoch_ns < 0 {
		return 0
	}
	return u64(unix_epoch_ns)
}
}
