/* Adheres to Datastar SDK ADR from the commit in
https://github.com/starfederation/datastar/commit/850d0479e9479d437f13ded4ce0e191708b1a209
*/

package datastar

import tina "../../.."
import http "../server"
import "core:encoding/json"
import "core:strconv"
import "core:testing"

DATASTAR_EVENT_PATCH_ELEMENTS :: "datastar-patch-elements"
DATASTAR_EVENT_PATCH_SIGNALS :: "datastar-patch-signals"
DATASTAR_RETRY_DURATION_MS_DEFAULT :: u32(1000)

@(private = "file")
SSE_PREFIX_EVENT :: "event: "
@(private = "file")
SSE_PREFIX_ID :: "id: "
@(private = "file")
SSE_PREFIX_RETRY :: "retry: "
@(private = "file")
SSE_PREFIX_DATA :: "data: "
@(private = "file")
SSE_SCRIPT_DATA_PREFIX :: "data: elements "

Patch_Mode :: enum u8 {
	Outer,
	Inner,
	Replace,
	Prepend,
	Append,
	Before,
	After,
	Remove,
}

Namespace :: enum u8 {
	HTML,
	SVG,
	MathML,
}

Patch_Elements_Flag :: enum u8 {
	Use_View_Transition,
}
Patch_Elements_Flags :: distinct bit_set[Patch_Elements_Flag;u8]

Patch_Signals_Flag :: enum u8 {
	Only_If_Missing,
}
Patch_Signals_Flags :: distinct bit_set[Patch_Signals_Flag;u8]

Script_Lifetime :: enum u8 {
	Auto_Remove,
	Persistent,
}

@(private = "file")
Event_Type :: enum u8 {
	Patch_Elements,
	Patch_Signals,
}

SSE_Start_Error :: enum u8 {
	None,
	Invalid_Argument,
	Header_Staging_Failed,
	Begin_Failed,
}

SSE_Send_Error :: enum u8 {
	None,
	Invalid_Argument,
	Backpressured,
	Body_Too_Large,
	Body_Closed,
	Body_Mode_Invalid,
	Commit_Stale,
}

Read_Signals_Error :: enum u8 {
	None,
	Missing,
	Unsupported_Method,
	Invalid_JSON,
	Invalid_Argument,
}

Generator :: struct {
	response: ^http.Response,
}

ServerSentEventGenerator :: Generator

@(private = "file")
Send_Options :: struct {
	event_id:          string,
	retry_duration_ms: u32,
}

Patch_Elements_Options :: struct {
	selector:                 string,
	mode:                     Patch_Mode,
	flags:                    Patch_Elements_Flags,
	view_transition_selector: string,
	namespace:                Namespace,
	event_id:                 string,
	retry_duration_ms:        u32,
}

Patch_Signals_Options :: struct {
	flags:             Patch_Signals_Flags,
	event_id:          string,
	retry_duration_ms: u32,
}

Execute_Script_Options :: struct {
	lifetime:          Script_Lifetime,
	attributes:        []string,
	event_id:          string,
	retry_duration_ms: u32,
}

@(private = "file")
Data_Field :: struct {
	name:  string,
	value: string,
}

@(private = "file")
Script_Payload :: struct {
	content:    string,
	attributes: []string,
	lifetime:   Script_Lifetime,
}

@(require_results)
start_sse :: proc(
	request: ^http.Request, // TODO: remove because this parameter isn't used.
	response: ^http.Response,
) -> (
	generator: Generator,
	error: SSE_Start_Error,
) {
	_ = request
	if response == nil {
		return generator, .Invalid_Argument
	}
	if header_error := http.header_set(response, "Cache-Control", "no-cache");
	   header_error != .Staged {
		return generator, .Header_Staging_Failed
	}
	if header_error := http.header_set(response, "X-Accel-Buffering", "no");
	   header_error != .Staged {
		return generator, .Header_Staging_Failed
	}
	if begin_error := http.begin_stream(response, http.HTTP_STATUS_OK, "text/event-stream");
	   begin_error != .Begun {
		return generator, .Begin_Failed
	}
	return Generator{response = response}, .None
}

resume :: #force_inline proc(response: ^http.Response) -> Generator {
	return Generator{response = response}
}

