package http_server

import "core:testing"

// ─── Limits ─────────────────────────────────────────────────────────────────
//
// Bounds the parser's resource consumption. Every field is used at boot time
// to compute working memory sizing (ADR §5.5) and at parse time to enforce
// per-request maximums. Under-provisioning is caught at startup, not at runtime.

Limits :: struct {
	header_size_max:       u32, // Max total header bytes (all headers combined).
	request_arena_size:    u32, // App-owned per-request working arena budget (bytes).
	handler_scratch_max:   u32, // App max scratch use per callback (bytes).
	request_line_size_max: u16, // Max bytes for the request line (method + target + version).
	header_count_max:      u16, // Max number of individual headers.
	query_pair_count_max:  u16, // Max query key-value pairs for lazy parse.
	param_count_max:       u8,  // Max route parameters.
}

// ─── Timeouts ───────────────────────────────────────────────────────────────
//
// Per-connection timeout configuration. Each timeout arms a timer wheel entry
// that fires a lazy-cancellation message. Stale timeouts are filtered by
// deadline + sequence checks (ADR §15).

Timeouts :: struct {
	timeout_ms_idle:   u32, // Keep-alive idle timeout.
	timeout_ms_header: u32, // Time to receive complete headers after accept/keep-alive.
	timeout_ms_body:   u32, // Time between body progress (re-armed on each recv).
	timeout_ms_send:   u32, // Time between send progress (re-armed on each partial send).
}

// ─── Production Defaults ────────────────────────────────────────────────────
//
// Conservative values suitable for a general-purpose HTTP/1.1 server.
// Operators tune via Server config; these are the safe starting point.

DEFAULT_LIMITS :: Limits {
	header_size_max       = 8192,  // 8 KB — covers most real-world header sets.
	request_arena_size    = 4096,  // 4 KB — sufficient for typical per-request state.
	handler_scratch_max   = 2048,  // 2 KB — percent decode, temp formatting.
	request_line_size_max = 2048,  // 2 KB — long URIs with query strings.
	header_count_max      = 64,    // Practical ceiling; most requests use < 20.
	query_pair_count_max  = 32,    // Generous for typical API query strings.
	param_count_max       = 8,     // Route params like /a/:b/:c/:d.
}

DEFAULT_TIMEOUTS :: Timeouts {
	timeout_ms_idle   = 60_000,  // 60 seconds — standard keep-alive idle.
	timeout_ms_header = 10_000,  // 10 seconds — slow-loris defense.
	timeout_ms_body   = 30_000,  // 30 seconds — body progress deadline.
	timeout_ms_send   = 30_000,  // 30 seconds — slow-read defense.
}


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
	testing.expect(t, limits.header_count_max > 0, "header_count_max must be > 0")
	testing.expect(t, limits.query_pair_count_max > 0, "query_pair_count_max must be > 0")
	testing.expect(t, limits.param_count_max > 0, "param_count_max must be > 0")
}

@(test)
test_default_limits_invariants :: proc(t: ^testing.T) {
	limits := DEFAULT_LIMITS

	// The total header budget must be at least as large as a single request line,
	// otherwise a valid request line could never fit in the header space.
	testing.expect(
		t,
		limits.header_size_max >= u32(limits.request_line_size_max),
		"header_size_max must be >= request_line_size_max",
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
