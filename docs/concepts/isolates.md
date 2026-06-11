# Isolates, Transitions & Messaging

**An Isolate is a unit of concurrent work that receives messages, acts on those messages, and communicates intent to the scheduler by returning an `Isolate_Transition`. Isolates share no memory. They reference each other by generational Handle and crash independently without affecting other Isolates.**

## What Is an Isolate?

An Isolate is the fundamental unit of execution, fault isolation, and identity in Tina. It is:
- A **typed struct** residing inside a Shard.
- A unit of composition. You can compose Isolates to build whatever architecture or topology you want.
- Referenced by a **generational Handle**.
- Executed via **handler functions** called by the scheduler.
- The unit of **fault containment**: if an Isolate crashes (panics or even segfaults), the Shard's trap boundary catches the fault, cleans up the Isolate, and the supervisor restarts it. Other Isolates on the same Shard never notice.

What an Isolate is NOT:
- Not a coroutine (no stack to save/restore).
- Not a Hewitt Actor (no `become` or other theoretical features).
- Not a goroutine (no shared heap, no work-stealing, no OS-managed scheduling).

The name **'Isolate'** explicitly defines its architectural guarantee — **fault and memory isolation**. "An Isolate crashed", or "An Isolate was restarted" should communicate what happened. You can't do that in most of the other models 😉.

## Defining an Isolate Type

Three artifacts per Isolate type:
1. **The struct** — the Isolate's state. Lives in a typed arena. Should be 256–512 bytes for most cases, up to 4KB for protocol-heavy Isolates.
2. **`init_handler`** — called once on spawn. Receives init args (up to 64 bytes), returns the initial `Isolate_Transition`.
3. **`handler_fn`** — called on every message/I/O completion. Returns an `Isolate_Transition` telling the scheduler what to do next.

```odin
MyWorker :: struct {
    id:     u32,
    boss:   tina.Handle,
}

worker_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
    self := tina.self_as(MyWorker, self_raw)
    // ... initialize from args ...
    return tina.ISOLATE_TRANSITION_WAIT_MESSAGE  // park, wait for messages
}

worker_handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
    self := tina.self_as(MyWorker, self_raw)
    switch message.tag {
    case MY_TAG:
        // ... handle the message ...
        return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
    case:
        return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
    }
}
```

Both functions receive `rawptr` because the scheduler operates on heterogeneous typed arenas. Use `tina.self_as(T, self_raw)` for a debug-checked cast that validates the stride at runtime.

## The Transition System

Handlers return an `Isolate_Transition` — a 2-byte value describing what the Isolate wants next, not how to schedule it. The scheduler interprets the transition. This is the core abstraction that enables deterministic simulation: in production the transition interpreter talks to io_uring/kqueue; in simulation it returns scripted completions. The Isolate code is identical.

Seven possible states:

| Transition | What it means |
|---|---|
| `ISOLATE_TRANSITION_DONE` | Deallocate me. Clean exit. |
| `transition_to_crash(reason)` | Voluntary failure — "let it crash." Supervisor decides what happens. |
| `ISOLATE_TRANSITION_YIELD` | Run me again next tick. |
| `ISOLATE_TRANSITION_WAIT_MESSAGE` | Park me until my mailbox has a message. |
| `ISOLATE_TRANSITION_WAIT_REPLY` | A call was staged via `ctx_call_*` — park until reply or timeout. |
| `ISOLATE_TRANSITION_WAIT_IO` | I/O was staged via `ctx_submit_io` — park until completion. |
| `transition_to_wait_io_or_crash(result)` | Submit staged I/O and park, or crash on contract violation. |

**Every transition is a state notification**, not an action. Actions (sending messages, spawning Isolates, logging, submitting I/O) are done via `ctx_*()` calls during the handler. The transition is returned at the end.

This split — actions via `ctx_*` calls during the handler, state transition via the return value — is what makes the API non-colored. You can send 100 messages, submit I/O, and park on completion in a single handler invocation. No async/await, no callbacks, no colored functions.

## Handles: Safe Identity Without Pointers

Isolates are never referenced by pointer. They are referenced by **Handles** — 64-bit generational indices encoded as:

```
Handle (u64):
┌──────────┬────────────┬─────────────┬──────────────┐
│ shard_id │  type_id   │ slot_index  │  generation  │
│  (8 bit) │  (8 bit)   │  (20 bit)   │   (28 bit)   │
└──────────┴────────────┴─────────────┴──────────────┘
```

The **generation** is the key to safety. When an Isolate is torn down, its arena slot's generation counter increments. Any Handle still referencing the old generation is now **stale** — sends to it return `.stale_handle` instead of delivering to whatever new Isolate now occupies that slot.

This eliminates dangling pointers, use-after-free, and the ABA problem — structurally, without reference counting, garbage collection, or borrow checking.

