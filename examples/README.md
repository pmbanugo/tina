# Tina Examples

## Building

Each example is a standalone `package main` file that imports the tina library. Build each one individually:

```sh
# TCP Echo Server
odin build examples/example_tcp_echo.odin -file -out:tina_echo

# Task Dispatcher
odin build examples/example_task_dispatcher.odin -file -out:tina_dispatch
```

To enable debug assertions (validates `self_as` casts, `payload_offset_of` bounds, etc.):

```sh
odin build examples/example_tcp_echo.odin -file -out:tina_echo -define:TINA_ASSERTS=true
```

---

## Example 1: TCP Echo Server (`example_tcp_echo.odin`)

A multi-shard TCP ping-pong server that demonstrates I/O, supervision, and quarantine recovery.

**Architecture:**
- **Shard 0:** Listener (accepts connections), 2 Clients (send PINGs, expect PONGs)
- **Shard 1:** 2 Clients + 1 Chaos Isolate (triggers quarantine at a configurable tick)

**What it demonstrates:**
- `Effect_Io` for async socket operations (accept, connect, send, recv, close)
- `io_send` helper for zero-boilerplate sends from isolate buffers (e.g. buffer could be derived from working memory)
- FD handoff from listener to per-connection isolates via `Spawn_Spec.handoff_fd`
- Supervision restart budgets and shard-level quarantine
- Quarantine recovery via `kill -USR2 <pid>` (POSIX only)

### Config Flags

All flags are compile-time via `-define:FLAG=value`.

| Flag | Default | Description |
|------|---------|-------------|
| `TINA_DEMO_ECHO_ROOT_RESTART_MAX` | `5` | Shard 0 root group restart budget |
| `TINA_DEMO_ECHO_ROOT_WINDOW_TICKS` | `10000` | Shard 0 root group restart window (ticks) |
| `TINA_DEMO_ECHO_CHAOS_RESTART_MAX` | `3` | Shard 1 root group restart budget (tighter to trigger quarantine) |
| `TINA_DEMO_ECHO_CHAOS_WINDOW_TICKS` | `1000` | Shard 1 root group restart window (ticks) |
| `TINA_DEMO_ECHO_SHARD_RESTART_MAX` | `2` | Watchdog Level 2 restart limit before quarantine |
| `TINA_DEMO_ECHO_SHARD_RESTART_WINDOW_MS` | `30000` | Watchdog Level 2 restart window (ms) |
| `TINA_DEMO_ECHO_ABORT_ON_QUARANTINE` | `false` | If `true`, process aborts instead of quarantining |
| `TINA_DEMO_ECHO_CHAOS_START_TICK` | `5000` | Tick at which the Chaos isolate begins crashing |
| `TINA_DEMO_ECHO_CHAOS_END_TICK` | `6000` | Tick at which the Chaos isolate stops crashing on init |

### Running

```sh
# Default: Shard 1 quarantines around tick 5000
./tina_echo

# Make quarantine happen faster
odin build examples/example_tcp_echo.odin -file -out:tina_echo \
  -define:TINA_DEMO_ECHO_CHAOS_START_TICK=2000 \
  -define:TINA_DEMO_ECHO_CHAOS_RESTART_MAX=2
./tina_echo

# Abort on quarantine instead of isolating the shard
odin build examples/example_tcp_echo.odin -file -out:tina_echo \
  -define:TINA_DEMO_ECHO_ABORT_ON_QUARANTINE=true
./tina_echo
```

To recover a quarantined shard at runtime (POSIX):

```sh
kill -USR2 <pid>
```

---

## Example 2: Task Dispatcher (`example_task_dispatcher.odin`)

A single-shard task dispatch system that demonstrates messaging, supervision, and crash recovery.

**Architecture:**
- 1 Dispatcher Isolate spawns N Workers
- Dispatcher sends jobs on a timer; Workers process and reply
- Every Nth job triggers a Worker crash (configurable), exercising restart

**What it demonstrates:**
- `ctx_send` for typed inter-Isolate messaging
- `init_args_of` for passing structured init arguments to spawned Isolates
- The check-in pattern: Workers send their new Handle back after restart
- Load shedding: Dispatcher detects stale handles and drops jobs for dead Workers
- Supervision restart budgets at both root-group and shard levels

### Config Flags

| Flag | Default | Description |
|------|---------|-------------|
| `TINA_DEMO_CRASH_EVERY` | `5` | Workers crash on every Nth job (0 = never) |
| `TINA_DEMO_ROOT_RESTART_MAX` | `10` | Root group restart budget |
| `TINA_DEMO_ROOT_WINDOW_TICKS` | `5000` | Root group restart window (ticks) |
| `TINA_DEMO_SHARD_RESTART_MAX` | `3` | Watchdog Level 2 restart limit |
| `TINA_DEMO_SHARD_RESTART_WINDOW_MS` | `30000` | Watchdog Level 2 restart window (ms) |
| `TINA_DEMO_ABORT_ON_QUARANTINE` | `false` | If `true`, process aborts instead of quarantining |

### Running

```sh
# Run directly without a separate build step
odin run examples/example_task_dispatcher.odin -file \
  -define:TINA_SIM=false \
  -define:TINA_DEMO_CRASH_EVERY=1 \
  -define:TINA_DEMO_ROOT_RESTART_MAX=1 \
  -define:TINA_DEMO_ROOT_WINDOW_TICKS=10000 \
  -define:TINA_DEMO_SHARD_RESTART_MAX=1 \
  -define:TINA_DEMO_SHARD_RESTART_WINDOW_MS=10000

# Default: Workers crash every 5th job
./tina_dispatch

# Disable crashes entirely
odin build examples/example_task_dispatcher.odin -file -out:tina_dispatch \
  -define:TINA_DEMO_CRASH_EVERY=0
./tina_dispatch

# Crash every 2nd job with a tight restart window
odin build examples/example_task_dispatcher.odin -file -out:tina_dispatch \
  -define:TINA_DEMO_CRASH_EVERY=2 \
  -define:TINA_DEMO_ROOT_RESTART_MAX=3
./tina_dispatch
```

---

## Startup Output

Both examples print their active configuration at launch:

```
Starting TCP Ping-Pong Echo Server. Press Ctrl+C to shut down.
[DEMO] root_max=5 root_window=10000 chaos_max=3 chaos_window=1000 shard_max=2 shard_window_ms=30000 chaos_ticks=5000..6000 quarantine_policy=Quarantine pid=12345
[DEMO] To recover quarantined shards, run: kill -USR2 12345
```

This makes it easy to verify which knobs are active without reading the source.
