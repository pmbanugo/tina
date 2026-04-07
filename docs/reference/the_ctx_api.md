# The `ctx` API Reference

Complete public API surface available to Isolate `init_fn` and `handler_fn` callbacks. All functions operate on a `^TinaContext` passed by the scheduler.

Source files: `api.odin`, `api_context.odin`, `logging.odin`, `timer.odin`.

---

## Messaging

| Call | Signature | Returns | Errors | Description |
|------|-----------|---------|--------|-------------|
| `ctx_send` | Overloaded: `ctx_send_raw(ctx, to, tag, payload)` / `ctx_send_typed(ctx, to, $tag, &msg)` | `Send_Result` | `.mailbox_full`, `.pool_exhausted`, `.stale_handle` | Send a message to a target Isolate. `tag` must be `>= USER_MESSAGE_TAG_BASE` (0x0040). Payload max: 96 bytes. |
| `ctx_transfer_send` | `ctx_transfer_send(ctx, to, handle) -> Send_Result` | `Send_Result` | `.mailbox_full`, `.pool_exhausted`, `.stale_handle` | Send a `Transfer_Handle` reference to another Isolate. Uses system tag `TAG_TRANSFER` internally. |

**Tag constants:**

| Constant | Value | Purpose |
|----------|-------|---------|
| `USER_MESSAGE_TAG_BASE` | `0x0040` | Minimum tag value for user messages. |
| `TAG_TIMER` | `0x0002` | Delivered when a registered timer fires. |
| `TAG_TRANSFER` | `0x0004` | System tag for transfer buffer messages. |
| `TAG_SHUTDOWN` | `0x0003` | Shard shutdown notification. |
| `TAG_SHARD_RESTARTED` | `0x0005` | Peer shard restarted notification. |
| `TAG_SHARD_QUARANTINED` | `0x0006` | Peer shard quarantined notification. |

**I/O completion tags** (delivered by the reactor, not user-sendable):

| Constant | Value |
|----------|-------|
| `IO_TAG_READ_COMPLETE` | `0x0010` |
| `IO_TAG_WRITE_COMPLETE` | `0x0011` |
| `IO_TAG_ACCEPT_COMPLETE` | `0x0012` |
| `IO_TAG_CONNECT_COMPLETE` | `0x0013` |
| `IO_TAG_SEND_COMPLETE` | `0x0014` |
| `IO_TAG_RECV_COMPLETE` | `0x0015` |
| `IO_TAG_SENDTO_COMPLETE` | `0x0016` |
| `IO_TAG_RECVFROM_COMPLETE` | `0x0017` |
| `IO_TAG_CLOSE_COMPLETE` | `0x0018` |

---

## Spawning

| Call | Signature | Returns | Errors | Description |
|------|-----------|---------|--------|-------------|
| `ctx_spawn` | `ctx_spawn(ctx, spec: Spawn_Spec) -> Spawn_Result` | `Handle` or `Spawn_Error` | `.arena_full`, `.group_full`, `.type_not_allocated`, `.init_failed` | Spawn a new Isolate on the local Shard. Requires `@(require_results)`. |

---

## Timers

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `ctx_register_timer` | `ctx_register_timer(ctx, duration_ns: u64, tag: Message_Tag)` | void | Register a one-shot timer. Delivers a message with the given `tag` back to this Isolate after `duration_ns` nanoseconds (converted to ticks internally). |

---

## Logging

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `ctx_log` | Overloaded: `ctx_log_raw(ctx, level, $tag, payload)` / `ctx_log_typed(ctx, level, $tag, &msg)` | void | Write a diagnostic log entry. Each Shard buffers log entries and flushes them to stderr once per scheduler tick. |

**Log levels:**

```odin
Log_Level :: enum u8 {
    ERROR = 0,
    WARN  = 1,
    INFO  = 2,
    DEBUG = 3,
}
```

