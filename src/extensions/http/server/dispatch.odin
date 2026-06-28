package http_server

import tina "../../.."
import "core:strings"

@(private = "package")
HTTP_INTERNAL_TAG_AWAIT_TIMEOUT :: tina.Message_Tag(0xFFFE)

@(private = "package")
_dispatch_route :: proc(request: ^Request, response: ^Response) -> Route_Step {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "_dispatch_route: request state is nil")
		assert(response != nil && response.connection != nil, "_dispatch_route: response connection is nil")
		assert(request.connection_state == &response.connection.connection_state, "_dispatch_route: request/response connection mismatch")
		assert(request.connection_state.shard_runtime != nil, "_dispatch_route: shard runtime is nil")
	}
	state := request.connection_state
	runtime := state.shard_runtime

	_apply_request_connection_policy(state)

	// `OPTIONS *` is a server-wide capability query. If an explicit handler was
	// registered, dispatch it; otherwise emit the canned response from the router.
	if .Options_Asterisk in state.request.status_flags {
		if runtime.router.options_asterisk_route_index != ROUTE_INDEX_NONE {
			state.request.route_index = runtime.router.options_asterisk_route_index
			descriptor := runtime.router.descriptors[state.request.route_index]
			handler := cast(Request_Handler)descriptor.handler
			step := handler(request, response)
			return _normalize_route_step(step)
		}
		if len(runtime.router.options_asterisk_allow) > 0 {
			_ = header_set(response, "Allow", string(runtime.router.options_asterisk_allow))
		}
		return _normalize_route_step(respond_text(response, HTTP_STATUS_NO_CONTENT, ""))
	}

	if state.request.route_index == ROUTE_INDEX_NONE {
		path_bytes := request.frame[int(state.request.path_offset):][:int(state.request.path_size)]
		match_result := match_route(&runtime.router, &state.request, path_bytes)
		#partial switch match_result.outcome {
		case .Found:
			state.request.route_index = match_result.route_index
		case .Method_Not_Allowed:
			_ = allow_value_write_and_stage(response, match_result.methods_mask)
			return _normalize_route_step(respond_text(response, HTTP_STATUS_METHOD_NOT_ALLOWED, "Method Not Allowed"))
		case .Not_Found:
			if .Unknown_Method in state.request.status_flags {
				return _normalize_route_step(respond_text(response, HTTP_STATUS_NOT_IMPLEMENTED, "Not Implemented"))
			}
			return _normalize_route_step(respond_text(response, HTTP_STATUS_NOT_FOUND, "Not Found"))
		}
	}

	if state.request.route_index == ROUTE_INDEX_NONE {
		return .Close
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.body_mode == .None && state.parser.phase != .Complete {
		state.response.flags += {.Close_After_Send}
	}
	if descriptor.body_mode != .None && _known_body_size_exceeds_limit(state, descriptor) {
		state.response.flags += {.Close_After_Send}
		return _normalize_route_step(respond_text(response, HTTP_STATUS_CONTENT_TOO_LARGE, "Content Too Large"))
	}
	route_context := _make_route_context(state)
	route_state := _route_state_ptr(state)
	if descriptor.handler_kind == .Event {
		if descriptor.body_mode == .Buffered && state.parser.phase != .Complete {
			return .Read_Body
		}
		handler := cast(Route_Event_Handler)descriptor.handler
		step := handler(Route_Event(Request_Start{}), request, response, route_context, route_state)
		if descriptor.body_mode == .Streamed && state.parser.phase != .Complete {
			if step == .Expect_Application {
				return .Close
			}
			if step != .Read_Body {
				state.response.flags += {.Close_After_Send}
			}
		}
		return _normalize_route_step(
			step,
			allow_read_body = descriptor.body_mode == .Streamed,
			allow_expect_application = true,
		)
	}
	if descriptor.body_mode == .Streamed {
		return .Close
	}
	if descriptor.body_mode == .Buffered && state.parser.phase != .Complete {
		return .Read_Body
	}

	handler := cast(Request_Handler)descriptor.handler
	step := handler(request, response)
	return _normalize_route_step(step)
}

