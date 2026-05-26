package tina

import "core:mem"

MAX_INIT_ARGS_SIZE :: 64 //Fixed-Size Payload/Args for init_handler
MAX_ISOLATES_PER_TYPE :: 1_048_575 // 20-bit slot index
SENDFILE_ALL_BYTES: u32 : max(u32)

Monotonic_Time_NS :: distinct u64

// Converts a duration in nanoseconds to ticks, rounding up so the timer fires
// at or after the requested duration. Uses the standard unsigned ceil division
// identity: ceil(a/b) = (a + b - 1) / b.
@(private = "package")
_duration_ns_to_ticks :: #force_inline proc "contextless" (duration_ns: u64, timer_resolution_ns: u64) -> u64 {
	return (duration_ns + timer_resolution_ns - 1) / timer_resolution_ns
}

Supervision_Group_Id :: distinct u16
SUPERVISION_GROUP_ID_NONE :: Supervision_Group_Id(0xFFFF)
SUPERVISION_GROUP_ID_ROOT :: Supervision_Group_Id(0)

// Solves the 0xFFFF bitwise truncation hazard by explicitly using the 255th slot
SUPERVISION_SUBGROUP_TYPE_ID: Isolate_Type_Id : 255

// Coarse fault classification for scheduler policy, counters, and logs.
// This is intentionally not a detailed error transport channel. Rich
// diagnostics belong in logs so the hot-path transition stays tiny.
Isolate_Fault_Reason :: enum u8 {
	None                     = 0,
	Spawn_Failed             = 1,
	Unimplemented_Transition = 2,
	Init_Failed              = 3,
	Contract_Violation       = 4,
}

Exit_Kind :: enum u8 {
	Normal, // Child returned Isolate_Transition{kind = .Done} (clean shutdown)
	Crashed, // Child returned Isolate_Transition{kind = .Crash} or panicked (Tier 1 / Tier 2)
	Shutdown, // Child was torn down by supervisor strategy (recursion guard)
}

Isolate_Transition_Kind :: enum u8 {
	Done,
	Yield,
	Wait_Message,
	Wait_Reply,
	Wait_Io,
	Crash,
}

// The scheduler only needs the next isolate state plus a coarse fault classification.
Isolate_Transition :: struct {
	kind:         Isolate_Transition_Kind,
	fault_reason: Isolate_Fault_Reason,
}

#assert(size_of(Isolate_Transition) == 2)

ISOLATE_TRANSITION_DONE :: Isolate_Transition{kind = .Done}
ISOLATE_TRANSITION_YIELD :: Isolate_Transition{kind = .Yield}
ISOLATE_TRANSITION_WAIT_MESSAGE :: Isolate_Transition{kind = .Wait_Message}
ISOLATE_TRANSITION_WAIT_REPLY :: Isolate_Transition{kind = .Wait_Reply}
ISOLATE_TRANSITION_WAIT_IO :: Isolate_Transition{kind = .Wait_Io}

transition_to_crash :: #force_inline proc "contextless" (fault_reason: Isolate_Fault_Reason) -> Isolate_Transition {
	return Isolate_Transition{kind = .Crash, fault_reason = fault_reason}
}

transition_to_wait_io_or_crash :: #force_inline proc "contextless" (result: Io_Submit_Result) -> Isolate_Transition {
	if result == .ok {
		return ISOLATE_TRANSITION_WAIT_IO
	}
	return transition_to_crash(.Contract_Violation)
}

Send_Result :: enum u8 {
	ok,
	mailbox_full,
	pool_exhausted,
	stale_handle,
}

Reply_Result :: enum u8 {
	ok,
	already_replied,
	not_call_context,
	mailbox_full,
	pool_exhausted,
	stale_handle,
}

Call_Result :: enum u8 {
	ok,
	already_staged,
	mailbox_full,
	stale_handle,
	target_quarantined,
}

Io_Submit_Result :: enum u8 {
	ok,
	already_staged,
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

Correlation_Id :: distinct u32

CORRELATION_ID_NONE :: Correlation_Id(0)
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
	type_id:      Isolate_Type_Id,
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

// Scalar capability token valid only during the active Isolate handler invocation.
TinaContext :: distinct u64

Enqueue_Result :: enum u8 {
	Success,
	Full,
}

// ============================================================================
// Ergonomic Helpers
// ============================================================================

// Helper to safely cast a typed struct pointer into a byte slice for sending.
bytes_of :: #force_inline proc(ptr: ^$T) -> []u8 {
	return mem.byte_slice(ptr, size_of(T))
}

