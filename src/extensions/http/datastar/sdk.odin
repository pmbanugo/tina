package datastar

import http "../server"
import json "core:encoding/json"
import "core:fmt"
import "core:strings"

Event_Type :: enum {
	Patch_Elements,
	Patch_Signals,
}

Element_Patch_Mode :: enum {
	Outer,
	Inner,
	Replace,
	Prepend,
	Append,
	Before,
	After,
	Remove,
}

Element_Namespace :: enum {
	HTML,
	SVG,
	MathML,
}

Send_Options :: struct {
	event_id:          string,
	retry_duration_ms: u32, // 0 means Datastar default: 1000ms
}

Patch_Elements_Options :: struct {
	selector:                 string,
	mode:                     Element_Patch_Mode, // zero value: outer
	use_view_transition:      bool,
	view_transition_selector: string,
	namespace:                Element_Namespace, // zero value: html
	event_id:                 string,
	retry_duration_ms:        u32, // 0 means Datastar default: 1000ms
}

Patch_Signals_Options :: struct {
	only_if_missing:   bool,
	event_id:          string,
	retry_duration_ms: u32, // 0 means Datastar default: 1000ms
}

Script_Auto_Remove :: enum {
	Default,
	Enabled,
	Disabled,
}

Execute_Script_Options :: struct {
	auto_remove:       Script_Auto_Remove, // zero value: ADR default true
	attributes:        []string,
	event_id:          string,
	retry_duration_ms: u32, // 0 means Datastar default: 1000ms
}

ServerSentEventGenerator :: struct {
	request:  ^http.Request,
	response: ^http.Response,
}

DEFAULT_RETRY_DURATION_MS :: u32(1000)

Read_Signals_Error :: enum {
	None,
	Missing_Datastar_Query,
	Invalid_Percent_Encoding,
	Invalid_JSON,
	Unsupported_Method,
}

read_signals :: proc(request: ^http.Request, signals: ^$T) -> Read_Signals_Error {
	#partial switch http.method(request) {
	case .GET, .DELETE:
		allocator := http.request_scratch(request)
		decoded, ok := http.query_value_decoded(request, "datastar")
		if !ok do return .Invalid_Percent_Encoding
		if len(decoded) == 0 do return .Missing_Datastar_Query

		if err := json.unmarshal(decoded, signals, allocator = allocator); err != nil {
			return .Invalid_JSON
		}
		return .None

	case .POST, .PUT, .PATCH:
		body := http.body_buffered(request)
		if err := json.unmarshal(body, signals, allocator = http.request_scratch(request)); err != nil {
			return .Invalid_JSON
		}
		return .None
	}

	return .Unsupported_Method
}

server_sent_event_generator :: proc(request: ^http.Request, response: ^http.Response) -> ServerSentEventGenerator {
	_ = http.header_set(response, "Cache-Control", "no-cache")
	http.begin_stream(response, http.HTTP_STATUS_OK, "text/event-stream")
	return ServerSentEventGenerator{request = request, response = response}
}

send :: proc(generator: ^ServerSentEventGenerator, event_type: Event_Type, data_lines: []string, options := Send_Options{}) -> http.Route_Step {
	frame := format_event_frame(event_type, data_lines, options, context.temp_allocator)
	if int(http.write_bytes(generator.response, transmute([]u8)frame)) != len(frame) do return http.close()
	return http.flush()
}

patch_elements :: proc(generator: ^ServerSentEventGenerator, elements := "", options := Patch_Elements_Options{}) -> http.Route_Step {
	lines := strings.builder_make()
	defer strings.builder_destroy(&lines)

	append_patch_elements_data_lines(&lines, elements, options)
	data_lines := split_data_lines(strings.to_string(lines), context.temp_allocator)
	return send(
		generator,
		.Patch_Elements,
		data_lines,
		Send_Options{event_id = options.event_id, retry_duration_ms = options.retry_duration_ms},
	)
}

patch_signals :: proc(generator: ^ServerSentEventGenerator, signals: string, options := Patch_Signals_Options{}) -> http.Route_Step {
	lines := strings.builder_make()
	defer strings.builder_destroy(&lines)

	append_patch_signals_data_lines(&lines, signals, options)
	data_lines := split_data_lines(strings.to_string(lines), context.temp_allocator)
	return send(
		generator,
		.Patch_Signals,
		data_lines,
		Send_Options{event_id = options.event_id, retry_duration_ms = options.retry_duration_ms},
	)
}

