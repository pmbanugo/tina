package http_server

import "core:strings"
import "core:testing"

// These are pre-baked HTTP/1.1 response frames the library writes when
// the response state machine cannot recover — typically
// after a `respond_*()` overflow or a response-header staging overflow.
//
// Each response unconditionally carries `Connection: close` because the
// framework's contract on these failures is to terminate the connection after
// the bytes flush. The body is the canonical short reason phrase; clients that
// need machine-readable error envelopes are expected to rely on the success
// path, which the application owns.
//
// The matching reason-phrase tables in `response.odin` and the parser-emitted
// `Parse_Status` error variants in `parser.odin` together cover the codes the
// library itself produces; this file is the byte-level source of truth for the
// fallback path.

// All entries follow the schema:
//   "HTTP/1.1 <code> <reason>\r\nContent-Length: <body_size>\r\nConnection: close\r\n\r\n<body>"
// The body is intentionally `<reason>` itself so the wire response is
// self-describing without consulting the status line.

@(private = "package")
ERROR_RESPONSE_400_BAD_REQUEST :: "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Request"

@(private = "package")
ERROR_RESPONSE_404_NOT_FOUND :: "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found"

@(private = "package")
ERROR_RESPONSE_405_METHOD_NOT_ALLOWED :: "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 18\r\nConnection: close\r\n\r\nMethod Not Allowed"

@(private = "package")
ERROR_RESPONSE_408_REQUEST_TIMEOUT :: "HTTP/1.1 408 Request Timeout\r\nContent-Length: 15\r\nConnection: close\r\n\r\nRequest Timeout"

@(private = "package")
ERROR_RESPONSE_413_CONTENT_TOO_LARGE :: "HTTP/1.1 413 Content Too Large\r\nContent-Length: 17\r\nConnection: close\r\n\r\nContent Too Large"

@(private = "package")
ERROR_RESPONSE_414_URI_TOO_LONG :: "HTTP/1.1 414 URI Too Long\r\nContent-Length: 12\r\nConnection: close\r\n\r\nURI Too Long"

@(private = "package")
ERROR_RESPONSE_417_EXPECTATION_FAILED :: "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 18\r\nConnection: close\r\n\r\nExpectation Failed"

@(private = "package")
ERROR_RESPONSE_431_HEADER_FIELDS_TOO_LARGE :: "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 31\r\nConnection: close\r\n\r\nRequest Header Fields Too Large"

@(private = "package")
ERROR_RESPONSE_500_INTERNAL_SERVER_ERROR :: "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\nConnection: close\r\n\r\nInternal Server Error"

@(private = "package")
ERROR_RESPONSE_501_NOT_IMPLEMENTED :: "HTTP/1.1 501 Not Implemented\r\nContent-Length: 15\r\nConnection: close\r\n\r\nNot Implemented"

@(private = "package")
ERROR_RESPONSE_503_SERVICE_UNAVAILABLE :: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nService Unavailable"

@(private = "package")
ERROR_RESPONSE_505_HTTP_VERSION_NOT_SUPPORTED :: "HTTP/1.1 505 HTTP Version Not Supported\r\nContent-Length: 26\r\nConnection: close\r\n\r\nHTTP Version Not Supported"


