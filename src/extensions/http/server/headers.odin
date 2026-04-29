package http_server

import "core:testing"

// Headers with semantic meaning to the parser — tracked exactly during parse
@(private = "package")
Known_Header :: enum u8 {
	Host,
	Content_Length,
	Transfer_Encoding,
	Connection,
	Expect,
	Upgrade,
}

@(private = "package")
Known_Header_Mask :: distinct bit_set[Known_Header;u8]


// ─── FNV-1a Hashing ────────────────────────────────────────────────────────
//
// Used for arbitrary header lookup via Header_View.hash and the bloom filter.

@(private = "package")
FNV1A_OFFSET_BASIS :: u32(2166136261)

@(private = "package")
FNV1A_PRIME :: u32(16777619)

// Fold ASCII uppercase A..Z to lowercase a..z. All other bytes pass through
// unchanged — See Parser Notes §1.
@(private = "package")
fold_ascii_upper :: #force_inline proc "contextless" (character: u8) -> u8 {
	difference_from_A := character - 'A'
	is_upper_alpha := u8(difference_from_A < 26)
	return character | (is_upper_alpha << 5)
}

// Computes a case-insensitive FNV-1a hash directly from the slice.
// Precondition: name_bytes must already be validated as valid HTTP token characters (CHARS_HTTP_TOKEN).
// Only ASCII letters A..Z are folded to lowercase; all other bytes are preserved.
@(private = "package")
compute_header_hash :: #force_inline proc "contextless" (name_bytes: []u8) -> u32 {
	hash_value: u32 = FNV1A_OFFSET_BASIS

	for character in name_bytes {
		hash_value = (hash_value ~ u32(fold_ascii_upper(character))) * FNV1A_PRIME
	}

	return hash_value
}

// Combined validation + hashing in a single pass over header name bytes.
// Rejects any byte not in CHARS_HTTP_TOKEN and returns (0, false).
// On success, returns the case-insensitive FNV-1a hash.
//
// This is the parser's primary entry point for header name processing.
// see Parser Notes §6.
@(private = "package")
validate_and_hash_header_name :: proc "contextless" (
	name_bytes: []u8,
) -> (
	hash: u32,
	valid: bool,
) {
	if len(name_bytes) == 0 do return 0, false

	hash_value: u32 = FNV1A_OFFSET_BASIS

	for character in name_bytes {
		// Reject any byte that is not a valid token character.
		if !is_token_byte(character) {
			return 0, false
		}
		hash_value = (hash_value ~ u32(fold_ascii_upper(character))) * FNV1A_PRIME
	}

	return hash_value, true
}


// ─── Bloom Filter ───────────────────────────────────────────────────────────

// Sets 2 bits in a 64-bit bloom filter derived from the hash.
@(private = "package")
bloom_set :: #force_inline proc "contextless" (bloom: ^u64, hash: u32) {
	bit_a := hash & 0x3F // low 6 bits  -> bit position 0..63
	bit_b := (hash >> 6) & 0x3F // next 6 bits -> bit position 0..63
	bloom^ |= (1 << bit_a) | (1 << bit_b)
}

// Tests whether the bloom filter may contain a header with the given hash.
@(private = "package")
bloom_may_contain :: #force_inline proc "contextless" (bloom: u64, hash: u32) -> bool {
	bit_a := hash & 0x3F
	bit_b := (hash >> 6) & 0x3F
	mask := u64(1 << bit_a) | u64(1 << bit_b)
	return (bloom & mask) == mask
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

// ─── Known Header Mask Tests ────────────────────────────────────────────────

@(test)
test_known_header_mask_operations :: proc(t: ^testing.T) {
	mask := Known_Header_Mask{.Host, .Content_Length}

	testing.expect(t, .Host in mask, "Host should be in mask")
	testing.expect(t, .Content_Length in mask, "Content_Length should be in mask")
	testing.expect(t, .Transfer_Encoding not_in mask, "Transfer_Encoding should not be in mask")

	mask += {.Transfer_Encoding}
	testing.expect(t, .Transfer_Encoding in mask, "Transfer_Encoding should be in mask after add")
}

// ─── fold_ascii_upper Boundary Tests ────────────────────────────────────────

