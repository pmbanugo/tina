// ─── Selective In-Place Path Canonicalization ───────────────────────────────
//
// HTTP path canonicalization decodes every valid `%HH` escape EXCEPT `%2F`/`%2f`,
// which are preserved so that segment boundaries cannot be smuggled past the router.
// See HTTP_LIBRARY_ROUTING_AND_DISPATCH.md §3.5 for the security rationale.
//
// The same rule is applied to incoming request paths AND to registered route
// patterns at install time, so both sides of the router's `memcmp` are
// normalized identically.

package http_server

import "core:bytes"
import "core:mem"
import "core:testing"


@(private = "package")
Path_Canon_Error :: enum u8 {
	None,
	Malformed_Percent,
	Decoded_CTL, // decoded byte is < 0x20 or == 0x7F (DEL)
}

@(private = "package")
path_canonicalize_selective_in_place :: proc "contextless" (
	path_bytes: []u8,
) -> (
	canonical_size: int,
	error: Path_Canon_Error,
	error_offset: int,
) {
	first_percent_index := bytes.index_byte(path_bytes, '%')
	if first_percent_index < 0 {
		return len(path_bytes), .None, -1
	}

	read_index := first_percent_index
	write_index := first_percent_index
	input_size := len(path_bytes)

	for read_index < input_size {
		current_byte := path_bytes[read_index]
		if current_byte != '%' {
			path_bytes[write_index] = current_byte
			read_index += 1
			write_index += 1
			continue
		}

		// `%HH` requires two more bytes.
		if read_index + 2 >= input_size {
			return 0, .Malformed_Percent, read_index
		}
		hi_nibble := path_bytes[read_index + 1]
		lo_nibble := path_bytes[read_index + 2]
		if !is_hex_digit_byte(hi_nibble) || !is_hex_digit_byte(lo_nibble) {
			return 0, .Malformed_Percent, read_index
		}

		decoded_byte := u8((hex_digit_value(hi_nibble) << 4) | hex_digit_value(lo_nibble))

		if decoded_byte == '/' {
			// Preserve `%2F` and case-canonicalize `%2f` → `%2F` so segment
			// boundaries cannot be reintroduced post-decode.
			path_bytes[write_index + 0] = '%'
			path_bytes[write_index + 1] = '2'
			path_bytes[write_index + 2] = 'F'
			read_index += 3
			write_index += 3
			continue
		}

		// Reject decoded CTL/DEL bytes — closes downstream-truncation
		// smuggling vectors at the parser layer.
		if decoded_byte < 0x20 || decoded_byte == 0x7F {
			return 0, .Decoded_CTL, read_index
		}

		path_bytes[write_index] = decoded_byte
		read_index += 3
		write_index += 1
	}

	return write_index, .None, -1
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_path_canon_no_percent_fast_path :: proc(t: ^testing.T) {
	buffer := transmute([]u8)([]u8{'/', 'a', 'p', 'i', '/', 'u', 's', 'e', 'r', 's'})
	original := make([]u8, len(buffer))
	copy(original, buffer)
	defer mem.delete(original)

	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, size, 10)
	for i in 0 ..< size {
		testing.expect_value(t, buffer[i], original[i])
	}
}

@(test)
test_path_canon_decode_unreserved :: proc(t: ^testing.T) {
	// `%61` → `a`
	buffer := []u8{'/', '%', '6', '1', 'd', 'm', 'i', 'n'}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, size, 6)
	testing.expect_value(t, string(buffer[:size]), "/admin")
}

@(test)
test_path_canon_preserves_uppercase_2F :: proc(t: ^testing.T) {
	buffer := []u8{'/', 'a', '%', '2', 'F', 'b'}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, size, 6)
	testing.expect_value(t, string(buffer[:size]), "/a%2Fb")
}

@(test)
test_path_canon_canonicalizes_lowercase_2f_to_uppercase :: proc(t: ^testing.T) {
	buffer := []u8{'/', 'a', '%', '2', 'f', 'b'}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, size, 6)
	testing.expect_value(t, string(buffer[:size]), "/a%2Fb")
}

@(test)
test_path_canon_rejects_decoded_null :: proc(t: ^testing.T) {
	buffer := []u8{'/', '%', '0', '0'}
	_, err, offset := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.Decoded_CTL)
	testing.expect_value(t, offset, 1)
}

@(test)
test_path_canon_rejects_decoded_low_ctl :: proc(t: ^testing.T) {
	buffer := []u8{'/', '%', '1', 'F'}
	_, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.Decoded_CTL)
}

@(test)
test_path_canon_rejects_decoded_del :: proc(t: ^testing.T) {
	buffer := []u8{'/', '%', '7', 'F'}
	_, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.Decoded_CTL)
}

@(test)
test_path_canon_rejects_truncated_percent :: proc(t: ^testing.T) {
	buffer := []u8{'/', 'a', '%'}
	_, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.Malformed_Percent)
}

@(test)
test_path_canon_rejects_short_trailing_percent :: proc(t: ^testing.T) {
	buffer := []u8{'/', 'a', '%', '4'}
	_, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.Malformed_Percent)
}

@(test)
test_path_canon_rejects_non_hex_digits :: proc(t: ^testing.T) {
	buffer := []u8{'/', '%', 'G', '0'}
	_, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.Malformed_Percent)

	buffer2 := []u8{'/', '%', '0', 'G'}
	_, err2, _ := path_canonicalize_selective_in_place(buffer2)
	testing.expect_value(t, err2, Path_Canon_Error.Malformed_Percent)
}

@(test)
test_path_canon_decodes_utf8_bytes :: proc(t: ^testing.T) {
	// `/caf%C3%A9` → `/café` (UTF-8 0xC3 0xA9)
	buffer := []u8{'/', 'c', 'a', 'f', '%', 'C', '3', '%', 'A', '9'}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, size, 6)
	testing.expect_value(t, buffer[0], u8('/'))
	testing.expect_value(t, buffer[1], u8('c'))
	testing.expect_value(t, buffer[2], u8('a'))
	testing.expect_value(t, buffer[3], u8('f'))
	testing.expect_value(t, buffer[4], u8(0xC3))
	testing.expect_value(t, buffer[5], u8(0xA9))
}

@(test)
test_path_canon_2F_does_not_split_segments :: proc(t: ^testing.T) {
	// `/a%2Fb` must survive as one structural segment for the router.
	buffer := []u8{'/', 'a', '%', '2', 'F', 'b'}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	canonical := string(buffer[:size])
	// The canonical form must still contain `%2F`, NOT a literal `/`.
	testing.expect(t, bytes.contains(buffer[:size], []u8{'%', '2', 'F'}), "must preserve %2F")
	testing.expect_value(t, canonical, "/a%2Fb")
}

@(test)
test_path_canon_mixed_decode_and_preserve :: proc(t: ^testing.T) {
	// `/u%73ers/%2Fid` → `/users/%2Fid` (decode `%73`→`s`, preserve `%2F`)
	buffer := []u8{'/', 'u', '%', '7', '3', 'e', 'r', 's', '/', '%', '2', 'F', 'i', 'd'}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, string(buffer[:size]), "/users/%2Fid")
}

@(test)
test_path_canon_empty_input :: proc(t: ^testing.T) {
	buffer: []u8 = {}
	size, err, _ := path_canonicalize_selective_in_place(buffer)
	testing.expect_value(t, err, Path_Canon_Error.None)
	testing.expect_value(t, size, 0)
}