// Retrieves the current deterministic time (in nanoseconds) from the scheduler.
// This ensures all isolates process events using a consistent, uniform clock per tick.
ctx_monotonic_time_ns :: #force_inline proc(ctx: TinaContext) -> Monotonic_Time_NS {
	invocation := ctx_invocation(ctx)
	return Monotonic_Time_NS(invocation.current_tick * invocation.timer_resolution_ns)
}

ctx_timer_resolution_ns :: #force_inline proc(ctx: TinaContext) -> u64 {
	return ctx_invocation(ctx).timer_resolution_ns
}

ctx_current_tick :: #force_inline proc(ctx: TinaContext) -> u64 {
	return ctx_invocation(ctx).current_tick
}

// Helper to safely cast an incoming message payload byte slice into a typed pointer.
payload_as :: #force_inline proc($T: typeid, payload: []u8) -> ^T {
	assert(size_of(T) <= len(payload), "Payload slice too small for type")
	return cast(^T)raw_data(payload)
}

// Serializes typed init args into a fixed-size buffer for Spawn_Spec.
init_args_of :: #force_inline proc(args: ^$T) -> (payload: [MAX_INIT_ARGS_SIZE]u8, size: u8) {
	#assert(size_of(T) <= MAX_INIT_ARGS_SIZE, "Init args exceed MAX_INIT_ARGS_SIZE")
	mem.copy(&payload[0], args, size_of(T))
	return payload, u8(size_of(T))
}

// Debug-checked cast from rawptr to a typed Isolate pointer.
// Validates at runtime (under TINA_DEBUG_ASSERTS) that the registered stride
// matches the target type, catching wrong-type casts before they corrupt memory.
self_as :: #force_inline proc($T: typeid, self_raw: rawptr, ctx: TinaContext) -> ^T {
	when TINA_RUNTIME_ASSERTIONS {
		invocation := ctx_invocation(ctx)
		shard := invocation.shard
		type_id := invocation.type_id
		registered_stride := shard.type_descriptors[type_id].stride
		assert(
			registered_stride == size_of(T),
			"self_as: type stride mismatch — registered stride does not match target type size",
		)
	}
	return cast(^T)self_raw
}

// Computes the byte offset of a buffer within an Isolate's stable memory region.
// In debug builds, validates the slice actually lives inside the Isolate struct.
payload_offset_of :: #force_inline proc(self: ^$Isolate, buffer: []u8) -> u16 {
	base := uintptr(self)
	buf_start := uintptr(raw_data(buffer))
	when TINA_RUNTIME_ASSERTIONS {
		assert(buf_start >= base, "payload_offset_of: buffer starts before isolate base")
		assert(
			buf_start + uintptr(len(buffer)) <= base + size_of(Isolate),
			"payload_offset_of: buffer extends past isolate end",
		)
	}
	return u16(buf_start - base)
}

// Stages a socket send from an Isolate-owned buffer for commit if the handler
// returns Isolate_Transition{kind = .Wait_Io}.
@(require_results)
ctx_io_send :: #force_inline proc(
	ctx: TinaContext,
	self: ^$Isolate,
	fd: FD_Handle,
	buffer: []u8,
) -> Io_Submit_Result {
	return ctx_submit_io(
		ctx,
		IoOp_Send {
			fd = fd,
			payload_offset = payload_offset_of(self, buffer),
			payload_size = u32(len(buffer)),
		},
	)
}

// Stages write command to a file-descriptor, from an Isolate-owned buffer for commit
// if the handler returns Isolate_Transition{kind = .Wait_Io}.
@(require_results)
ctx_io_write :: #force_inline proc(
	ctx: TinaContext,
	self: ^$Isolate,
	fd: FD_Handle,
	buffer: []u8,
	offset: u64,
) -> Io_Submit_Result {
	return ctx_submit_io(
		ctx,
		IoOp_Write {
			fd = fd,
			payload_offset = payload_offset_of(self, buffer),
			payload_size = u32(len(buffer)),
			offset = offset,
		},
	)
}