**Log tags:** `Log_Tag` is a `distinct u8`. Tags `0x00`–`0x3F` are reserved for the framework (system tags). User code must use tags `>= USER_LOG_TAG_BASE` (`0x40`). This is enforced at compile time — using a system tag in `ctx_log` is a compile error.

Define your own tags for filtering and categorization:

```odin
MY_APP_TAG:    tina.Log_Tag : tina.USER_LOG_TAG_BASE      // 0x40
MY_METRIC_TAG: tina.Log_Tag : tina.USER_LOG_TAG_BASE + 1  // 0x41
```

**Usage pattern:**

```odin
// Format into the scratch arena, then log.
str := fmt.bprintf(ctx.scratch_arena.data, "Connection %d closed after %d bytes",
    self.conn_id, self.bytes_sent)
tina.ctx_log(ctx, .INFO, MY_APP_TAG, transmute([]u8)str)
```

**Output format** (written to stderr):

```
[tick] LEVEL[Tag:hex] Handle:hex - payload
```

Example: `[48231] INFO[Tag:40] Handle:10003A2 - Connection 5 closed after 1024 bytes`

**Behavior notes:**

- Log formatting happens after all handlers have run, and then flushed to stderr.
- If the log buffer is full, new entries are silently dropped. Size the buffer via `log_ring_size` on `SystemSpec` (default depends on your config; must be a power of 2).
- Maximum payload per log entry is 96 bytes (same as message envelope payload). Longer strings are truncated.

---

## Memory

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `ctx_working_arena` | `ctx_working_arena(ctx) -> mem.Allocator` | `Allocator` | The Isolate's private working arena. Persists across handler invocations. Freed on teardown. |
| `ctx_working_arena_reset` | `ctx_working_arena_reset(ctx)` | void | Resets working arena offset to 0. All prior allocations invalidated. |
| `ctx_scratch_arena` | `ctx_scratch_arena(ctx) -> mem.Allocator` | `Allocator` | Shard-wide scratch arena. Reset before every handler call. For temporaries only. |

---

## Transfer Buffers (Large Payloads)

For payloads exceeding the 96-byte inline message limit.

| Call | Signature | Returns | Errors | Description |
|------|-----------|---------|--------|-------------|
| `ctx_transfer_alloc` | `ctx_transfer_alloc(ctx) -> Transfer_Alloc_Result` | `Transfer_Handle` or `Transfer_Alloc_Error` | `.Pool_Exhausted` | Allocate a transfer buffer slot. |
| `ctx_transfer_write` | Overloaded: `ctx_transfer_write_raw(ctx, handle, data)` / `ctx_transfer_write_typed(ctx, handle, &msg)` | `Transfer_Write_Error` | `.Stale_Handle`, `.Bounds_Violation` | Write data into a transfer slot. |
| `ctx_transfer_read` | `ctx_transfer_read(ctx, handle) -> Transfer_Read_Result` | `[]u8` or `Transfer_Read_Error` | `.Stale_Handle` | Read from a transfer buffer. The scheduler auto-frees the transfer slot when the receiver's handler returns. **Call ONCE per invocation.** |
| `ctx_transfer_send` | `ctx_transfer_send(ctx, to, handle) -> Send_Result` | `Send_Result` | `.mailbox_full`, `.pool_exhausted`, `.stale_handle` | Send a transfer handle reference to another Isolate. |

---

## I/O Control (Synchronous Socket Operations)

These are non-batched, non-blocking control-plane operations executed during handler invocation.

