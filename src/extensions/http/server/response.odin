package http_server

import tina "../../.."
import "core:strings"
import "core:testing"

// Egress buffer size per connection. Default is sufficient for status
// line + common headers + Date + small text/JSON bodies. The struct stride
// (and Grand Arena sizing) is derived automatically from this constant.
@(private = "package")
HTTP_EGRESS_BUFFER_SIZE :: #config(HTTP_EGRESS_BUFFER_SIZE, 4096)

// Hard floor: a minimal HTTP/1.1 response (status line + Date + Content-Length
// + Connection + CRLF) is ~75–100 bytes. 256 bytes guarantees protocol
// viability with safety margin. Compliance floor, not a recommended size.
@(private = "package")
HTTP_EGRESS_BUFFER_SIZE_MIN :: 256

// Hard cap on response headers per response. The typical response carries
// fewer than 12 headers; >32 is almost certainly a bug or attack surface.
// Increasing this widens `Response_State` by 8 bytes per added slot.
@(private = "package")
HTTP_RESPONSE_HEADERS_MAX :: #config(HTTP_RESPONSE_HEADERS_MAX, 32)

// Chunked framing reserve carved out of HTTP_EGRESS_BUFFER_SIZE so that the
// terminator (`0\r\n\r\n`) and any in-flight chunk header always have room.
//   max hex chunk-size string : 4 bytes (covers HTTP_EGRESS_BUFFER_SIZE up to 65535)
//   chunk-size CRLF           : 2 bytes
//   trailing CRLF after data  : 2 bytes
//   terminating "0\r\n\r\n"   : 5 bytes
//   safety margin             : 3 bytes
//   ─────────────────────────────────
//   total                     : 16 bytes
@(private = "package")
HTTP_CHUNKED_FRAMING_RESERVE :: 16

// Maximum payload (per response) staged in chunked mode before reserve.
@(private = "package")
HTTP_CHUNKED_PAYLOAD_BUDGET :: HTTP_EGRESS_BUFFER_SIZE - HTTP_CHUNKED_FRAMING_RESERVE


// Boot-time invariant guards. These compile-fail bad configurations rather
// than risking a runtime livelock.
#assert(HTTP_EGRESS_BUFFER_SIZE >= HTTP_EGRESS_BUFFER_SIZE_MIN)
#assert(HTTP_EGRESS_BUFFER_SIZE_MIN >= 256)
#assert(HTTP_EGRESS_BUFFER_SIZE >= HTTP_EGRESS_BUFFER_SIZE_MIN + HTTP_CHUNKED_FRAMING_RESERVE)
#assert(HTTP_RESPONSE_HEADERS_MAX > 0 && HTTP_RESPONSE_HEADERS_MAX <= 255)

// Bytes staged in egress_buffer ready to send.
Egress_Size :: distinct u16

// Bytes already transmitted from egress_buffer.
Egress_Size_Sent :: distinct u16

@(private = "package")
Response_Mode :: enum u8 {
	Not_Started, // No status / headers staged yet; entries empty.
	Fixed_Length, // Content-Length framing; body_size_total is authoritative.
	Chunked, // Transfer-Encoding: chunked; no Content-Length.
	Head_Suppressed, // /dev/null body sink for HEAD / 204 / 304 (DR-9).
	Closed, // Final flush issued; further mutations are programmer errors.
}

// Response state-machine flags. Adding a 9th flag must widen the backing type
// to u16; the type advertises remaining capacity by construction.
@(private = "package")
Response_Flag :: enum u8 {
	Headers_Committed, // Status + headers serialized into egress_buffer.
	Close_After_Send, // Final flush must drop the connection (overflow / Connection: close).
	Backpressured, // Last write_bytes did not fully admit; awaiting Send_Ready.
	Aborted, // Response surface poisoned (double-response, library failure).
	In_Drain, // Server is draining; no new keep-alive after current response.
	Interim_100_Sent, // 100 Continue staged or flushed; duplicate sends are no-ops.
	User_Set_Date, // User called header_set/add with name == "Date" (skip auto-Date at commit).
}

@(private = "package")
Response_Flags :: distinct bit_set[Response_Flag;u8]

@(private = "package")
Response_Header_Entry :: struct {
	name_offset:  u16,
	name_size:    u16,
	value_offset: u16,
	value_size:   u16,
}
#assert(
	size_of(Response_Header_Entry) == 8,
	"Response_Header_Entry size/layout changed — expected to be exactly 8 bytes so HTTP_RESPONSE_HEADERS_MAX × 8 = 256 bytes",
)

@(private = "package")
Response_State :: struct {
	body_size_total:   u64, // Fixed_Length: declared body size; Chunked: ignored.
	body_size_sent:    u64, // Bytes of body logically sent (advances even when sink-suppressed).
	egress_size:       Egress_Size, // Cursor into egress_buffer; transactional commit's source of truth.
	egress_size_sent:  Egress_Size_Sent,
	headers:           [HTTP_RESPONSE_HEADERS_MAX]Response_Header_Entry,
	header_bytes_used: u16, // Cursor into the Working Memory response_header_bytes slice.
	status_code:       HTTP_Status,
	header_count:      u8,
	mode:              Response_Mode,
	flags:             Response_Flags,
}

// Named constants for the codes the library itself emits and the codes most
// applications return. User code may construct any valid status with
// `HTTP_Status(n)`; these names exist for readability and grep-ability at call
// sites — e.g. `respond_text(response, HTTP_STATUS_NOT_FOUND, "...")`.
//
// Public surface — kept in lockstep with `status_reason_phrase` and the
// pre-baked `errors.odin` fallback frames so the three sources of truth stay
// aligned. Adding a new framework-emitted code requires updating all three.
HTTP_STATUS_CONTINUE :: HTTP_Status(100)
HTTP_STATUS_OK :: HTTP_Status(200)
HTTP_STATUS_CREATED :: HTTP_Status(201)
HTTP_STATUS_ACCEPTED :: HTTP_Status(202)
HTTP_STATUS_NO_CONTENT :: HTTP_Status(204)
HTTP_STATUS_MOVED_PERMANENTLY :: HTTP_Status(301)
HTTP_STATUS_FOUND :: HTTP_Status(302)
HTTP_STATUS_NOT_MODIFIED :: HTTP_Status(304)
HTTP_STATUS_BAD_REQUEST :: HTTP_Status(400)
HTTP_STATUS_UNAUTHORIZED :: HTTP_Status(401)
HTTP_STATUS_FORBIDDEN :: HTTP_Status(403)
HTTP_STATUS_NOT_FOUND :: HTTP_Status(404)
HTTP_STATUS_METHOD_NOT_ALLOWED :: HTTP_Status(405)
HTTP_STATUS_REQUEST_TIMEOUT :: HTTP_Status(408)
HTTP_STATUS_LENGTH_REQUIRED :: HTTP_Status(411)
HTTP_STATUS_CONTENT_TOO_LARGE :: HTTP_Status(413)
HTTP_STATUS_URI_TOO_LONG :: HTTP_Status(414)
HTTP_STATUS_EXPECTATION_FAILED :: HTTP_Status(417)
HTTP_STATUS_TOO_MANY_REQUESTS :: HTTP_Status(429)
HTTP_STATUS_HEADER_FIELDS_TOO_LARGE :: HTTP_Status(431)
HTTP_STATUS_INTERNAL_SERVER_ERROR :: HTTP_Status(500)
HTTP_STATUS_NOT_IMPLEMENTED :: HTTP_Status(501)
HTTP_STATUS_SERVICE_UNAVAILABLE :: HTTP_Status(503)
HTTP_STATUS_GATEWAY_TIMEOUT :: HTTP_Status(504)
HTTP_STATUS_HTTP_VERSION_NOT_SUPPORTED :: HTTP_Status(505)
// Default status used by `response_state_reset`. A successful handler that
// never calls `status()` falls through to 200 OK.
@(private = "package")
HTTP_STATUS_DEFAULT :: HTTP_STATUS_OK