@(test)
test_fold_ascii_upper_alpha_range :: proc(t: ^testing.T) {
	// Every byte in 'A'..'Z' folds to its lowercase counterpart.
	for byte_value: u8 = 'A'; byte_value <= 'Z'; byte_value += 1 {
		expected := byte_value | 0x20
		actual := fold_ascii_upper(byte_value)
		testing.expectf(
			t,
			actual == expected,
			"fold('%c'/0x%02X) = 0x%02X, want 0x%02X",
			byte_value,
			byte_value,
			actual,
			expected,
		)
	}
}

@(test)
test_fold_ascii_upper_boundary_neighbors :: proc(t: ^testing.T) {
	// Bytes immediately surrounding the 'A'..'Z' range MUST pass through unchanged.
	// '@' (0x40) is one below 'A' (0x41); '[' (0x5B) is one above 'Z' (0x5A).
	// '^' (0x5E) and '_' (0x5F) are the historically misfolded symbols that
	// motivated the branchless boundary check.
	unchanged_bytes := [?]u8 {
		0x00,
		0x09,
		0x20, // CTL/whitespace
		'0',
		'9', // digits
		'@', // 0x40, just below 'A'
		'[',
		'\\',
		']',
		'^',
		'_', // 0x5B-0x5F, just above 'Z'
		'`', // 0x60, just below 'a'
		'a',
		'z', // already-lowercase letters
		'{',
		'|',
		'}',
		'~', // 0x7B-0x7E
		0x7F,
		0x80,
		0xFF, // DEL and high bytes
	}
	for byte_value in unchanged_bytes {
		actual := fold_ascii_upper(byte_value)
		testing.expectf(
			t,
			actual == byte_value,
			"fold(0x%02X) = 0x%02X, want unchanged 0x%02X",
			byte_value,
			actual,
			byte_value,
		)
	}
}

// ─── FNV-1a Hash Tests ──────────────────────────────────────────────────────

@(test)
test_compute_header_hash_case_insensitive :: proc(t: ^testing.T) {
	// All case variants of "Host" must produce the same hash.
	hash_lower := compute_header_hash(transmute([]u8)string("host"))
	hash_upper := compute_header_hash(transmute([]u8)string("HOST"))
	hash_mixed := compute_header_hash(transmute([]u8)string("hOsT"))
	hash_canon := compute_header_hash(transmute([]u8)string("Host"))

	testing.expect_value(t, hash_lower, hash_canon)
	testing.expect_value(t, hash_upper, hash_canon)
	testing.expect_value(t, hash_mixed, hash_canon)
}

@(test)
test_compute_header_hash_distinct_names :: proc(t: ^testing.T) {
	hash_host := compute_header_hash(transmute([]u8)string("host"))
	hash_content_length := compute_header_hash(transmute([]u8)string("content-length"))
	hash_connection := compute_header_hash(transmute([]u8)string("connection"))

	testing.expect(
		t,
		hash_host != hash_content_length,
		"host and content-length should have different hashes",
	)
	testing.expect(
		t,
		hash_host != hash_connection,
		"host and connection should have different hashes",
	)
	testing.expect(
		t,
		hash_content_length != hash_connection,
		"content-length and connection should have different hashes",
	)
}

@(test)
test_compute_header_hash_preserves_non_alpha :: proc(t: ^testing.T) {
	// Characters like '-', '_', '^', '~' must not be corrupted by the fold.
	// The hyphen in "X-Custom" must contribute the same hash value regardless
	// of the surrounding letter case.
	hash_a := compute_header_hash(transmute([]u8)string("x-custom"))
	hash_b := compute_header_hash(transmute([]u8)string("X-Custom"))
	hash_c := compute_header_hash(transmute([]u8)string("X-CUSTOM"))

	testing.expect_value(t, hash_a, hash_b)
	testing.expect_value(t, hash_a, hash_c)
}

// ─── Validate and Hash Tests ────────────────────────────────────────────────

@(test)
test_validate_and_hash_valid :: proc(t: ^testing.T) {
	hash, valid := validate_and_hash_header_name(transmute([]u8)string("Content-Type"))
	testing.expect(t, valid, "Content-Type should be valid")

	// Cross-check: should produce the same hash as compute_header_hash.
	expected_hash := compute_header_hash(transmute([]u8)string("Content-Type"))
	testing.expect_value(t, hash, expected_hash)
}

@(test)
test_validate_and_hash_invalid_space :: proc(t: ^testing.T) {
	_, valid := validate_and_hash_header_name(transmute([]u8)string("Bad Header"))
	testing.expect(t, !valid, "space in header name should be invalid")
}

