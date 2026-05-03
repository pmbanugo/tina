package http_server

import "core:testing"

Method :: enum u8 {
	GET,
	POST,
	PUT,
	DELETE,
	PATCH,
	HEAD,
	OPTIONS,
	TRACE,
}

// Used for method matching via `request_method in route_method_mask`.
Method_Mask :: distinct bit_set[Method;u8]


// HTTP status code (100..599).
HTTP_Status :: distinct u16


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_method_enum_values :: proc(t: ^testing.T) {
	// GET must be 0 — the fast-path default.
	testing.expect_value(t, u8(Method.GET), 0)
	testing.expect_value(t, u8(Method.POST), 1)
	testing.expect_value(t, u8(Method.PUT), 2)
	testing.expect_value(t, u8(Method.DELETE), 3)
	testing.expect_value(t, u8(Method.PATCH), 4)
	testing.expect_value(t, u8(Method.HEAD), 5)
	testing.expect_value(t, u8(Method.OPTIONS), 6)
	testing.expect_value(t, u8(Method.TRACE), 7)
}