// Resets the response to its pre-request baseline. Called before dispatching a
// new request frame on a keep-alive connection.
@(private = "package")
response_state_reset :: #force_inline proc "contextless" (response: ^Response_State) {
	response^ = Response_State {
		status_code = HTTP_STATUS_DEFAULT,
		mode        = .Not_Started,
	}
}

response_header_set :: proc "contextless" (
	response: ^Response_State,
	bytes_region: []u8,
	name: []u8,
	value: []u8,
) -> bool {
	return _stage_header(response, bytes_region, name, value, replace_existing = true)
}

response_header_add :: proc "contextless" (
	response: ^Response_State,
	bytes_region: []u8,
	name: []u8,
	value: []u8,
) -> bool {
	return _stage_header(response, bytes_region, name, value, replace_existing = false)
}

// Internal staging core. Held in one place so that `header_set` and
// `header_add` cannot drift apart in their reserved-name handling, Date
// detection, or overflow accounting.
@(private = "file")
_stage_header :: proc "contextless" (
	response: ^Response_State,
	bytes_region: []u8,
	name: []u8,
	value: []u8,
	replace_existing: bool,
) -> bool {
	if .Headers_Committed in response.flags do return false
	if .Aborted in response.flags do return false
	if len(name) == 0 do return false

	if _name_is_reserved_framing(name) do return true

	// Track user-set Date so the framework can skip auto-injection at commit
	// time without rescanning entries.
	if equal_bytes_ci_with_rhs_lowercase(name, "date") {
		response.flags += {.User_Set_Date}
	}

	cursor := int(response.header_bytes_used)
	region_size := len(bytes_region)

	if replace_existing {
		#no_bounds_check for index in 0 ..< response.header_count {
			entry := response.headers[index]
			existing_name := bytes_region[entry.name_offset:][:entry.name_size]
			if !equal_bytes_ci(existing_name, name) do continue

			// Reuse this slot. Only the value bytes are appended fresh.
			// Pre-flight the budget so a failure leaves the cursor at its
			// pre-call position — staging is transactional.
			new_header_bytes_used := u32(cursor) + u32(len(value))
			if new_header_bytes_used > u32(max(u16)) do return false
			if int(new_header_bytes_used) > region_size do return false

			if len(value) > 0 do copy(bytes_region[cursor:], value)
			response.headers[index].value_offset = u16(cursor)
			response.headers[index].value_size = u16(len(value))
			response.header_bytes_used = u16(new_header_bytes_used)
			return true
		}
	}

	// Append path. The entry-array budget is the structural slot space.
	if response.header_count >= HTTP_RESPONSE_HEADERS_MAX do return false

	// Pre-flight name + value together so a partial name copy cannot leave
	// the cursor advanced when the subsequent value copy would overflow.
	new_header_bytes_used := u32(cursor) + u32(len(name)) + u32(len(value))
	if new_header_bytes_used > u32(max(u16)) do return false
	if int(new_header_bytes_used) > region_size do return false

	if len(name) > 0 do copy(bytes_region[cursor:], name)
	if len(value) > 0 do copy(bytes_region[cursor + len(name):], value)

	response.headers[response.header_count] = Response_Header_Entry {
		name_offset  = u16(cursor),
		name_size    = u16(len(name)),
		value_offset = u16(cursor + len(name)),
		value_size   = u16(len(value)),
	}
	response.header_count += 1
	response.header_bytes_used = u16(new_header_bytes_used)
	return true
}

@(private = "file")
_name_is_reserved_framing :: #force_inline proc "contextless" (name: []u8) -> bool {
	switch len(name) {
	case 10:
		return equal_bytes_ci_with_rhs_lowercase(name, "connection")
	case 14:
		return equal_bytes_ci_with_rhs_lowercase(name, "content-length")
	case 17:
		return equal_bytes_ci_with_rhs_lowercase(name, "transfer-encoding")
	}
	return false
}

// Case-insensitive byte-slice compare. Both inputs may carry arbitrary case
// because user code chooses the casing for both `header_set("Content-Type")`
// and a subsequent `header_set("content-type")` which must match.
@(private = "file")
equal_bytes_ci :: #force_inline proc "contextless" (lhs: []u8, rhs: []u8) -> bool {
	if len(lhs) != len(rhs) do return false
	#no_bounds_check for index in 0 ..< len(lhs) {
		if fold_ascii_upper_to_lower(lhs[index]) != fold_ascii_upper_to_lower(rhs[index]) {
			return false
		}
	}
	return true
}


// ─── Chunked Admission Math (DR-12) ─────────────────────────────────────────
//
// In `Response_Mode.Chunked`, every body chunk takes a per-chunk framing tax
// (hex chunk-size + CRLF + payload + CRLF). The 16-byte
// `HTTP_CHUNKED_FRAMING_RESERVE` is held back from the egress buffer so the
// terminator (`0\r\n\r\n`) and the next chunk header always have room.
//
// `admit_chunk_payload(free, want)` returns the largest payload size `n` that
// fits in `free` bytes including framing, with `n ≤ want`. It is constant-time
// (≤ 4 hex bands).
//
//   free = HTTP_EGRESS_BUFFER_SIZE - egress_size - HTTP_CHUNKED_FRAMING_RESERVE
//   admit n bytes ⇔  hex_size_chars(n) + 2 + n + 2 ≤ free
//
// A return of 0 means "nothing fits this round" — `write_bytes` then short-
// circuits without emitting a `0`-prefix chunk (which is reserved for the
// terminator written by `flush(final = true)`).

@(private = "package")
hex_size_chars :: #force_inline proc "contextless" (value: u16) -> u16 {
	switch {
	case value >= 0x1000:
		return 4
	case value >= 0x100:
		return 3
	case value >= 0x10:
		return 2
	case:
		// Includes value == 0; admit_chunk_payload short-circuits on want == 0
		// so this branch is only reached for value in [1, 0xF].
		return 1
	}
}

