# Backpressure & Load-Shedding

**Every resource in Tina — mailboxes, message pools, cross-shard channels — is strictly bounded and pre-allocated at boot time. When capacity is exceeded, excess is shed immediately: the sender learns at the point of sending, not minutes later when a downstream timeout fires.**

> "Queues don't fix overload. They're only useful when the rate of work production is occasionally and temporarily higher than the rate of work completion."
> — Fred Hebert, *Handling Overload*

This is the central insight behind Tina's approach to resource exhaustion. An unbounded queue hides overload by absorbing excess work — until the process runs out of memory and crashes. A bounded queue with silent buffering delays the failure signal — the system appears healthy while latency climbs, timeouts cascade, and users see degraded service that nobody can diagnose.

Tina takes a different position: **when capacity is exceeded, excess is shed immediately.** The sender learns about the failure at the point of sending, not minutes later when a downstream timeout fires. Recovery is the job of the control plane — supervisors, timeouts, application-level retries — not of growing buffers.

## Three Bounded Resources

Backpressure in Tina emerges from three bounded resources, each with a hard capacity limit set at startup and enforced at runtime:

### 1. Per-Isolate Mailbox

Every Isolate has a mailbox — a FIFO queue of pending messages. The mailbox capacity is set per Isolate type via `mailbox_capacity` in the `TypeDescriptor` (default: 256 messages).

When a sender targets a full mailbox, the scheduler rejects the delivery and drops the message. The message pool slot is not allocated. The sender receives `.mailbox_full` as the return value.

### 2. Per-Shard Message Pool

All message envelopes on a Shard are allocated from a single, pre-allocated pool of fixed-size 128-byte slots. The pool uses an intrusive LIFO free list — O(1) alloc, O(1) free, zero fragmentation.

The pool is partitioned into two regions: a **user region** and a **system region**. The system region is reserved for control-plane messages — timer expirations, supervision signals, shutdown notifications. A high-water mark ensures the system region is never exhausted by user traffic. When the user region is empty, user message sends return `.pool_exhausted`. The system region continues to function.

This separation is critical: the control plane must always be able to communicate, even when the data plane is saturated. A supervision restart message must never be dropped because user messages consumed all the pool capacity.

### 3. Cross-Shard Messaging Channel

Cross-shard messages travel through dedicated messaging channels (one per Shard-pair, implemented as lock-free ring buffers). Each channel has a fixed capacity configured in the boot spec. When a channel is full, the message is dropped. The sender's Shard increments a `ring_full_drops` counter.

There is no secondary buffer. If the outbound channel to Shard 3 is full, the message does not go into a local overflow queue to be retried later. This is a deliberate isolation boundary: Shard A must not spend its own memory to compensate for Shard B's inability to drain its inbound channel. An overflow buffer would let a slow consumer on Shard B cause memory growth on Shard A — violating the shared-nothing invariant.

## The Backpressure Path

Here is what happens when an Isolate handler calls `ctx_send()`:

```
ctx_send(ctx, target_handle, tag, payload)
    │
    ├── Is target on this Shard?
    │   ├── Yes: local delivery
    │   │   ├── Is target Handle still valid (generation check)?
    │   │   │   └── No → return .stale_handle
    │   │   ├── Is target mailbox full?
    │   │   │   └── Yes → return .mailbox_full
    │   │   ├── Is message pool (user region) empty?
    │   │   │   └── Yes → return .pool_exhausted
    │   │   └── Allocate pool slot, copy envelope, link to mailbox
    │   │       → return .ok
    │   │
    │   └── No: cross-shard delivery
    │       ├── Is target Shard quarantined (peer alive mask)?
    │       │   └── Yes → return .stale_handle
    │       ├── Is outbound channel full?
    │       │   └── Yes → return .mailbox_full
    │       └── Copy envelope into channel slot
    │           → return .ok
```

Every path returns a `Send_Result`:

```odin
Send_Result :: enum u8 {
    ok,
    mailbox_full,
    pool_exhausted,
    stale_handle,
}
```

The sender decides what to do with the result. This is policy, not mechanism:

- **Fire-and-forget:** `_ = ctx_send(...)` — explicitly discard the result. The underscore is intentional: it documents that the developer chose to ignore backpressure, not that they forgot to check.
- **Crash on failure:** `if result != .ok do return Effect_Crash{}` — the Isolate declares itself unable to continue without successful delivery.
- **Retry on next tick:** Store the message in the Isolate's state and return `Effect_Yield{}` to try again on the next scheduler tick.
- **Shed the work:** Drop the request and move on to the next item.