| Call | Signature | Returns | Errors | Description |
|------|-----------|---------|--------|-------------|
| `ctx_socket` | `ctx_socket(ctx, domain, socket_type, protocol) -> (FD_Handle, Reactor_Socket_Error)` | FD handle + error | `.Backend_Error`, `.FD_Table_Full` | Create a socket and register it in the FD table. |
| `ctx_bind` | `ctx_bind(ctx, fd: FD_Handle, address: Socket_Address) -> Backend_Error` | `Backend_Error` | `.Queue_Full`, `.System_Error`, `.Not_Found` | Bind socket to address. |
| `ctx_listen` | `ctx_listen(ctx, fd: FD_Handle, backlog: u32) -> Backend_Error` | `Backend_Error` | `.Queue_Full`, `.System_Error`, `.Not_Found` | Start listening on a bound socket. |
| `ctx_setsockopt` | Overloaded: `ctx_setsockopt_raw`, `_bool`, `_i32`, `_linger` | `Backend_Error` | `.Queue_Full`, `.System_Error`, `.Not_Found` | Set a socket option. |
| `ctx_getsockopt` | `ctx_getsockopt(ctx, fd, level, option) -> (Socket_Option_Value, Backend_Error)` | value + error | `.Queue_Full`, `.System_Error`, `.Not_Found` | Get a socket option value. |
| `ctx_shutdown` | `ctx_shutdown(ctx, fd: FD_Handle, how: Shutdown_How) -> Backend_Error` | `Backend_Error` | `.Queue_Full`, `.System_Error`, `.Not_Found` | Shutdown a socket connection direction. |
| `ctx_read_buffer` | `ctx_read_buffer(ctx, buffer_index: u16, size: u32) -> []u8` | `[]u8` | — | Read I/O completion data from the reactor buffer pool. Valid for one handler call only. |

---

## Lifecycle & Identity

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `ctx_is_shutting_down` | `ctx_is_shutting_down(ctx) -> bool` | `bool` | Is the Shard in shutdown mode? |
| `ctx_shard_id` | `ctx_shard_id(ctx) -> u8` | `u8` | Current Shard's ID. |
| `ctx_supervision_group_id` | `ctx_supervision_group_id(ctx) -> Supervision_Group_Id` | `Supervision_Group_Id` | Current Isolate's supervision group. |
| `ctx_root_supervision_group_id` | `ctx_root_supervision_group_id() -> Supervision_Group_Id` | `Supervision_Group_Id` | Root supervision group ID (constant `0`). No `ctx` parameter. |
| `ctx_type_config` | `ctx_type_config(ctx) -> ^TypeDescriptor` | `^TypeDescriptor` | Type descriptor for current Isolate's registered type. |

---

## Ergonomic Helpers

Not `ctx_`-prefixed but part of the public API.

### Type Casting

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `self_as` | `self_as($T, self_raw: rawptr, ctx) -> ^T` | `^T` | Debug-checked cast from `rawptr` to typed Isolate pointer. When `TINA_DEBUG_ASSERTS` is true, validates stride matches `size_of(T)`. |
| `payload_as` | `payload_as($T, payload: []u8) -> ^T` | `^T` | Cast message payload bytes to a typed pointer. Asserts `size_of(T) <= len(payload)`. |
| `bytes_of` | `bytes_of(ptr: ^$T) -> []u8` | `[]u8` | Cast a typed struct pointer to a byte slice for sending. |

### Spawn Argument Serialization

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `init_args_of` | `init_args_of(args: ^$T) -> ([MAX_INIT_ARGS_SIZE]u8, u8)` | buffer + size | Serialize typed init args into a fixed-size buffer for `Spawn_Spec`. Compile-time asserts `size_of(T) <= 64`. |
| `make_spawn_args` | `make_spawn_args(args: ^$T) -> (buf, size)` | buffer + size | Alias for `init_args_of`. Runtime assert instead of compile-time. |

### I/O Effect Builders

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `io_send` | `io_send(self: ^$Isolate, fd: FD_Handle, buffer: []u8) -> Effect` | `Effect_Io` | Build a send Effect. `buffer` must live inside the Isolate struct. |
| `io_write` | `io_write(self: ^$Isolate, fd: FD_Handle, buffer: []u8, offset: u64) -> Effect` | `Effect_Io` | Build a write Effect at a byte offset. |
| `io_sendto` | `io_sendto(self: ^$Isolate, fd: FD_Handle, buffer: []u8, address: Socket_Address) -> Effect` | `Effect_Io` | Build a sendto Effect (UDP). |
| `payload_offset_of` | `payload_offset_of(self: ^$Isolate, buffer: []u8) -> u16` | `u16` | Compute byte offset of a buffer within an Isolate's stable memory. Debug-validated. |

