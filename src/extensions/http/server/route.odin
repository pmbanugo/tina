package http_server

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
	pattern:       string,
	body_size_max: u32,
	methods_mask:  Method_Mask,
	body_mode:     Route_Body_Mode,
	state_size:    u16,
}

// Compiled, immutable per-route record stored in `Compiled_Router.descriptors`
// and indexed by `Route_Index`. Mirrors Tina core's `TypeDescriptor` pattern.

@(private = "package")
Route_Descriptor :: struct {
	handler:       rawptr,
	body_size_max: u32,
	body_mode:     Route_Body_Mode,
	state_size:    u16,
}
