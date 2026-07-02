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
#assert(HTTP_EGRESS_BUFFER_SIZE <= max(u16))
#assert(HTTP_RESPONSE_HEADERS_MAX > 0 && HTTP_RESPONSE_HEADERS_MAX <= 255)

// Bytes staged in egress_buffer ready to send.
Egress_Size :: distinct u16

// Bytes already transmitted from egress_buffer.
Egress_Size_Sent :: distinct u16

// What happens to the response body on the wire. This is orthogonal to the
// transport framing mode because the same transport (Fixed_Length) can either
// send bytes or suppress them (HEAD), and some status codes forbid body
// framing headers entirely (1xx, 204, 304).
@(private = "package")
Response_Body_Policy :: enum u8 {
	Send, // Body is sent as declared by the framing mode.
	Suppress_With_Length, // Body is suppressed, but Content-Length is emitted (HEAD).
	Suppress_Without_Framing, // Body is suppressed and no framing header is emitted (1xx, 204, 304).
}

@(private = "package")
Response_Mode :: enum u8 {
	Not_Started, // No status / headers staged yet; entries empty.
	Fixed_Length, // Content-Length framing; body_size_total is authoritative.
	Chunked, // Transfer-Encoding: chunked; no Content-Length.
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
	Fixed_Length_Body_Violation, // Declared Content-Length contract was broken.
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

Header_Result :: enum u8 {
	Staged,
	Reserved_Name,
	Invalid_Name,
	Invalid_Value,
	Header_Count_Exceeded,
	Header_Bytes_Exceeded,
	Already_Committed,
	Aborted,
}

Response_Begin_Result :: enum u8 {
	Begun,
	Already_Committed,
	Aborted,
	Invalid_Header,
	Header_Count_Exceeded,
	Header_Bytes_Exceeded,
	Egress_Buffer_Exceeded,
}

Body_Reservation_Result :: enum u8 {
	Reserved,
	Suppressed,
	Backpressured,
	Body_Too_Large,
	Closed,
	Invalid_Mode,
}

Body_Commit_Result :: enum u8 {
	Committed,
	Stale,
}

Body_Reservation :: struct {
	payload:               []u8,
	egress_size_before:    Egress_Size,
	egress_size_commit:    Egress_Size,
	body_size_sent_before: u64,
	body_size_sent_commit: u64,
}

@(private = "file")
Header_Stage_Mode :: enum u8 {
	Set,
	Add,
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
	body_policy:       Response_Body_Policy,
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
		body_policy = .Send,
	}
}

response_header_set :: proc "contextless" (
	response: ^Response_State,
	bytes_region: []u8,
	name: []u8,
	value: []u8,
) -> Header_Result {
	return _stage_header(response, bytes_region, name, value, .Set)
}

response_header_add :: proc "contextless" (
	response: ^Response_State,
	bytes_region: []u8,
	name: []u8,
	value: []u8,
) -> Header_Result {
	return _stage_header(response, bytes_region, name, value, .Add)
}

// Internal staging core. Held in one place so that `header_set` and
// `header_add` cannot drift apart in their reserved-name handling or
// overflow accounting.
@(private = "file")
_stage_header :: proc "contextless" (
	response: ^Response_State,
	bytes_region: []u8,
	name: []u8,
	value: []u8,
	mode: Header_Stage_Mode,
) -> Header_Result {
	if .Headers_Committed in response.flags do return .Already_Committed
	if .Aborted in response.flags do return .Aborted
	if len(name) == 0 do return .Invalid_Name
	if !validate_token_bytes(name) do return .Invalid_Name
	if _name_is_reserved(name) do return .Reserved_Name

	for byte_value in value {
		if !is_header_value_byte(byte_value) do return .Invalid_Value
	}

	cursor := int(response.header_bytes_used)
	region_size := len(bytes_region)

	if mode == .Set {
		#no_bounds_check for index in 0 ..< response.header_count {
			entry := response.headers[index]
			existing_name := bytes_region[entry.name_offset:][:entry.name_size]
			if !equal_bytes_ci(existing_name, name) do continue

			// Reuse this slot. Only the value bytes are appended fresh.
			// Pre-flight the budget so a failure leaves the cursor at its
			// pre-call position — staging is transactional.
			new_header_bytes_used := u32(cursor) + u32(len(value))
			if new_header_bytes_used > u32(max(u16)) do return .Header_Bytes_Exceeded
			if int(new_header_bytes_used) > region_size do return .Header_Bytes_Exceeded

			if len(value) > 0 do copy(bytes_region[cursor:], value)
			response.headers[index].value_offset = u16(cursor)
			response.headers[index].value_size = u16(len(value))
			response.header_bytes_used = u16(new_header_bytes_used)
			return .Staged
		}
	}

	// Append path. The entry-array budget is the structural slot space.
	if response.header_count >= HTTP_RESPONSE_HEADERS_MAX do return .Header_Count_Exceeded

	// Pre-flight name + value together so a partial name copy cannot leave
	// the cursor advanced when the subsequent value copy would overflow.
	new_header_bytes_used := u32(cursor) + u32(len(name)) + u32(len(value))
	if new_header_bytes_used > u32(max(u16)) do return .Header_Bytes_Exceeded
	if int(new_header_bytes_used) > region_size do return .Header_Bytes_Exceeded

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
	return .Staged
}

