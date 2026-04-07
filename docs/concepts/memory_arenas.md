# Memory Arenas & The Grand Arena

**At boot, each Shard allocates one contiguous block of memory from the OS. Every Isolate, message envelope, I/O buffer, and timer entry is carved from this block — after initialization, `malloc` is never called.**

To understand Tina's memory model, you need to understand why modern CPUs care about memory layout — and why `malloc` is the wrong tool for high-throughput systems work.

## Why Layout Matters: A Hardware Primer

A modern CPU does not fetch one byte at a time. It fetches **cache lines** — 64 bytes on x86, 128 bytes on Apple Silicon performance cores. When you access a single field of a struct, the entire cache line containing that field is pulled into L1 cache. If the next thing you access is nearby, it is already there. If it is across the heap in a `malloc`-ed block, you pay 60–80ns for a DRAM round-trip.

Three hardware mechanisms reward contiguous, uniform-stride memory:

1. **The L1 stride prefetcher** detects sequential access patterns with uniform strides (up to 2KB on Intel, similar on AMD and ARM). If you iterate an array of 256-byte structs, the prefetcher sees the stride and speculatively fetches the next struct before you ask for it — hiding the latency entirely.

2. **The L2 spatial prefetcher** (Intel Sandy Bridge and later) fetches 128-byte aligned pairs of cache lines. When you touch one cache line at address 0x1000, it speculatively fetches its partner at 0x1040 to complete the 128-byte pair. If your data structure is 128-byte aligned, this always fetches useful data. If your data is scattered across the heap, the partner line belongs to an unrelated allocation — wasted bandwidth.

3. **TLB coverage.** Virtual-to-physical address translation uses a Translation Lookaside Buffer with limited entries. A contiguous allocation needs fewer TLB entries than scattered `malloc` blocks. Huge pages (2MB or 1GB) further reduce TLB pressure, but only work well with large contiguous reservations.

These mechanisms are not optional optimizations. On a cache miss, your CPU stalls for 60–80ns — enough time to execute ~200 instructions. Memory layout is performance.

## The Grand Arena

At boot, each Shard requests **one contiguous block of memory** from the OS via `mmap` (Linux/macOS) or `VirtualAlloc` (Windows). This block is the **Grand Arena**. Every data structure the Shard will ever need — every Isolate, every message envelope, every I/O buffer, every timer entry — is carved from this single block during initialization.

After boot, Tina never calls `malloc` or do any dynamic allocation.

```
┌────────────────────────────────────────────────────────────────────┐
│                    SHARD GRAND ARENA (Core N)                      │
│                                                                    │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────────────────────┐ │
│  │ Typed Arena   │ │ Typed Arena   │ │ Typed Arena                │ │
│  │ SessionIso   │ │ TimerIso     │ │ ListenerIso                │ │
│  └──────────────┘ └──────────────┘ └────────────────────────────┘ │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────────────────────┐ │
│  │ Isolate Metadata  │ │ Working      │ │ Message Pool               │ │
│  │ (all types)   │ │ Memory       │ │ (128-byte envelopes)       │ │
│  └──────────────┘ └──────────────┘ └────────────────────────────┘ │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────────────────────┐ │
│  │ Reactor Bufs  │ │ Transfer Pool│ │ Timer Wheel                │ │
│  └──────────────┘ └──────────────┘ └────────────────────────────┘ │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────────────────────┐ │
│  │ FD Table      │ │ Log Ring     │ │ Scratch Arena              │ │
│  └──────────────┘ └──────────────┘ └────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

The Grand Arena is a bump allocator: a base pointer and an offset. Each sub-allocation advances the offset. All sub-allocations are cache-line aligned (128-byte boundary) to prevent false sharing and ensure clean prefetcher behavior. After initialization completes, the offset is frozen. The allocator is effectively read-only for the rest of the process's life.

## Three Memory Generations

Every byte of memory in a Shard belongs to one of three lifetime generations. This model synthesizes Ginger Bill's lifetime matrix (size vs. lifetime classification) with Ryan Fleury's three-lifetime arena model.

```
┌────────────────────────────────────────────────────────────────────┐
│ GENERATION 1: SHARD-PERMANENT                                      │
│ Born: Shard init                    Dies: Process exit             │
│                                                                    │
│ Typed arenas, Isolate metadata, message pool, reactor buffer pool,     │
│ transfer pool, timer wheel, FD table, log ring, supervision        │
│ groups, working memory regions, scratch arena backing store.       │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ GENERATION 2: ISOLATE-LIFETIME                                │  │
│  │ Born: Isolate spawn              Dies: Isolate teardown       │  │
│  │                                                                │  │
│  │ Connection buffers, protocol state, accumulated data,          │  │
│  │ hash tables, any Isolate-private dynamic state.                │  │
│  │                                                                │  │
│  │  ┌────────────────────────────────────────────────────────┐   │  │
│  │  │ GENERATION 3: HANDLER-TRANSIENT                         │   │  │
│  │  │ Born: Handler entry          Dies: Handler return       │   │  │
│  │  │                                                          │   │  │
│  │  │ Parse buffers, string formatting, intermediate           │   │  │
│  │  │ computations, temporary copies from I/O buffers.         │   │  │
│  │  └────────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**Generation 1 (Shard-Permanent)** is carved from the Grand Arena at init. It lives until the process exits. This is the arena allocator in its purest form — bump a pointer, never free. The backing memory for every pool, every metadata array, and every buffer comes from this generation.

