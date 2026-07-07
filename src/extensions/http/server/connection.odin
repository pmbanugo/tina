package http_server

import tina "../../.."
import "core:mem"
import "core:testing"

@(private = "package")
HTTP_SENDFILE_CHUNK_SIZE_MAX :: #config(HTTP_SENDFILE_CHUNK_SIZE_MAX, 256 * 1024)

@(private = "package")
_http_connection_init :: proc(self: rawptr, args: []u8) -> tina.Isolate_Transition {
	connection := cast(^HTTP_Connection)self
	if len(args) < size_of(HTTP_Connection_Init_Args) {
		return tina.transition_to_crash(.Init_Failed)
	}

	init_args := (cast(^HTTP_Connection_Init_Args)raw_data(args))^
	runtime := init_args.shard_runtime
	if runtime == nil {
		return tina.transition_to_crash(.Init_Failed)
	}

	frame_size :=
		int(runtime.server.parse_budget.request_line_size_max) +
		int(runtime.server.parse_budget.header_size_max)
	connection.connection_state.shard_runtime = runtime
	connection.connection_state.deadline_timer_handle = tina.ctx_timer_acquire()
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(
			connection.connection_state.deadline_timer_handle != tina.TIMER_HANDLE_NONE,
			"_http_connection_init: failed to acquire renewable deadline slot",
		)
	}
	connection.connection_state.deadline_ns = 0
	connection.connection_state.self_handle = tina.ctx_self_handle()
	connection.connection_state.fd = init_args.client_fd
	_connection_init_working_memory_regions(connection, frame_size)
	connection.connection_state.peer = {}
	_runtime_active_slot_add(connection)
	_connection_begin_keep_alive_wait(connection)

	return tina.transition_to_wait_io_or_crash(
		tina.ctx_submit_io(
			tina.IoOp_Recv {
				fd = init_args.client_fd,
				buffer_size_max = u32(runtime.server.parse_budget.request_line_size_max) +
				u32(runtime.server.parse_budget.header_size_max),
			},
		),
	)
}

@(private = "file")
_connection_init_working_memory_regions :: proc(
	connection: ^HTTP_Connection,
	frame_size: int,
) {
	state := &connection.connection_state
	runtime := state.shard_runtime

	working_bytes := _connection_working_memory_bytes()
	working_offset := 0

	state.request_frame_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		frame_size,
	)
	state.buffered_body_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.buffered_body_size_max),
	)
	state.pipeline_tail_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.memory_budget.pipeline_size_max),
	)

	header_view_storage := _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.memory_budget.header_count_max) * size_of(Header_View),
	)
	if len(header_view_storage) > 0 {
		state.header_views = mem.slice_ptr(
			cast(^Header_View)raw_data(header_view_storage),
			int(runtime.server.memory_budget.header_count_max),
		)
	}

	// Debug/test-only structural invariant: both budgets derive from the same
	// `Limits.header_count_max`, so the working-memory layout matches the
	// parser cap by construction. Defaults are checked at compile time in
	// `limits.odin`; operator values are validated at install.
	when ODIN_DEBUG || ODIN_TEST {
		assert(
			len(state.header_views) == int(runtime.server.parse_budget.header_count_max),
			"_connection_init_working_memory_regions: header_views region under-provisioned relative to Parse_Budget.header_count_max — working-memory layout drift",
		)
	}

	state.route_state_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.route_state_size_max),
	)

	request_arena_bytes := _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.memory_budget.request_arena_size),
	)
	mem.arena_init(&state.request_arena_region, request_arena_bytes)

	state.response_header_bytes = _connection_working_region_take(
		working_bytes,
		&working_offset,
		int(runtime.server.memory_budget.response_header_bytes_max),
	)
}

@(private = "file")
_connection_working_memory_bytes :: proc() -> []u8 {
	return tina.ctx_working_arena_bytes()
}