@(require_results)
patch_elements :: proc(
	generator: ^Generator,
	elements: string,
	options: Patch_Elements_Options = {},
) -> SSE_Send_Error {
	if generator == nil || generator.response == nil {
		return .Invalid_Argument
	}
	if len(elements) == 0 && options.mode != .Remove {
		return .Invalid_Argument
	}

	fields: [5]Data_Field
	field_count := 0
	if len(options.selector) != 0 {
		fields[field_count] = Data_Field {
			name  = "selector",
			value = options.selector,
		}
		field_count += 1
	}
	if options.mode != .Outer {
		fields[field_count] = Data_Field {
			name  = "mode",
			value = patch_mode_string(options.mode),
		}
		field_count += 1
	}
	if .Use_View_Transition in options.flags {
		fields[field_count] = Data_Field {
			name  = "useViewTransition",
			value = "true",
		}
		field_count += 1
		if len(options.view_transition_selector) != 0 {
			fields[field_count] = Data_Field {
				name  = "viewTransitionSelector",
				value = options.view_transition_selector,
			}
			field_count += 1
		}
	}
	if options.namespace != .HTML {
		fields[field_count] = Data_Field {
			name  = "namespace",
			value = namespace_string(options.namespace),
		}
		field_count += 1
	}

	send_options := Send_Options {
		event_id          = options.event_id,
		retry_duration_ms = options.retry_duration_ms,
	}
	return _send_event(
		generator,
		.Patch_Elements,
		fields[:field_count],
		"elements",
		elements,
		{},
		send_options,
	)
}

@(require_results)
patch_signals :: proc(
	generator: ^Generator,
	signals: string,
	options: Patch_Signals_Options = {},
) -> SSE_Send_Error {
	if generator == nil || generator.response == nil || len(signals) == 0 {
		return .Invalid_Argument
	}

	fields: [1]Data_Field
	field_count := 0
	if .Only_If_Missing in options.flags {
		fields[field_count] = Data_Field {
			name  = "onlyIfMissing",
			value = "true",
		}
		field_count += 1
	}

	send_options := Send_Options {
		event_id          = options.event_id,
		retry_duration_ms = options.retry_duration_ms,
	}
	return _send_event(
		generator,
		.Patch_Signals,
		fields[:field_count],
		"signals",
		signals,
		{},
		send_options,
	)
}

@(require_results)
execute_script :: proc(
	generator: ^Generator,
	script: string,
	options: Execute_Script_Options = {},
) -> SSE_Send_Error {
	if generator == nil || generator.response == nil || len(script) == 0 {
		return .Invalid_Argument
	}

	fields := [?]Data_Field{{name = "mode", value = "append"}, {name = "selector", value = "body"}}
	script_payload := Script_Payload {
		content    = script,
		attributes = options.attributes,
		lifetime   = options.lifetime,
	}
	send_options := Send_Options {
		event_id          = options.event_id,
		retry_duration_ms = options.retry_duration_ms,
	}
	return _send_event(generator, .Patch_Elements, fields[:], "", "", script_payload, send_options)
}

@(require_results)
read_signals :: proc(request: ^http.Request, signals: ^$T) -> Read_Signals_Error {
	if request == nil || signals == nil {
		return .Invalid_Argument
	}

	signal_bytes: []u8
	#partial switch http.method(request) {
	case .GET, .DELETE:
		decoded, query_result := http.query_value_decoded(request, "datastar")
		switch query_result {
		case .Found:
			signal_bytes = decoded
		case .Not_Found:
			return .Missing
		case .Decode_Error:
			return .Invalid_JSON
		}
	case .POST, .PUT, .PATCH:
		signal_bytes = http.body_buffered(request)
		if len(signal_bytes) == 0 {
			return .Missing
		}
	case:
		return .Unsupported_Method
	}

	if error := json.unmarshal(signal_bytes, signals, .JSON, http.request_arena(request));
	   error != nil {
		return .Invalid_JSON
	}
	return .None
}

@(require_results, private = "file")
_send_event :: proc(
	generator: ^Generator,
	event_type: Event_Type,
	fields: []Data_Field,
	line_name: string,
	lines: string,
	script: Script_Payload,
	options: Send_Options,
) -> SSE_Send_Error {
	event_size := _emit_event_payload(
		false,
		nil,
		event_type,
		fields,
		line_name,
		lines,
		script,
		options,
	)
	if event_size > int(max(u32)) {
		return .Body_Too_Large
	}
	reservation, reserve_result := http.reserve_body_exact(generator.response, u32(event_size))
	switch reserve_result {
	case .Reserved:
		written := _emit_event_payload(
			true,
			reservation.payload,
			event_type,
			fields,
			line_name,
			lines,
			script,
			options,
		)
		when tina.TINA_RUNTIME_ASSERTIONS {
			assert(written == event_size, "datastar: measured and written event sizes diverged")
		}
		if commit_result := http.commit_body(generator.response, reservation);
		   commit_result != .Committed {
			return .Commit_Stale
		}
		return .None
	case .Suppressed:
		return .None
	case .Backpressured:
		return .Backpressured
	case .Body_Too_Large:
		return .Body_Too_Large
	case .Closed:
		return .Body_Closed
	case .Invalid_Mode:
		return .Body_Mode_Invalid
	}
	return .Body_Mode_Invalid
}

