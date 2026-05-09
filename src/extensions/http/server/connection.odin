package http_server

import tina "../../.."
import "core:mem"
import "core:testing"

@(private = "package")
HTTP_SENDFILE_CHUNK_SIZE_MAX :: #config(HTTP_SENDFILE_CHUNK_SIZE_MAX, 256 * 1024)

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

	frame_size := int(runtime.server.limits.request_line_size_max) + int(runtime.server.limits.header_size_max)
	connection.connection_state.shard_runtime = runtime
	connection.connection_state.fd = init_args.client_fd
	_connection_init_working_memory_regions(connection, ctx, frame_size)
	connection.connection_state.peer = {}
	_runtime_active_slot_add(connection, ctx)
	_connection_begin_keep_alive_wait(connection, ctx)

	return tina.Effect_Io {
		operation = tina.IoOp_Recv {
			fd              = init_args.client_fd,
			buffer_size_max = u32(runtime.server.limits.request_line_size_max) + u32(runtime.server.limits.header_size_max),
		},
	}
}

@(private = "file")
_connection_init_working_memory_regions :: proc(
	connection: ^HTTP_Connection,
	ctx: ^tina.TinaContext,
	frame_size: int,
) {
	state := &connection.connection_state
	runtime := state.shard_runtime

	working_bytes := _connection_working_memory_bytes(ctx)
	working_offset := 0

	state.request_frame_bytes = _connection_working_region_take(working_bytes, &working_offset, frame_size)
	state.buffered_body_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.buffered_body_size_max),
	)
	state.pipeline_tail_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.limits.pipeline_size_max),
	)

	header_view_storage := _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.limits.header_count_max) * size_of(Header_View),
	)
	if len(header_view_storage) > 0 {
		state.header_views = (cast([^]Header_View)raw_data(header_view_storage))[:int(runtime.server.limits.header_count_max)]
	}

	state.route_state_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.route_state_size_max),
	)

	request_arena_bytes := _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.limits.request_arena_size),
	)
	mem.arena_init(&state.request_arena_region, request_arena_bytes)

	state.response_header_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.limits.response_header_bytes_max),
	)
}

@(private = "file")
_connection_working_memory_bytes :: proc(ctx: ^tina.TinaContext) -> []u8 {
	shard := ctx._shard
	type_id := tina.extract_type_id(ctx.self_handle)
	slot_index := tina.extract_slot(ctx.self_handle)
	working_stride := shard.type_descriptors[type_id].working_memory_size
	if working_stride <= 0 {
		return nil
	}
	start_index := int(slot_index) * working_stride
	return shard.working_memory[type_id][start_index:start_index + working_stride]
}

@(private = "file")
_connection_working_region_take :: proc(working_bytes: []u8, working_offset: ^int, region_size: int) -> []u8 {
	if region_size <= 0 {
		return nil
	}
	aligned_offset := _align_up(working_offset^)
	aligned_size := _align_up(region_size)
	end_offset := aligned_offset + aligned_size
	when tina.TINA_DEBUG_ASSERTS {
		assert(end_offset <= len(working_bytes), "_connection_working_region_take: working memory too small")
	}
	if end_offset > len(working_bytes) {
		return nil
	}
	working_offset^ = end_offset
	return working_bytes[aligned_offset:][:region_size]
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
		_connection_mark_draining(connection, ctx)
		if state.state == .Application_Expectation {
			return _connection_dispatch_server_drain(connection, ctx)
		}
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}

	case TAG_HEADER_TIMEOUT:
		if state.state != .Recv_Headers {
			return tina.Effect_Receive{}
		}
		if state.request.route_index != ROUTE_INDEX_NONE {
			return tina.Effect_Receive{}
		}
		if !_connection_timeout_is_current(connection, ctx, state.deadline_ns_header, message.correlation) {
			return tina.Effect_Receive{}
		}
		state.response.flags += {.Close_After_Send, .Aborted}
		return _connection_stage_canned_response(connection, transmute([]u8)string(ERROR_RESPONSE_408_REQUEST_TIMEOUT))

	case TAG_BODY_TIMEOUT:
		if state.state != .Recv_Body_Streamed && state.state != .Recv_Body_Buffered {
			return tina.Effect_Receive{}
		}
		if !_connection_timeout_is_current(connection, ctx, state.deadline_ns_body, message.correlation) {
			return tina.Effect_Receive{}
		}
		state.response.flags += {.Close_After_Send, .Aborted}
		return _connection_stage_canned_response(connection, transmute([]u8)string(ERROR_RESPONSE_408_REQUEST_TIMEOUT))

	case TAG_SEND_TIMEOUT:
		if state.state != .Sending {
			return tina.Effect_Receive{}
		}
		if !_connection_timeout_is_current(connection, ctx, state.deadline_ns_send, message.correlation) {
			return tina.Effect_Receive{}
		}
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}

	case TAG_IDLE_TIMEOUT:
		if state.state != .Keep_Alive_Idle {
			return tina.Effect_Receive{}
		}
		if !_connection_timeout_is_current(connection, ctx, state.deadline_ns_idle, message.correlation) {
			return tina.Effect_Receive{}
		}
		_idle_slot_remove(connection, ctx)
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}

	case TAG_DRAIN_TIMEOUT:
		if state.shard_runtime == nil || !state.shard_runtime.draining {
			return tina.Effect_Receive{}
		}
		if !_connection_timeout_is_current(connection, ctx, state.deadline_ns_drain, message.correlation) {
			return tina.Effect_Receive{}
		}
		if state.state == .Keep_Alive_Idle {
			_idle_slot_remove(connection, ctx)
		}
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}

	case TAG_EVICT:
		if state.state != .Keep_Alive_Idle {
			return tina.Effect_Receive{}
		}
		_idle_slot_remove(connection, ctx)
		state.response.flags += {.Close_After_Send}
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}

	case tina.IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		if state.state == .Keep_Alive_Idle {
			_connection_prepare_incoming_request(connection, ctx)
		}
		if state.shard_runtime != nil && state.shard_runtime.draining {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		return _connection_handle_recv_complete(connection, ctx, message.io.buffer_index, u32(message.io.result))

	case tina.IO_TAG_SEND_COMPLETE:
		if message.io.result <= 0 {
			return _connection_dispatch_peer_closed(connection, ctx)
		}
		return _connection_handle_send_complete(connection, u32(message.io.result), ctx)

	case tina.IO_TAG_SENDFILE_COMPLETE:
		if message.io.result < 0 {
			return _connection_dispatch_peer_closed(connection, ctx)
		}
		return _connection_handle_sendfile_complete(connection, u32(message.io.result), ctx)

	case tina.IO_TAG_CLOSE_COMPLETE:
		_runtime_active_slot_remove(connection, ctx)
		_connection_release_slot(connection, ctx)
		return tina.Effect_Done{}

	case:
		if message.tag >= tina.USER_MESSAGE_TAG_BASE {
			if state.state != .Application_Expectation {
				_connection_store_pending_application_message(state, message)
				return tina.Effect_Receive{}
			}
			return _connection_handle_application_mailbox_message(connection, message, ctx)
		}
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
	if state.state == .Recv_Body_Streamed || state.state == .Recv_Body_Buffered {
		return _connection_handle_body_recv_complete(connection, buffer, ctx)
	}
	if len(buffer) == 0 {
		if _connection_should_drain(runtime, ctx) {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(runtime)}}
	}

	if _connection_should_drain(runtime, ctx) && state.response.egress_size == 0 {
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	return _connection_process_header_bytes(connection, buffer, ctx)
}

