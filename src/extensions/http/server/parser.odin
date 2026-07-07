package http_server

import "core:bytes"
import "core:math/bits"
import "core:testing"
import tina "../../.."

@(private = "package")
Parse_Phase :: enum u8 {
	Request_Line,
	Headers,
	Body_Fixed,
	Chunk_Size,
	Chunk_Ext,
	Chunk_Data,
	Chunk_Data_CRLF,
	Trailers,
	Complete,
	Error,
}

@(private = "package")
Parser_Flag :: enum u8 {
	Has_Content_Length,
	Has_Transfer_Encoding,
	Chunked_Request,
	Connection_Close,
	Expect_100,
	Upgrade_Request,
	Head_Method,
	Keep_Alive_Allowed,
}

// 8 flags fit exactly in u8. A 9th flag is a deliberate decision that must
// bump the backing type to u16; the type advertises remaining capacity.
@(private = "package")
Parser_Flags :: distinct bit_set[Parser_Flag;u8]

// ─── 256-Bit Validation Tables ──────────────────────────────────
//
// These are 256-bit lookup tables stored as [4]u64 (because no u256 for bit_set in Odin)
//
// Bit mapping:
//   - bit index = ASCII value (0–255)
//   - word index = tina.bitmap_word_index_from_bit_index(c)
//   - bit index  = tina.bitmap_word_bit_index_from_bit_index(c) (LSB = lower ASCII values)
//
// Example:
//   'A' (65) → table[1] bit 1
//   'a' (97) → table[1] bit 33
//
// Important:
//   These tables are derived from RFC rules.
//   Use verify_all_tables() in debug builds to ensure correctness.
@(private = "package")
Table_256 :: distinct [4]u64

// Pre-calculated RFC bitmasks
// These represent exact 256-bit sets mathematically derived from HTTP RFCs.
//
// Char tables are intentionally `@(private = "file", rodata)` per the ADR
// allowance (HTTP_LIBRARY_DESIGN.md §2)
// Validation reaches them via package-private `is_*_byte` accessors below.

@(private = "file", rodata)
CHARS_HTTP_TOKEN := Table_256 {
	0x03FF6CFA00000000,
	0x57FFFFFFC7FFFFFE,
	0x0000000000000000,
	0x0000000000000000,
}

@(private = "file", rodata)
CHARS_URI := Table_256 {
	0xAFFFFFF200000000,
	0x47FFFFFE87FFFFFF,
	0x0000000000000000,
	0x0000000000000000,
}

@(private = "file", rodata)
CHARS_HEADER_VALUE := Table_256 {
	0xFFFFFFFF00000200, // HTAB (bit 9), SP (bit 32), VCHAR (bits 33-63)
	0x7FFFFFFFFFFFFFFF, // VCHAR (bits 64-126), DEL (bit 127) excluded
	0x0000000000000000, // obs-text (0x80-0xBF) rejected
	0x0000000000000000, // obs-text (0xC0-0xFF) rejected
}

@(private = "file", rodata)
CHARS_DIGIT_HEX := Table_256 {
	0x03FF000000000000, // '0'-'9'
	0x0000007E0000007E, // 'A'-'F' and 'a'-'f'
	0x0000000000000000,
	0x0000000000000000,
}

@(private = "file", rodata)
CHARS_DIGIT_DECIMAL := Table_256 {
	0x03FF000000000000, // '0'-'9'
	0x0000000000000000,
	0x0000000000000000,
	0x0000000000000000,
}

// ─── Validation Helpers ──────────────────────────────────────────────
//
// They map the u8 to the exact bit in the 256-bit set.

@(private = "package")
is_token_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	bit_index := u32(byte_value)
	#no_bounds_check return (
		CHARS_HTTP_TOKEN[tina.bitmap_word_index_from_bit_index(bit_index)] &
		tina.bitmap_mask_from_bit_index(bit_index)
	) != 0
}

@(private = "package")
is_uri_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	bit_index := u32(byte_value)
	#no_bounds_check return (
		CHARS_URI[tina.bitmap_word_index_from_bit_index(bit_index)] &
		tina.bitmap_mask_from_bit_index(bit_index)
	) != 0
}

@(private = "package")
is_header_value_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	bit_index := u32(byte_value)
	#no_bounds_check return (
		CHARS_HEADER_VALUE[tina.bitmap_word_index_from_bit_index(bit_index)] &
		tina.bitmap_mask_from_bit_index(bit_index)
	) != 0
}

@(private = "package")
is_hex_digit_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	bit_index := u32(byte_value)
	#no_bounds_check return (
		CHARS_DIGIT_HEX[tina.bitmap_word_index_from_bit_index(bit_index)] &
		tina.bitmap_mask_from_bit_index(bit_index)
	) != 0
}

@(private = "package")
is_decimal_digit_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	bit_index := u32(byte_value)
	#no_bounds_check return (
		CHARS_DIGIT_DECIMAL[tina.bitmap_word_index_from_bit_index(bit_index)] &
		tina.bitmap_mask_from_bit_index(bit_index)
	) != 0
}

// Validates that every byte in the slice is a valid HTTP token character.
// Returns false on empty input (a zero-length token violates RFC 9110 §5.6.2).
@(private = "package")
validate_token_bytes :: proc "contextless" (bytes_array: []u8) -> bool {
	if len(bytes_array) == 0 do return false
	for byte_value in bytes_array {
		if !is_token_byte(byte_value) do return false
	}
	return true
}

// ─── Integer Decoders ──────────────────────────────────────────────────

// Parses a base-10 unsigned size value. Rejects empty input, non-digit bytes,
// and values that do not fit in a u64.
@(private = "package")
parse_decimal_size :: proc "contextless" (decimal_bytes: []u8) -> (u64, bool) {
	if len(decimal_bytes) == 0 do return 0, false
	if len(decimal_bytes) > 20 do return 0, false

	parsed_size: u64 = 0

	// The largest 19-digit decimal (9_999_999_999_999_999_999) fits in u64,
	// so the common path needs no overflow checks.
	if len(decimal_bytes) < 20 {
		for character in decimal_bytes {
			digit := character - '0'
			if digit > 9 do return 0, false
			parsed_size = (parsed_size * 10) + u64(digit)
		}
		return parsed_size, true
	}

	// Exactly 20 digits can overflow; parse the first 19 unchecked, then check
	// the final digit with carry-aware arithmetic.
	#no_bounds_check first_nineteen := decimal_bytes[:19]
	for character in first_nineteen {
		digit := character - '0'
		if digit > 9 do return 0, false
		parsed_size = (parsed_size * 10) + u64(digit)
	}

	#no_bounds_check last_character := decimal_bytes[19]
	last_digit := last_character - '0'
	if last_digit > 9 do return 0, false

	product_hi, product_lo := bits.mul_u64(parsed_size, 10)
	if product_hi != 0 do return 0, false

	sum, carry := bits.add_u64(product_lo, u64(last_digit), 0)
	if carry != 0 do return 0, false

	return sum, true
}

// Hexadecimal digit to integer conversion.
// Precondition: character is a validated hex byte (0-9, A-F, a-f).
@(private = "package")
hex_digit_value :: #force_inline proc "contextless" (character: u8) -> u64 {
	return u64(character & 0x0F) + u64((character >> 6) & 1) * 9
}

// Parses a base-16 chunk size.
// Precondition: hex_bytes must contain ONLY validated hex characters.
@(private = "package")
parse_hexadecimal_size :: proc "contextless" (hex_bytes: []u8) -> (u64, bool) {
	if len(hex_bytes) == 0 do return 0, false

	parsed_size: u64 = 0
	for character in hex_bytes {
		// Overflow guard: if any of the top 4 bits are set,
		// the next left-shift by 4 will overflow u64.
		if (parsed_size >> 60) != 0 do return 0, false
		parsed_size = (parsed_size << 4) | hex_digit_value(character)
	}

	return parsed_size, true
}

