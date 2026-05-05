package http_server

import tina "../../.."

when tina.TINA_SIMULATION_MODE {
wall_clock_unix_epoch_ns :: proc "contextless" (monotonic_ns: u64) -> u64 {
	// Simulation wall clock is deterministic by construction: derive wall time
	// directly from the scheduler's monotonic tick time.
	return monotonic_ns
}
}