@(private = "file")
_connection_process_header_bytes :: proc(
	connection: ^HTTP_Connection,
	buffer: []u8,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	parse_status, parsed_offset := parse_step(&state.parser, &state.request, state.header_views, buffer, 0, runtime.server.limits)
	#partial switch parse_status {
	case .Need_More:
		if state.parser.phase == .Body_Fixed ||
			state.parser.phase == .Chunk_Size ||
			state.parser.phase == .Chunk_Data ||
			state.parser.phase == .Chunk_Data_CRLF ||
			state.parser.phase == .Trailers
		{
			_connection_arm_body_timeout(connection, ctx)
		}
		return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(runtime)}}

	case .Headers_Done:
		if _connection_should_drain(runtime, ctx) {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		request := _connection_make_request(connection, buffer, ctx)
		response := _connection_make_response(connection, ctx)
		if state.request.method == .HEAD {
			state.response.mode = .Head_Suppressed
		}
		step := _dispatch_route(&request, &response)
		if state.request.route_index != ROUTE_INDEX_NONE {
			descriptor := runtime.router.descriptors[state.request.route_index]
			if descriptor.body_mode != .None || descriptor.handler_kind == .Event {
				_connection_retain_request_frame(connection, buffer[:parsed_offset])
			}
		}
		if parsed_offset < u16(len(buffer)) {
			if !_connection_retain_tail(connection, buffer[parsed_offset:]) {
				if step == .Read_Body {
					state.state = .Closing
					return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
				}
				state.response.flags += {.Close_After_Send}
			}
		}
		return _dispatch_step(connection, step, ctx)

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
	response := _connection_make_response(connection, ctx)
	request := _connection_make_request(connection, frame, ctx)

	#partial switch match_result.outcome {
	case .Found:
		state.request.route_index = match_result.route_index
		if state.request.method == .HEAD {
			state.response.mode = .Head_Suppressed
		}
		step := _dispatch_route(&request, &response)
		return _dispatch_step(connection, step, ctx)

	case .Method_Not_Allowed:
		allow_buffer: [128]u8
		allow_size := allow_value_write(allow_buffer[:], match_result.methods_mask)
		if allow_size > 0 {
			_ = header_set(&response, "Allow", string(allow_buffer[:allow_size]))
		}
		step := respond_text(&response, HTTP_STATUS_METHOD_NOT_ALLOWED, "Method Not Allowed")
		return _dispatch_step(connection, step, ctx)

	case .Not_Found:
		step := respond_text(&response, HTTP_STATUS_NOT_FOUND, "Not Found")
		return _dispatch_step(connection, step, ctx)
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
	ctx: ^tina.TinaContext,
	frame: []u8,
	method: Method,
	is_asterisk: bool,
) -> tina.Effect {
	_ = frame
	_ = method
	_ = is_asterisk
	response := _connection_make_response(connection, ctx)
	step := respond_text(&response, HTTP_STATUS_NOT_FOUND, "Not Found")
	return _dispatch_step(connection, step, ctx)
}

@(private = "file")
_connection_handle_send_complete :: proc(connection: ^HTTP_Connection, bytes_sent: u32, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
	if remaining > 0 {
		sent := min(int(bytes_sent), remaining)
		state.response.egress_size_sent += Egress_Size_Sent(sent)
		remaining -= sent
		if remaining > 0 {
			start_offset := int(state.response.egress_size_sent)
			_connection_arm_send_timeout(connection, ctx)
			return tina.io_send(connection, state.fd, connection.egress_buffer[start_offset:][:remaining])
		}
	}

	if state.sendfile_active {
		return _connection_drive_sendfile(connection, ctx)
	}

	if state.shard_runtime != nil && state.request.route_index != ROUTE_INDEX_NONE {
		descriptor := state.shard_runtime.router.descriptors[state.request.route_index]
		if state.response.status_code == HTTP_STATUS_CONTINUE {
			_response_prepare_next_message(&state.response)
			state.state = .Recv_Body_Streamed if descriptor.body_mode == .Streamed else .Recv_Body_Buffered
			state.response_flush_final = false
			return _connection_drive_body_read(connection, ctx)
		}
	}

	if state.response_flush_final {
		state.response_flush_final = false
		return _connection_finalize_flushed_response(connection, ctx)
	}

	return _connection_continue_after_non_final_flush(connection, ctx)
}

@(private = "file")
_connection_handle_sendfile_complete :: proc(connection: ^HTTP_Connection, bytes_sent: u32, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	if !state.sendfile_active {
		return tina.Effect_Receive{}
	}

	if bytes_sent == 0 {
		if state.sendfile_size_remaining == 0 {
			state.sendfile_active = false
			return _connection_finalize_flushed_response(connection, ctx)
		}
		state.response.flags += {.Close_After_Send, .Aborted}
		_connection_release_slot(connection, ctx)
		return _connection_dispatch_peer_closed(connection, ctx)
	}

	sent_size := min(u64(bytes_sent), state.sendfile_size_remaining)
	state.sendfile_offset += sent_size
	state.sendfile_size_remaining -= sent_size
	state.response.body_size_sent += sent_size

	if state.sendfile_size_remaining == 0 {
		state.sendfile_active = false
		return _connection_finalize_flushed_response(connection, ctx)
	}

	return _connection_drive_sendfile(connection, ctx)
}

@(private = "file")
_connection_drive_sendfile :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	if !state.sendfile_active || state.sendfile_size_remaining == 0 {
		state.sendfile_active = false
		return _connection_finalize_flushed_response(connection, ctx)
	}

	chunk_size := min(state.sendfile_size_remaining, u64(HTTP_SENDFILE_CHUNK_SIZE_MAX))
	if chunk_size == 0 {
		state.sendfile_active = false
		return _connection_finalize_flushed_response(connection, ctx)
	}

	state.state = .Sending
	_connection_arm_send_timeout(connection, ctx)
	return tina.io_sendfile(state.fd, state.sendfile_file_fd, state.sendfile_offset, u32(chunk_size))
}

