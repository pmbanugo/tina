package tina

MAX_INIT_ARGS_SIZE :: 64 //Fixed-Size Payload/Args for init_fn
MAX_ISOLATES_PER_TYPE :: int(max(u16)) // 65535, constrained by 16-bit slot index in Handle

HANDLE_NONE :: Handle(0)

Crash_Reason :: enum u8 {
    None = 0,
    Spawn_Failed = 1,
    Unimplemented_Effect = 2,
    Init_Failed = 3,
}

// Explicitly sized variants for the Effect tagged union. Empty structs (should) cost 0 bytes.
Effect_Done    :: struct {}
Effect_Crash   :: struct { reason: Crash_Reason }
Effect_Yield   :: struct {}
Effect_Receive :: struct {}
Effect_Call    :: struct { to: Handle, message: Message, timeout: u64 }
Effect_Reply   :: struct { message: Message }
Effect_Io      :: struct { operation: u32 } // Phase 4 placeholder

Effect :: union {
    Effect_Done,
    Effect_Crash,
    Effect_Yield,
    Effect_Receive,
    Effect_Call,
    Effect_Reply,
    Effect_Io,
}

Send_Result :: enum u8 { ok, mailbox_full, pool_exhausted, stale_handle }

Spawn_Error :: enum u8 { arena_full, group_full, type_not_allocated, init_failed }
Spawn_Result :: union { Handle, Spawn_Error }
Restart_Type :: enum u8 { permanent, transient, temporary }

Spawn_Spec :: struct {
    group: u32,
    args_payload:[MAX_INIT_ARGS_SIZE]u8,
    type_id: u8,
    restart_type: Restart_Type,
    args_size: u8,
}

TinaContext :: struct {
    shard: ^Shard,
    self_handle: Handle,
    current_message_source: Handle,
}
