package http_server

import tina "../../.."
import "core:mem"
import "core:slice"
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

#assert(
	size_of(Header_View) == 12,
	"Header_View layout changed — expected 12 bytes (2×u16 offset + u32 hash + 2×u16 size)",
)
#assert(
	size_of(Param_View) == 8,
	"Param_View layout changed — expected 8 bytes (2×u16 offset + 2×u16 size)",
)

// Per-request semantic flags populated by the parser. These are distinct from
// `Parser_Flags` (which tracks header presence during parsing); `Request_Flags`
// records request-level conditions consumed by routing and dispatch.

Request_Flag :: enum u8 {
	Options_Asterisk, // OPTIONS * — server-wide query (ADR DR-10)
	Unknown_Method, // method passed token validation but is not in the known set
}
Request_Flags :: distinct bit_set[Request_Flag;u8]

// Sentinel meaning "path_segment_count has not been computed yet".
// Using a sentinel instead of zero disambiguates the legitimate
//  root-path case (`/` has 0 segments) from the not-yet-computed state.
@(private = "package")
PATH_SEGMENT_COUNT_NONE :: u8(0xFF)

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
		route_index        = ROUTE_INDEX_NONE,
		path_segment_count = PATH_SEGMENT_COUNT_NONE,
	}
}

method :: #force_inline proc (request: ^Request) -> Method {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "method: request state is nil")
	}
	state := request.connection_state
	return state.request.method
}

target :: #force_inline proc (request: ^Request) -> []u8 {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "target: request state is nil")
	}
	state := request.connection_state
	if len(request.frame) == 0 || state.request.target_size == 0 {
		return nil
	}
	return request.frame[int(state.request.target_offset):][:int(state.request.target_size)]
}

path :: #force_inline proc (request: ^Request) -> []u8 {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "path: request state is nil")
	}
	state := request.connection_state
	if len(request.frame) == 0 || state.request.path_size == 0 {
		return nil
	}
	return request.frame[int(state.request.path_offset):][:int(state.request.path_size)]
}

query :: #force_inline proc (request: ^Request) -> []u8 {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "query: request state is nil")
	}
	state := request.connection_state
	if len(request.frame) == 0 || state.request.query_size == 0 {
		return nil
	}
	return request.frame[int(state.request.query_offset):][:int(state.request.query_size)]
}

body_buffered :: proc (request: ^Request) -> []u8 {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "body_buffered: request state is nil")
	}
	state := request.connection_state
	if state.buffered_body_size == 0 {
		return nil
	}
	if state.request.route_index == ROUTE_INDEX_NONE {
		return nil
	}
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(state.shard_runtime != nil, "body_buffered: shard_runtime is nil")
	}
	if state.shard_runtime.router.descriptors[state.request.route_index].body_mode != .Buffered {
		return nil
	}
	return state.buffered_body_bytes[:int(state.buffered_body_size)]
}

header :: proc (request: ^Request, name: string) -> []u8 {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "header: request state is nil")
	}
	state := request.connection_state
	if len(name) == 0 || len(request.frame) == 0 {
		return nil
	}
	name_bytes := transmute([]u8)name
	target_hash := compute_header_hash(name_bytes)
	header_views := state.header_views
	header_count := int(state.request.header_count)
	for view in header_views[:header_count] {
		if view.hash != target_hash {
			continue
		}
		header_name := request.frame[int(view.name_offset):][:int(view.name_size)]
		if !_equal_bytes_ci(header_name, name_bytes) {
			continue
		}
		value := request.frame[int(view.value_offset):][:int(view.value_size)]
		return _trim_optional_whitespace(value)
	}
	return nil
}

