# Handling State Machines

Every Isolate in Tina is a state machine. This guide covers three patterns — from simple to complex.

---

## Pattern 1: The Reactive Handler (Most Common)

Most Isolates don't need explicit state. They just switch on `message.tag` and react.

```odin
package main

import tina "../src"
import "core:fmt"

// ---- A Worker that receives jobs, does work, reports done ----

WORKER_TYPE: u8 : 0

TAG_JOB:      tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1
TAG_JOB_DONE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 2

JobMsg :: struct {
    job_id: u32,
}

JobDoneMsg :: struct {
    job_id:    u32,
    worker_id: u32,
}

Worker :: struct {
    id:     u32,
    boss:   tina.Handle,  // who to report results to
}

worker_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(Worker, self_raw, ctx)
    // ... parse init args, set self.id and self.boss ...
    return tina.Effect_Receive{}  // park, waiting for messages
}

worker_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(Worker, self_raw, ctx)

    switch message.tag {

    // ---- Got a job. Do the work. Report back. ----
    case TAG_JOB:
        job := tina.payload_as(JobMsg, message.user.payload[:])

        // ... do the work ...

        // Report completion to whoever sent us the job.
        done := JobDoneMsg{job_id = job.job_id, worker_id = self.id}
        _ = tina.ctx_send(ctx, self.boss, TAG_JOB_DONE, &done)

        // Park again, waiting for the next job.
        return tina.Effect_Receive{}

    // ---- Anything else — ignore and wait ----
    case:
        return tina.Effect_Receive{}
    }
}
```

**No state enum. No transitions. Just tag → action → park.** This covers timers, simple services, and most workers.

---

## Pattern 2: The Lifecycle State Machine (Explicit Phases)

For Isolates with sequential phases — like a TCP connection that goes through `connecting → active → draining → closing` — use an explicit state enum in the struct.

```odin
// ---- Connection states ----
Conn_State :: enum u8 {
    Connecting,  // waiting for TCP connect to complete
    Active,      // reading and writing data
    Draining,    // shutdown requested, flushing remaining data
    Closing,     // waiting for socket close to complete
}

Connection :: struct {
    fd:     tina.FD_Handle,
    state:  Conn_State,       // the explicit state machine
    buffer: [256]u8,
}

conn_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(Connection, self_raw, ctx)
    // ... parse args, get target address ...

    self.state = .Connecting  // start in the Connecting phase

    // Initiate async connect.
    return tina.Effect_Io{
        operation = tina.IoOp_Connect{
            fd      = self.fd,
            address = tina.ipv4(127, 0, 0, 1, 9090),
        },
    }
}

conn_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(Connection, self_raw, ctx)

    // ---- Switch on STATE first, then on message.tag within each state ----
    switch self.state {

    case .Connecting:
        switch message.tag {
        case tina.IO_TAG_CONNECT_COMPLETE:
            if message.io.result < 0 {
                // Connect failed — close and exit.
                self.state = .Closing
                return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
            }
            // Connected! Transition to Active, start reading.
            self.state = .Active
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }
        case:
            return tina.Effect_Receive{}
        }

    case .Active:
        switch message.tag {
        case tina.IO_TAG_RECV_COMPLETE:
            if message.io.result <= 0 {
                // EOF or error — close.
                self.state = .Closing
                return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
            }
            // Got data — process it, then read more.
            // ... handle the data ...
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }

        case tina.TAG_SHUTDOWN:
            // Graceful shutdown requested — transition to Draining.
            tina.ctx_shutdown(ctx, self.fd, .SHUT_WRITER)  // send TCP FIN
            self.state = .Draining
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }
        case:
            return tina.Effect_Receive{}
        }

    case .Draining:
        switch message.tag {
        case tina.IO_TAG_RECV_COMPLETE:
            if message.io.result <= 0 {
                // EOF — peer acknowledged close. Now close the socket.
                self.state = .Closing
                return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
            }
            // Still receiving data during drain — keep reading until EOF.
            return tina.Effect_Io{
                operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = u32(len(self.buffer))},
            }
        case:
            return tina.Effect_Receive{}
        }

    case .Closing:
        switch message.tag {
        case tina.IO_TAG_CLOSE_COMPLETE:
            // Socket closed — we're done.
            return tina.Effect_Done{}
        case:
            return tina.Effect_Receive{}
        }
    }

    return tina.Effect_Receive{}
}
```

**The state transition diagram:**

```
  ┌────────────┐  connect ok  ┌────────┐  TAG_SHUTDOWN  ┌──────────┐  EOF  ┌─────────┐
  │ Connecting │ ───────────▶ │ Active │ ─────────────▶ │ Draining │ ────▶ │ Closing │ ──▶ Done
  └────────────┘              └────────┘                └──────────┘       └─────────┘
        │                          │
        │ connect fail             │ EOF / error
        └──────────────────────────┴──────────────────────────────────────▶ Closing ──▶ Done
```