@(private = "package")
admit_chunk_payload :: #force_inline proc "contextless" (free: u16, want: u16) -> u16 {
	if want == 0 do return 0

	// Minimum 1-byte chunk needs: 1 hex + CRLF + 1 + CRLF = 6 bytes free.
	if free < 6 do return 0

	want_hex := hex_size_chars(want)
	if u32(want_hex) + 4 + u32(want) <= u32(free) do return want

	// Try each hex band from largest to smallest. For each band, the
	// candidate payload is bounded by:
	//   - the band's hex-digit ceiling,
	//   - the caller's `want`,
	//   - the bytes available after framing tax (free - hex_chars - 4).
	// Accept only when the candidate's natural hex width matches the band —
	// otherwise the band's framing tax was over-counted; fall through.

	// Band [0x1000..0xFFFF] (4 hex digits)
	if want >= 0x1000 && free >= 4 + 4 {
		candidate := u16(min(u32(want), u32(free) - 4 - 4))
		if candidate >= 0x1000 do return candidate
	}
	// Band [0x100..0xFFF] (3 hex digits)
	if want >= 0x100 && free >= 3 + 4 {
		candidate := u16(min(u32(want), u32(0x0FFF), u32(free) - 3 - 4))
		if candidate >= 0x100 do return candidate
	}
	// Band [0x10..0xFF] (2 hex digits)
	if want >= 0x10 && free >= 2 + 4 {
		candidate := u16(min(u32(want), u32(0x00FF), u32(free) - 2 - 4))
		if candidate >= 0x10 do return candidate
	}
	// Band [0x1..0xF] (1 hex digit)
	if free >= 1 + 4 {
		candidate := u16(min(u32(want), u32(0x000F), u32(free) - 1 - 4))
		return candidate
	}
	return 0
}

// Returns the canonical IANA reason phrase for the codes the library itself
// emits. Unknown codes yield an empty string — the serializer still writes a
// well-formed status line because the SP is preserved (`HTTP/1.1 999 \r\n`).
status_reason_phrase :: #force_inline proc "contextless" (code: HTTP_Status) -> string {
	switch code {
	case 100:
		return "Continue"
	case 101:
		return "Switching Protocols"
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 202:
		return "Accepted"
	case 204:
		return "No Content"
	case 206:
		return "Partial Content"
	case 301:
		return "Moved Permanently"
	case 302:
		return "Found"
	case 303:
		return "See Other"
	case 304:
		return "Not Modified"
	case 307:
		return "Temporary Redirect"
	case 308:
		return "Permanent Redirect"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 406:
		return "Not Acceptable"
	case 408:
		return "Request Timeout"
	case 409:
		return "Conflict"
	case 410:
		return "Gone"
	case 411:
		return "Length Required"
	case 413:
		return "Content Too Large"
	case 414:
		return "URI Too Long"
	case 415:
		return "Unsupported Media Type"
	case 417:
		return "Expectation Failed"
	case 422:
		return "Unprocessable Content"
	case 426:
		return "Upgrade Required"
	case 429:
		return "Too Many Requests"
	case 431:
		return "Request Header Fields Too Large"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	case 504:
		return "Gateway Timeout"
	case 505:
		return "HTTP Version Not Supported"
	}
	return ""
}

// Serializes the staged response head (status line, framework headers, user
// headers, terminating CRLF) into a caller-provided egress buffer slice. Uses
// a local cursor: the caller observes the returned `(size, true)` only on full
// success. On any overflow, the function returns `(0, false)` and leaves the
// destination semantically untouched (bytes may have been written but the
// caller treats them as garbage).
//
// Inputs:
//   destination       — writable slice (typically HTTP_Connection.egress_buffer[:])
//   response          — staged headers and mode
//   bytes_region      — Working Memory slice the entry offsets index into
//   date_value        — pre-formatted Date value (e.g. "Wed, 01 May 2026 12:34:56 GMT").
//                       Empty disables auto-Date emission. Caller suppresses it
//                       when `User_Set_Date` is set in `response.flags`.
//
// The caller is responsible for setting `response.body_size_total` for
// `Fixed_Length` and `Head_Suppressed` modes before calling.

@(private = "package")
serialize_response_headers :: proc "contextless" (
	destination: []u8,
	response: ^Response_State,
	bytes_region: []u8,
	date_value: []u8,
) -> (
	size: Egress_Size,
	ok: bool,
) {
	// Named returns default to (0, false). On any helper failure the
	// `or_return` short-circuits with that pair, satisfying the transactional
	// contract: callers observe (size>0, true) only on full success.
	cursor: int

	// 1. Status line: "HTTP/1.1 <code> <reason>\r\n"
	cursor = _write_bytes_into(destination, cursor, transmute([]u8)string("HTTP/1.1 ")) or_return
	cursor = _write_status_code(destination, cursor, response.status_code) or_return
	cursor = _write_byte_into(destination, cursor, ' ') or_return
	reason := status_reason_phrase(response.status_code)
	if len(reason) > 0 {
		cursor = _write_bytes_into(destination, cursor, transmute([]u8)reason) or_return
	}
	cursor = _write_bytes_into(destination, cursor, transmute([]u8)string("\r\n")) or_return

	// 2. Date — auto-injected unless the user staged one explicitly.
	if len(date_value) > 0 && !(.User_Set_Date in response.flags) {
		cursor = _write_bytes_into(destination, cursor, transmute([]u8)string("Date: ")) or_return
		cursor = _write_bytes_into(destination, cursor, date_value) or_return
		cursor = _write_bytes_into(destination, cursor, transmute([]u8)string("\r\n")) or_return
	}

	// 3. Connection — library-owned. Emit `close` only when the response
	//    has been marked `Close_After_Send`. HTTP/1.1's default is keep-alive,
	//    so the absence of this header is the affirmative keep-alive signal.
	if .Close_After_Send in response.flags {
		cursor = _write_bytes_into(
			destination,
			cursor,
			transmute([]u8)string("Connection: close\r\n"),
		) or_return
	}

	// 4. Framing header per response mode (library-owned, written here only).
	switch response.mode {
	case .Not_Started:
		// Treat Not_Started identically to Fixed_Length 0 — the caller may
		// have called serialize without a respond_*() (e.g. raw 204 hand-off).
		cursor = _write_content_length(destination, cursor, 0) or_return
	case .Fixed_Length, .Head_Suppressed:
		cursor = _write_content_length(destination, cursor, response.body_size_total) or_return
	case .Chunked:
		cursor = _write_bytes_into(
			destination,
			cursor,
			transmute([]u8)string("Transfer-Encoding: chunked\r\n"),
		) or_return
	case .Closed:
		// Closed responses must never round-trip through the serializer; the
		// state machine writes the canned 500 directly. Treat as overflow.
		return
	}

	// 5. User headers — entries are live by construction (DR-1 update-in-place).
	#no_bounds_check for index in 0 ..< response.header_count {
		entry := response.headers[index]
		name := bytes_region[entry.name_offset:][:entry.name_size]
		value := bytes_region[entry.value_offset:][:entry.value_size]
		cursor = _write_bytes_into(destination, cursor, name) or_return
		cursor = _write_bytes_into(destination, cursor, transmute([]u8)string(": ")) or_return
		cursor = _write_bytes_into(destination, cursor, value) or_return
		cursor = _write_bytes_into(destination, cursor, transmute([]u8)string("\r\n")) or_return
	}

	// 6. Header terminator.
	cursor = _write_bytes_into(destination, cursor, transmute([]u8)string("\r\n")) or_return

	// `Egress_Size` is u16. The destination is bounded by HTTP_EGRESS_BUFFER_SIZE
	// (≤ u16 max) at install time; this cast is therefore lossless by precondition.
	if cursor > int(max(u16)) do return
	size = Egress_Size(cursor)
	ok = true
	return
}

// ─── Response Facade Helpers ────────────────────────────────────────────────

@(private = "file")
_response_state :: #force_inline proc "contextless" (response: ^Response) -> ^Response_State {
	return &response.connection.connection_state.response
}