execute_script :: proc(generator: ^ServerSentEventGenerator, script: string, options := Execute_Script_Options{}) -> http.Route_Step {
	elements := build_script_element(script, options, context.temp_allocator)
	return patch_elements(
		generator,
		elements,
		Patch_Elements_Options{
			selector          = "body",
			mode              = .Append,
			event_id          = options.event_id,
			retry_duration_ms = options.retry_duration_ms,
		},
	)
}

format_event_frame :: proc(event_type: Event_Type, data_lines: []string, options := Send_Options{}, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	append_event_frame(&builder, event_type, data_lines, options)
	return strings.to_string(builder)
}

append_event_frame :: proc(builder: ^strings.Builder, event_type: Event_Type, data_lines: []string, options := Send_Options{}) {
	strings.write_string(builder, "event: ")
	strings.write_string(builder, event_type_string(event_type))
	strings.write_byte(builder, '\n')

	if len(options.event_id) > 0 {
		strings.write_string(builder, "id: ")
		strings.write_string(builder, options.event_id)
		strings.write_byte(builder, '\n')
	}

	if options.retry_duration_ms != 0 && options.retry_duration_ms != DEFAULT_RETRY_DURATION_MS {
		fmt.sbprintf(builder, "retry: %d\n", options.retry_duration_ms)
	}

	for line in data_lines {
		strings.write_string(builder, "data: ")
		strings.write_string(builder, line)
		strings.write_byte(builder, '\n')
	}

	strings.write_byte(builder, '\n')
}

split_data_lines :: proc(value: string, allocator := context.allocator) -> []string {
	line_bytes := transmute([]u8)value
	if line_bytes[len(line_bytes)-1] == '\n' {
		line_bytes = line_bytes[:len(line_bytes)-1]
	}
	return strings.split_lines(string(line_bytes), allocator)
}

append_patch_elements_data_lines :: proc(builder: ^strings.Builder, elements: string, options := Patch_Elements_Options{}) {
	if options.mode != .Outer {
		fmt.sbprintf(builder, "mode %s\n", element_patch_mode_string(options.mode))
	}
	if len(options.selector) > 0 {
		fmt.sbprintf(builder, "selector %s\n", options.selector)
	}
	if options.use_view_transition {
		strings.write_string(builder, "useViewTransition true\n")
		if len(options.view_transition_selector) > 0 {
			fmt.sbprintf(builder, "viewTransitionSelector %s\n", options.view_transition_selector)
		}
	}
	if options.namespace != .HTML {
		fmt.sbprintf(builder, "namespace %s\n", element_namespace_string(options.namespace))
	}
	if len(elements) > 0 {
		append_prefixed_lines(builder, "elements ", elements)
	}
}

append_patch_signals_data_lines :: proc(builder: ^strings.Builder, signals: string, options := Patch_Signals_Options{}) {
	if options.only_if_missing {
		strings.write_string(builder, "onlyIfMissing true\n")
	}
	append_prefixed_lines(builder, "signals ", signals)
}

build_script_element :: proc(script: string, options := Execute_Script_Options{}, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `<script type="application/javascript"`)
	if script_auto_remove_enabled(options.auto_remove) {
		strings.write_string(&builder, ` data-effect="el.remove()"`)
	}
	for attribute in options.attributes {
		strings.write_byte(&builder, ' ')
		strings.write_string(&builder, attribute)
	}
	strings.write_byte(&builder, '>')
	strings.write_string(&builder, script)
	strings.write_string(&builder, `</script>`)
	return strings.to_string(builder)
}

append_prefixed_lines :: proc(builder: ^strings.Builder, prefix: string, value: string) {
	if len(value) == 0 do return

	bytes := transmute([]u8)value
	line_start := 0
	for index := 0; index < len(bytes); index += 1 {
		if bytes[index] != '\n' do continue
		strings.write_string(builder, prefix)
		strings.write_string(builder, string(bytes[line_start:index]))
		strings.write_byte(builder, '\n')
		line_start = index + 1
	}

	if line_start < len(bytes) {
		strings.write_string(builder, prefix)
		strings.write_string(builder, string(bytes[line_start:]))
		strings.write_byte(builder, '\n')
	}
}

event_type_string :: proc "contextless" (event_type: Event_Type) -> string {
	switch event_type {
	case .Patch_Elements:
		return "datastar-patch-elements"
	case .Patch_Signals:
		return "datastar-patch-signals"
	}
	return ""
}

element_patch_mode_string :: proc "contextless" (mode: Element_Patch_Mode) -> string {
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

element_namespace_string :: proc "contextless" (namespace: Element_Namespace) -> string {
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

script_auto_remove_enabled :: proc "contextless" (auto_remove: Script_Auto_Remove) -> bool {
	switch auto_remove {
	case .Default, .Enabled:
		return true
	case .Disabled:
		return false
	}
	return true
}