## Two Delivery Guarantees

Tina offers two message-sending mechanisms, each with different guarantees:

**`ctx_send()` is UDP-like.** Best-effort delivery with immediate feedback. The message is either delivered to the target's mailbox (`.ok`) or it is not (`.mailbox_full`, `.pool_exhausted`, `.stale_handle`). There is no retry, no acknowledgment, no timeout. The sender knows the outcome immediately.

**`Effect_Call` is RPC-like.** The sender parks itself and waits for a reply from the target, with a mandatory timeout. If the reply arrives, the sender wakes with the response. If the timeout expires, the sender wakes with a `TAG_CALL_TIMEOUT` message. This provides bounded-time request-response semantics — the sender never waits forever.

```odin
// Fire-and-forget: sender does not wait
_ = ctx_send(ctx, target, MY_TAG, payload)
return Effect_Receive{}

// Request-response: sender parks until reply or timeout
return Effect_Call{
    to      = target,
    message = request_message,
    timeout = 5000,  // ticks
}
```

The `.call` timeout is the reliability mechanism. If you need guaranteed delivery — if the message *must* arrive — use `.call` with a timeout and handle the timeout case, or build application-level acknowledgment on top of `ctx_send()`.

## Control Plane / Data Plane Separation

The design ensures that system-critical operations continue to function when user traffic saturates the data plane:

**Timer expirations bypass the message pool's user region.** They are delivered via the system region of the pool, which is protected by the high-water mark. A flood of user messages cannot prevent timers from firing.

**Supervision is zero-allocation.** When an Isolate crashes, the supervisor's restart logic executes as direct function calls within the scheduler — not as messages routed through the message pool. A supervision restart does not need to allocate a pool slot, enqueue a message, or compete with user traffic for mailbox capacity.

**I/O completions bypass the message pool entirely.** When an I/O operation completes, the result is written directly into the Isolate's Isolate metadata fields (`io_completion_tag`, `io_result`, `io_fd`, `io_buffer_index`). The scheduler checks these fields during dispatch. No message envelope is allocated. No mailbox slot is consumed. This means I/O-heavy workloads do not compete with messaging workloads for pool capacity.

The result: even when every user message pool slot is allocated, every mailbox is full, and every cross-shard ring is saturated, the system can still:
- Fire timers
- Restart crashed Isolates
- Deliver I/O completions
- Process shutdown signals

## No Cross-Shard Retry Buffering

If Shard A tries to send a message to Shard B and the cross-shard channel A→B is full, the message is dropped. Shard A does not store the message in a local retry buffer to try again later.

This is a strict isolation boundary. Consider the alternative: if Shard A buffers messages destined for a slow Shard B, then Shard B's backpressure problem becomes Shard A's memory problem. A cascade of slow consumers can exhaust memory on every producing Shard — the classic unbounded-queue failure mode, just moved one level up.

By dropping immediately, the failure stays local to the interaction. Shard A's own Isolates, pools, and arenas are unaffected. The sender's handler receives `.mailbox_full` and can take corrective action (shed load, notify upstream, crash and restart).

## Tradeoffs Accepted

**Messages can be dropped under load.** This is by design, not a bug. Tina's mailboxes are bounded, its pools are bounded, and its rings are bounded. When any of these resources are exhausted, excess is shed. If your application requires guaranteed delivery, build it at the application layer — acknowledgments, sequence numbers, retransmission protocols — the same way TCP is built on top of IP.

**No unbounded mailbox mode.** Every mailbox has a hard cap (`mailbox_capacity`, default 256). There is no `mailbox_capacity = infinity` option. If an Isolate cannot process messages as fast as they arrive, the system tells the senders immediately rather than accumulating a latency debt that compounds until the process dies.

**Cross-shard messages are dropped on channel full, not buffered.** The sender learns via `Send_Result`. No secondary buffer absorbs the overflow. This preserves the shared-nothing isolation boundary: a slow consumer on one Shard cannot cause memory growth on another.

**The `.call` timeout is the reliability mechanism for request-response.** If you need guaranteed delivery, use `Effect_Call` with a timeout and handle the timeout case. Alternatively, build application-level acknowledgments over `ctx_send()`. Tina provides the building blocks — bounded channels with immediate feedback — not a turnkey reliable delivery protocol.
