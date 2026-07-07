package http_server

import "core:bytes"
import "core:mem"
import "core:testing"

// Drains up to `len(destination)` bytes from `network` into `destination`.
// Extracts pure payload without allocating.
// Returns the number of bytes actually copied.
@(require_results)
drain_buffered_body :: #force_inline proc "contextless" (
	network: []u8,
	destination: []u8,
) -> int {
	copy_size := min(len(network), len(destination))
	if copy_size > 0 {
		mem.copy(raw_data(destination), raw_data(network), copy_size)
	}
	return copy_size
}

// Retains unconsumed pipeline bytes into the pipeline region.
// If the unconsumed source exceeds the destination budget, it returns
// `budget_exceeded = true`, allowing the caller to close the connection
// after the current response.
@(require_results)
retain_pipeline_tail :: #force_inline proc "contextless" (
	unconsumed_source: []u8,
	destination_pipeline_region: []u8,
) -> (
	retained_size: int,
	budget_exceeded: bool,
) {
	source_size := len(unconsumed_source)
	if source_size == 0 {
		return 0, false
	}

	if source_size > len(destination_pipeline_region) {
		return 0, true
	}

	mem.copy(raw_data(destination_pipeline_region), raw_data(unconsumed_source), source_size)
	return source_size, false
}

@(private = "package")
Body_Drain_Result :: struct {
	consumed_size:  int,
	data_offset:    int,
	data_size:      int,
	done:           bool,
	need_more:      bool,
	protocol_error: bool,
	body_too_large: bool,
}

@(private = "package")
CHUNK_SIZE_DIGIT_COUNT_MAXIMUM :: u8(16)