@(private = "file")
_response_clear_sendfile_plan :: #force_inline proc "contextless" (response: ^Response) {
	response.connection.connection_state.sendfile_file_fd = tina.FD_HANDLE_NONE
	response.connection.connection_state.sendfile_offset = 0
	response.connection.connection_state.sendfile_size_remaining = 0
	response.connection.connection_state.sendfile_active = false
}

@(private = "file")
_response_stage_internal_server_error :: proc "contextless" (
	response: ^Response,
	state: ^Response_State,
) {
	copy(response.connection.egress_buffer[:], ERROR_RESPONSE_500_INTERNAL_SERVER_ERROR)
	state.flags += {.Aborted, .Close_After_Send}
	state.mode = .Closed
	state.egress_size = Egress_Size(len(ERROR_RESPONSE_500_INTERNAL_SERVER_ERROR))
	state.egress_size_sent = 0
	_response_clear_sendfile_plan(response)
}

@(private = "file")
_response_preserve_flags :: proc "contextless" (state: ^Response_State) {
	head_suppressed := state.mode == .Head_Suppressed
	close_after_send := .Close_After_Send in state.flags
	in_drain := .In_Drain in state.flags
	interim_100_sent := .Interim_100_Sent in state.flags
	response_state_reset(state)
	if head_suppressed {
		state.mode = .Head_Suppressed
	}
	if close_after_send {
		state.flags += {.Close_After_Send}
	}
	if in_drain {
		state.flags += {.In_Drain}
	}
	if interim_100_sent {
		state.flags += {.Interim_100_Sent}
	}
}

status :: #force_inline proc "contextless" (response: ^Response, code: HTTP_Status) {
	state := _response_state(response)
	state.status_code = code
	if code == HTTP_STATUS_NO_CONTENT ||
	   code == HTTP_STATUS_NOT_MODIFIED ||
	   code == HTTP_STATUS_CONTINUE {
		state.mode = .Head_Suppressed
	}
}

header_set :: #force_inline proc "contextless" (
	response: ^Response,
	name: string,
	value: string,
) -> bool {
	return response_header_set(
		_response_state(response),
		response.connection.connection_state.response_header_bytes,
		transmute([]u8)name,
		transmute([]u8)value,
	)
}

header_add :: #force_inline proc "contextless" (
	response: ^Response,
	name: string,
	value: string,
) -> bool {
	return response_header_add(
		_response_state(response),
		response.connection.connection_state.response_header_bytes,
		transmute([]u8)name,
		transmute([]u8)value,
	)
}

respond_text :: #force_inline proc "contextless" (
	response: ^Response,
	status_code: HTTP_Status,
	body: string,
) -> Route_Step {
	return _respond_bytes(response, status_code, "text/plain; charset=utf-8", transmute([]u8)body)
}

respond_json :: #force_inline proc "contextless" (
	response: ^Response,
	status_code: HTTP_Status,
	body: string,
) -> Route_Step {
	return _respond_bytes(response, status_code, "application/json", transmute([]u8)body)
}

respond_bytes :: #force_inline proc "contextless" (
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
	body: []u8,
) -> Route_Step {
	return _respond_bytes(response, status_code, content_type, body)
}

begin_stream :: #force_inline proc "contextless" (
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
) {
	state := _response_state(response)
	_response_preserve_flags(state)
	state.status_code = status_code
	if state.mode != .Head_Suppressed {
		state.mode = .Chunked
	}
	state.body_size_total = 0
	state.body_size_sent = 0
	state.egress_size = Egress_Size(0)
	state.egress_size_sent = Egress_Size_Sent(0)
	_response_clear_sendfile_plan(response)
	_ = header_set(response, "content-type", content_type)
	if !_response_commit_headers(response) {
		return
	}
}

begin_fixed_stream :: #force_inline proc "contextless" (
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
	total_size: u64,
) {
	state := _response_state(response)
	_response_preserve_flags(state)
	state.status_code = status_code
	if state.mode != .Head_Suppressed {
		state.mode = .Fixed_Length
	}
	state.body_size_total = total_size
	state.body_size_sent = 0
	state.egress_size = Egress_Size(0)
	state.egress_size_sent = Egress_Size_Sent(0)
	_response_clear_sendfile_plan(response)
	_ = header_set(response, "Content-Type", content_type)
	if !_response_commit_headers(response) {
		return
	}
}

respond_file :: proc "contextless" (
	response: ^Response,
	fd_file: tina.FD_Handle,
	file_size: u64,
	content_type: string,
) -> Route_Step {
	state := _response_state(response)
	_response_preserve_flags(state)
	state.status_code = HTTP_STATUS_OK
	if state.mode != .Head_Suppressed {
		state.mode = .Fixed_Length
	}
	state.body_size_total = file_size
	state.body_size_sent = 0
	state.egress_size = 0
	state.egress_size_sent = 0
	_response_clear_sendfile_plan(response)
	_ = header_set(response, "Content-Type", content_type)

	if !_response_commit_headers(response) {
		return .Flush_Final
	}

	if state.mode == .Head_Suppressed || file_size == 0 {
		return .Flush_Final
	}

	response.connection.connection_state.sendfile_file_fd = fd_file
	response.connection.connection_state.sendfile_offset = 0
	response.connection.connection_state.sendfile_size_remaining = file_size
	response.connection.connection_state.sendfile_active = true
	return .Flush
}

continue_100 :: proc "contextless" (response: ^Response) {
	state := _response_state(response)
	if .Interim_100_Sent in state.flags {
		return
	}
	_response_preserve_flags(state)
	state.status_code = HTTP_STATUS_CONTINUE
	state.mode = .Head_Suppressed
	state.body_size_total = 0
	state.body_size_sent = 0
	state.egress_size = 0
	state.egress_size_sent = 0
	_response_clear_sendfile_plan(response)

	size, ok := serialize_response_headers(
		response.connection.egress_buffer[:],
		state,
		response.connection.connection_state.response_header_bytes,
		_connection_date_value(response.connection, response.tina_context),
	)
	if !ok {
		_response_stage_internal_server_error(response, state)
		return
	}

	state.flags += {.Headers_Committed, .Interim_100_Sent}
	state.egress_size = size
}

write_bytes :: proc "contextless" (response: ^Response, data: []u8) -> u16 {
	state := _response_state(response)
	if state.mode == .Head_Suppressed {
		accepted_size := u16(min(len(data), int(max(u16))))
		state.body_size_sent += u64(accepted_size)
		return accepted_size
	}
	if state.mode == .Closed || len(data) == 0 {
		return 0
	}

	cursor := int(state.egress_size)
	remaining := len(response.connection.egress_buffer) - cursor
	if remaining <= 0 do return 0

	if state.mode == .Chunked {
		if remaining <= HTTP_CHUNKED_FRAMING_RESERVE {
			state.flags += {.Backpressured}
			return 0
		}
		free := u16(remaining - HTTP_CHUNKED_FRAMING_RESERVE)
		want := u16(min(len(data), int(max(u16))))
		admitted := admit_chunk_payload(free, want)
		if admitted == 0 {
			state.flags += {.Backpressured}
			return 0
		}

		next_cursor, ok := _write_hex_u16(response.connection.egress_buffer[:], cursor, admitted)
		if !ok do return 0
		next_cursor, ok = _write_bytes_into(
			response.connection.egress_buffer[:],
			next_cursor,
			transmute([]u8)string("\r\n"),
		)
		if !ok do return 0
		next_cursor, ok = _write_bytes_into(
			response.connection.egress_buffer[:],
			next_cursor,
			data[:int(admitted)],
		)
		if !ok do return 0
		next_cursor, ok = _write_bytes_into(
			response.connection.egress_buffer[:],
			next_cursor,
			transmute([]u8)string("\r\n"),
		)
		if !ok do return 0

		state.egress_size = Egress_Size(next_cursor)
		state.body_size_sent += u64(admitted)
		if int(admitted) < len(data) {
			state.flags += {.Backpressured}
		}
		return admitted
	}

	copy_size := min(len(data), remaining)
	if copy_size > 0 {
		copy(response.connection.egress_buffer[cursor:], data[:copy_size])
		state.egress_size = Egress_Size(cursor + copy_size)
		state.body_size_sent += u64(copy_size)
	}
	if copy_size < len(data) {
		state.flags += {.Backpressured}
	}
	return u16(copy_size)
}