param :: proc (request: ^Request, name: string) -> []u8 {
	if len(name) == 0 {
		return nil
	}
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "param: request state is nil")
	}
	state := request.connection_state
	runtime := state.shard_runtime
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(runtime != nil, "param: shard_runtime is nil")
	}
	if state.request.route_index == ROUTE_INDEX_NONE {
		return nil
	}

	router_entry, route_ok := _router_entry_for_route_index(&runtime.router, state.request.route_index)
	if !route_ok {
		return nil
	}

	path_bytes := path(request)
	if len(path_bytes) == 0 {
		return nil
	}

	name_bytes := transmute([]u8)name
	read_index := 1
	for part_index in int(router_entry.first_part_index) ..< int(router_entry.first_part_index)+int(router_entry.part_count) {
		if read_index > len(path_bytes) {
			return nil
		}

		part := runtime.router.route_parts[part_index]
		if part.kind == .Wildcard {
			break
		}

		segment_begin := read_index
		segment_end := segment_begin
		for segment_end < len(path_bytes) && path_bytes[segment_end] != '/' {
			segment_end += 1
		}
		if segment_begin == segment_end {
			return nil
		}

		if part.kind == .Param {
			part_name := runtime.router.literal_buffer[int(part.name_offset):][:int(part.name_size)]
			if slice.equal(part_name, name_bytes) {
				return path_bytes[segment_begin:segment_end]
			}
		}

		read_index = segment_end + 1
	}

	return nil
}

param_decoded :: proc(request: ^Request, name: string) -> []u8 {
	raw_value := param(request, name)
	if len(raw_value) == 0 {
		return raw_value
	}

	decode_required := false
	for b in raw_value {
		if b == '%' {
			decode_required = true
			break
		}
	}
	if !decode_required {
		return raw_value
	}

	allocator := request_scratch(request)
	decoded_value := make([]u8, len(raw_value), allocator)
	decoded_size, ok := _decode_percent_bytes(decoded_value, raw_value)
	if !ok {
		return nil
	}
	return decoded_value[:decoded_size]
}

query_value :: proc (request: ^Request, name: string) -> []u8 {
	query_bytes := query(request)
	if len(query_bytes) == 0 || len(name) == 0 {
		return nil
	}

	name_bytes := transmute([]u8)name
	empty_value := query_bytes[:0]
	read_index := 0
	for read_index < len(query_bytes) {
		pair_begin := read_index
		for read_index < len(query_bytes) && query_bytes[read_index] != '&' {
			read_index += 1
		}
		pair_end := read_index
		if read_index < len(query_bytes) && query_bytes[read_index] == '&' {
			read_index += 1
		}

		if pair_begin == pair_end {
			continue
		}

		equals_index := -1
		for index in pair_begin ..< pair_end {
			if query_bytes[index] == '=' {
				equals_index = index
				break
			}
		}

		key_begin := pair_begin
		key_end := pair_end if equals_index < 0 else equals_index
		if key_begin == key_end {
			continue
		}
		if !slice.equal(query_bytes[key_begin:key_end], name_bytes) {
			continue
		}

		if equals_index < 0 {
			return empty_value
		}
		value_begin := equals_index + 1
		return query_bytes[value_begin:pair_end]
	}

	return nil
}

@(private = "package")
query_value_decode :: proc(raw_value: []u8, allocator: mem.Allocator) -> (decoded: []u8, ok: bool) {
	decode_required := false
	for b in raw_value {
		if b == '%' || b == '+' {
			decode_required = true
			break
		}
	}
	if !decode_required {
		return raw_value, true
	}

	decoded_value := make([]u8, len(raw_value), allocator)
	decoded_size, decode_ok := percent_decode(decoded_value, transmute(string)raw_value)
	if !decode_ok {
		return nil, false
	}
	return decoded_value[:decoded_size], true
}

query_value_decoded :: proc(request: ^Request, name: string) -> (decoded: []u8, ok: bool) {
	raw_value := query_value(request, name)
	if raw_value == nil {
		return nil, true
	}

	decode_required := false
	for b in raw_value {
		if b == '%' || b == '+' {
			decode_required = true
			break
		}
	}
	if !decode_required {
		return raw_value, true
	}

	return query_value_decode(raw_value, request_scratch(request))
}

expects_continue :: #force_inline proc (request: ^Request) -> bool {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "expects_continue: request state is nil")
	}
	state := request.connection_state
	return .Expect_100 in state.parser.flags
}

is_head :: #force_inline proc "contextless" (request: ^Request) -> bool {
	return request.connection_state.request.method == .HEAD
}

is_upgrade_requested :: #force_inline proc (request: ^Request) -> bool {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "is_upgrade_requested: request state is nil")
	}
	state := request.connection_state
	return .Upgrade_Request in state.parser.flags
}