@(private = "package")
drain_request_body :: proc "contextless" (
	parser: ^Parser_State,
	network: []u8,
	destination: []u8,
	destination_size: u32,
	body_size_received: u64,
	body_size_max: u32,
	parse_budget: Parse_Budget,
	buffered: bool,
) -> (Body_Drain_Result, u32, u64) {
	result: Body_Drain_Result

	#partial switch parser.phase {
	case .Body_Fixed:
		return _drain_body_payload(
			parser,
			network,
			destination,
			destination_size,
			body_size_received,
			body_size_max,
			buffered,
			fixed_length = true,
		)

	case .Chunk_Size:
		parsed_size := parser.chunk_size_parsed
		digit_count := parser.chunk_size_digit_count
		for index in 0 ..< len(network) {
			byte_value := network[index]

			if is_hex_digit_byte(byte_value) {
				if digit_count >= CHUNK_SIZE_DIGIT_COUNT_MAXIMUM || (parsed_size >> 60) != 0 {
					result.protocol_error = true
					return result, destination_size, body_size_received
				}
				parsed_size = (parsed_size << 4) | hex_digit_value(byte_value)
				digit_count += 1
				continue
			}

			if byte_value == '\r' {
				if digit_count == 0 {
					result.protocol_error = true
					return result, destination_size, body_size_received
				}
				if index + 1 >= len(network) {
					parser.chunk_size_parsed = parsed_size
					parser.chunk_size_digit_count = digit_count
					result.consumed_size = index
					result.need_more = true
					return result, destination_size, body_size_received
				}
				if network[index + 1] != '\n' {
					result.protocol_error = true
					return result, destination_size, body_size_received
				}
				if body_size_received > u64(body_size_max) ||
				   parsed_size > u64(body_size_max) - body_size_received {
					result.body_too_large = true
					return result, destination_size, body_size_received
				}
				parser.chunk_size_remaining = parsed_size
				parser.chunk_size_parsed = 0
				parser.chunk_size_digit_count = 0
				parser.phase = .Trailers if parsed_size == 0 else .Chunk_Data
				result.consumed_size = index + 2
				return result, destination_size, body_size_received
			}

			if (byte_value == ';' || byte_value == ' ' || byte_value == '\t') && digit_count > 0 {
				parser.chunk_size_remaining = parsed_size
				parser.chunk_size_parsed = 0
				parser.chunk_size_digit_count = 0
				parser.phase = .Chunk_Ext
				result.consumed_size = index + 1
				return result, destination_size, body_size_received
			}

			result.protocol_error = true
			return result, destination_size, body_size_received
		}
		parser.chunk_size_parsed = parsed_size
		parser.chunk_size_digit_count = digit_count
		result.consumed_size = len(network)
		result.need_more = true
		return result, destination_size, body_size_received

	case .Chunk_Ext:
		for index in 0 ..< len(network) {
			byte_value := network[index]
			if byte_value == '\r' {
				if index + 1 >= len(network) {
					result.consumed_size = index
					result.need_more = true
					return result, destination_size, body_size_received
				}
				if network[index + 1] != '\n' {
					result.protocol_error = true
					return result, destination_size, body_size_received
				}
				parser.chunk_size_parsed = 0
				parser.phase = .Trailers if parser.chunk_size_remaining == 0 else .Chunk_Data
				result.consumed_size = index + 2
				return result, destination_size, body_size_received
			}
			if byte_value < 0x20 && byte_value != '\t' {
				result.protocol_error = true
				return result, destination_size, body_size_received
			}
			parser.chunk_size_parsed += 1
			if parser.chunk_size_parsed > u64(parse_budget.chunk_ext_size_max) {
				result.protocol_error = true
				return result, destination_size, body_size_received
			}
		}
		result.consumed_size = len(network)
		result.need_more = true
		return result, destination_size, body_size_received

	case .Chunk_Data:
		return _drain_body_payload(
			parser,
			network,
			destination,
			destination_size,
			body_size_received,
			body_size_max,
			buffered,
			fixed_length = false,
		)

	case .Chunk_Data_CRLF:
		if len(network) == 0 {
			result.need_more = true
			return result, destination_size, body_size_received
		}
		if network[0] != '\r' {
			result.protocol_error = true
			return result, destination_size, body_size_received
		}
		if len(network) == 1 {
			result.need_more = true
			return result, destination_size, body_size_received
		}
		if network[1] != '\n' {
			result.protocol_error = true
			return result, destination_size, body_size_received
		}
		parser.phase = .Chunk_Size
		result.consumed_size = 2
		return result, destination_size, body_size_received

	case .Trailers:
		cursor := 0
		for {
			if cursor >= len(network) {
				result.consumed_size = cursor
				result.need_more = true
				return result, destination_size, body_size_received
			}
			view := network[cursor:]
			if len(view) == 1 && view[0] == '\r' {
				result.consumed_size = cursor
				result.need_more = true
				return result, destination_size, body_size_received
			}
			if len(view) >= 2 && view[0] == '\r' && view[1] == '\n' {
				parser.phase = .Complete
				result.consumed_size = cursor + 2
				result.done = true
				return result, destination_size, body_size_received
			}

			line_end := bytes.index_byte(view, '\r')
			if line_end < 0 {
				if int(parser.header_size) + len(view) > int(parse_budget.header_size_max) {
					result.protocol_error = true
					return result, destination_size, body_size_received
				}
				result.consumed_size = cursor
				result.need_more = true
				return result, destination_size, body_size_received
			}
			if line_end + 1 >= len(view) {
				result.consumed_size = cursor
				result.need_more = true
				return result, destination_size, body_size_received
			}
			if view[line_end + 1] != '\n' {
				result.protocol_error = true
				return result, destination_size, body_size_received
			}

			line_size := line_end + 2
			if int(parser.header_size) + line_size > int(parse_budget.header_size_max) {
				result.protocol_error = true
				return result, destination_size, body_size_received
			}
			if int(parser.header_count) >= int(parse_budget.header_count_max) {
				result.protocol_error = true
				return result, destination_size, body_size_received
			}
			parser.header_size += u16(line_size)
			parser.header_count += 1
			cursor += line_size
		}

	case .Complete:
		result.done = true
		return result, destination_size, body_size_received

	case:
		result.protocol_error = true
		return result, destination_size, body_size_received
	}
}