@(private = "file")
_apply_request_connection_policy :: #force_inline proc "contextless" (state: ^HTTP_Connection_State) {
	if .Connection_Close in state.parser.flags {
		state.response.flags += {.Close_After_Send}
	}
}

@(private = "package")
_dispatch_route_event :: proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(request != nil && request.connection_state != nil, "_dispatch_route_event: request state is nil")
		assert(response != nil && response.connection != nil, "_dispatch_route_event: response connection is nil")
		assert(request.connection_state == route_context.connection_state, "_dispatch_route_event: route context state mismatch")
		assert(request.connection_state == &response.connection.connection_state, "_dispatch_route_event: request/response connection mismatch")
		assert(request.connection_state.shard_runtime != nil, "_dispatch_route_event: shard runtime is nil")
	}
	state_connection := request.connection_state
	runtime := state_connection.shard_runtime
	if state_connection.request.route_index == ROUTE_INDEX_NONE {
		return .Close
	}

	descriptor := runtime.router.descriptors[state_connection.request.route_index]
	if descriptor.handler_kind != .Event {
		return .Close
	}

	handler := cast(Route_Event_Handler)descriptor.handler
	step := handler(event, request, response, route_context, state)
	return _normalize_route_step(
		step,
		allow_read_body = descriptor.body_mode == .Streamed,
		allow_expect_application = true,
	)
}

@(private = "file")
_normalize_route_step :: #force_inline proc "contextless" (
	step: Route_Step,
	allow_read_body: bool = false,
	allow_expect_application: bool = false,
) -> Route_Step {
	#partial switch step {
	case .Flush, .Flush_Final, .Close:
		return step
	case .Read_Body:
		if allow_read_body {
			return step
		}
		return .Close
	case .Expect_Application:
		if allow_expect_application {
			return step
		}
		return .Close
	case:
		return .Close
	}
}

@(private = "file")
_known_body_size_exceeds_limit :: proc "contextless" (
	state: ^HTTP_Connection_State,
	descriptor: Route_Descriptor,
) -> bool {
	if state.parser.phase != .Body_Fixed {
		return false
	}
	return state.parser.body_size_remaining > u64(descriptor.body_size_max)
}

@(private = "package")
_route_state_ptr :: proc "contextless" (state: ^HTTP_Connection_State) -> rawptr {
	if len(state.route_state_bytes) == 0 {
		return nil
	}
	return raw_data(state.route_state_bytes)
}

@(private = "package")
_make_route_context :: proc (state: ^HTTP_Connection_State) -> Route_Context {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(state != nil, "_make_route_context: state is nil")
	}
	return Route_Context {
		connection_state = state,
	}
}

@(private = "file")
allow_value_write_and_stage :: proc(response: ^Response, methods_mask: Method_Mask) -> Header_Result {
	allow_buffer: [128]u8
	allow_size := allow_value_write(allow_buffer[:], methods_mask)
	if allow_size == 0 {
		return .Invalid_Name
	}
	return header_set(response, "Allow", string(allow_buffer[:allow_size]))
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

import "core:testing"

@(test)
test_dispatch_unknown_method_missing_path_returns_not_implemented :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET}}}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	request_frame := transmute([]u8)string("FOO /missing HTTP/1.1\r\nHost: example\r\n\r\n")
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.request = Request_State{
		method       = .GET,
		path_offset  = 4,
		path_size    = 8,
		route_index  = ROUTE_INDEX_NONE,
		status_flags = {.Unknown_Method},
	}
	Dispatch_Unknown_Method_Test_State :: struct {fixture: ^HTTP_Test_Fixture, request_frame: []u8, t: ^testing.T}
	dispatch_unknown_method_test_state := Dispatch_Unknown_Method_Test_State {
		fixture       = &fixture,
		request_frame = request_frame,
		t             = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&dispatch_unknown_method_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Dispatch_Unknown_Method_Test_State)user_data
			request := http_test_fixture_request(test_state.fixture, test_state.request_frame)
			response := http_test_fixture_response(test_state.fixture)
			step := _dispatch_route(&request, &response)
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
		},
	)
	testing.expect_value(t, fixture.connection.connection_state.response.status_code, HTTP_STATUS_NOT_IMPLEMENTED)
}