is_shutting_down :: #force_inline proc(request: ^Request) -> bool {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "is_shutting_down: request state is nil")
	}
	state := request.connection_state
	if state.shard_runtime != nil && state.shard_runtime.draining {
		return true
	}
	return tina.ctx_is_shutting_down()
}

peer_address :: #force_inline proc (request: ^Request) -> tina.Peer_Address {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "peer_address: request state is nil")
	}
	state := request.connection_state
	return state.peer
}

// Returns the allocator for the Connection's (Isolate) working memory
request_arena :: proc(request: ^Request) -> mem.Allocator {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "request_arena: request state is nil")
	}
	if request == nil || request.connection_state == nil do return mem.Allocator{}
	return mem.arena_allocator(&request.connection_state.request_arena_region)
}

// Returns the allocator for the Connection's (Isolate) scratch memory
request_scratch :: proc(request: ^Request) -> mem.Allocator {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil, "request_scratch: request is nil")
	}
	if request == nil do return mem.Allocator{}
	return tina.ctx_scratch_arena()
}

@(private = "file")
_router_entry_for_route_index :: proc "contextless" (
	router: ^Compiled_Router,
	route_index: Route_Index,
) -> (
	entry: Route_Entry,
	ok: bool,
) {
	if router == nil {
		return {}, false
	}
	for router_entry in router.entries {
		for method in Method {
			if router_entry.route_index_by_method[method] == route_index {
				return router_entry, true
			}
		}
	}
	return {}, false
}

@(private = "file")
_decode_percent_bytes :: proc "contextless" (destination: []u8, source: []u8) -> (decoded_size: int, ok: bool) {
	if len(destination) < len(source) {
		return 0, false
	}

	destination_index := 0
	source_index := 0
	for source_index < len(source) {
		b := source[source_index]
		if b != '%' {
			destination[destination_index] = b
			destination_index += 1
			source_index += 1
			continue
		}

		if source_index + 2 >= len(source) {
			return 0, false
		}

		high_nibble, high_nibble_ok := _hex_nibble(source[source_index+1])
		low_nibble, low_nibble_ok := _hex_nibble(source[source_index+2])
		if !high_nibble_ok || !low_nibble_ok {
			return 0, false
		}

		destination[destination_index] = (high_nibble << 4) | low_nibble
		destination_index += 1
		source_index += 3
	}

	return destination_index, true
}

@(private = "file")
_hex_nibble :: #force_inline proc "contextless" (value: u8) -> (nibble: u8, ok: bool) {
	if value >= '0' && value <= '9' {
		return value - '0', true
	}
	if value >= 'a' && value <= 'f' {
		return 10 + (value - 'a'), true
	}
	if value >= 'A' && value <= 'F' {
		return 10 + (value - 'A'), true
	}
	return 0, false
}

@(private = "file")
_trim_optional_whitespace :: proc "contextless" (value: []u8) -> []u8 {
	start_index := 0
	end_index := len(value)
	for start_index < end_index {
		if value[start_index] != ' ' && value[start_index] != '\t' {
			break
		}
		start_index += 1
	}
	for end_index > start_index {
		last_index := end_index - 1
		if value[last_index] != ' ' && value[last_index] != '\t' {
			break
		}
		end_index = last_index
	}
	return value[start_index:end_index]
}

@(private = "file")
_equal_bytes_ci :: #force_inline proc "contextless" (lhs: []u8, rhs: []u8) -> bool {
	if len(lhs) != len(rhs) do return false
	#no_bounds_check for index in 0 ..< len(lhs) {
		if fold_ascii_upper_to_lower(lhs[index]) != fold_ascii_upper_to_lower(rhs[index]) {
			return false
		}
	}
	return true
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

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
	testing.expect_value(t, request.path_segment_count, PATH_SEGMENT_COUNT_NONE)
	testing.expect(t, request.status_flags == {}, "status_flags should reset to empty")
	testing.expect(t, request.known_headers == {}, "known_headers should reset to empty")
}

