# Tina Examples

These examples deliberately crash workers and shards to show how Tina contains failures. Each one is a single-file program you can build and run in seconds.


## Task Dispatcher — *A Dead Worker Is Not a Dead System*

A dispatcher assigns jobs to three workers on a timer. Every 3rd job triggers a worker crash. The supervisor restarts the worker, it checks in with a fresh handle, and the dispatcher resumes — no locks, no shared-state cleanup.

A restarted worker gets a new handle; stale ones fail closed.

### Run it

```sh
odin build examples/example_task_dispatcher.odin -file -out:tina_dispatch
./tina_dispatch
```

Workers crash every 3rd job by default. The first crash happens within a few seconds.

### What to watch in the output

- `[FAIL]` — a worker hit a bad job and crashed
- `[RECOVER]` — the same worker restarted with a new handle (the old one is now permanently invalid)
- `[INSIGHT]` — the dispatcher noticed the stale handle and dropped the job cleanly

Here's roughly what the first crash cycle looks like:

```
Worker 0: Completed Job 1.
Worker 1: Completed Job 2.
[FAIL] Worker 2 crashed on Job 3. Watch: it will come back with a NEW handle.
[RECOVER] Worker 2 checked in with handle A3F1
[RECOVER] Worker 2 reborn. old=91C0 new=A3F1
[INSIGHT] Same role. New identity. Stale sends fail safely.
Worker 0: Completed Job 4.
```

The dispatcher kept assigning work the whole time. It didn't block, retry, or coordinate a cleanup. The dead worker's handle became stale, the job was dropped, and the worker came back on its own terms.

### Why this matters

The interesting thing here isn't the crash — it's what *doesn't* happen after the crash. There's no mutex to release, no channel to drain, no shared state to reconcile. The handle itself is the coordination mechanism: when it goes stale, sends fail cleanly instead of corrupting something.

**If you know Go:** In a typical worker-pool design, you'd need to think about in-flight work and any shared state the worker held. Here, the old handle simply becomes invalid — the dispatcher finds out through a normal send result, not a panic or a timeout.

**If you know Elixir:** The supervision shape will feel familiar. The "check-in pattern" is Tina's equivalent of a restarted process re-registering its PID. The difference is that workers are native isolates with zero-allocation messaging, not BEAM processes.

**If you know Rust:** The state-machine style will feel natural. The new piece is runtime fault containment at the isolate boundary — the old handle becomes a revoked capability rather than a dangling reference.

### Try this next

1. Rebuild with `-define:TINA_DEMO_CRASH_EVERY=1` — every single job crashes a worker. The system still makes progress.
2. Rebuild with a tight restart budget: `-define:TINA_DEMO_ROOT_RESTART_MAX=3 -define:TINA_DEMO_ROOT_WINDOW_TICKS=500` — the shard itself gets quarantined when the restart rate exceeds the budget.
3. On POSIX, send `kill -USR2 <pid>` to revive the quarantined shard.

### Compile-time knobs

All flags use `-define:FLAG=value`.

| Flag | Default | What it controls |
|------|---------|------------------|
| `TINA_DEMO_CRASH_EVERY` | `3` | Workers crash on every Nth job (0 = never) |
| `TINA_DEMO_ROOT_RESTART_MAX` | `10` | Root group restart budget |
| `TINA_DEMO_ROOT_WINDOW_TICKS` | `5000` | Root group restart window (ticks) |
| `TINA_DEMO_SHARD_RESTART_MAX` | `3` | Watchdog restart limit before quarantine |
| `TINA_DEMO_SHARD_RESTART_WINDOW_MS` | `30000` | Watchdog restart window (ms) |
| `TINA_DEMO_ABORT_ON_QUARANTINE` | `false` | Abort the process instead of quarantining |


## TCP Echo — *"One Shard Goes Bad, the Process Stays Alive"*

A two-shard TCP echo server. Shard 0 runs a listener and two clients exchanging PINGs and PONGs. Shard 1 runs two more clients plus a chaos client that crashes after a few successful round-trips. The supervisor restarts it, it reconnects and crashes again, draining Shard 1's restart budget until it gets quarantined.

