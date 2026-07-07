package http_server

import "core:testing"

// ─── Limits ─────────────────────────────────────────────────────────────────
//


Limits :: struct {
	request_arena_size:        u32, // App-owned per-request working arena budget.
	handler_scratch_max:       u32, // App max scratch use per callback.
	header_size_max:           u16, // Max total request header bytes.
	request_line_size_max:     u16, // Max bytes for the request line (method + target + version).
	chunk_ext_size_max:        u16, // Max bytes in a single chunk extension line (between chunk-size and CRLF).
	pipeline_size_max:         u16, // Max bytes retained for the pipelined next-request tail.
	response_header_bytes_max: u16, // Max bytes the response header staging region (Working Memory) holds (DR-1).
	header_count_max:          u8, // Max number of individual request headers (255 cap; >255 is an attack).
	path_segment_count_max:    u8, // Max path segments for parametric matching (255 cap; computed lazily).
	param_count_max:           u8, // Max route parameters.
}

// ─── Timeouts ───────────────────────────────────────────────────────────────
//
// Per-connection timeout configuration. Each timeout arms a renewable deadline
// in Tina's core timer subsystem. Stale timeouts are filtered by deadline +
// sequence checks (HTTP_LIBRARY_RUNTIME_POLICIES.md §1).

Timeouts :: struct {
	timeout_ms_idle:   u32, // Keep-alive idle timeout.
	timeout_ms_header: u32, // Absolute deadline from request start until full headers parsed (DR-14, never re-armed).
	timeout_ms_body:   u32, // Time between body progress (re-armed on each recv).
	timeout_ms_send:   u32, // Time between send progress (re-armed on each partial send).
}

// the per-header-line parser path bounds total header bytes,
// request-line bytes, and the number of individual headers it will accept.
@(private = "package")
Parse_Budget :: struct {
	header_size_max:       u16, // Max total request header bytes.
	request_line_size_max: u16, // Max bytes for the request line (method + target + version).
	chunk_ext_size_max:    u16, // Max bytes in a single chunk extension line.
	header_count_max:      u8, // Max number of individual request headers the parser accepts.
}

// route-table compilation rejects patterns whose segment or
// param count exceeds the operator-configured ceiling.
@(private = "package")
Route_Budget :: struct {
	path_segment_count_max: u8, // Max path segments a route pattern may declare.
	param_count_max:        u8, // Max `:param` segments a route pattern may declare.
}

// per-request path-segment matching rejects request paths that
// exceed the operator-configured ceiling; baked into `Compiled_Router` at
// compile time so the match path never re-reads `Limits`.
@(private = "package")
Match_Budget :: struct {
	path_segment_count_max: u8, // Max path segments a request path may have for parametric matching.
}

// working-memory sizing at install time and per-region carve
// at connection init. Each field maps 1-to-1 onto one working-memory region.
@(private = "package")
Memory_Budget :: struct {
	request_arena_size:        u32, // App-owned per-request working arena budget.
	handler_scratch_max:       u32, // App max scratch use per handler invocation.
	pipeline_size_max:         u16, // Max bytes retained for the pipelined next-request tail.
	response_header_bytes_max: u16, // Max bytes the response header staging region holds.
	header_count_max:          u8, // Sizing cap for the per-connection `Header_View` storage region.
}

@(private = "package")
Limits_Error :: enum u8 {
	None,
	Zero_Limit, // A limit required to be non-zero was zero.
	Header_Count_Width, // header_count_max >= 255 (collides with parser sentinel space; >255 is an attack).
	Segment_Width, // path_segment_count_max >= 255 (collides with PATH_SEGMENT_COUNT_NONE).
	Param_Exceeds_Segments, // param_count_max > path_segment_count_max (every param occupies a segment).
	Frame_Width_Exceeded, // request_line_size_max + header_size_max exceeds the u16 frame coordinate space.
}

// ─── Budget constructors ────────────────────────────────────────────────────
//
// Each constructor is the sole owner of its budget's contract. The runtime
// never holds `Limits`; `install_into_system_spec` calls these once and bakes
// the results into `Server_Runtime`. Failures surface as `Limits_Error`, which
// install asserts to `.None` — the boundary contract per AGENTS.md.

