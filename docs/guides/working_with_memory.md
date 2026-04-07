# Working with Memory

Tina provides three memory APIs, each with a different lifetime. This guide shows when and how to use each one.

For the conceptual background — why three generations, why no malloc, why the scheduler owns deallocation — see [Memory Arenas & The Grand Arena](../concepts/memory_arenas.md).

---

## The Decision Rule

| Question | Answer |
|---|---|
| Is it part of the Isolate's fixed state? | **The struct itself** (embedded fields) |
| Will I need this data on the next handler call? | **Working arena** (`ctx_working_arena()`) |
| Only for this handler call? | **Scratch arena** (`ctx_scratch_arena()`) |
| Am I sending a large payload to another Isolate? | **Transfer buffer** (`ctx_transfer_alloc()`) |

---

## Scratch Arena: Temporary Data

The scratch arena is for data that does not outlive the current handler call. The scheduler resets it before every handler invocation — you get a clean slate each time.

### String formatting for logging

The most common pattern. Use `ctx.scratch_arena.data` as the destination buffer for `fmt.bprintf`:

```odin
handler :: proc(self_raw: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(MyIsolate, self_raw, ctx)

    // Format a log string into the scratch arena's backing buffer.
    // This buffer is valid until this handler returns.
    str := fmt.bprintf(ctx.scratch_arena.data, "Processed request %d on Shard %d",
        self.request_count, tina.ctx_shard_id(ctx))
    tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

    return tina.Effect_Receive{}
}
```

### Allocating temporary buffers

You can get a standard `mem.Allocator` from the scratch arena for general-purpose temporary allocations:

```odin
    // Get a standard Allocator backed by the scratch arena.
    scratch := tina.ctx_scratch_arena(ctx)

    // Allocate a temporary buffer for parsing.
    temp_buffer := make([]u8, 256, scratch)
    // ... use temp_buffer for parsing, intermediate computation, etc. ...

    // No need to free. When this handler returns, the scheduler
    // resets the scratch arena. temp_buffer becomes invalid.
```

### The rule

**Do not** store a scratch allocation in the Isolate's struct. It will be a dangling reference on the next handler call. If you need data to survive, copy it into the struct or the working arena.

---

## Working Arena: Persistent Isolate State

The working arena is for data that persists across handler calls but dies when the Isolate is torn down. Use it when your Isolate needs dynamic-size storage that does not fit in the struct itself.

### Allocating a lookup table on init

```odin
RouterIsolate :: struct {
    subscribers:      ^SubscriberTable,   // pointer to working arena allocation
    subscriber_count: u32,
}

router_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(RouterIsolate, self_raw, ctx)

    // Get an Allocator backed by this Isolate's private working memory region.
    working := tina.ctx_working_arena(ctx)

    // Allocate a subscriber table. This memory survives across handler calls —
    // it persists until the Isolate is torn down (crash, Effect_Done, or shutdown).
    self.subscribers = new(SubscriberTable, working)

    return tina.Effect_Receive{}
}

router_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(RouterIsolate, self_raw, ctx)

    // self.subscribers is still valid — working arena persists across handler calls.
    switch message.tag {
    case TAG_SUBSCRIBE:
        sub := tina.payload_as(SubMsg, message.user.payload[:])
        // ... add to self.subscribers ...
        return tina.Effect_Receive{}
    case:
        return tina.Effect_Receive{}
    }
}
```

### Sizing

Set the working arena size per Isolate type via `working_memory_size` on the `TypeDescriptor`. If the arena fills up, allocations fail (return `nil`). This is a deployment sizing issue — increase `working_memory_size` and rebuild.

If `working_memory_size = 0` (the default), `ctx_working_arena()` returns a zero-size allocator — any allocation attempt fails immediately. This is correct for simple reactive Isolates that only hold struct fields.

### Resetting

To reclaim all working arena memory without tearing down the Isolate, call `ctx_working_arena_reset(ctx)`. All prior allocations from the working arena become invalid. Use this when your Isolate goes through phases that don't share state — e.g., resetting between protocol sessions.

---

## Transfer Buffers: Large Payloads

Message envelopes carry up to 96 bytes of inline payload. When you need to send more than 96 bytes to another Isolate on the same Shard, use the transfer buffer pool.

For the full lifecycle and I/O buffer details, see [I/O, Buffers & Data Transfer](../concepts/io_and_data_flow.md).

### Sending a large payload

```odin
// 1. Allocate a transfer buffer slot.
handle_result := tina.ctx_transfer_alloc(ctx)
handle, ok := handle_result.(tina.Transfer_Handle)
if !ok {
    // Pool exhausted — shed load or retry later.
    return tina.Effect_Yield{}
}

// 2. Write the large payload into the transfer slot.
tina.ctx_transfer_write(ctx, handle, &my_large_struct)

// 3. Send a small reference message to the receiver.
_ = tina.ctx_transfer_send(ctx, target, handle)
```

### Receiving a large payload

```odin
case tina.TAG_TRANSFER:
    handle := (cast(^tina.Transfer_Handle)&message.user.payload[0])^

    // Read the large payload. This slice is valid ONLY during this handler call.
    read_result := tina.ctx_transfer_read(ctx, handle)
    data, ok := read_result.([]u8)
    if !ok {
        // Stale handle — the slot was already freed.
        return tina.Effect_Receive{}
    }

    // Copy what you need into your own memory.
    mem.copy(&self.staging[0], raw_data(data), len(data))

    // After this handler returns, the transfer slot is auto-freed.
    return tina.Effect_Receive{}
```

### The rule

**Framework-provided data is available during this handler call only. Copy what you need.** This applies to both transfer buffers (`ctx_transfer_read()`) and I/O buffers (`ctx_read_buffer()`). The scheduler frees the slot when the handler returns — no manual cleanup, no leak risk.

---

## Summary

| API | Lifetime | Freed by | Use for |
|---|---|---|---|
| Struct fields | Isolate lifetime | Isolate teardown | Fixed-size state: handles, counters, enums, small buffers |
| `ctx_working_arena()` | Isolate lifetime | Isolate teardown (or explicit reset) | Dynamic-size state: lookup tables, accumulated data, variable collections |
| `ctx_scratch_arena()` | Single handler call | Scheduler (automatic reset) | Temporaries: string formatting, parsing, intermediate computation |
| `ctx_transfer_alloc()` | Until receiver's handler returns | Scheduler (auto-free) | Large payloads (>96 bytes) between Isolates on the same Shard |
| `ctx_read_buffer()` | Single handler call | Scheduler (auto-free) | I/O completion data from the reactor |
