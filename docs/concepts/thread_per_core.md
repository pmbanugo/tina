# Thread-Per-Core Architecture

**Each Shard is one OS thread pinned to one CPU core, owning all its memory, scheduler, and I/O reactor. Shards share nothing — cross-core communication flows through dedicated lock-free messaging channels, one per Shard pair.**

> In [this talk by the engineering team at WhatsApp (Meta)](https://youtu.be/tC435RGwRCI?si=gAuSiHux4xTn2SgX), they detail how the Erlang VM suffered from severe lock contention and scheduler bottlenecks when scaling to many-core machines (100+ cores). Tina's shared-nothing, thread-per-core architecture is designed specifically to eliminate this class of contention.

Modern CPUs are not faster. They are wider. A single core has not meaningfully improved in clock speed since ~2005, but a commodity server now has 16–128 cores. The question is no longer "how fast is your thread?" but "how well do your threads avoid stepping on each other?"

The conventional answer — a shared-memory thread pool with locks — pays a tax on every memory access: cache-coherency traffic, lock acquisition, and the invisible serialization of cache lines bouncing between cores via the MESI protocol. Tina takes a different path.

## One Thread, One Core, One World

Tina runs **one OS thread per CPU core**, pinned permanently via `sched_setaffinity` (Linux) or thread affinity APIs on other platforms. Each thread is called a **Shard**.

A Shard is not just a thread. It is a self-contained runtime:

```
┌──────────────────────────────────────────────────┐
│                  SHARD (Core N)                  │
│                                                  │
│  Typed Arenas (per Isolate type)                 │
│  Isolate Metadata (state, generation, mailbox)   │
│  Scheduler (budget-batched by type)              │
│  Message Pool (128-byte envelopes)               │
│  I/O Reactor (io_uring / kqueue / IOCP)          │
│  Timer Wheel (hashed, array-backed)              │
│  Supervision Groups                              │
│  Scratch Arena (handler-transient)               │
│  Transfer Buffer Pool                            │
│  Log Buffer                                      │
└──────────────────────────────────────────────────┘
```

Shards share no memory. No Shard reads or writes another Shard's arenas, pools, metadata, or reactor state. The only connection between Shards is a set of lock-free cross-shard messaging channels — and even those are carefully partitioned so each side touches only its own cache lines.

This is the Seastar/ScyllaDB model, adapted for a cooperative actor framework.

## Why No Work-Stealing

Work-stealing schedulers (Go, Tokio, .NET ThreadPool, Erlang VM) allow idle threads to take tasks from busy threads. Work-stealing optimizes for CPU utilization at the expense of memory locality and determinism, and it has a structural cost.

When a task migrates from core A to core B:

1. **Every cache line of that task's working data** must be fetched from core A's L1/L2 caches (or from DRAM). On modern hardware, an L1 hit is ~1ns; a cross-core fetch is ~20–40ns; a DRAM miss is ~60–80ns.
2. **The task's memory allocations** may now be on the wrong NUMA node, adding ~2× latency on every subsequent cache miss.
3. **Determinism is lost.** The execution order becomes a function of OS scheduling jitter, cache timing, and interrupt distribution — impossible to reproduce in testing.

Tina makes a different choice: **an Isolate belongs to exactly one Shard for its entire lifetime.** No migration. Ever.

This preserves three properties that work-stealing sacrifices:

- **Shared-nothing invariant.** If an Isolate can move, its memory must be accessible from any core. That reintroduces shared state. By pinning Isolates, their memory lives entirely within one Shard's Grand Arena — no cross-core access, no coherency traffic.
- **Cache locality.** An Isolate's struct, its mailbox metadata, and its working memory all reside in cache lines that are warm on the owning core. They stay warm because nothing evicts them across cores.
- **Determinism.** The scheduler's dispatch order is a function of the Shard's local state — its inbound messages, I/O completions, and timer expirations. In simulation mode, the same seed reproduces the same execution, every time.

Tina does not abandon load balancing; it moves it to **placement time**. When an Isolate is spawned, the caller decides which Shard it belongs to. Tina provides `key_to_shard(key, shard_count)` utility function for consistent key-based partitioning (e.g. `session_id % shard_count`). The topology is planned upfront in the boot spec, not discovered at runtime.

## Cross-Shard Messaging

When an Isolate on Shard A needs to send a message to an Isolate on Shard B, the message is copied into a **cross-shard messaging channel** — a lock-free ring buffer with one writer (Shard A) and one reader (Shard B).

The communication topology is a directed graph of point-to-point channels:

```
Shard 0 ──channel──▶ Shard 1
Shard 0 ──channel──▶ Shard 2
Shard 1 ──channel──▶ Shard 0
Shard 1 ──channel──▶ Shard 2
Shard 2 ──channel──▶ Shard 0
Shard 2 ──channel──▶ Shard 1
```

For N Shards, there are N×(N-1) channels. For 16 cores, that is 240 channels.

Why one channel per Shard-pair instead of one shared inbound queue per Shard? A shared queue would mean multiple Shards writing to the same data structure, requiring atomic compare-and-swap on every enqueue. Under high cross-shard traffic, the CAS retry loop becomes the bottleneck.

With dedicated channels, the writer needs **no atomics on the hot path**. It writes to its local write cursor, copies the envelope into the channel slot, and advances the cursor. The only atomic operation is the store-release that publishes the batch to the consumer — and that happens once per scheduler tick, not once per message. The consumer side is symmetric: one atomic load-acquire per tick to check for new messages.

The memory cost of N×(N-1) channels is modest. Each channel is a contiguous array of 128-byte message envelopes, sized per Shard-pair in the boot spec (configurable via the Painter's Algorithm for ring topology). A default channel of 64 slots is 8KB. For 16 Shards at 240 channels, that is ~1.9MB total — well within the memory budget of a modern server.

## The Scheduler Loop

Each Shard runs a tight loop that processes work in a fixed, deterministic order:

```
loop {
    1. Drain inbound cross-shard channels → deliver to local mailboxes
    2. Collect I/O completions (non-blocking) → deliver via Isolate metadata
    3. For each Isolate type (budget-limited):
         Dispatch Isolates with pending work
         Call handler(isolate, message, ctx) → Effect
         Interpret the Effect
    4. Flush accumulated I/O submissions (one syscall per tick)
    5. Flush outbound cross-shard channels (one atomic store per channel)
    6. Advance timer wheel
    7. Flush log buffer
}
```

The order matters:

- **Inbound first** (step 1): Messages from other Shards are delivered before local handlers run, so handlers see fresh cross-shard data.
- **I/O second** (step 2): Completed I/O operations are available before dispatch.
- **Outbound after dispatch** (step 5): All messages generated during step 3 are batched and published in one atomic store per ring. This is the LMAX Disruptor's batching effect — lagging consumers catch up in bursts, amortizing the cost of atomic operations.
- **Log last** (step 7): String formatting pollutes the L1 instruction cache. Deferring it until after all handler execution keeps the cache hot during the performance-critical dispatch phase.

## Budgeted Batching by Type

In step 3, the scheduler does not round-robin individual Isolates. It processes Isolates **grouped by type** — all pending Session Isolates, then all pending Timer Isolates, and so on.

Why? When the scheduler calls the same handler function for 50 Session Isolates in a row, the handler's machine code stays hot in the L1 instruction cache. The Session Isolate struct has a uniform stride, so the hardware prefetcher (which handles strides up to 2KB) accurately predicts the next memory access.

If the scheduler interleaved types — Session, Timer, Session, Listener, Session — the instruction cache would thrash between handler functions, and the data prefetcher would see irregular strides.

The risk of pure type-batching is **starvation**: 10,000 pending Timer Isolates could starve a handful of urgent Session Isolates. Tina solves this with a **budget** per type. Each type has a configurable `budget_weight` (default: 1). The scheduler dispatches at most `budget_weight × 256` Isolates of that type per tick. When the budget is exhausted, the scheduler saves a cursor and moves to the next type, resuming from the saved position on the next tick.

This preserves ~90% of the cache benefit of pure batching while bounding worst-case dispatch latency.

## Tradeoffs Accepted

**No work-stealing means potential load imbalance.** If Shard 3 has 10× more active Isolates than Shard 7, Shard 7 will idle while Shard 3 is saturated. This is solved by thoughtful placement at spawn time — partition your workload by key, spread your Isolate types across Shards in the boot spec, and monitor per-Shard utilization. The load distribution is a deployment decision, not a runtime guess.

**No Isolate migration means you must plan your topology upfront.** You cannot rebalance a running system by moving Isolates between Shards. If your traffic pattern changes dramatically, you redeploy with a new boot spec. This is the Seastar philosophy: the operator knows the workload shape better than a runtime heuristic.

**Cross-shard channels mean N×(N-1) channels for N Shards.** For 16 cores, that is 240 channels. For 64 cores, that is 4,032 channels. At 8KB each, 64 cores costs ~31MB of channel memory — a rounding error on a server with 256GB of RAM. The payoff is zero contention on the messaging hot path: no CAS loops, no lock queues, no cache-line bouncing between cores.