@(private = "file")
_connection_working_region_take :: proc(
	working_bytes: []u8,
	working_offset: ^int,
	region_size: int,
) -> []u8 {
	if region_size <= 0 {
		return nil
	}
	aligned_offset := _align_up(working_offset^)
	aligned_size := _align_up(region_size)
	end_offset := aligned_offset + aligned_size
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(
			end_offset <= len(working_bytes),
			"_connection_working_region_take: working memory too small",
		)
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
) -> tina.Isolate_Transition {
	connection := cast(^HTTP_Connection)self
	state := &connection.connection_state

	switch message.tag {
	case tina.TAG_SHUTDOWN:
		_connection_mark_draining(connection)
		if state.state == .Application_Expectation {
			return _connection_dispatch_server_drain(connection)
		}
		return _connection_begin_close(connection)

	case TAG_HEADER_TIMEOUT:
		if state.state != .Recv_Headers {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if state.request.route_index != ROUTE_INDEX_NONE {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if !_connection_timeout_is_current(connection, message.correlation) {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		state.response.flags += {.Close_After_Send, .Aborted}
		return _connection_stage_canned_response(
			connection,
			transmute([]u8)string(ERROR_RESPONSE_408_REQUEST_TIMEOUT),
		)

	case TAG_BODY_TIMEOUT:
		if state.state != .Recv_Body_Streamed && state.state != .Recv_Body_Buffered {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if !_connection_timeout_is_current(connection, message.correlation) {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		state.response.flags += {.Close_After_Send, .Aborted}
		return _connection_stage_canned_response(
			connection,
			transmute([]u8)string(ERROR_RESPONSE_408_REQUEST_TIMEOUT),
		)

	case TAG_SEND_TIMEOUT:
		if state.state != .Sending {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if !_connection_timeout_is_current(connection, message.correlation) {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		return _connection_begin_close(connection)

	case TAG_IDLE_TIMEOUT:
		if state.state != .Keep_Alive_Idle {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if !_connection_timeout_is_current(connection, message.correlation) {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		return _connection_begin_close(connection)

	case TAG_DRAIN_TIMEOUT:
		when tina.TINA_RUNTIME_ASSERTIONS {
			assert(
				state.shard_runtime != nil,
				"_http_connection_handler: shard runtime is nil during drain timeout",
			)
		}
		if !state.shard_runtime.draining {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if !_connection_timeout_is_current(connection, message.correlation) {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		return _connection_begin_close(connection)

	case TAG_EVICT:
		if state.state != .Keep_Alive_Idle {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		state.response.flags += {.Close_After_Send}
		return _connection_begin_close(connection)

	case tina.IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			return _connection_begin_close(connection)
		}
		if state.state == .Keep_Alive_Idle {
			_connection_prepare_incoming_request(connection)
		}
		if state.shard_runtime.draining {
			return _connection_begin_close(connection)
		}
		return _connection_handle_recv_complete(
			connection,
			message.io.buffer_index,
			u32(message.io.result),
		)

	case tina.IO_TAG_SEND_COMPLETE:
		if message.io.result <= 0 {
			return _connection_dispatch_peer_closed(connection)
		}
		return _connection_handle_send_complete(connection, u32(message.io.result))

	case tina.IO_TAG_SENDFILE_COMPLETE:
		if message.io.result < 0 {
			return _connection_dispatch_peer_closed(connection)
		}
		return _connection_handle_sendfile_complete(connection, u32(message.io.result))

	case tina.IO_TAG_CLOSE_COMPLETE:
		_connection_complete_close(connection)
		return tina.ISOLATE_TRANSITION_DONE

	case:
		if message.tag >= tina.USER_MESSAGE_TAG_BASE {
			if state.state != .Application_Expectation {
				_connection_store_pending_application_message(state, message)
				return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
			}
			return _connection_handle_application_mailbox_message(connection, message)
		}
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

@(private = "file")
_connection_handle_recv_complete :: proc(
	connection: ^HTTP_Connection,
	buffer_index: tina.IO_Slot_Index,
	buffer_size: u32,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	buffer := tina.ctx_read_io_slot( buffer_index, buffer_size)
	if state.state == .Recv_Body_Streamed || state.state == .Recv_Body_Buffered {
		return _connection_handle_body_recv_complete(connection, buffer)
	}
	if len(buffer) == 0 {
		if _connection_should_drain(runtime) {
			return _connection_begin_close(connection)
		}
		return tina.transition_to_wait_io_or_crash(
			tina.ctx_submit_io(
				tina.IoOp_Recv {
					fd = state.fd,
					buffer_size_max = _recv_buffer_size_max(runtime),
				},
			),
		)
	}

	if _connection_should_drain(runtime) && state.response.egress_size == 0 {
		return _connection_begin_close(connection)
	}

	return _connection_process_header_bytes(connection, buffer)
}

@(private = "file")
_connection_process_header_bytes :: proc(
	connection: ^HTTP_Connection,
	buffer: []u8,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		return _connection_begin_close(connection)
	}

	source := buffer
	tail_bytes: []u8
	parsed_offset_start := u16(0)
	ingress_size_before := u16(state.ingress_size)
	if ingress_size_before > 0 {
		storage := state.request_frame_bytes
		storage_size := u16(len(storage))
		buffer_size := u16(len(buffer))
		append_size := min(buffer_size, storage_size - ingress_size_before)
		if append_size > 0 {
			copy(storage[ingress_size_before:][:append_size], buffer[:append_size])
		}
		state.ingress_size = Ingress_Size(ingress_size_before + append_size)
		source = state.request_frame_bytes[:state.ingress_size]
		tail_bytes = buffer[append_size:]
		parsed_offset_start = u16(state.ingress_parsed_offset)
	}

	parse_status, parsed_offset := parse_step(
		&state.parser,
		&state.request,
		state.header_views,
		source,
		parsed_offset_start,
		runtime.server.parse_budget,
	)
	#partial switch parse_status {
	case .Need_More:
		if len(tail_bytes) > 0 {
			limit_status := Parse_Status.Error_Header_Too_Large
			if state.parser.phase == .Request_Line {
				limit_status = .Error_Bad_Request
			}
			return _connection_send_parse_error(connection, limit_status)
		}
		if ingress_size_before > 0 {
			state.ingress_parsed_offset = Ingress_Offset(parsed_offset)
		} else {
			if len(buffer) > len(state.request_frame_bytes) || len(buffer) > int(max(u16)) {
				limit_status := Parse_Status.Error_Header_Too_Large
				if state.parser.phase == .Request_Line {
					limit_status = .Error_Bad_Request
				}
				return _connection_send_parse_error(connection, limit_status)
			}
			if len(buffer) > 0 {
				copy(state.request_frame_bytes[:len(buffer)], buffer)
			}
			state.ingress_size = Ingress_Size(u16(len(buffer)))
			state.ingress_parsed_offset = Ingress_Offset(parsed_offset)
		}
		if state.parser.phase == .Body_Fixed ||
		   state.parser.phase == .Chunk_Size ||
		   state.parser.phase == .Chunk_Data ||
		   state.parser.phase == .Chunk_Data_CRLF ||
		   state.parser.phase == .Trailers {
			_connection_arm_body_timeout(connection)
		}
		return tina.transition_to_wait_io_or_crash(
			tina.ctx_submit_io(
				tina.IoOp_Recv {
					fd = state.fd,
					buffer_size_max = _recv_buffer_size_max(runtime),
				},
			),
		)

	case .Headers_Done:
		if _connection_should_drain(runtime) {
			return _connection_begin_close(connection)
		}
		request_frame, canonical_error := _connection_canonicalize_request_frame(
			connection,
			source,
			parsed_offset,
		)
		if canonical_error == .Bad_Path {
			return _connection_send_parse_error(connection, .Error_Bad_Request)
		}
		if canonical_error == .Frame_Too_Large {
			return _connection_send_parse_error(connection, .Error_Header_Too_Large)
		}

		request := _connection_make_request(connection, request_frame)
		response := _connection_make_response(connection)
		step := _dispatch_route(&request, &response)
		if state.request.route_index != ROUTE_INDEX_NONE {
			descriptor := runtime.router.descriptors[state.request.route_index]
			if descriptor.body_mode != .None || descriptor.handler_kind == .Event {
				_connection_retain_request_frame(connection, request_frame)
			}
		}
		if parsed_offset < u16(len(source)) || len(tail_bytes) > 0 {
			if !_connection_retain_tail_pair(connection, source[parsed_offset:], tail_bytes) {
				if step == .Read_Body {
					return _connection_begin_close(connection)
				}
				state.response.flags += {.Close_After_Send}
			}
		}
		return _dispatch_step(connection, step)

	case .Error_Bad_Request,
	     .Error_Expectation,
	     .Error_Header_Too_Large,
	     .Error_Not_Implemented,
	     .Error_Version:
		return _connection_send_parse_error(connection, parse_status)

	case:
		return _connection_begin_close(connection)
	}
}

@(private = "file")
Request_Frame_Canonicalization_Error :: enum u8 {
	None,
	Bad_Path,
	Frame_Too_Large,
}

@(private = "file")
_connection_canonicalize_request_frame :: proc(
	connection: ^HTTP_Connection,
	frame: []u8,
	frame_size: u16,
) -> (
	canonical_frame: []u8,
	error: Request_Frame_Canonicalization_Error,
) {
	state := &connection.connection_state
	path_offset := state.request.path_offset
	path_size := state.request.path_size

	for path_index: u16 = 0; path_index < path_size; path_index += 1 {
		if frame[path_offset + path_index] != '%' do continue

		if int(frame_size) > len(state.request_frame_bytes) {
			when tina.TINA_RUNTIME_ASSERTIONS {
				assert(false, "_connection_canonicalize_request_frame: parsed frame exceeds retained frame capacity")
			}
			return nil, .Frame_Too_Large
		}
		copy(state.request_frame_bytes[:frame_size], frame[:frame_size])

		path_bytes := state.request_frame_bytes[path_offset:][:path_size]
		path_size_canonical, path_error, _ := path_canonicalize_selective_in_place(path_bytes)
		if path_error != .None {
			return nil, .Bad_Path
		}
		if path_size_canonical > int(path_size) {
			when tina.TINA_RUNTIME_ASSERTIONS {
				assert(false, "_connection_canonicalize_request_frame: canonical path grew")
			}
			return nil, .Bad_Path
		}

		shift_size := path_size - u16(path_size_canonical)
		if shift_size > 0 {
			source_offset := path_offset + path_size
			target_offset := path_offset + u16(path_size_canonical)
			move_size := frame_size - source_offset
			copy(
				state.request_frame_bytes[target_offset:][:move_size],
				state.request_frame_bytes[source_offset:][:move_size],
			)

			state.request.path_size = u16(path_size_canonical)
			state.request.target_size -= shift_size
			if state.request.query_offset != 0 {
				state.request.query_offset -= shift_size
			}
			state.request.path_segment_count = PATH_SEGMENT_COUNT_NONE
			state.parser.request_line_size -= shift_size

			for header_index: u8 = 0; header_index < state.request.header_count; header_index += 1 {
				state.header_views[header_index].name_offset -= shift_size
				state.header_views[header_index].value_offset -= shift_size
			}
		}

		return state.request_frame_bytes[:frame_size - shift_size], .None
	}

	return frame[:frame_size], .None
}

@(private = "package")
_connection_dispatch_match :: proc(
	connection: ^HTTP_Connection,
	frame: []u8,
	match_result: Match_Result,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	response := _connection_make_response(connection)
	request := _connection_make_request(connection, frame)

	#partial switch match_result.outcome {
	case .Found:
		state.request.route_index = match_result.route_index
		step := _dispatch_route(&request, &response)
		return _dispatch_step(connection, step)

	case .Method_Not_Allowed:
		allow_buffer: [128]u8
		allow_size := allow_value_write(allow_buffer[:], match_result.methods_mask)
		if allow_size > 0 {
			_ = header_set(&response, "Allow", string(allow_buffer[:allow_size]))
		}
		step := respond_text(&response, HTTP_STATUS_METHOD_NOT_ALLOWED, "Method Not Allowed")
		return _dispatch_step(connection, step)

	case .Not_Found:
		step := respond_text(&response, HTTP_STATUS_NOT_FOUND, "Not Found")
		return _dispatch_step(connection, step)
	}

	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

@(private = "file")
_connection_send_parse_error :: proc(
	connection: ^HTTP_Connection,
	parse_status: Parse_Status,
) -> tina.Isolate_Transition {
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
) -> tina.Isolate_Transition {
	_ = frame
	_ = method
	_ = is_asterisk
	response := _connection_make_response(connection)
	step := respond_text(&response, HTTP_STATUS_NOT_FOUND, "Not Found")
	return _dispatch_step(connection, step)
}

@(private = "file")
_connection_handle_send_complete :: proc(
	connection: ^HTTP_Connection,
	bytes_sent: u32,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(
			state.shard_runtime != nil,
			"_connection_handle_send_complete: shard runtime is nil",
		)
	}
	remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
	if remaining > 0 {
		sent := min(int(bytes_sent), remaining)
		state.response.egress_size_sent += Egress_Size_Sent(sent)
		remaining -= sent
		if remaining > 0 {
			start_offset := state.response.egress_size_sent
			_connection_arm_send_timeout(connection)
			return tina.transition_to_wait_io_or_crash(
				tina.ctx_io_send(
					connection,
					state.fd,
					connection.egress_buffer[start_offset:][:remaining],
				),
			)
		}
	}

	if state.sendfile_active {
		return _connection_drive_sendfile(connection)
	}

	if state.request.route_index != ROUTE_INDEX_NONE {
		descriptor := state.shard_runtime.router.descriptors[state.request.route_index]
		if state.response.status_code == HTTP_STATUS_CONTINUE {
			_response_prepare_next_message(&state.response)
			state.state =
				.Recv_Body_Streamed if descriptor.body_mode == .Streamed else .Recv_Body_Buffered
			state.response_flush_final = false
			return _connection_drive_body_read(connection)
		}
	}

	if state.response_flush_final {
		state.response_flush_final = false
		return _connection_finalize_flushed_response(connection)
	}

	return _connection_continue_after_non_final_flush(connection)
}

@(private = "file")
_connection_handle_sendfile_complete :: proc(
	connection: ^HTTP_Connection,
	bytes_sent: u32,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	if !state.sendfile_active {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	if bytes_sent == 0 {
		if state.sendfile_size_remaining == 0 {
			state.sendfile_active = false
			return _connection_finalize_flushed_response(connection)
		}
		state.response.flags += {.Close_After_Send, .Aborted}
		return _connection_dispatch_peer_closed(connection)
	}

	sent_size := min(u64(bytes_sent), state.sendfile_size_remaining)
	state.sendfile_offset += sent_size
	state.sendfile_size_remaining -= sent_size
	state.response.body_size_sent += sent_size

	if state.sendfile_size_remaining == 0 {
		state.sendfile_active = false
		return _connection_finalize_flushed_response(connection)
	}

	return _connection_drive_sendfile(connection)
}

@(private = "file")
_connection_drive_sendfile :: proc(
	connection: ^HTTP_Connection,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	if !state.sendfile_active || state.sendfile_size_remaining == 0 {
		state.sendfile_active = false
		return _connection_finalize_flushed_response(connection)
	}

	chunk_size := min(state.sendfile_size_remaining, u64(HTTP_SENDFILE_CHUNK_SIZE_MAX))
	if chunk_size == 0 {
		state.sendfile_active = false
		return _connection_finalize_flushed_response(connection)
	}

	state.state = .Sending
	_connection_arm_send_timeout(connection)
	return tina.transition_to_wait_io_or_crash(
		tina.ctx_io_sendfile(
			state.fd,
			state.sendfile_file_fd,
			state.sendfile_offset,
			u32(chunk_size),
		),
	)
}

@(private = "file")
_connection_finalize_flushed_response :: proc(
	connection: ^HTTP_Connection,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(
			state.shard_runtime != nil,
			"_connection_finalize_flushed_response: shard runtime is nil",
		)
	}
	state.sendfile_active = false
	state.sendfile_file_fd = tina.FD_HANDLE_NONE
	state.sendfile_offset = 0
	state.sendfile_size_remaining = 0
	if .Close_After_Send in state.response.flags ||
	   .In_Drain in state.response.flags ||
	   state.state == .Closing {
		return _connection_begin_close(connection)
	}

	if state.shard_runtime.free_count <= state.shard_runtime.keepalive_reserve {
		state.response.flags += {.Close_After_Send}
		return _connection_begin_close(connection)
	}

	if _connection_should_drain(state.shard_runtime) {
		return _connection_begin_close(connection)
	}

	if state.pipeline_tail_size > 0 {
		pipeline_tail_size := state.pipeline_tail_size
		_connection_begin_keep_alive_wait(connection)
		_connection_prepare_incoming_request(connection)
		state.pipeline_tail_size = 0
		return _connection_process_header_bytes(
			connection,
			state.pipeline_tail_bytes[:int(pipeline_tail_size)],
		)
	}

	_connection_begin_keep_alive_wait(connection)
	return tina.transition_to_wait_io_or_crash(
		tina.ctx_submit_io(
			tina.IoOp_Recv {
				fd = state.fd,
				buffer_size_max = _recv_buffer_size_max(state.shard_runtime),
			},
		),
	)
}

@(private = "file")
_connection_continue_after_non_final_flush :: proc(
	connection: ^HTTP_Connection,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(
			state.shard_runtime != nil,
			"_connection_continue_after_non_final_flush: shard runtime is nil",
		)
	}
	state.response_flush_final = false

	if .Close_After_Send in state.response.flags ||
	   .In_Drain in state.response.flags ||
	   state.state == .Closing {
		return _connection_finalize_flushed_response(connection)
	}
	if state.shard_runtime.free_count <= state.shard_runtime.keepalive_reserve {
		state.response.flags += {.Close_After_Send}
		return _connection_finalize_flushed_response(connection)
	}
	if _connection_should_drain(state.shard_runtime) {
		return _connection_finalize_flushed_response(connection)
	}

	state.response.egress_size = 0
	state.response.egress_size_sent = 0

	if state.request.route_index != ROUTE_INDEX_NONE {
		descriptor := state.shard_runtime.router.descriptors[state.request.route_index]
		if descriptor.handler_kind == .Event {
			request := _connection_make_request(connection, nil)
			response := _connection_make_response(connection)
			route_context := _make_route_context(state)
			event := Route_Event(Send_Ready{})
			step := _dispatch_route_event(
				event,
				&request,
				&response,
				route_context,
				_route_state_ptr(state),
			)
			return _dispatch_step(connection, step)
		}
	}

	return _connection_finalize_flushed_response(connection)
}

@(private = "file")
_connection_stage_canned_response :: proc(
	connection: ^HTTP_Connection,
	response_bytes: []u8,
) -> tina.Isolate_Transition {
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
	_connection_arm_send_timeout(connection)
	return tina.transition_to_wait_io_or_crash(
		tina.ctx_io_send( connection, state.fd, connection.egress_buffer[:len(response_bytes)]),
	)
}

@(private = "package")
_connection_make_request :: proc(
	connection: ^HTTP_Connection,
	frame: []u8,
) -> Request {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(connection != nil, "_connection_make_request: connection is nil")
	}
	request_frame := frame
	if len(request_frame) == 0 && connection.connection_state.request_frame_size > 0 {
		request_frame = connection.connection_state.request_frame_bytes[:connection.connection_state.request_frame_size]
	}
	return Request {
		connection_state = &connection.connection_state,
		frame = request_frame,
	}
}

@(private = "package")
_connection_date_value :: proc(connection: ^HTTP_Connection) -> []u8 {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		return nil
	}

	monotonic_ns := tina.ctx_monotonic_time_ns()
	if monotonic_ns >= runtime.date_cache.next_second_threshold_ns {
		unix_epoch_ns := wall_clock_unix_epoch_ns(u64(monotonic_ns))
		update_date_cache(&runtime.date_cache, monotonic_ns, unix_epoch_ns)
	}

	if runtime.date_cache.size == 0 {
		return nil
	}
	return runtime.date_cache.bytes[:int(runtime.date_cache.size)]
}

@(private = "package")
_connection_make_response :: proc(
	connection: ^HTTP_Connection,
) -> Response {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(connection != nil, "_connection_make_response: connection is nil")
	}
	return Response{connection = connection}
}

@(test)
test_connection_make_request_and_response_populate_internal_facades :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)

	frame := transmute([]u8)string("GET / HTTP/1.1\r\n\r\n")
	request := _connection_make_request(&fixture.connection, frame)
	response := _connection_make_response(&fixture.connection)

	testing.expect(
		t,
		request.connection_state == &fixture.connection.connection_state,
		"request must point at the connection state",
	)
	testing.expect(
		t,
		response.connection == &fixture.connection,
		"response must point at the connection",
	)
	testing.expect_value(t, string(request.frame), string(frame))
}

@(test)
test_connection_make_request_uses_retained_frame_when_frame_absent :: proc(t: ^testing.T) {
	fixture: HTTP_Test_Fixture
	http_test_fixture_init(&fixture)

	retained_frame := transmute([]u8)string("GET /retained HTTP/1.1\r\n\r\n")
	copy(fixture.connection.connection_state.request_frame_bytes[:], retained_frame)
	fixture.connection.connection_state.request_frame_size = u16(len(retained_frame))

	request := _connection_make_request(&fixture.connection, nil)
	testing.expect_value(t, string(request.frame), string(retained_frame))
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
_connection_dispatch_server_drain :: proc(
	connection: ^HTTP_Connection,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || state.request.route_index == ROUTE_INDEX_NONE {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.handler_kind != .Event {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	request := _connection_make_request(connection, nil)
	response := _connection_make_response(connection)
	route_context := _make_route_context(state)
	step := _dispatch_route_event(
		Route_Event(Server_Drain{}),
		&request,
		&response,
		route_context,
		_route_state_ptr(state),
	)
	return _dispatch_step(connection, step)
}

@(private = "file")
_connection_dispatch_peer_closed :: proc(
	connection: ^HTTP_Connection,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime != nil && state.request.route_index != ROUTE_INDEX_NONE {
		descriptor := runtime.router.descriptors[state.request.route_index]
		if descriptor.handler_kind == .Event {
			request := _connection_make_request(connection, nil)
			response := _connection_make_response(connection)
			route_context := _make_route_context(state)
			_ = _dispatch_route_event(
				Route_Event(Peer_Closed{}),
				&request,
				&response,
				route_context,
				_route_state_ptr(state),
			)
		}
	}

	return _connection_begin_close(connection)
}

@(private = "file")
_connection_handle_application_mailbox_message :: proc(
	connection: ^HTTP_Connection,
	message: ^tina.Message,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if state.state != .Application_Expectation || runtime == nil {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
	if state.request.route_index == ROUTE_INDEX_NONE {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.handler_kind != .Event {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	is_timeout := message.tag == HTTP_INTERNAL_TAG_AWAIT_TIMEOUT
	message_tag := Message_Tag(message.tag)

	#partial switch state.application_expectation_kind {
	case .Reply:
		if is_timeout {
			if state.application_correlation_id != message.correlation {
				return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
			}
			event := Route_Event(
				Application_Reply {
					source_handle = state.application_expected_source,
					message_tag = state.application_expected_tag,
					payload_bytes = {},
					reply_result = .Timeout,
				},
			)
			request := _connection_make_request(connection, nil)
			response := _connection_make_response(connection)
			route_context := _make_route_context(state)
			step := _dispatch_route_event(
				event,
				&request,
				&response,
				route_context,
				_route_state_ptr(state),
			)
			return _dispatch_step(connection, step)
		}
		if state.application_expected_source != message.user.source {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if state.application_expected_tag != message_tag {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if state.application_correlation_id != message.correlation {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		event := Route_Event(
			Application_Reply {
				source_handle = message.user.source,
				message_tag = message_tag,
				payload_bytes = message.user.payload[:int(message.user.payload_size)],
				reply_result = .Ok,
			},
		)
		request := _connection_make_request(connection, nil)
		response := _connection_make_response(connection)
		route_context := _make_route_context(state)
		step := _dispatch_route_event(
			event,
			&request,
			&response,
			route_context,
			_route_state_ptr(state),
		)
		return _dispatch_step(connection, step)

	case .Notification:
		if !is_timeout {
			if state.application_expected_source != tina.ISOLATE_HANDLE_NONE &&
			   state.application_expected_source != message.user.source {
				return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
			}
			if state.application_expected_tag != Message_Tag(0) &&
			   state.application_expected_tag != message_tag {
				return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
			}
			event := Route_Event(
				Application_Notification {
					source_handle = message.user.source,
					message_tag = message_tag,
					payload_bytes = message.user.payload[:int(message.user.payload_size)],
				},
			)
			request := _connection_make_request(connection, nil)
			response := _connection_make_response(connection)
			route_context := _make_route_context(state)
			step := _dispatch_route_event(
				event,
				&request,
				&response,
				route_context,
				_route_state_ptr(state),
			)
			return _dispatch_step(connection, step)
		}
		if state.application_correlation_id != message.correlation {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		event := Route_Event(
			Application_Reply {
				source_handle = state.application_expected_source,
				message_tag = state.application_expected_tag,
				payload_bytes = {},
				reply_result = .Timeout,
			},
		)
		request := _connection_make_request(connection, nil)
		response := _connection_make_response(connection)
		route_context := _make_route_context(state)
		step := _dispatch_route_event(
			event,
			&request,
			&response,
			route_context,
			_route_state_ptr(state),
		)
		return _dispatch_step(connection, step)
	}

	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

@(private = "file")
_dispatch_step :: proc(
	connection: ^HTTP_Connection,
	step: Route_Step,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	when tina.TINA_RUNTIME_ASSERTIONS {
		if .Fixed_Length_Body_Violation in state.response.flags {
			assert(false, "_dispatch_step: fixed-length response body violates declared Content-Length")
		}
	}
	if step != .Expect_Application &&
	   step != .Flush &&
	   step != .Flush_Final &&
	   int(state.response.egress_size) > int(state.response.egress_size_sent) {
		state.state = .Sending
		_connection_arm_send_timeout(connection)
		if step == .Close {
			state.response.flags += {.Close_After_Send}
			state.response_flush_final = true
		}
		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		start_offset := state.response.egress_size_sent
		return tina.transition_to_wait_io_or_crash(
			tina.ctx_io_send(
				connection,
				state.fd,
				connection.egress_buffer[start_offset:][:remaining],
			),
		)
	}

	#partial switch step {
	case .Close:
		return _connection_begin_close(connection)
	case .Read_Body:
		return _connection_drive_body_read(connection)
	case .Flush, .Flush_Final:
		response := _connection_make_response(connection)
		final := step == .Flush_Final
		if !_response_prepare_flush(&response, final) {
			if int(state.response.egress_size) > int(state.response.egress_size_sent) {
				state.response_flush_final = true
				state.state = .Sending
				_connection_arm_send_timeout(connection)
				remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
				start_offset := state.response.egress_size_sent
				return tina.transition_to_wait_io_or_crash(
					tina.ctx_io_send(
						connection,
						state.fd,
						connection.egress_buffer[start_offset:][:remaining],
					),
				)
			}
			return _connection_begin_close(connection)
		}

		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		if remaining > 0 {
			state.response_flush_final = final
			state.state = .Sending
			_connection_arm_send_timeout(connection)
			start_offset := state.response.egress_size_sent
			return tina.transition_to_wait_io_or_crash(
				tina.ctx_io_send(
					connection,
					state.fd,
					connection.egress_buffer[start_offset:][:remaining],
				),
			)
		}

		if final {
			state.response_flush_final = false
			return _connection_finalize_flushed_response(connection)
		}
		return _connection_continue_after_non_final_flush(connection)

	case .Expect_Application:
		when tina.TINA_RUNTIME_ASSERTIONS {
			assert(
				int(state.response.egress_size) == int(state.response.egress_size_sent),
				"Cannot park with unsent HTTP bytes. Call flush() first; on Send_Ready, then expect_*().",
			)
		}
		if int(state.response.egress_size) != int(state.response.egress_size_sent) {
			return _connection_begin_close(connection)
		}
		when tina.TINA_RUNTIME_ASSERTIONS {
			assert(
				state.shard_runtime != nil,
				"_dispatch_step: shard runtime is nil while parking application expectation",
			)
		}
		if state.application_timeout_ns > 0 {
			tina.ctx_register_timer_with_correlation(
				state.application_timeout_ns,
				HTTP_INTERNAL_TAG_AWAIT_TIMEOUT,
				state.application_correlation_id,
			)
		}
		state.state = .Application_Expectation
		pending_message: tina.Message
		if _connection_pending_application_message_take(state, &pending_message) {
			return _connection_handle_application_mailbox_message(
				connection,
				&pending_message,
			)
		}
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	case:
		return _connection_begin_close(connection)
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
	return _connection_retain_tail_pair(connection, source, nil)
}

@(private = "file")
_connection_retain_tail_pair :: proc(
	connection: ^HTTP_Connection,
	source_first: []u8,
	source_second: []u8,
) -> bool {
	state := &connection.connection_state
	retained_size := len(source_first) + len(source_second)
	if retained_size == 0 {
		state.pipeline_tail_size = 0
		return true
	}
	if retained_size > len(state.pipeline_tail_bytes) || retained_size > int(max(u16)) {
		state.pipeline_tail_size = 0
		return false
	}

	write_offset := 0
	if len(source_first) > 0 {
		copy(state.pipeline_tail_bytes[write_offset:], source_first)
		write_offset += len(source_first)
	}
	if len(source_second) > 0 {
		copy(state.pipeline_tail_bytes[write_offset:], source_second)
	}
	state.pipeline_tail_size = u16(retained_size)
	return true
}

@(private = "file")
_connection_handle_body_recv_complete :: proc(
	connection: ^HTTP_Connection,
	buffer: []u8,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	if len(buffer) == 0 {
		return _connection_drive_body_read(connection)
	}

	source := buffer
	if state.pipeline_tail_size > 0 {
		combined_size := int(state.pipeline_tail_size) + len(buffer)
		if combined_size > len(state.pipeline_tail_bytes) {
			return _connection_begin_close(connection)
		}
		copy(state.pipeline_tail_bytes[int(state.pipeline_tail_size):], buffer)
		source = state.pipeline_tail_bytes[:combined_size]
		state.pipeline_tail_size = 0
	}

	return _connection_process_body_bytes(connection, source)
}

@(private = "file")
_connection_drive_body_read :: proc(
	connection: ^HTTP_Connection,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || state.request.route_index == ROUTE_INDEX_NONE {
		return _connection_begin_close(connection)
	}

	descriptor := runtime.router.descriptors[state.request.route_index]
	if descriptor.body_mode == .None {
		return _connection_begin_close(connection)
	}
	if descriptor.body_mode == .Buffered &&
	   state.parser.phase != .Complete &&
	   .Expect_100 in state.parser.flags &&
	   .Interim_100_Sent not_in state.response.flags {
		response := _connection_make_response(connection)
		continue_100(&response)
	}

	if int(state.response.egress_size) > int(state.response.egress_size_sent) {
		state.state = .Sending
		_connection_arm_send_timeout(connection)
		start_offset := state.response.egress_size_sent
		remaining := int(state.response.egress_size) - int(state.response.egress_size_sent)
		return tina.transition_to_wait_io_or_crash(
			tina.ctx_io_send(
				connection,
				state.fd,
				connection.egress_buffer[start_offset:][:remaining],
			),
		)
	}

	if descriptor.body_mode == .Streamed &&
	   state.parser.phase == .Complete &&
	   !state.request_body_complete_notified {
		request := _connection_make_request(connection, nil)
		response := _connection_make_response(connection)
		route_context := _make_route_context(state)
		state.request_body_complete_notified = true
		step := _dispatch_route_event(
			Route_Event(Body_Chunk{data = {}, is_last = true}),
			&request,
			&response,
			route_context,
			_route_state_ptr(state),
		)
		return _dispatch_step(connection, step)
	}

	if descriptor.body_mode == .Buffered && state.parser.phase == .Complete {
		request := _connection_make_request(connection, nil)
		response := _connection_make_response(connection)
		step := _dispatch_route(&request, &response)
		return _dispatch_step(connection, step)
	}

	if state.pipeline_tail_size > 0 {
		source := state.pipeline_tail_bytes[:state.pipeline_tail_size]
		state.pipeline_tail_size = 0
		return _connection_process_body_bytes(connection, source)
	}

	state.state = .Recv_Body_Streamed if descriptor.body_mode == .Streamed else .Recv_Body_Buffered
	_connection_arm_body_timeout(connection)
	return tina.transition_to_wait_io_or_crash(
		tina.ctx_submit_io(
			tina.IoOp_Recv {
				fd = state.fd,
				buffer_size_max = _recv_buffer_size_max(runtime),
			},
		),
	)
}

@(private = "file")
_connection_process_body_bytes :: proc(
	connection: ^HTTP_Connection,
	source: []u8,
) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil || state.request.route_index == ROUTE_INDEX_NONE {
		return _connection_begin_close(connection)
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
				return _connection_drive_body_read(connection)
			}

			result: Body_Drain_Result
			result, state.buffered_body_size, state.request_body_size_received = drain_request_body(
				&state.parser,
				remaining_source,
				state.buffered_body_bytes,
				state.buffered_body_size,
				state.request_body_size_received,
				descriptor.body_size_max,
				runtime.server.parse_budget,
				buffered = false,
			)

			if result.protocol_error {
				return _connection_send_parse_error(connection, .Error_Bad_Request)
			}
			if result.body_too_large {
				state.response.flags += {.Close_After_Send, .Aborted}
				return _connection_stage_canned_response(
					connection,
					transmute([]u8)string(ERROR_RESPONSE_413_CONTENT_TOO_LARGE),
				)
			}

			next_source := remaining_source[result.consumed_size:]

			if result.data_size > 0 {
				request := _connection_make_request(connection, nil)
				response := _connection_make_response(connection)
				route_context := _make_route_context(state)
				is_last := result.done && state.parser.phase == .Complete
				if is_last {
					state.request_body_complete_notified = true
				}
				step := _dispatch_route_event(
					Route_Event(
						Body_Chunk {
							data = remaining_source[result.data_offset:][:result.data_size],
							is_last = is_last,
						},
					),
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
						return _connection_drive_body_read(connection)
					}
					continue
				}
				if state.request_body_complete_notified && len(next_source) > 0 {
					if !_connection_retain_tail(connection, next_source) {
						state.response.flags += {.Close_After_Send}
					}
				}
				return _dispatch_step(connection, step)
			}

			if result.need_more {
				if !_connection_retain_tail(connection, next_source) {
					return _connection_begin_close(connection)
				}
				return _connection_drive_body_read(connection)
			}

			if result.consumed_size <= 0 {
				return _connection_drive_body_read(connection)
			}

			remaining_source = next_source
			if len(remaining_source) == 0 {
				return _connection_drive_body_read(connection)
			}
		}
	} else {
		for {
			result: Body_Drain_Result
			result, state.buffered_body_size, state.request_body_size_received = drain_request_body(
				&state.parser,
				remaining_source,
				state.buffered_body_bytes,
				state.buffered_body_size,
				state.request_body_size_received,
				descriptor.body_size_max,
				runtime.server.parse_budget,
				buffered = true,
			)

			if result.protocol_error {
				return _connection_send_parse_error(connection, .Error_Bad_Request)
			}
			if result.body_too_large {
				state.response.flags += {.Close_After_Send, .Aborted}
				return _connection_stage_canned_response(
					connection,
					transmute([]u8)string(ERROR_RESPONSE_413_CONTENT_TOO_LARGE),
				)
			}

			next_source := remaining_source[result.consumed_size:]

			if result.done && state.parser.phase == .Complete {
				if len(next_source) > 0 {
					if !_connection_retain_tail(connection, next_source) {
						state.response.flags += {.Close_After_Send}
					}
				}
				return _connection_drive_body_read(connection)
			}

			if result.need_more {
				if !_connection_retain_tail(connection, next_source) {
					return _connection_begin_close(connection)
				}
				return _connection_drive_body_read(connection)
			}

			if result.consumed_size <= 0 {
				return _connection_drive_body_read(connection)
			}

			remaining_source = next_source
			if len(remaining_source) == 0 {
				return _connection_drive_body_read(connection)
			}
		}
	}
}

@(private = "file")
_connection_begin_close :: proc(connection: ^HTTP_Connection) -> tina.Isolate_Transition {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime != nil {
		_idle_slot_remove(connection)
		if state.deadline_timer_handle != tina.TIMER_HANDLE_NONE {
			tina.ctx_timer_release(state.deadline_timer_handle)
			state.deadline_timer_handle = tina.TIMER_HANDLE_NONE
			state.deadline_ns = 0
		}
	}
	state.state = .Closing
	return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = state.fd}))
}

@(private = "file")
_connection_complete_close :: proc(connection: ^HTTP_Connection) {
	state := &connection.connection_state
	runtime := state.shard_runtime
	if runtime == nil {
		return
	}

	_idle_slot_remove(connection)
	if _runtime_active_slot_remove(connection) && runtime.free_count < runtime.connection_slot_count {
		runtime.free_count += 1
	}
}

@(private = "file")
_recv_buffer_size_max :: proc(runtime: ^HTTP_Shard_Runtime) -> u32 {
	return(
		u32(runtime.server.parse_budget.request_line_size_max) +
		u32(runtime.server.parse_budget.header_size_max) \
	)
}

@(private = "file")
TEST_NOTIFICATION_MESSAGE_TAG :: Message_Tag(0x4400)

@(private = "file")
Notification_Test_State :: struct {
	dropped_count:  u32,
	accepted_count: u32,
	drain_count:    u32,
}

@(test)
test_idle_peer_close_unlinks_idle_before_fd_close :: proc(t: ^testing.T) {
	active_slot_indices: [1]u16
	active_connections: [1]^HTTP_Connection
	active_slot_positions: [1]u16
	idle_slot_indices: [1]u16
	idle_slot_handles: [1]tina.Isolate_Handle
	idle_slot_positions: [1]u16
	active_slot_positions[0] = u16(IDLE_ARRAY_INDEX_NONE)
	idle_slot_positions[0] = u16(IDLE_ARRAY_INDEX_NONE)

	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
		active_slot_indices   = active_slot_indices[:],
		active_connections    = active_connections[:],
		active_slot_positions = active_slot_positions[:],
		idle_slot_indices     = idle_slot_indices[:],
		idle_slot_handles     = idle_slot_handles[:],
		idle_slot_positions   = idle_slot_positions[:],
		free_count            = 0,
		connection_slot_count = 1,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(17)
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)
	runtime.active_slot_indices[0] = 0
	runtime.active_connections[0] = &connection
	runtime.active_slot_positions[0] = 0
	runtime.active_count = Active_Array_Count(1)

	Close_Lifecycle_Test_State :: struct {
		connection: ^HTTP_Connection,
		message:    ^tina.Message,
		t:          ^testing.T,
	}
	close_lifecycle_test_state := Close_Lifecycle_Test_State {connection = &connection, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&close_lifecycle_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Close_Lifecycle_Test_State)user_data
			_connection_begin_keep_alive_wait(test_state.connection)
		},
	)
	testing.expect_value(t, u16(runtime.idle_count), u16(1))

	message: tina.Message
	message.tag = tina.IO_TAG_RECV_COMPLETE
	message.io.result = 0
	close_lifecycle_test_state.message = &message
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&close_lifecycle_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Close_Lifecycle_Test_State)user_data
			effect := _http_connection_handler(rawptr(test_state.connection), test_state.message)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(test_state.t, false, "idle peer close must close the socket")
			}
		},
	)
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
	testing.expect_value(t, u16(runtime.idle_count), u16(0))
	testing.expect_value(t, runtime.idle_slot_positions[0], u16(IDLE_ARRAY_INDEX_NONE))
	testing.expect_value(t, u16(runtime.active_count), u16(1))
	testing.expect_value(t, runtime.free_count, u16(0))

	close_complete: tina.Message
	close_complete.tag = tina.IO_TAG_CLOSE_COMPLETE
	close_lifecycle_test_state.message = &close_complete
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&close_lifecycle_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Close_Lifecycle_Test_State)user_data
			_ = _http_connection_handler(rawptr(test_state.connection), test_state.message)
			_ = _http_connection_handler(rawptr(test_state.connection), test_state.message)
		},
	)
	testing.expect_value(t, u16(runtime.active_count), u16(0))
	testing.expect_value(t, runtime.active_slot_positions[0], u16(IDLE_ARRAY_INDEX_NONE))
	testing.expect_value(t, runtime.free_count, u16(1))
}