**HANDLE_NONE** (`0`) is the null sentinel. It always fails validation.

## Messaging

Isolates communicate by sending messages. There is no shared memory. No locks. No channels. Just: copy a payload into an envelope, put the envelope in the receiver's mailbox.

### The Message Envelope

Every message is a fixed-size **128-byte envelope**:

| Field | Size | Purpose |
|---|---|---|
| `source` | 8 bytes | Sender's Handle |
| `destination` | 8 bytes | Receiver's Handle |
| `tag` | 2 bytes | Message type discriminant |
| `flags` | 2 bytes | Internal metadata (is_reply, is_call) |
| `payload_size` | 2 bytes | Bytes of payload actually used |
| `correlation` | 4 bytes | For `.call` request-response matching |
| `_reserved` | 4 bytes | Mailbox queue linkage (scheduler-internal) |
| `payload` | 96 bytes | Inline message data |

For payloads larger than 96 bytes, use the **Transfer Buffer Pool** — allocate via `ctx_transfer_alloc()`, write via `ctx_transfer_write()`, send a small reference message, receiver reads via `ctx_transfer_read()`.

### Sending a Message

```odin
result := tina.ctx_send(target_handle, MY_TAG, &my_payload)
```

`ctx_send()` returns `Send_Result` immediately:
- `.ok` — delivered to the receiver's mailbox.
- `.mailbox_full` — receiver's mailbox is at capacity. Message not sent.
- `.pool_exhausted` — message pool has no free slots. Message not sent.
- `.stale_handle` — the target is dead or has been restarted with a new generation.

The sender decides what to do. Fire-and-forget: `_ = tina.ctx_send(...)`. This is explicit — the underscore documents the choice to ignore backpressure.

### Intra-Shard Messaging

Within a Shard, everything runs on a single OS thread. The mailbox is a simple FIFO queue — no locks, no atomics, no CAS. The scheduler enqueues and dequeues on the same thread. This is the simplest possible data structure: an intrusive linked list through the message pool's `_reserved` field.

### Cross-Shard Messaging

When an Isolate sends to an Isolate on another Shard, the message is staged for the outbound **cross-shard messaging channel** — a lock-free ring buffer with one writer (this Shard) and one reader (the destination Shard). Messages are flushed in batch at the end of each scheduler tick. The receiving Shard drains them at the start of its next tick.

There is one channel per Shard-pair. For N Shards: N×(N-1) channels. Each is sized independently in the boot spec.

### Receiving a Message

The handler receives messages one at a time:

```odin
handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
    switch message.tag {
    case MY_TAG:
        msg := tina.payload_as(MyPayload, message.user.payload[:])
        // ... handle it ...
    case tina.TAG_SHUTDOWN:
        return tina.ISOLATE_TRANSITION_DONE
    case:
        return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
    }
}
```

There is no selective receive (no Erlang-style pattern matching on the mailbox). The handler always gets the HEAD message. Switch on `message.tag`.

## Spawning Isolates

```odin
spec := tina.Spawn_Spec{
    type_id      = WORKER_TYPE,
    group_id     = tina.ctx_supervision_group_id(),
    restart_type = .permanent,
    args_payload = payload,
    args_size    = size,
}
result := tina.ctx_spawn(spec)
```

`ctx_spawn()` returns synchronously: either a `Handle` (the new Isolate's identity) or a `Spawn_Error` (arena full, group full, init failed). The child's `init_handler` runs immediately — the spawn is not deferred.

## Tradeoffs Accepted

**No selective receive.** The handler always gets the first message from its mailbox. If you need to process messages out of order, you store them in the Isolate's state and replay them later. This keeps the mailbox a simple FIFO queue — no scan, no pattern matching overhead, no complexity.

**No location transparency.** A Handle encodes the Shard ID. The sender knows (structurally) whether the target is local or remote. There is no naming service, no registry, no distributed Handle resolution. If you need a name service, build it as an Isolate.

**Fixed-size envelopes limit inline payloads to 96 bytes.** Most messages fit easily (a Handle is 8 bytes, a typical request struct is 20–60 bytes). For larger payloads, the Transfer Buffer Pool provides a reference-passing mechanism. This keeps the common path cache-optimal.

**One outstanding `.call` per Isolate.** An Isolate can have at most one pending `.call` at a time (structural consequence: the handler returns one `Isolate_Transition`). If you need scatter-gather (multiple concurrent requests), decompose into multiple cooperating Isolates — one per concurrent call. However, you can build your own request-response protocol on top of the async messaging.

**Init args are limited to 64 bytes.** Serialized into a fixed-size buffer on the `Spawn_Spec`. If you need to pass more state to a newly spawned Isolate, send a follow-up message after spawn. This keeps the spawn path allocation-free.