@(private = "file")
_connection_finalize_flushed_response :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	state.sendfile_active = false
	state.sendfile_file_fd = tina.FD_HANDLE_NONE
	state.sendfile_offset = 0
	state.sendfile_size_remaining = 0
	if .Close_After_Send in state.response.flags || .In_Drain in state.response.flags || state.state == .Closing {
		state.state = .Closing
		_connection_release_slot(connection, ctx)
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	if state.shard_runtime != nil && state.shard_runtime.free_count <= state.shard_runtime.keepalive_reserve {
		state.response.flags += {.Close_After_Send}
		state.state = .Closing
		_connection_release_slot(connection, ctx)
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	if _connection_should_drain(state.shard_runtime, ctx) {
		state.state = .Closing
		_connection_release_slot(connection, ctx)
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	if state.pipeline_tail_size > 0 {
		pipeline_tail_size := state.pipeline_tail_size
		_connection_begin_keep_alive_wait(connection, ctx)
		_connection_prepare_incoming_request(connection, ctx)
		state.pipeline_tail_size = 0
		return _connection_process_header_bytes(connection, state.pipeline_tail_bytes[:int(pipeline_tail_size)], ctx)
	}

	_connection_begin_keep_alive_wait(connection, ctx)
	return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(state.shard_runtime)}}
}

@(private = "file")
_connection_continue_after_non_final_flush :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	state.response_flush_final = false

	if .Close_After_Send in state.response.flags || .In_Drain in state.response.flags || state.state == .Closing {
		return _connection_finalize_flushed_response(connection, ctx)
	}
	if state.shard_runtime != nil && state.shard_runtime.free_count <= state.shard_runtime.keepalive_reserve {
		state.response.flags += {.Close_After_Send}
		return _connection_finalize_flushed_response(connection, ctx)
	}
	if _connection_should_drain(state.shard_runtime, ctx) {
		return _connection_finalize_flushed_response(connection, ctx)
	}

	state.response.egress_size = 0
	state.response.egress_size_sent = 0

	if state.shard_runtime != nil && state.request.route_index != ROUTE_INDEX_NONE {
		descriptor := state.shard_runtime.router.descriptors[state.request.route_index]
		if descriptor.handler_kind == .Event {
			request := _connection_make_request(connection, nil, ctx)
			response := _connection_make_response(connection, ctx)
			route_context := _make_route_context(state, ctx)
			event := Route_Event(Send_Ready{})
			step := _dispatch_route_event(event, &request, &response, route_context, _route_state_ptr(state))
			return _dispatch_step(connection, step, ctx)
		}
	}

	return _connection_finalize_flushed_response(connection, ctx)
}

@(private = "file")
_connection_stage_canned_response :: proc(connection: ^HTTP_Connection, response_bytes: []u8) -> tina.Effect {
	copy(connection.egress_buffer[:], response_bytes)
	state := &connection.connection_state
	state.response.egress_size = Egress_Size(len(response_bytes))
	state.response.egress_size_sent = 0
	state.response.mode = .Closed
	state.response_flush_final = true
	state.sendfile_active = false
	state.sendfile_file_fd = tina.FD_HANDLE_NONE
	state.sendfile_offset = 0
	state.sendfile_size_remaining = 0
	state.state = .Sending
	return tina.io_send(connection, state.fd, connection.egress_buffer[:len(response_bytes)])
}

@(private = "file")
_connection_make_request :: proc(connection: ^HTTP_Connection, frame: []u8, ctx: ^tina.TinaContext) -> Request {
	request_frame := frame
	if len(request_frame) == 0 && connection.connection_state.request_frame_size > 0 {
		request_frame = connection.connection_state.request_frame_bytes[:connection.connection_state.request_frame_size]
	}
	return Request {
		connection_state = &connection.connection_state,
		tina_context     = ctx,
		frame            = request_frame,
	}
}

@(private = "package")
_connection_date_value :: proc "contextless" (connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> []u8 {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || ctx == nil || ctx._shard == nil {
		return nil
	}

	monotonic_ns := tina.ctx_monotonic_time_ns(ctx)
	if monotonic_ns >= runtime.date_cache.next_second_threshold_ns {
		unix_epoch_ns := wall_clock_unix_epoch_ns(monotonic_ns)
		update_date_cache(&runtime.date_cache, monotonic_ns, unix_epoch_ns)
	}

	if runtime.date_cache.size == 0 {
		return nil
	}
	return runtime.date_cache.bytes[:int(runtime.date_cache.size)]
}

@(private = "file")
_connection_make_response :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext = nil) -> Response {
	return Response {
		connection   = connection,
		tina_context = ctx,
	}
}

@(private = "file")
_connection_store_pending_application_message :: proc(
	state: ^HTTP_Connection_State,
	message: ^tina.Message,
) {
	// A parked expectation can consume at most one application event next.
	// Preserve the earliest deferred event and drop later arrivals until it is consumed.
	if state.application_pending_message_valid {
		return
	}

	pending := &state.application_pending_message
	pending.source_handle = message.user.source
	pending.message_tag = Message_Tag(message.tag)
	pending.correlation_id = message.correlation
	pending.payload_size = message.user.payload_size
	if pending.payload_size > 0 {
		copy(pending.payload[:], message.user.payload[:int(pending.payload_size)])
	}
	state.application_pending_message_valid = true
}

@(private = "file")
_connection_pending_application_message_take :: proc(
	state: ^HTTP_Connection_State,
	out_message: ^tina.Message,
) -> bool {
	if !state.application_pending_message_valid {
		return false
	}

	pending := &state.application_pending_message
	out_message.tag = tina.Message_Tag(pending.message_tag)
	out_message.correlation = pending.correlation_id
	out_message.user.source = pending.source_handle
	out_message.user.payload_size = pending.payload_size
	if pending.payload_size > 0 {
		copy(out_message.user.payload[:], pending.payload[:int(pending.payload_size)])
	}

	state.application_pending_message_valid = false
	state.application_pending_message.payload_size = 0
	return true
}

@(private = "file")
_connection_dispatch_server_drain :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || state.request.route_index == ROUTE_INDEX_NONE {
		return tina.Effect_Receive{}
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.handler_kind != .Event {
		return tina.Effect_Receive{}
	}

	request := _connection_make_request(connection, nil, ctx)
	response := _connection_make_response(connection, ctx)
	route_context := _make_route_context(state, ctx)
	step := _dispatch_route_event(Route_Event(Server_Drain{}), &request, &response, route_context, _route_state_ptr(state))
	return _dispatch_step(connection, step, ctx)
}

@(private = "file")
_connection_dispatch_peer_closed :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime != nil && state.request.route_index != ROUTE_INDEX_NONE {
		descriptor := runtime.router.descriptors[state.request.route_index]
		if descriptor.handler_kind == .Event {
			request := _connection_make_request(connection, nil, ctx)
			response := _connection_make_response(connection, ctx)
			route_context := _make_route_context(state, ctx)
			_ = _dispatch_route_event(
				Route_Event(Peer_Closed{}),
				&request,
				&response,
				route_context,
				_route_state_ptr(state),
			)
		}
	}

	state.state = .Closing
	return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
}