@(private = "package")
find_newline_offset :: proc "contextless" (
	buffer_bytes: []u8,
	parsed_size_current: u16,
	size_maximum: u16,
) -> (
	offset: int,
	limit_exceeded: bool,
) {
	remaining_size_allowed := int(size_maximum - parsed_size_current)
	scan_size := min(len(buffer_bytes), remaining_size_allowed)

	// bytes.index_byte leverages SIMD vectorization automatically
	#no_bounds_check newline_offset := bytes.index_byte(buffer_bytes[:scan_size], '\r')

	// If no newline is found AND we hit our strict size maximum, the client
	// is violating limits. Connection must be dropped.
	if newline_offset < 0 && len(buffer_bytes) >= remaining_size_allowed {
		return -1, true
	}

	return newline_offset, false
}


// Mutable per-request parser cursor. Lives inside HTTP_Connection_State and is
// reset between requests on a keep-alive connection.
@(private = "package")
Parser_State :: struct {
	body_size_remaining:  u64, // Content-Length remaining; tracked from header parse onward
	chunk_size_remaining: u64, // bytes left inside the current chunk's data section
	chunk_size_parsed:    u64, // partial hex value while accumulating a chunk size line
	header_size:          u16, // total header bytes consumed (incl. CRLFs); bounded by Parse_Budget.header_size_max
	request_line_size:    u16, // size of the request line (incl. trailing CRLF)
	header_count:            u8, // number of headers parsed so far
	chunk_size_digit_count: u8,
	flags:                   Parser_Flags,
	phase:                   Parse_Phase,
}

// Initializes the parser to its pre-request baseline.
// Called by the connection state machine on accept and
// after each completed request frame on a keep-alive connection.
@(private = "package")
parser_state_reset :: #force_inline proc "contextless" (state: ^Parser_State) {
	state^ = Parser_State{}
}

// Result returned to the connection state machine after each parse_step call.
// Error variants encode the wire-protocol HTTP status code that the library
// must respond with (then close the connection). The error → status mapping is
// the source of truth — see HTTP_LIBRARY_REQUEST_PARSING.md §4.
@(private = "package")
Parse_Status :: enum u8 {
	// `Continue` is an internal sentinel emitted by per-line helpers to signal
	// that forward progress was made and the parse loop should keep going. It
	// is filtered out by parse_step and never escapes the parser boundary.
	Continue,
	Need_More, // not enough buffered bytes to make progress; preserve state and resume
	Headers_Done, // request line + all headers parsed and validated
	Error_Bad_Request, // 400 — malformed request, smuggling guard tripped
	Error_Expectation, // 417 — Expect header carries something other than 100-continue
	Error_Header_Too_Large, // 431 — request line OR cumulative headers exceeded the limit
	Error_Not_Implemented, // 501 — unsupported transfer-coding (e.g. anything other than `chunked`)
	Error_Version, // 505 — version other than HTTP/1.1
}


// ─── Comparison Helpers ──────────────────────────────────────────────

// Case-sensitive byte slice vs. literal string equality.
@(private = "package")
equal_bytes :: #force_inline proc "contextless" (lhs: []u8, rhs: string) -> bool {
	if len(lhs) != len(rhs) do return false
	rhs_bytes := transmute([]u8)rhs
	#no_bounds_check for index in 0 ..< len(lhs) {
		if lhs[index] != rhs_bytes[index] do return false
	}
	return true
}

// ASCII case-insensitive equality (folds A..Z only — see Parser Notes §1).
// PRECONDITION: `rhs_lowercase` MUST be a fully lowercase ASCII string —
// typically a compile-time literal.
@(private = "package")
equal_bytes_ci_with_rhs_lowercase :: #force_inline proc "contextless" (
	lhs: []u8,
	rhs_lowercase: string,
) -> bool {
	if len(lhs) != len(rhs_lowercase) do return false
	rhs_bytes := transmute([]u8)rhs_lowercase
	#no_bounds_check for index in 0 ..< len(lhs) {
		if fold_ascii_upper_to_lower(lhs[index]) != rhs_bytes[index] do return false
	}
	return true
}

// Length-dispatched compare against the closed set of methods exposed by
// `Method`. Method names are case-sensitive per RFC 9110 §9. Unknown but
// otherwise valid token methods are reported with `known = false` so the
// router can return 405 / 501 in a later phase.
@(private = "package")
classify_method :: #force_inline proc "contextless" (
	method_bytes: []u8,
) -> (
	method: Method,
	known: bool,
) {
	switch len(method_bytes) {
	case 3:
		if equal_bytes(method_bytes, "GET") do return .GET, true
		if equal_bytes(method_bytes, "PUT") do return .PUT, true
	case 4:
		if equal_bytes(method_bytes, "POST") do return .POST, true
		if equal_bytes(method_bytes, "HEAD") do return .HEAD, true
	case 5:
		if equal_bytes(method_bytes, "PATCH") do return .PATCH, true
		if equal_bytes(method_bytes, "TRACE") do return .TRACE, true
	case 6:
		if equal_bytes(method_bytes, "DELETE") do return .DELETE, true
	case 7:
		if equal_bytes(method_bytes, "OPTIONS") do return .OPTIONS, true
	}
	return .GET, false
}

// Length-dispatched case-insensitive match against the closed `Known_Header`
// set. Only headers with semantic meaning to the parser/router are tracked
// here; arbitrary headers are stored in the bloom filter for negative lookup
// and confirmed later by `length + ci-compare` on the raw slice.
@(private = "package")
classify_known_header :: #force_inline proc "contextless" (
	name_bytes: []u8,
) -> (
	header: Known_Header,
	known: bool,
) {
	switch len(name_bytes) {
	case 4:
		if equal_bytes_ci_with_rhs_lowercase(name_bytes, "host") do return .Host, true
	case 6:
		if equal_bytes_ci_with_rhs_lowercase(name_bytes, "expect") do return .Expect, true
	case 7:
		if equal_bytes_ci_with_rhs_lowercase(name_bytes, "upgrade") do return .Upgrade, true
	case 10:
		if equal_bytes_ci_with_rhs_lowercase(name_bytes, "connection") do return .Connection, true
	case 14:
		if equal_bytes_ci_with_rhs_lowercase(name_bytes, "content-length") do return .Content_Length, true
	case 17:
		if equal_bytes_ci_with_rhs_lowercase(name_bytes, "transfer-encoding") do return .Transfer_Encoding, true
	}
	return .Host, false
}

// `Connection: close, keep-alive, upgrade` is a comma-separated token list
// with optional surrounding whitespace. Per RFC 9110 §7.6.1 we walk tokens,
// case-insensitively matching the small set we care about.
@(private = "package")
parse_connection_tokens :: #force_inline proc "contextless" (
	state: ^Parser_State,
	value_bytes: []u8,
) {
	cursor := 0
	for cursor < len(value_bytes) {
		// Skip leading OWS and commas.
		for cursor < len(value_bytes) {
			#no_bounds_check byte_value := value_bytes[cursor]
			if byte_value != ' ' && byte_value != '\t' && byte_value != ',' do break
			cursor += 1
		}
		if cursor >= len(value_bytes) do break

		token_start := cursor
		for cursor < len(value_bytes) {
			#no_bounds_check byte_value := value_bytes[cursor]
			if byte_value == ',' || byte_value == ' ' || byte_value == '\t' do break
			cursor += 1
		}
		token := value_bytes[token_start:cursor]

		switch {
		case equal_bytes_ci_with_rhs_lowercase(token, "close"):
			state.flags += {.Connection_Close}
		case equal_bytes_ci_with_rhs_lowercase(token, "upgrade"):
			state.flags += {.Upgrade_Request}
		case equal_bytes_ci_with_rhs_lowercase(token, "keep-alive"):
			state.flags += {.Keep_Alive_Allowed}
		}
	}
}