flush :: proc(final: bool = false) -> Route_Step {
	return .Flush_Final if final else .Flush
}

read_body :: #force_inline proc "contextless" () -> Route_Step {
	return .Read_Body
}

close :: proc() -> Route_Step {return .Close}

@(private = "file")
_response_append_chunked_terminator :: proc "contextless" (
	state: ^Response_State,
	egress_buffer: []u8,
) -> bool {
	cursor := int(state.egress_size)
	if cursor + 5 > len(egress_buffer) {
		return false
	}
	copy(egress_buffer[cursor:], transmute([]u8)string("0\r\n\r\n"))
	state.egress_size = Egress_Size(cursor + 5)
	return true
}

@(private = "package")
_response_commit_headers :: proc "contextless" (response: ^Response) -> bool {
	state := _response_state(response)
	if .Headers_Committed in state.flags {
		return true
	}

	size, ok := serialize_response_headers(
		response.connection.egress_buffer[:],
		state,
		response.connection.connection_state.response_header_bytes,
		_connection_date_value(response.connection, response.tina_context),
	)
	if !ok {
		_response_stage_internal_server_error(response, state)
		return false
	}

	state.flags += {.Headers_Committed}
	state.egress_size = size
	state.egress_size_sent = 0
	return true
}

@(private = "package")
_response_prepare_flush :: proc "contextless" (response: ^Response, final: bool) -> bool {
	state := _response_state(response)
	if !_response_commit_headers(response) {
		return false
	}

	if final {
		if state.mode == .Chunked {
			if !_response_append_chunked_terminator(state, response.connection.egress_buffer[:]) {
				state.flags += {.Aborted, .Close_After_Send}
				return false
			}
		}
		state.mode = .Closed
	}

	return true
}

@(private = "package")
_response_prepare_next_message :: proc "contextless" (state: ^Response_State) {
	_response_preserve_flags(state)
	state.egress_size = 0
	state.egress_size_sent = 0
}

@(private = "file")
_stage_application_expectation :: proc "contextless" (
	route_context: Route_Context,
	kind: Application_Expectation_Kind,
	source_handle: tina.Handle,
	message_tag: Message_Tag,
	correlation_id: tina.Correlation_Id,
	timeout_ns: u64,
) {
	state := route_context.connection_state
	state.application_expectation_kind = kind
	state.application_expected_source = source_handle
	state.application_expected_tag = message_tag
	state.application_correlation_id = correlation_id
	state.application_timeout_ns = timeout_ns
}

@(require_results)
expect_reply :: proc(
	route_context: Route_Context,
	target_handle: tina.Handle,
	$message_tag: tina.Message_Tag,
	payload_bytes: []u8,
	timeout_ns: u64,
) -> tina.Send_Result {
	when tina.TINA_DEBUG_ASSERTS {
		assert(timeout_ns > 0, "expect_reply: timeout_ns must be > 0")
	}
	correlation_id := tina.ctx_reserve_correlation_id(route_context.tina_context)
	send_result := tina.ctx_send_with_correlation(
		route_context.tina_context,
		target_handle,
		tina.Message_Tag(message_tag),
		payload_bytes,
		correlation_id,
	)
	if send_result != .ok do return send_result

	_stage_application_expectation(
		route_context,
		.Reply,
		target_handle,
		message_tag,
		correlation_id,
		timeout_ns,
	)
	return .ok
}

expect_notification :: proc(
	route_context: Route_Context,
	timeout_ns: u64,
	source_handle: tina.Handle = tina.HANDLE_NONE,
	message_tag: Message_Tag = Message_Tag(0),
) -> Route_Step {
	when tina.TINA_DEBUG_ASSERTS {
		assert(timeout_ns > 0, "expect_notification: timeout_ns must be > 0")
	}
	correlation_id := tina.ctx_reserve_correlation_id(route_context.tina_context)
	_stage_application_expectation(
		route_context,
		.Notification,
		source_handle,
		message_tag,
		correlation_id,
		timeout_ns,
	)
	return .Expect_Application
}

@(private = "file")
_respond_bytes :: proc "contextless" (
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
	body: []u8,
) -> Route_Step {
	state := _response_state(response)
	_response_preserve_flags(state)
	state.status_code = status_code
	state.body_size_total = u64(len(body))
	state.body_size_sent = 0
	if state.mode != .Head_Suppressed {
		state.mode = .Fixed_Length
	}
	state.egress_size = Egress_Size(0)
	state.egress_size_sent = Egress_Size_Sent(0)
	_response_clear_sendfile_plan(response)
	_ = header_set(response, "Content-Type", content_type)

	size, ok := serialize_response_headers(
		response.connection.egress_buffer[:],
		state,
		response.connection.connection_state.response_header_bytes,
		_connection_date_value(response.connection, response.tina_context),
	)
	if !ok {
		_response_stage_internal_server_error(response, state)
		return .Flush_Final
	}

	if state.mode != .Head_Suppressed {
		body_size := len(body)
		if int(size) + body_size > len(response.connection.egress_buffer) {
			_response_stage_internal_server_error(response, state)
			return .Flush_Final
		}
		copy(response.connection.egress_buffer[int(size):], body)
		state.egress_size = Egress_Size(int(size) + body_size)
		state.body_size_sent = u64(body_size)
	} else {
		state.egress_size = size
		state.body_size_sent = state.body_size_total
	}
	state.flags += {.Headers_Committed}
	return .Flush_Final
}

@(private = "file")
_write_bytes_into :: #force_inline proc "contextless" (
	destination: []u8,
	cursor: int,
	payload: []u8,
) -> (
	next_cursor: int,
	ok: bool,
) {
	next_cursor = cursor + len(payload)
	if next_cursor > len(destination) do return cursor, false
	#no_bounds_check if len(payload) > 0 do copy(destination[cursor:], payload)
	return next_cursor, true
}

@(private = "file")
_write_byte_into :: #force_inline proc "contextless" (
	destination: []u8,
	cursor: int,
	value: u8,
) -> (
	next_cursor: int,
	ok: bool,
) {
	if cursor >= len(destination) do return cursor, false
	#no_bounds_check destination[cursor] = value
	return cursor + 1, true
}

// Note on `%`: Odin distinguishes truncated remainder (`%`) from Euclidean
// modulo (`%%`). For the unsigned operands used in this file they are
// identical; `%` is intentional.

