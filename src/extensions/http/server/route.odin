package http_server

import tina "../../.."
import "core:testing"

Message_Tag :: tina.Message_Tag

Reply_Result :: enum u8 {
	Ok,
	Timeout,
}

Request_Start :: struct {}
Body_Chunk :: struct {
	data:    []u8,
	is_last: bool,
}
Send_Ready :: struct {}
Peer_Closed :: struct {}
Server_Drain :: struct {}

Application_Reply :: struct {
	source_handle: tina.Isolate_Handle,
	message_tag:   Message_Tag,
	payload_bytes: []u8,
	reply_result:  Reply_Result,
}

Application_Notification :: struct {
	source_handle: tina.Isolate_Handle,
	message_tag:   Message_Tag,
	payload_bytes: []u8,
}

Route_Event :: union {
	Request_Start,
	Body_Chunk,
	Send_Ready,
	Peer_Closed,
	Server_Drain,
	Application_Reply,
	Application_Notification,
}

// ─── Route Step ─────────────────────────────────────────────────────────────
//
// Small instruction returned by route handlers telling the library what
// phase to enter next. The connection state machine interprets this after
// each handler invocation.

Route_Step :: enum u8 {
	Flush,
	Flush_Final,
	Read_Body,
	Close,
	Expect_Application,
}

// Simple request handler used by the Phase 7 vertical slice.
Request_Handler :: #type proc(request: ^Request, response: ^Response) -> Route_Step

// Multi-step event handler used by downstream I/O and streaming routes.
Route_Event_Handler :: #type proc(
	event: Route_Event,
	request: ^Request,
	response: ^Response,
	route_context: Route_Context,
	state: rawptr,
) -> Route_Step

Route_Handler_Kind :: enum u8 {
	Request,
	Event,
}

// Opaque request facade passed to handlers. Fields stay package-private so the
// request lifetime and backing storage remain under library control.
Request :: struct {
	connection_state: ^HTTP_Connection_State,
	frame:            []u8,
}

// Opaque response facade passed to handlers. It owns the staged header bytes
// slice and the connection-local egress buffer view.
Response :: struct {
	connection:   ^HTTP_Connection,
}

// Connection-execution context. Passed by value to event handlers and helper
// functions that need Tina messaging or the connection state.
Route_Context :: struct {
	connection_state: ^HTTP_Connection_State,
}

@(require_results)
route_send :: #force_inline proc(
	route_context: Route_Context,
	to: tina.Isolate_Handle,
	$tag: tina.Message_Tag,
	payload: []u8,
) -> tina.Send_Result {
	return tina.ctx_send_raw(to, tag, payload)
}

@(require_results)
route_spawn :: proc(route_context: Route_Context, spec: tina.Spawn_Spec) -> tina.Spawn_Result {
	return tina.ctx_spawn(spec)
}

route_self_handle :: proc(route_context: Route_Context) -> tina.Isolate_Handle {
	return tina.ctx_self_handle()
}

route_request_token :: proc(route_context: Route_Context) -> Request_Token {
	return route_context.connection_state.request_token
}

// Per-route opt-in for request body acquisition. Selected at registration time;
// not changeable per-request. `Request_Handler` supports `.None`/`.Buffered`
// only; `Route_Event_Handler` may additionally use `.Streamed`.

Route_Body_Mode :: enum u8 {
	None, // no request body accepted
	Buffered, // body fully buffered before handler dispatch
	Streamed, // body delivered incrementally via Body_Chunk events
}

// `Route` is the user-facing struct passed to the boot-time router compiler.
// Builder helpers (`get`, `post`, …) will be added in the route-model phase
// once `Request_Handler` and `Route_Event_Handler` proc types exist; until
// then `Route` is constructed directly.
//
// `handler` is held opaquely as `rawptr` here so that route compilation and
// matching can be implemented and tested before the request/response facades
// land. It is reinterpreted as a typed `Route_Handler` union by the dispatch
// layer in a later phase.

Route :: struct {
	handler:       rawptr,
	handler_kind:  Route_Handler_Kind,
	pattern:       string,
	body_size_max: u32,
	methods_mask:  Method_Mask,
	body_mode:     Route_Body_Mode,
	state_size:    u16,
}

@(private = "file")
_build_request_route :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	methods_mask: Method_Mask,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return Route {
		handler = rawptr(handler),
		handler_kind = .Request,
		pattern = pattern,
		methods_mask = methods_mask,
		body_mode = body_mode,
		body_size_max = body_size_max,
		state_size = 0,
	}
}