// Strict RFC 9112 §3 request-line: METHOD SP request-target SP HTTP-version CRLF.
// Exactly one SP between parts, no HTAB, no leading blank lines. v1 supports
// origin-form (`/path?query`) and asterisk-form (`*` for OPTIONS only).
// On success the parser advances `parsed_offset` past the CRLF and the caller
// transitions to the Headers phase.
@(private = "package")
parse_request_line :: #force_inline proc "contextless" (
	state: ^Parser_State,
	request: ^Request_State,
	buffer: []u8,
	parsed_offset: u16,
	budget: Parse_Budget,
) -> (
	Parse_Status,
	u16,
) {
	if len(buffer) <= int(parsed_offset) {
		return .Need_More, parsed_offset
	}

	view := buffer[parsed_offset:]

	// Reject leading blank lines (RFC 9112 §2.2 RECOMMENDS ignore; we strictly
	// reject to harden against parser-desync smuggling vectors).
	#no_bounds_check if view[0] == '\r' || view[0] == '\n' {
		return .Error_Bad_Request, parsed_offset
	}

	cr_offset, limit_exceeded := find_newline_offset(view, 0, budget.request_line_size_max)
	if limit_exceeded {
		// A request line that exceeds the configured cap is treated as a
		// malformed request rather than 414 — request-target overrun is
		// indistinguishable from missing CRLF at the parser boundary.
		return .Error_Bad_Request, parsed_offset
	}
	if cr_offset < 0 {
		return .Need_More, parsed_offset
	}
	if cr_offset + 1 >= len(view) {
		return .Need_More, parsed_offset // saw '\r', waiting for '\n'
	}
	#no_bounds_check if view[cr_offset + 1] != '\n' {
		return .Error_Bad_Request, parsed_offset // bare CR without LF — smuggling vector
	}

	line := view[:cr_offset]

	// Reject HTAB anywhere in the request line — only SP is permitted.
	for byte_value in line {
		if byte_value == '\t' do return .Error_Bad_Request, parsed_offset
	}

	first_space := index_byte_in(line, ' ')
	if first_space < 0 do return .Error_Bad_Request, parsed_offset
	#no_bounds_check method_bytes := line[:first_space]

	#no_bounds_check rest_after_method := line[first_space + 1:]
	second_space := index_byte_in(rest_after_method, ' ')
	if second_space < 0 do return .Error_Bad_Request, parsed_offset
	#no_bounds_check target_bytes := rest_after_method[:second_space]
	#no_bounds_check version_bytes := rest_after_method[second_space + 1:]

	if !validate_token_bytes(method_bytes) do return .Error_Bad_Request, parsed_offset

	// Version must be exactly "HTTP/1.1". Anything else (HTTP/1.0, HTTP/2.0,
	// junk) is a 505 — the connection is unusable for the requested version.
	if !equal_bytes(version_bytes, "HTTP/1.1") do return .Error_Version, parsed_offset

	if len(target_bytes) == 0 do return .Error_Bad_Request, parsed_offset
	for byte_value in target_bytes {
		if !is_uri_byte(byte_value) do return .Error_Bad_Request, parsed_offset
	}

	// Method classification — accept any token but flag unknown for the router.
	method, method_known := classify_method(method_bytes)
	request.method = method
	if !method_known do request.status_flags += {.Unknown_Method}
	if method == .HEAD do state.flags += {.Head_Method}

	target_offset_in_frame := parsed_offset + u16(first_space) + 1

	#no_bounds_check is_asterisk := len(target_bytes) == 1 && target_bytes[0] == '*'
	if is_asterisk {
		// asterisk-form is only valid for OPTIONS. Any other method gets
		// 400 + close (DR-10). Path/query are degenerate; record `*` as both.
		if method != .OPTIONS do return .Error_Bad_Request, parsed_offset
		request.status_flags += {.Options_Asterisk}
		request.target_offset = target_offset_in_frame
		request.target_size = 1
		request.path_offset = target_offset_in_frame
		request.path_size = 1
		request.query_offset = 0
		request.query_size = 0
	} else {
		#no_bounds_check if target_bytes[0] != '/' {
			// absolute-form (`http://...`) and authority-form (CONNECT) rejected.
			return .Error_Bad_Request, parsed_offset
		}
		request.target_offset = target_offset_in_frame
		request.target_size = u16(len(target_bytes))

		query_marker := index_byte_in(target_bytes, '?')
		if query_marker < 0 {
			request.path_offset = target_offset_in_frame
			request.path_size = u16(len(target_bytes))
			request.query_offset = 0
			request.query_size = 0
		} else {
			request.path_offset = target_offset_in_frame
			request.path_size = u16(query_marker)
			request.query_offset = target_offset_in_frame + u16(query_marker) + 1
			request.query_size = u16(len(target_bytes) - query_marker - 1)
		}
	}

	line_total := u16(cr_offset) + 2 // bytes consumed including CRLF
	state.request_line_size = line_total

	return .Continue, parsed_offset + line_total
}

// Parses one `Field-Name: field-value CRLF` line at `parsed_offset`. The empty
// CRLF terminator is recognized as `.Headers_Done` and consumed. Smuggling
// guardrails (duplicate Host, dual Content-Length, CL+TE coexistence,
// non-`chunked` transfer-codings, bad Expect) all surface as wire-status
// errors here, not later.
@(private = "package")
parse_one_header :: proc "contextless" (
	state: ^Parser_State,
	request: ^Request_State,
	headers: []Header_View,
	buffer: []u8,
	parsed_offset: u16,
	budget: Parse_Budget,
) -> (
	Parse_Status,
	u16,
) {
	if len(buffer) <= int(parsed_offset) {
		return .Need_More, parsed_offset
	}

	view := buffer[parsed_offset:]

	// Empty line ⇒ end of header section.
	#no_bounds_check if len(view) >= 2 && view[0] == '\r' && view[1] == '\n' {
		return .Headers_Done, parsed_offset + 2
	}
	#no_bounds_check if len(view) == 1 && view[0] == '\r' {
		return .Need_More, parsed_offset // need to see the '\n' to know whether headers end here
	}

	// Header lines must begin with a token byte. obs-fold (a continuation
	// line beginning with SP/HTAB) is unconditionally rejected per RFC 9112
	// §5.2 to neutralize smuggling via line-folding ambiguity.
	#no_bounds_check if view[0] == ' ' || view[0] == '\t' do return .Error_Bad_Request, parsed_offset

	remaining_budget := budget.header_size_max - state.header_size
	cr_offset, limit_exceeded := find_newline_offset(view, 0, remaining_budget)
	if limit_exceeded do return .Error_Header_Too_Large, parsed_offset
	if cr_offset < 0 do return .Need_More, parsed_offset
	if cr_offset + 1 >= len(view) do return .Need_More, parsed_offset
	#no_bounds_check if view[cr_offset + 1] != '\n' do return .Error_Bad_Request, parsed_offset
	if cr_offset == 0 do return .Error_Bad_Request, parsed_offset // protocol-impossible: empty is handled above

	line := view[:cr_offset]

	// Bound header_count before we touch any storage.
	if int(state.header_count) >= int(budget.header_count_max) ||
	   int(state.header_count) >= len(headers) {
		return .Error_Header_Too_Large, parsed_offset
	}

	colon_index := index_byte_in(line, ':')
	if colon_index <= 0 do return .Error_Bad_Request, parsed_offset

	#no_bounds_check name_bytes := line[:colon_index]

	// validate_and_hash_header_name catches:
	//   - empty names
	//   - any byte outside CHARS_HTTP_TOKEN (CTL, SP, HTAB, delimiters, high
	//     bytes) — including the "whitespace before colon" smuggling vector.
	hash, name_valid := validate_and_hash_header_name(name_bytes)
	if !name_valid do return .Error_Bad_Request, parsed_offset

	// Trim OWS surrounding the value (RFC 9110 §5.5).
	value_start := colon_index + 1
	#no_bounds_check for value_start < len(line) && (line[value_start] == ' ' || line[value_start] == '\t') {
		value_start += 1
	}
	value_end := len(line)
	#no_bounds_check for value_end > value_start && (line[value_end - 1] == ' ' || line[value_end - 1] == '\t') {
		value_end -= 1
	}
	#no_bounds_check value_bytes := line[value_start:value_end]

	for byte_value in value_bytes {
		if !is_header_value_byte(byte_value) do return .Error_Bad_Request, parsed_offset
	}

	// Frame-relative offsets — preserved verbatim if the bytes are later
	// promoted from reactor buffer to Working Memory (DR-3, I3).
	#no_bounds_check headers[state.header_count] = Header_View {
		name_offset  = parsed_offset,
		value_offset = parsed_offset + u16(value_start),
		hash         = hash,
		name_size    = u16(len(name_bytes)),
		value_size   = u16(len(value_bytes)),
	}

	known_header, is_known := classify_known_header(name_bytes)
	if is_known {
		switch known_header {
		case .Host:
			if .Host in request.known_headers do return .Error_Bad_Request, parsed_offset
		case .Content_Length:
			if .Has_Content_Length in state.flags do return .Error_Bad_Request, parsed_offset
			if .Has_Transfer_Encoding in state.flags do return .Error_Bad_Request, parsed_offset
			content_length, parsed_ok := parse_decimal_size(value_bytes)
			if !parsed_ok do return .Error_Bad_Request, parsed_offset
			state.body_size_remaining = content_length
			state.flags += {.Has_Content_Length}
		case .Transfer_Encoding:
			if .Has_Transfer_Encoding in state.flags do return .Error_Bad_Request, parsed_offset
			if .Has_Content_Length in state.flags do return .Error_Bad_Request, parsed_offset
			// v1 accepts only the single token `chunked`. Any list (e.g.
			// "gzip, chunked") or unknown coding is 501 + close.
			if !equal_bytes_ci_with_rhs_lowercase(value_bytes, "chunked") do return .Error_Not_Implemented, parsed_offset
			state.flags += {.Has_Transfer_Encoding, .Chunked_Request}
		case .Connection:
			parse_connection_tokens(state, value_bytes)
		case .Expect:
			if !equal_bytes_ci_with_rhs_lowercase(value_bytes, "100-continue") do return .Error_Expectation, parsed_offset
			state.flags += {.Expect_100}
		case .Upgrade:
			state.flags += {.Upgrade_Request}
		}
		request.known_headers += {known_header}
	} else {
		// Bloom is populated for arbitrary headers only; known headers go
		// through the exact `Known_Header_Mask` check, which has zero false
		// positives.
		request.header_bloom = bloom_set(request.header_bloom, hash)
	}

	line_total := u16(cr_offset) + 2
	state.header_size += line_total
	state.header_count += 1
	request.header_count = state.header_count

	return .Continue, parsed_offset + line_total
}