@(private = "file")
_drain_body_payload :: proc "contextless" (
	parser: ^Parser_State,
	network: []u8,
	destination: []u8,
	destination_size: u32,
	body_size_received: u64,
	body_size_max: u32,
	buffered: bool,
	fixed_length: bool,
) -> (Body_Drain_Result, u32, u64) {
	result: Body_Drain_Result
	new_destination_size := destination_size
	new_body_size_received := body_size_received
	remaining_size := parser.body_size_remaining if fixed_length else parser.chunk_size_remaining
	if remaining_size == 0 {
		parser.phase = .Complete if fixed_length else .Chunk_Data_CRLF
		result.done = fixed_length
		return result, new_destination_size, new_body_size_received
	}

	available_size := min(len(network), int(remaining_size))
	if available_size == 0 {
		result.need_more = true
		return result, new_destination_size, new_body_size_received
	}

	next_body_size_received := new_body_size_received + u64(available_size)
	if next_body_size_received > u64(body_size_max) {
		result.body_too_large = true
		return result, new_destination_size, new_body_size_received
	}

	if buffered {
		next_destination_size := int(new_destination_size) + available_size
		if next_destination_size > len(destination) {
			result.body_too_large = true
			return result, new_destination_size, new_body_size_received
		}
		copy(destination[int(new_destination_size):][:available_size], network[:available_size])
		new_destination_size = u32(next_destination_size)
	} else {
		result.data_size = available_size
	}

	new_body_size_received = next_body_size_received
	result.consumed_size = available_size

	if fixed_length {
		parser.body_size_remaining -= u64(available_size)
		if parser.body_size_remaining == 0 {
			parser.phase = .Complete
			result.done = true
		}
		return result, new_destination_size, new_body_size_received
	}

	parser.chunk_size_remaining -= u64(available_size)
	if parser.chunk_size_remaining == 0 {
		parser.phase = .Chunk_Data_CRLF
	}
	return result, new_destination_size, new_body_size_received
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_drain_buffered_body :: proc(t: ^testing.T) {
	network_data := []u8{1, 2, 3, 4, 5, 6, 7, 8}

	// Test partial drain (budget < network)
	destination_small := make([]u8, 4)
	defer mem.delete(destination_small)
	copied_small := drain_buffered_body(network_data, destination_small)
	testing.expect_value(t, copied_small, 4)
	testing.expect_value(t, destination_small[0], 1)
	testing.expect_value(t, destination_small[3], 4)

	// Test full drain (budget > network)
	destination_large := make([]u8, 10)
	defer mem.delete(destination_large)
	copied_large := drain_buffered_body(network_data, destination_large)
	testing.expect_value(t, copied_large, 8)
	testing.expect_value(t, destination_large[7], 8)
}

@(test)
test_retain_pipeline_tail :: proc(t: ^testing.T) {
	// Simulate "GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\n\r\n"
	request_two := "GET /2 HTTP/1.1\r\n\r\n"
	unconsumed := transmute([]u8)request_two

	// Budget is large enough
	pipeline_region := make([]u8, 64)
	defer mem.delete(pipeline_region)

	retained_size, budget_exceeded := retain_pipeline_tail(unconsumed, pipeline_region)
	testing.expect_value(t, budget_exceeded, false)
	testing.expect_value(t, retained_size, len(request_two))
	testing.expect_value(t, string(pipeline_region[:retained_size]), request_two)

	// Budget is too small
	small_region := make([]u8, 4)
	defer mem.delete(small_region)

	retained_size_small, budget_exceeded_small := retain_pipeline_tail(unconsumed, small_region)
	testing.expect_value(t, budget_exceeded_small, true)
	testing.expect_value(t, retained_size_small, 0)
}

@(test)
test_drain_request_body_fixed_buffered :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Body_Fixed,
		body_size_remaining = 5,
	}
	destination := make([]u8, 8)
	defer mem.delete(destination)
	result: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	result, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("hello"),
		destination,
		destination_size,
		body_size_received,
		5,
		DEFAULT_PARSE_BUDGET,
		true,
	)

	testing.expect_value(t, result.protocol_error, false)
	testing.expect_value(t, result.body_too_large, false)
	testing.expect_value(t, result.done, true)
	testing.expect_value(t, parser.phase, Parse_Phase.Complete)
	testing.expect_value(t, destination_size, u32(5))
	testing.expect_value(t, string(destination[:int(destination_size)]), "hello")
}

