# Deterministic Simulation Testing

**Tina controls the clock, network, and I/O behind the scheduler loop, so the same seed and config produce the same execution every time. This enables FoundationDB/TigerBeetle-style simulation testing: inject faults, drop messages, partition Shards — and reproduce any bug on demand.**

Stress tests find bugs by accident. Deterministic simulation finds them on purpose.

The idea is simple: if you control every source of non-determinism in your system — the clock, the network, the disk, the thread interleaving — then you can replay any execution exactly. A bug found with seed `0xDEADBEEF42` can be reproduced tomorrow, next week, or after a refactor, by running the same seed again. This is the technique used by FoundationDB (Sim2) and TigerBeetle (VOPR) to find bugs that stress tests, fuzzing, and code review consistently miss.

Tina is designed from the ground up to support this. It is not bolted on.

## How Tina Makes This Possible

Deterministic simulation requires that no execution decision depends on anything outside the framework's control. In practice, three things introduce non-determinism in concurrent systems:

1. **The clock.** `clock_gettime()` returns a different value every call.
2. **I/O completions.** The kernel returns I/O results in unpredictable order and timing.
3. **Thread interleaving.** On a multi-core machine, the OS scheduler decides which core runs when.

Tina's architecture already abstracts all three behind the scheduler loop. Isolates do not call the clock, do not perform I/O directly, and do not run on OS threads. They return `Effect` values, and the scheduler interprets them. In simulation mode, the interpreter is swapped — the Isolate code is identical in both modes.

| Subsystem | Production | Simulation |
|---|---|---|
| Clock | `clock_gettime(CLOCK_MONOTONIC)` | Tick counter, advanced by the harness |
| I/O backend | `io_uring` / `kqueue` / `IOCP` | Scripted completions, injectable faults |
| Cross-shard transport | Lock-free messaging channels | Passive network with delay, drop, and partition |
| Thread model | One OS thread per core, pinned | All Shards on one OS thread, sequential |

## Single-Threaded Simulation

In simulation mode, all Shards run on a single OS thread. The simulation loop ticks each Shard exactly once per round, in sequence:

```
for each round until max_ticks:
    1. Advance simulated time by one tick
    2. Run fault engine (partitions, heals, delay jitter)
    3. Determine Shard execution order (PRNG-shuffled)
    4. Tick each Shard exactly once (full scheduler loop)
    5. Run structural checkers at interval
    6. Check for quiescence
```

**Why single-threaded?** With multiple OS threads, the execution order depends on the OS scheduler, cache timing, and interrupt distribution — all non-deterministic. By running every Shard sequentially on one thread, the execution order is a pure function of the PRNG state.

**Why shuffle the Shard order?** In production, CPU cores are not lock-stepping to a global metronome. They drift due to L3 cache misses, branch mispredictions, and variable I/O polling times. Shuffling the Shard execution order per round is the deterministic emulation of this phase drift.

When Shard A ticks before Shard B in a round, messages that A flushes in step 5 of its scheduler loop are visible to B in step 1 of the same round. When B ticks first, it does not see A's messages until the next round. This explores the interleaving space where race conditions hide — deterministically.

## The PRNG Tree

All randomness in a simulation derives from a single master seed. But the seed is not consumed linearly. Instead, it is split into a **tree of independent child PRNGs**, each governing a specific domain:

```
Master Seed (u64)
    │
    ├── Scheduling PRNG     (Shard execution order shuffling)
    ├── Network Drop PRNG   (per-message drop decisions)
    ├── Partition PRNG       (partition create/heal decisions, delay jitter)
    │
    ├── Shard 0 I/O PRNG    (I/O fault injection for Shard 0)
    ├── Shard 0 Crash PRNG  (Isolate crash injection for Shard 0)
    ├── Shard 1 I/O PRNG
    ├── Shard 1 Crash PRNG
    ├── ...
    └── Shard N I/O PRNG
        Shard N Crash PRNG
```

The tree structure serves a critical purpose: **domain isolation.** Adding a new Isolate type on Shard 2 changes the crash PRNG consumption rate for Shard 2, but it does not alter the network drop sequence, the scheduling order, or the fault injection on Shard 0. Without domain isolation, a small change to one part of the system would shift the entire PRNG sequence, making it impossible to narrow the cause of a newly discovered bug.

The derivation order within the tree is strict and append-only. New domains are appended at the end, never inserted between existing ones. This means old seeds remain valid across code changes that add new simulation features.

Tina uses Xoshiro256** as the PRNG engine — a well-characterized generator with 256 bits of state (fits in a single cache line), period 2^256-1, and no known statistical weaknesses for this use case. It is hard-forked from Odin's standard library to guarantee bit-identical output across compiler versions indefinitely.

## Integer-Ratio Fault Probabilities

All fault rates are expressed as `Ratio { numerator: u32, denominator: u32 }` and evaluated with pure integer arithmetic:

```odin
ratio_chance :: proc(r: Ratio, p: ^Prng) -> bool {
    if r.numerator == 0 do return false
    if r.numerator >= r.denominator do return true
    return prng_uint_less_than(p, r.denominator) < r.numerator
}
```