// Called once header parsing completes. Sets `state.phase` to the appropriate
// body-mode entry phase. Body parsing itself is owned by `body.odin`
// and reads `state.body_size_remaining` / `Chunked_Request` to drive its loop.
@(private = "package")
determine_body_framing :: #force_inline proc "contextless" (state: ^Parser_State) {
	if .Chunked_Request in state.flags {
		state.phase = .Chunk_Size
		return
	}
	if .Has_Content_Length in state.flags && state.body_size_remaining > 0 {
		state.phase = .Body_Fixed
		return
	}
	state.phase = .Complete
}


// ─── Top-Level Parse Step ──────────────────────────────────────────────────
//
// Drives the parser to forward progress on the supplied buffer slice. The
// caller (Connection state machine) accumulates ingress bytes in a contiguous
// region (reactor buffer or Working Memory split-packet carry) and calls
// parse_step whenever new bytes arrive. parse_step returns:
//
//   - `Need_More`     — more bytes required; parser state preserved.
//   - `Headers_Done`  — request line + headers fully parsed; body framing set.
//   - `Error_*`       — protocol violation; caller serializes the matching
//                       HTTP status response and closes the connection.
//
// `parsed_offset` is updated in place to point at the first unconsumed byte.

@(private = "package")
parse_step :: #force_inline proc "contextless" (
	state: ^Parser_State,
	request: ^Request_State,
	headers: []Header_View,
	buffer: []u8,
	parsed_offset: u16,
	budget: Parse_Budget,
) -> (
	Parse_Status,
	u16,
) {
	current_offset := parsed_offset
	for {
		switch state.phase {
		case .Request_Line:
			result, new_offset := parse_request_line(
				state,
				request,
				buffer,
				current_offset,
				budget,
			)
			current_offset = new_offset
			#partial switch result {
			case .Continue:
				state.phase = .Headers
			case .Need_More:
				return .Need_More, current_offset
			case:
				state.phase = .Error
				return result, current_offset
			}

		case .Headers:
			for {
				result, new_offset := parse_one_header(
					state,
					request,
					headers,
					buffer,
					current_offset,
					budget,
				)
				current_offset = new_offset
				#partial switch result {
				case .Continue:
					continue // Loop and parse the next header line without hitting the outer switch
				case .Need_More:
					return .Need_More, current_offset
				case .Headers_Done:
					// Mandatory-header validation gate: HTTP/1.1 requires Host.
					// (Duplicate Host was already caught inline by parse_one_header.)
					if .Host not_in request.known_headers {
						state.phase = .Error
						return .Error_Bad_Request, current_offset
					}
					determine_body_framing(state)
					return .Headers_Done, current_offset
				case:
					state.phase = .Error
					return result, current_offset
				}
			}

		case .Body_Fixed, .Chunk_Size, .Chunk_Ext, .Chunk_Data, .Chunk_Data_CRLF, .Trailers, .Complete:
			// Body phases are owned by body.odin (Phase 3). For Phase 2,
			// returning Need_More keeps parse_step idempotent if a caller
			// re-enters after Headers_Done without owning body parsing.
			return .Need_More, current_offset

		case .Error:
			return .Error_Bad_Request, current_offset
		}
	}
}


// ─── Local Helpers ─────────────────────────────────────────────────────────

// Forwarded `bytes.index_byte` — kept thin and inlinable so the hot parser
// loops do not pay a function-call overhead for each delimiter scan.
@(private = "file")
index_byte_in :: #force_inline proc "contextless" (slice: []u8, target: u8) -> int {
	return bytes.index_byte(slice, target)
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_token_chars_accept_valid :: proc(t: ^testing.T) {
	valid_bytes := [?]u8 {
		'!',
		'#',
		'$',
		'%',
		'&',
		'\'',
		'*',
		'+',
		'-',
		'.',
		'^',
		'_',
		'`',
		'|',
		'~',
		'0',
		'1',
		'9',
		'A',
		'Z',
		'a',
		'z',
	}
	for byte_value in valid_bytes {
		testing.expectf(
			t,
			is_token_byte(byte_value),
			"tchar 0x%02X should be accepted",
			byte_value,
		)
	}
}

@(test)
test_token_chars_reject_invalid :: proc(t: ^testing.T) {
	invalid_bytes := [?]u8 {
		0x00,
		0x09,
		0x0A,
		0x0D,
		0x20,
		'(',
		')',
		'<',
		'>',
		'@',
		',',
		';',
		':',
		'\\',
		'"',
		'/',
		'[',
		']',
		'?',
		'=',
		'{',
		'}',
		0x7F,
		0x80,
		0xFF,
	}
	for byte_value in invalid_bytes {
		testing.expectf(
			t,
			!is_token_byte(byte_value),
			"byte 0x%02X should be rejected by CHARS_HTTP_TOKEN",
			byte_value,
		)
	}
}

@(test)
test_header_value_chars_accept_visible_ascii :: proc(t: ^testing.T) {
	// HTAB, SP, and VCHAR (0x21..0x7E) are the only accepted bytes per
	// HTTP_LIBRARY_REQUEST_PARSING.md §3.2.
	testing.expect(t, is_header_value_byte(0x09), "HTAB accepted")
	testing.expect(t, is_header_value_byte(0x20), "SP accepted")
	testing.expect(t, is_header_value_byte(0x21), "VCHAR lower bound 0x21 accepted")
	testing.expect(t, is_header_value_byte(0x41), "ASCII 'A' accepted")
	testing.expect(t, is_header_value_byte(0x7E), "VCHAR upper bound 0x7E accepted")
}

@(test)
test_header_value_chars_reject_obs_text :: proc(t: ^testing.T) {
	// obs-text (0x80..0xFF) must be REJECTED at the parser boundary to
	// close downstream-truncation smuggling vectors against C-based proxies,
	// CGI processes, and log parsers.
	invalid_high_bytes := [?]u8{0x80, 0x95, 0xAA, 0xC0, 0xFE, 0xFF}
	for byte_value in invalid_high_bytes {
		testing.expectf(
			t,
			!is_header_value_byte(byte_value),
			"obs-text byte 0x%02X must be rejected",
			byte_value,
		)
	}
}