@(private = "package")
parse_budget_from :: proc "contextless" (limits: Limits) -> (Parse_Budget, Limits_Error) {
	if limits.header_size_max == 0 ||
	   limits.request_line_size_max == 0 ||
	   limits.chunk_ext_size_max == 0 ||
	   limits.header_count_max == 0 {
		return {}, .Zero_Limit
	}
	if limits.header_count_max >= 0xFF {
		return {}, .Header_Count_Width
	}
	if u32(limits.request_line_size_max) + u32(limits.header_size_max) > 65_535 {
		return {}, .Frame_Width_Exceeded
	}
	return Parse_Budget {
		header_size_max       = limits.header_size_max,
		request_line_size_max = limits.request_line_size_max,
		chunk_ext_size_max    = limits.chunk_ext_size_max,
		header_count_max      = limits.header_count_max,
	}, .None
}

@(private = "package")
route_budget_from :: proc "contextless" (limits: Limits) -> (Route_Budget, Limits_Error) {
	if limits.path_segment_count_max == 0 || limits.param_count_max == 0 {
		return {}, .Zero_Limit
	}
	if limits.path_segment_count_max >= 0xFF {
		return {}, .Segment_Width
	}
	if limits.param_count_max > limits.path_segment_count_max {
		return {}, .Param_Exceeds_Segments
	}
	return Route_Budget {
		path_segment_count_max = limits.path_segment_count_max,
		param_count_max        = limits.param_count_max,
	}, .None
}

@(private = "package")
match_budget_from :: proc "contextless" (limits: Limits) -> (Match_Budget, Limits_Error) {
	if limits.path_segment_count_max == 0 {
		return {}, .Zero_Limit
	}
	if limits.path_segment_count_max >= 0xFF {
		return {}, .Segment_Width
	}
	return Match_Budget {
		path_segment_count_max = limits.path_segment_count_max,
	}, .None
}

@(private = "package")
memory_budget_from :: proc "contextless" (limits: Limits) -> (Memory_Budget, Limits_Error) {
	if limits.request_arena_size == 0 ||
	   limits.handler_scratch_max == 0 ||
	   limits.pipeline_size_max == 0 ||
	   limits.response_header_bytes_max == 0 ||
	   limits.header_count_max == 0 {
		return {}, .Zero_Limit
	}

	return Memory_Budget {
		request_arena_size        = limits.request_arena_size,
		handler_scratch_max       = limits.handler_scratch_max,
		pipeline_size_max         = limits.pipeline_size_max,
		response_header_bytes_max = limits.response_header_bytes_max,
		header_count_max          = limits.header_count_max,
	}, .None
}

// ─── Production Defaults ────────────────────────────────────────────────────
//
// Conservative values suitable for a general-purpose HTTP/1.1 server.
// Operators tune via Server config; these are the safe starting point. The
// derived `DEFAULT_*_BUDGET` constants below are the runtime's view of these
// defaults — `Server_Runtime` tests use the `DEFAULT_SERVER_RUNTIME` base built
// from them.

DEFAULT_LIMITS :: Limits {
	header_size_max           = 8192, // 8 KB — covers most real-world header sets.
	request_arena_size        = 4096, // 4 KB — sufficient for typical per-request state.
	handler_scratch_max       = 2048, // 2 KB — percent decode, temp formatting.
	request_line_size_max     = 2048, // 2 KB — long URIs with query strings.
	chunk_ext_size_max        = 4096, // 4 KB — one chunk extension line; protects from oversized-extension DoS.
	pipeline_size_max         = 8192, // 8 KB — one full extra pipelined request frame.
	header_count_max          = 64, // Practical ceiling; most requests use < 20.
	response_header_bytes_max = 1024, // 1 KB — typical response headers + retries (DR-1).
	path_segment_count_max    = 16, // Matches typical REST paths; bounded by `u8`.
	param_count_max           = 8, // Route params like /a/:b/:c/:d.
}

DEFAULT_TIMEOUTS :: Timeouts {
	timeout_ms_idle   = 60_000, // 60 seconds — standard keep-alive idle.
	timeout_ms_header = 10_000, // 10 seconds — slow-loris defense.
	timeout_ms_body   = 30_000, // 30 seconds — body progress deadline.
	timeout_ms_send   = 30_000, // 30 seconds — slow-read defense.
}