@(private = "file")
_build_event_route :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	methods_mask: Method_Mask,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return Route {
		handler = rawptr(handler),
		handler_kind = .Event,
		pattern = pattern,
		methods_mask = methods_mask,
		body_mode = body_mode,
		body_size_max = body_size_max,
		state_size = state_size,
	}
}

get_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.GET}, body_size_max, body_mode)
}

get_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.GET}, state_size, body_size_max, body_mode)
}

get :: proc {
	get_simple,
	get_event,
}

post_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.POST}, body_size_max, body_mode)
}

post_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.POST}, state_size, body_size_max, body_mode)
}

post :: proc {
	post_simple,
	post_event,
}

put_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.PUT}, body_size_max, body_mode)
}

put_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.PUT}, state_size, body_size_max, body_mode)
}

put :: proc {
	put_simple,
	put_event,
}

delete_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.DELETE}, body_size_max, body_mode)
}

delete_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.DELETE}, state_size, body_size_max, body_mode)
}

delete :: proc {
	delete_simple,
	delete_event,
}

patch_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.PATCH}, body_size_max, body_mode)
}

patch_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.PATCH}, state_size, body_size_max, body_mode)
}

patch :: proc {
	patch_simple,
	patch_event,
}

head_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.HEAD}, body_size_max, body_mode)
}

head_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.HEAD}, state_size, body_size_max, body_mode)
}

head :: proc {
	head_simple,
	head_event,
}

options_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(pattern, handler, {.OPTIONS}, body_size_max, body_mode)
}

options_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(pattern, handler, {.OPTIONS}, state_size, body_size_max, body_mode)
}

options :: proc {
	options_simple,
	options_event,
}

any_simple :: #force_inline proc "contextless" (
	pattern: string,
	handler: Request_Handler,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_request_route(
		pattern,
		handler,
		{.GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS, .TRACE},
		body_size_max,
		body_mode,
	)
}

any_event :: #force_inline proc "contextless" (
	pattern: string,
	handler: Route_Event_Handler,
	state_size: u16 = 0,
	body_size_max: u32 = 0,
	body_mode: Route_Body_Mode = .None,
) -> Route {
	return _build_event_route(
		pattern,
		handler,
		{.GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS, .TRACE},
		state_size,
		body_size_max,
		body_mode,
	)
}

any :: proc {
	any_simple,
	any_event,
}

// Compiled, immutable per-route record stored in `Compiled_Router.descriptors`
// and indexed by `Route_Index`. Mirrors Tina core's `IsolateTypeDescriptor` pattern.

@(private = "package")
Route_Descriptor :: struct {
	handler:       rawptr,
	handler_kind:  Route_Handler_Kind,
	body_size_max: u32,
	body_mode:     Route_Body_Mode,
	state_size:    u16,
}

@(private = "file")
_test_request_handler :: proc(request: ^Request, response: ^Response) -> Route_Step {
	_ = request
	_ = response
	return .Close
}

@(private = "file")
_test_event_handler :: proc(
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
	return .Close
}

@(test)
test_route_builder_post_simple_sets_method_mask :: proc(t: ^testing.T) {
	route := post("/upload", _test_request_handler)
	testing.expect(t, .POST in route.methods_mask, "post route should include POST")
	testing.expect(t, .GET not_in route.methods_mask, "post route should not include GET")
	testing.expect_value(t, route.handler_kind, Route_Handler_Kind.Request)
}

@(test)
test_route_builder_post_simple_accepts_buffered_body_mode :: proc(t: ^testing.T) {
	route := post("/echo", _test_request_handler, body_size_max = 4096, body_mode = Route_Body_Mode.Buffered)
	testing.expect_value(t, route.handler_kind, Route_Handler_Kind.Request)
	testing.expect_value(t, route.body_mode, Route_Body_Mode.Buffered)
	testing.expect_value(t, route.body_size_max, u32(4096))
}

@(test)
test_route_builder_any_event_sets_all_methods :: proc(t: ^testing.T) {
	route := any("/events", _test_event_handler)
	testing.expect_value(t, route.handler_kind, Route_Handler_Kind.Event)
	testing.expect(t, .GET in route.methods_mask, "any should include GET")
	testing.expect(t, .POST in route.methods_mask, "any should include POST")
	testing.expect(t, .PUT in route.methods_mask, "any should include PUT")
	testing.expect(t, .DELETE in route.methods_mask, "any should include DELETE")
	testing.expect(t, .PATCH in route.methods_mask, "any should include PATCH")
	testing.expect(t, .HEAD in route.methods_mask, "any should include HEAD")
	testing.expect(t, .OPTIONS in route.methods_mask, "any should include OPTIONS")
	testing.expect(t, .TRACE in route.methods_mask, "any should include TRACE")
}