@(test)
test_header_value_chars_reject_ctl :: proc(t: ^testing.T) {
	// NUL, internal CTL characters (0x00..0x08, 0x0A..0x1F), and DEL (0x7F)
	// MUST be rejected.
	invalid_bytes := [?]u8{0x00, 0x01, 0x08, 0x0A, 0x0D, 0x1F, 0x7F}
	for byte_value in invalid_bytes {
		testing.expectf(
			t,
			!is_header_value_byte(byte_value),
			"CTL byte 0x%02X must be rejected",
			byte_value,
		)
	}
}

@(test)
test_decimal_size_parsing :: proc(t: ^testing.T) {
	parsed_size: u64
	success: bool

	parsed_size, success = parse_decimal_size(transmute([]u8)string("0"))
	testing.expect(t, success && parsed_size == 0)

	parsed_size, success = parse_decimal_size(transmute([]u8)string("4096"))
	testing.expect(t, success && parsed_size == 4096)

	// Largest 19-digit number fits comfortably in u64.
	parsed_size, success = parse_decimal_size(transmute([]u8)string("9999999999999999999"))
	testing.expect(t, success && parsed_size == 9_999_999_999_999_999_999)

	// Maximum u64 value is a 20-digit decimal and must parse exactly.
	parsed_size, success = parse_decimal_size(transmute([]u8)string("18446744073709551615"))
	testing.expect(t, success && parsed_size == max(u64), "max(u64) decimal must parse exactly")

	// One past max(u64) must overflow and be rejected.
	_, success = parse_decimal_size(transmute([]u8)string("18446744073709551616"))
	testing.expect(t, !success, "max(u64) + 1 decimal must overflow")

	// More than 20 digits can never fit in u64.
	_, success = parse_decimal_size(transmute([]u8)string("100000000000000000000"))
	testing.expect(t, !success, "21-digit decimal must be rejected")
}

@(test)
test_decimal_size_rejects_invalid_syntax :: proc(t: ^testing.T) {
	// Any byte outside '0'..'9' must be rejected; these are all valid HTTP
	// header-value bytes but are not valid Content-Length syntax.
	invalid_cases := [?]string {
		"",
		"abc",
		"1x",
		"x1",
		"+1",
		"-1",
		"1.5",
		"1,000",
		"1\t2",
		" 1",
		"1 ",
	}

	for case_text in invalid_cases {
		_, ok := parse_decimal_size(transmute([]u8)case_text)
		testing.expectf(t, !ok, "parse_decimal_size(%q) must be rejected", case_text)
	}
}

@(test)
test_hex_size_parsing :: proc(t: ^testing.T) {
	parsed_size: u64
	success: bool

	parsed_size, success = parse_hexadecimal_size(transmute([]u8)string("0"))
	testing.expect(t, success && parsed_size == 0)

	parsed_size, success = parse_hexadecimal_size(transmute([]u8)string("1aF"))
	testing.expect(t, success && parsed_size == 431) // 0x1AF

	parsed_size, success = parse_hexadecimal_size(transmute([]u8)string("FFFFFFFFFFFFFFFF"))
	testing.expect(t, success && parsed_size == max(u64))

	_, success = parse_hexadecimal_size(transmute([]u8)string("10000000000000000"))
	testing.expect(t, !success, "17 hex digits must overflow and fail")
}

@(test)
test_uri_chars_accept_valid :: proc(t: ^testing.T) {
	// Representative valid URI bytes: unreserved, sub-delims, and specific delimiters
	valid_bytes := [?]u8 {
		'a',
		'Z',
		'0',
		'9',
		'-',
		'.',
		'_',
		'~', // ↑ unreserved
		'!',
		'$',
		'&',
		'\'',
		'(',
		')',
		'*',
		'+',
		',',
		';',
		'=', // ↑ sub-delims
		':',
		'@',
		'/',
		'?',
		'%', // ↑ delimiters and percent-encoding
	}
	for byte_value in valid_bytes {
		testing.expectf(
			t,
			is_uri_byte(byte_value),
			"URI byte 0x%02X ('%c') must be accepted",
			byte_value,
			rune(byte_value),
		)
	}
}

@(test)
test_uri_chars_reject_invalid :: proc(t: ^testing.T) {
	// Fragments ('#') are not allowed in the HTTP request-target per RFC 9112.
	// Spaces, CTLs, and high-bytes are also invalid.
	invalid_bytes := [?]u8{0x00, 0x0A, 0x20, '#', '<', '>', '{', '}', 0x7F, 0x80, 0xFF}
	for byte_value in invalid_bytes {
		testing.expectf(
			t,
			!is_uri_byte(byte_value),
			"byte 0x%02X must be rejected by CHARS_URI",
			byte_value,
		)
	}
}

@(test)
test_hex_and_decimal_digit_chars :: proc(t: ^testing.T) {
	// Decimal checks
	testing.expect(t, is_decimal_digit_byte('0'))
	testing.expect(t, is_decimal_digit_byte('9'))
	testing.expect(t, !is_decimal_digit_byte('A'))

	// Hexadecimal checks
	testing.expect(t, is_hex_digit_byte('0'))
	testing.expect(t, is_hex_digit_byte('9'))
	testing.expect(t, is_hex_digit_byte('a'))
	testing.expect(t, is_hex_digit_byte('f'))
	testing.expect(t, is_hex_digit_byte('A'))
	testing.expect(t, is_hex_digit_byte('F'))
	testing.expect(t, !is_hex_digit_byte('G'))
	testing.expect(t, !is_hex_digit_byte('g'))
}

@(test)
test_validate_token_bytes_slice :: proc(t: ^testing.T) {
	// Valid token slices
	testing.expect(t, validate_token_bytes(transmute([]u8)string("Host")))
	testing.expect(t, validate_token_bytes(transmute([]u8)string("Content-Type")))

	// Empty slice must fail (a token requires at least 1 character)
	testing.expect(t, !validate_token_bytes(nil))
	testing.expect(t, !validate_token_bytes(transmute([]u8)string("")))

	// Slices with embedded invalid characters must fail
	testing.expect(t, !validate_token_bytes(transmute([]u8)string("Content Type"))) // Space
	testing.expect(t, !validate_token_bytes(transmute([]u8)string("Host:"))) // Colon
	testing.expect(t, !validate_token_bytes(transmute([]u8)string("Header\x00"))) // NUL byte
}

// ─── Math & Logic Edge Case Tests ───────────────────────────────────────────

@(test)
test_hex_digit_value_math :: proc(t: ^testing.T) {
	// Validate the branchless hex math produces exact integer offsets
	testing.expect_value(t, hex_digit_value('0'), 0)
	testing.expect_value(t, hex_digit_value('9'), 9)
	testing.expect_value(t, hex_digit_value('a'), 10)
	testing.expect_value(t, hex_digit_value('f'), 15)
	testing.expect_value(t, hex_digit_value('A'), 10)
	testing.expect_value(t, hex_digit_value('F'), 15)
}

@(test)
test_find_newline_offset_bounds :: proc(t: ^testing.T) {
	buffer_bytes := transmute([]u8)string("Hello World\r\n")

	offset: int
	limit_exceeded: bool

	// Case 1: Newline is well within our limits
	// parsed_size = 0, size_maximum = 100
	offset, limit_exceeded = find_newline_offset(buffer_bytes, 0, 100)
	testing.expect(t, !limit_exceeded, "Should not exceed limit")
	testing.expect_value(t, offset, 11) // Index of '\r'

	// Case 2: No newline, but buffer is smaller than remaining limit
	// E.g., we received an incomplete packet, we should just wait for more data.
	incomplete_bytes := transmute([]u8)string("Hello ")
	offset, limit_exceeded = find_newline_offset(incomplete_bytes, 0, 100)
	testing.expect(t, !limit_exceeded, "Should not exceed limit, just incomplete")
	testing.expect_value(t, offset, -1)

	// Case 3: No newline, and we hit the strict maximum size
	// We've parsed 95 bytes, max is 100. The buffer is 10 bytes long.
	// We are only allowed to scan 5 bytes. If no \r is in those 5 bytes, limit is exceeded.
	malicious_bytes := transmute([]u8)string("xxxxxXXXXX")
	offset, limit_exceeded = find_newline_offset(malicious_bytes, 95, 100)
	testing.expect(t, limit_exceeded, "Must strictly exceed limit to prevent DoS")
	testing.expect_value(t, offset, -1)
}

