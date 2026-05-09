package datastar

import "core:strings"
import "core:testing"

@(test)
test_format_event_frame_minimal_patch_elements :: proc(t: ^testing.T) {
	lines := []string{"elements <div id=\"feed\"><span>1</span></div>"}
	frame := format_event_frame(.Patch_Elements, lines, allocator = context.temp_allocator)

	expected := "event: datastar-patch-elements\ndata: elements <div id=\"feed\"><span>1</span></div>\n\n"
	testing.expect_value(t, frame, expected)
}

@(test)
test_format_event_frame_full_order :: proc(t: ^testing.T) {
	lines := []string{
		"mode inner",
		"selector #feed",
		"elements <div id=\"feed\">",
		"elements     <span>1</span>",
		"elements </div>",
	}
	frame := format_event_frame(
		.Patch_Elements,
		lines,
		Send_Options{event_id = "123", retry_duration_ms = 2000},
		allocator = context.temp_allocator,
	)

	expected := "event: datastar-patch-elements\nid: 123\nretry: 2000\ndata: mode inner\ndata: selector #feed\ndata: elements <div id=\"feed\">\ndata: elements     <span>1</span>\ndata: elements </div>\n\n"
	testing.expect_value(t, frame, expected)
}

@(test)
test_patch_elements_data_lines_include_only_non_defaults :: proc(t: ^testing.T) {
	frame := format_patch_elements_for_test(
		"<circle id=\"c1\" cx=\"10\" r=\"5\"/>",
		Patch_Elements_Options{
			selector                 = "#vis",
			mode                     = .Append,
			use_view_transition      = true,
			view_transition_selector = "#main",
			namespace                = .SVG,
		},
	)

	expected := "event: datastar-patch-elements\ndata: mode append\ndata: selector #vis\ndata: useViewTransition true\ndata: viewTransitionSelector #main\ndata: namespace svg\ndata: elements <circle id=\"c1\" cx=\"10\" r=\"5\"/>\n\n"
	testing.expect_value(t, frame, expected)
}

@(test)
test_patch_signals_data_lines :: proc(t: ^testing.T) {
	frame := format_patch_signals_for_test(
		`{"output":"Patched Output Test","show":true}`,
		Patch_Signals_Options{only_if_missing = true},
	)

	expected := "event: datastar-patch-signals\ndata: onlyIfMissing true\ndata: signals {\"output\":\"Patched Output Test\",\"show\":true}\n\n"
	testing.expect_value(t, frame, expected)
}

@(test)
test_execute_script_builds_patch_elements_script :: proc(t: ^testing.T) {
	elements := build_script_element("console.log('Here')", Execute_Script_Options{}, context.temp_allocator)
	frame := format_patch_elements_for_test(
		elements,
		Patch_Elements_Options{selector = "body", mode = .Append},
	)

	expected := "event: datastar-patch-elements\ndata: mode append\ndata: selector body\ndata: elements <script type=\"application/javascript\" data-effect=\"el.remove()\">console.log('Here')</script>\n\n"
	testing.expect_value(t, frame, expected)
}

format_patch_elements_for_test :: proc(elements: string, options := Patch_Elements_Options{}) -> string {
	builder := strings.builder_make(context.temp_allocator)
	append_patch_elements_data_lines(&builder, elements, options)
	data_lines := split_data_lines(strings.to_string(builder), context.temp_allocator)
	return format_event_frame(
		.Patch_Elements,
		data_lines,
		Send_Options{event_id = options.event_id, retry_duration_ms = options.retry_duration_ms},
		allocator = context.temp_allocator,
	)
}

format_patch_signals_for_test :: proc(signals: string, options := Patch_Signals_Options{}) -> string {
	builder := strings.builder_make(context.temp_allocator)
	append_patch_signals_data_lines(&builder, signals, options)
	data_lines := split_data_lines(strings.to_string(builder), context.temp_allocator)
	return format_event_frame(
		.Patch_Signals,
		data_lines,
		Send_Options{event_id = options.event_id, retry_duration_ms = options.retry_duration_ms},
		allocator = context.temp_allocator,
	)
}
