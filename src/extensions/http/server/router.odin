package http_server

import "core:testing"

// Index into Compiled_Router.descriptors[].
// 0xFF is the sentinel for "no route".
@(private = "package")
Route_Index :: distinct u8

@(private = "package")
ROUTE_INDEX_NONE :: Route_Index(0xFF)


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_route_index_sentinel :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(ROUTE_INDEX_NONE), 0xFF)

	// A valid route index must be less than the sentinel.
	valid_index := Route_Index(0)
	testing.expect(t, valid_index != ROUTE_INDEX_NONE, "valid index should differ from sentinel")
}