@(test)
test_integer_parsers_empty_slice :: proc(t: ^testing.T) {
	// Ensure that feeding empty slices/nil does not crash and cleanly returns false
	parsed_dec, ok_dec := parse_decimal_size(nil)
	testing.expect(t, !ok_dec, "empty slice to decimal parser should fail gracefully")
	testing.expect_value(t, parsed_dec, 0)

	parsed_hex, ok_hex := parse_hexadecimal_size(nil)
	testing.expect(t, !ok_hex, "empty slice to hexadecimal parser should fail gracefully")
	testing.expect_value(t, parsed_hex, 0)
}

@(test)
test_find_newline_ignores_bare_lf_smuggling :: proc(t: ^testing.T) {
	// An attacker sends a bare \n instead of \r\n, padding with valid characters.
	// If the parser stops at \n, it gets smuggled. If it scans for \r, it hits the limit.
	malicious_bytes := transmute([]u8)string("Host: malicious.com\nBut-No-CR-Here")

	// Let's say the limit is exactly the length of this string
	offset, limit_exceeded := find_newline_offset(malicious_bytes, 0, u16(len(malicious_bytes)))

	testing.expect(t, limit_exceeded, "Must exceed limit because no \r was found")
	testing.expect_value(t, offset, -1)
}

@(test)
test_find_newline_exact_boundaries :: proc(t: ^testing.T) {
	// Case A: \r is exactly at the last allowed byte.
	// 9 padding characters + '\r' = 10 bytes total. Limit is 10.
	buffer_exact := transmute([]u8)string("123456789\r")
	offset_exact, limit_exceeded_exact := find_newline_offset(buffer_exact, 0, 10)

	testing.expect(
		t,
		!limit_exceeded_exact,
		"Should NOT exceed limit when \\r is exactly the last allowed byte",
	)
	testing.expect_value(t, offset_exact, 9)

	// Case B: \r is exactly ONE byte past the allowed limit.
	// 10 padding characters + '\r' = 11 bytes total. Limit is 10.
	buffer_past := transmute([]u8)string("1234567890\r")
	offset_past, limit_exceeded_past := find_newline_offset(buffer_past, 0, 10)

	testing.expect(
		t,
		limit_exceeded_past,
		"Must exceed limit when \\r is pushed beyond the maximum size",
	)
	testing.expect_value(t, offset_past, -1)
}


// ─── Helper Procs for Parser State-Machine Tests ───────────────────────────

@(private = "file")
Parse_Harness :: struct {
	state:         Parser_State,
	request:       Request_State,
	headers:       [64]Header_View,
	parsed_offset: u16,
	budget:        Parse_Budget,
}

@(private = "file")
parse_harness_make :: proc() -> Parse_Harness {
	harness := Parse_Harness {
		budget = DEFAULT_PARSE_BUDGET,
	}
	request_state_reset(&harness.request)
	parser_state_reset(&harness.state)
	return harness
}

// Drives the parser to terminal status (Headers_Done or any Error_*) by
// repeatedly calling parse_step on the same buffer. Returns the final status.
@(private = "file")
parse_harness_run :: proc(harness: ^Parse_Harness, buffer: []u8) -> Parse_Status {
	status, new_offset := parse_step(
		&harness.state,
		&harness.request,
		harness.headers[:],
		buffer,
		harness.parsed_offset,
		harness.budget,
	)
	harness.parsed_offset = new_offset
	return status
}

// Feeds the buffer to the parser one byte at a time.
// Returns the terminal status that the parser produces.
@(private = "file")
parse_harness_run_byte_by_byte :: proc(
	harness: ^Parse_Harness,
	buffer: []u8,
) -> (
	terminal_status: Parse_Status,
	terminal_index: int,
) {
	for index := 1; index <= len(buffer); index += 1 {
		status, new_offset := parse_step(
			&harness.state,
			&harness.request,
			harness.headers[:],
			buffer[:index],
			harness.parsed_offset,
			harness.budget,
		)
		harness.parsed_offset = new_offset
		if status != .Need_More {
			return status, index
		}
	}
	return .Need_More, len(buffer)
}


// ─── Happy-Path Parser Tests ───────────────────────────────────────────────

@(test)
test_parse_step_simple_get :: proc(t: ^testing.T) {
	request_bytes := transmute([]u8)string("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect_value(t, harness.request.method, Method.GET)
	testing.expect_value(t, harness.request.path_offset, 4)
	testing.expect_value(t, harness.request.path_size, 1)
	testing.expect_value(t, harness.request.query_size, 0)
	testing.expect_value(t, harness.request.header_count, 1)
	testing.expect(t, .Host in harness.request.known_headers, "Host should be classified")
	testing.expect_value(t, harness.parsed_offset, u16(len(request_bytes)))
	testing.expect_value(t, harness.state.phase, Parse_Phase.Complete)
}

@(test)
test_parse_step_path_query_split :: proc(t: ^testing.T) {
	// Query begins after the first '?'. The '?' itself is not part of either side.
	request_bytes := transmute([]u8)string(
		"GET /api/users?name=jane&age=30 HTTP/1.1\r\nHost: api.local\r\n\r\n",
	)
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect_value(t, harness.request.path_offset, 4)
	testing.expect_value(t, harness.request.path_size, 10) // "/api/users"
	testing.expect_value(t, harness.request.query_offset, 15)
	testing.expect_value(t, harness.request.query_size, 16) // "name=jane&age=30"

	path := request_bytes[harness.request.path_offset:][:harness.request.path_size]
	query := request_bytes[harness.request.query_offset:][:harness.request.query_size]
	testing.expect(t, equal_bytes(path, "/api/users"), "path should be /api/users")
	testing.expect(t, equal_bytes(query, "name=jane&age=30"), "query should match")
}

@(test)
test_parse_step_post_with_content_length :: proc(t: ^testing.T) {
	request_bytes := transmute([]u8)string(
		"POST /upload HTTP/1.1\r\nHost: u.local\r\nContent-Length: 1024\r\n\r\n",
	)
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect_value(t, harness.request.method, Method.POST)
	testing.expect(t, .Has_Content_Length in harness.state.flags, "CL flag set")
	testing.expect_value(t, harness.state.body_size_remaining, 1024)
	testing.expect_value(t, harness.state.phase, Parse_Phase.Body_Fixed)
}

@(test)
test_parse_step_chunked_request :: proc(t: ^testing.T) {
	request_bytes := transmute([]u8)string(
		"POST /upload HTTP/1.1\r\nHost: u.local\r\nTransfer-Encoding: chunked\r\n\r\n",
	)
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect(t, .Chunked_Request in harness.state.flags, "Chunked flag set")
	testing.expect(t, .Has_Transfer_Encoding in harness.state.flags, "TE flag set")
	testing.expect_value(t, harness.state.phase, Parse_Phase.Chunk_Size)
}

@(test)
test_parse_step_options_asterisk :: proc(t: ^testing.T) {
	request_bytes := transmute([]u8)string("OPTIONS * HTTP/1.1\r\nHost: srv.local\r\n\r\n")
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect_value(t, harness.request.method, Method.OPTIONS)
	testing.expect(
		t,
		.Options_Asterisk in harness.request.status_flags,
		"asterisk flag should be set",
	)
	testing.expect_value(t, harness.request.target_size, 1)
}

@(test)
test_parse_step_unknown_method_flagged :: proc(t: ^testing.T) {
	// "FOO" is a valid HTTP token but is not in the known method set.
	// The parser must accept the request but flag it for the router.
	request_bytes := transmute([]u8)string("FOO / HTTP/1.1\r\nHost: x\r\n\r\n")
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect(
		t,
		.Unknown_Method in harness.request.status_flags,
		"Unknown_Method flag must be set for non-standard methods",
	)
}

@(test)
test_parse_step_known_headers_skip_bloom :: proc(t: ^testing.T) {
	// Known headers must NOT pollute the bloom filter — they're tracked exactly
	// via Known_Header_Mask. Only arbitrary headers populate the bloom.
	request_bytes := transmute([]u8)string(
		"GET / HTTP/1.1\r\nHost: x\r\nX-Trace: abc\r\nUser-Agent: test\r\n\r\n",
	)
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect(t, harness.request.header_bloom != 0, "bloom should reflect arbitrary headers")

	// The bloom must NOT contain Host (Host is exact-tracked).
	host_hash := compute_header_hash(transmute([]u8)string("host"))
	x_trace_hash := compute_header_hash(transmute([]u8)string("x-trace"))
	user_agent_hash := compute_header_hash(transmute([]u8)string("user-agent"))

	// Hash space is small (64 bits) so we can only assert positives reliably.
	// Negatives can be coincidental — assert positives only.
	testing.expect(
		t,
		bloom_may_contain(harness.request.header_bloom, x_trace_hash),
		"bloom must contain X-Trace",
	)
	testing.expect(
		t,
		bloom_may_contain(harness.request.header_bloom, user_agent_hash),
		"bloom must contain User-Agent",
	)
	_ = host_hash // suppress unused; bloom may incidentally cover it via collision
}

@(test)
test_parse_step_connection_close_token :: proc(t: ^testing.T) {
	request_bytes := transmute([]u8)string(
		"GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, close\r\n\r\n",
	)
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)

	testing.expect_value(t, status, Parse_Status.Headers_Done)
	testing.expect(t, .Connection_Close in harness.state.flags, "close token recognized")
	testing.expect(t, .Keep_Alive_Allowed in harness.state.flags, "keep-alive token recognized")
}


