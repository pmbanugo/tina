# Graceful Shutdown

When your process receives SIGTERM or SIGINT, Tina runs a three-phase shutdown protocol. This guide shows how your Isolates participate.

---

## The Three Phases

```
SIGTERM / SIGINT
       │
       ▼
┌─────────────────────────────────────┐
│  Phase 1: Notification (Tick 0)     │  All live Isolates receive TAG_SHUTDOWN.
│  All parked Isolates are woken.     │  No pool allocation — delivered via SOA-bypass.
└──────────────────┬──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│  Phase 2: Graceful Drain            │  Bounded by shutdown_timeout_ms (from SystemSpec).
│  Isolates run their drain logic.    │  Scheduler loop keeps running (I/O, timers, messages).
│  ctx_is_shutting_down() == true.    │  Spawns still allowed.
└──────────────────┬──────────────────┘
                   │  timeout expires OR second SIGTERM
                   ▼
┌─────────────────────────────────────┐
│  Phase 3: Force-Kill                │  Emergency log flush, then _exit(0).
│  Kernel reclaims everything.        │  TCP sockets send RST. All threads terminated.
└─────────────────────────────────────┘
```

**The framework provides the signal and the timeout. You provide the drain logic.**

---

## The Shutdown Signal: TAG_SHUTDOWN

`TAG_SHUTDOWN` is system tag `0x0003`. The scheduler delivers it to every live Isolate when the Shard enters shutdown mode.