### Address Construction

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `ipv4` | `ipv4(a, b, c, d: u8, port: u16) -> Socket_Address` | `Socket_Address` | Construct an IPv4 socket address. |
| `ipv6` | `ipv6(addr: [16]u8, port: u16, flow: u32 = 0, scope: u32 = 0) -> Socket_Address` | `Socket_Address` | Construct an IPv6 socket address. |

### Partitioning

| Call | Signature | Returns | Description |
|------|-----------|---------|-------------|
| `key_to_shard` | `key_to_shard(key: u64, shard_count: u8) -> u8` | `u8` | Consistent key-based shard partitioning via modulo. Hash non-uniform keys first. |

---

## Key Types

### `Effect`

Tagged union returned by `init_fn` and `handler_fn`. Tells the scheduler what to do next.

```odin
Effect :: union {
    Effect_Done,      // Clean shutdown. Isolate is terminated.
    Effect_Crash,     // Crash with reason. Triggers supervision.
    Effect_Yield,     // Yield and re-enter handler on next tick.
    Effect_Receive,   // Park until a message arrives.
    Effect_Call,      // Send a message and park until reply or timeout.
    Effect_Reply,     // Reply to a pending Call.
    Effect_Io,        // Submit an async I/O operation.
}
```

**Variant fields:**

| Variant | Fields | Notes |
|---------|--------|-------|
| `Effect_Done` | — | Empty struct. |
| `Effect_Crash` | `reason: Crash_Reason` | Triggers supervision strategy. |
| `Effect_Yield` | — | Re-scheduled next tick. |
| `Effect_Receive` | — | Parked until message enqueued. |
| `Effect_Call` | `to: Handle`, `message: Message`, `timeout: u64` | Synchronous call with timeout. |
| `Effect_Reply` | `message: Message` | Reply to a pending call. |
| `Effect_Io` | `operation: IoOp` | Async I/O. Completion delivered as a message. |

### `IoOp`

```odin
IoOp :: union {
    IoOp_Read,      // {fd, buffer_size_max, offset}
    IoOp_Write,     // {fd, payload_offset, payload_size, offset}
    IoOp_Accept,    // {listen_fd}
    IoOp_Connect,   // {fd, address}
    IoOp_Send,      // {fd, payload_offset, payload_size}
    IoOp_Recv,      // {fd, buffer_size_max}
    IoOp_Sendto,    // {fd, address, payload_offset, payload_size}
    IoOp_Recvfrom,  // {fd, buffer_size_max}
    IoOp_Close,     // {fd}
}
```

### `Send_Result`

```odin
Send_Result :: enum u8 {
    ok,             // Message enqueued successfully.
    mailbox_full,   // Target mailbox or cross-shard channel is full.
    pool_exhausted, // Message pool has no free slots.
    stale_handle,   // Target handle is dead (generation mismatch or quarantined shard).
}
```

### `Spawn_Result`

```odin
Spawn_Result :: union {
    Handle,       // Success — the new Isolate's handle.
    Spawn_Error,  // Failure reason.
}
```

### `Spawn_Error`

```odin
Spawn_Error :: enum u8 {
    arena_full,          // No memory for the Isolate's slot.
    group_full,          // Supervision group at dynamic child capacity.
    type_not_allocated,  // Type ID has no allocated slots on this Shard.
    init_failed,         // init_fn returned an error Effect.
}
```

### `Spawn_Spec`

Configuration passed to `ctx_spawn`.

