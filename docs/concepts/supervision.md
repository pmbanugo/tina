# Supervision & Fault Tolerance

**When an Isolate crashes, the supervisor wipes its state and restarts it from a known-good initial configuration — the code is correct, only the state was corrupt. Supervision operates as direct function calls within the scheduler, consuming zero message pool capacity and functioning even when the data plane is saturated.**

Most production bugs are not logic errors caught during development. They are transient state corruption — a counter overflows, a protocol parser enters an invalid state, a race condition leaves a data structure half-updated. The traditional approach is to handle every error at the point of occurrence, wrapping each operation in defensive checks. The OTP approach, born from decades of building telephone switches that must not go down, is different.

## Let It Crash

The insight that changed how reliable systems are built: let the corrupted process crash, wipe its state, and restart it from a known-good initial state. The supervisor — not the failed process — decides the recovery strategy.

This works because most transient failures are state problems, not code problems. The code is correct; the state became invalid. Restarting from a clean initial state eliminates the invalid state. The bug may recur, but if it is truly transient (a race, a network hiccup, a cosmic ray), it won't recur immediately — and if it does, the supervisor notices the rapid restart pattern and escalates.

Tina implements this philosophy with three structural guarantees:

1. **Fault isolation.** An Isolate crash does not corrupt other Isolates or the Shard. The Shard's trap boundary catches panics AND segfaults (via `sigaltstack` + `siglongjmp`).
2. **Deterministic cleanup.** When an Isolate crashes, teardown is immediate: its mailbox is drained (messages returned to the pool), its working arena is reclaimed, pending I/O and transfer buffers are freed, and its arena slot's generation counter increments (invalidating all outstanding Handles).
3. **Automatic restart.** The supervision system restarts the Isolate from its `init_fn` with the same boot args. The restarted Isolate gets a fresh struct, a fresh Handle, and no memory of its past life.

## The Three-Level Recovery Hierarchy

```
Level 1: Isolate Recovery (Supervisor restarts the Isolate)
    │
    │  Too many restarts in the window?
    ▼
Level 2: Shard Recovery (Wipe all Isolates, rebuild from boot spec)
    │
    │  Shard itself is structurally broken?
    ▼
Level 3: Process Abort (External supervisor restarts the process)
```

**Level 1** is the normal path. An Isolate crashes, the supervisor restarts it. The Shard continues serving. Other Isolates never notice — they keep processing messages, handling I/O, firing timers.

**Level 2** happens when a supervision group exceeds its restart budget (too many crashes in the time window). The Shard quarantines: all Isolates are torn down, all memory is reset, and the supervision tree is rebuilt from the boot spec. Other Shards continue serving. On POSIX, send `SIGUSR2` to revive quarantined Shards.

**Level 3** is for unrecoverable failures: framework bugs, hardware faults, or a cascade that overwhelms Level 2. The watchdog calls `_exit(0)`. The kernel reclaims all resources — memory, file descriptors, io_uring state, threads. An external supervisor (systemd, Kubernetes) optionally restarts the process.

## Supervision Groups

Isolates are organized into **supervision groups**. Each group has:
- A **strategy** — what happens when a child crashes.
- A **restart budget** — max restarts within a time window before escalation.
- **Children** — a list of static children (spawned at boot) and dynamically spawned children.

### Strategies

| Strategy | Behavior |
|---|---|
| `One_For_One` | Only the crashed child is restarted. Siblings are unaffected. |
| `One_For_All` | All children in the group are torn down and restarted. Use when children have interdependent state. |
| `Rest_For_One` | The crashed child and all children started after it are restarted. Order matters. |

### Restart Budget

Each group has a `restart_count_max` and `window_duration_ticks`. If the group exceeds `restart_count_max` restarts within the window, it escalates — the parent group handles the failure, or (for the root group) the Shard enters Level 2 recovery.

Example: `restart_count_max = 5, window_duration_ticks = 10_000` means "if this group has more than 5 crashes in 10,000 ticks (~10 seconds at 1ms resolution), something is fundamentally wrong — escalate."

### Restart Types

| Type | Meaning |
|---|---|
| `.permanent` | Always restart, regardless of exit reason. |
| `.transient` | Restart only on crash. Clean exit (`Effect_Done`) is not restarted. |
| `.temporary` | Never restart. Used for one-shot tasks and connection handlers. |