@(private = "package")
DEFAULT_PARSE_BUDGET :: Parse_Budget {
	header_size_max       = DEFAULT_LIMITS.header_size_max,
	request_line_size_max = DEFAULT_LIMITS.request_line_size_max,
	chunk_ext_size_max    = DEFAULT_LIMITS.chunk_ext_size_max,
	header_count_max      = DEFAULT_LIMITS.header_count_max,
}

@(private = "package")
DEFAULT_ROUTE_BUDGET :: Route_Budget {
	path_segment_count_max = DEFAULT_LIMITS.path_segment_count_max,
	param_count_max        = DEFAULT_LIMITS.param_count_max,
}

@(private = "package")
DEFAULT_MATCH_BUDGET :: Match_Budget {
	path_segment_count_max = DEFAULT_LIMITS.path_segment_count_max,
}

@(private = "package")
DEFAULT_MEMORY_BUDGET :: Memory_Budget {
	request_arena_size        = DEFAULT_LIMITS.request_arena_size,
	handler_scratch_max       = DEFAULT_LIMITS.handler_scratch_max,
	pipeline_size_max         = DEFAULT_LIMITS.pipeline_size_max,
	response_header_bytes_max = DEFAULT_LIMITS.response_header_bytes_max,
	header_count_max          = DEFAULT_LIMITS.header_count_max,
}

#assert(DEFAULT_LIMITS.header_size_max > 0)
#assert(DEFAULT_LIMITS.request_line_size_max > 0)
#assert(DEFAULT_LIMITS.chunk_ext_size_max > 0)
#assert(DEFAULT_LIMITS.header_count_max > 0 && DEFAULT_LIMITS.header_count_max < 255)
#assert(u32(DEFAULT_LIMITS.request_line_size_max) + u32(DEFAULT_LIMITS.header_size_max) <= 65_535)
#assert(DEFAULT_LIMITS.path_segment_count_max > 0 && DEFAULT_LIMITS.path_segment_count_max < 255)
#assert(DEFAULT_LIMITS.param_count_max > 0)
#assert(DEFAULT_LIMITS.param_count_max <= DEFAULT_LIMITS.path_segment_count_max)
#assert(DEFAULT_LIMITS.request_arena_size > 0)
#assert(DEFAULT_LIMITS.handler_scratch_max > 0)
#assert(DEFAULT_LIMITS.pipeline_size_max > 0)
#assert(DEFAULT_LIMITS.response_header_bytes_max > 0)

// Defaults must stay in sync with `DEFAULT_LIMITS`. Compile-time counterpart
// to the debug-only structural check in `_connection_init_working_memory_regions`.
#assert(DEFAULT_PARSE_BUDGET.header_size_max == DEFAULT_LIMITS.header_size_max)
#assert(DEFAULT_PARSE_BUDGET.request_line_size_max == DEFAULT_LIMITS.request_line_size_max)
#assert(DEFAULT_PARSE_BUDGET.chunk_ext_size_max == DEFAULT_LIMITS.chunk_ext_size_max)
#assert(DEFAULT_PARSE_BUDGET.header_count_max == DEFAULT_LIMITS.header_count_max)
#assert(DEFAULT_ROUTE_BUDGET.path_segment_count_max == DEFAULT_LIMITS.path_segment_count_max)
#assert(DEFAULT_ROUTE_BUDGET.param_count_max == DEFAULT_LIMITS.param_count_max)
#assert(DEFAULT_MATCH_BUDGET.path_segment_count_max == DEFAULT_LIMITS.path_segment_count_max)
#assert(DEFAULT_MEMORY_BUDGET.request_arena_size == DEFAULT_LIMITS.request_arena_size)
#assert(DEFAULT_MEMORY_BUDGET.handler_scratch_max == DEFAULT_LIMITS.handler_scratch_max)
#assert(DEFAULT_MEMORY_BUDGET.pipeline_size_max == DEFAULT_LIMITS.pipeline_size_max)
#assert(DEFAULT_MEMORY_BUDGET.response_header_bytes_max == DEFAULT_LIMITS.response_header_bytes_max)
#assert(DEFAULT_MEMORY_BUDGET.header_count_max == DEFAULT_LIMITS.header_count_max)
#assert(DEFAULT_MEMORY_BUDGET.header_count_max == DEFAULT_PARSE_BUDGET.header_count_max)


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_default_limits_non_zero :: proc(t: ^testing.T) {
	limits := DEFAULT_LIMITS
	testing.expect(t, limits.header_size_max > 0, "header_size_max must be > 0")
	testing.expect(t, limits.request_arena_size > 0, "request_arena_size must be > 0")
	testing.expect(t, limits.handler_scratch_max > 0, "handler_scratch_max must be > 0")
	testing.expect(t, limits.request_line_size_max > 0, "request_line_size_max must be > 0")
	testing.expect(t, limits.chunk_ext_size_max > 0, "chunk_ext_size_max must be > 0")
	testing.expect(t, limits.pipeline_size_max > 0, "pipeline_size_max must be > 0")
	testing.expect(t, limits.header_count_max > 0, "header_count_max must be > 0")
	testing.expect(t, limits.response_header_bytes_max > 0, "response_header_bytes_max must be > 0")
	testing.expect(t, limits.path_segment_count_max > 0, "path_segment_count_max must be > 0")
	testing.expect(t, limits.param_count_max > 0, "param_count_max must be > 0")
}