// Writes a 3-digit ASCII status code. HTTP statuses are always 100..599 so
// width is fixed at 3 — no leading zeroes elision, no separate decoding path.
@(private = "file")
_write_status_code :: #force_inline proc "contextless" (
	destination: []u8,
	cursor: int,
	code: HTTP_Status,
) -> (
	next_cursor: int,
	ok: bool,
) {
	if cursor + 3 > len(destination) do return cursor, false
	value := u16(code)
	#no_bounds_check {
		destination[cursor + 0] = u8('0' + (value / 100) % 10)
		destination[cursor + 1] = u8('0' + (value / 10) % 10)
		destination[cursor + 2] = u8('0' + value % 10)
	}
	return cursor + 3, true
}

@(private = "file")
_write_hex_u16 :: proc "contextless" (
	destination: []u8,
	cursor: int,
	value: u16,
) -> (
	next_cursor: int,
	ok: bool,
) {
	if value == 0 {
		return _write_byte_into(destination, cursor, '0')
	}

	digit_count := int(hex_size_chars(value))
	next_cursor = cursor + digit_count
	if next_cursor > len(destination) do return cursor, false

	remainder := value
	#no_bounds_check for index in 0 ..< digit_count {
		digit := remainder & 0xF
		ascii_digit := u8('0' + digit)
		if digit >= 10 {
			ascii_digit = u8('a' + (digit - 10))
		}
		destination[next_cursor - 1 - index] = ascii_digit
		remainder >>= 4
	}
	return next_cursor, true
}

@(private = "file")
_write_content_length :: proc "contextless" (
	destination: []u8,
	cursor: int,
	body_size: u64,
) -> (
	next_cursor: int,
	ok: bool,
) {
	next_cursor = cursor
	next_cursor, ok = _write_bytes_into(
		destination,
		next_cursor,
		transmute([]u8)string("Content-Length: "),
	)
	if !ok do return cursor, false
	next_cursor, ok = _write_decimal_u64(destination, next_cursor, body_size)
	if !ok do return cursor, false
	return _write_bytes_into(destination, next_cursor, transmute([]u8)string("\r\n"))
}

@(private = "file")
_write_decimal_u64 :: proc "contextless" (
	destination: []u8,
	cursor: int,
	value: u64,
) -> (
	next_cursor: int,
	ok: bool,
) {
	// u64 max fits in 20 decimal digits; build right-to-left into a stack
	// scratch then copy left-to-right into the destination. This avoids both
	// allocation and a divide-by-power-of-ten table.
	scratch: [20]u8
	digit_count := 0
	if value == 0 {
		scratch[0] = '0'
		digit_count = 1
	} else {
		remainder := value
		for remainder > 0 {
			scratch[digit_count] = u8('0' + (remainder % 10))
			digit_count += 1
			remainder /= 10
		}
	}
	next_cursor = cursor + digit_count
	if next_cursor > len(destination) do return cursor, false
	#no_bounds_check for index in 0 ..< digit_count {
		destination[cursor + index] = scratch[digit_count - 1 - index]
	}
	return next_cursor, true
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

// ─── Reset and Layout ──────────────────────────────────────────────────────

@(test)
test_response_state_reset_baseline :: proc(t: ^testing.T) {
	response: Response_State
	response.status_code = 404
	response.header_count = 5
	response.header_bytes_used = 99
	response.flags = {.Headers_Committed, .User_Set_Date}
	response.mode = .Chunked
	response.egress_size = 123

	response_state_reset(&response)

	testing.expect_value(t, response.status_code, HTTP_STATUS_DEFAULT)
	testing.expect_value(t, response.header_count, 0)
	testing.expect_value(t, response.header_bytes_used, 0)
	testing.expect_value(t, response.mode, Response_Mode.Not_Started)
	testing.expect_value(t, response.egress_size, Egress_Size(0))
	testing.expect(t, response.flags == {}, "flags must reset to empty")
}

// ─── header_set / header_add ───────────────────────────────────────────────

@(test)
test_response_header_set_appends_when_absent :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	ok := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Content-Type"),
		transmute([]u8)string("application/json"),
	)

	testing.expect(t, ok)
	testing.expect_value(t, response.header_count, 1)
	testing.expect_value(t, response.headers[0].name_size, u16(12))
	testing.expect_value(t, response.headers[0].value_size, u16(16))
}

@(test)
test_response_header_set_updates_in_place :: proc(t: ^testing.T) {
	// A second header_set on the same name must update the existing entry's
	// value offset/size — header_count must stay at 1 (DR-1 update-in-place).
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	_ = response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Content-Type"),
		transmute([]u8)string("text/plain"),
	)
	cursor_after_first := response.header_bytes_used

	ok := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("content-type"), // case-insensitive match
		transmute([]u8)string("application/json"),
	)
	testing.expect(t, ok)
	testing.expect_value(t, response.header_count, 1)
	testing.expect_value(t, response.headers[0].value_size, u16(16))

	// Bytes-region cursor advances by the new value's length only — the
	// older value lives on as dead bytes (acceptable soft cost per DR-1).
	testing.expect_value(t, response.header_bytes_used, cursor_after_first + 16)

	resolved := region[response.headers[0].value_offset:][:response.headers[0].value_size]
	testing.expect(t, string(resolved) == "application/json")
}

@(test)
test_response_header_add_creates_separate_entries :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	_ = response_header_add(
		&response,
		region[:],
		transmute([]u8)string("Set-Cookie"),
		transmute([]u8)string("a=1"),
	)
	_ = response_header_add(
		&response,
		region[:],
		transmute([]u8)string("Set-Cookie"),
		transmute([]u8)string("b=2"),
	)

	testing.expect_value(t, response.header_count, 2)
}

@(test)
test_response_header_set_reserved_silently_ignored :: proc(t: ^testing.T) {
	// Library-owned framing names must not be staged. The contract returns
	// `true` so middleware does not 500 on a no-op.
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	ok_a := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Content-Length"),
		transmute([]u8)string("999"),
	)
	ok_b := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Transfer-Encoding"),
		transmute([]u8)string("chunked"),
	)
	ok_c := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Connection"),
		transmute([]u8)string("close"),
	)

	testing.expect(t, ok_a && ok_b && ok_c)
	testing.expect_value(t, response.header_count, 0)
	testing.expect_value(t, response.header_bytes_used, u16(0))
}

@(test)
test_response_header_set_user_date_flag :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	_ = response_header_set(
		&response,
		region[:],
		transmute([]u8)string("date"),
		transmute([]u8)string("Wed, 01 May 2026 12:00:00 GMT"),
	)
	testing.expect(t, .User_Set_Date in response.flags)
}

@(test)
test_response_header_set_bytes_region_overflow :: proc(t: ^testing.T) {
	// Fill the bytes region until the next staging call must overflow. The
	// helper returns `false` so the connection state machine can transition
	// to the transactional 500 path (DR-6 / Phase 7).
	response: Response_State
	response_state_reset(&response)
	region: [16]u8 // intentionally tiny

	// 4 + 6 = 10 bytes consumed; cursor at 10 of 16.
	ok := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Name"),
		transmute([]u8)string("value!"),
	)
	testing.expect(t, ok)
	testing.expect_value(t, response.header_bytes_used, u16(10))

	// Adding another header with combined name+value > 6 bytes must fail.
	overflow_ok := response_header_add(
		&response,
		region[:],
		transmute([]u8)string("XXXXXX"),
		transmute([]u8)string("YYYY"),
	)
	testing.expect(t, !overflow_ok, "bytes-region overflow must return false")
	// Cursor must remain at the pre-attempt position so the response state
	// stays coherent for the 500 path.
	testing.expect_value(t, response.header_bytes_used, u16(10))
	testing.expect_value(t, response.header_count, 1)
}