@(private = "file")
_name_is_reserved :: #force_inline proc "contextless" (name: []u8) -> bool {
	switch len(name) {
	case 4:
		return equal_bytes_ci_with_rhs_lowercase(name, "date")
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
//   response          — staged headers, mode, and body policy
//   bytes_region      — Working Memory slice the entry offsets index into
//   date_value        — pre-formatted Date value (e.g. "Wed, 01 May 2026 12:34:56 GMT").
//                       Empty disables auto-Date emission.
//
// The caller is responsible for setting `response.body_size_total` for
// `Fixed_Length` and `.Suppress_With_Length` body policy before calling.

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

	// 2. Date — framework-owned, always auto-injected when a value is supplied.
	if len(date_value) > 0 {
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

	// 4. Framing header per response body policy and transport mode
	//    (library-owned, written here only).
	#partial switch response.body_policy {
	case .Suppress_Without_Framing:
		// 1xx, 204, and 304 responses must not carry Content-Length or
		// Transfer-Encoding framing headers (RFC 9110/9112).
	case .Suppress_With_Length:
		// HEAD responses describe the would-be body size but never send it.
		cursor = _write_content_length(destination, cursor, response.body_size_total) or_return
	case .Send:
		#partial switch response.mode {
		case .Not_Started:
			// Treat Not_Started identically to Fixed_Length 0 — the caller may
			// have called serialize without a respond_*() (e.g. raw hand-off).
			cursor = _write_content_length(destination, cursor, 0) or_return
		case .Fixed_Length:
			cursor = _write_content_length(destination, cursor, response.body_size_total) or_return
		case .Chunked:
			cursor = _write_bytes_into(
				destination,
				cursor,
				transmute([]u8)string("Transfer-Encoding: chunked\r\n"),
			)		or_return
		case .Closed:
			// Closed responses must never round-trip through the serializer; the
			// state machine writes the canned 500 directly. Treat as overflow.
			return
		}
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
	close_after_send := .Close_After_Send in state.flags
	in_drain := .In_Drain in state.flags
	interim_100_sent := .Interim_100_Sent in state.flags
	response_state_reset(state)
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

@(private = "file")
_response_prepare_begin :: proc "contextless" (state: ^Response_State) -> Response_Begin_Result {
	if .Headers_Committed in state.flags do return .Already_Committed
	if .Aborted in state.flags do return .Aborted

	headers := state.headers
	header_count := state.header_count
	header_bytes_used := state.header_bytes_used
	_response_preserve_flags(state)
	state.headers = headers
	state.header_count = header_count
	state.header_bytes_used = header_bytes_used
	return .Begun
}

@(private = "file")
_response_begin_result_from_header :: #force_inline proc "contextless" (
	header_result: Header_Result,
) -> Response_Begin_Result {
	switch header_result {
	case .Staged, .Reserved_Name:
		return .Begun
	case .Header_Count_Exceeded:
		return .Header_Count_Exceeded
	case .Header_Bytes_Exceeded:
		return .Header_Bytes_Exceeded
	case .Invalid_Name, .Invalid_Value:
		return .Invalid_Header
	case .Already_Committed:
		return .Already_Committed
	case .Aborted:
		return .Aborted
	}
	return .Aborted
}

status :: #force_inline proc (response: ^Response, code: HTTP_Status) {
	state := _response_state(response)
	when tina.TINA_RUNTIME_ASSERTIONS {
		if .Headers_Committed in state.flags {
			assert(false, "status: cannot change status after headers are committed")
		}
	}
	state.status_code = code
	state.body_policy = _body_policy_from_status(code, response.connection.connection_state.request.method)
}

@(private = "file")
_body_policy_from_status :: #force_inline proc "contextless" (
	code: HTTP_Status,
	method: Method,
) -> Response_Body_Policy {
	// Informational responses and statuses that forbid a message body must
	// not carry Content-Length or Transfer-Encoding framing headers.
	if code < 200 || code == HTTP_STATUS_NO_CONTENT || code == HTTP_STATUS_NOT_MODIFIED {
		return .Suppress_Without_Framing
	}
	// HEAD responses describe the would-be GET body via Content-Length but
	// never send the body itself.
	if method == .HEAD {
		return .Suppress_With_Length
	}
	return .Send
}

@(require_results)
header_set :: #force_inline proc "contextless" (
	response: ^Response,
	name: string,
	value: string,
) -> Header_Result {
	return response_header_set(
		_response_state(response),
		response.connection.connection_state.response_header_bytes,
		transmute([]u8)name,
		transmute([]u8)value,
	)
}

@(require_results)
header_add :: #force_inline proc "contextless" (
	response: ^Response,
	name: string,
	value: string,
) -> Header_Result {
	return response_header_add(
		_response_state(response),
		response.connection.connection_state.response_header_bytes,
		transmute([]u8)name,
		transmute([]u8)value,
	)
}

respond_text :: #force_inline proc(
	response: ^Response,
	status_code: HTTP_Status,
	body: string,
) -> Route_Step {
	return _respond_bytes(response, status_code, "text/plain; charset=utf-8", transmute([]u8)body)
}

respond_json :: #force_inline proc(
	response: ^Response,
	status_code: HTTP_Status,
	body: string,
) -> Route_Step {
	return _respond_bytes(response, status_code, "application/json", transmute([]u8)body)
}

respond_bytes :: #force_inline proc(
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
	body: []u8,
) -> Route_Step {
	return _respond_bytes(response, status_code, content_type, body)
}