@(private = "file")
_connection_handle_application_mailbox_message :: proc(
	connection: ^HTTP_Connection,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if state.state != .Application_Expectation || runtime == nil {
		return tina.Effect_Receive{}
	}
	if state.request.route_index == ROUTE_INDEX_NONE {
		return tina.Effect_Receive{}
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.handler_kind != .Event {
		return tina.Effect_Receive{}
	}

	is_timeout := message.tag == HTTP_INTERNAL_TAG_AWAIT_TIMEOUT
	message_tag := Message_Tag(message.tag)

	#partial switch state.application_expectation_kind {
	case .Reply:
		if is_timeout {
			if state.application_correlation_id != message.correlation {
				return tina.Effect_Receive{}
			}
			event := Route_Event(Application_Reply {
				source_handle = state.application_expected_source,
				message_tag   = state.application_expected_tag,
				payload_bytes = nil,
				reply_result  = .Timeout,
			})
			request := _connection_make_request(connection, nil, ctx)
			response := _connection_make_response(connection, ctx)
			route_context := _make_route_context(state, ctx)
			step := _dispatch_route_event(event, &request, &response, route_context, _route_state_ptr(state))
			return _dispatch_step(connection, step, ctx)
		}
		if state.application_expected_source != message.user.source {
			return tina.Effect_Receive{}
		}
		if state.application_expected_tag != message_tag {
			return tina.Effect_Receive{}
		}
		if state.application_correlation_id != message.correlation {
			return tina.Effect_Receive{}
		}
		event := Route_Event(Application_Reply {
			source_handle = message.user.source,
			message_tag   = message_tag,
			payload_bytes = message.user.payload[:int(message.user.payload_size)],
			reply_result  = .Ok,
		})
		request := _connection_make_request(connection, nil, ctx)
		response := _connection_make_response(connection, ctx)
		route_context := _make_route_context(state, ctx)
		step := _dispatch_route_event(event, &request, &response, route_context, _route_state_ptr(state))
		return _dispatch_step(connection, step, ctx)

	case .Notification:
		if !is_timeout {
			if state.application_expected_source != tina.HANDLE_NONE && state.application_expected_source != message.user.source {
				return tina.Effect_Receive{}
			}
			if state.application_expected_tag != Message_Tag(0) && state.application_expected_tag != message_tag {
				return tina.Effect_Receive{}
			}
			event := Route_Event(Application_Notification {
				source_handle = message.user.source,
				message_tag   = message_tag,
				payload_bytes = message.user.payload[:int(message.user.payload_size)],
			})
			request := _connection_make_request(connection, nil, ctx)
			response := _connection_make_response(connection, ctx)
			route_context := _make_route_context(state, ctx)
			step := _dispatch_route_event(event, &request, &response, route_context, _route_state_ptr(state))
			return _dispatch_step(connection, step, ctx)
		}
		if state.application_correlation_id != message.correlation {
			return tina.Effect_Receive{}
		}
		event := Route_Event(Application_Reply {
			source_handle = state.application_expected_source,
			message_tag   = state.application_expected_tag,
			payload_bytes = nil,
			reply_result  = .Timeout,
		})
		request := _connection_make_request(connection, nil, ctx)
		response := _connection_make_response(connection, ctx)
		route_context := _make_route_context(state, ctx)
		step := _dispatch_route_event(event, &request, &response, route_context, _route_state_ptr(state))
		return _dispatch_step(connection, step, ctx)
	}

	return tina.Effect_Receive{}
}