@(private = "file")
Notification_Test_Payload :: struct {
	request_token: Request_Token,
}

@(private = "file")
Notification_Context_Test_State :: struct {
	t:          ^testing.T,
	connection: ^HTTP_Connection,
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
		return expect_notification(
			route_context,
			1_000_000,
			tina.ISOLATE_HANDLE_NONE,
			TEST_NOTIFICATION_MESSAGE_TAG,
		)

	case Application_Notification:
		payload := (cast(^Notification_Test_Payload)raw_data(ev.payload_bytes))^
		if payload.request_token != route_request_token(route_context) {
			test_state.dropped_count += 1
			return expect_notification(
				route_context,
				1_000_000,
				tina.ISOLATE_HANDLE_NONE,
				TEST_NOTIFICATION_MESSAGE_TAG,
			)
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
	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	notification_context_test_state := Notification_Context_Test_State {
		t          = t,
		connection = &connection,
	}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle = connection.connection_state.self_handle,
			timer_resolution_ns = 1,
		},
		rawptr(&notification_context_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Notification_Context_Test_State)user_data
			connection := test_state.connection
			route_state := cast(^Notification_Test_State)raw_data(
				connection.connection_state.route_state_bytes,
			)
			request := _connection_make_request(connection, nil)
			response := _connection_make_response(connection)
			step := _dispatch_route(&request, &response)
			#partial switch step {
			case .Expect_Application:
			case:
				testing.expect(
					test_state.t,
					false,
					"Request_Start should request application parking",
				)
			}
			park_effect := _dispatch_step(connection, step)
			testing.expect_value(
				test_state.t,
				park_effect.kind,
				tina.Isolate_Transition_Kind.Wait_Message,
			)
			testing.expect_value(test_state.t, route_state.dropped_count, u32(0))
			testing.expect_value(test_state.t, route_state.accepted_count, u32(0))
			testing.expect_value(
				test_state.t,
				connection.connection_state.state,
				Connection_Phase.Application_Expectation,
			)

			stale_message: tina.Message
			stale_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
			stale_message.user.source = tina.make_handle(0, 3, 2, 1)
			stale_message.user.payload_size = u16(size_of(Notification_Test_Payload))
			(cast(^Notification_Test_Payload)&stale_message.user.payload[0])^ =
				Notification_Test_Payload {
					request_token = Request_Token(99),
				}
			stale_effect := 		_connection_handle_application_mailbox_message(
				connection,
				&stale_message,
			)
			testing.expect_value(
				test_state.t,
				stale_effect.kind,
				tina.Isolate_Transition_Kind.Wait_Message,
			)
			testing.expect_value(test_state.t, route_state.dropped_count, u32(1))
			testing.expect_value(test_state.t, route_state.accepted_count, u32(0))
			testing.expect_value(
				test_state.t,
				connection.connection_state.state,
				Connection_Phase.Application_Expectation,
			)

			correct_message: tina.Message
			correct_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
			correct_message.user.source = tina.make_handle(0, 3, 2, 1)
			correct_message.user.payload_size = u16(size_of(Notification_Test_Payload))
			(cast(^Notification_Test_Payload)&correct_message.user.payload[0])^ =
				Notification_Test_Payload {
					request_token = connection.connection_state.request_token,
				}
			correct_effect := 		_connection_handle_application_mailbox_message(
				connection,
				&correct_message,
			)
			if correct_effect.kind == tina.Isolate_Transition_Kind.Wait_Message {
				testing.expect(test_state.t, false, "valid notification should be handled")
			}
		},
	)
	testing.expect_value(t, route_state_storage[0].accepted_count, u32(1))
}