@(require_results)
begin_stream :: proc(
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
) -> Response_Begin_Result {
	state := _response_state(response)
	if result := _response_prepare_begin(state); result != .Begun {
		return result
	}
	status(response, status_code)
	if state.body_policy == .Send {
		state.mode = .Chunked
	}
	state.body_size_total = 0
	state.body_size_sent = 0
	state.egress_size = Egress_Size(0)
	state.egress_size_sent = Egress_Size_Sent(0)
	_response_clear_sendfile_plan(response)
	header_result := header_set(response, "Content-Type", content_type)
	if header_result != .Staged {
		_response_stage_internal_server_error(response, state)
		return _response_begin_result_from_header(header_result)
	}
	if !_response_commit_headers(response) {
		return .Egress_Buffer_Exceeded
	}
	return .Begun
}

@(require_results)
begin_fixed_stream :: proc(
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
	total_size: u64,
) -> Response_Begin_Result {
	state := _response_state(response)
	if result := _response_prepare_begin(state); result != .Begun {
		return result
	}
	status(response, status_code)
	if state.body_policy == .Send {
		state.mode = .Fixed_Length
	}
	state.body_size_total = total_size
	state.body_size_sent = 0
	state.egress_size = Egress_Size(0)
	state.egress_size_sent = Egress_Size_Sent(0)
	_response_clear_sendfile_plan(response)
	header_result := header_set(response, "Content-Type", content_type)
	if header_result != .Staged {
		_response_stage_internal_server_error(response, state)
		return _response_begin_result_from_header(header_result)
	}
	if !_response_commit_headers(response) {
		return .Egress_Buffer_Exceeded
	}
	return .Begun
}

respond_file :: proc(
	response: ^Response,
	fd_file: tina.FD_Handle,
	file_size: u64,
	content_type: string,
) -> Route_Step {
	state := _response_state(response)
	if _response_prepare_begin(state) != .Begun {
		_response_stage_internal_server_error(response, state)
		return .Flush_Final
	}
	status(response, HTTP_STATUS_OK)
	if state.body_policy == .Send {
		state.mode = .Fixed_Length
	}
	state.body_size_total = file_size
	state.body_size_sent = 0
	state.egress_size = 0
	state.egress_size_sent = 0
	_response_clear_sendfile_plan(response)
	if header_set(response, "Content-Type", content_type) != .Staged {
		_response_stage_internal_server_error(response, state)
		return .Flush_Final
	}

	if !_response_commit_headers(response) {
		return .Flush_Final
	}

	if state.body_policy != .Send || file_size == 0 {
		return .Flush_Final
	}

	response.connection.connection_state.sendfile_file_fd = fd_file
	response.connection.connection_state.sendfile_offset = 0
	response.connection.connection_state.sendfile_size_remaining = file_size
	response.connection.connection_state.sendfile_active = true
	return .Flush
}

continue_100 :: proc(response: ^Response) {
	state := _response_state(response)
	if .Interim_100_Sent in state.flags || .Headers_Committed in state.flags {
		return
	}
	_response_preserve_flags(state)
	status(response, HTTP_STATUS_CONTINUE)
	state.body_size_total = 0
	state.body_size_sent = 0
	state.egress_size = 0
	state.egress_size_sent = 0
	_response_clear_sendfile_plan(response)

	if !_response_commit_headers(response) {
		return
	}
	state.flags += {.Interim_100_Sent}
}

write_bytes :: proc(response: ^Response, data: []u8) -> u16 {
	state := _response_state(response)
	data_size := len(data)
	if state.body_policy != .Send {
		accepted_size := u16(min(data_size, int(max(u16))))
		state.body_size_sent += u64(accepted_size)
		return accepted_size
	}
	if state.mode == .Closed || data_size == 0 {
		return 0
	}
	// Fixed-length streaming is a byte-for-byte contract: never stage bytes
	// beyond the already-advertised Content-Length.
	if state.mode == .Fixed_Length {
		if state.body_size_sent > state.body_size_total {
			state.flags += {.Aborted, .Close_After_Send, .Fixed_Length_Body_Violation}
			state.mode = .Closed
			when tina.TINA_RUNTIME_ASSERTIONS {
				assert(false, "write_bytes: fixed-length body size already exceeds declared Content-Length")
			}
			return 0
		}

		body_size_remaining := state.body_size_total - state.body_size_sent
		if u64(data_size) > body_size_remaining {
			state.flags += {.Aborted, .Close_After_Send, .Fixed_Length_Body_Violation}
			state.mode = .Closed
			when tina.TINA_RUNTIME_ASSERTIONS {
				assert(false, "write_bytes: fixed-length write exceeds declared Content-Length")
			}
			return 0
		}
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
		want := u16(min(data_size, int(max(u16))))
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
		if int(admitted) < data_size {
			state.flags += {.Backpressured}
		}
		return admitted
	}

	copy_size := min(data_size, remaining)
	if copy_size > 0 {
		copy(response.connection.egress_buffer[cursor:], data[:copy_size])
		state.egress_size = Egress_Size(cursor + copy_size)
		state.body_size_sent += u64(copy_size)
	}
	if copy_size < data_size {
		state.flags += {.Backpressured}
	}
	return u16(copy_size)
}

