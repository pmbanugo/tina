package http_server

import tina "../../.."
import "core:strings"

@(private = "package")
HTTP_INTERNAL_TAG_AWAIT_TIMEOUT :: tina.Message_Tag(0xFFFE)

@(private = "package")
_dispatch_route :: proc(request: ^Request, response: ^Response) -> Route_Step {
	state := request.connection_state
	runtime := state.shard_runtime
	if state == nil || runtime == nil || runtime.router == nil {
		return .Close
	}

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
		if len(runtime.router.options_asterisk_response) > 0 {
			copy(response.egress_buffer, runtime.router.options_asterisk_response)
			state.response.egress_size = Egress_Size(len(runtime.router.options_asterisk_response))
			state.response.egress_size_sent = 0
			state.response.flags += {.Headers_Committed}
			state.response.mode = .Closed
			return .Flush_Final
		}
		return .Close
	}

	if state.request.route_index == ROUTE_INDEX_NONE {
		path_bytes := request.frame[int(state.request.path_offset):][:int(state.request.path_size)]
		match_result := match_route(runtime.router, &state.request, path_bytes)
		#partial switch match_result.outcome {
		case .Found:
			state.request.route_index = match_result.route_index
		case .Method_Not_Allowed:
			if allow_value_write_and_stage(response, match_result.methods_mask) {
				return _normalize_route_step(respond_text(response, HTTP_STATUS_METHOD_NOT_ALLOWED, "Method Not Allowed"))
			}
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
	if descriptor.body_mode != .None && _known_body_size_exceeds_limit(state, descriptor) {
		state.response.flags += {.Close_After_Send}
		return _normalize_route_step(respond_text(response, HTTP_STATUS_CONTENT_TOO_LARGE, "Content Too Large"))
	}
	route_context := _make_route_context(state, request.tina_context)
	route_state := _route_state_ptr(state)
	if descriptor.handler_kind == .Event {
		if descriptor.body_mode == .Buffered && state.parser.phase != .Complete {
			return .Read_Body
		}
		handler := cast(Route_Event_Handler)descriptor.handler
		step := handler(Route_Event(Request_Start{}), request, response, route_context, route_state)
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
	state_connection := request.connection_state
	runtime := state_connection.shard_runtime
	if state_connection == nil || runtime == nil || runtime.router == nil {
		return .Close
	}
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
_make_route_context :: proc "contextless" (state: ^HTTP_Connection_State, ctx: ^tina.TinaContext) -> Route_Context {
	return Route_Context {
		connection_state = state,
		tina_context     = ctx,
	}
}

@(private = "file")
allow_value_write_and_stage :: proc(response: ^Response, methods_mask: Method_Mask) -> bool {
	allow_buffer: [128]u8
	allow_size := allow_value_write(allow_buffer[:], methods_mask)
	if allow_size == 0 {
		return false
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
	router, compile_error, _ := compile_router(routes)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	response_header_storage: [128]u8
	request_frame := transmute([]u8)string("FOO /missing HTTP/1.1\r\nHost: example\r\n\r\n")
	runtime := HTTP_Shard_Runtime{router = &router}
	connection_state := HTTP_Connection_State{
		shard_runtime          = &runtime,
		response_header_bytes  = response_header_storage[:],
		request = Request_State{
			method       = .GET,
			path_offset  = 4,
			path_size    = 8,
			route_index  = ROUTE_INDEX_NONE,
			status_flags = {.Unknown_Method},
		},
	}
	egress_buffer: [HTTP_EGRESS_BUFFER_SIZE]u8
	request := Request{
		connection_state = &connection_state,
		request_state    = &connection_state.request,
		frame            = request_frame,
	}
	response := Response{
		connection_state      = &connection_state,
		egress_buffer         = egress_buffer[:],
		response_header_bytes = response_header_storage[:],
	}

	step := _dispatch_route(&request, &response)
	testing.expect_value(t, step, Route_Step.Flush_Final)
	testing.expect_value(t, connection_state.response.status_code, HTTP_STATUS_NOT_IMPLEMENTED)
}

@(private = "file")
_dispatch_test_ok_handler :: proc(request: ^Request, response: ^Response) -> Route_Step {
	_ = request
	return respond_text(response, HTTP_STATUS_OK, "ok")
}

@(test)
test_dispatch_connection_close_marks_response_for_close_after_send :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET}, handler = rawptr(_dispatch_test_ok_handler)}}
	router, compile_error, _ := compile_router(routes)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	response_header_storage: [128]u8
	request_frame := transmute([]u8)string("GET /x HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n")
	runtime := HTTP_Shard_Runtime{router = &router}
	connection_state := HTTP_Connection_State{
		shard_runtime         = &runtime,
		response_header_bytes = response_header_storage[:],
		parser                = Parser_State{flags = {.Connection_Close}},
		request = Request_State{
			method      = .GET,
			path_offset = 4,
			path_size   = 2,
			route_index = ROUTE_INDEX_NONE,
		},
	}
	egress_buffer: [HTTP_EGRESS_BUFFER_SIZE]u8
	request := Request{
		connection_state = &connection_state,
		request_state    = &connection_state.request,
		frame            = request_frame,
	}
	response := Response{
		connection_state      = &connection_state,
		egress_buffer         = egress_buffer[:],
		response_header_bytes = response_header_storage[:],
	}

	step := _dispatch_route(&request, &response)
	testing.expect_value(t, step, Route_Step.Flush_Final)
	testing.expect(t, .Close_After_Send in connection_state.response.flags, "response must close after send")
	testing.expect(
		t,
		strings.index(string(egress_buffer[:int(connection_state.response.egress_size)]), "\r\nConnection: close\r\n") >= 0,
		"serialized response must advertise Connection: close",
	)
}
