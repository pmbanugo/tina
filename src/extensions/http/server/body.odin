package http_server

import "core:mem"
import "core:testing"

// Drains up to `len(destination)` bytes from `network` into `destination`.
// Extracts pure payload without allocating.
// Returns the number of bytes actually copied.
@(require_results)
drain_buffered_body :: #force_inline proc "contextless" (
	network: []u8,
	destination: []u8,
) -> int {
	copy_size := min(len(network), len(destination))
	if copy_size > 0 {
		mem.copy(raw_data(destination), raw_data(network), copy_size)
	}
	return copy_size
}

// Retains unconsumed pipeline bytes into the pipeline region.
// If the unconsumed source exceeds the destination budget, it returns
// `budget_exceeded = true`, allowing the caller to close the connection
// after the current response.
@(require_results)
retain_pipeline_tail :: #force_inline proc "contextless" (
	unconsumed_source: []u8,
	destination_pipeline_region: []u8,
) -> (
	retained_size: int,
	budget_exceeded: bool,
) {
	source_size := len(unconsumed_source)
	if source_size == 0 {
		return 0, false
	}

	if source_size > len(destination_pipeline_region) {
		return 0, true
	}

	mem.copy(raw_data(destination_pipeline_region), raw_data(unconsumed_source), source_size)
	return source_size, false
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_drain_buffered_body :: proc(t: ^testing.T) {
	network_data := []u8{1, 2, 3, 4, 5, 6, 7, 8}

	// Test partial drain (budget < network)
	destination_small := make([]u8, 4)
	defer delete(destination_small)
	copied_small := drain_buffered_body(network_data, destination_small)
	testing.expect_value(t, copied_small, 4)
	testing.expect_value(t, destination_small[0], 1)
	testing.expect_value(t, destination_small[3], 4)

	// Test full drain (budget > network)
	destination_large := make([]u8, 10)
	defer delete(destination_large)
	copied_large := drain_buffered_body(network_data, destination_large)
	testing.expect_value(t, copied_large, 8)
	testing.expect_value(t, destination_large[7], 8)
}

@(test)
test_retain_pipeline_tail :: proc(t: ^testing.T) {
	// Simulate "GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\n\r\n"
	request_two := "GET /2 HTTP/1.1\r\n\r\n"
	unconsumed := transmute([]u8)request_two

	// Budget is large enough
	pipeline_region := make([]u8, 64)
	defer delete(pipeline_region)

	retained_size, budget_exceeded := retain_pipeline_tail(unconsumed, pipeline_region)
	testing.expect_value(t, budget_exceeded, false)
	testing.expect_value(t, retained_size, len(request_two))
	testing.expect_value(t, string(pipeline_region[:retained_size]), request_two)

	// Budget is too small
	small_region := make([]u8, 4)
	defer delete(small_region)

	retained_size_small, budget_exceeded_small := retain_pipeline_tail(unconsumed, small_region)
	testing.expect_value(t, budget_exceeded_small, true)
	testing.expect_value(t, retained_size_small, 0)
}