@(require_results)
reserve_body_exact :: proc "contextless" (
	response: ^Response,
	body_size: u32,
) -> (
	reservation: Body_Reservation,
	result: Body_Reservation_Result,
) {
	state := _response_state(response)
	if body_size > u32(max(u16)) {
		return reservation, .Body_Too_Large
	}
	if state.body_policy != .Send {
		state.body_size_sent += u64(body_size)
		return reservation, .Suppressed
	}
	if state.mode == .Closed {
		return reservation, .Closed
	}
	if state.mode != .Chunked && state.mode != .Fixed_Length {
		return reservation, .Invalid_Mode
	}
	if state.mode == .Fixed_Length && state.body_size_sent + u64(body_size) > state.body_size_total {
		return reservation, .Body_Too_Large
	}

	cursor := int(state.egress_size)
	remaining := len(response.connection.egress_buffer) - cursor
	if remaining < 0 {
		return reservation, .Backpressured
	}

	body_size_u16 := u16(body_size)
	reservation.egress_size_before = state.egress_size
	reservation.body_size_sent_before = state.body_size_sent
	reservation.body_size_sent_commit = state.body_size_sent + u64(body_size)

	if state.mode == .Chunked {
		if body_size == 0 {
			reservation.egress_size_commit = state.egress_size
			return reservation, .Reserved
		}
		buffer_free := u16(len(response.connection.egress_buffer) - HTTP_CHUNKED_FRAMING_RESERVE)
		max_body_ever := admit_chunk_payload(buffer_free, buffer_free)
		if body_size_u16 > max_body_ever {
			return reservation, .Body_Too_Large
		}
		if remaining <= HTTP_CHUNKED_FRAMING_RESERVE {
			state.flags += {.Backpressured}
			return reservation, .Backpressured
		}
		free := u16(remaining - HTTP_CHUNKED_FRAMING_RESERVE)
		if admit_chunk_payload(free, body_size_u16) != body_size_u16 {
			state.flags += {.Backpressured}
			return reservation, .Backpressured
		}

		next_cursor, ok := _write_hex_u16(response.connection.egress_buffer[:], cursor, body_size_u16)
		if !ok do return reservation, .Backpressured
		next_cursor, ok = _write_bytes_into(
			response.connection.egress_buffer[:],
			next_cursor,
			transmute([]u8)string("\r\n"),
		)
		if !ok do return reservation, .Backpressured
		payload_begin := next_cursor
		next_cursor += int(body_size)
		if next_cursor > len(response.connection.egress_buffer) {
			return reservation, .Backpressured
		}
		next_cursor, ok = _write_bytes_into(
			response.connection.egress_buffer[:],
			next_cursor,
			transmute([]u8)string("\r\n"),
		)
		if !ok do return reservation, .Backpressured

		reservation.payload = response.connection.egress_buffer[payload_begin:][:int(body_size)]
		reservation.egress_size_commit = Egress_Size(next_cursor)
		return reservation, .Reserved
	}

	if int(body_size) > remaining {
		state.flags += {.Backpressured}
		return reservation, .Backpressured
	}
	reservation.payload = response.connection.egress_buffer[cursor:][:int(body_size)]
	reservation.egress_size_commit = Egress_Size(cursor + int(body_size))
	return reservation, .Reserved
}

@(require_results)
commit_body :: proc "contextless" (
	response: ^Response,
	reservation: Body_Reservation,
) -> Body_Commit_Result {
	state := _response_state(response)
	if state.egress_size != reservation.egress_size_before ||
	   state.body_size_sent != reservation.body_size_sent_before {
		return .Stale
	}
	state.egress_size = reservation.egress_size_commit
	state.body_size_sent = reservation.body_size_sent_commit
	return .Committed
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
	cursor := state.egress_size
	if int(cursor) + 5 > len(egress_buffer) {
		return false
	}
	copy(egress_buffer[cursor:], transmute([]u8)string("0\r\n\r\n"))
	state.egress_size = cursor + 5
	return true
}