```odin
Spawn_Spec :: struct {
    args_payload: [MAX_INIT_ARGS_SIZE]u8,  // Serialized init args (max 64 bytes).
    group_id:     Supervision_Group_Id,     // Target supervision group.
    type_id:      u8,                       // Registered TypeDescriptor ID.
    restart_type: Restart_Type,             // permanent | transient | temporary.
    args_size:    u8,                       // Actual byte count within args_payload.
    handoff_mode: Handoff_Mode,             // FD ownership transfer mode.
    handoff_fd:   FD_Handle,                // FD to hand off (FD_HANDLE_NONE if none).
}
```

### `TinaContext`

The primary API gateway. Passed to `init_fn` and `handler_fn`.

**User-visible fields:**

| Field | Type | Description |
|-------|------|-------------|
| `self_handle` | `Handle` | This Isolate's current handle. |
| `current_message_source` | `Handle` | Source handle of the currently dispatched message. |
| `working_arena` | `mem.Arena` | Private per-Isolate arena. Persists across handler calls. |
| `scratch_arena` | `mem.Arena` | Shard-wide scratch. Reset before each handler call. |
| `current_correlation` | `u32` | Correlation ID for Call/Reply matching. |
| `flags` | `Context_Flags` | Bit set. Currently: `{Is_Call}`. |

`_shard` is opaque internal state — do not access.

### `Message`

Incoming event to an Isolate handler. Contains a `#raw_union` body:

**`message.user` fields (for user/system messages):**

| Field | Type | Description |
|-------|------|-------------|
| `source` | `Handle` | Sender's handle. |
| `payload_size` | `u16` | Actual payload byte count. |
| `payload` | `[96]u8` | Raw payload bytes. Use `payload_as` to cast. |

**`message.io` fields (for I/O completions):**

| Field | Type | Description |
|-------|------|-------------|
| `peer_address` | `Peer_Address` | Peer address from accept/recvfrom. |
| `fd` | `FD_Handle` | Which FD completed (or new client FD for accept). |
| `result` | `i32` | Bytes transferred, or negative error code. |
| `buffer_index` | `u16` | Reactor buffer pool index. Pass to `ctx_read_buffer`. |

**`message.tag`** — `Message_Tag` discriminant. Switch on this to determine message type.

### `Handle`

```odin
Handle :: distinct u64
HANDLE_NONE :: Handle(0)
```

Packed 64-bit generational handle. Bit layout:
- Bits 63–56: `shard_id` (8 bits)
- Bits 55–48: `type_id` (8 bits)
- Bits 47–28: `slot_index` (20 bits)
- Bits 27–0: `generation` (28 bits)

### `Crash_Reason`

```odin
Crash_Reason :: enum u8 {
    None                 = 0,  // Generic / user-triggered crash.
    Spawn_Failed         = 1,  // A spawned child failed.
    Unimplemented_Effect = 2,  // Returned an unhandled Effect variant.
    Init_Failed          = 3,  // Initialization failed.
}
```

### `Restart_Type`

```odin
Restart_Type :: enum u8 {
    permanent,  // Always restarted on exit.
    transient,  // Restarted only on crash (not normal exit).
    temporary,  // Never restarted.
}
```

### Error Types

**`Reactor_Socket_Error`:**
```odin
Reactor_Socket_Error :: enum u8 {
    None,           // Success.
    Backend_Error,  // OS-level socket creation failed.
    FD_Table_Full,  // Shard's FD table has no free slots.
}
```

**`Backend_Error`:**
```odin
Backend_Error :: enum u8 {
    None,          // Success.
    Queue_Full,    // Submission queue is full.
    System_Error,  // OS-level error.
    Not_Found,     // FD or resource not found.
    Too_Late,      // Operation cancelled or expired.
    Unsupported,   // Operation not supported on this platform.
}
```

**`Transfer_Alloc_Error`:**
```odin
Transfer_Alloc_Error :: enum u8 { None, Pool_Exhausted }
```

**`Transfer_Write_Error`:**
```odin
Transfer_Write_Error :: enum u8 { None, Stale_Handle, Bounds_Violation }
```