@(private = "file")
_emit_event_payload :: proc(
	$WRITE: bool,
	destination: []u8,
	event_type: Event_Type,
	fields: []Data_Field,
	line_name: string,
	lines: string,
	script: Script_Payload,
	options: Send_Options,
) -> int {
	cursor := _emit_event_begin(WRITE, destination, event_type, options)
	for field in fields {
		cursor = _emit_data_field(WRITE, destination, cursor, field.name, field.value)
	}
	if len(script.content) != 0 {
		cursor = _emit_script_element(WRITE, destination, cursor, script)
	} else if len(lines) != 0 {
		cursor = _emit_data_lines(WRITE, destination, cursor, line_name, lines)
	}
	return _emit_byte(WRITE, destination, cursor, '\n')
}

@(private = "file")
_emit_event_begin :: proc(
	$WRITE: bool,
	destination: []u8,
	event_type: Event_Type,
	options: Send_Options,
) -> int {
	cursor := 0
	cursor = _emit_literal(WRITE, destination, cursor, SSE_PREFIX_EVENT)
	cursor = _emit_literal(WRITE, destination, cursor, event_type_string(event_type))
	cursor = _emit_byte(WRITE, destination, cursor, '\n')
	if len(options.event_id) != 0 {
		cursor = _emit_literal(WRITE, destination, cursor, SSE_PREFIX_ID)
		cursor = _emit_literal(WRITE, destination, cursor, options.event_id)
		cursor = _emit_byte(WRITE, destination, cursor, '\n')
	}
	if retry_duration_ms_is_non_default(options.retry_duration_ms) {
		cursor = _emit_literal(WRITE, destination, cursor, SSE_PREFIX_RETRY)
		retry_buffer: [10]u8
		retry_bytes := strconv.write_uint(retry_buffer[:], u64(options.retry_duration_ms), 10)
		// string(retry_bytes) lives on the stack for the duration of this call;
		// it is consumed immediately by _emit_literal and then discarded.
		cursor = _emit_literal(WRITE, destination, cursor, string(retry_bytes))
		cursor = _emit_byte(WRITE, destination, cursor, '\n')
	}
	return cursor
}

@(private = "file")
_emit_data_field :: proc(
	$WRITE: bool,
	destination: []u8,
	cursor: int,
	field_name: string,
	field_value: string,
) -> int {
	write_index := cursor
	write_index = _emit_literal(WRITE, destination, write_index, SSE_PREFIX_DATA)
	write_index = _emit_literal(WRITE, destination, write_index, field_name)
	write_index = _emit_byte(WRITE, destination, write_index, ' ')
	write_index = _emit_literal(WRITE, destination, write_index, field_value)
	return _emit_byte(WRITE, destination, write_index, '\n')
}

@(private = "file")
_emit_data_lines :: proc(
	$WRITE: bool,
	destination: []u8,
	cursor: int,
	field_name: string,
	data: string,
) -> int {
	write_index := cursor
	data_bytes := transmute([]u8)data
	line_begin := 0
	for line_end in 0 ..< len(data_bytes) {
		if data_bytes[line_end] != '\n' {
			continue
		}
		line := line_trim_end_cr(data_bytes[line_begin:line_end])
		write_index = _emit_data_field(
			WRITE,
			destination,
			write_index,
			field_name,
			transmute(string)line,
		)
		line_begin = line_end + 1
	}
	if line_begin < len(data_bytes) {
		line := line_trim_end_cr(data_bytes[line_begin:])
		write_index = _emit_data_field(
			WRITE,
			destination,
			write_index,
			field_name,
			transmute(string)line,
		)
	}
	return write_index
}