**When to use this pattern:** Any Isolate where the same message tag means different things depending on which phase you're in. TCP connections, protocol handshakes, multi-step workflows.

---

## Pattern 3: The Dispatcher-Worker Pattern

A Dispatcher spawns Workers, assigns jobs. Workers crash and restart with new Handles. The Dispatcher structurally tolerates stale Handles.

### The Problem

When a Worker crashes and the supervisor restarts it, the restarted Worker gets a **new Handle**. The Dispatcher still holds the **old Handle**. Sending to the old Handle returns `.stale_handle` — it doesn't crash, it doesn't block, it just fails safely.

### The Solution: The Check-In Pattern

After restart, each Worker sends its new Handle to the Dispatcher. The Dispatcher updates its table.

> **Why doesn't Tina update the Handle automatically?** Handles encode physical routing information — Shard ID, type ID, slot index, and generation. When the supervisor restarts an Isolate, the new Isolate occupies a (possibly different) slot with a new generation. The old Handle is structurally dead. Automatic forwarding would require a global, lock-protected registry — violating the shared-nothing architecture. The Check-In pattern keeps Handle resolution O(1) and lock-free: one shift, one mask, one generation comparison. No registry. No indirection.

```odin
// ---- Message tags ----
TAG_WORKER_READY:  tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1
TAG_JOB:           tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 2
TAG_JOB_DONE:      tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 3
TAG_DISPATCH_TICK: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 4

// ---- Init args: tells the Worker who its boss is ----
WorkerInitArgs :: struct {
    id:         u32,           // logical role (stays the same across restarts)
    dispatcher: tina.Handle,   // who to check in with
}

// ---- The check-in message ----
WorkerReadyMsg :: struct {
    id:     u32,            // "I am Worker #2"
    handle: tina.Handle,    // "and here is my new Handle"
}
```

### Worker: Check In on Init

```odin
WORKER_TYPE: u8 : 1

WorkerIsolate :: struct {
    id:         u32,
    dispatcher: tina.Handle,
}

worker_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(WorkerIsolate, self_raw, ctx)

    // Parse init args — the Dispatcher passed these when it spawned us.
    init_args := tina.payload_as(WorkerInitArgs, args)
    self.id = init_args.id
    self.dispatcher = init_args.dispatcher

    // THE CHECK-IN PATTERN:
    // After a restart, ctx.self_handle is a brand-new Handle.
    // The old one is dead — sends to it return .stale_handle.
    // We must tell the Dispatcher our new identity.
    ready_msg := WorkerReadyMsg{
        id     = self.id,            // same role as before
        handle = ctx.self_handle,    // new Handle (different after restart!)
    }
    _ = tina.ctx_send(ctx, self.dispatcher, TAG_WORKER_READY, &ready_msg)

    str := fmt.bprintf(
        ctx.scratch_arena.data,
        "[RECOVER] Worker %d checked in with handle %X",
        self.id,
        u64(ctx.self_handle),
    )
    tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

    return tina.Effect_Receive{}  // ready for jobs
}

worker_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    using self := tina.self_as(WorkerIsolate, self_raw, ctx)

    switch message.tag {
    case TAG_JOB:
        job := tina.payload_as(JobMsg, message.user.payload[:])

        // Simulate a crash on every 3rd job.
        if job.job_id % 3 == 0 {
            // The supervisor restarts us. We'll check in again with a new Handle.
            return tina.Effect_Crash{reason = .None}
        }

        // Happy path — do the work, report done.
        done := JobDoneMsg{job_id = job.job_id, worker_id = id}
        _ = tina.ctx_send(ctx, dispatcher, TAG_JOB_DONE, &done)
        return tina.Effect_Receive{}

    case:
        return tina.Effect_Receive{}
    }
}
```

### Dispatcher: Track Handles, Tolerate Stale Sends

