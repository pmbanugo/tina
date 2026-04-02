# Future Memo: Clock Subsystem

## Status

Deferred. No behavior change proposed. The current implicit clock satisfies all ADR contract rules in both production and simulation.

## Context

Tina has two clock sources today:

- **Production**: `os_monotonic_time_ns()` — platform-specific wall clock (Darwin `clock_gettime_nsec_np`, Linux `clock_gettime(BOOTTIME)`, BSD `clock_gettime(MONOTONIC)`, Windows `QueryPerformanceCounter`). Called directly by the scheduler loop and bootstrap code. The result is divided by `timer_resolution_ns` to produce `shard.current_tick`.

- **Simulation**: the harness loop in `simulator_run` sets `shard.current_tick = round` directly, bypassing `os_monotonic_time_ns()` entirely. Time advances by harness control, not wall clock.

Both paths write the same field (`shard.current_tick`) and the same downstream consumers (scheduler, timer wheel, I/O backend) read it without knowing which source produced it. This is already behavioral substitution — the two clock sources satisfy the same contract — but the substitution is implicit: it happens because simulation code is behind `when TINA_SIMULATION_MODE` and production code runs otherwise.

This memo considers what a formal Clock subsystem would look like if both sources were unified behind a shared contract, and why it is deferred.

## The scheduler-facing clock contract

Regardless of source, the clock must satisfy:

1. `current_tick` advances monotonically within a shard's lifetime.
2. `current_tick` is the sole time reference for timer deadlines, I/O completion timing, and heartbeat stamps.
3. `timer_resolution_ns` is uniform and immutable after init.
4. In simulation: every shard observes the same tick value for a given round.
5. In simulation: time advances only under harness control.
6. In simulation: fast-forward must not skip earlier deliverable events.

Rules 1–3 apply universally. Rules 4–6 are simulation-specific but do not conflict with 1–3.

## How each subsystem uses the clock today

### Production bootstrap (`bootstrap_shard.odin`)

Calls `os_monotonic_time_ns()` before the main scheduler loop to set the initial `current_tick` and `timer_wheel.last_tick`. Also uses wall time for shard restart window accounting.

### Scheduler loop (`shard.odin`)

Calls `os_monotonic_time_ns()` at the top of each `scheduler_tick` iteration to refresh `shard.current_tick`. This is the production clock's tick point — one read per loop iteration.

### Timer wheel (`timer.odin`)

Reads `current_tick` to fire expired spokes. Timer deadlines are absolute: `current_tick + delay_ticks` at registration. The timer wheel does not call any clock procedure directly.

### I/O backend — production (`io_backend_linux.odin`, `io_backend_bsd.odin`)

Production backends do not use `current_tick` for completion timing. Completions arrive from the kernel and are processed immediately.

### I/O backend — simulation (`io_backend_simulated.odin`)

Uses `current_tick` to determine when simulated completions become deliverable. Delay is `submit_tick + configured_delay`, compared against `current_tick` during `backend_collect`.

### Harness loop (`simulator.odin`)

Owns the `round` variable. Sets `shard.current_tick = round` for every shard before calling `scheduler_tick`. Implements fast-forward by jumping `round` to the earliest timer deadline when idle.

### Heartbeat / watchdog (`bootstrap_shard.odin`, `watchdog.odin`)

Production uses `current_tick` for heartbeat stamps (atomic store, read by watchdog thread). Simulation bypasses the watchdog entirely.

### Fault engine (`simulation_faults.odin`)

Receives the `round` value as a parameter. Does not read `shard.current_tick`.

## What a Clock subsystem would provide

### Explicit substitution contract

Today the substitution works because `when TINA_SIMULATION_MODE` compiles away the production clock path. A Clock subsystem would make the contract explicit: both production and simulation implement the same set of procedures, and downstream code calls clock procedures rather than `os_monotonic_time_ns()` or writing `current_tick` directly.

This follows the Liskov substitution principle: any code that works with the production clock must also work with the simulation clock, because both honor the same behavioral contract. The scheduler should not need to know which clock it is using.

### Single write path for `current_tick`

Today, `current_tick` is written in three places:

- `bootstrap_shard.odin` (production init)
- `shard.odin` scheduler loop (production per-tick)
- `simulator_run` (simulation per-round)

A Clock subsystem would reduce this to one procedure per mode, called from one site. Shard ticks become published mirrors managed by the clock, not ad hoc writes.

### Testable time source

A dedicated clock makes it possible to test time-dependent behavior (timer deadlines, heartbeat staleness, I/O timeout) without running the full scheduler loop or the full simulation harness.

### Trace and instrumentation

Funneling all tick advancement through clock procedures creates a natural hook point for:

- tick advancement logging
- fast-forward event recording
- replay or step-through debugging
- round-by-round trace capture

### Control plane

A simulation debugger or test harness could interact with the clock directly: pause, step, query next deliverable event, inspect fast-forward eligibility.

## Why it is deferred

1. The current implicit substitution works. Both modes produce correct `current_tick` values and the scheduler does not need to distinguish them.
2. The production clock path is two lines: `now_ns := os_monotonic_time_ns()` then `shard.current_tick = now_ns / shard.timer_resolution_ns`. There is not enough complexity to justify wrapping it.
3. Odin does not have interfaces or vtables. Behavioral substitution in Odin is done via `when` compile-time selection or procedure variables. A Clock subsystem would be a struct with `when`-selected procedure bodies — the same mechanism already in use, just named.
4. Introducing a Clock struct now would touch `bootstrap_shard.odin`, `shard.odin`, and `simulator.odin` for no behavioral change. That is churn without payoff.
5. The three write sites for `current_tick` are each in their correct lifecycle phase (init, tick, simulation round). Unifying them under one procedure is cleaner but not necessary for correctness.

## Possible shape if revisited

A minimal Clock subsystem in Odin would look like:

- A `when TINA_SIMULATION_MODE` split that selects between two struct layouts or two sets of procedures.
- Both sides implement the same procedure signatures: `clock_init`, `clock_tick` (advance and publish), `clock_now_tick`, `clock_resolution_ns`.
- The scheduler calls `clock_tick` instead of reading `os_monotonic_time_ns()` directly.
- The simulation harness calls `clock_tick` with the round value instead of writing `shard.current_tick` directly.
- Fast-forward logic moves into a `clock_try_fast_forward` procedure that encapsulates the idle check and earliest-deadline scan.

The key design constraint: `shard.current_tick` must remain a plain field (not a procedure call) because the scheduler loop and timer wheel read it in hot paths. The Clock subsystem owns the write; consumers read the field directly.

## When to revisit

Reopen this memo if one of these becomes true:

- A fourth write site for `current_tick` appears.
- Fast-forward policy grows beyond the current idle-check-plus-timer-scan pattern.
- A simulation debugger or step-through tool needs a time control API.
- Trace or instrumentation work needs a hook point for tick advancement events.
- The production clock path gains complexity (e.g., clock skew handling, NTP correction, multi-source time).
- A new backend or subsystem needs to read time but should not call `os_monotonic_time_ns()` directly.

Without one of those triggers, the current implicit substitution is correct and sufficient.