@(private = "file")
_emit_script_element :: proc(
	$WRITE: bool,
	destination: []u8,
	cursor: int,
	script: Script_Payload,
) -> int {
	write_index := cursor
	write_index = _emit_literal(WRITE, destination, write_index, SSE_SCRIPT_DATA_PREFIX)
	write_index = _emit_literal(WRITE, destination, write_index, "<script")
	for attribute in script.attributes {
		if len(attribute) == 0 do continue
		write_index = _emit_byte(WRITE, destination, write_index, ' ')
		write_index = _emit_literal(WRITE, destination, write_index, attribute)
	}
	if script.lifetime == .Auto_Remove {
		write_index = _emit_literal(
			WRITE,
			destination,
			write_index,
			" data-effect=\"el.remove()\"",
		)
	}
	write_index = _emit_byte(WRITE, destination, write_index, '>')

	script_bytes := transmute([]u8)script.content
	line_begin := 0
	for line_end in 0 ..< len(script_bytes) {
		if script_bytes[line_end] != '\n' {
			continue
		}
		line := line_trim_end_cr(script_bytes[line_begin:line_end])
		write_index = _emit_literal(WRITE, destination, write_index, transmute(string)line)
		write_index = _emit_byte(WRITE, destination, write_index, '\n')
		write_index = _emit_literal(WRITE, destination, write_index, SSE_SCRIPT_DATA_PREFIX)
		line_begin = line_end + 1
	}
	if line_begin < len(script_bytes) {
		line := line_trim_end_cr(script_bytes[line_begin:])
		write_index = _emit_literal(WRITE, destination, write_index, transmute(string)line)
	}
	return _emit_literal(WRITE, destination, write_index, "</script>\n")
}

@(private = "file")
_emit_byte :: #force_inline proc "contextless" (
	$WRITE: bool,
	destination: []u8,
	cursor: int,
	value: u8,
) -> int {
	when WRITE {
		#no_bounds_check destination[cursor] = value
	}
	return cursor + 1
}

@(private = "file")
_emit_literal :: #force_inline proc "contextless" (
	$WRITE: bool,
	destination: []u8,
	cursor: int,
	value: string,
) -> int {
	when WRITE {
		#no_bounds_check if len(value) > 0 do copy(destination[cursor:], transmute([]u8)value)
	}
	return cursor + len(value)
}

@(private = "file")
line_trim_end_cr :: #force_inline proc "contextless" (line: []u8) -> []u8 {
	if len(line) != 0 && line[len(line) - 1] == '\r' {
		return line[:len(line) - 1]
	}
	return line
}

@(private = "file")
retry_duration_ms_is_non_default :: #force_inline proc "contextless" (
	retry_duration_ms: u32,
) -> bool {
	return retry_duration_ms != 0 && retry_duration_ms != DATASTAR_RETRY_DURATION_MS_DEFAULT
}

@(private = "file")
event_type_string :: #force_inline proc "contextless" (event_type: Event_Type) -> string {
	switch event_type {
	case .Patch_Elements:
		return DATASTAR_EVENT_PATCH_ELEMENTS
	case .Patch_Signals:
		return DATASTAR_EVENT_PATCH_SIGNALS
	}
	return ""
}

@(private = "file")
patch_mode_string :: #force_inline proc "contextless" (mode: Patch_Mode) -> string {
	switch mode {
	case .Outer:
		return "outer"
	case .Inner:
		return "inner"
	case .Replace:
		return "replace"
	case .Prepend:
		return "prepend"
	case .Append:
		return "append"
	case .Before:
		return "before"
	case .After:
		return "after"
	case .Remove:
		return "remove"
	}
	return ""
}

@(private = "file")
namespace_string :: #force_inline proc "contextless" (namespace: Namespace) -> string {
	switch namespace {
	case .HTML:
		return "html"
	case .SVG:
		return "svg"
	case .MathML:
		return "mathml"
	}
	return ""
}

@(test)
test_patch_mode_strings_match_datastar_wire_values :: proc(t: ^testing.T) {
	testing.expect_value(t, patch_mode_string(.Outer), "outer")
	testing.expect_value(t, patch_mode_string(.Inner), "inner")
	testing.expect_value(t, patch_mode_string(.Append), "append")
	testing.expect_value(t, patch_mode_string(.Remove), "remove")
}

@(test)
test_namespace_strings_match_datastar_wire_values :: proc(t: ^testing.T) {
	testing.expect_value(t, namespace_string(.HTML), "html")
	testing.expect_value(t, namespace_string(.SVG), "svg")
	testing.expect_value(t, namespace_string(.MathML), "mathml")
}