@(test)
test_request_header_case_insensitive_lookup :: proc(t: ^testing.T) {
	frame := transmute([]u8)string("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
	views := [1]Header_View{
		{name_offset = 16, value_offset = 22, hash = compute_header_hash(transmute([]u8)string("host")), name_size = 4, value_size = 11},
	}
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.request = Request_State{header_count = 1}
	fixture.connection.connection_state.header_views = views[:]
	request := http_test_fixture_request(&fixture, frame)

	value := header(&request, "HOST")
	testing.expect_value(t, string(value), "example.com")
}

@(test)
test_request_header_trims_optional_whitespace :: proc(t: ^testing.T) {
	frame := transmute([]u8)string("GET / HTTP/1.1\r\nX-Test:\t  value \t\r\n\r\n")
	views := [1]Header_View{
		{name_offset = 16, value_offset = 24, hash = compute_header_hash(transmute([]u8)string("x-test")), name_size = 6, value_size = 9},
	}
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.request = Request_State{header_count = 1}
	fixture.connection.connection_state.header_views = views[:]
	request := http_test_fixture_request(&fixture, frame)

	value := header(&request, "x-test")
	testing.expect_value(t, string(value), "value")
}

@(test)
test_query_value_finds_first_match :: proc(t: ^testing.T) {
	frame := transmute([]u8)string("/users?id=42&mode=full&id=99")
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.request = Request_State{
		query_offset = 7,
		query_size   = 21,
	}
	request := http_test_fixture_request(&fixture, frame)

	value := query_value(&request, "id")
	testing.expect_value(t, string(value), "42")
	missing := query_value(&request, "missing")
	testing.expect(t, missing == nil, "missing query key should return nil")
}

@(test)
test_query_value_decoded_borrows_plain_bytes :: proc(t: ^testing.T) {
	query_text := "plain=hello"
	frame := transmute([]u8)query_text
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.request = Request_State{
		query_offset = 0,
		query_size   = u16(len(query_text)),
	}
	request := http_test_fixture_request(&fixture, frame)

	plain_raw := query_value(&request, "plain")
	plain, plain_ok := query_value_decoded(&request, "plain")
	testing.expect_value(t, plain_ok, true)
	testing.expect_value(t, string(plain), "hello")
	testing.expect(t, raw_data(plain) == raw_data(plain_raw), "plain query should not allocate or copy")
}

@(test)
test_query_value_decode_decodes_percent_and_plus :: proc(t: ^testing.T) {
	raw := `%7B%22message%22%3A%22hello+%2B+world%22%7D`
	decoded, ok := query_value_decode(transmute([]u8)raw, context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, string(decoded), `{"message":"hello + world"}`)
}

@(test)
test_query_value_decode_rejects_invalid_percent_encoding :: proc(t: ^testing.T) {
	raw := "%2G"
	_, ok := query_value_decode(transmute([]u8)raw, context.temp_allocator)
	testing.expect_value(t, ok, false)
}

@(test)
test_param_extracts_named_segment :: proc(t: ^testing.T) {
	routes := []Route{{
		handler      = rawptr(uintptr(0x1234)),
		handler_kind = .Request,
		pattern      = "/users/:id",
		methods_mask = {.GET},
		body_mode    = .None,
	}}
	router, compile_error, _ := compile_router(routes)
	testing.expect_value(t, compile_error, Compile_Error.None)
	defer compiled_router_destroy(&router)

	path_bytes := transmute([]u8)string("/users/42")
	request_state := Request_State {
		method      = .GET,
		path_offset = 0,
		path_size   = 9,
		path_segment_count = PATH_SEGMENT_COUNT_NONE,
	}
	match_result := match_route(&router, &request_state, path_bytes)
	testing.expect_value(t, match_result.outcome, Match_Outcome.Found)
	request_state.route_index = match_result.route_index

	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.request = request_state
	request := http_test_fixture_request(&fixture, path_bytes)

	value := param(&request, "id")
	testing.expect_value(t, string(value), "42")
	decoded_value := param_decoded(&request, "id")
	testing.expect_value(t, string(decoded_value), "42")
}

@(test)
test_is_upgrade_requested_reads_parser_flag :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	request := http_test_fixture_request(&fixture)

	testing.expect(t, !is_upgrade_requested(&request), "upgrade should be false when parser flag is unset")
	fixture.connection.connection_state.parser.flags += {.Upgrade_Request}
	testing.expect(t, is_upgrade_requested(&request), "upgrade should be true when parser flag is set")
}
