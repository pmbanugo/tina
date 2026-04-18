package http_server

import "core:testing"

// ─── Known Headers ──────────────────────────────────────────────────────────
//
// Headers with semantic meaning to the parser — tracked exactly during parse
// via bit_set, zero false positives, zero hash computation. These are checked
// after header parsing completes for mandatory validation (e.g. Host present,
// no conflicting Content-Length + Transfer-Encoding).

Known_Header :: enum u8 {
	Host,
	Content_Length,
	Transfer_Encoding,
	Connection,
	Expect,
	Upgrade,
}

Known_Header_Mask :: distinct bit_set[Known_Header; u8]


// ─── FNV-1a Hashing ────────────────────────────────────────────────────────
//
// Used for arbitrary header lookup via Header_View.hash and the bloom filter.
// FNV-1a is the correct choice for 4–20 byte header names: zero setup cost,
// inline case-folding, no allocation. See Parser Notes §4 for the full
// rationale vs xxHash/murmur/djb2.

FNV1A_OFFSET_BASIS :: u32(2166136261)
FNV1A_PRIME        :: u32(16777619)

// Fold ASCII uppercase A..Z to lowercase a..z. All other bytes pass through
// unchanged — critical for symbols like '^' (0x5E) and '_' (0x5F) that naive
// `| 0x20` would corrupt. Pure ALU, zero memory loads, compiler-unrollable.
// See Parser Notes §1 for rationale.
fold_ascii_upper :: #force_inline proc "contextless" (character: u8) -> u8 {
	if character >= 'A' && character <= 'Z' {
		return character | 0x20
	}
	return character
}

// Computes a case-insensitive FNV-1a hash directly from the slice.
// Precondition: name_bytes must already be validated as valid HTTP token characters (CHARS_HTTP_TOKEN).
// Only ASCII letters A..Z are folded to lowercase; all other bytes are preserved.
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
// One pass does the work of two — see Parser Notes §6.
validate_and_hash_header_name :: proc "contextless" (name_bytes: []u8) -> (hash: u32, valid: bool) {
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
//
// 64-bit probabilistic filter for fast negative header lookup. Two bit
// positions are derived from different segments of the 32-bit FNV-1a hash.
// False negatives are impossible; false positives are expected and confirmed
// by length + exact case-insensitive compare on the raw slice.

// Sets 2 bits in a 64-bit bloom filter derived from the hash.
bloom_set :: #force_inline proc "contextless" (bloom: ^u64, hash: u32) {
	bit_a := hash & 0x3F         // low 6 bits  -> bit position 0..63
	bit_b := (hash >> 6) & 0x3F  // next 6 bits -> bit position 0..63
	bloom^ |= (1 << bit_a) | (1 << bit_b)
}

// Tests whether the bloom filter may contain a header with the given hash.
// Returns false only when the header is definitely absent.
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

	// Add Transfer_Encoding
	mask += {.Transfer_Encoding}
	testing.expect(t, .Transfer_Encoding in mask, "Transfer_Encoding should be in mask after add")
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

	testing.expect(t, hash_host != hash_content_length, "host and content-length should have different hashes")
	testing.expect(t, hash_host != hash_connection, "host and connection should have different hashes")
	testing.expect(t, hash_content_length != hash_connection, "content-length and connection should have different hashes")
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

// ─── Bloom Filter Tests ────────────────────────────────────────────────────

@(test)
test_bloom_empty :: proc(t: ^testing.T) {
	bloom: u64 = 0

	// An empty bloom filter must never report "may contain".
	// Test with a spread of hash values.
	testing.expect(t, !bloom_may_contain(bloom, 0), "empty bloom should not contain hash 0")
	testing.expect(t, !bloom_may_contain(bloom, 12345), "empty bloom should not contain hash 12345")
	testing.expect(t, !bloom_may_contain(bloom, 0xDEADBEEF), "empty bloom should not contain arbitrary hash")
}

@(test)
test_bloom_set_and_query :: proc(t: ^testing.T) {
	bloom: u64 = 0

	hash_host := compute_header_hash(transmute([]u8)string("host"))
	bloom_set(&bloom, hash_host)

	// The hash we just set must be found.
	testing.expect(t, bloom_may_contain(bloom, hash_host), "bloom should contain host hash after set")

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
	// Our DOD compute_header_hash specifically guards this by only folding A-Z.

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