@(private = "file")
_dispatch_step :: proc(connection: ^HTTP_Connection, step: Route_Step, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	if step != .Expect_Application && step != .Flush && step != .Flush_Final && int(state.response.egress_size) > int(state.response.egress_size_sent) {
		state.state = .Sending
		_connection_arm_send_timeout(connection, ctx)
		if step == .Close {
			state.response.flags += {.Close_After_Send}
			state.response_flush_final = true
		}
		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		start_offset := int(state.response.egress_size_sent)
		return tina.io_send(connection, state.fd, connection.egress_buffer[start_offset:][:remaining])
	}

	#partial switch step {
	case .Close:
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	case .Read_Body:
		return _connection_drive_body_read(connection, ctx)
	case .Flush, .Flush_Final:
		response := _connection_make_response(connection, ctx)
		final := step == .Flush_Final
		if !_response_prepare_flush(&response, final) {
			if int(state.response.egress_size) > int(state.response.egress_size_sent) {
				state.response_flush_final = true
				state.state = .Sending
				_connection_arm_send_timeout(connection, ctx)
				remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
				start_offset := int(state.response.egress_size_sent)
				return tina.io_send(connection, state.fd, connection.egress_buffer[start_offset:][:remaining])
			}
			state.state = .Closing
			_connection_release_slot(connection, ctx)
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}

		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		if remaining > 0 {
			state.response_flush_final = final
			state.state = .Sending
			_connection_arm_send_timeout(connection, ctx)
			start_offset := int(state.response.egress_size_sent)
			return tina.io_send(connection, state.fd, connection.egress_buffer[start_offset:][:remaining])
		}

		if final {
			state.response_flush_final = false
			return _connection_finalize_flushed_response(connection, ctx)
		}
		return _connection_continue_after_non_final_flush(connection, ctx)

	case .Expect_Application:
		when tina.TINA_DEBUG_ASSERTS {
			assert(
				int(state.response.egress_size) == int(state.response.egress_size_sent),
				"Cannot park with unsent HTTP bytes. Call flush() first; on Send_Ready, then expect_*().",
			)
		}
		if int(state.response.egress_size) != int(state.response.egress_size_sent) {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		if state.shard_runtime == nil {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		if state.application_timeout_ns > 0 {
			tina.ctx_register_timer_with_correlation(
				ctx,
				state.application_timeout_ns,
				HTTP_INTERNAL_TAG_AWAIT_TIMEOUT,
				state.application_correlation_id,
			)
		}
		state.state = .Application_Expectation
		pending_message: tina.Message
		if _connection_pending_application_message_take(state, &pending_message) {
			return _connection_handle_application_mailbox_message(connection, &pending_message, ctx)
		}
		return tina.Effect_Receive{}
	case:
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}
}

@(private = "file")
_connection_retain_request_frame :: proc(connection: ^HTTP_Connection, frame: []u8) {
	state := &connection.connection_state
	copy_size := min(len(frame), len(state.request_frame_bytes))
	if copy_size > 0 {
		copy(state.request_frame_bytes[:copy_size], frame[:copy_size])
	}
	state.request_frame_size = u16(copy_size)
}

@(private = "file")
_connection_retain_tail :: proc(connection: ^HTTP_Connection, source: []u8) -> bool {
	state := &connection.connection_state
	retained_size, budget_exceeded := retain_pipeline_tail(source, state.pipeline_tail_bytes)
	if budget_exceeded {
		state.pipeline_tail_size = 0
		return false
	}
	state.pipeline_tail_size = u16(retained_size)
	return true
}

@(private = "file")
_connection_handle_body_recv_complete :: proc(
	connection: ^HTTP_Connection,
	buffer: []u8,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	state := &connection.connection_state
	if len(buffer) == 0 {
		return _connection_drive_body_read(connection, ctx)
	}

	source := buffer
	if state.pipeline_tail_size > 0 {
		combined_size := int(state.pipeline_tail_size) + len(buffer)
		if combined_size > len(state.pipeline_tail_bytes) {
			state.state = .Closing
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
		}
		copy(state.pipeline_tail_bytes[int(state.pipeline_tail_size):], buffer)
		source = state.pipeline_tail_bytes[:combined_size]
		state.pipeline_tail_size = 0
	}

	return _connection_process_body_bytes(connection, source, ctx)
}

@(private = "file")
_connection_drive_body_read :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || state.request.route_index == ROUTE_INDEX_NONE {
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.body_mode == .None {
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}
	if descriptor.body_mode == .Buffered && state.parser.phase != .Complete && .Expect_100 in state.parser.flags && .Interim_100_Sent not_in state.response.flags {
		response := _connection_make_response(connection, ctx)
		continue_100(&response)
	}

	if int(state.response.egress_size) > int(state.response.egress_size_sent) {
		state.state = .Sending
		_connection_arm_send_timeout(connection, ctx)
		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		return tina.io_send(connection, state.fd, connection.egress_buffer[:remaining])
	}

	if descriptor.body_mode == .Streamed && state.parser.phase == .Complete && !state.request_body_complete_notified {
		request := _connection_make_request(connection, nil, ctx)
		response := _connection_make_response(connection, ctx)
		route_context := _make_route_context(state, ctx)
		state.request_body_complete_notified = true
		step := _dispatch_route_event(
			Route_Event(Body_Chunk {data = nil, is_last = true}),
			&request,
			&response,
			route_context,
			_route_state_ptr(state),
		)
		return _dispatch_step(connection, step, ctx)
	}

	if descriptor.body_mode == .Buffered && state.parser.phase == .Complete {
		request := _connection_make_request(connection, nil, ctx)
		response := _connection_make_response(connection, ctx)
		step := _dispatch_route(&request, &response)
		return _dispatch_step(connection, step, ctx)
	}

	if state.pipeline_tail_size > 0 {
		source := state.pipeline_tail_bytes[:state.pipeline_tail_size]
		state.pipeline_tail_size = 0
		return _connection_process_body_bytes(connection, source, ctx)
	}

	state.state = .Recv_Body_Streamed if descriptor.body_mode == .Streamed else .Recv_Body_Buffered
	_connection_arm_body_timeout(connection, ctx)
	return tina.Effect_Io{operation = tina.IoOp_Recv{fd = state.fd, buffer_size_max = _recv_buffer_size_max(runtime)}}
}

@(private = "file")
_connection_process_body_bytes :: proc(
	connection: ^HTTP_Connection,
	source: []u8,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || state.request.route_index == ROUTE_INDEX_NONE {
		state.state = .Closing
		return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	remaining_source := source

	if descriptor.body_mode == .Streamed {
		for {
			if state.parser.phase == .Complete && !state.request_body_complete_notified {
				if len(remaining_source) > 0 {
					if !_connection_retain_tail(connection, remaining_source) {
						state.response.flags += {.Close_After_Send}
					}
				}
				return _connection_drive_body_read(connection, ctx)
			}

			result := drain_request_body(
				&state.parser,
				remaining_source,
				state.buffered_body_bytes,
				&state.buffered_body_size,
				&state.request_body_size_received,
				descriptor.body_size_max,
				runtime.server.limits,
				buffered = false,
			)

			if result.protocol_error {
				return _connection_send_parse_error(connection, .Error_Bad_Request)
			}
			if result.body_too_large {
				state.response.flags += {.Close_After_Send, .Aborted}
				return _connection_stage_canned_response(connection, transmute([]u8)string(ERROR_RESPONSE_413_CONTENT_TOO_LARGE))
			}

			next_source := remaining_source[result.consumed_size:]

			if result.data_size > 0 {
				request := _connection_make_request(connection, nil, ctx)
				response := _connection_make_response(connection, ctx)
				route_context := _make_route_context(state, ctx)
				is_last := result.done && state.parser.phase == .Complete
				if is_last {
					state.request_body_complete_notified = true
				}
				step := _dispatch_route_event(
					Route_Event(Body_Chunk {
						data    = remaining_source[result.data_offset:][:result.data_size],
						is_last = is_last,
					}),
					&request,
					&response,
					route_context,
					_route_state_ptr(state),
				)
				if step != .Read_Body && !state.request_body_complete_notified {
					state.response.flags += {.Close_After_Send}
				}
				if step == .Read_Body {
					remaining_source = next_source
					if len(remaining_source) == 0 {
						return _connection_drive_body_read(connection, ctx)
					}
					continue
				}
				if state.request_body_complete_notified && len(next_source) > 0 {
					if !_connection_retain_tail(connection, next_source) {
						state.response.flags += {.Close_After_Send}
					}
				}
				return _dispatch_step(connection, step, ctx)
			}

			if result.need_more {
				if !_connection_retain_tail(connection, next_source) {
					state.state = .Closing
					return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
				}
				return _connection_drive_body_read(connection, ctx)
			}

			if result.consumed_size <= 0 {
				return _connection_drive_body_read(connection, ctx)
			}

			remaining_source = next_source
			if len(remaining_source) == 0 {
				return _connection_drive_body_read(connection, ctx)
			}
		}
	} else {
		for {
			result := drain_request_body(
				&state.parser,
				remaining_source,
				state.buffered_body_bytes,
				&state.buffered_body_size,
				&state.request_body_size_received,
				descriptor.body_size_max,
				runtime.server.limits,
				buffered = true,
			)

			if result.protocol_error {
				return _connection_send_parse_error(connection, .Error_Bad_Request)
			}
			if result.body_too_large {
				state.response.flags += {.Close_After_Send, .Aborted}
				return _connection_stage_canned_response(connection, transmute([]u8)string(ERROR_RESPONSE_413_CONTENT_TOO_LARGE))
			}

			next_source := remaining_source[result.consumed_size:]

			if result.done && state.parser.phase == .Complete {
				if len(next_source) > 0 {
					if !_connection_retain_tail(connection, next_source) {
						state.response.flags += {.Close_After_Send}
					}
				}
				return _connection_drive_body_read(connection, ctx)
			}

			if result.need_more {
				if !_connection_retain_tail(connection, next_source) {
					state.state = .Closing
					return tina.Effect_Io{operation = tina.IoOp_Close{fd = state.fd}}
				}
				return _connection_drive_body_read(connection, ctx)
			}

			if result.consumed_size <= 0 {
				return _connection_drive_body_read(connection, ctx)
			}

			remaining_source = next_source
			if len(remaining_source) == 0 {
				return _connection_drive_body_read(connection, ctx)
			}
		}
	}
}

@(private = "file")
_connection_release_slot :: proc(connection: ^HTTP_Connection, ctx: ^tina.TinaContext) {
	state := &connection.connection_state
	if state.state == .Keep_Alive_Idle {
		_idle_slot_remove(connection, ctx)
	}
	if state.shard_runtime != nil && state.shard_runtime.free_count < state.shard_runtime.connection_slot_count {
		state.shard_runtime.free_count += 1
	}
}

@(private = "file")
_recv_buffer_size_max :: proc(runtime: ^HTTP_Shard_Runtime) -> u32 {
	return u32(runtime.server.limits.request_line_size_max) + u32(runtime.server.limits.header_size_max)
}

@(private = "file")
TEST_NOTIFICATION_MESSAGE_TAG :: Message_Tag(0x4400)

@(private = "file")
Notification_Test_State :: struct {
	dropped_count:  u32,
	accepted_count: u32,
	drain_count:    u32,
}

@(private = "file")
Notification_Test_Payload :: struct {
	request_token: Request_Token,
}

@(private = "file")
Peer_Closed_Test_State :: struct {
	peer_closed_count: u32,
}

@(private = "file")
_peer_closed_route_event_handler :: proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step {
	_ = request
	_ = response
	_ = route_context
	test_state := cast(^Peer_Closed_Test_State)state
	#partial switch _ in event {
	case Peer_Closed:
		test_state.peer_closed_count += 1
		return flush(true)
	case:
		return close()
	}
}

@(private = "file")
_notification_route_event_handler :: proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step {
	_ = request
	_ = response
	test_state := cast(^Notification_Test_State)state
	#partial switch ev in event {
	case Request_Start:
		return expect_notification(route_context, 1_000_000, tina.HANDLE_NONE, TEST_NOTIFICATION_MESSAGE_TAG)

	case Application_Notification:
		payload := (cast(^Notification_Test_Payload)raw_data(ev.payload_bytes))^
		if payload.request_token != route_request_token(route_context) {
			test_state.dropped_count += 1
			return expect_notification(route_context, 1_000_000, tina.HANDLE_NONE, TEST_NOTIFICATION_MESSAGE_TAG)
		}
		test_state.accepted_count += 1
		return close()

	case Server_Drain:
		test_state.drain_count += 1
		return close()

	case:
		return close()
	}
}

