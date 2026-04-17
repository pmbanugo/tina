package http_server

import "core:testing"

// ─── HTTP Methods ───────────────────────────────────────────────────────────
//
// Enum values map 1:1 to RFC 9110 method tokens. The ordering is chosen so
// GET (the common case) occupies value 0 for branch-friendly default comparison.

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

// Branchless method matching via `request_method in route_method_mask`.
// A single bitwise AND replaces a chain of equality comparisons.
Method_Mask :: distinct bit_set[Method; u8]

// ─── Route Index ────────────────────────────────────────────────────────────
//
// Dense index into Compiled_Router.descriptors[]. 0xFF is the sentinel for "no route".

Route_Index :: distinct u8

ROUTE_INDEX_NONE :: Route_Index(0xFF)

// ─── Route Step ─────────────────────────────────────────────────────────────
//
// Small instruction returned by route handlers telling the library what
// phase to enter next. The connection state machine interprets this after
// each handler invocation.

Route_Step :: union {
	Step_Flush,
	Step_Read_Body,
	Step_Close,
}

// Send the current egress buffer contents.
// final=true means the response is complete after this flush.
// final=false means the handler expects a Send_Ready callback when the
// buffer drains.
Step_Flush :: struct {
	final: bool,
}

// Begin or continue reading request body. Body limit is set per-route
// in Route_Descriptor.body_limit, not per-call.
Step_Read_Body :: struct {}

// Close the connection after the current safe point.
Step_Close :: struct {}


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

@(test)
test_route_index_sentinel :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(ROUTE_INDEX_NONE), 0xFF)

	// A valid route index must be less than the sentinel.
	valid_index := Route_Index(0)
	testing.expect(t, valid_index != ROUTE_INDEX_NONE, "valid index should differ from sentinel")
}

@(test)
test_route_step_variant_discrimination :: proc(t: ^testing.T) {
	// Step_Flush
	step_flush: Route_Step = Step_Flush{final = true}
	flush, is_flush := step_flush.(Step_Flush)
	testing.expect(t, is_flush, "should be Step_Flush")
	testing.expect(t, flush.final, "final should be true")

	// Step_Read_Body
	step_read: Route_Step = Step_Read_Body{}
	_, is_read := step_read.(Step_Read_Body)
	testing.expect(t, is_read, "should be Step_Read_Body")

	// Step_Close
	step_close: Route_Step = Step_Close{}
	_, is_close := step_close.(Step_Close)
	testing.expect(t, is_close, "should be Step_Close")

	// nil union — the zero value
	step_nil: Route_Step
	testing.expect(t, step_nil == nil, "zero Route_Step should be nil")
}