// ─── Fragmentation (Incremental Feed) Tests ────────────────────────────────

@(test)
test_parse_step_fragmentation_matches_atomic :: proc(t: ^testing.T) {
	// The parser MUST be deterministic regardless of how the bytes arrive.
	// Feeding the request 1 byte at a time must produce a final state that is
	// identical (modulo internal counters) to feeding the entire buffer at once.
	request_bytes := transmute([]u8)string(
		"GET /api/users?id=42 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: tina-test\r\nAccept: */*\r\nContent-Length: 0\r\n\r\n",
	)

	atomic_harness := parse_harness_make()
	atomic_status := parse_harness_run(&atomic_harness, request_bytes)
	testing.expect_value(t, atomic_status, Parse_Status.Headers_Done)

	streaming_harness := parse_harness_make()
	streaming_status, terminal_index := parse_harness_run_byte_by_byte(
		&streaming_harness,
		request_bytes,
	)

	testing.expect_value(t, streaming_status, Parse_Status.Headers_Done)
	testing.expect_value(t, terminal_index, len(request_bytes))

	// Field-level equality between atomic and streaming runs.
	testing.expect_value(t, streaming_harness.request.method, atomic_harness.request.method)
	testing.expect_value(
		t,
		streaming_harness.request.path_offset,
		atomic_harness.request.path_offset,
	)
	testing.expect_value(t, streaming_harness.request.path_size, atomic_harness.request.path_size)
	testing.expect_value(
		t,
		streaming_harness.request.query_offset,
		atomic_harness.request.query_offset,
	)
	testing.expect_value(
		t,
		streaming_harness.request.query_size,
		atomic_harness.request.query_size,
	)
	testing.expect_value(
		t,
		streaming_harness.request.header_count,
		atomic_harness.request.header_count,
	)
	testing.expect_value(
		t,
		streaming_harness.request.known_headers,
		atomic_harness.request.known_headers,
	)
	testing.expect_value(
		t,
		streaming_harness.request.header_bloom,
		atomic_harness.request.header_bloom,
	)
	testing.expect_value(t, streaming_harness.state.flags, atomic_harness.state.flags)
	testing.expect_value(t, streaming_harness.state.phase, atomic_harness.state.phase)
	testing.expect_value(t, streaming_harness.state.header_size, atomic_harness.state.header_size)
	testing.expect_value(t, streaming_harness.parsed_offset, atomic_harness.parsed_offset)

	// Header_View entries must match byte-for-byte.
	for i in 0 ..< int(atomic_harness.request.header_count) {
		testing.expect_value(t, streaming_harness.headers[i], atomic_harness.headers[i])
	}
}