@(private = "file")
_dispatch_test_ok_handler :: proc(request: ^Request, response: ^Response) -> Route_Step {
	_ = request
	return respond_text(response, HTTP_STATUS_OK, "ok")
}

@(private = "file")
_dispatch_test_final_event_handler :: proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step {
	_ = event
	_ = request
	_ = route_context
	_ = state
	return respond_text(response, HTTP_STATUS_OK, "done")
}

@(private = "file")
_dispatch_test_expect_event_handler :: proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step {
	_ = event
	_ = request
	_ = response
	_ = route_context
	_ = state
	return .Expect_Application
}

@(test)
test_dispatch_connection_close_marks_response_for_close_after_send :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET}, handler = rawptr(_dispatch_test_ok_handler)}}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	request_frame := transmute([]u8)string("GET /x HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n")
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.parser = Parser_State{flags = {.Connection_Close}}
	fixture.connection.connection_state.request = Request_State{
		method      = .GET,
		path_offset = 4,
		path_size   = 2,
		route_index = ROUTE_INDEX_NONE,
	}
	Dispatch_Close_Test_State :: struct {fixture: ^HTTP_Test_Fixture, request_frame: []u8, t: ^testing.T}
	dispatch_close_test_state := Dispatch_Close_Test_State {
		fixture       = &fixture,
		request_frame = request_frame,
		t             = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&dispatch_close_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Dispatch_Close_Test_State)user_data
			request := http_test_fixture_request(test_state.fixture, test_state.request_frame)
			response := http_test_fixture_response(test_state.fixture)
			step := _dispatch_route(&request, &response)
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
		},
	)
	testing.expect(t, .Close_After_Send in fixture.connection.connection_state.response.flags, "response must close after send")
	testing.expect(
		t,
		strings.index(string(fixture.connection.egress_buffer[:fixture.connection.connection_state.response.egress_size]), "\r\nConnection: close\r\n") >= 0,
		"serialized response must advertise Connection: close",
	)
}

@(test)
test_dispatch_none_body_route_closes_after_response_when_body_present :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.POST}, handler = rawptr(_dispatch_test_ok_handler)}}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	request_frame := transmute([]u8)string("POST /x HTTP/1.1\r\nHost: example\r\nContent-Length: 4\r\n\r\n")
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.parser = Parser_State{
		phase               = .Body_Fixed,
		body_size_remaining = 4,
		flags               = {.Has_Content_Length},
	}
	fixture.connection.connection_state.request = Request_State{
		method      = .POST,
		path_offset = 5,
		path_size   = 2,
		route_index = ROUTE_INDEX_NONE,
	}
	Dispatch_None_Body_Test_State :: struct {fixture: ^HTTP_Test_Fixture, request_frame: []u8, t: ^testing.T}
	dispatch_none_body_test_state := Dispatch_None_Body_Test_State {
		fixture       = &fixture,
		request_frame = request_frame,
		t             = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&dispatch_none_body_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Dispatch_None_Body_Test_State)user_data
			request := http_test_fixture_request(test_state.fixture, test_state.request_frame)
			response := http_test_fixture_response(test_state.fixture)
			step := _dispatch_route(&request, &response)
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
		},
	)
	testing.expect(t, .Close_After_Send in fixture.connection.connection_state.response.flags, "unconsumed request body must close after response")
	testing.expect(
		t,
		strings.index(string(fixture.connection.egress_buffer[:fixture.connection.connection_state.response.egress_size]), "\r\nConnection: close\r\n") >= 0,
		"serialized response must advertise Connection: close when body is not consumed",
	)
}