One shard can be quarantined while another keeps serving.

### Run it

```sh
odin build examples/example_tcp_echo.odin -file -out:tina_echo
./tina_echo
```

The chaos client crashes after 2 round-trips (by default). Shard 1 will be quarantined within ~6 seconds.

### What to watch in the output

Look at two things at once: Shard 1's crashes and Shard 0's PONGs.

```
Client on Shard 0: PONG #3 received ✓
Chaos client on Shard 1: PONG #2 received ✓
[FAIL] Chaos client on Shard 1 crashing (after 2 pings)
[FAIL] Chaos client on Shard 1 crashing (after 2 pings)
  ... Shard 1 quarantined ...
Client on Shard 0: PONG #8 received ✓
Client on Shard 0: PONG #8 received ✓
```

Shard 0 never stopped. The process is still up. The damage stayed within one shard.

### Why this matters

Shard 0 and Shard 1 share no memory. Each shard is a separate OS thread with its own arena, separated by hardware guard pages. When Shard 1 becomes unstable, the watchdog quarantines it — the thread stops, but nothing else is affected.

**If you know Go:** The closest analogue is running separate processes and coordinating with IPC. A panicking goroutine with `recover()` still shares the heap. Tina shards share nothing — the isolation is hardware-enforced.

**If you know Elixir:** Think application-level supervision, but each application is pinned to a CPU core with its own pre-allocated memory arena. If a NIF segfaults in one shard, the other shards continue — something the BEAM can't guarantee for native code.

**If you know Rust:** Tokio tasks share an executor and heap. If one corrupts memory, the damage can spread. Tina shards are physically separate — different threads, different arenas, guard pages between them. Quarantine is a runtime operation the scheduler provides, not something you build yourself.

### Try this next

1. After Shard 1 is quarantined, send `kill -USR2 <pid>` to revive it. Watch it come back and resume serving.
2. Rebuild with `-define:TINA_DEMO_ECHO_ABORT_ON_QUARANTINE=true` — the process aborts instead of quarantining. Compare the behavior.
3. Rebuild with `-define:TINA_DEMO_ECHO_CHAOS_CRASH_AFTER=1` — the chaos client crashes on every single round-trip. Quarantine happens faster.

### Compile-time knobs

| Flag | Default | What it controls |
|------|---------|------------------|
| `TINA_DEMO_ECHO_ROOT_RESTART_MAX` | `5` | Shard 0 root group restart budget |
| `TINA_DEMO_ECHO_ROOT_WINDOW_TICKS` | `10000` | Shard 0 root group restart window (ticks) |
| `TINA_DEMO_ECHO_CHAOS_RESTART_MAX` | `2` | Shard 1 restart budget (tight — triggers quarantine) |
| `TINA_DEMO_ECHO_CHAOS_WINDOW_TICKS` | `15000` | Shard 1 restart window (ticks) |
| `TINA_DEMO_ECHO_SHARD_RESTART_MAX` | `2` | Watchdog restart limit before quarantine |
| `TINA_DEMO_ECHO_SHARD_RESTART_WINDOW_MS` | `30000` | Watchdog restart window (ms) |
| `TINA_DEMO_ECHO_ABORT_ON_QUARANTINE` | `false` | Abort the process instead of quarantining |
| `TINA_DEMO_ECHO_CHAOS_CRASH_AFTER` | `2` | Chaos client crashes after N successful round-trips |


## Debug build

Enable debug assertions (validates `self_as` casts, `payload_offset_of` bounds, etc.):

```sh
odin build examples/example_tcp_echo.odin -file -out:tina_echo -define:TINA_ASSERTS=true
```

## What each example covers

| Concept | Dispatcher | Echo |
|---------|-----------|------|
| Ephemeral handles (stale = safe drop) | ✓ | |
| Check-in pattern (worker re-registration) | ✓ | |
| Typed inter-isolate messaging | ✓ | |
| Supervision restart budgets | ✓ | ✓ |
| Shard quarantine & recovery | ✓ | ✓ |
| Async I/O (accept/connect/send/recv) | | ✓ |
| FD handoff between isolates | | ✓ |
| Blast radius containment | | ✓ |