@(test)
test_pending_application_message_is_preserved_until_expectation :: proc(t: ^testing.T) {
	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	pending_application_test_state := Notification_Context_Test_State {
		t          = t,
		connection = &connection,
	}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle = connection.connection_state.self_handle,
			timer_resolution_ns = 1,
		},
		rawptr(&pending_application_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Notification_Context_Test_State)user_data
			connection := test_state.connection
			notification_message: tina.Message
			notification_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
			notification_message.user.source = tina.make_handle(0, 3, 2, 1)
			notification_message.user.payload_size = u16(size_of(Notification_Test_Payload))
			(cast(^Notification_Test_Payload)&notification_message.user.payload[0])^ =
				Notification_Test_Payload {
					request_token = Request_Token(7),
				}
			stash_effect := _http_connection_handler(
				rawptr(connection),
				&notification_message,
			)
			testing.expect_value(
				test_state.t,
				stash_effect.kind,
				tina.Isolate_Transition_Kind.Wait_Message,
			)
			testing.expect(
				test_state.t,
				connection.connection_state.application_pending_message_valid,
			)

			connection.connection_state.application_expectation_kind = .Notification
			connection.connection_state.application_expected_source = tina.ISOLATE_HANDLE_NONE
			connection.connection_state.application_expected_tag = TEST_NOTIFICATION_MESSAGE_TAG
			connection.connection_state.application_correlation_id = tina.Correlation_Id(33)
			connection.connection_state.application_timeout_ns = 1_000_000

			effect := _dispatch_step(connection, .Expect_Application)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(
					test_state.t,
					false,
					"deferred notification should dispatch to handler and close",
				)
			}
		},
	)
	testing.expect_value(t, route_state_storage[0].accepted_count, u32(1))
	testing.expect(t, !connection.connection_state.application_pending_message_valid)
}

