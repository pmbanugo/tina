# Tuning the Boot Spec

Every resource in Tina is pre-allocated at startup and fixed for the process lifetime. There is no runtime growth — if a resource is exhausted, the framework sheds load rather than allocating more. This means sizing matters. Under-provision and you drop messages; over-provision and you waste memory that could serve more Isolates.

This guide walks through every tuning knob, organized by subsystem.

---

## Message Pool (`pool_slot_count`)

**What it controls:** The total number of 128-byte message envelopes available per Shard. Every message sent via `ctx_send()`, every timer expiration, and every `.call` request consumes one slot. Slots are returned to the pool when the receiving handler finishes processing the message.

**How to size it:** Estimate the peak number of messages in-flight at any instant. This is roughly `sum(mailbox_capacity × typical_active_isolates_of_type)` across all types on the Shard. Size the pool comfortably larger than this sum — the framework reserves a small fraction (1% by default) for system messages (timer expirations), so user traffic cannot starve the control plane.

**What happens when it's too small:** User sends return `Send_Result.pool_exhausted`. Messages are dropped. Timer expirations still work (they use the reserved system slots).

**What happens when it's too large:** Wasted memory. Each slot is 128 bytes. A pool of 65,536 slots = 8MB per Shard.

**Rule of thumb:** Start with 4,096 for development, 16,384–65,536 for production. Must be a power of 2.

---

## Mailbox Capacity (`mailbox_capacity` on TypeDescriptor)

**What it controls:** The maximum number of messages that can be queued for any single Isolate of this type. When an Isolate's mailbox is full, further sends to it return `Send_Result.mailbox_full`.

**How to size it:** Most Isolates are reactive — they process one message and park. For these, 16–64 is plenty. Aggregator or router Isolates that receive fan-in traffic need more: 256–1,024. Timer-heavy Isolates that accumulate periodic expirations while blocked on I/O need enough headroom for the maximum expected timer backlog.

**What happens when it's too small:** Messages dropped under burst traffic. Senders see `.mailbox_full`.

**What happens when it's too large:** A single hot Isolate can consume a disproportionate share of the message pool. If one Isolate has `mailbox_capacity = 10,000` and fills up, it consumes 10,000 pool slots — potentially starving other Isolates on the same Shard.

**Rule of thumb:** 16 for simple workers and connections. 64 for dispatchers. 256+ for routers and aggregators. The relationship between `mailbox_capacity` and `pool_slot_count` matters: keep `sum(mailbox_capacity × isolate_count)` well below the pool size.

---

## Cross-Shard Channel Size (`default_ring_size`, `ring_overrides`)

**What it controls:** The capacity of each cross-shard messaging channel. One channel exists per ordered Shard pair (Shard A → Shard B). `default_ring_size` sets the baseline for all channels. `ring_overrides` lets you customize specific pairs or directions.

**How to size it:** Depends on cross-shard traffic patterns. If Shards mostly communicate with their neighbors, default is fine. If one Shard is a hot router that fans out to all others, increase its outbound channels via `ring_overrides`.

**What happens when it's too small:** Cross-shard messages dropped when the channel fills. Senders see `Send_Result.mailbox_full`.

**What happens when it's too large:** Wasted memory. Each slot is 128 bytes. A channel of 1,024 slots = 128KB per Shard-pair.

**Rule of thumb:** 32–64 for light cross-shard traffic. 256–1,024 for heavy cross-shard messaging. Must be a power of 2, minimum 16.

```odin
// Override: Shard 0 → Shard 1 gets a larger channel (heavy traffic path)
ring_overrides := [1]tina.Ring_Override{
    {type = .Pair, source = 0, destination = 1, size = 256},
}
```

---

## I/O Buffers (`reactor_buffer_slot_count`, `reactor_buffer_slot_size`)

**What it controls:** The pool of buffers used for I/O read completions. When a `recv` or `read` completes, the data lands in one of these slots. The slot is freed when the handler returns.

**How to size it:**

- `reactor_buffer_slot_count` — at least as many as the maximum number of Isolates that can be parked on I/O simultaneously. Each Isolate parked on a read-type I/O operation holds one buffer slot.
- `reactor_buffer_slot_size` — the maximum bytes you expect a single read to return. 4,096 (one OS page) is a common choice for network I/O. Larger for bulk file reads.

**What happens when it's too small:** I/O submissions fail when no buffer slots are available. The Isolate stays parked until a slot frees up (or is torn down by the supervisor).

**What happens when it's too large:** Wasted memory. `slot_count × slot_size` bytes per Shard.

**Rule of thumb:** `slot_count = max_concurrent_io_isolates`. `slot_size = 4096` for network servers, larger for bulk file I/O.

---

## Transfer Buffers (`transfer_slot_count`, `transfer_slot_size`)

**What it controls:** The pool of buffers for sending large payloads (>96 bytes) between Isolates on the same Shard. Allocated via `ctx_transfer_alloc()`, auto-freed when the receiver's handler returns.

