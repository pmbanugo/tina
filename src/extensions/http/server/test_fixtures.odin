package http_server

import tina "../../.."

@(private = "package")
HTTP_Test_Fixture :: struct {
	connection:              HTTP_Connection,
	runtime:                 HTTP_Shard_Runtime,
	request_frame_storage:   [512]u8,
	response_header_storage: [256]u8,
}

@(private = "package")
http_test_fixture_init :: proc(fixture: ^HTTP_Test_Fixture, router: Compiled_Router = {}) {
	fixture.runtime = HTTP_Shard_Runtime {
		router = router,
	}
	fixture.connection = HTTP_Connection {}
	fixture.connection.connection_state.shard_runtime = &fixture.runtime
	fixture.connection.connection_state.self_handle = tina.make_handle(0, u16(HTTP_TYPE_OFFSET_CONNECTION), 0, 1)
	fixture.connection.connection_state.request_frame_bytes = fixture.request_frame_storage[:]
	fixture.connection.connection_state.response_header_bytes = fixture.response_header_storage[:]
}

@(private = "package")
http_test_fixture_request :: proc(
	fixture: ^HTTP_Test_Fixture,
	frame: []u8 = nil,
	ctx: tina.TinaContext = 0,
) -> Request {
	return _connection_make_request(&fixture.connection, frame, ctx)
}

@(private = "package")
http_test_fixture_response :: proc(fixture: ^HTTP_Test_Fixture, ctx: tina.TinaContext = 0) -> Response {
	return _connection_make_response(&fixture.connection, ctx)
}