@(test)
test_response_header_set_entry_array_overflow :: proc(t: ^testing.T) {
	// header_add unconditionally appends. Filling beyond HTTP_RESPONSE_HEADERS_MAX
	// must fail without corrupting the entry array.
	response: Response_State
	response_state_reset(&response)
	region: [4096]u8

	// Use a unique single-character name per slot via Set-Cookie (allows duplicates).
	for index in 0 ..< HTTP_RESPONSE_HEADERS_MAX {
		ok := response_header_add(
			&response,
			region[:],
			transmute([]u8)string("Set-Cookie"),
			transmute([]u8)string("k=v"),
		)
		testing.expectf(t, ok, "fill index %d should succeed", index)
	}
	testing.expect_value(t, int(response.header_count), HTTP_RESPONSE_HEADERS_MAX)

	overflow_ok := response_header_add(
		&response,
		region[:],
		transmute([]u8)string("Set-Cookie"),
		transmute([]u8)string("k=v"),
	)
	testing.expect(t, !overflow_ok, "entry-array overflow must return false")
	testing.expect_value(t, int(response.header_count), HTTP_RESPONSE_HEADERS_MAX)
}

@(test)
test_response_header_set_after_commit_fails :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.flags += {.Headers_Committed}
	region: [256]u8

	ok := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("X-Late"),
		transmute([]u8)string("v"),
	)
	testing.expect(t, !ok, "writes after commit must fail")
}

// ─── admit_chunk_payload ───────────────────────────────────────────────────

@(test)
test_admit_chunk_payload_zero_want :: proc(t: ^testing.T) {
	// Empty payload must always yield 0 — write_bytes uses this to short-
	// circuit and avoid emitting a zero-length chunk (the terminator's form).
	testing.expect_value(t, admit_chunk_payload(1024, 0), u16(0))
}

@(test)
test_admit_chunk_payload_below_min_framing :: proc(t: ^testing.T) {
	// 5 bytes free is exactly the terminator's footprint; anything below 6
	// (1 hex + CRLF + 1 + CRLF) cannot admit even one byte of payload.
	testing.expect_value(t, admit_chunk_payload(0, 100), u16(0))
	testing.expect_value(t, admit_chunk_payload(5, 100), u16(0))
	testing.expect_value(t, admit_chunk_payload(6, 100), u16(1))
}

@(test)
test_admit_chunk_payload_natural_fit :: proc(t: ^testing.T) {
	// hex(15) = 1 char, framing tax = 5, total = 20.
	testing.expect_value(t, admit_chunk_payload(20, 15), u16(15))
	// hex(16) = 2 chars, framing tax = 6, total = 22.
	testing.expect_value(t, admit_chunk_payload(22, 16), u16(16))
}

@(test)
test_admit_chunk_payload_band_boundary_2_to_1 :: proc(t: ^testing.T) {
	// want=20 (2 hex chars), free=21 → cannot fit 2-hex band's natural 20+6=26.
	// Algorithm must cap at 1-hex band: candidate = free - 5 = 16, but
	// candidate must remain inside the 1-hex band (≤ 0xF), so n=15.
	got := admit_chunk_payload(21, 20)
	testing.expectf(t, got == 15, "want 15, got %d", got)
}

@(test)
test_admit_chunk_payload_band_boundary_3_to_2 :: proc(t: ^testing.T) {
	// want=300 (3 hex chars), free=262 → 3-hex band needs at least 0x100
	// (256) bytes of payload, costing 3+4+256 = 263 > 262. Algorithm must
	// fall to the 2-hex band: candidate = min(300, 0xFF, 262-6) = 255.
	// Verify: 2+2+255+2 = 261 ≤ 262.
	got := admit_chunk_payload(262, 300)
	testing.expectf(t, got == 255, "want 255, got %d", got)
}

@(test)
test_admit_chunk_payload_never_exceeds_want :: proc(t: ^testing.T) {
	// Generous free, modest want — must never inflate the request.
	testing.expect_value(t, admit_chunk_payload(8192, 100), u16(100))
}

@(test)
test_admit_chunk_payload_leaves_terminator_room :: proc(t: ^testing.T) {
	// Phase 3 acceptance criterion: with a large simulated slice, admission
	// must leave exact room for the `0\r\n\r\n` terminator (5 bytes) inside
	// the 16-byte chunked framing reserve. The reserve is *not* part of
	// `free` — it has already been removed before calling — so we verify the
	// invariant by simulating the worst case: the entire egress payload
	// budget is `free`.
	free := u16(HTTP_EGRESS_BUFFER_SIZE - HTTP_CHUNKED_FRAMING_RESERVE)
	want := u16(65535)

	admitted := admit_chunk_payload(free, want)

	// After admission, the bytes consumed by this chunk are
	//   hex_size_chars(admitted) + 2 + admitted + 2
	// and the difference against `free` is the slack inside the payload
	// budget. Combined with the 16-byte reserve, total post-write headroom
	// is at least the terminator's 5 bytes and the 16-byte reserve guarantee.
	consumed := u32(hex_size_chars(admitted)) + 2 + u32(admitted) + 2
	testing.expectf(
		t,
		consumed <= u32(free),
		"admission must not exceed `free` (admitted=%d consumed=%d free=%d)",
		admitted,
		consumed,
		free,
	)

	post_chunk_headroom := u32(HTTP_EGRESS_BUFFER_SIZE) - consumed
	testing.expectf(
		t,
		post_chunk_headroom >= 5,
		"post-chunk headroom must reserve the 0\\r\\n\\r\\n terminator (got %d)",
		post_chunk_headroom,
	)

	// Stronger invariant: the framing reserve itself is preserved as a whole.
	testing.expectf(
		t,
		post_chunk_headroom >= u32(HTTP_CHUNKED_FRAMING_RESERVE),
		"the 16-byte chunked framing reserve must remain intact (got %d)",
		post_chunk_headroom,
	)
}

// ─── hex_size_chars ────────────────────────────────────────────────────────

@(test)
test_hex_size_chars_bands :: proc(t: ^testing.T) {
	testing.expect_value(t, hex_size_chars(1), u16(1))
	testing.expect_value(t, hex_size_chars(0xF), u16(1))
	testing.expect_value(t, hex_size_chars(0x10), u16(2))
	testing.expect_value(t, hex_size_chars(0xFF), u16(2))
	testing.expect_value(t, hex_size_chars(0x100), u16(3))
	testing.expect_value(t, hex_size_chars(0xFFF), u16(3))
	testing.expect_value(t, hex_size_chars(0x1000), u16(4))
	testing.expect_value(t, hex_size_chars(0xFFFF), u16(4))
}

// ─── status_reason_phrase ──────────────────────────────────────────────────

@(test)
test_status_reason_phrase_known :: proc(t: ^testing.T) {
	testing.expect_value(t, status_reason_phrase(200), "OK")
	testing.expect_value(t, status_reason_phrase(404), "Not Found")
	testing.expect_value(t, status_reason_phrase(500), "Internal Server Error")
	testing.expect_value(t, status_reason_phrase(431), "Request Header Fields Too Large")
}