**How to size it:**

- `transfer_slot_count` — the maximum number of concurrent large-payload transfers. Most systems have few simultaneous large transfers.
- `transfer_slot_size` — the maximum payload size. Must be large enough for your biggest transfer.

**What happens when it's too small:** `ctx_transfer_alloc()` returns `Pool_Exhausted`. The sender must shed load or retry.

**Rule of thumb:** 8–32 slots for most workloads. `slot_size = 4096` unless you regularly transfer larger payloads.

---

## Working Memory (`working_memory_size` on TypeDescriptor)

**What it controls:** Per-Isolate private arena for data that persists across handler invocations but dies with the Isolate. Accessed via `ctx_working_arena()`. Set per Isolate type.

**How to size it:** Estimate the maximum data each Isolate of this type accumulates during its lifetime. A connection handler that builds a response buffer needs 4–16KB. A router that maintains a subscription table needs more. Simple workers that only hold struct fields: set this to 0.

**What happens when it's too small:** Allocations from `ctx_working_arena()` fail (return nil).

**What happens when it's too large:** Wasted Shard-permanent memory. The Grand Arena carves working memory for every slot of this type, whether occupied or not: `working_memory_size × slot_count` bytes.

**Rule of thumb:** 0 for simple reactive Isolates. 4,096–16,384 for connection handlers with dynamic state. Size conservatively — you're reserving this for every possible Isolate of this type, not just the active ones.

---

## Scratch Arena (`scratch_arena_size`)

**What it controls:** Shard-wide temporary memory, reset before every handler invocation. Accessed via `ctx_scratch_arena()`. Used for string formatting, parsing, intermediate computations — anything that doesn't need to survive past the current handler call.

**How to size it:** Find the single most memory-hungry handler across all Isolate types on the Shard. The scratch arena must be at least that large. Each type can declare `scratch_requirement_max` on its `TypeDescriptor` — startup validation ensures the scratch arena is large enough.

**What happens when it's too small:** Scratch allocations fail (return nil). Startup validation catches this if `scratch_requirement_max` is set correctly.

**What happens when it's too large:** Minimal cost. One allocation per Shard (not per Isolate). 64KB is negligible.

**Rule of thumb:** 65,536 (64KB). Increase only if a handler does heavy string formatting or parsing.

---

## Isolate Slots (`slot_count` on TypeDescriptor)

**What it controls:** The maximum number of Isolates of this type that can exist simultaneously on one Shard. Each slot is pre-allocated in the typed arena: `slot_count × stride` bytes.

**How to size it:** For static services (listeners, dispatchers): 1–4. For dynamically spawned Isolates (connections, workers): estimate peak concurrency. A TCP server with up to 10,000 concurrent connections needs `slot_count = 10_000` for the connection type.

**What happens when it's too small:** `ctx_spawn()` returns `Spawn_Error.arena_full`. New Isolates cannot be created.

**What happens when it's too large:** Wasted arena memory. `slot_count × stride` bytes reserved even if most slots are empty.

**Rule of thumb:** Match your expected peak concurrency. Add 20% headroom for bursts.

---

## Timers (`timer_spoke_count`, `timer_entry_count`, `timer_resolution_ns`)

**What it controls:**

- `timer_spoke_count` — number of slots in the timer wheel (hash table). Must be a power of 2.
- `timer_entry_count` — maximum concurrent timer registrations.
- `timer_resolution_ns` — the tick duration. Timers fire at multiples of this resolution.

**How to size it:**

- `timer_spoke_count` — 1,024–4,096 for most workloads. Larger wheels spread timers more evenly, reducing collision chains.
- `timer_entry_count` — at least as many as the maximum concurrent timers. Each Isolate using `ctx_register_timer()` holds one entry until the timer fires.
- `timer_resolution_ns` — 1,000,000 (1ms) for network servers. 16,000,000 (16ms) for game servers (frame-aligned). 100,000 (100µs) for low-latency proxies.

**Rule of thumb:** `timer_spoke_count = 1024`, `timer_entry_count = 1024`, `timer_resolution_ns = 1_000_000`. Adjust based on timer density.

---

## Supervision (`restart_count_max`, `window_duration_ticks`)

**What it controls:** The restart budget for a supervision group. If the group exceeds `restart_count_max` restarts within `window_duration_ticks`, it escalates — the parent group handles the failure, or (for root groups) the Shard enters quarantine.

**How to size it:** Conservative for production. A web server's root group: 5 restarts in 10,000 ticks (10 seconds at 1ms resolution). A worker pool that processes unreliable data: 20 restarts in 50,000 ticks.

**What happens when it's too tight:** Transient failures (bad input, temporary network issue) escalate to Shard quarantine unnecessarily.

**What happens when it's too loose:** Genuine cascade failures keep restarting instead of escalating, burning CPU without progress.