// Maps a `Parse_Status` error variant to the matching pre-baked fallback
// response bytes. The connection state machine uses this when a parse error
// terminates the request before any user code runs.
//
// Returns an empty string for non-error variants so misuse cannot accidentally
// emit a fallback frame on a healthy parse.
@(private = "package")
parse_error_response_bytes :: proc "contextless" (status: Parse_Status) -> string {
	switch status {
	case .Continue, .Need_More, .Headers_Done:
		return ""
	case .Error_Bad_Request:
		return ERROR_RESPONSE_400_BAD_REQUEST
	case .Error_Expectation:
		return ERROR_RESPONSE_417_EXPECTATION_FAILED
	case .Error_Header_Too_Large:
		return ERROR_RESPONSE_431_HEADER_FIELDS_TOO_LARGE
	case .Error_Not_Implemented:
		return ERROR_RESPONSE_501_NOT_IMPLEMENTED
	case .Error_Version:
		return ERROR_RESPONSE_505_HTTP_VERSION_NOT_SUPPORTED
	}
	return ""
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

// Each fallback response must conform to the literal schema:
//   begins with "HTTP/1.1 ", contains "Connection: close", terminates with
//   exactly one "\r\n\r\n" between headers and body, and the declared
//   `Content-Length` matches the actual body byte count. A drift here is a
//   hard wire-protocol bug because there is no formatter to catch it.

// Extracts the declared "Content-Length" header value and returns its parsed
// integer value plus the body bytes that follow the header terminator.
@(private = "file")
extract_content_length_and_body :: proc(
	response_bytes: string,
) -> (
	declared_size: int,
	body: string,
	parsed_ok: bool,
) {
	separator_offset := strings.index(response_bytes, "\r\n\r\n")
	if separator_offset < 0 do return 0, "", false
	body = response_bytes[separator_offset + 4:]

	header_block := response_bytes[:separator_offset]
	marker := "\r\nContent-Length: "
	marker_offset := strings.index(header_block, marker)
	if marker_offset < 0 do return 0, body, false

	value_start := marker_offset + len(marker)
	value_end := value_start
	for value_end < len(header_block) && header_block[value_end] != '\r' {
		value_end += 1
	}
	declared_size = 0
	for digit in header_block[value_start:value_end] {
		if digit < '0' || digit > '9' do return 0, body, false
		declared_size = declared_size * 10 + int(digit - '0')
	}
	return declared_size, body, true
}

@(test)
test_error_response_well_formed_400 :: proc(t: ^testing.T) {
	declared, body, ok := extract_content_length_and_body(ERROR_RESPONSE_400_BAD_REQUEST)
	testing.expect(t, ok, "Content-Length header must be parseable")
	testing.expect_value(t, declared, len(body))
	testing.expect_value(t, body, "Bad Request")
}

@(test)
test_error_response_well_formed_500 :: proc(t: ^testing.T) {
	declared, body, ok := extract_content_length_and_body(ERROR_RESPONSE_500_INTERNAL_SERVER_ERROR)
	testing.expect(t, ok, "Content-Length header must be parseable")
	testing.expect_value(t, declared, len(body))
	testing.expect_value(t, body, "Internal Server Error")
}

@(test)
test_error_response_all_have_close :: proc(t: ^testing.T) {
 all_responses := [?]string {
		ERROR_RESPONSE_400_BAD_REQUEST,
		ERROR_RESPONSE_404_NOT_FOUND,
		ERROR_RESPONSE_405_METHOD_NOT_ALLOWED,
		ERROR_RESPONSE_408_REQUEST_TIMEOUT,
		ERROR_RESPONSE_413_CONTENT_TOO_LARGE,
		ERROR_RESPONSE_414_URI_TOO_LONG,
		ERROR_RESPONSE_417_EXPECTATION_FAILED,
		ERROR_RESPONSE_431_HEADER_FIELDS_TOO_LARGE,
		ERROR_RESPONSE_500_INTERNAL_SERVER_ERROR,
		ERROR_RESPONSE_501_NOT_IMPLEMENTED,
		ERROR_RESPONSE_503_SERVICE_UNAVAILABLE,
		ERROR_RESPONSE_505_HTTP_VERSION_NOT_SUPPORTED,
	}
	for response_bytes in all_responses {
		declared, body, ok := extract_content_length_and_body(response_bytes)
		testing.expectf(
			t,
			ok,
			"each fallback must declare Content-Length: %q",
			response_bytes[:min(len(response_bytes), 40)],
		)
		testing.expectf(
			t,
			declared == len(body),
			"Content-Length must equal body byte count for: %q",
			response_bytes[:min(len(response_bytes), 40)],
		)
		// Connection: close must be present so the connection state machine
		// can rely on the wire frame instructing the peer to drop the socket.
		testing.expectf(
			t,
			strings.index(response_bytes, "\r\nConnection: close\r\n") >= 0,
			"Connection: close header missing from %q",
			response_bytes[:min(len(response_bytes), 40)],
		)
	}
}

@(test)
test_parse_error_response_bytes_mapping :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		parse_error_response_bytes(.Error_Bad_Request),
		ERROR_RESPONSE_400_BAD_REQUEST,
	)
	testing.expect_value(
		t,
		parse_error_response_bytes(.Error_Expectation),
		ERROR_RESPONSE_417_EXPECTATION_FAILED,
	)
	testing.expect_value(
		t,
		parse_error_response_bytes(.Error_Header_Too_Large),
		ERROR_RESPONSE_431_HEADER_FIELDS_TOO_LARGE,
	)
	testing.expect_value(
		t,
		parse_error_response_bytes(.Error_Not_Implemented),
		ERROR_RESPONSE_501_NOT_IMPLEMENTED,
	)
	testing.expect_value(
		t,
		parse_error_response_bytes(.Error_Version),
		ERROR_RESPONSE_505_HTTP_VERSION_NOT_SUPPORTED,
	)
	// Non-error variants must yield the empty string so a misuse cannot emit
	// a fallback frame on a healthy parse.
	testing.expect_value(t, parse_error_response_bytes(.Continue), "")
	testing.expect_value(t, parse_error_response_bytes(.Need_More), "")
	testing.expect_value(t, parse_error_response_bytes(.Headers_Done), "")
}
