package http_server

import "core:testing"

@(private = "package")
Header_View :: struct {
	name_offset:  u16,
	value_offset: u16,
	hash:         FNV_Hash_1a, // FNV-1a, A..Z folded — see Parser Notes §1
	name_size:    u16,
	value_size:   u16,
}

@(private = "package")
Param_View :: struct {
	name_offset:  u16,
	value_offset: u16,
	name_size:    u16,
	value_size:   u16,
}

// Per-request semantic flags populated by the parser. These are distinct from
// `Parser_Flags` (which tracks header presence during parsing); `Request_Flags`
// records request-level conditions consumed by routing and dispatch.

Request_Flag :: enum u8 {
	Options_Asterisk, // OPTIONS * — server-wide query (ADR DR-10)
	Unknown_Method, // method passed token validation but is not in the known set
}
Request_Flags :: distinct bit_set[Request_Flag;u8]

@(private = "package")
Request_State :: struct {
	header_bloom:       u64,
	target_offset:      u16,
	path_offset:        u16,
	query_offset:       u16,
	target_size:        u16,
	path_size:          u16,
	query_size:         u16,
	status_flags:       Request_Flags,
	header_count:       u8,
	path_segment_count: u8,
	param_count:        u8,
	method:             Method,
	route_index:        Route_Index,
	known_headers:      Known_Header_Mask,
}

// Initializes a Request_State to a clean per-request baseline.
// Called by the connection state machine before invoking the parser for a
// new request frame on the same keep-alive connection.
@(private = "package")
request_state_reset :: #force_inline proc "contextless" (request: ^Request_State) {
	request^ = Request_State {
		route_index = ROUTE_INDEX_NONE,
	}
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_header_view_layout :: proc(t: ^testing.T) {
	// Header_View must stay compact (2 × u16 offsets + u32 + 2 × u16 = 12 bytes)
	// so that `header_count_max` slots fit predictably in working memory.
	testing.expect_value(t, size_of(Header_View), 12)
}

@(test)
test_param_view_layout :: proc(t: ^testing.T) {
	// Param_View is the slim cousin of Header_View with no hash field.
	testing.expect_value(t, size_of(Param_View), 8)
}

@(test)
test_request_state_reset_baseline :: proc(t: ^testing.T) {
	request: Request_State
	request.method = .POST
	request.header_count = 17
	request.status_flags = {.Unknown_Method}
	request.known_headers = {.Host, .Content_Length}
	request.header_bloom = 0xDEAD_BEEF
	request.route_index = Route_Index(3)

	request_state_reset(&request)

	testing.expect_value(t, request.method, Method.GET)
	testing.expect_value(t, request.header_count, 0)
	testing.expect_value(t, request.header_bloom, 0)
	testing.expect_value(t, request.route_index, ROUTE_INDEX_NONE)
	testing.expect(t, request.status_flags == {}, "status_flags should reset to empty")
	testing.expect(t, request.known_headers == {}, "known_headers should reset to empty")
}

@(test)
test_request_flags_membership :: proc(t: ^testing.T) {
	flags := Request_Flags{.Options_Asterisk}
	testing.expect(t, .Options_Asterisk in flags, "Options_Asterisk should be in mask")
	testing.expect(t, .Unknown_Method not_in flags, "Unknown_Method should not be in mask")

	flags += {.Unknown_Method}
	testing.expect(t, .Unknown_Method in flags, "Unknown_Method should be in mask after add")
}