@(private = "package")
_response_commit_headers :: proc(response: ^Response) -> bool {
	state := _response_state(response)
	if .Headers_Committed in state.flags {
		return true
	}

	size, ok := serialize_response_headers(
		response.connection.egress_buffer[:],
		state,
		response.connection.connection_state.response_header_bytes,
		_connection_date_value(response.connection),
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
_response_prepare_flush :: proc(response: ^Response, final: bool) -> bool {
	state := _response_state(response)
	if !_response_commit_headers(response) {
		return false
	}
	if .Fixed_Length_Body_Violation in state.flags {
		when tina.TINA_RUNTIME_ASSERTIONS {
			assert(false, "flush: fixed-length body size violates declared Content-Length")
		}
		return false
	}

	if final {
		if state.mode == .Fixed_Length && state.body_policy == .Send {
			fixed_length_complete := state.body_size_sent == state.body_size_total
			if !fixed_length_complete {
				state.flags += {.Aborted, .Close_After_Send, .Fixed_Length_Body_Violation}
				state.mode = .Closed
				when tina.TINA_RUNTIME_ASSERTIONS {
					assert(false, "flush(final): fixed-length body size must match declared Content-Length")
				}
				return false
			}
		}
		if state.mode == .Chunked {
			if !_response_append_chunked_terminator(state, response.connection.egress_buffer[:]) {
				state.flags += {.Aborted, .Close_After_Send}
				state.mode = .Closed
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
	source_handle: tina.Isolate_Handle,
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
	target_handle: tina.Isolate_Handle,
	$message_tag: tina.Message_Tag,
	payload_bytes: []u8,
	timeout_ns: u64,
) -> tina.Send_Result {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(timeout_ns > 0, "expect_reply: timeout_ns must be > 0")
	}
	correlation_id := tina.ctx_reserve_correlation_id()
	send_result := tina.ctx_send_with_correlation(
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
	source_handle: tina.Isolate_Handle = tina.ISOLATE_HANDLE_NONE,
	message_tag: Message_Tag = Message_Tag(0),
) -> Route_Step {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(timeout_ns > 0, "expect_notification: timeout_ns must be > 0")
	}
	correlation_id := tina.ctx_reserve_correlation_id()
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
_respond_bytes :: proc(
	response: ^Response,
	status_code: HTTP_Status,
	content_type: string,
	body: []u8,
) -> Route_Step {
	state := _response_state(response)
	if _response_prepare_begin(state) != .Begun {
		_response_stage_internal_server_error(response, state)
		return .Flush_Final
	}
	status(response, status_code)
	if state.body_policy == .Send {
		state.mode = .Fixed_Length
	}
	state.body_size_total = u64(len(body))
	state.body_size_sent = 0
	state.egress_size = Egress_Size(0)
	state.egress_size_sent = Egress_Size_Sent(0)
	_response_clear_sendfile_plan(response)
	if header_set(response, "Content-Type", content_type) != .Staged {
		_response_stage_internal_server_error(response, state)
		return .Flush_Final
	}

	if !_response_commit_headers(response) {
		return .Flush_Final
	}

	switch state.body_policy {
	case .Send:
		body_size := len(body)
		if int(state.egress_size) + body_size > len(response.connection.egress_buffer) {
			_response_stage_internal_server_error(response, state)
			return .Flush_Final
		}
		copy(response.connection.egress_buffer[state.egress_size:], body)
		state.egress_size = Egress_Size(int(state.egress_size) + body_size)
		state.body_size_sent = u64(body_size)
	case .Suppress_With_Length:
		state.body_size_sent = state.body_size_total
	case .Suppress_Without_Framing:
		state.body_size_total = 0
		state.body_size_sent = 0
	}
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
	response.flags = {.Headers_Committed}
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

	testing.expect_value(t, ok, Header_Result.Staged)
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
	testing.expect_value(t, ok, Header_Result.Staged)
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
test_response_header_set_reserved_names_are_not_staged :: proc(t: ^testing.T) {
	// Library-owned headers must not be staged. The result is explicit so
	// callers can distinguish safe no-op policy from storage exhaustion.
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
	ok_d := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("Date"),
		transmute([]u8)string("Wed, 01 May 2026 12:00:00 GMT"),
	)

	testing.expect_value(t, ok_a, Header_Result.Reserved_Name)
	testing.expect_value(t, ok_b, Header_Result.Reserved_Name)
	testing.expect_value(t, ok_c, Header_Result.Reserved_Name)
	testing.expect_value(t, ok_d, Header_Result.Reserved_Name)
	testing.expect_value(t, response.header_count, 0)
	testing.expect_value(t, response.header_bytes_used, u16(0))
}

@(test)
test_response_header_set_date_is_reserved :: proc(t: ^testing.T) {
	// Date is framework-owned, just like Connection, Content-Length, and
	// Transfer-Encoding. User attempts to stage it are rejected explicitly.
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	ok := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("date"),
		transmute([]u8)string("Wed, 01 May 2026 12:00:00 GMT"),
	)
	testing.expect_value(t, ok, Header_Result.Reserved_Name)
	testing.expect_value(t, response.header_count, 0)
	testing.expect_value(t, response.header_bytes_used, u16(0))
}

@(test)
test_response_header_set_rejects_invalid_name_bytes :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	result_space := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("X Trace"),
		transmute([]u8)string("abc"),
	)
	result_colon := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("X:Trace"),
		transmute([]u8)string("abc"),
	)
	result_crlf := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("X-Trace\r\nInjected"),
		transmute([]u8)string("abc"),
	)

	testing.expect_value(t, result_space, Header_Result.Invalid_Name)
	testing.expect_value(t, result_colon, Header_Result.Invalid_Name)
	testing.expect_value(t, result_crlf, Header_Result.Invalid_Name)
	testing.expect_value(t, response.header_count, 0)
	testing.expect_value(t, response.header_bytes_used, u16(0))
}

@(test)
test_response_header_set_rejects_invalid_value_bytes :: proc(t: ^testing.T) {
	response: Response_State
	response_state_reset(&response)
	region: [256]u8

	result_crlf := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("X-Trace"),
		transmute([]u8)string("abc\r\nInjected: yes"),
	)
	result_delete := response_header_set(
		&response,
		region[:],
		transmute([]u8)string("X-Trace"),
		[]u8{'a', 0x7F, 'b'},
	)

	testing.expect_value(t, result_crlf, Header_Result.Invalid_Value)
	testing.expect_value(t, result_delete, Header_Result.Invalid_Value)
	testing.expect_value(t, response.header_count, 0)
	testing.expect_value(t, response.header_bytes_used, u16(0))
}