@(test)
test_status_reason_phrase_unknown :: proc(t: ^testing.T) {
	// Unknown codes return empty so the serializer still writes a valid line.
	testing.expect_value(t, status_reason_phrase(999), "")
}

// ─── serialize_response_headers ────────────────────────────────────────────

@(test)
test_serialize_basic_200_with_user_header :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.mode = .Fixed_Length
	response.body_size_total = 11

	region: [256]u8
	_ = response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Content-Type"),
		transmute([]u8)string("text/plain"),
	)

	destination: [HTTP_EGRESS_BUFFER_SIZE]u8
	size, ok := serialize_response_headers(
		destination[:],
		&response,
		region[:],
		transmute([]u8)string("Wed, 01 May 2026 12:00:00 GMT"),
	)
	testing.expect(t, ok)

	head := string(destination[:size])
	testing.expect(t, strings.index(head, "HTTP/1.1 200 OK\r\n") == 0)
	testing.expect(t, strings.index(head, "\r\nDate: Wed, 01 May 2026 12:00:00 GMT\r\n") >= 0)
	testing.expect(t, strings.index(head, "\r\nContent-Length: 11\r\n") >= 0)
	testing.expect(t, strings.index(head, "\r\nContent-Type: text/plain\r\n") >= 0)
	// Header block ends with a blank-line terminator.
	testing.expect(t, len(head) >= 4 && head[len(head) - 4:] == "\r\n\r\n")
}

@(test)
test_serialize_chunked_emits_transfer_encoding :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.mode = .Chunked

	region: [64]u8
	destination: [HTTP_EGRESS_BUFFER_SIZE]u8

	size, ok := serialize_response_headers(destination[:], &response, region[:], nil)
	testing.expect(t, ok)
	head := string(destination[:size])

	testing.expect(t, strings.index(head, "\r\nTransfer-Encoding: chunked\r\n") >= 0)
	testing.expect(t, strings.index(head, "Content-Length:") < 0)
}

@(test)
test_serialize_close_after_send_emits_connection_close :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.mode = .Fixed_Length
	response.flags += {.Close_After_Send}

	region: [64]u8
	destination: [HTTP_EGRESS_BUFFER_SIZE]u8

	size, ok := serialize_response_headers(destination[:], &response, region[:], nil)
	testing.expect(t, ok)
	head := string(destination[:size])
	testing.expect(t, strings.index(head, "\r\nConnection: close\r\n") >= 0)
}

@(test)
test_serialize_user_set_date_skips_auto_date :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.mode = .Fixed_Length
	response.flags += {.User_Set_Date}

	region: [256]u8
	destination: [HTTP_EGRESS_BUFFER_SIZE]u8

	size, ok := serialize_response_headers(
		destination[:],
		&response,
		region[:],
		transmute([]u8)string("Wed, 01 May 2026 12:00:00 GMT"),
	)
	testing.expect(t, ok)
	head := string(destination[:size])
	testing.expect(t, strings.index(head, "Date:") < 0, "auto-Date must be suppressed")
}

@(test)
test_serialize_unknown_status_writes_empty_reason :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.status_code = 999
	response.mode = .Fixed_Length

	region: [64]u8
	destination: [HTTP_EGRESS_BUFFER_SIZE]u8

	size, ok := serialize_response_headers(destination[:], &response, region[:], nil)
	testing.expect(t, ok)
	head := string(destination[:size])
	// "HTTP/1.1 999 \r\n" — three-digit code, SP, empty reason, CRLF.
	testing.expect(t, head[:15] == "HTTP/1.1 999 \r\n")
}

@(test)
test_serialize_egress_overflow_returns_zero_false :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	response.mode = .Fixed_Length
	response.body_size_total = 0

	region: [64]u8
	tiny_destination: [16]u8 // far too small for any valid response head

	size, ok := serialize_response_headers(tiny_destination[:], &response, region[:], nil)
	testing.expect(t, !ok, "tiny destination must overflow")
	testing.expect_value(t, size, Egress_Size(0))
}

@(test)
test_serialize_head_suppressed_emits_content_length :: proc(t: ^testing.T) {
	// HEAD responses must emit Content-Length "as if GET" so the client can
	// size the absent body (DR-9 / §3.6).
	response: Response_State
	response_state_reset(&response)
	response.mode = .Head_Suppressed
	response.body_size_total = 1234

	region: [64]u8
	destination: [HTTP_EGRESS_BUFFER_SIZE]u8

	size, ok := serialize_response_headers(destination[:], &response, region[:], nil)
	testing.expect(t, ok)
	head := string(destination[:size])
	testing.expect(t, strings.index(head, "\r\nContent-Length: 1234\r\n") >= 0)
}

@(test)
test_begin_stream_commits_headers_and_write_bytes_frames_chunk :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	response := http_test_fixture_response(&fixture)

	begin_stream(&response, HTTP_STATUS_OK, "text/plain")
	state := _response_state(&response)

	testing.expect(t, .Headers_Committed in state.flags)
	head_size := int(state.egress_size)
	testing.expect(t, head_size > 0)
	committed_head := string(fixture.connection.egress_buffer[:head_size])
	testing.expect(t, strings.index(committed_head, "\r\nTransfer-Encoding: chunked\r\n") >= 0)

	admitted := write_bytes(&response, transmute([]u8)string("hello"))
	testing.expect_value(t, admitted, u16(5))

	wire_chunk := string(fixture.connection.egress_buffer[head_size:int(state.egress_size)])
	testing.expect_value(t, wire_chunk, "5\r\nhello\r\n")
}

@(test)
test_response_prepare_flush_final_appends_chunked_terminator :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	response := http_test_fixture_response(&fixture)

	begin_stream(&response, HTTP_STATUS_OK, "text/plain")
	_ = write_bytes(&response, transmute([]u8)string("ab"))
	state := _response_state(&response)
	pre_flush_size := int(state.egress_size)

	ok := _response_prepare_flush(&response, true)
	testing.expect(t, ok)
	testing.expect(t, state.mode == .Closed)
	testing.expect_value(
		t,
		string(fixture.connection.egress_buffer[pre_flush_size:int(state.egress_size)]),
		"0\r\n\r\n",
	)
}

@(test)
test_head_suppressed_write_bytes_accepts_without_staging :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.response.mode = .Head_Suppressed
	response := http_test_fixture_response(&fixture)

	begin_stream(&response, HTTP_STATUS_OK, "text/plain")
	state := _response_state(&response)
	header_size := int(state.egress_size)
	accepted := write_bytes(&response, transmute([]u8)string("payload"))

	testing.expect_value(t, accepted, u16(7))
	testing.expect_value(t, int(state.egress_size), header_size)
	testing.expect_value(t, state.body_size_sent, u64(7))
}

@(test)
test_respond_file_sets_sendfile_plan_and_returns_flush :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	response := http_test_fixture_response(&fixture)

	step := respond_file(&response, tina.FD_Handle(42), 8192, "application/octet-stream")
	testing.expect_value(t, step, Route_Step.Flush)
	testing.expect_value(t, fixture.connection.connection_state.sendfile_file_fd, tina.FD_Handle(42))
	testing.expect_value(t, fixture.connection.connection_state.sendfile_offset, u64(0))
	testing.expect_value(t, fixture.connection.connection_state.sendfile_size_remaining, u64(8192))
	testing.expect_value(t, fixture.connection.connection_state.sendfile_active, true)
}
