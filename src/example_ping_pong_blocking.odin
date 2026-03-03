package tina

import "core:mem"

// --- Tags & Messages ---

APP_TAG_PING : Message_Tag : USER_MESSAGE_TAG_BASE + 1
APP_TAG_PONG : Message_Tag : USER_MESSAGE_TAG_BASE + 2

Ping_Msg :: struct { seq: u32 }
Pong_Msg :: struct { seq: u32 }
Ping_Init_Args :: struct { pong_handle: Handle }

// --- 1. Coordinator Isolate ---

Coordinator_Isolate :: struct {}

coordinator_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    // 1. Spawn Pong
    pong_spec := Spawn_Spec{
        type_id = 2, // PONG_TYPE_ID
        group = 0,
        restart_type = .temporary,
        args_size = 0,
    }

    pong_handle: Handle
    switch h in ctx_spawn(ctx, pong_spec) {
        case Handle: pong_handle = h
        case Spawn_Error: return Effect_Crash{ reason = .Spawn_Failed }
    }

    // 2. Spawn Ping, passing Pong's Handle via inline args_payload
    ping_args := Ping_Init_Args{ pong_handle = pong_handle }
    ping_spec := Spawn_Spec{
        type_id = 1, // PING_TYPE_ID
        group = 0,
        restart_type = .temporary,
        args_size = size_of(Ping_Init_Args),
    }
    copy(ping_spec.args_payload[:], mem.byte_slice(&ping_args, size_of(Ping_Init_Args)))

    if _, err := ctx_spawn(ctx, ping_spec).(Spawn_Error); err {
        return Effect_Crash{ reason = .Spawn_Failed }
    }

    // Coordinator is just a bootstrapper. Die cleanly.
    return Effect_Done{}
}

coordinator_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    return Effect_Receive{}
}


// --- 2. Pong Isolate (Callee) ---

Pong_Isolate :: struct {}

pong_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    return Effect_Receive{}
}

pong_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    if message.tag == APP_TAG_PING {
        ping_msg := cast(^Ping_Msg)&message.body.user.payload[0]

        pong_msg := Pong_Msg{ seq = ping_msg.seq }
        reply_msg: Message
        reply_msg.tag = APP_TAG_PONG
        reply_msg.body.user.payload_size = size_of(Pong_Msg)
        copy(reply_msg.body.user.payload[:], mem.byte_slice(&pong_msg, size_of(Pong_Msg)))

        // Immediately reply and park
        return Effect_Reply{ message = reply_msg }
    }
    return Effect_Receive{}
}


// --- 3. Ping Isolate (Caller) ---

Ping_Isolate :: struct {
    pong_handle: Handle,
    seq: u32,
    success_count: u32,
}

ping_init :: proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect {
    state := cast(^Ping_Isolate)self
    init_args := cast(^Ping_Init_Args)&args[0]

    state.pong_handle = init_args.pong_handle
    state.seq = 0
    state.success_count = 0

    // Construct request
    ping_msg := Ping_Msg{ seq = state.seq }
    req_msg: Message
    req_msg.tag = APP_TAG_PING
    req_msg.body.user.payload_size = size_of(Ping_Msg)
    copy(req_msg.body.user.payload[:], mem.byte_slice(&ping_msg, size_of(Ping_Msg)))

    // Call with a 10-tick timeout
    return Effect_Call{ to = state.pong_handle, message = req_msg, timeout = 10 }
}

ping_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
    state := cast(^Ping_Isolate)self

    if message.tag == TAG_CALL_TIMEOUT {
        // A network drop occurred! The timeout fired. We must retry.
        ping_msg := Ping_Msg{ seq = state.seq }
        req_msg: Message
        req_msg.tag = APP_TAG_PING
        req_msg.body.user.payload_size = size_of(Ping_Msg)
        copy(req_msg.body.user.payload[:], mem.byte_slice(&ping_msg, size_of(Ping_Msg)))

        return Effect_Call{ to = state.pong_handle, message = req_msg, timeout = 10 }

    } else if message.tag == APP_TAG_PONG {
        pong_msg := cast(^Pong_Msg)&message.body.user.payload[0]

        // Assert ordering is preserved
        if pong_msg.seq == state.seq {
            state.success_count += 1
            state.seq += 1
        }

        if state.success_count >= 100 {
            // Reached our goal despite the chaotic network. Shut down.
            return Effect_Done{}
        }

        // Send next ping
        ping_msg := Ping_Msg{ seq = state.seq }
        req_msg: Message
        req_msg.tag = APP_TAG_PING
        req_msg.body.user.payload_size = size_of(Ping_Msg)
        copy(req_msg.body.user.payload[:], mem.byte_slice(&ping_msg, size_of(Ping_Msg)))

        return Effect_Call{ to = state.pong_handle, message = req_msg, timeout = 10 }
    }

    return Effect_Receive{}
}