@(test)
test_dispatch_streamed_route_final_response_before_body_closes_after_send :: proc(t: ^testing.T) {
	routes := []Route{
		{
			pattern       = "/x",
			methods_mask  = {.POST},
			handler       = rawptr(_dispatch_test_final_event_handler),
			handler_kind  = .Event,
			body_mode     = .Streamed,
			body_size_max = 16,
		},
	}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	request_frame := transmute([]u8)string("POST /x HTTP/1.1\r\nHost: example\r\nContent-Length: 4\r\n\r\n")
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.parser = Parser_State{
		phase               = .Body_Fixed,
		body_size_remaining = 4,
		flags               = {.Has_Content_Length},
	}
	fixture.connection.connection_state.request = Request_State{
		method      = .POST,
		path_offset = 5,
		path_size   = 2,
		route_index = ROUTE_INDEX_NONE,
	}
	Dispatch_Streamed_Test_State :: struct {fixture: ^HTTP_Test_Fixture, request_frame: []u8, t: ^testing.T}
	dispatch_streamed_test_state := Dispatch_Streamed_Test_State {
		fixture       = &fixture,
		request_frame = request_frame,
		t             = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&dispatch_streamed_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Dispatch_Streamed_Test_State)user_data
			request := http_test_fixture_request(test_state.fixture, test_state.request_frame)
			response := http_test_fixture_response(test_state.fixture)
			step := _dispatch_route(&request, &response)
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
		},
	)
	testing.expect(t, .Close_After_Send in fixture.connection.connection_state.response.flags, "early final streamed response must close")
}

@(test)
test_dispatch_streamed_route_cannot_park_before_consuming_body :: proc(t: ^testing.T) {
	routes := []Route{
		{
			pattern       = "/x",
			methods_mask  = {.POST},
			handler       = rawptr(_dispatch_test_expect_event_handler),
			handler_kind  = .Event,
			body_mode     = .Streamed,
			body_size_max = 16,
		},
	}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	request_frame := transmute([]u8)string("POST /x HTTP/1.1\r\nHost: example\r\nContent-Length: 4\r\n\r\n")
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.parser = Parser_State{
		phase               = .Body_Fixed,
		body_size_remaining = 4,
		flags               = {.Has_Content_Length},
	}
	fixture.connection.connection_state.request = Request_State{
		method      = .POST,
		path_offset = 5,
		path_size   = 2,
		route_index = ROUTE_INDEX_NONE,
	}
	request := http_test_fixture_request(&fixture, request_frame)
	response := http_test_fixture_response(&fixture)

	step := _dispatch_route(&request, &response)
	testing.expect_value(t, step, Route_Step.Close)
}

@(test)
test_dispatch_options_asterisk_implicit_response :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET}}}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture, router)
	fixture.connection.connection_state.request = Request_State{
		method       = .OPTIONS,
		status_flags = {.Options_Asterisk},
	}

	Options_Asterisk_Test_State :: struct {fixture: ^HTTP_Test_Fixture, t: ^testing.T}
	options_asterisk_test_state := Options_Asterisk_Test_State {fixture = &fixture, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = fixture.connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&options_asterisk_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Options_Asterisk_Test_State)user_data
			request := http_test_fixture_request(test_state.fixture)
			response := http_test_fixture_response(test_state.fixture)

			step := _dispatch_route(&request, &response)
			testing.expect_value(test_state.t, step, Route_Step.Flush_Final)
			state := test_state.fixture.connection.connection_state.response
			wire := string(test_state.fixture.connection.egress_buffer[:state.egress_size])
			testing.expect_value(test_state.t, state.status_code, HTTP_STATUS_NO_CONTENT)
			testing.expect(test_state.t, strings.index(wire, "Allow: GET, HEAD") >= 0)
			testing.expect(test_state.t, strings.index(wire, "Content-Length") < 0)
			testing.expect(test_state.t, strings.index(wire, "Transfer-Encoding") < 0)
		},
	)
}