@(test)
test_pending_application_message_first_wins_when_multiple_arrive :: proc(t: ^testing.T) {
	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	first_wins_test_state := Notification_Context_Test_State {
		t          = t,
		connection = &connection,
	}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle = connection.connection_state.self_handle,
			timer_resolution_ns = 1,
		},
		rawptr(&first_wins_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Notification_Context_Test_State)user_data
			connection := test_state.connection
			first_message: tina.Message
			first_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
			first_message.user.source = tina.make_handle(0, 3, 2, 1)
			first_message.user.payload_size = u16(size_of(Notification_Test_Payload))
			(cast(^Notification_Test_Payload)&first_message.user.payload[0])^ =
				Notification_Test_Payload {
					request_token = Request_Token(7),
				}

			second_message: tina.Message
			second_message.tag = tina.Message_Tag(TEST_NOTIFICATION_MESSAGE_TAG)
			second_message.user.source = tina.make_handle(0, 3, 2, 1)
			second_message.user.payload_size = u16(size_of(Notification_Test_Payload))
			(cast(^Notification_Test_Payload)&second_message.user.payload[0])^ =
				Notification_Test_Payload {
					request_token = Request_Token(999),
				}
			_ = _http_connection_handler(rawptr(connection), &first_message)
			_ = _http_connection_handler(rawptr(connection), &second_message)
			testing.expect(
				test_state.t,
				connection.connection_state.application_pending_message_valid,
			)

			connection.connection_state.application_expectation_kind = .Notification
			connection.connection_state.application_expected_source = tina.ISOLATE_HANDLE_NONE
			connection.connection_state.application_expected_tag = TEST_NOTIFICATION_MESSAGE_TAG
			connection.connection_state.application_correlation_id = tina.Correlation_Id(44)
			connection.connection_state.application_timeout_ns = 1_000_000

			effect := _dispatch_step(connection, .Expect_Application)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(
					test_state.t,
					false,
					"first deferred notification should be delivered and close",
				)
			}
		},
	)

	testing.expect_value(t, route_state_storage[0].accepted_count, u32(1))
	testing.expect_value(t, route_state_storage[0].dropped_count, u32(0))
}