@(test)
test_parse_step_fragmentation_split_at_crlf_boundary :: proc(t: ^testing.T) {
	// The CR/LF boundary (\r without \n yet) is the canonical "single byte more"
	// case. Verify the parser asks for more bytes rather than declaring success.
	request_bytes := transmute([]u8)string("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
	harness := parse_harness_make()

	// Feed everything except the final '\n'.
	short_view := request_bytes[:len(request_bytes) - 1]
	short_status := parse_harness_run(&harness, short_view)
	testing.expect_value(t, short_status, Parse_Status.Need_More)

	// Now feed the whole buffer including the final '\n'.
	final_status := parse_harness_run(&harness, request_bytes)
	testing.expect_value(t, final_status, Parse_Status.Headers_Done)
}


// ─── Smuggling Guardrail Tests ─────────────────────────────────────────────

// A small DSL for declaring "feed this byte slice → expect this terminal status".
@(private = "file")
Smuggling_Case :: struct {
	name:    string,
	wire:    string,
	expects: Parse_Status,
}

@(test)
test_parse_step_smuggling_400_bad_request :: proc(t: ^testing.T) {
	cases := [?]Smuggling_Case {
		{"space in method", " ET / HTTP/1.1\r\nHost: x\r\n\r\n", .Error_Bad_Request},
		{"tab in request line", "GET\t/\tHTTP/1.1\r\nHost: x\r\n\r\n", .Error_Bad_Request},
		{"leading blank line", "\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n", .Error_Bad_Request},
		{"missing host header", "GET / HTTP/1.1\r\n\r\n", .Error_Bad_Request},
		{"duplicate host", "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", .Error_Bad_Request},
		{
			"duplicate content-length",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length and transfer-encoding both",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"transfer-encoding then content-length",
			"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"duplicate transfer-encoding",
			"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length non-numeric",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length negative sign",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length plus sign",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +1\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length mixed alphanumeric",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1x\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length decimal overflow",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 18446744073709551616\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"content-length with internal whitespace",
			"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1 2\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"obs-fold continuation line",
			"GET / HTTP/1.1\r\nHost: x\r\nX-Trace: abc\r\n  more\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"absolute-form request target",
			"GET http://example.com/ HTTP/1.1\r\nHost: x\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"asterisk target with non-OPTIONS method",
			"GET * HTTP/1.1\r\nHost: x\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"null byte in header value",
			"GET / HTTP/1.1\r\nHost: x\r\nX-T: bad\x00val\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"obs-text high byte in header value",
			"GET / HTTP/1.1\r\nHost: x\r\nX-T: caf\xc3\xa9\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"colon-prefixed header (empty name)",
			"GET / HTTP/1.1\r\nHost: x\r\n: empty-name\r\n\r\n",
			.Error_Bad_Request,
		},
		{
			"whitespace before colon",
			"GET / HTTP/1.1\r\nHost: x\r\nBad Header: v\r\n\r\n",
			.Error_Bad_Request,
		},
	}

	for tc in cases {
		harness := parse_harness_make()
		status := parse_harness_run(&harness, transmute([]u8)tc.wire)
		testing.expectf(
			t,
			status == tc.expects,
			"%q: expected %v but got %v",
			tc.name,
			tc.expects,
			status,
		)
	}
}

@(test)
test_parse_step_smuggling_417_expectation :: proc(t: ^testing.T) {
	request_bytes := transmute([]u8)string(
		"POST / HTTP/1.1\r\nHost: x\r\nExpect: lol-not-100\r\n\r\n",
	)
	harness := parse_harness_make()
	status := parse_harness_run(&harness, request_bytes)
	testing.expect_value(t, status, Parse_Status.Error_Expectation)
}

@(test)
test_parse_step_smuggling_501_unsupported_te :: proc(t: ^testing.T) {
	cases := [?]Smuggling_Case {
		{
			"gzip-only TE",
			"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n",
			.Error_Not_Implemented,
		},
		{
			"gzip+chunked list rejected (v1)",
			"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
			.Error_Not_Implemented,
		},
		{
			"unknown coding",
			"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\n\r\n",
			.Error_Not_Implemented,
		},
	}
	for tc in cases {
		harness := parse_harness_make()
		status := parse_harness_run(&harness, transmute([]u8)tc.wire)
		testing.expectf(
			t,
			status == tc.expects,
			"%q: expected %v but got %v",
			tc.name,
			tc.expects,
			status,
		)
	}
}

@(test)
test_parse_step_smuggling_505_bad_version :: proc(t: ^testing.T) {
	cases := [?]Smuggling_Case {
		{"HTTP/1.0", "GET / HTTP/1.0\r\nHost: x\r\n\r\n", .Error_Version},
		{"HTTP/2.0", "GET / HTTP/2.0\r\nHost: x\r\n\r\n", .Error_Version},
		{"junk version", "GET / HTTP/9.9\r\nHost: x\r\n\r\n", .Error_Version},
		{"missing slash", "GET / HTTP1.1\r\nHost: x\r\n\r\n", .Error_Version},
	}
	for tc in cases {
		harness := parse_harness_make()
		status := parse_harness_run(&harness, transmute([]u8)tc.wire)
		testing.expectf(
			t,
			status == tc.expects,
			"%q: expected %v but got %v",
			tc.name,
			tc.expects,
			status,
		)
	}
}

@(test)
test_parse_step_smuggling_431_header_too_large :: proc(t: ^testing.T) {
	// Construct headers that exceed `header_size_max` while remaining
	// individually well-formed. Use a tightened limit for a fast test.
	harness := parse_harness_make()
	harness.budget.header_size_max = 64

	// Build a single oversize header value.
	buf: [256]u8
	build_index := 0
	prefix := transmute([]u8)string("GET / HTTP/1.1\r\nHost: x\r\nX-Big: ")
	copy(buf[build_index:], prefix)
	build_index += len(prefix)
	for i in 0 ..< 200 {
		buf[build_index] = 'a'
		build_index += 1
	}
	tail := transmute([]u8)string("\r\n\r\n")
	copy(buf[build_index:], tail)
	build_index += len(tail)

	status := parse_harness_run(&harness, buf[:build_index])
	testing.expect_value(t, status, Parse_Status.Error_Header_Too_Large)
}

@(test)
test_parse_step_smuggling_request_line_too_long :: proc(t: ^testing.T) {
	harness := parse_harness_make()
	harness.budget.request_line_size_max = 32

	// Path long enough to overrun request_line_size_max with no CR in budget.
	buf: [128]u8
	build_index := 0
	prefix := transmute([]u8)string("GET /")
	copy(buf[:], prefix)
	build_index += len(prefix)
	for i in 0 ..< 100 {
		buf[build_index] = 'a'
		build_index += 1
	}
	tail := transmute([]u8)string(" HTTP/1.1\r\nHost: x\r\n\r\n")
	copy(buf[build_index:], tail)
	build_index += len(tail)

	status := parse_harness_run(&harness, buf[:build_index])
	testing.expect_value(t, status, Parse_Status.Error_Bad_Request)
}

@(test)
test_parse_step_smuggling_too_many_headers :: proc(t: ^testing.T) {
	// Cap header_count_max well below what we feed.
	harness := parse_harness_make()
	harness.budget.header_count_max = 3

	request_bytes := transmute([]u8)string(
		"GET / HTTP/1.1\r\nHost: x\r\nA: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\n\r\n",
	)
	status := parse_harness_run(&harness, request_bytes)
	testing.expect_value(t, status, Parse_Status.Error_Header_Too_Large)
}


// ─── Frame-Relative Offset Sanity ──────────────────────────────────────────

@(test)
test_parse_step_offsets_are_frame_relative :: proc(t: ^testing.T) {
	// Resolve every Header_View / path / query offset against the original
	// buffer and assert byte-for-byte equality with the expected text.
	request_bytes := transmute([]u8)string(
		"POST /foo?bar=baz HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n",
	)
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)
	testing.expect_value(t, status, Parse_Status.Headers_Done)

	path := request_bytes[harness.request.path_offset:][:harness.request.path_size]
	testing.expect(t, equal_bytes(path, "/foo"), "path offset/size resolves to /foo")

	query := request_bytes[harness.request.query_offset:][:harness.request.query_size]
	testing.expect(t, equal_bytes(query, "bar=baz"), "query resolves to bar=baz")

	// Header 0: Host
	host_view := harness.headers[0]
	host_name := request_bytes[host_view.name_offset:][:host_view.name_size]
	host_value := request_bytes[host_view.value_offset:][:host_view.value_size]
	testing.expect(t, equal_bytes(host_name, "Host"), "header[0] name is Host")
	testing.expect(t, equal_bytes(host_value, "example.com"), "header[0] value is example.com")

	// Header 1: Content-Length
	cl_view := harness.headers[1]
	cl_name := request_bytes[cl_view.name_offset:][:cl_view.name_size]
	cl_value := request_bytes[cl_view.value_offset:][:cl_view.value_size]
	testing.expect(t, equal_bytes(cl_name, "Content-Length"), "header[1] name is Content-Length")
	testing.expect(t, equal_bytes(cl_value, "0"), "header[1] value is 0")
}

@(test)
test_parse_step_value_ows_trimmed :: proc(t: ^testing.T) {
	// OWS surrounding the value must be trimmed in the stored Header_View.
	request_bytes := transmute([]u8)string("GET / HTTP/1.1\r\nHost:    spaced.example   \r\n\r\n")
	harness := parse_harness_make()

	status := parse_harness_run(&harness, request_bytes)
	testing.expect_value(t, status, Parse_Status.Headers_Done)

	host_view := harness.headers[0]
	host_value := request_bytes[host_view.value_offset:][:host_view.value_size]
	testing.expect(
		t,
		equal_bytes(host_value, "spaced.example"),
		"OWS around value must be trimmed",
	)
}


// ─── classify_method / classify_known_header Tests ─────────────────────────

@(test)
test_classify_method_known :: proc(t: ^testing.T) {
	method, known := classify_method(transmute([]u8)string("GET"))
	testing.expect(t, known && method == .GET)

	method, known = classify_method(transmute([]u8)string("OPTIONS"))
	testing.expect(t, known && method == .OPTIONS)

	method, known = classify_method(transmute([]u8)string("TRACE"))
	testing.expect(t, known && method == .TRACE)
}

@(test)
test_classify_method_unknown :: proc(t: ^testing.T) {
	_, known := classify_method(transmute([]u8)string("FOO"))
	testing.expect(t, !known, "FOO should not be a known method")

	_, known = classify_method(transmute([]u8)string("get"))
	testing.expect(t, !known, "lowercase should not match (HTTP methods are case-sensitive)")
}

@(test)
test_classify_known_header :: proc(t: ^testing.T) {
	header, ok := classify_known_header(transmute([]u8)string("Host"))
	testing.expect(t, ok && header == .Host)

	header, ok = classify_known_header(transmute([]u8)string("content-length"))
	testing.expect(t, ok && header == .Content_Length)

	header, ok = classify_known_header(transmute([]u8)string("TRANSFER-ENCODING"))
	testing.expect(t, ok && header == .Transfer_Encoding)

	_, ok = classify_known_header(transmute([]u8)string("X-Custom"))
	testing.expect(t, !ok, "X-Custom is not a known header")
}

@(test)
test_equal_bytes_ci :: proc(t: ^testing.T) {
	testing.expect(t, equal_bytes_ci_with_rhs_lowercase(transmute([]u8)string("HOST"), "host"))
	testing.expect(t, equal_bytes_ci_with_rhs_lowercase(transmute([]u8)string("Host"), "host"))
	testing.expect(t, equal_bytes_ci_with_rhs_lowercase(transmute([]u8)string("host"), "host"))
	testing.expect(t, !equal_bytes_ci_with_rhs_lowercase(transmute([]u8)string("Hosts"), "host"))
	testing.expect(t, !equal_bytes_ci_with_rhs_lowercase(transmute([]u8)string("Hxst"), "host"))
}
