package http_server

import tina "../../.."

@(private = "package")
_http_connection_init :: proc(self: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	connection := cast(^HTTP_Connection)self
	if len(args) < size_of(HTTP_Connection_Init_Args) {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	init_args := (cast(^HTTP_Connection_Init_Args)raw_data(args))^
	runtime := init_args.shard_runtime
	if runtime == nil {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	working_allocator := tina.ctx_working_arena(ctx)
	connection.connection_state.shard_runtime = runtime
	connection.connection_state.fd = init_args.client_fd
	connection.connection_state.header_views = make([]Header_View, int(runtime.server.limits.header_count_max), working_allocator)
	connection.connection_state.response_header_bytes = make(
		[]u8,
		int(runtime.server.limits.response_header_bytes_max),
		working_allocator,
	)
	connection.connection_state.peer = {}
	_connection_begin_request(connection)

	return tina.Effect_Io {
		operation = tina.IoOp_Recv {
			fd              = init_args.client_fd,
			buffer_size_max = u32(runtime.server.limits.request_line_size_max) + u32(runtime.server.limits.header_size_max),
		},
	}
}

@(private = "package")
_http_connection_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	connection := cast(^HTTP_Connection)self
	state := &connection.connection_state

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		state.response.flags += {.In_Drain, .Close_After_Send}
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}

	case tina.IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		return _connection_handle_recv_complete(connection, ctx, message.io.buffer_index, u32(message.io.result))

	case tina.IO_TAG_SEND_COMPLETE:
		if message.io.result <= 0 {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		return _connection_handle_send_complete(connection, u32(message.io.result))

	case tina.IO_TAG_CLOSE_COMPLETE:
		_connection_release_slot(state)
		return tina.Effect_Done{}

	case:
		return tina.Effect_Receive{}
	}
}

@(private = "file")
_connection_handle_recv_complete :: proc(
	connection: ^HTTP_Connection,
	ctx: ^tina.TinaContext,
	buffer_index: u16,
	buffer_size: u32,
) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	buffer := tina.ctx_read_buffer(ctx, buffer_index, buffer_size)
	if len(buffer) == 0 {
		return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(runtime)}}
	}

	parse_status, _ := parse_step(&state.parser, &state.request, state.header_views, buffer, 0, runtime.server.limits)
	#partial switch parse_status {
	case .Need_More:
		return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(runtime)}}

	case .Headers_Done:
		request := _connection_make_request(connection, buffer, ctx)
		response := _connection_make_response(connection)
		if state.request.method == .HEAD {
			state.response.mode = .Head_Suppressed
		}
		step := _dispatch_route(&request, &response)
		return _connection_interpret_step(connection, step)

	case .Error_Bad_Request, .Error_Expectation, .Error_Header_Too_Large, .Error_Not_Implemented, .Error_Version:
		return _connection_send_parse_error(connection, parse_status)

	case:
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}
}

@(private = "package")
_connection_dispatch_match :: proc(
	connection: ^HTTP_Connection,
	ctx: ^tina.TinaContext,
	frame: []u8,
	match_result: Match_Result,
) -> tina.Effect {
	state := &connection.connection_state
	response := _connection_make_response(connection)
	request := _connection_make_request(connection, frame, ctx)

	#partial switch match_result.outcome {
	case .Found:
		state.request.route_index = match_result.route_index
		if state.request.method == .HEAD {
			state.response.mode = .Head_Suppressed
		}
		step := _dispatch_route(&request, &response)
		return _connection_interpret_step(connection, step)

	case .Method_Not_Allowed:
		allow_buffer: [128]u8
		allow_size := allow_value_write(allow_buffer[:], match_result.methods_mask)
		if allow_size > 0 {
			_ = header_set(&response, "Allow", string(allow_buffer[:allow_size]))
		}
		step := respond_text(&response, HTTP_STATUS_METHOD_NOT_ALLOWED, "Method Not Allowed")
		return _connection_interpret_step(connection, step)

	case .Not_Found:
		step := respond_text(&response, HTTP_STATUS_NOT_FOUND, "Not Found")
		return _connection_interpret_step(connection, step)
	}

	return tina.Effect_Receive{}
}