@(test)
test_shutdown_in_application_expectation_delivers_server_drain :: proc(t: ^testing.T) {
	route_state_storage := [1]Notification_Test_State{}
	header_views_storage: [1]Header_View
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler = rawptr(_notification_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Notification_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
			graceful_drain_ms = 1,
		),
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	shutdown_drain_test_state := Notification_Context_Test_State {
		t          = t,
		connection = &connection,
	}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle = connection.connection_state.self_handle,
			shutting_down = true,
			timer_resolution_ns = 1,
		},
		rawptr(&shutdown_drain_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Notification_Context_Test_State)user_data
			connection := test_state.connection
			shutdown_message: tina.Message
			shutdown_message.tag = tina.TAG_SHUTDOWN
			effect := _http_connection_handler(rawptr(connection), &shutdown_message)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(
					test_state.t,
					false,
					"shutdown drain handler should return close",
				)
			}
		},
	)
	testing.expect(t, runtime.draining)
	testing.expect_value(t, route_state_storage[0].drain_count, u32(1))
}

@(test)
test_shutdown_while_reading_headers_closes_immediately :: proc(t: ^testing.T) {
	idle_slot_indices: [1]u16
	idle_slot_handles: [1]tina.Isolate_Handle
	idle_slot_positions: [1]u16
	idle_slot_positions[0] = u16(IDLE_ARRAY_INDEX_NONE)

	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(graceful_drain_ms = 1),
		connection_slot_count = 1,
		idle_slot_indices = idle_slot_indices[:],
		idle_slot_handles = idle_slot_handles[:],
		idle_slot_positions = idle_slot_positions[:],
	}
	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.fd = tina.FD_Handle(17)
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	shutdown_headers_test_state := Notification_Context_Test_State {
		t          = t,
		connection = &connection,
	}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle = connection.connection_state.self_handle,
			shutting_down = true,
			timer_resolution_ns = 1,
		},
		rawptr(&shutdown_headers_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Notification_Context_Test_State)user_data
			connection := test_state.connection
			shutdown_message: tina.Message
			shutdown_message.tag = tina.TAG_SHUTDOWN
			effect := _http_connection_handler(rawptr(connection), &shutdown_message)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(
					test_state.t,
					false,
					"shutdown while reading headers should close immediately",
				)
			}
		},
	)
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
			handler = rawptr(_flush_send_ready_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Flush_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)

	Dispatch_Flush_Test_State :: struct {connection: ^HTTP_Connection, t: ^testing.T}
	dispatch_flush_test_state := Dispatch_Flush_Test_State {connection = &connection, t = t}
		tina.test_with_turn_frame(
			tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
			rawptr(&dispatch_flush_test_state),
			proc(user_data: rawptr) {
				test_state := cast(^Dispatch_Flush_Test_State)user_data
				effect := _dispatch_step(test_state.connection, .Flush)
				testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
				if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
					testing.expect(
						test_state.t,
						false,
						"non-final flush with no bytes should re-enter route via Send_Ready",
					)
				}
			},
		)
	testing.expect_value(t, route_state_storage[0].send_ready_count, u32(1))
}

@(test)
test_dispatch_step_flush_final_skips_send_ready_without_io :: proc(t: ^testing.T) {
	route_state_storage := [1]Flush_Test_State{}
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler = rawptr(_flush_send_ready_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Flush_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)

	Dispatch_Flush_Final_Test_State :: struct {connection: ^HTTP_Connection, t: ^testing.T}
	dispatch_flush_final_test_state := Dispatch_Flush_Final_Test_State {connection = &connection, t = t}
		tina.test_with_turn_frame(
			tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
			rawptr(&dispatch_flush_final_test_state),
			proc(user_data: rawptr) {
				test_state := cast(^Dispatch_Flush_Final_Test_State)user_data
				effect := _dispatch_step(test_state.connection, .Flush_Final)
				testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
				if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
					testing.expect(test_state.t, false, "final flush with close-after-send should close")
				}
			},
		)
	testing.expect_value(t, route_state_storage[0].send_ready_count, u32(0))
}

@(test)
test_send_complete_with_sendfile_plan_transitions_to_sendfile_io :: proc(t: ^testing.T) {
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)

	Send_Complete_Test_State :: struct {connection: ^HTTP_Connection, t: ^testing.T}
	send_complete_test_state := Send_Complete_Test_State {connection = &connection, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&send_complete_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Send_Complete_Test_State)user_data
			effect := _connection_handle_send_complete(test_state.connection, 0)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			#partial switch sendfile_op in tina.ctx_staged_io_operation() {
			case tina.IoOp_Sendfile:
				testing.expect_value(test_state.t, sendfile_op.fd_socket, tina.FD_Handle(11))
				testing.expect_value(test_state.t, sendfile_op.fd_file, tina.FD_Handle(22))
				testing.expect_value(test_state.t, sendfile_op.source_offset, u64(0))
				testing.expect(test_state.t, sendfile_op.size > 0)
			case:
				testing.expect(test_state.t, false, "expected IoOp_Sendfile")
			}
		},
	)
}

@(test)
test_stage_canned_response_arms_send_timeout :: proc(t: ^testing.T) {
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 25,
			},
		),
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.deadline_timer_handle = tina.TIMER_HANDLE_NONE
	connection.connection_state.fd = tina.FD_Handle(31)
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)

	Canned_Response_Test_State :: struct {
		connection: ^HTTP_Connection,
		t:          ^testing.T,
	}
	test_state := Canned_Response_Test_State {connection = &connection, t = t}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle         = connection.connection_state.self_handle,
			monotonic_time_ns   = tina.Monotonic_Time_NS(100),
			timer_resolution_ns = 1,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Canned_Response_Test_State)user_data
			state.connection.connection_state.deadline_timer_handle = tina.ctx_timer_acquire()
			effect := _connection_stage_canned_response(
				state.connection,
				transmute([]u8)string(ERROR_RESPONSE_408_REQUEST_TIMEOUT),
			)
			testing.expect_value(state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
				testing.expect(state.t, false, "canned response should send bytes")
			}
		},
	)

	testing.expect(
		t,
		connection.connection_state.deadline_timer_handle != tina.TIMER_HANDLE_NONE,
		"canned response should arm send timeout",
	)
	testing.expect(t, connection.connection_state.deadline_ns != 0, "canned response should store deadline")
}

@(test)
test_drive_body_read_restarts_send_from_unsent_offset :: proc(t: ^testing.T) {
	router_descriptors := [1]Route_Descriptor {
		Route_Descriptor {
			handler_kind = .Request,
			body_mode    = .Buffered,
		},
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 25,
			},
		),
		router = Compiled_Router {
			descriptors = router_descriptors[:],
		},
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.deadline_timer_handle = tina.TIMER_HANDLE_NONE
	connection.connection_state.fd = tina.FD_Handle(41)
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.response.egress_size = 128
	connection.connection_state.response.egress_size_sent = 64

	Drive_Body_Read_Test_State :: struct {
		connection: ^HTTP_Connection,
		t:          ^testing.T,
	}
	test_state := Drive_Body_Read_Test_State {connection = &connection, t = t}

	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle         = connection.connection_state.self_handle,
			monotonic_time_ns   = tina.Monotonic_Time_NS(200),
			timer_resolution_ns = 1,
		},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Drive_Body_Read_Test_State)user_data
			state.connection.connection_state.deadline_timer_handle = tina.ctx_timer_acquire()
			effect := _connection_drive_body_read(state.connection)
			testing.expect_value(state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			#partial switch send_op in tina.ctx_staged_io_operation() {
			case tina.IoOp_Send:
				testing.expect_value(state.t, send_op.fd, tina.FD_Handle(41))
				testing.expect_value(state.t, tina.ctx_staged_io_payload_size(), u32(64))
				testing.expect_value(
					state.t,
					tina.ctx_staged_io_payload_offset(),
					tina.payload_offset_of(
						state.connection,
						state.connection.egress_buffer[64:][:64],
					),
				)
			case:
				testing.expect(state.t, false, "expected IoOp_Send")
			}
		},
	)

	testing.expect(
		t,
		connection.connection_state.deadline_timer_handle != tina.TIMER_HANDLE_NONE,
		"resumed body send should arm send timeout",
	)
	testing.expect(t, connection.connection_state.deadline_ns != 0, "resumed body send should store deadline")
}