@(test)
test_drain_request_body_chunked_streamed_emits_payload_then_trailer_completion :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size_line: Body_Drain_Result
	payload: Body_Drain_Result
	chunk_data_end: Body_Drain_Result
	zero_line: Body_Drain_Result
	trailers_end: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size_line, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size_line.protocol_error, false)
	testing.expect_value(t, size_line.consumed_size, 3)
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)

	payload, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("Wiki"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, payload.protocol_error, false)
	testing.expect_value(t, payload.data_size, 4)
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data_CRLF)

	chunk_data_end, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, chunk_data_end.protocol_error, false)
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Size)

	zero_line, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("0\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, zero_line.protocol_error, false)
	testing.expect_value(t, parser.phase, Parse_Phase.Trailers)

	trailers_end, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, trailers_end.protocol_error, false)
	testing.expect_value(t, trailers_end.done, true)
	testing.expect_value(t, parser.phase, Parse_Phase.Complete)
}

@(test)
test_drain_request_body_chunked_accepts_chunk_extension :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4;foo=bar\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("foo=bar\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, false)
	testing.expect_value(t, ext.consumed_size, len("foo=bar\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_accepts_size_line_trailing_whitespace :: proc(t: ^testing.T) {
	parser_space := Parser_State {
		phase = .Chunk_Size,
	}
	parser_tab := Parser_State {
		phase = .Chunk_Size,
	}
	space_first: Body_Drain_Result
	space_second: Body_Drain_Result
	tab_first: Body_Drain_Result
	tab_second: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	space_first, destination_size, body_size_received = drain_request_body(
		&parser_space,
		transmute([]u8)string("4 "),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, space_first.protocol_error, false)
	testing.expect_value(t, space_first.consumed_size, len("4 "))
	testing.expect_value(t, parser_space.phase, Parse_Phase.Chunk_Ext)

	space_second, destination_size, body_size_received = drain_request_body(
		&parser_space,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, space_second.protocol_error, false)
	testing.expect_value(t, space_second.consumed_size, len("\r\n"))
	testing.expect_value(t, parser_space.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser_space.phase, Parse_Phase.Chunk_Data)

	tab_first, destination_size, body_size_received = drain_request_body(
		&parser_tab,
		transmute([]u8)string("4\t"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, tab_first.protocol_error, false)
	testing.expect_value(t, tab_first.consumed_size, len("4\t"))
	testing.expect_value(t, parser_tab.phase, Parse_Phase.Chunk_Ext)

	tab_second, destination_size, body_size_received = drain_request_body(
		&parser_tab,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, tab_second.protocol_error, false)
	testing.expect_value(t, tab_second.consumed_size, len("\r\n"))
	testing.expect_value(t, parser_tab.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser_tab.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_accepts_extension_with_bws :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4 ; foo=bar\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4 "))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("; foo=bar\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, false)
	testing.expect_value(t, ext.consumed_size, len("; foo=bar\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_accepts_multiple_extensions :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4;foo=bar;baz=qux\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("foo=bar;baz=qux\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, false)
	testing.expect_value(t, ext.consumed_size, len("foo=bar;baz=qux\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_accepts_zero_chunk_with_extension :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("0;reason=done\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("0;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("reason=done\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, false)
	testing.expect_value(t, ext.consumed_size, len("reason=done\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(0))
	testing.expect_value(t, parser.phase, Parse_Phase.Trailers)
}

@(test)
test_drain_request_body_chunked_accepts_extension_quoted_string :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4;foo=\"hello world\"\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("foo=\"hello world\"\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, false)
	testing.expect_value(t, ext.consumed_size, len("foo=\"hello world\"\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_rejects_extension_ctl :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4;"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("\x01foo\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, true)
}

@(test)
test_drain_request_body_chunked_rejects_extension_budget_overflow :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4;"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	extension: [4097]u8
	for i in 0 ..< len(extension) {
		extension[i] = 'a'
	}
	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		extension[:],
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, true)
}

@(test)
test_drain_request_body_chunked_extension_survives_cr_fragmentation :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext_fragment: Body_Drain_Result
	ext_end: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4;foo\r"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4;"))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext_fragment, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("foo\r"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext_fragment.protocol_error, false)
	testing.expect_value(t, ext_fragment.consumed_size, len("foo"))
	testing.expect_value(t, ext_fragment.need_more, true)
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext_end, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext_end.protocol_error, false)
	testing.expect_value(t, ext_end.consumed_size, len("\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_accepts_size_line_extension_without_semicolon :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	size: Body_Drain_Result
	ext: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	size, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4 invalid\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, size.protocol_error, false)
	testing.expect_value(t, size.consumed_size, len("4 "))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Ext)

	ext, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("invalid\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, ext.protocol_error, false)
	testing.expect_value(t, ext.consumed_size, len("invalid\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_size_line_survives_cr_fragmentation :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	fragment_first: Body_Drain_Result
	fragment_second: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	fragment_first, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("4\r"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, fragment_first.protocol_error, false)
	testing.expect_value(t, fragment_first.need_more, true)
	testing.expect_value(t, fragment_first.consumed_size, len("4"))
	testing.expect_value(t, parser.chunk_size_parsed, u64(4))
	testing.expect_value(t, parser.chunk_size_digit_count, u8(1))

	fragment_second, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, fragment_second.protocol_error, false)
	testing.expect_value(t, fragment_second.consumed_size, len("\r\n"))
	testing.expect_value(t, parser.chunk_size_remaining, u64(4))
	testing.expect_value(t, parser.chunk_size_digit_count, u8(0))
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Data)
}

@(test)
test_drain_request_body_chunked_rejects_empty_size_line :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	result: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	result, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, result.protocol_error, true)
}

@(test)
test_drain_request_body_chunked_rejects_more_than_u64_hex_digits :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	fragment_first: Body_Drain_Result
	fragment_second: Body_Drain_Result
	destination_size: u32
	body_size_received: u64

	fragment_first, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("0000000000000000"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, fragment_first.protocol_error, false)
	testing.expect_value(t, fragment_first.need_more, true)
	testing.expect_value(t, parser.chunk_size_digit_count, CHUNK_SIZE_DIGIT_COUNT_MAXIMUM)

	fragment_second, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("0\r\n"),
		nil,
		destination_size,
		body_size_received,
		16,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, fragment_second.protocol_error, true)
}

@(test)
test_drain_request_body_chunked_rejects_chunk_size_over_body_budget :: proc(t: ^testing.T) {
	parser := Parser_State {
		phase = .Chunk_Size,
	}
	body_size_received := u64(3)
	destination_size: u32
	result: Body_Drain_Result

	result, destination_size, body_size_received = drain_request_body(
		&parser,
		transmute([]u8)string("3\r\n"),
		nil,
		destination_size,
		body_size_received,
		5,
		DEFAULT_PARSE_BUDGET,
		false,
	)
	testing.expect_value(t, result.body_too_large, true)
	testing.expect_value(t, parser.phase, Parse_Phase.Chunk_Size)
}