@(private = "file")
_connection_send_parse_error :: proc(connection: ^HTTP_Connection, parse_status: Parse_Status) -> tina.Effect {
	connection.connection_state.response.flags += {.Close_After_Send, .Aborted}
	bytes := parse_error_response_bytes(parse_status)
	return _connection_stage_canned_response(connection, transmute([]u8)bytes)
}

@(private = "file")
_connection_send_not_found :: proc(
	connection: ^HTTP_Connection,
	frame: []u8,
	method: Method,
	is_asterisk: bool,
) -> tina.Effect {
	_ = frame
	_ = method
	_ = is_asterisk
	response := _connection_make_response(connection)
	step := respond_text(&response, HTTP_STATUS_NOT_FOUND, "Not Found")
	return _connection_interpret_step(connection, step)
}

@(private = "file")
_connection_handle_send_complete :: proc(connection: ^HTTP_Connection, bytes_sent: u32) -> tina.Effect {
	state := &connection.connection_state
	remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
	if remaining > 0 {
		sent := min(int(bytes_sent), remaining)
		state.response.egress_size_sent += Egress_Size_Sent(sent)
		remaining -= sent
		if remaining > 0 {
			start_offset := int(state.response.egress_size_sent)
			return tina.io_send(connection, state.fd, connection.egress_buffer[start_offset:][:remaining])
		}
	}

	if .Close_After_Send in state.response.flags || .In_Drain in state.response.flags || state.state == .Closing {
		state.state = .Closing
		_connection_release_slot(state)
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	_connection_begin_request(connection)
	return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(state.shard_runtime)}}
}

@(private = "file")
_connection_stage_canned_response :: proc(connection: ^HTTP_Connection, response_bytes: []u8) -> tina.Effect {
	copy(connection.egress_buffer[:], response_bytes)
	state := &connection.connection_state
	state.response.egress_size = Egress_Size(len(response_bytes))
	state.response.egress_size_sent = 0
	state.response.mode = .Closed
	state.state = .Sending
	return tina.io_send(connection, state.fd, connection.egress_buffer[:len(response_bytes)])
}

@(private = "file")
_connection_make_request :: proc(connection: ^HTTP_Connection, frame: []u8, ctx: ^tina.TinaContext) -> Request {
	return Request {
		connection_state = &connection.connection_state,
		request_state    = &connection.connection_state.request,
		frame            = frame,
		header_views     = connection.connection_state.header_views,
		tina_context     = ctx,
	}
}

@(private = "file")
_connection_make_response :: proc(connection: ^HTTP_Connection) -> Response {
	return Response {
		connection_state    = &connection.connection_state,
		egress_buffer       = connection.egress_buffer[:],
		response_header_bytes = connection.connection_state.response_header_bytes,
	}
}

@(private = "file")
_connection_interpret_step :: proc(connection: ^HTTP_Connection, step: Route_Step) -> tina.Effect {
	state := &connection.connection_state
	if state.response.egress_size > 0 {
		state.state = .Sending
		if step == .Close {
			state.response.flags += {.Close_After_Send}
		}
		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		return tina.io_send(connection, state.fd, connection.egress_buffer[:remaining])
	}

	#partial switch step {
	case .Close:
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	case .Flush, .Flush_Final:
		_connection_begin_request(connection)
		return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(state.shard_runtime)}}
	case:
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}
}

@(private = "file")
_connection_begin_request :: proc(connection: ^HTTP_Connection) {
	state := &connection.connection_state
	request_state_reset(&state.request)
	response_state_reset(&state.response)
	parser_state_reset(&state.parser)
	state.state = .Recv_Headers
	state.route_index = ROUTE_INDEX_NONE
	state.ingress_size = 0
	state.ingress_parsed_offset = 0
	state.request_token += 1
	if state.request_token == 0 do state.request_token = 1
}

@(private = "file")
_connection_release_slot :: proc(state: ^HTTP_Connection_State) {
	if state.shard_runtime != nil && state.shard_runtime.free_count < state.shard_runtime.connection_slot_count {
		state.shard_runtime.free_count += 1
	}
}

@(private = "file")
_recv_buffer_size_max :: proc(runtime: ^HTTP_Shard_Runtime) -> u32 {
	return u32(runtime.server.limits.request_line_size_max) + u32(runtime.server.limits.header_size_max)
}