@(test)
test_send_complete_error_dispatches_peer_closed_then_closes :: proc(t: ^testing.T) {
	route_state_storage := [1]Peer_Closed_Test_State{}
	response_header_storage: [32]u8
	router_descriptors: [1]Route_Descriptor = [1]Route_Descriptor {
		Route_Descriptor {
			handler = rawptr(_peer_closed_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Peer_Closed_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
		router = router,
	}

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.state = .Sending
	connection.connection_state.fd = tina.FD_Handle(19)
	connection.connection_state.request.route_index = Route_Index(0)
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.route_state_bytes = tina.bytes_of(&route_state_storage[0])
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)

	message: tina.Message
	message.tag = tina.IO_TAG_SEND_COMPLETE
	message.io.result = -1

	Peer_Closed_Error_Test_State :: struct {
		connection: ^HTTP_Connection,
		message:    ^tina.Message,
		t:          ^testing.T,
	}
	test_state := Peer_Closed_Error_Test_State {connection = &connection, message = &message, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Peer_Closed_Error_Test_State)user_data
			effect := _http_connection_handler(rawptr(state.connection), state.message)
			testing.expect_value(state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(state.t, false, "send failure should close after Peer_Closed dispatch")
			}
		},
	)
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
			handler = rawptr(_peer_closed_route_event_handler),
			handler_kind = .Event,
			body_size_max = 0,
			body_mode = .None,
			state_size = u16(size_of(Peer_Closed_Test_State)),
		},
	}
	router := Compiled_Router {
		descriptors = router_descriptors[:],
	}
	runtime := HTTP_Shard_Runtime {
		server = _test_server_runtime(
			timeouts = Timeouts {
				timeout_ms_idle = 1,
				timeout_ms_header = 1,
				timeout_ms_body = 1,
				timeout_ms_send = 1,
			},
		),
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
	connection.connection_state.self_handle = tina.make_handle(0, HTTP_TYPE_OFFSET_CONNECTION, 0, 1)

	message: tina.Message
	message.tag = tina.IO_TAG_SENDFILE_COMPLETE
	message.io.result = -1

	Sendfile_Error_Test_State :: struct {
		connection: ^HTTP_Connection,
		message:    ^tina.Message,
		t:          ^testing.T,
	}
	test_state := Sendfile_Error_Test_State {connection = &connection, message = &message, t = t}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&test_state),
		proc(user_data: rawptr) {
			state := cast(^Sendfile_Error_Test_State)user_data
			effect := _http_connection_handler(rawptr(state.connection), state.message)
			testing.expect_value(state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(state.t, false, "sendfile failure should close after Peer_Closed dispatch")
			}
		},
	)
	testing.expect_value(t, route_state_storage[0].peer_closed_count, u32(1))
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
	testing.expect_value(t, connection.connection_state.response.egress_size, Egress_Size(0))
}

@(test)
test_process_header_bytes_retains_tail_for_simple_request :: proc(t: ^testing.T) {
	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	second_request := "GET /second HTTP/1.1\r\nHost: example\r\n\r\n"
	combined := transmute([]u8)string(
		"GET /first HTTP/1.1\r\nHost: example\r\n\r\nGET /second HTTP/1.1\r\nHost: example\r\n\r\n",
	)

	Process_Header_Test_State :: struct {connection: ^HTTP_Connection, input: []u8, t: ^testing.T}
	process_header_test_state := Process_Header_Test_State {
		connection = &connection,
		input      = combined,
		t          = t,
	}
		tina.test_with_turn_frame(
			tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
			rawptr(&process_header_test_state),
			proc(user_data: rawptr) {
				test_state := cast(^Process_Header_Test_State)user_data
				effect := _connection_process_header_bytes(test_state.connection, test_state.input)
				testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
				if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
					testing.expect(test_state.t, false, "simple request should stage and send a response")
				}
			},
		)

	second_request_size := len(second_request)
	testing.expect_value(
		t,
		int(connection.connection_state.pipeline_tail_size),
		second_request_size,
	)
	retained_tail := string(
		connection.connection_state.pipeline_tail_bytes[:int(
			connection.connection_state.pipeline_tail_size,
		)],
	)
	testing.expect_value(t, retained_tail, second_request)
}

@(private = "file")
_connection_test_canonical_route_handler :: proc(request: ^Request, response: ^Response) -> Route_Step {
	if string(path(request)) != "/admin" {
		return respond_text(response, HTTP_STATUS_INTERNAL_SERVER_ERROR, "bad path")
	}
	if string(query(request)) != "x=1" {
		return respond_text(response, HTTP_STATUS_INTERNAL_SERVER_ERROR, "bad query")
	}
	if string(header(request, "Host")) != "example" {
		return respond_text(response, HTTP_STATUS_INTERNAL_SERVER_ERROR, "bad host")
	}
	return respond_text(response, HTTP_STATUS_OK, "ok")
}

@(test)
test_process_header_bytes_canonicalizes_path_before_route_match :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/admin", methods_mask = {.GET}, handler = rawptr(_connection_test_canonical_route_handler)}}
	router, compile_error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, compile_error, Compile_Error.None)

	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
		router = router,
	}

	header_views_storage: [64]Header_View
	request_frame_storage: [512]u8
	response_header_storage: [1024]u8

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(36)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	request_bytes := transmute([]u8)string("GET /%61dmin?x=1 HTTP/1.1\r\nHost: example\r\n\r\n")
	Canonical_Path_Test_State :: struct {connection: ^HTTP_Connection, input: []u8, t: ^testing.T}
	canonical_path_test_state := Canonical_Path_Test_State {
		connection = &connection,
		input      = request_bytes,
		t          = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&canonical_path_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Canonical_Path_Test_State)user_data
			effect := _connection_process_header_bytes(test_state.connection, test_state.input)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
				testing.expect(test_state.t, false, "canonical path request should stage a response send")
			}
		},
	)
	testing.expect_value(t, connection.connection_state.response.status_code, HTTP_STATUS_OK)
	testing.expect_value(t, connection.connection_state.request.path_size, u16(len("/admin")))
	testing.expect_value(t, connection.connection_state.request.target_size, u16(len("/admin?x=1")))
}

@(test)
test_connection_canonicalize_request_frame_preserves_encoded_slash :: proc(t: ^testing.T) {
	request_frame_storage: [128]u8
	frame := transmute([]u8)string("GET /a%2fb?x=1 HTTP/1.1\r\nHost: example\r\n\r\n")
	copy(request_frame_storage[:len(frame)], frame)

	connection := HTTP_Connection{}
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.request = Request_State {
		target_offset = 4,
		path_offset   = 4,
		query_offset  = 11,
		target_size   = u16(len("/a%2fb?x=1")),
		path_size     = u16(len("/a%2fb")),
		query_size    = u16(len("x=1")),
	}

	canonical_frame, path_error := _connection_canonicalize_request_frame(
		&connection,
		request_frame_storage[:len(frame)],
		u16(len(frame)),
	)
	testing.expect_value(t, path_error, Request_Frame_Canonicalization_Error.None)
	testing.expect_value(t, string(canonical_frame[4:][:len("/a%2Fb")]), "/a%2Fb")
	testing.expect_value(t, connection.connection_state.request.path_size, u16(len("/a%2Fb")))
	testing.expect_value(t, connection.connection_state.request.query_offset, u16(11))
}

@(test)
test_connection_canonicalize_request_frame_shifts_empty_query_offset :: proc(t: ^testing.T) {
	request_frame_storage: [128]u8
	frame := transmute([]u8)string("GET /%61? HTTP/1.1\r\nHost: example\r\n\r\n")
	copy(request_frame_storage[:len(frame)], frame)

	connection := HTTP_Connection{}
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.request = Request_State {
		target_offset = 4,
		path_offset   = 4,
		query_offset  = 9,
		target_size   = u16(len("/%61?")),
		path_size     = u16(len("/%61")),
		query_size    = 0,
	}
	connection.connection_state.parser.request_line_size = u16(len("GET /%61? HTTP/1.1\r\n"))

	canonical_frame, canonical_error := _connection_canonicalize_request_frame(
		&connection,
		request_frame_storage[:len(frame)],
		u16(len(frame)),
	)
	testing.expect_value(t, canonical_error, Request_Frame_Canonicalization_Error.None)
	testing.expect_value(t, string(canonical_frame[4:][:len("/a?")]), "/a?")
	testing.expect_value(t, connection.connection_state.request.path_size, u16(len("/a")))
	testing.expect_value(t, connection.connection_state.request.target_size, u16(len("/a?")))
	testing.expect_value(t, connection.connection_state.request.query_offset, u16(7))
	testing.expect_value(t, connection.connection_state.parser.request_line_size, u16(len("GET /a? HTTP/1.1\r\n")))
}

@(test)
test_connection_canonicalize_request_frame_shifts_multiple_decoded_bytes :: proc(t: ^testing.T) {
	request_frame_storage: [128]u8
	frame := transmute([]u8)string("GET /%61%62%63 HTTP/1.1\r\nHost: example\r\n\r\n")
	copy(request_frame_storage[:len(frame)], frame)

	connection := HTTP_Connection{}
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.request = Request_State {
		target_offset = 4,
		path_offset   = 4,
		target_size   = u16(len("/%61%62%63")),
		path_size     = u16(len("/%61%62%63")),
	}
	connection.connection_state.parser.request_line_size = u16(len("GET /%61%62%63 HTTP/1.1\r\n"))

	canonical_frame, canonical_error := _connection_canonicalize_request_frame(
		&connection,
		request_frame_storage[:len(frame)],
		u16(len(frame)),
	)
	testing.expect_value(t, canonical_error, Request_Frame_Canonicalization_Error.None)
	testing.expect_value(t, string(canonical_frame[4:][:len("/abc")]), "/abc")
	testing.expect_value(t, connection.connection_state.request.path_size, u16(len("/abc")))
	testing.expect_value(t, connection.connection_state.request.target_size, u16(len("/abc")))
	testing.expect_value(t, connection.connection_state.request.query_offset, u16(0))
}