**Generation 2 (Isolate-Lifetime)** provides each Isolate with a private sub-arena for data that outlives a single handler call but dies with the Isolate. When an Isolate is spawned, the scheduler assigns it a slice of the pre-allocated working memory region for its type. When the Isolate is torn down, the slice is reclaimed (the offset resets). The user accesses it via `ctx_working_arena()`.

**Generation 3 (Handler-Transient)** is a single scratch arena shared across all Isolates on the Shard. Before each handler invocation, the scheduler resets the scratch arena offset to zero — two integer assignments. All scratch allocations from the previous handler are instantly invalidated. The user accesses it via `ctx_scratch_arena()`.

Why only one scratch arena per Shard instead of one per Isolate? With 10,000 Isolates and a 4KB scratch arena each, you waste 40MB of cold memory. A single Shard-wide scratch arena of 64KB (configurable) stays hot in L1/L2 cache and is reused by every handler. Only one handler runs at a time per Shard — cooperative scheduling means no contention.

## Typed Arenas: Prefetcher-Friendly Uniform Stride

Each Isolate type gets its own dense array within the Grand Arena. Different types live in separate arenas:

```
Arena[Session]  → [S₀][S₁][S₂][S₃][S₄]...   stride = sizeof(Session)
Arena[Timer]    → [T₀][T₁][T₂]...             stride = sizeof(Timer)
Arena[Listener] → [L₀][L₁]...                 stride = sizeof(Listener)
```

This layout has four properties the hardware rewards:

- **Uniform stride.** The L1 stride prefetcher sees a constant offset between elements. It prefetches ahead automatically.
- **No wasted bytes.** Each type uses exactly the memory it needs. A 128-byte Session Isolate does not share an arena with a 4KB Protocol Isolate.
- **Type-pure iteration.** When the scheduler dispatches all Session Isolates, it touches only Session memory. Timer and Listener data stays out of the cache.
- **Instruction cache efficiency.** Processing all Session Isolates in sequence keeps the Session handler function hot in L1i. The scheduler batches by type for exactly this reason.

Isolate metadata (state, generation, mailbox head/tail, I/O completion tags) is stored in a parallel **SOA (Structure of Arrays)** layout, separate from the user-facing Isolate struct. This lets the scheduler scan metadata arrays (e.g. checking which Isolates have pending work) without pulling any user data into the cache.

## No General-Purpose Malloc

There is no `ctx_alloc(size)` that returns arbitrary memory with arbitrary lifetime. Every allocation goes through one of the three generations:

| Need | API | Lifetime |
|---|---|---|
| Memory for the life of your Isolate | `ctx_working_arena()` | Isolate spawn → teardown |
| Memory for this handler call only | `ctx_scratch_arena()` | Handler entry → return |
| Large payload transfer to another Isolate | `ctx_transfer_alloc()` / `ctx_transfer_write()` / `ctx_transfer_read()` | Sender writes → receiver's handler returns |

The absence of a general-purpose allocator is a deliberate constraint. It forces every allocation into a known lifetime scope managed by the scheduler. There are no "when do I free this?" questions, no reference counting, no garbage collection, and no use-after-free — because the scheduler owns every deallocation boundary.

If none of the three generations fit your allocation pattern, the architecture needs rethinking: decompose the Isolate, restructure the data flow, or change the protocol.

## NUMA Awareness: Pin-Then-Fault

On multi-socket servers, each CPU socket has its own local memory. Accessing memory on the remote socket (crossing the NUMA interconnect) adds ~2× latency to every cache miss.

Tina uses a **pin-then-fault** initialization sequence to ensure every Shard's Grand Arena resides on the correct NUMA node:

1. The main thread reserves virtual address space for each Shard via `mmap` (no physical pages committed yet).
2. Each Shard thread is spawned and pinned to its target core via `sched_setaffinity`.
3. The pinned Shard thread touches its own Grand Arena pages, triggering page faults. The kernel allocates physical pages on the NUMA node local to the faulting core.

This guarantees that all memory a Shard will ever access is physically local to the core running that Shard. The main thread never pre-faults pages on behalf of a Shard — that would allocate pages on the wrong NUMA node.

## Tradeoffs Accepted

**No dynamic memory growth.** All memory sizes are computed from the boot spec and allocated at startup. If a Shard exhausts its Grand Arena, its working memory, or its message pool, the framework sheds load (drops messages, rejects spawns) rather than growing. This is a deployment sizing issue, not a runtime error. Fail-fast behavior surfaces misconfigurations immediately instead of hiding them behind silent reallocation.

**Working memory must be sized in the boot spec.** Each Isolate type declares its `working_memory_size` at compile time. Under-provisioning means a handler's `ctx_working_arena()` allocation fails. Over-provisioning wastes Shard-permanent memory. The operator must understand the workload's memory footprint. This is the Seastar and TigerBeetle philosophy: size your deployment to your workload, don't let the runtime guess.

**The scratch arena is shared per-Shard, not per-Isolate.** Only one handler runs at a time on a Shard (cooperative scheduling), so there is no contention. But this means a handler that allocates heavily from scratch can consume the entire scratch arena. The boot spec requires each Isolate type to declare its `scratch_requirement_max`, and startup validation ensures the scratch arena is at least as large as the maximum requirement across all types.