- **Source:** `HANDLE_NONE` (it's a system message, not from another Isolate).
- **Payload:** Empty.
- **Delivery:** Via SOA-bypass — zero pool allocation. Deliverable even if the message pool is exhausted.
- **Priority:** I/O completions are dispatched *before* `TAG_SHUTDOWN`. Your handler will always see pending I/O results first.

```
Dispatch priority during shutdown:

    io_completion_tag != 0  >  shutdown_pending  >  inbox_count > 0
    ─────────────────────      ─────────────────    ──────────────
    (process I/O first)        (then TAG_SHUTDOWN)  (then mailbox)
```

---

## Proactive Check: ctx_is_shutting_down

You don't have to wait for `TAG_SHUTDOWN`. Call `tina.ctx_is_shutting_down(ctx)` in any handler to check if the Shard is shutting down. Returns `true` once the Shard enters shutdown mode.

Use this to stop accepting new work before `TAG_SHUTDOWN` arrives:

```odin
case TAG_JOB:
    // Don't start new work if we're shutting down.
    if tina.ctx_is_shutting_down(ctx) {
        return tina.Effect_Done{}
    }
    // ... process the job normally ...
```

---

## Pattern 1: Instant Exit

For Isolates with no drain work — timers, simple workers, dispatchers.

```odin
worker_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(WorkerIsolate, self_raw, ctx)

    switch message.tag {

    // ---- Shutdown requested. No cleanup needed. Exit immediately. ----
    case tina.TAG_SHUTDOWN:
        return tina.Effect_Done{}

    case TAG_JOB:
        // ... normal work ...
        return tina.Effect_Receive{}

    case:
        return tina.Effect_Receive{}
    }
}
```

That's it. One line: `return tina.Effect_Done{}`. The supervisor marks the Isolate as cleanly exited.

---

## Pattern 2: Connection Drain

For TCP connections that need to flush data and close the socket gracefully.

The sequence: receive `TAG_SHUTDOWN` → send TCP FIN → read until EOF → close socket → exit.

```odin
Conn_State :: enum u8 {
    Active,    // normal operation
    Draining,  // shutdown requested, reading until EOF
    Closing,   // waiting for close to complete
}

DrainConnection :: struct {
    fd:     tina.FD_Handle,
    state:  Conn_State,
    buffer: [4096]u8,
}

drain_conn_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(DrainConnection, self_raw, ctx)

    switch self.state {

    // ---- Normal operation ----
    case .Active:
        switch message.tag {

        // ---- Shutdown requested while actively serving ----
        case tina.TAG_SHUTDOWN:
            // Send TCP FIN to the peer. This tells them "no more data from us."
            tina.ctx_shutdown(ctx, self.fd, .SHUT_WRITER)

            // Transition to Draining. We need to read until EOF
            // so the peer knows we received their last bytes.
            self.state = .Draining
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }

        case tina.IO_TAG_RECV_COMPLETE:
            if message.io.result <= 0 {
                self.state = .Closing
                return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
            }
            // ... process data, echo back, etc ...
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }

        case:
            return tina.Effect_Receive{}
        }

    // ---- Draining: read until EOF, discard data ----
    case .Draining:
        switch message.tag {
        case tina.IO_TAG_RECV_COMPLETE:
            if message.io.result <= 0 {
                // EOF (result == 0) or error (result < 0).
                // Either way, the peer is done. Close the socket.
                self.state = .Closing
                return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
            }
            // Peer is still sending data. Keep reading until they stop.
            // We already sent FIN, so they know we're closing.
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }
        case:
            return tina.Effect_Receive{}
        }

    // ---- Closing: wait for the close syscall to complete ----
    case .Closing:
        switch message.tag {
        case tina.IO_TAG_CLOSE_COMPLETE:
            // Socket is closed. We're done.
            return tina.Effect_Done{}
        case:
            return tina.Effect_Receive{}
        }
    }

    return tina.Effect_Receive{}
}
```

**The drain timeline:**

```
TAG_SHUTDOWN received
       │
       ├─▶ ctx_shutdown(fd, .SHUT_WRITER)   ← sends TCP FIN to peer
       │
       ├─▶ state = .Draining
       │
       ├─▶ IoOp_Recv (read until EOF)       ← peer sends remaining data
       │       │
       │       ├─▶ result > 0: keep reading (discard data)
       │       │
       │       └─▶ result == 0: EOF!        ← peer acknowledged the close
       │               │
       │               ├─▶ IoOp_Close       ← close the socket
       │               │
       │               └─▶ Effect_Done{}    ← Isolate exits cleanly
       │
       └── all within shutdown_timeout_ms ──┘
```

---

## Listener Shutdown

A Listener can receive `TAG_SHUTDOWN` while an accept is in flight. Handle both cases:

```odin
listener_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(ServerListener, self_raw, ctx)

    switch message.tag {

    // ---- Accept completed, but we might be shutting down ----
    case tina.IO_TAG_ACCEPT_COMPLETE:
        if message.io.result >= 0 {
            // Spawn a Connection even during shutdown.
            // The spawned child immediately sees ctx_is_shutting_down() == true
            // and will receive TAG_SHUTDOWN on its first dispatch.
            conn_args := ConnectionArgs{client_fd = message.io.fd}
            payload, size := tina.init_args_of(&conn_args)
            spec := tina.Spawn_Spec{
                type_id      = CONN_TYPE,
                group_id     = tina.ctx_supervision_group_id(ctx),
                restart_type = .temporary,
                args_payload = payload,
                args_size    = size,
                handoff_fd   = message.io.fd,
                handoff_mode = .Full,
            }
            _ = tina.ctx_spawn(ctx, spec)
        }

        // If shutting down, stop accepting. Otherwise, accept the next connection.
        if tina.ctx_is_shutting_down(ctx) {
            return tina.Effect_Done{}
        }
        return tina.Effect_Io{
            operation = tina.IoOp_Accept{listen_fd = self.listen_fd},
        }

    // ---- Shutdown signal (if we were parked waiting for accept, the I/O was cancelled) ----
    case tina.TAG_SHUTDOWN:
        return tina.Effect_Done{}

    case:
        return tina.Effect_Receive{}
    }
}
```

---

## Spawns During Shutdown

Spawning is allowed during shutdown. The spawned child immediately sees `ctx_is_shutting_down() == true` and receives `TAG_SHUTDOWN` on its first dispatch.

This matters for Listeners: if an accept completes just as shutdown begins, the Listener must still spawn a Connection to handle the accepted FD. Otherwise the FD leaks and the peer hangs.

---

## Configuring the Timeout

Set `shutdown_timeout_ms` in your `SystemSpec`:

```odin
spec := tina.SystemSpec{
    // ...
    shutdown_timeout_ms = 5_000,  // 5 seconds for graceful drain
    // ...
}
```

If your Isolates don't finish within this window, Phase 3 kicks in: emergency log flush, then `_exit(0)`. The kernel closes all sockets (sending RST), unmaps all memory, and terminates all threads.

---

## Summary

| Isolate Type | On TAG_SHUTDOWN | Drain Work |
|---|---|---|
| Timer / Worker | `return Effect_Done{}` | None |
| Listener | Stop accepting, `return Effect_Done{}` | None |
| Connection | `ctx_shutdown(fd, .SHUT_WRITER)` → read until EOF → close → done | Multi-step I/O |
| Dispatcher | `return Effect_Done{}` | None (workers drain themselves) |

| API | Purpose |
|---|---|
| `tina.TAG_SHUTDOWN` | System message tag (`0x0003`). Delivered to all live Isolates on shutdown. |
| `tina.ctx_is_shutting_down(ctx)` | Returns `true` once the Shard enters shutdown mode. Check proactively. |
| `tina.ctx_shutdown(ctx, fd, how)` | Half-close a socket (`.SHUT_WRITER` sends TCP FIN). |
| `shutdown_timeout_ms` on `SystemSpec` | Maximum time for Phase 2 graceful drain. |