@(test)
test_validate_and_hash_invalid_null :: proc(t: ^testing.T) {
	_, valid := validate_and_hash_header_name(transmute([]u8)string("Bad\x00Name"))
	testing.expect(t, !valid, "NUL in header name should be invalid")
}

@(test)
test_validate_and_hash_invalid_colon :: proc(t: ^testing.T) {
	_, valid := validate_and_hash_header_name(transmute([]u8)string("Content:Type"))
	testing.expect(t, !valid, "colon in header name should be invalid")
}

@(test)
test_validate_and_hash_empty :: proc(t: ^testing.T) {
	_, valid := validate_and_hash_header_name(nil)
	testing.expect(t, !valid, "empty header name should be invalid")
}

@(test)
test_validate_and_hash_invalid_ctl_and_del :: proc(t: ^testing.T) {
	// Embedded CTL (0x01..0x1F) and DEL (0x7F) bytes must be rejected by
	// the combined validate-and-hash pass — they are not HTTP token chars.
	rejected_inputs := [?]string {
		"Header\x01Name", // SOH (CTL)
		"Header\x1FName", // US (CTL)
		"Header\x7FName", // DEL
	}
	for input in rejected_inputs {
		_, valid := validate_and_hash_header_name(transmute([]u8)input)
		testing.expectf(t, !valid, "input %q must be rejected", input)
	}
}

// ─── Bloom Filter Tests ────────────────────────────────────────────────────

@(test)
test_bloom_empty :: proc(t: ^testing.T) {
	bloom: u64 = 0

	// An empty bloom filter must never report "may contain".
	// Test with a spread of hash values.
	testing.expect(t, !bloom_may_contain(bloom, 0), "empty bloom should not contain hash 0")
	testing.expect(
		t,
		!bloom_may_contain(bloom, 12345),
		"empty bloom should not contain hash 12345",
	)
	testing.expect(
		t,
		!bloom_may_contain(bloom, 0xDEADBEEF),
		"empty bloom should not contain arbitrary hash",
	)
}

@(test)
test_bloom_set_and_query :: proc(t: ^testing.T) {
	bloom: u64 = 0

	hash_host := compute_header_hash(transmute([]u8)string("host"))
	bloom_set(&bloom, hash_host)

	testing.expect(
		t,
		bloom_may_contain(bloom, hash_host),
		"bloom should contain host hash after set",
	)

	// The bloom filter is non-zero after insertion.
	testing.expect(t, bloom != 0, "bloom should be non-zero after insertion")
}

@(test)
test_bloom_no_false_negatives :: proc(t: ^testing.T) {
	bloom: u64 = 0

	// Insert several distinct header hashes.
	headers := [?]string{"host", "content-length", "connection", "accept", "user-agent"}
	hashes: [5]u32

	for header, index in headers {
		hashes[index] = compute_header_hash(transmute([]u8)header)
		bloom_set(&bloom, hashes[index])
	}

	// Every inserted hash must be found — zero false negatives.
	for header, index in headers {
		testing.expectf(
			t,
			bloom_may_contain(bloom, hashes[index]),
			"bloom must contain '%s' (no false negatives)",
			header,
		)
	}
}

@(test)
test_header_hashing_case_insensitivity :: proc(t: ^testing.T) {
	hash_upper := compute_header_hash(transmute([]u8)string("CONTENT-LENGTH"))
	hash_lower := compute_header_hash(transmute([]u8)string("content-length"))
	hash_mixed := compute_header_hash(transmute([]u8)string("Content-Length"))

	testing.expect(t, hash_upper == hash_lower, "Upper and lower hashes must match")
	testing.expect(t, hash_upper == hash_mixed, "Upper and mixed hashes must match")
}

@(test)
test_header_hashing_preserves_symbols :: proc(t: ^testing.T) {
	// RFC 9110 allows symbols like '^' (0x5E) and '_' (0x5F) in tchar.
	// A naive `| 0x20` lowercase blindly mutates '^' (0x5E) into '~' (0x7E).

	hash_caret := compute_header_hash(transmute([]u8)string("^Header"))
	hash_tilde := compute_header_hash(transmute([]u8)string("~Header"))

	testing.expect(t, hash_caret != hash_tilde, "Hash must not naively fold ^ into ~")

	// Verify A-Z folding still works even when symbols are present
	hash_caret_upper := compute_header_hash(transmute([]u8)string("^HEADER"))
	testing.expect(
		t,
		hash_caret == hash_caret_upper,
		"Case insensitivity must work around symbols",
	)
}
