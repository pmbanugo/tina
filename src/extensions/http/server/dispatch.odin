package http_server

import tina "../../.."

@(private = "package")
HTTP_INTERNAL_TAG_AWAIT_TIMEOUT :: tina.Message_Tag(0xFFFE)

@(private = "package")
_dispatch_route :: proc(request: ^Request, response: ^Response) -> Route_Step {
	state := request.connection_state
	runtime := state.shard_runtime
	if state == nil || runtime == nil || runtime.router == nil {
		return .Close
	}

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
			return _normalize_route_step(respond_text(response, HTTP_STATUS_NOT_FOUND, "Not Found"))
		}
	}

	if state.request.route_index == ROUTE_INDEX_NONE {
		return .Close
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.body_mode != .None {
		// The vertical slice only wires the zero-body `Request_Handler` path.
		return .Close
	}

	handler := cast(Request_Handler)descriptor.handler
	step := handler(request, response)
	return _normalize_route_step(step)
}

@(private = "file")
_normalize_route_step :: #force_inline proc "contextless" (step: Route_Step) -> Route_Step {
	#partial switch step {
	case .Flush, .Flush_Final, .Close:
		return step
	case:
		return .Close
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