```odin
DISPATCHER_TYPE: u8 : 0
NUM_WORKERS :: 3

DispatcherIsolate :: struct {
    workers:     [NUM_WORKERS]tina.Handle,  // indexed by Worker role ID
    job_counter: u32,
}

dispatcher_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(DispatcherIsolate, self_raw, ctx)

    // Spawn the workers. We don't know their Handles yet!
    // They'll check in via TAG_WORKER_READY.
    for i in 0 ..< NUM_WORKERS {
        self.workers[i] = tina.HANDLE_NONE  // placeholder until check-in

        init_args := WorkerInitArgs{
            id         = u32(i),
            dispatcher = ctx.self_handle,   // tell the Worker who we are
        }
        payload, size := tina.init_args_of(&init_args)

        spec := tina.Spawn_Spec{
            type_id      = WORKER_TYPE,
            group_id     = tina.ctx_supervision_group_id(ctx),
            restart_type = .permanent,          // always restart crashed Workers
            args_payload = payload,
            args_size    = size,
        }
        _ = tina.ctx_spawn(ctx, spec)
    }

    // Start a periodic dispatch timer (fires every 400ms).
    tina.ctx_register_timer(ctx, 400 * 1_000_000, TAG_DISPATCH_TICK)
    return tina.Effect_Receive{}
}

dispatcher_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    using self := tina.self_as(DispatcherIsolate, self_raw, ctx)

    switch message.tag {

    // ---- A Worker checked in (at boot OR after restart) ----
    case TAG_WORKER_READY:
        msg := tina.payload_as(WorkerReadyMsg, message.user.payload[:])
        // Update our table with the Worker's current Handle.
        workers[msg.id] = msg.handle
        return tina.Effect_Receive{}

    // ---- Time to dispatch jobs ----
    case TAG_DISPATCH_TICK:
        for i in 0 ..< len(workers) {
            job_counter += 1
            target := workers[i]

            if target == tina.HANDLE_NONE {
                // Worker hasn't checked in yet (still restarting). Skip.
                continue
            }

            job := JobMsg{job_id = job_counter}
            result := tina.ctx_send(ctx, target, TAG_JOB, &job)

            // ---- THE KEY MOMENT ----
            // If the Worker crashed between our last check and now,
            // ctx_send returns .stale_handle. Not a panic. Not a crash.
            // Just a safe, immediate "that Handle is dead" signal.
            if result == .stale_handle {
                // Clear the slot. The restarted Worker will check in
                // with TAG_WORKER_READY and fill it again.
                workers[i] = tina.HANDLE_NONE
            }
        }

        // Re-arm the timer for the next dispatch cycle.
        tina.ctx_register_timer(ctx, 400 * 1_000_000, TAG_DISPATCH_TICK)
        return tina.Effect_Receive{}

    case:
        return tina.Effect_Receive{}
    }
}
```

### What Happens During a Crash-Restart Cycle

```
Tick 1:  Dispatcher sends Job #3 to Worker #0 (Handle = 0xAA)
Tick 2:  Worker #0 crashes on Job #3 → Effect_Crash
Tick 3:  Supervisor restarts Worker #0 → new Handle = 0xBB
Tick 3:  Worker #0's init_fn sends TAG_WORKER_READY{id=0, handle=0xBB}
Tick 4:  Dispatcher sends Job #6 to Worker #0 (Handle = 0xAA) → .stale_handle!
         Dispatcher clears workers[0] = HANDLE_NONE
Tick 5:  Dispatcher receives TAG_WORKER_READY → workers[0] = 0xBB
Tick 6:  Dispatcher sends Job #9 to Worker #0 (Handle = 0xBB) → .ok ✓
```

> **The handle changes. The role doesn't. Stale sends fail safely.**

### Boot Spec

```odin
main :: proc() {
    types := [2]tina.TypeDescriptor{
        {
            id               = DISPATCHER_TYPE,
            slot_count       = 1,                          // one dispatcher
            stride           = size_of(DispatcherIsolate),
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn          = dispatcher_init,
            handler_fn       = dispatcher_handler,
            mailbox_capacity = 64,                         // needs room for check-ins + done msgs
        },
        {
            id               = WORKER_TYPE,
            slot_count       = 10,                         // up to 10 workers
            stride           = size_of(WorkerIsolate),
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn          = worker_init,
            handler_fn       = worker_handler,
            mailbox_capacity = 16,
        },
    }

    // Only the Dispatcher is a static child. Workers are spawned dynamically by the Dispatcher.
    children := [1]tina.Child_Spec{
        tina.Static_Child_Spec{type_id = DISPATCHER_TYPE, restart_type = .temporary},
    }

    root_group := tina.Group_Spec{
        strategy              = .One_For_One,
        restart_count_max     = 10,
        window_duration_ticks = 5_000,
        children              = children[:],
        child_count_dynamic_max = 10,   // room for Workers
    }

    shard_specs := [1]tina.ShardSpec{
        {shard_id = 0, root_group = root_group, target_core = -1},
    }

    spec := tina.SystemSpec{
        shard_count           = 1,
        types                 = types[:],
        shard_specs           = shard_specs[:],
        timer_resolution_ns   = 1_000_000,
        pool_slot_count       = 4096,
        timer_spoke_count     = 1024,
        timer_entry_count     = 1024,
        log_ring_size         = 65536,
        default_ring_size     = 16,
        scratch_arena_size    = 65536,
        fd_table_slot_count   = 16,
        fd_entry_size         = size_of(tina.FD_Entry),
        supervision_groups_max = 4,
        reactor_buffer_slot_count = 16,
        reactor_buffer_slot_size  = 4096,
        transfer_slot_count   = 16,
        transfer_slot_size    = 4096,
        shutdown_timeout_ms   = 3_000,
    }

    tina.tina_start(&spec)
}
```

---

## Summary

| Pattern | State Lives In | When To Use |
|---|---|---|
| **Reactive Handler** | `message.tag` (no explicit state) | Timers, workers, simple services |
| **Lifecycle State Machine** | `enum` field in the Isolate struct | TCP connections, protocol handshakes, multi-phase workflows |
| **Dispatcher-Worker** | Handle table in the Dispatcher | Work distribution with crash tolerance |