### Defining the Supervision Tree

The supervision tree is declared in the boot spec — it's data, not code:

```odin
children := [2]tina.Child_Spec{
    tina.Static_Child_Spec{type_id = LISTENER_TYPE, restart_type = .permanent},
    tina.Static_Child_Spec{type_id = METRICS_TYPE,  restart_type = .permanent},
}

root_group := tina.Group_Spec{
    strategy              = .One_For_One,
    restart_count_max     = 5,
    window_duration_ticks = 10_000,
    children              = children[:],
    child_count_dynamic_max = 64,   // room for dynamically spawned children
}

shard_spec := tina.ShardSpec{
    shard_id   = 0,
    root_group = root_group,
}
```

Static children are spawned automatically when the Shard boots. Dynamic children are spawned at runtime via `ctx_spawn()`.

## Supervision Is Zero-Allocation

This is a critical design property: supervision operates as **direct function calls within the scheduler**, not as messages routed through the message pool.

When an Isolate crashes:
1. The scheduler calls the teardown sequence (drain mailbox, free resources, increment generation).
2. The scheduler calls the supervision group's restart logic directly.
3. The restarted Isolate's `init_fn` runs.

No message envelope is allocated. No mailbox slot is consumed. No pool capacity is needed. This means supervision works even when the message pool is completely exhausted — the control plane operates independently of the data plane.

## Shard Quarantine

When a Shard's root supervision group exceeds its restart budget, the Shard is **quarantined**:
- All Isolates are torn down.
- The Shard stops its scheduler loop.
- Other Shards detect the quarantine via the `peer_alive_mask` (a bitmask of active Shards).
- Cross-shard messages to the quarantined Shard are dropped (sender gets `.stale_handle`).

On POSIX, send `SIGUSR2` to the process to revive all quarantined Shards. They rebuild their supervision trees from the boot spec and re-enter the scheduler loop.

The watchdog monitors quarantine events. If configured with `Quarantine_Policy.Abort`, the process aborts instead of quarantining — suitable for environments where partial service is worse than a full restart.

## The Trap Boundary

Tina's trap boundary catches not just panics but also **hardware faults** — SIGSEGV, SIGBUS, SIGFPE. Each Shard thread installs a `sigaltstack` (64KB alternate signal stack) so it can handle stack overflows. When a fault occurs:

1. The signal handler performs an emergency log flush (for diagnostics).
2. `siglongjmp` jumps to the Shard-level recovery point.
3. Level 2 recovery runs: all Isolates torn down, supervision tree rebuilt.

Guard pages between Grand Arenas prevent a wild pointer in one Shard from silently corrupting another Shard's memory. A sequential overflow hits the guard, triggers SIGSEGV on the offending Shard, and initiates Level 2 recovery — the other Shards never notice.

## Tradeoffs Accepted

**No framework-enforced shutdown ordering.** During graceful shutdown, each Isolate handles `TAG_SHUTDOWN` independently. Natural ordering emerges from the dependency structure (listeners stop first, connections drain, infrastructure outlives workers). Framework-enforced supervision tree walk is deferred to post-v1. The global shutdown timeout provides the safety net.

**Supervision restarts use the same init args.** A restarted Isolate receives the same `args_payload` that was in its `Spawn_Spec`. If the original args are stale (e.g., they referenced a dead Handle), the `init_fn` must handle this — typically by using the check-in pattern (send a message with the new Handle to a coordinator).

**Quarantine is Shard-wide, not per-group.** When escalation reaches the root group, the entire Shard quarantines. There is no "quarantine one group, keep the rest running" mode. This is conservative but simple — a cascade of failures within a Shard suggests systemic corruption, not a single misbehaving group.

**The trap boundary relies on `siglongjmp` from signal handlers.** While this pattern introduces locking hazards in traditional C/C++ applications, it is structurally safe in Tina because the hot path is lock-free, `malloc`-free, and strictly thread-local. There are no locks to leak, no heap allocations to corrupt, and no complex stack state to unwind.

**Level 3 (process abort) delegates to external supervision.** Tina does not attempt to "heal" a structurally broken process. systemd, Kubernetes health checks, or Erlang's `heart` module are the correct Level 3 supervisors. This matches the Erlang philosophy: the BEAM node has `heart`; Tina has the OS.
