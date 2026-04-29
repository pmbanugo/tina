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

@(test)
test_method_mask_membership :: proc(t: ^testing.T) {
	mask := Method_Mask{.GET, .POST}

	testing.expect(t, .GET in mask, "GET should be in {GET, POST}")
	testing.expect(t, .POST in mask, "POST should be in {GET, POST}")
	testing.expect(t, .DELETE not_in mask, "DELETE should not be in {GET, POST}")
	testing.expect(t, .HEAD not_in mask, "HEAD should not be in {GET, POST}")
}

@(test)
test_method_mask_set_operations :: proc(t: ^testing.T) {
	mask_a := Method_Mask{.GET, .HEAD}
	mask_b := Method_Mask{.GET, .POST}

	// Union
	union_mask := mask_a + mask_b
	testing.expect(t, .GET in union_mask, "GET in union")
	testing.expect(t, .HEAD in union_mask, "HEAD in union")
	testing.expect(t, .POST in union_mask, "POST in union")

	// Intersection
	intersection := mask_a & mask_b
	testing.expect(t, .GET in intersection, "GET in intersection")
	testing.expect(t, .HEAD not_in intersection, "HEAD not in intersection")
	testing.expect(t, .POST not_in intersection, "POST not in intersection")
}