@(test)
test_stale_notification_on_keep_alive_connection_is_dropped :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [4]u32
	entries: [4]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler      = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode    = .None,
			state_size   = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
	}
	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.request_token = Request_Token(7)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.response.egress_size = 0
	connection.connection_state.response.egress_size_sent = 0

	ctx := tina.TinaContext {}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	request := _connection_make_request(&connection, nil, &ctx)
	response := _connection_make_response(&connection, &ctx)
		step := _dispatch_route(&request, &response)
		#partial switch step {
		case .Expect_Application:
		case:
			testing.expect(t, false, "Request_Start should request application parking")
		}
		park_effect := _dispatch_step(&connection, step, &ctx)
		#partial switch e in park_effect {
		case tina.Effect_Receive:
		case:
			testing.expect(t, false, "Request_Start should park for notifications")
		}
	state := &route_state_storage[0]
	testing.expect_value(t, state.dropped_count, u32(0))
	testing.expect_value(t, state.accepted_count, u32(0))
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Application_Expectation)

	stale_message: tina.Message
	stale_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
	stale_message.user.source = tina.make_handle(0, 3, 2, 1)
	stale_message.user.payload_size = u16(size_of(Notification_Test_Payload))
	(cast(^Notification_Test_Payload)&stale_message.user.payload[0])^ = Notification_Test_Payload {
		request_token = Request_Token(99),
	}
		stale_effect := _connection_handle_application_mailbox_message(&connection, &stale_message, &ctx)
		#partial switch e in stale_effect {
		case tina.Effect_Receive:
		case:
			testing.expect(t, false, "stale notification should be dropped and re-parked")
		}
	testing.expect_value(t, state.dropped_count, u32(1))
	testing.expect_value(t, state.accepted_count, u32(0))
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Application_Expectation)

	correct_message: tina.Message
	correct_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
	correct_message.user.source = tina.make_handle(0, 3, 2, 1)
	correct_message.user.payload_size = u16(size_of(Notification_Test_Payload))
	(cast(^Notification_Test_Payload)&correct_message.user.payload[0])^ = Notification_Test_Payload {
		request_token = route_request_token(Route_Context {
			connection_state = &connection.connection_state,
			tina_context     = &ctx,
		}),
	}
		correct_effect := _connection_handle_application_mailbox_message(&connection, &correct_message, &ctx)
		#partial switch e in correct_effect {
		case tina.Effect_Receive:
			testing.expect(t, false, "valid notification should be handled")
		case:
		}
	testing.expect_value(t, state.accepted_count, u32(1))
}

@(test)
test_pending_application_message_is_preserved_until_expectation :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [4]u32
	entries: [4]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler      = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode    = .None,
			state_size   = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
	}
	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.request_token = Request_Token(7)
	connection.connection_state.state = .Sending
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.response.egress_size = 0
	connection.connection_state.response.egress_size_sent = 0

	ctx := tina.TinaContext {}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	notification_message: tina.Message
	notification_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
	notification_message.user.source = tina.make_handle(0, 3, 2, 1)
	notification_message.user.payload_size = u16(size_of(Notification_Test_Payload))
	(cast(^Notification_Test_Payload)&notification_message.user.payload[0])^ = Notification_Test_Payload {
		request_token = Request_Token(7),
	}

	stash_effect := _http_connection_handler(rawptr(&connection), &notification_message, &ctx)
	#partial switch _ in stash_effect {
	case tina.Effect_Receive:
	case:
		testing.expect(t, false, "message outside Application_Expectation should be preserved and deferred")
	}
	testing.expect(t, connection.connection_state.application_pending_message_valid)

	connection.connection_state.application_expectation_kind = .Notification
	connection.connection_state.application_expected_source = tina.HANDLE_NONE
	connection.connection_state.application_expected_tag = TEST_NOTIFICATION_MESSAGE_TAG
	connection.connection_state.application_correlation_id = tina.Correlation_Id(33)
	connection.connection_state.application_timeout_ns = 1_000_000

	effect := _dispatch_step(&connection, .Expect_Application, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "deferred notification should dispatch to handler and close")
		}
	case:
		testing.expect(t, false, "deferred notification should produce close effect from handler")
	}
	testing.expect_value(t, route_state_storage[0].accepted_count, u32(1))
	testing.expect(t, !connection.connection_state.application_pending_message_valid)
}

