package http_server

import "core:testing"

// ─── Route Step ─────────────────────────────────────────────────────────────
//
// Small instruction returned by route handlers telling the library what
// phase to enter next. The connection state machine interprets this after
// each handler invocation.
//
// Public API per HTTP_LIBRARY_DESIGN.md §2 — the route model lives in
// route.odin alongside the eventual route builders, Route_Event,
// Route_Context, and route_send/spawn helpers.

Route_Step :: union {
	Step_Flush,
	Step_Read_Body,
	Step_Close,
}

// Send the current egress buffer contents.
Step_Flush :: struct {
	final: bool,
}

// Begin or continue reading request body. Body limit is set per-route
// in Route_Descriptor.body_limit.
Step_Read_Body :: struct {}

// Close the connection after the current safe point.
Step_Close :: struct {}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_route_step_variant_discrimination :: proc(t: ^testing.T) {
	// Step_Flush
	step_flush: Route_Step = Step_Flush {
		final = true,
	}
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