@(test)
test_response_header_set_bytes_region_overflow :: proc(t: ^testing.T) {
	// Fill the bytes region until the next staging call must overflow. The
	// result is explicit and transactional so callers can map it to policy.
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
	testing.expect_value(t, ok, Header_Result.Staged)
	testing.expect_value(t, response.header_bytes_used, u16(10))

	// Adding another header with combined name+value > 6 bytes must fail.
	overflow_ok := response_header_add(
		&response,
		region[:],
		transmute([]u8)string("XXXXXX"),
		transmute([]u8)string("YYYY"),
	)
	testing.expect_value(t, overflow_ok, Header_Result.Header_Bytes_Exceeded)
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
		testing.expectf(t, ok == .Staged, "fill index %d should succeed", index)
	}
	testing.expect_value(t, int(response.header_count), HTTP_RESPONSE_HEADERS_MAX)

	overflow_ok := response_header_add(
		&response,
		region[:],
		transmute([]u8)string("Set-Cookie"),
		transmute([]u8)string("k=v"),
	)
	testing.expect_value(t, overflow_ok, Header_Result.Header_Count_Exceeded)
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
	testing.expect_value(t, ok, Header_Result.Already_Committed)
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
	response: Response_State
	response_state_reset(&response)
	response.mode = .Fixed_Length
	response.body_policy = .Suppress_With_Length
	response.body_size_total = 1234

	region: [64]u8
	destination: [HTTP_EGRESS_BUFFER_SIZE]u8

	size, ok := serialize_response_headers(destination[:], &response, region[:], nil)
	testing.expect(t, ok)
	head := string(destination[:size])
	testing.expect(t, strings.index(head, "\r\nContent-Length: 1234\r\n") >= 0)
}

@(test)
test_staged_header_survives_respond_text :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Staged_Header_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	staged_header_test_state := Staged_Header_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&staged_header_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Staged_Header_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			header_result := header_set(&response, "X-Trace", "abc")
			testing.expect_value(test_state.t, header_result, Header_Result.Staged)

			step := respond_text(&response, HTTP_STATUS_OK, "ok")
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)

			state := _response_state(&response)
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect(test_state.t, strings.index(wire, "\r\nX-Trace: abc\r\n") >= 0)
			testing.expect(test_state.t, strings.index(wire, "\r\nContent-Length: 2\r\n") >= 0)
		},
	)
}

@(test)
test_begin_stream_commits_headers_and_write_bytes_frames_chunk :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Begin_Stream_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	begin_stream_test_state := Begin_Stream_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&begin_stream_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Begin_Stream_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_stream(&response, HTTP_STATUS_OK, "text/plain")
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			state := _response_state(&response)
			testing.expect(test_state.t, .Headers_Committed in state.flags)
			head_size := state.egress_size
			testing.expect(test_state.t, head_size > 0)
			committed_head := string(test_state.fixture.connection.egress_buffer[:head_size])
			testing.expect(test_state.t, strings.index(committed_head, "\r\nTransfer-Encoding: chunked\r\n") >= 0)
			admitted := write_bytes(&response, transmute([]u8)string("hello"))
			testing.expect_value(test_state.t, admitted, u16(5))
			wire_chunk := string(test_state.fixture.connection.egress_buffer[head_size:state.egress_size])
			testing.expect_value(test_state.t, wire_chunk, "5\r\nhello\r\n")
		},
	)
}

@(test)
test_begin_fixed_stream_write_bytes_completes_exact_length :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Fixed_Stream_Exact_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	fixed_stream_exact_test_state := Fixed_Stream_Exact_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&fixed_stream_exact_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Fixed_Stream_Exact_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_fixed_stream(&response, HTTP_STATUS_OK, "text/plain", 5)
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			state := _response_state(&response)
			head_size := state.egress_size
			committed_head := string(test_state.fixture.connection.egress_buffer[:head_size])
			testing.expect(test_state.t, strings.index(committed_head, "\r\nContent-Length: 5\r\n") >= 0)

			accepted := write_bytes(&response, transmute([]u8)string("hello"))
			testing.expect_value(test_state.t, accepted, u16(5))
			ok := _response_prepare_flush(&response, true)
			testing.expect(test_state.t, ok)
			testing.expect_value(test_state.t, state.mode, Response_Mode.Closed)
			testing.expect_value(test_state.t, state.body_size_sent, u64(5))
			wire_body := string(test_state.fixture.connection.egress_buffer[head_size:state.egress_size])
			testing.expect_value(test_state.t, wire_body, "hello")
		},
	)
}

@(test)
test_fixed_stream_write_bytes_rejects_overflow_without_staging :: proc(t: ^testing.T) {
	when tina.TINA_RUNTIME_ASSERTIONS {
		_ = t
	} else {
		fixture: HTTP_Test_Fixture
		http_test_fixture_init(&fixture)
		Fixed_Stream_Overflow_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
		fixed_stream_overflow_test_state := Fixed_Stream_Overflow_Test_State {fixture = &fixture, t = t}
		tina.test_with_turn_frame(
			tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
			rawptr(&fixed_stream_overflow_test_state),
			proc(user_data: rawptr) {
				test_state := cast(^Fixed_Stream_Overflow_Test_State)user_data
				response := http_test_fixture_response(test_state.fixture)
				begin_result := begin_fixed_stream(&response, HTTP_STATUS_OK, "text/plain", 5)
				testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
				state := _response_state(&response)
				egress_size_before := state.egress_size
				body_size_sent_before := state.body_size_sent

				accepted := write_bytes(&response, transmute([]u8)string("excess"))
				testing.expect_value(test_state.t, accepted, u16(0))
				testing.expect_value(test_state.t, state.egress_size, egress_size_before)
				testing.expect_value(test_state.t, state.body_size_sent, body_size_sent_before)
				testing.expect(test_state.t, .Aborted in state.flags)
				testing.expect(test_state.t, .Close_After_Send in state.flags)
				testing.expect(test_state.t, .Fixed_Length_Body_Violation in state.flags)
				testing.expect_value(test_state.t, state.mode, Response_Mode.Closed)
				wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
				testing.expect(test_state.t, strings.index(wire, "excess") < 0)
			},
		)
	}
}

