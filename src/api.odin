package tina

import "core:mem"

MAX_INIT_ARGS_SIZE :: 64 //Fixed-Size Payload/Args for init_fn
MAX_ISOLATES_PER_TYPE :: 1_048_575 // 20-bit slot index

Supervision_Group_Id :: distinct u16
SUPERVISION_GROUP_ID_NONE :: Supervision_Group_Id(0xFFFF)
SUPERVISION_GROUP_ID_ROOT :: Supervision_Group_Id(0)

// Solves the 0xFFFF bitwise truncation hazard by explicitly using the 255th slot
SUPERVISION_SUBGROUP_TYPE_ID: u8 : 255

Crash_Reason :: enum u8 {
	None                 = 0,
	Spawn_Failed         = 1,
	Unimplemented_Effect = 2,
	Init_Failed          = 3,
}

Exit_Kind :: enum u8 {
	Normal, // Child returned Effect_Done (clean shutdown)
	Crashed, // Child returned Effect_Crash or panicked (Tier 1 / Tier 2)
	Shutdown, // Child was torn down by supervisor strategy (recursion guard)
}

// Explicitly sized variants for the Effect tagged union. Empty structs (should) cost 0 bytes.
Effect_Done :: struct {}
Effect_Crash :: struct {
	reason: Crash_Reason,
}
Effect_Yield :: struct {}
Effect_Receive :: struct {}
Effect_Call :: struct {
	to:      Handle,
	message: Message,
	timeout: u64,
}
Effect_Reply :: struct {
	message: Message,
}
Effect_Io :: struct {
	operation: IoOp,
}

// The state transition returned by an Isolate handler.
// It tells the scheduler exactly what to do with the Isolate next (e.g., park, crash, wait for I/O).
Effect :: union {
	Effect_Done,
	Effect_Crash,
	Effect_Yield,
	Effect_Receive,
	Effect_Call,
	Effect_Reply,
	Effect_Io,
}

Send_Result :: enum u8 {
	ok,
	mailbox_full,
	pool_exhausted,
	stale_handle,
}

Spawn_Error :: enum u8 {
	arena_full,
	group_full,
	type_not_allocated,
	init_failed,
}
Spawn_Result :: union {
	Handle,
	Spawn_Error,
}
Restart_Type :: enum u8 {
	permanent,
	transient,
	temporary,
}

Transfer_Alloc_Error :: enum u8 {
	None,
	Pool_Exhausted,
}
Transfer_Write_Error :: enum u8 {
	None,
	Stale_Handle,
	Bounds_Violation,
}
Transfer_Read_Error :: enum u8 {
	None,
	Stale_Handle,
}

Transfer_Alloc_Result :: union {
	Transfer_Handle,
	Transfer_Alloc_Error,
}
Transfer_Read_Result :: union {
	[]u8,
	Transfer_Read_Error,
}

// Configuration passed to `ctx_spawn` to dynamically create a new Isolate at runtime.
Spawn_Spec :: struct {
	args_payload: [MAX_INIT_ARGS_SIZE]u8,
	group_id:     Supervision_Group_Id,
	type_id:      u8,
	restart_type: Restart_Type,
	args_size:    u8,
	handoff_mode: Handoff_Mode,
	_padding:     [2]u8,
	handoff_fd:   FD_Handle,
}

Context_Flag :: enum u8 {
	Is_Call,
	// Future flags would come here.
}
Context_Flags :: distinct bit_set[Context_Flag;u8]

// The primary API gateway for Isolates during execution.
// Passed into `init_fn` and `handler_fn` to provide access to messaging, spawning, and memory.
TinaContext :: struct {
	// Opaque pointer to internal Shard state to prevents user mutation.
	_shard:                 rawptr,
	self_handle:            Handle,
	current_message_source: Handle,
	// Memory surfaces (initialized per handler invocation by the scheduler)
	working_arena:          mem.Arena,
	scratch_arena:          mem.Arena,
	current_correlation:    u32,
	flags:                  Context_Flags,
	_padding:               [3]u8,
}

Enqueue_Result :: enum u8 {
	Success,
	Full,
}

// ============================================================================
// Internal Helpers
// ============================================================================

@(private = "package")
_ctx_extract_shard :: #force_inline proc "contextless" (ctx: ^TinaContext) -> ^Shard {
	return cast(^Shard)ctx._shard
}

// ============================================================================
// Ergonomic Helpers
// ============================================================================

// Helper to safely cast a typed struct pointer into a byte slice for sending.
bytes_of :: #force_inline proc(ptr: ^$T) -> []u8 {
	return mem.byte_slice(ptr, size_of(T))
}

// Helper to safely cast an incoming message payload byte slice into a typed pointer.
payload_as :: #force_inline proc($T: typeid, payload: []u8) -> ^T {
	assert(size_of(T) <= len(payload), "Payload slice too small for type")
	return cast(^T)raw_data(payload)
}

// Sends a typed message to a target (Isolate), identified by its Handle.
// Returns a Send_Result immediately to provide backpressure feedback (e.g., mailbox full, dead handle).
@(require_results)
ctx_send_typed :: #force_inline proc(
	ctx: ^TinaContext,
	to: Handle,
	$tag: Message_Tag,
	message: ^$T,
) -> Send_Result where size_of(T) <=
	MAX_PAYLOAD_SIZE {
	#assert(
		tag >= USER_MESSAGE_TAG_BASE,
		"ctx_send: Cannot forge system messages. Tag must be >= 0x0040.",
	)
	return ctx_send_raw(ctx, to, tag, mem.byte_slice(message, size_of(T)))
}

ctx_send :: proc {
	ctx_send_raw,
	ctx_send_typed,
}

make_spawn_args :: #force_inline proc(args: ^$T) -> (buf: [MAX_INIT_ARGS_SIZE]u8, size: u8) {
	assert(size_of(T) <= MAX_INIT_ARGS_SIZE, "Init args exceed MAX_INIT_ARGS_SIZE")
	mem.copy(&buf[0], args, size_of(T))
	return buf, u8(size_of(T))
}

// Consistent key-based partitioning utility
// Uses simple modulo to map a logical key (e.g., session_id, user_id)
// to a Shard ID.
// Use this when you need to decide which Shard should spawn a new Isolate
// or handle a specific piece of data.
// If your keys are not uniformly distributed (e.g., memory addresses),
// perhaps hash them before passing them here.
key_to_shard :: #force_inline proc "contextless" (key: u64, shard_count: u8) -> u8 {
	return u8(key % u64(shard_count))
}