@(test)
test_pending_application_message_first_wins_when_multiple_arrive :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [4]u32
	entries: [4]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler      = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode    = .None,
			state_size   = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
	}
	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.request_token = Request_Token(7)
	connection.connection_state.state = .Sending
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.response.egress_size = 0
	connection.connection_state.response.egress_size_sent = 0

	ctx := tina.TinaContext {}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	first_message: tina.Message
	first_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
	first_message.user.source = tina.make_handle(0, 3, 2, 1)
	first_message.user.payload_size = u16(size_of(Notification_Test_Payload))
	(cast(^Notification_Test_Payload)&first_message.user.payload[0])^ = Notification_Test_Payload {
		request_token = Request_Token(7),
	}

	second_message: tina.Message
	second_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
	second_message.user.source = tina.make_handle(0, 3, 2, 1)
	second_message.user.payload_size = u16(size_of(Notification_Test_Payload))
	(cast(^Notification_Test_Payload)&second_message.user.payload[0])^ = Notification_Test_Payload {
		request_token = Request_Token(999),
	}

	_ = _http_connection_handler(rawptr(&connection), &first_message, &ctx)
	_ = _http_connection_handler(rawptr(&connection), &second_message, &ctx)
	testing.expect(t, connection.connection_state.application_pending_message_valid)

	connection.connection_state.application_expectation_kind = .Notification
	connection.connection_state.application_expected_source = tina.HANDLE_NONE
	connection.connection_state.application_expected_tag = TEST_NOTIFICATION_MESSAGE_TAG
	connection.connection_state.application_correlation_id = tina.Correlation_Id(44)
	connection.connection_state.application_timeout_ns = 1_000_000

	effect := _dispatch_step(&connection, .Expect_Application, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "first deferred notification should be delivered and close")
		}
	case:
		testing.expect(t, false, "first deferred notification should dispatch before later arrivals")
	}

	testing.expect_value(t, route_state_storage[0].accepted_count, u32(1))
	testing.expect_value(t, route_state_storage[0].dropped_count, u32(0))
}

@(test)
test_shutdown_in_application_expectation_delivers_server_drain :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [4]u32
	entries: [4]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler      = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode    = .None,
			state_size   = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
			graceful_drain_ms = 1,
		},
		router = router,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Application_Expectation
	connection.connection_state.fd = tina.FD_Handle(17)
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.response.egress_size = 0
	connection.connection_state.response.egress_size_sent = 0

	ctx := tina.TinaContext {}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	shutdown_message: tina.Message
	shutdown_message.tag = tina.TAG_SHUTDOWN

	effect := _http_connection_handler(rawptr(&connection), &shutdown_message, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "shutdown drain handler should return close")
		}
	case:
		testing.expect(t, false, "shutdown during Application_Expectation should dispatch Server_Drain")
	}
	testing.expect(t, runtime.draining)
	testing.expect_value(t, route_state_storage[0].drain_count, u32(1))
}

@(test)
test_shutdown_while_reading_headers_closes_immediately :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [4]u32
	entries: [4]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	idle_slot_indices: [1]u16
	idle_slot_handles: [1]tina.Handle
	idle_slot_positions: [1]u16
	idle_slot_positions[0] = u16(IDLE_ARRAY_INDEX_NONE)

	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			graceful_drain_ms = 1,
		},
		connection_slot_count = 1,
		idle_slot_indices     = idle_slot_indices[:],
		idle_slot_handles     = idle_slot_handles[:],
		idle_slot_positions   = idle_slot_positions[:],
	}
	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.fd = tina.FD_Handle(17)

	ctx := tina.TinaContext {}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	shutdown_message: tina.Message
	shutdown_message.tag = tina.TAG_SHUTDOWN

	effect := _http_connection_handler(rawptr(&connection), &shutdown_message, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "shutdown while reading headers should close immediately")
		}
	case:
		testing.expect(t, false, "expected close effect")
	}
	testing.expect(t, runtime.draining)
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
}

@(private = "file")
Flush_Test_State :: struct {
	send_ready_count: u32,
}

@(private = "file")
_flush_send_ready_event_handler :: proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step {
	_ = request
	_ = response
	_ = route_context
	test_state := cast(^Flush_Test_State)state
	#partial switch _ in event {
	case Send_Ready:
		test_state.send_ready_count += 1
		return .Close
	case:
		return .Close
	}
}

@(test)
test_dispatch_step_flush_non_final_dispatches_send_ready_without_io :: proc(t: ^testing.T) {
	route_state_storage := [1]Flush_Test_State{}
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler      = rawptr(_flush_send_ready_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode    = .None,
			state_size   = u16(size_of(Flush_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
		free_count = 8,
		keepalive_reserve = 0,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.response.flags += {.Headers_Committed}
	connection.connection_state.response.egress_size = 0
	connection.connection_state.response.egress_size_sent = 0

	ctx := tina.TinaContext {}
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	effect := _dispatch_step(&connection, .Flush, &ctx)
	#partial switch _ in effect {
	case tina.Effect_Io:
		operation := effect.(tina.Effect_Io).operation
		if _, ok := operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "non-final flush with no bytes should re-enter route via Send_Ready")
		}
	case:
		testing.expect(t, false, "expected close after Send_Ready handler")
	}
	testing.expect_value(t, route_state_storage[0].send_ready_count, u32(1))
}

@(test)
test_dispatch_step_flush_final_skips_send_ready_without_io :: proc(t: ^testing.T) {
	route_state_storage := [1]Flush_Test_State{}
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler      = rawptr(_flush_send_ready_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode    = .None,
			state_size   = u16(size_of(Flush_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
		free_count = 8,
		keepalive_reserve = 0,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.response.flags += {.Headers_Committed, .Close_After_Send}
	connection.connection_state.response.egress_size = 0
	connection.connection_state.response.egress_size_sent = 0

	ctx := tina.TinaContext {}
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	effect := _dispatch_step(&connection, .Flush_Final, &ctx)
	#partial switch _ in effect {
	case tina.Effect_Io:
		operation := effect.(tina.Effect_Io).operation
		if _, ok := operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "final flush with close-after-send should close")
		}
	case:
		testing.expect(t, false, "expected close effect")
	}
	testing.expect_value(t, route_state_storage[0].send_ready_count, u32(0))
}

@(test)
test_send_complete_with_sendfile_plan_transitions_to_sendfile_io :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [4]u32
	entries: [4]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		free_count = 8,
		keepalive_reserve = 0,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(11)
	connection.connection_state.response.egress_size = 128
	connection.connection_state.response.egress_size_sent = 128
	connection.connection_state.sendfile_active = true
	connection.connection_state.sendfile_file_fd = tina.FD_Handle(22)
	connection.connection_state.sendfile_size_remaining = 4096
	connection.connection_state.sendfile_offset = 0

	ctx := tina.TinaContext{}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	effect := _connection_handle_send_complete(&connection, 0, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		operation := io_effect.operation
		#partial switch sendfile_op in operation {
		case tina.IoOp_Sendfile:
			testing.expect_value(t, sendfile_op.fd_socket, tina.FD_Handle(11))
			testing.expect_value(t, sendfile_op.fd_file, tina.FD_Handle(22))
			testing.expect_value(t, sendfile_op.source_offset, u64(0))
			testing.expect(t, sendfile_op.size > 0)
		case:
			testing.expect(t, false, "expected IoOp_Sendfile")
		}
	case:
		testing.expect(t, false, "expected Effect_Io")
	}
}

