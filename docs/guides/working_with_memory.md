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
| Am I sending outbound data that isn't in my struct? | **Staging slot** (`ctx_claim_send_slot()`) |
| Am I sending a large payload to another Isolate? | **Transfer buffer** (`ctx_transfer_alloc()`) |

---

## Scratch Arena: Temporary Data

The scratch arena is for data that does not outlive the current handler call. The scheduler resets it before every handler invocation — you get a clean slate each time.

### String formatting for logging

The most common pattern. Use `tina.ctx_scratch_arena_bytes()` as the destination buffer for `fmt.bprintf`:

```odin
handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
    self := tina.self_as(MyIsolate, self_raw)

    // Format a log string into the scratch arena's backing buffer.
    // This buffer is valid until this handler returns.
    str := fmt.bprintf(tina.ctx_scratch_arena_bytes(), "Processed request %d on Shard %d",
        self.request_count, tina.ctx_shard_id())
    tina.ctx_log(.INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

    return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}
```

### Allocating temporary buffers

You can get a standard `mem.Allocator` from the scratch arena for general-purpose temporary allocations:

```odin
    // Get a standard Allocator backed by the scratch arena.
    scratch := tina.ctx_scratch_arena()

    // Allocate a temporary buffer for parsing.
    temp_buffer := make([]u8, 256, scratch)
    // ... use temp_buffer for parsing, intermediate computation, etc. ...

    // No need to free. When this handler returns, the scheduler
    // resets the scratch arena. temp_buffer becomes invalid.
```

### The rule

Pointers to the scratch arena are strictly scoped to the current handler invocation. Storing a scratch pointer in your Isolate struct guarantees a dangling pointer on the next tick — the scheduler resets the scratch arena before every handler call and overwrites that memory. If you need data to survive, copy it into the struct or the working memory arena.

---

## Working Arena: Persistent Isolate State

The working arena is for data that persists across handler calls but dies when the Isolate is torn down. Use it when your Isolate needs dynamic-size storage that does not fit in the struct itself.

### Allocating a lookup table on init

```odin
RouterIsolate :: struct {
    subscribers:      ^SubscriberTable,   // pointer to working arena allocation
    subscriber_count: u32,
}

router_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
    self := tina.self_as(RouterIsolate, self_raw)

    // Get an Allocator backed by this Isolate's private working memory region.
    working := tina.ctx_working_arena()

    // Allocate a subscriber table. This memory survives across handler calls —
    // it persists until the Isolate is torn down (crash, ISOLATE_TRANSITION_DONE, or shutdown).
    self.subscribers = new(SubscriberTable, working)

    return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

router_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
) -> tina.Isolate_Transition {
    self := tina.self_as(RouterIsolate, self_raw)

    // self.subscribers is still valid — working arena persists across handler calls.
    switch message.tag {
    case TAG_SUBSCRIBE:
        sub := tina.payload_as(SubMsg, message.user.payload[:])
        // ... add to self.subscribers ...
        return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
    case:
        return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
    }
}
```

### Sizing

Set the working arena size per Isolate type via `working_memory_size` on the `IsolateTypeDescriptor`. If the arena fills up, allocations fail (return `nil`). This is a deployment sizing issue — increase `working_memory_size` and rebuild.

If `working_memory_size = 0` (the default), `ctx_working_arena()` returns a zero-size allocator — any allocation attempt fails immediately. This is correct for simple reactive Isolates that only hold struct fields.

### Resetting

To reclaim all working arena memory without tearing down the Isolate, call `ctx_working_arena_reset()`. All prior allocations from the working arena become invalid. Use this when your Isolate goes through phases that don't share state — e.g., resetting between protocol sessions.

---

## Transfer Buffers: Large Payloads

Message envelopes carry up to 96 bytes of inline payload. When you need to send more than 96 bytes to another Isolate on the same Shard, use the transfer buffer pool.

For the full lifecycle and I/O buffer details, see [I/O, Buffers & Data Transfer](../concepts/io_and_data_flow.md).

### Sending a large payload

```odin
// 1. Allocate a transfer buffer slot.
handle_result := tina.ctx_transfer_alloc()
handle, ok := handle_result.(tina.Transfer_Handle)
if !ok {
    // Pool exhausted — shed load or retry later.
    return tina.ISOLATE_TRANSITION_YIELD
}

// 2. Write the large payload into the transfer slot.
tina.ctx_transfer_write(handle, &my_large_struct)

// 3. Send a small reference message to the receiver.
_ = tina.ctx_transfer_send(target, handle)
```

### Receiving a large payload

```odin
case tina.TAG_TRANSFER:
    handle := (cast(^tina.Transfer_Handle)&message.user.payload[0])^

    // Read the large payload. This slice is valid ONLY during this handler call.
    read_result := tina.ctx_transfer_read(handle)
    data, ok := read_result.([]u8)
    if !ok {
        // Stale handle — the slot was already freed.
        return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
    }

    // Copy what you need into your own memory.
    mem.copy(&self.staging[0], raw_data(data), len(data))

    // After this handler returns, the transfer slot is auto-freed.
    return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
```

### The rule

**Framework-provided data is available during this handler call only. Copy what you need.** This applies to both transfer buffers (`ctx_transfer_read()`) and I/O buffers (`ctx_read_io_slot()`). The scheduler frees the slot when the handler returns — no manual cleanup, no leak risk.

---

## Staging Slots: Dynamic Outbound I/O

`ctx_io_send()` reads directly from your Isolate struct — zero-copy, zero allocation. But it requires the payload to be a slice of the struct itself. When you need to send data that's larger than 4KB (typically), use the **I/O staging pool**. But you can use I/O staging for any I/O send/write if they perform better than reading from struct fields.

```odin
// Claim a staging slot — returns a writable slice or nil on exhaustion.
data := tina.ctx_claim_send_slot()
if data == nil {
    // Pool exhausted. Shed load or retry next tick.
    return tina.ISOLATE_TRANSITION_YIELD
}

// Write the dynamic payload into the slot.
n := serialize_my_response(data[:])

// Commit as a send. The reactor reads directly from the staging slot.
return tina.transition_to_wait_io_or_crash(tina.ctx_io_send_staged(self.fd, u32(n)))
```

**Key properties:**
- **One slot per handler turn.** `ctx_claim_send_slot()` returns `nil` if already claimed. Claim early.
- **Auto-freed.** If committed, freed when the Isolate parks on I/O. If claimed but never committed, the scheduler reclaims it on handler return.
- **Configured system-wide.** `staging_slot_count` and `staging_slot_size` on `SystemSpec` control the pool size. See [Tuning the Boot Spec](tuning_the_boot_spec.md).

---

## Summary

| API | Lifetime | Freed by | Use for |
|---|---|---|---|
| Struct fields | Isolate lifetime | Isolate teardown | Fixed-size state: handles, counters, enums, small buffers |
| `ctx_working_arena()` | Isolate lifetime | Isolate teardown (or explicit reset) | Dynamic-size state: lookup tables, accumulated data, variable collections |
| `ctx_scratch_arena()` | Single handler call | Scheduler (automatic reset) | Temporaries: string formatting, parsing, intermediate computation |
| `ctx_claim_send_slot()` | Single handler call | Scheduler (auto-free) | Dynamic outbound I/O payloads (send/write) |
| `ctx_transfer_alloc()` | Until receiver's handler returns | Scheduler (auto-free) | Large payloads (>96 bytes) between Isolates on the same Shard |
| `ctx_read_io_slot()` | Single handler call | Scheduler (auto-free) | I/O completion data from the reactor |