@(test)
test_fixed_stream_final_flush_rejects_underflow :: proc(t: ^testing.T) {
	when tina.TINA_RUNTIME_ASSERTIONS {
		_ = t
	} else {
		fixture: HTTP_Test_Fixture
		http_test_fixture_init(&fixture)
		Fixed_Stream_Underflow_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
		fixed_stream_underflow_test_state := Fixed_Stream_Underflow_Test_State {fixture = &fixture, t = t}
		tina.test_with_turn_frame(
			tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
			rawptr(&fixed_stream_underflow_test_state),
			proc(user_data: rawptr) {
				test_state := cast(^Fixed_Stream_Underflow_Test_State)user_data
				response := http_test_fixture_response(test_state.fixture)
				begin_result := begin_fixed_stream(&response, HTTP_STATUS_OK, "text/plain", 5)
				testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)

				accepted := write_bytes(&response, transmute([]u8)string("abc"))
				testing.expect_value(test_state.t, accepted, u16(3))
				state := _response_state(&response)
				ok := _response_prepare_flush(&response, true)
				testing.expect(test_state.t, !ok)
				testing.expect_value(test_state.t, state.body_size_sent, u64(3))
				testing.expect(test_state.t, .Aborted in state.flags)
				testing.expect(test_state.t, .Close_After_Send in state.flags)
				testing.expect(test_state.t, .Fixed_Length_Body_Violation in state.flags)
				testing.expect_value(test_state.t, state.mode, Response_Mode.Closed)
			},
		)
	}
}

@(test)
test_reserve_body_exact_commits_one_chunk :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Reserve_Body_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	reserve_body_test_state := Reserve_Body_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&reserve_body_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Reserve_Body_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_stream(&response, HTTP_STATUS_OK, "text/plain")
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			state := _response_state(&response)
			head_size := int(state.egress_size)

			reservation, reserve_result := reserve_body_exact(&response, 11)
			testing.expect_value(test_state.t, reserve_result, Body_Reservation_Result.Reserved)
			copy(reservation.payload, transmute([]u8)string("hello world"))
			commit_result := commit_body(&response, reservation)
			testing.expect_value(test_state.t, commit_result, Body_Commit_Result.Committed)

			wire_chunk := string(test_state.fixture.connection.egress_buffer[head_size:state.egress_size])
			testing.expect_value(test_state.t, wire_chunk, "b\r\nhello world\r\n")
			testing.expect_value(test_state.t, state.body_size_sent, u64(11))
		},
	)
}

@(test)
test_reserve_body_exact_oversized_chunk_is_body_too_large :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Reserve_Backpressure_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	reserve_backpressure_test_state := Reserve_Backpressure_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&reserve_backpressure_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Reserve_Backpressure_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_stream(&response, HTTP_STATUS_OK, "text/plain")
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			state := _response_state(&response)
			egress_size_before := state.egress_size
			body_size_sent_before := state.body_size_sent

			_, reserve_result := reserve_body_exact(&response, u32(HTTP_EGRESS_BUFFER_SIZE))
			testing.expect_value(test_state.t, reserve_result, Body_Reservation_Result.Body_Too_Large)
			testing.expect_value(test_state.t, state.egress_size, egress_size_before)
			testing.expect_value(test_state.t, state.body_size_sent, body_size_sent_before)
		},
	)
}

@(test)
test_response_prepare_flush_final_appends_chunked_terminator :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Prepare_Flush_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	prepare_flush_test_state := Prepare_Flush_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&prepare_flush_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Prepare_Flush_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_stream(&response, HTTP_STATUS_OK, "text/plain")
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			_ = write_bytes(&response, transmute([]u8)string("ab"))
			state := _response_state(&response)
			pre_flush_size := state.egress_size
			ok := _response_prepare_flush(&response, true)
			testing.expect(test_state.t, ok)
			testing.expect(test_state.t, state.mode == .Closed)
			testing.expect_value(
				test_state.t,
				string(test_state.fixture.connection.egress_buffer[pre_flush_size:state.egress_size]),
				"0\r\n\r\n",
			)
		},
	)
}

@(test)
test_head_suppressed_write_bytes_accepts_without_staging :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.request.method = .HEAD
	Head_Suppressed_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	head_suppressed_test_state := Head_Suppressed_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&head_suppressed_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Head_Suppressed_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_stream(&response, HTTP_STATUS_OK, "text/plain")
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			state := _response_state(&response)
			header_size := state.egress_size
			accepted := write_bytes(&response, transmute([]u8)string("payload"))
			testing.expect_value(test_state.t, accepted, u16(7))
			testing.expect_value(test_state.t, state.egress_size, header_size)
			testing.expect_value(test_state.t, state.body_size_sent, u64(7))
		},
	)
}