Why not floating-point? `3.0 / 1000.0` may produce different bit patterns across compilers, optimization levels, and CPU architectures. IEEE 754 permits intermediate precision widening, fused multiply-add, and platform-specific rounding — all of which can change the result by one ULP, which can change the branch outcome, which changes the entire execution from that point forward. `Ratio{3, 1000}` with integer comparison is bitwise identical everywhere. This follows TigerBeetle's approach exactly.

## Fault Configuration

The `FaultConfig` struct controls what breaks and how often:

| Field | Type | Effect |
|---|---|---|
| `io_error_rate` | `Ratio` | Per-completion probability of returning an error |
| `io_delay_range_ticks` | `[2]u32` | Min/max completion delay in ticks |
| `network_drop_rate` | `Ratio` | Per-message drop probability on cross-shard send |
| `network_delay_range_ticks` | `[2]u32` | Min/max per-channel delivery delay |
| `network_partition_rate` | `Ratio` | Per-round probability of isolating a Shard |
| `network_partition_heal_rate` | `Ratio` | Per-round probability of healing a partition |
| `isolate_crash_rate` | `Ratio` | Per-handler-invocation forced crash probability |
| `init_failure_rate` | `Ratio` | Per-init forced failure probability |

All rates default to `Ratio{0, 1}` (disabled). Network partitions isolate a randomly chosen Shard from all peers — analogous to a NIC failure or cable pull. Partitions are symmetric: if A is partitioned from B, B is also partitioned from A.

## Structural Checkers

At configurable intervals during the simulation (and unconditionally at termination), the framework runs **structural checkers** that verify internal invariants:

- **Pool integrity:** `free_count + allocated_count == total_count` for every pool on every Shard.
- **Generation monotonicity:** Isolate generation counters only increase. A generation of zero is always a violation (zero is reserved as the HANDLE_NONE sentinel).
- **User-defined checkers:** Application-level invariant functions that receive read-only access to all Shard state. For example, a banking application can verify that the sum of all account balances equals the initial total — a conservation invariant that must hold regardless of how many Isolates crash, how many messages are dropped, and how many partitions occur.

Checkers are not assertions sprinkled through code. They are external observers that verify the system's structural integrity from the outside, at regular intervals, across the entire distributed state. A checker violation halts the simulation and logs the seed for reproduction.

## Boot-Spec-Driven Workloads

Test scenarios are defined entirely in the `SystemSpec`. The user adds **TestDriver** Isolate types that generate traffic — sending messages, issuing `.call` requests, spawning dynamic children. TestDrivers are ordinary Isolates: they are subject to the same scheduling, backpressure, fault injection, and supervision as the system under test.

There is no privileged injection API. No god-mode message insertion. No bypassing of mailbox capacity limits. If a TestDriver overwhelms the system, it experiences the same backpressure the system would experience under real load. This tests the system's behavior under realistic conditions, not idealized ones.

```
// Simulation boot spec includes real types + test drivers
SystemSpec {
    types = [
        // Real application types
        TypeDescriptor { id = 0, handler_fn = session_handler, ... },
        TypeDescriptor { id = 1, handler_fn = router_handler, ...  },
        // Test workload driver (simulation only)
        TypeDescriptor { id = 100, handler_fn = driver_handler, ... },
    ],
    simulation = SimulationConfig {
        seed = 0xDEADBEEF,
        ticks_max = 1_000_000,
        shuffle_shard_order = true,
        faults = FaultConfig {
            network_drop_rate = Ratio{1, 100},
            isolate_crash_rate = Ratio{1, 500},
            ...
        },
    },
}
```

Your Isolate code is the same in both modes. The `Effect` interpreter is what changes.

## Tradeoffs Accepted

**Simulation is single-threaded — slower than production but fully reproducible.** A 16-Shard simulation runs 16 Shard ticks sequentially where production runs them in parallel. Simulation throughput is roughly 1/N of production for N Shards. This is acceptable because simulation is a testing tool, not a performance benchmark. The value is in the bugs it finds, not the speed at which it runs.

**No floating-point in simulation-critical paths.** All fault rates, time calculations, and scheduling decisions use integer arithmetic. This forces occasional awkwardness — you cannot say "crash 0.1% of the time," you must say `Ratio{1, 1000}`. The payoff is bitwise reproducibility across every platform, compiler, and optimization level Tina will ever target.

**All Shards must use the same timer resolution in simulation mode.** Heterogeneous tick rates would require LCM/GCD clock tracking — significant complexity for near-zero bug-finding utility. The probability of a bug manifesting only because Shard 1 ticks at 1ms and Shard 2 at 1.5ms is negligible compared to bugs found by network drops, handler crashes, and partition healing.

**Hash maps are forbidden in simulation-critical data structures.** Hash map iteration order is insertion-dependent and varies with table resizing. Any simulation-critical code using hash maps introduces non-determinism. All internal data structures use arrays, dense SOA arrays, or ordered structures. This constraint is enforced by convention, not by the type system — it requires discipline.