@(test)
test_connection_canonicalize_request_frame_rejects_decoded_control_byte :: proc(t: ^testing.T) {
	request_frame_storage: [128]u8
	frame := transmute([]u8)string("GET /bad%00path HTTP/1.1\r\nHost: example\r\n\r\n")
	copy(request_frame_storage[:len(frame)], frame)

	connection := HTTP_Connection{}
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.request = Request_State {
		target_offset = 4,
		path_offset   = 4,
		target_size   = u16(len("/bad%00path")),
		path_size     = u16(len("/bad%00path")),
	}

	_, canonical_error := _connection_canonicalize_request_frame(
		&connection,
		request_frame_storage[:len(frame)],
		u16(len(frame)),
	)
	testing.expect_value(t, canonical_error, Request_Frame_Canonicalization_Error.Bad_Path)
}

@(test)
test_process_header_bytes_rejects_malformed_percent_path :: proc(t: ^testing.T) {
	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
		router = router,
	}

	header_views_storage: [64]Header_View
	request_frame_storage: [512]u8
	response_header_storage: [1024]u8

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(37)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	request_bytes := transmute([]u8)string("GET /bad%GG HTTP/1.1\r\nHost: example\r\n\r\n")
	Malformed_Path_Test_State :: struct {connection: ^HTTP_Connection, input: []u8, t: ^testing.T}
	malformed_path_test_state := Malformed_Path_Test_State {
		connection = &connection,
		input      = request_bytes,
		t          = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&malformed_path_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Malformed_Path_Test_State)user_data
			effect := _connection_process_header_bytes(test_state.connection, test_state.input)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
				testing.expect(test_state.t, false, "malformed percent path should stage a parse-error response")
			}
		},
	)
	testing.expect_value(t, string(connection.egress_buffer[:len("HTTP/1.1 400")]), "HTTP/1.1 400")
	testing.expect(t, .Aborted in connection.connection_state.response.flags, "malformed percent path should abort the response")
}

@(test)
test_process_header_bytes_accumulates_fragmented_request_line :: proc(t: ^testing.T) {
	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
		router = router,
	}

	header_views_storage: [64]Header_View
	request_frame_storage: [512]u8
	response_header_storage: [1024]u8

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(34)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	fragment_first := transmute([]u8)string("GET /fragmented HT")
	fragment_second := transmute([]u8)string("TP/1.1\r\nHost: example\r\n\r\n")

	Process_Fragment_Test_State :: struct {connection: ^HTTP_Connection, input: []u8, t: ^testing.T}
	fragment_first_state := Process_Fragment_Test_State {
		connection = &connection,
		input      = fragment_first,
		t          = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&fragment_first_state),
		proc(user_data: rawptr) {
			test_state := cast(^Process_Fragment_Test_State)user_data
			effect := _connection_process_header_bytes(test_state.connection, test_state.input)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Recv); !ok {
				testing.expect(test_state.t, false, "first fragment should wait for more recv bytes")
			}
		},
	)
	testing.expect_value(t, int(connection.connection_state.ingress_size), len(fragment_first))
	testing.expect_value(t, int(connection.connection_state.ingress_parsed_offset), 0)

	fragment_second_state := Process_Fragment_Test_State {
		connection = &connection,
		input      = fragment_second,
		t          = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&fragment_second_state),
		proc(user_data: rawptr) {
			test_state := cast(^Process_Fragment_Test_State)user_data
			effect := _connection_process_header_bytes(test_state.connection, test_state.input)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
				testing.expect(test_state.t, false, "completed fragmented request should stage a response send")
			}
		},
	)
	testing.expect_value(t, connection.connection_state.response.status_code, HTTP_STATUS_NOT_FOUND)
	testing.expect_value(t, connection.connection_state.parser.phase, Parse_Phase.Complete)
}

@(test)
test_process_header_bytes_accumulates_fragmented_header_value :: proc(t: ^testing.T) {
	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
		router = router,
	}

	header_views_storage: [64]Header_View
	request_frame_storage: [512]u8
	response_header_storage: [1024]u8

	connection := HTTP_Connection{}
	connection.connection_state.shard_runtime = &runtime
	connection.connection_state.fd = tina.FD_Handle(35)
	connection.connection_state.state = .Recv_Headers
	connection.connection_state.header_views = header_views_storage[:]
	connection.connection_state.request_frame_bytes = request_frame_storage[:]
	connection.connection_state.response_header_bytes = response_header_storage[:]
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	fragment_first := transmute([]u8)string("GET /field HTTP/1.1\r\nHost: exam")
	fragment_second := transmute([]u8)string("ple\r\n\r\n")
	request_line_size := len("GET /field HTTP/1.1\r\n")

	Process_Header_Fragment_Test_State :: struct {connection: ^HTTP_Connection, input: []u8, t: ^testing.T}
	fragment_first_state := Process_Header_Fragment_Test_State {
		connection = &connection,
		input      = fragment_first,
		t          = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&fragment_first_state),
		proc(user_data: rawptr) {
			test_state := cast(^Process_Header_Fragment_Test_State)user_data
			effect := _connection_process_header_bytes(test_state.connection, test_state.input)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Recv); !ok {
				testing.expect(test_state.t, false, "partial header value should wait for more recv bytes")
			}
		},
	)
	testing.expect_value(t, int(connection.connection_state.ingress_size), len(fragment_first))
	testing.expect_value(t, int(connection.connection_state.ingress_parsed_offset), request_line_size)
	testing.expect_value(t, connection.connection_state.parser.phase, Parse_Phase.Headers)

	fragment_second_state := Process_Header_Fragment_Test_State {
		connection = &connection,
		input      = fragment_second,
		t          = t,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
		rawptr(&fragment_second_state),
		proc(user_data: rawptr) {
			test_state := cast(^Process_Header_Fragment_Test_State)user_data
			effect := _connection_process_header_bytes(test_state.connection, test_state.input)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
				testing.expect(test_state.t, false, "completed fragmented header should stage a response send")
			}
		},
	)
	testing.expect(t, .Host in connection.connection_state.request.known_headers, "fragmented Host header should be recognized")
	testing.expect_value(t, connection.connection_state.response.status_code, HTTP_STATUS_NOT_FOUND)
	testing.expect_value(t, connection.connection_state.parser.phase, Parse_Phase.Complete)
}

@(test)
test_process_header_bytes_closes_when_core_shutdown_started_before_http_runtime_draining :: proc(
	t: ^testing.T,
) {
	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)
	request_state_reset(&connection.connection_state.request)
	parser_state_reset(&connection.connection_state.parser)

	request_bytes := transmute([]u8)string("GET /first HTTP/1.1\r\nHost: example\r\n\r\n")
	Shutdown_Header_Test_State :: struct {
		t:             ^testing.T,
		connection:    ^HTTP_Connection,
		request_bytes: []u8,
	}
	shutdown_header_test_state := Shutdown_Header_Test_State {
		t             = t,
		connection    = &connection,
		request_bytes = request_bytes,
	}
	tina.test_with_turn_frame(
		tina.Test_Turn_Frame_Config {
			self_handle = connection.connection_state.self_handle,
			shutting_down = true,
			timer_resolution_ns = 1,
		},
		rawptr(&shutdown_header_test_state),
		proc(user_data: rawptr) {
			test_state := cast(^Shutdown_Header_Test_State)user_data
			effect := _connection_process_header_bytes(
				test_state.connection,
				test_state.request_bytes,
			)
			testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
			if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Close); !ok {
				testing.expect(
					test_state.t,
					false,
					"core shutdown should close before dispatching a new request",
				)
			}
		},
	)
	testing.expect(t, !runtime.draining, "HTTP runtime may not have seen TAG_SHUTDOWN yet")
	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Closing)
}

@(test)
test_finalize_flushed_response_processes_pipeline_tail_before_recv :: proc(t: ^testing.T) {
	idle_slot_indices: [4]u16
	idle_slot_handles: [4]tina.Isolate_Handle
	idle_slot_positions: [4]u16
	for position_index in 0 ..< len(idle_slot_positions) {
		idle_slot_positions[position_index] = u16(IDLE_ARRAY_INDEX_NONE)
	}

	router := Compiled_Router{}
	runtime := HTTP_Shard_Runtime {
		server = DEFAULT_SERVER_RUNTIME,
		router = router,
		free_count = 4,
		keepalive_reserve = 0,
		connection_slot_count = 4,
		idle_slot_indices = idle_slot_indices[:],
		idle_slot_handles = idle_slot_handles[:],
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
	connection.connection_state.self_handle = tina.make_handle(
		0,
		HTTP_TYPE_OFFSET_CONNECTION,
		0,
		1,
	)

	pipelined_request := "GET /tail HTTP/1.1\r\nHost: example\r\n\r\n"
	copy(connection.connection_state.pipeline_tail_bytes, transmute([]u8)string(pipelined_request))
	connection.connection_state.pipeline_tail_size = u16(len(pipelined_request))

	Finalize_Flush_Test_State :: struct {connection: ^HTTP_Connection, t: ^testing.T}
	finalize_flush_test_state := Finalize_Flush_Test_State {connection = &connection, t = t}
		tina.test_with_turn_frame(
			tina.Test_Turn_Frame_Config {self_handle = connection.connection_state.self_handle, timer_resolution_ns = 1},
			rawptr(&finalize_flush_test_state),
			proc(user_data: rawptr) {
				test_state := cast(^Finalize_Flush_Test_State)user_data
				effect := _connection_finalize_flushed_response(test_state.connection)
				testing.expect_value(test_state.t, effect.kind, tina.Isolate_Transition_Kind.Wait_Io)
				if _, ok := tina.ctx_staged_io_operation().(tina.IoOp_Send); !ok {
					testing.expect(test_state.t, false, "pipeline tail should be parsed and dispatched before recv")
				}
			},
		)

	testing.expect_value(t, connection.connection_state.state, Connection_Phase.Sending)
}