@(test)
test_default_limits_invariants :: proc(t: ^testing.T) {
	limits := DEFAULT_LIMITS

	// The total header budget must be at least as large as a single request line,
	// otherwise a valid request line could never fit in the header space.
	testing.expect(
		t,
		limits.header_size_max >= limits.request_line_size_max,
		"header_size_max must be >= request_line_size_max",
	)

	// The frame coordinate space invariant: request line + headers must fit in u16.
	frame_capacity := u32(limits.request_line_size_max) + u32(limits.header_size_max)
	testing.expect(t, frame_capacity <= 65_535, "default request frame must fit in u16")

	// path_segment_count_max must not collide with the PATH_SEGMENT_COUNT_NONE
	// sentinel (0xFF i.e. 255) used by the match path.
	testing.expect(
		t,
		limits.path_segment_count_max < 0xFF,
		"path_segment_count_max must be < 0xFF to avoid the match sentinel",
	)

	// Every `:param` segment occupies a path segment; the param ceiling can
	// never exceed the segment ceiling.
	testing.expect(
		t,
		limits.param_count_max <= limits.path_segment_count_max,
		"param_count_max must be <= path_segment_count_max",
	)

	// header_count_max is u8; the field comment documents ">255 is an attack".
	// 0xFF itself is reserved (matches the parser's sentinel discipline), so
	// the legal range is [1, 254].
	testing.expect(
		t,
		limits.header_count_max < 0xFF,
		"header_count_max must be < 0xFF (operator-side attack bound)",
	)
}

@(test)
test_default_timeouts_non_zero :: proc(t: ^testing.T) {
	timeouts := DEFAULT_TIMEOUTS
	testing.expect(t, timeouts.timeout_ms_idle > 0, "timeout_ms_idle must be > 0")
	testing.expect(t, timeouts.timeout_ms_header > 0, "timeout_ms_header must be > 0")
	testing.expect(t, timeouts.timeout_ms_body > 0, "timeout_ms_body must be > 0")
	testing.expect(t, timeouts.timeout_ms_send > 0, "timeout_ms_send must be > 0")
}

@(test)
test_timeouts_header_shorter_than_idle :: proc(t: ^testing.T) {
	timeouts := DEFAULT_TIMEOUTS

	// The header timeout should be shorter than the idle timeout — if a client
	// is accepted but sends nothing, the header timeout fires first.
	testing.expect(
		t,
		timeouts.timeout_ms_header < timeouts.timeout_ms_idle,
		"header timeout should be shorter than idle timeout",
	)
}

// ─── Budget constructor tests ────────────────────────────────────────────────

