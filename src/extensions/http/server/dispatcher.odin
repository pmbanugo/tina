package http_server

import tina "../../.."

@(private = "package")
_http_dispatcher_init :: proc(self: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	dispatcher := cast(^HTTP_Dispatcher)self
	if len(args) < size_of(HTTP_Dispatcher_Init_Args) {
		return tina.Effect_Crash{reason = .Init_Failed}
	}

	init_args := (cast(^HTTP_Dispatcher_Init_Args)raw_data(args))^
	dispatcher.shard_runtime = init_args.shard_runtime
	_ = ctx
	return tina.Effect_Receive{}
}

@(private = "package")
_http_dispatcher_handler :: proc(
	self: rawptr,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	dispatcher := cast(^HTTP_Dispatcher)self
	_ = dispatcher
	_ = message
	_ = ctx
	return tina.Effect_Receive{}
}