**Rule of thumb:** `restart_count_max = 5`, `window_duration_ticks = 10_000` for production. Loosen for development and testing.

---

## Watchdog (`Watchdog_Config`)

| Field | What it controls | Rule of thumb |
|---|---|---|
| `check_interval_ms` | How often the watchdog checks Shard heartbeats. | 500ms. Lower for tighter liveness detection, higher to reduce monitoring overhead. |
| `phase_2_threshold` | Consecutive stalls before forced recovery (SIGUSR1). | 2. At 500ms intervals, this means ~1 second before forced recovery. |
| `shard_restart_max` | Max Shard-level recoveries before quarantine (or abort). | 2–3 for production. |
| `shard_restart_window_ms` | Window for counting Shard restarts. | 30,000 (30 seconds). |

---

## File Descriptors (`fd_table_slot_count`)

**What it controls:** Maximum open file descriptors per Shard. Each socket, file, or pipe consumes one slot.

**Rule of thumb:** Match your expected peak open FD count per Shard. A TCP server: `max_connections + listeners + overhead`. Use `size_of(tina.FD_Entry)` for `fd_entry_size`.

---

## Shutdown (`shutdown_timeout_ms`)

**What it controls:** Maximum time for graceful drain (Phase 2) before the process force-kills with `_exit(0)`.

**Rule of thumb:** 3,000–5,000ms for most services. Longer if connections need time to drain large responses. The kernel handles cleanup on force-kill — TCP sockets send RST, io_uring releases its state, and the OS unmaps all memory.

---

## Workload Profiles

### Low-Latency TCP Proxy

Many concurrent connections, small messages, tight latency budget.

```odin
spec := tina.SystemSpec{
    shard_count               = 4,          // one per core
    pool_slot_count           = 16384,      // lots of messages in flight
    timer_resolution_ns       = 100_000,    // 100µs — tight timer resolution
    timer_spoke_count         = 4096,
    timer_entry_count         = 4096,       // one timeout per connection
    reactor_buffer_slot_count = 2048,       // many concurrent reads
    reactor_buffer_slot_size  = 4096,
    transfer_slot_count       = 16,         // few large transfers
    transfer_slot_size        = 4096,
    scratch_arena_size        = 65536,
    default_ring_size         = 256,        // heavy cross-shard routing
    fd_table_slot_count       = 4096,       // many open sockets
    shutdown_timeout_ms       = 5_000,
    // ...
}
// Connection type: slot_count = 4096, mailbox_capacity = 16
// Listener type:   slot_count = 1,    mailbox_capacity = 16
```

### Background Worker Farm

Few connections, large payloads, crash-tolerant workers.

```odin
spec := tina.SystemSpec{
    shard_count               = 2,
    pool_slot_count           = 4096,
    timer_resolution_ns       = 1_000_000,  // 1ms — relaxed
    timer_spoke_count         = 1024,
    timer_entry_count         = 256,
    reactor_buffer_slot_count = 32,         // few concurrent I/O ops
    reactor_buffer_slot_size  = 16384,      // larger reads (bulk data)
    transfer_slot_count       = 64,         // frequent large payloads
    transfer_slot_size        = 8192,
    scratch_arena_size        = 65536,
    default_ring_size         = 32,         // light cross-shard traffic
    fd_table_slot_count       = 64,
    shutdown_timeout_ms       = 10_000,     // workers may need time to finish
    // ...
}
// Worker type:     slot_count = 100,  mailbox_capacity = 16, working_memory_size = 8192
// Dispatcher type: slot_count = 1,    mailbox_capacity = 256
```

### Simulation Testing

Intentionally small pools to stress backpressure and fault paths.

```odin
sim_config := tina.SimulationConfig{
    seed      = 0xDEADBEEF,
    ticks_max = 1_000_000,
    faults    = tina.FaultConfig{
        network_drop_rate    = tina.Ratio{1, 100},
        isolate_crash_rate   = tina.Ratio{1, 500},
        init_failure_rate    = tina.Ratio{1, 1000},
    },
    // ...
}

spec := tina.SystemSpec{
    shard_count               = 4,
    pool_slot_count           = 1024,       // small! stress pool exhaustion
    timer_spoke_count         = 256,
    timer_entry_count         = 256,
    reactor_buffer_slot_count = 16,         // small! stress buffer contention
    reactor_buffer_slot_size  = 4096,
    transfer_slot_count       = 8,          // small! stress transfer exhaustion
    transfer_slot_size        = 4096,
    scratch_arena_size        = 4096,       // small!
    default_ring_size         = 16,         // minimum — stress ring-full drops
    fd_table_slot_count       = 16,
    simulation                = &sim_config,
    // ...
}
```

**Why small pools in simulation?** Backpressure paths (pool exhaustion, mailbox full, channel full) are the least-exercised code paths under normal load. Making pools small in simulation forces these paths to activate frequently, where fault injection and structural checkers can find bugs in your handling logic.