@(test)
test_respond_file_sets_sendfile_plan_and_returns_flush :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Respond_File_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	respond_file_test_state := Respond_File_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&respond_file_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Respond_File_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			step := respond_file(&response, tina.FD_Handle(42), 8192, "application/octet-stream")
			testing.expect_value(test_state.t, step, Route_Step.Flush)
			testing.expect_value(test_state.t, test_state.fixture.connection.connection_state.sendfile_file_fd, tina.FD_Handle(42))
			testing.expect_value(test_state.t, test_state.fixture.connection.connection_state.sendfile_offset, u64(0))
			testing.expect_value(test_state.t, test_state.fixture.connection.connection_state.sendfile_size_remaining, u64(8192))
			testing.expect_value(test_state.t, test_state.fixture.connection.connection_state.sendfile_active, true)
		},
	)
}

@(test)
test_100_continue_has_no_body_framing_headers :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Continue_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	continue_test_state := Continue_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&continue_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Continue_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			continue_100(&response)
			state := _response_state(&response)
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect(test_state.t, strings.index(wire, "HTTP/1.1 100 Continue\r\n") == 0)
			testing.expect(test_state.t, strings.index(wire, "Content-Length") < 0)
			testing.expect(test_state.t, strings.index(wire, "Transfer-Encoding") < 0)
			testing.expect(test_state.t, .Interim_100_Sent in state.flags)
		},
	)
}

@(test)
test_100_continue_reset_allows_final_response :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Continue_Final_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	continue_final_test_state := Continue_Final_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&continue_final_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Continue_Final_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			continue_100(&response)
			_response_prepare_next_message(&test_state.fixture.connection.connection_state.response)
			step := respond_text(&response, HTTP_STATUS_OK, "ok")
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
			state := _response_state(&response)
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect(test_state.t, strings.index(wire, "HTTP/1.1 200 OK\r\n") == 0)
			testing.expect(test_state.t, strings.index(wire, "Content-Length: 2\r\n") >= 0)
			testing.expect(test_state.t, .Interim_100_Sent in state.flags)
		},
	)
}

@(test)
test_204_response_has_no_body_framing_headers :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	No_Content_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	no_content_test_state := No_Content_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&no_content_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^No_Content_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			step := respond_text(&response, HTTP_STATUS_NO_CONTENT, "should-be-ignored")
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
			state := _response_state(&response)
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect(test_state.t, strings.index(wire, "HTTP/1.1 204 No Content\r\n") == 0)
			testing.expect(test_state.t, strings.index(wire, "Content-Length") < 0)
			testing.expect(test_state.t, strings.index(wire, "Transfer-Encoding") < 0)
			testing.expect_value(test_state.t, state.body_size_sent, u64(0))
		},
	)
}

@(test)
test_304_response_has_no_body_framing_headers :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Not_Modified_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	not_modified_test_state := Not_Modified_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&not_modified_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Not_Modified_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			step := respond_text(&response, HTTP_STATUS_NOT_MODIFIED, "should-be-ignored")
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
			state := _response_state(&response)
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect(test_state.t, strings.index(wire, "HTTP/1.1 304 Not Modified\r\n") == 0)
			testing.expect(test_state.t, strings.index(wire, "Content-Length") < 0)
			testing.expect(test_state.t, strings.index(wire, "Transfer-Encoding") < 0)
			testing.expect_value(test_state.t, state.body_size_sent, u64(0))
		},
	)
}

@(test)
test_head_response_emits_content_length_without_body :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	fixture.connection.connection_state.request.method = .HEAD
	Head_Response_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	head_response_test_state := Head_Response_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&head_response_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Head_Response_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			step := respond_text(&response, HTTP_STATUS_OK, "ok")
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
			state := _response_state(&response)
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect(test_state.t, strings.index(wire, "HTTP/1.1 200 OK\r\n") == 0)
			testing.expect(test_state.t, strings.index(wire, "Content-Length: 2\r\n") >= 0)
			testing.expect(test_state.t, strings.index(wire, "\r\n\r\nok") < 0)
			testing.expect_value(test_state.t, state.body_size_sent, u64(2))
		},
	)
}

@(test)
test_reserve_body_exact_backpressure_when_room_too_small :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)
	Reserve_Backpressure_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	reserve_backpressure_test_state := Reserve_Backpressure_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&reserve_backpressure_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Reserve_Backpressure_Test_State)user_data
			response := http_test_fixture_response(test_state.fixture)
			begin_result := begin_stream(&response, HTTP_STATUS_OK, "text/plain")
			testing.expect_value(test_state.t, begin_result, Response_Begin_Result.Begun)
			state := _response_state(&response)

			big_reserve, big_result := reserve_body_exact(&response, 3800)
			testing.expect_value(test_state.t, big_result, Body_Reservation_Result.Reserved)
			testing.expect_value(test_state.t, commit_body(&response, big_reserve), Body_Commit_Result.Committed)

			egress_size_before := state.egress_size
			body_size_sent_before := state.body_size_sent
			_, small_result := reserve_body_exact(&response, 200)
			testing.expect_value(test_state.t, small_result, Body_Reservation_Result.Backpressured)
			testing.expect_value(test_state.t, state.egress_size, egress_size_before)
			testing.expect_value(test_state.t, state.body_size_sent, body_size_sent_before)
		},
	)
}