// Stages a zero-copy sendfile operation for commit if the handler returns
// Isolate_Transition{kind = .Wait_Io}.
@(require_results)
ctx_io_sendfile :: #force_inline proc(
	ctx: TinaContext,
	fd_socket: FD_Handle,
	fd_file: FD_Handle,
	source_offset: u64,
	size: u32,
) -> Io_Submit_Result {
	return ctx_submit_io(
		ctx,
		IoOp_Sendfile {
			fd_file = fd_file,
			fd_socket = fd_socket,
			source_offset = source_offset,
			size = size,
		},
	)
}

// Stages a UDP send from an Isolate-owned buffer for commit if the handler
// returns Isolate_Transition{kind = .Wait_Io}.
@(require_results)
ctx_io_sendto :: #force_inline proc(
	ctx: TinaContext,
	self: ^$Isolate,
	fd: FD_Handle,
	buffer: []u8,
	address: Socket_Address,
) -> Io_Submit_Result {
	return ctx_submit_io(
		ctx,
		IoOp_Sendto {
			fd = fd,
			address = address,
			payload_offset = payload_offset_of(self, buffer),
			payload_size = u32(len(buffer)),
		},
	)
}

// Constructs an IPv4 socket address.
ipv4 :: #force_inline proc "contextless" (a, b, c, d: u8, port: u16) -> Socket_Address {
	return Socket_Address_Inet4{address = {a, b, c, d}, port = port}
}

// Constructs an IPv6 socket address.
ipv6 :: #force_inline proc "contextless" (
	addr: [16]u8,
	port: u16,
	flow: u32 = 0,
	scope: u32 = 0,
) -> Socket_Address {
	return Socket_Address_Inet6{address = addr, port = port, flow = flow, scope = scope}
}

// Sends a typed message to a target (Isolate), identified by its Handle.
// Returns a Send_Result immediately to provide backpressure feedback (e.g., mailbox full, dead handle).
@(require_results)
ctx_send_typed :: #force_inline proc(
	ctx: TinaContext,
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

// A distinct type representing a value that already has high entropy
// in its highest bits. You MUST explicitly cast to this type to
// bypass the SplitMix64 safety net for key_to_shard().
Hashed_Key_32 :: distinct u32

// SplitMix64 finalizer to guarantee bit-avalanche.
mix_bits_to_32 :: #force_inline proc "contextless" (key: u64) -> u32 {
	hash_value := key
	hash_value = (hash_value ~ (hash_value >> 30)) * 0xbf58476d1ce4e5b9
	hash_value = (hash_value ~ (hash_value >> 27)) * 0x94d049bb133111eb
	hash_value = hash_value ~ (hash_value >> 31)

	// We only need 32 bits of entropy for fastrange against a u8 divisor.
	// The highest bits have the best avalanche properties.
	return u32(hash_value >> 32)
}

// Consistent key-based partitioning utility
// Safely maps any u64 key (e.g., session_id, user_id) to a Shard_Id.
// Use this when you need to decide which Shard should spawn a new Isolate
// or handle a specific piece of data.
from_key_to_shard :: #force_inline proc "contextless" (key: u64, shard_count: u8) -> Shard_Id {
	// Bijection Mixer: Guarantee uniform distribution regardless of input shape.
	hash_value_32 := mix_bits_to_32(key)

	// Mapping: fastrange. (hash * N) >> 32
	shard_index := u8((u64(hash_value_32) * u64(shard_count)) >> 32)

	return Shard_Id(shard_index)
}

// Consistent key-based partitioning utility
// Accepts a Hashed_Key_32 & skips the Bijection Mixer entirely
// and just applies the fastrange mapping.
from_hash_to_shard :: #force_inline proc "contextless" (
	hash: Hashed_Key_32,
	shard_count: u8,
) -> Shard_Id {
	// Fastrange map directly
	shard_index := u8((u64(hash) * u64(shard_count)) >> 32)
	return Shard_Id(shard_index)
}

// Consistent key-based partitioning utility
key_to_shard :: proc {
	from_key_to_shard,
	from_hash_to_shard,
}
