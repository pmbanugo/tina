package http_server

import "core:bytes"
import "core:testing"

// ─── Parser State Machine ───────────────────────────────────────────────────
//
// The parser is an incremental state machine that processes bytes from the
// reactor buffer or working-memory ingress carry (split-packet).
// Parse_Phase drives the outer loop; Parser_Flags track semantic state
// extracted during header parsing.

@(private = "package")
Parse_Phase :: enum u8 {
	Request_Line,
	Headers,
	Body_Fixed,
	Chunk_Size,
	Chunk_Data,
	Chunk_Data_CRLF,
	Trailers,
	Complete,
	Error,
}

@(private = "package")
Parser_Flag :: enum u16 {
	Has_Content_Length,
	Has_Transfer_Encoding,
	Chunked_Request,
	Connection_Close,
	Expect_100,
	Upgrade_Request,
	Head_Method,
	Keep_Alive_Allowed,
}

@(private = "package")
Parser_Flags :: distinct bit_set[Parser_Flag;u16]

// ─── 256-Bit Validation Tables ──────────────────────────────────
//
// These are 256-bit lookup tables stored as [4]u64 (because no u256 for bit_set in Odin)
//
// Bit mapping:
//   - bit index = ASCII value (0–255)
//   - word index = c >> 6
//   - bit index  = c & 63   (LSB = lower ASCII values)
//
// Example:
//   'A' (65) → table[1] bit 1
//   'a' (97) → table[1] bit 33
//
// This enables branchless validation:
//   (table[c >> 6] & (1 << (c & 63))) != 0
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
// allowance for file-local lookup tables (HTTP_LIBRARY_DESIGN.md §2)
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

// ─── Inline Validation Helpers ──────────────────────────────────────────────
//
// They map the u8 to the exact bit in the 256-bit set.

@(private = "package")
is_token_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	return (CHARS_HTTP_TOKEN[byte_value >> 6] & (u64(1) << (byte_value & 63))) != 0
}

@(private = "package")
is_uri_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	return (CHARS_URI[byte_value >> 6] & (u64(1) << (byte_value & 63))) != 0
}

@(private = "package")
is_header_value_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	return (CHARS_HEADER_VALUE[byte_value >> 6] & (u64(1) << (byte_value & 63))) != 0
}

@(private = "package")
is_hex_digit_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	return (CHARS_DIGIT_HEX[byte_value >> 6] & (u64(1) << (byte_value & 63))) != 0
}

@(private = "package")
is_decimal_digit_byte :: #force_inline proc "contextless" (byte_value: u8) -> bool {
	return (CHARS_DIGIT_DECIMAL[byte_value >> 6] & (u64(1) << (byte_value & 63))) != 0
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

// Parses a base-10 Content-Length value.
// Precondition: digit_bytes must contain ONLY validated '0'..'9' characters.
// Returns (parsed_size, true) on success, (0, false) on empty input
// or conservative range reject.
@(private = "package")
parse_decimal_size :: proc "contextless" (digit_bytes: []u8) -> (u64, bool) {
	if len(digit_bytes) == 0 do return 0, false
	if len(digit_bytes) > 19 do return 0, false

	parsed_size: u64 = 0
	for character in digit_bytes {
		digit_value := u64(character - '0')
		parsed_size = (parsed_size * 10) + digit_value
	}

	return parsed_size, true
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
	parsed_size_current: u32,
	size_maximum: u32,
) -> (
	offset: int,
	limit_exceeded: bool,
) {
	remaining_size_allowed := size_maximum - parsed_size_current
	scan_size := min(u32(len(buffer_bytes)), remaining_size_allowed)

	// bytes.index_byte leverages SIMD vectorization automatically
	newline_offset := bytes.index_byte(buffer_bytes[:scan_size], '\r')

	// If no newline is found AND we hit our strict size maximum, the client
	// is violating limits. Connection must be dropped.
	if newline_offset < 0 && u32(len(buffer_bytes)) >= remaining_size_allowed {
		return -1, true
	}

	return newline_offset, false
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

	// Largest safe 19-digit number
	parsed_size, success = parse_decimal_size(transmute([]u8)string("9999999999999999999"))
	testing.expect(t, success && parsed_size == 9_999_999_999_999_999_999)

	// 20 digits should trigger fast-guard overflow block
	_, success = parse_decimal_size(transmute([]u8)string("18446744073709551615"))
	testing.expect(t, !success, "20-digit string must fail fast-guard")
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
	offset, limit_exceeded := find_newline_offset(malicious_bytes, 0, u32(len(malicious_bytes)))

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