@(test)
test_parse_budget_from_default_succeeds :: proc(t: ^testing.T) {
	budget, error := parse_budget_from(DEFAULT_LIMITS)
	testing.expect_value(t, error, Limits_Error.None)
	testing.expect_value(t, budget, DEFAULT_PARSE_BUDGET)
}

@(test)
test_parse_budget_from_rejects_zero :: proc(t: ^testing.T) {
	zeroed := DEFAULT_LIMITS
	zeroed.header_count_max = 0
	_, error := parse_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.header_size_max = 0
	_, error = parse_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.request_line_size_max = 0
	_, error = parse_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.chunk_ext_size_max = 0
	_, error = parse_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)
}

@(test)
test_parse_budget_from_rejects_header_count_width :: proc(t: ^testing.T) {
	wide := DEFAULT_LIMITS
	wide.header_count_max = 0xFF
	_, error := parse_budget_from(wide)
	testing.expect_value(t, error, Limits_Error.Header_Count_Width)
}

@(test)
test_parse_budget_from_rejects_frame_width_overflow :: proc(t: ^testing.T) {
	overflow := DEFAULT_LIMITS
	overflow.request_line_size_max = 40_000
	overflow.header_size_max = 40_000
	_, error := parse_budget_from(overflow)
	testing.expect_value(t, error, Limits_Error.Frame_Width_Exceeded)
}

@(test)
test_route_budget_from_default_succeeds :: proc(t: ^testing.T) {
	budget, error := route_budget_from(DEFAULT_LIMITS)
	testing.expect_value(t, error, Limits_Error.None)
	testing.expect_value(t, budget, DEFAULT_ROUTE_BUDGET)
}

@(test)
test_route_budget_from_rejects_zero :: proc(t: ^testing.T) {
	zeroed := DEFAULT_LIMITS
	zeroed.param_count_max = 0
	_, error := route_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.path_segment_count_max = 0
	_, error = route_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)
}

@(test)
test_route_budget_from_rejects_segment_width :: proc(t: ^testing.T) {
	wide := DEFAULT_LIMITS
	wide.path_segment_count_max = 0xFF
	_, error := route_budget_from(wide)
	testing.expect_value(t, error, Limits_Error.Segment_Width)
}

@(test)
test_route_budget_from_rejects_param_exceeds_segments :: proc(t: ^testing.T) {
	mismatched := DEFAULT_LIMITS
	mismatched.path_segment_count_max = 4
	mismatched.param_count_max = 5
	_, error := route_budget_from(mismatched)
	testing.expect_value(t, error, Limits_Error.Param_Exceeds_Segments)
}

@(test)
test_match_budget_from_default_succeeds :: proc(t: ^testing.T) {
	budget, error := match_budget_from(DEFAULT_LIMITS)
	testing.expect_value(t, error, Limits_Error.None)
	testing.expect_value(t, budget, DEFAULT_MATCH_BUDGET)
}

@(test)
test_match_budget_from_rejects_zero :: proc(t: ^testing.T) {
	zeroed := DEFAULT_LIMITS
	zeroed.path_segment_count_max = 0
	_, error := match_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)
}

@(test)
test_match_budget_from_rejects_segment_width :: proc(t: ^testing.T) {
	wide := DEFAULT_LIMITS
	wide.path_segment_count_max = 0xFF
	_, error := match_budget_from(wide)
	testing.expect_value(t, error, Limits_Error.Segment_Width)
}

@(test)
test_memory_budget_from_default_succeeds :: proc(t: ^testing.T) {
	budget, error := memory_budget_from(DEFAULT_LIMITS)
	testing.expect_value(t, error, Limits_Error.None)
	testing.expect_value(t, budget, DEFAULT_MEMORY_BUDGET)
}

@(test)
test_memory_budget_from_rejects_zero :: proc(t: ^testing.T) {
	zeroed := DEFAULT_LIMITS
	zeroed.request_arena_size = 0
	_, error := memory_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.handler_scratch_max = 0
	_, error = memory_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.pipeline_size_max = 0
	_, error = memory_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.response_header_bytes_max = 0
	_, error = memory_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)

	zeroed = DEFAULT_LIMITS
	zeroed.header_count_max = 0
	_, error = memory_budget_from(zeroed)
	testing.expect_value(t, error, Limits_Error.Zero_Limit)
}