@(test)
test_send_complete_error_dispatches_peer_closed_then_closes :: proc(t: ^testing.T) {
	route_state_storage := [1]Peer_Closed_Test_State{}
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler       = rawptr(_peer_closed_route_event_handler),
			handler_kind  = .Event,
			body_size_max = 0,
			body_mode     = .None,
			state_size    = u16(size_of(Peer_Closed_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Sending
	connection.connection_state.fd = tina.FD_Handle(19)
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])

	ctx := tina.TinaContext{}
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	message: tina.Message
	message.tag = tina.IO_TAG_SEND_COMPLETE
	message.io.result = -1

	effect := _http_connection_handler(rawptr(&connection), &message, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "send failure should close after Peer_Closed dispatch")
		}
	case:
		testing.expect(t, false, "expected close effect")
	}
	testing.expect_value(t, route_state_storage[0].peer_closed_count, u32(1))
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
	testing.expect_value(t, connection.connection_state.response.egress_size, Egress_Size(0))
}

@(test)
test_sendfile_error_dispatches_peer_closed_then_closes :: proc(t: ^testing.T) {
	route_state_storage := [1]Peer_Closed_Test_State{}
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler       = rawptr(_peer_closed_route_event_handler),
			handler_kind  = .Event,
			body_size_max = 0,
			body_mode     = .None,
			state_size    = u16(size_of(Peer_Closed_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			timeouts = Timeouts {
				timeout_ms_idle   = 1,
				timeout_ms_header = 1,
				timeout_ms_body   = 1,
				timeout_ms_send   = 1,
			},
		},
		router = router,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Sending
	connection.connection_state.fd = tina.FD_Handle(23)
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.sendfile_active = true
	connection.connection_state.sendfile_size_remaining = 4096

	ctx := tina.TinaContext{}
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	message: tina.Message
	message.tag = tina.IO_TAG_SENDFILE_COMPLETE
	message.io.result = -1

	effect := _http_connection_handler(rawptr(&connection), &message, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "sendfile failure should close after Peer_Closed dispatch")
		}
	case:
		testing.expect(t, false, "expected close effect")
	}
	testing.expect_value(t, route_state_storage[0].peer_closed_count, u32(1))
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
	testing.expect_value(t, connection.connection_state.response.egress_size, Egress_Size(0))
}

@(test)
test_process_header_bytes_retains_tail_for_simple_request :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [8]u32
	entries: [8]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			limits   = DEFAULT_LIMITS,
			timeouts = DEFAULT_TIMEOUTS,
		},
		router = router,
	}

	header_views_storage: [64]Header_View
	response_header_storage: [1024]u8
	pipeline_tail_storage: [8192]u8

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(33)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.pipeline_tail_bytes = pipeline_tail_storage[:]
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	ctx := tina.TinaContext{}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	second_request := "GET /second HTTP/1.1\r\nHost: example\r\n\r\n"
	combined := transmute([]u8)string("GET /first HTTP/1.1\r\nHost: example\r\n\r\nGET /second HTTP/1.1\r\nHost: example\r\n\r\n")

	effect := _connection_process_header_bytes(&connection, combined, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Send); !ok {
			testing.expect(t, false, "simple request should stage and send a response")
		}
	case:
		testing.expect(t, false, "expected send effect for simple request")
	}

	second_request_size := len(second_request)
	testing.expect_value(t, int(connection.connection_state.pipeline_tail_size), second_request_size)
	retained_tail := string(connection.connection_state.pipeline_tail_bytes[:int(connection.connection_state.pipeline_tail_size)])
	testing.expect_value(t, retained_tail, second_request)
}

@(test)
test_process_header_bytes_closes_when_core_shutdown_started_before_http_runtime_draining :: proc(t: ^testing.T) {
	watchdog_state := u8(tina.Shard_State.Shutting_Down)
	shard := tina.Shard {
		timer_resolution_ns     = 1,
		watchdog_state_pointer = &watchdog_state,
	}
	spokes: [8]u32
	entries: [8]tina.Timer_Entry
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			limits   = DEFAULT_LIMITS,
			timeouts = DEFAULT_TIMEOUTS,
		},
		router = router,
	}

	header_views_storage: [64]Header_View
	response_header_storage: [1024]u8
	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(33)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	ctx := tina.TinaContext{}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	request_bytes := transmute([]u8)string("GET /first HTTP/1.1\r\nHost: example\r\n\r\n")
	effect := _connection_process_header_bytes(&connection, request_bytes, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Close); !ok {
			testing.expect(t, false, "core shutdown should close before dispatching a new request")
		}
	case:
		testing.expect(t, false, "expected close effect")
	}
	testing.expect(t, !runtime.draining, "HTTP runtime may not have seen TAG_SHUTDOWN yet")
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
}

@(test)
test_finalize_flushed_response_processes_pipeline_tail_before_recv :: proc(t: ^testing.T) {
	shard := tina.Shard{}
	spokes: [8]u32
	entries: [8]tina.Timer_Entry
	shard.timer_resolution_ns = 1
	tina.timer_wheel_init(
		&shard.timer_wheel,
		spokes[:],
		entries[:],
		0,
	)

	idle_slot_indices: [4]u16
	idle_slot_handles: [4]tina.Handle
	idle_slot_positions: [4]u16
	for position_index in 0 ..< len(idle_slot_positions) {
		idle_slot_positions[position_index] = u16(IDLE_ARRAY_INDEX_NONE)
	}

	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = Server_Runtime {
			limits   = DEFAULT_LIMITS,
			timeouts = DEFAULT_TIMEOUTS,
		},
		router = router,
		free_count = 4,
		keepalive_reserve = 0,
		connection_slot_count = 4,
		idle_slot_indices   = idle_slot_indices[:],
		idle_slot_handles   = idle_slot_handles[:],
		idle_slot_positions = idle_slot_positions[:],
	}

	header_views_storage: [64]Header_View
	response_header_storage: [1024]u8
	pipeline_tail_storage: [8192]u8

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(44)
	connection.connection_state.state = .Sending
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.pipeline_tail_bytes = pipeline_tail_storage[:]

	pipelined_request := "GET /tail HTTP/1.1\r\nHost: example\r\n\r\n"
	copy(connection.connection_state.pipeline_tail_bytes, transmute([]u8)string(pipelined_request))
	connection.connection_state.pipeline_tail_size = u16(len(pipelined_request))

	ctx := tina.TinaContext{}
	ctx._shard = &shard
	ctx.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)

	effect := _connection_finalize_flushed_response(&connection, &ctx)
	#partial switch io_effect in effect {
	case tina.Effect_Io:
		if _, ok := io_effect.operation.(tina.IoOp_Send); !ok {
			testing.expect(t, false, "pipeline tail should be parsed and dispatched before recv")
		}
	case:
		testing.expect(t, false, "expected immediate send effect from retained pipeline request")
	}

	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Sending)
}