@(test)
test_event_payload_serializes_patch_elements_in_one_buffer :: proc(t: ^testing.T) {
	fields := [?]Data_Field {
		{name = "selector", value = "#feed"},
		{name = "mode", value = "append"},
	}
	options := Send_Options {
		event_id          = "123",
		retry_duration_ms = 2000,
	}
	elements := "<div>one</div>\n<div>two</div>"
	size := _emit_event_payload(
		false,
		nil,
		.Patch_Elements,
		fields[:],
		"elements",
		elements,
		{},
		options,
	)

	buffer: [512]u8
	written := _emit_event_payload(
		true,
		buffer[:size],
		.Patch_Elements,
		fields[:],
		"elements",
		elements,
		{},
		options,
	)

	testing.expect_value(t, written, size)
	testing.expect_value(
		t,
		string(buffer[:written]),
		"event: datastar-patch-elements\n" +
		"id: 123\n" +
		"retry: 2000\n" +
		"data: selector #feed\n" +
		"data: mode append\n" +
		"data: elements <div>one</div>\n" +
		"data: elements <div>two</div>\n" +
		"\n",
	)
}

@(test)
test_script_event_serializes_auto_remove_and_attributes :: proc(t: ^testing.T) {
	fields := [?]Data_Field{{name = "mode", value = "append"}, {name = "selector", value = "body"}}
	options := Execute_Script_Options {
		attributes = []string{"type=\"application/javascript\""},
	}
	send_options := Send_Options{}
	script := Script_Payload {
		content    = "one()\ntwo()",
		attributes = options.attributes,
		lifetime   = options.lifetime,
	}
	size := _emit_event_payload(
		false,
		nil,
		.Patch_Elements,
		fields[:],
		"",
		"",
		script,
		send_options,
	)

	buffer: [512]u8
	written := _emit_event_payload(
		true,
		buffer[:size],
		.Patch_Elements,
		fields[:],
		"",
		"",
		script,
		send_options,
	)

	testing.expect_value(t, written, size)
	testing.expect_value(
		t,
		string(buffer[:written]),
		"event: datastar-patch-elements\n" +
		"data: mode append\n" +
		"data: selector body\n" +
		"data: elements <script type=\"application/javascript\" data-effect=\"el.remove()\">one()\n" +
		"data: elements two()</script>\n" +
		"\n",
	)
}

@(test)
test_script_event_persistent_lifetime_omits_remove_effect :: proc(t: ^testing.T) {
	fields := [?]Data_Field{{name = "mode", value = "append"}, {name = "selector", value = "body"}}
	script := Script_Payload {
		content  = "console.log('hi')",
		lifetime = .Persistent,
	}
	send_options := Send_Options{}
	size := _emit_event_payload(
		false,
		nil,
		.Patch_Elements,
		fields[:],
		"",
		"",
		script,
		send_options,
	)

	buffer: [512]u8
	written := _emit_event_payload(
		true,
		buffer[:size],
		.Patch_Elements,
		fields[:],
		"",
		"",
		script,
		send_options,
	)

	testing.expect_value(t, written, size)
	testing.expect_value(
		t,
		string(buffer[:written]),
		"event: datastar-patch-elements\n" +
		"data: mode append\n" +
		"data: selector body\n" +
		"data: elements <script>console.log('hi')</script>\n" +
		"\n",
	)
}

@(test)
test_default_options_omit_id_and_retry :: proc(t: ^testing.T) {
	fields := [?]Data_Field{{name = "selector", value = "#feed"}}
	send_options := Send_Options{}
	elements := "<div></div>"
	size := _emit_event_payload(
		false,
		nil,
		.Patch_Elements,
		fields[:],
		"elements",
		elements,
		{},
		send_options,
	)

	buffer: [512]u8
	written := _emit_event_payload(
		true,
		buffer[:size],
		.Patch_Elements,
		fields[:],
		"elements",
		elements,
		{},
		send_options,
	)

	testing.expect_value(t, written, size)
	testing.expect_value(
		t,
		string(buffer[:written]),
		"event: datastar-patch-elements\n" +
		"data: selector #feed\n" +
		"data: elements <div></div>\n" +
		"\n",
	)
}

@(test)
test_crlf_line_endings_are_normalized :: proc(t: ^testing.T) {
	fields := [?]Data_Field{}
	send_options := Send_Options{}
	elements := "a\r\nb\r\nc"
	size := _emit_event_payload(
		false,
		nil,
		.Patch_Elements,
		fields[:],
		"elements",
		elements,
		{},
		send_options,
	)

	buffer: [512]u8
	written := _emit_event_payload(
		true,
		buffer[:size],
		.Patch_Elements,
		fields[:],
		"elements",
		elements,
		{},
		send_options,
	)

	testing.expect_value(t, written, size)
	testing.expect_value(
		t,
		string(buffer[:written]),
		"event: datastar-patch-elements\n" +
		"data: elements a\n" +
		"data: elements b\n" +
		"data: elements c\n" +
		"\n",
	)
}