**`Transfer_Read_Error`:**
```odin
Transfer_Read_Error :: enum u8 { None, Stale_Handle }
```

### `Handoff_Mode`

```odin
Handoff_Mode :: enum u8 {
    Full       = 0,  // Transfer both directions — parent loses all FD access.
    Read_Only  = 1,  // Child gets read, parent retains write.
    Write_Only = 2,  // Child gets write, parent retains read.
}
```

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_INIT_ARGS_SIZE` | `64` | Max bytes for `init_fn` args / `Spawn_Spec.args_payload`. |
| `MAX_PAYLOAD_SIZE` | `96` | Max inline message payload bytes. |
| `MAX_ISOLATES_PER_TYPE` | `1_048_575` | 20-bit slot index limit. |
| `HANDLE_NONE` | `Handle(0)` | Sentinel for "no handle". |
| `FD_HANDLE_NONE` | `FD_Handle(0)` | Sentinel for "no FD". |
| `SUPERVISION_GROUP_ID_NONE` | `0xFFFF` | Sentinel for "no group". |
| `SUPERVISION_GROUP_ID_ROOT` | `0` | Root group ID. |

### Function Type Signatures

```odin
Init_Fn    :: #type proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect
Handler_Fn :: #type proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect
```

### Boot

| Call | Signature | Description |
|------|-----------|-------------|
| `tina_start` | `tina_start(spec: ^SystemSpec)` | Validate spec, allocate all memory, build supervision trees, pin Shard threads to cores, and enter the run loop. Does not return under normal operation. |

---

## Quick Reference Dictionary

### `Send_Result`

| Value | Meaning |
|-------|---------|
| `.ok` | Message enqueued in the target's mailbox. |
| `.mailbox_full` | Target mailbox or cross-shard channel is at capacity. Message not sent. |
| `.pool_exhausted` | Shard message pool has no free slots. Message not sent. |
| `.stale_handle` | Target Handle is dead — generation mismatch or quarantined Shard. |

### `Spawn_Error`

| Value | Meaning |
|-------|---------|
| `.arena_full` | Typed arena for this Isolate type has no free slots. Increase `slot_count`. |
| `.group_full` | Supervision group reached `child_count_dynamic_max`. |
| `.type_not_allocated` | `type_id` references a type with no allocated slots on this Shard. |
| `.init_failed` | The spawned Isolate's `init_fn` returned `Effect_Crash`. |

### `Restart_Type`

| Value | Meaning |
|-------|---------|
| `.permanent` | Always restarted, regardless of exit reason. |
| `.transient` | Restarted only on crash. Clean exit (`Effect_Done`) is not restarted. |
| `.temporary` | Never restarted. One-shot tasks, connection handlers. |

### `Handoff_Mode`

| Value | Meaning |
|-------|---------|
| `.Full` | Transfer both read and write — parent loses all FD access. |
| `.Read_Only` | Child gets read access, parent retains write. |
| `.Write_Only` | Child gets write access, parent retains read. |

### `Crash_Reason`

| Value | Meaning |
|-------|---------|
| `.None` | Generic or user-triggered crash. |
| `.Spawn_Failed` | A spawned child's `init_fn` failed. |
| `.Unimplemented_Effect` | Handler returned an unhandled Effect variant. |
| `.Init_Failed` | This Isolate's own initialization failed. |

### `Backend_Error`

| Value | Meaning |
|-------|---------|
| `.None` | Success. |
| `.Queue_Full` | I/O submission queue is full. |
| `.System_Error` | OS-level error (errno). |
| `.Not_Found` | FD or resource not found in the FD table. |
| `.Too_Late` | Operation cancelled or expired. |
| `.Unsupported` | Operation not supported on this platform. |

### `Reactor_Socket_Error`

| Value | Meaning |
|-------|---------|
| `.None` | Success. |
| `.Backend_Error` | OS-level socket creation failed. |
| `.FD_Table_Full` | Shard's FD table has no free slots. Increase `fd_table_slot_count`. |
