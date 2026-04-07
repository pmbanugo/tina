# Building a TCP Server

Build a complete, non-blocking TCP echo server with Tina. Two Isolate types — a Listener that accepts connections and a Connection that echoes data back — wired into a supervision tree.

No async/await. No callbacks. No locks. Just state machines that return Effects.

## Overview

```
Client connects
       │
       ▼
┌──────────────┐   accept completes   ┌──────────────────┐
│   Listener   │ ───────────────────▶ │ spawn Connection │
│ (1 per Shard)│                      │ (1 per client)   │
└──────────────┘                      └──────────────────┘
       │                                       │
       │ loop: accept next                     │ loop: recv → send → recv
       ▼                                       ▼
```

---

## Step 1: Define the Listener Isolate

The mental model of a TCP server starts at the port. One Listener per Shard opens the socket, binds, listens, and loops on accept.

```odin
// ---- The Listener Isolate's state ----
ServerListener :: struct {
    listen_fd: tina.FD_Handle,  // the listening socket
}
```

### Listener init_fn

All socket setup happens here — in one shot, no multi-step init.

```odin
listener_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(ServerListener, self_raw, ctx)

    // 1. Create a TCP socket.
    fd, err := tina.ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
    if err != .None {
        // Can't open a socket — crash. The supervisor will restart us.
        return tina.Effect_Crash{reason = .Init_Failed}
    }
    self.listen_fd = fd

    // 2. Set SO_REUSEADDR so we can restart quickly without TIME_WAIT issues.
    tina.ctx_setsockopt(ctx, self.listen_fd, .SOL_SOCKET, .SO_REUSEADDR, true)

    // 3. Bind to 127.0.0.1:9090.
    tina.ctx_bind(ctx, self.listen_fd, tina.ipv4(127, 0, 0, 1, 9090))

    // 4. Start listening with a backlog of 128.
    tina.ctx_listen(ctx, self.listen_fd, 128)

    // 5. Log that we're ready.
    str := fmt.bprintf(ctx.scratch_arena.data, "TCP Server listening on 127.0.0.1:9090")
    tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

    // 6. Park waiting for the first connection.
    //    This is our initial parking Effect — the scheduler won't call us again
    //    until a client connects.
    return tina.Effect_Io{operation = tina.IoOp_Accept{listen_fd = self.listen_fd}}
}
```

### Listener handler_fn

Each time a connection is accepted, spawn a Connection Isolate and loop back to accepting.

```odin
listener_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(ServerListener, self_raw, ctx)

    switch message.tag {

    // ---- A new client connected ----
    case tina.IO_TAG_ACCEPT_COMPLETE:
        if message.io.result >= 0 {
            // message.io.fd is the new client's FD (set by the reactor on accept).

            // Package the client FD as init args for the Connection Isolate.
            conn_args := ConnectionArgs{client_fd = message.io.fd}
            payload, size := tina.init_args_of(&conn_args)

            // Spawn the Connection Isolate.
            spec := tina.Spawn_Spec{
                type_id      = CONN_TYPE,                              // which TypeDescriptor to use
                group_id     = tina.ctx_supervision_group_id(ctx),     // same supervision group as us
                restart_type = .temporary,                             // don't restart on clean exit
                args_payload = payload,                                // serialized ConnectionArgs
                args_size    = size,                                   // byte count
                handoff_fd   = message.io.fd,                          // transfer FD ownership
                handoff_mode = .Full,                                  // child owns both read and write
            }
            _ = tina.ctx_spawn(ctx, spec)
        }

        // Always loop back to accepting the next connection.
        return tina.Effect_Io{
            operation = tina.IoOp_Accept{listen_fd = self.listen_fd},
        }

    case:
        return tina.Effect_Receive{}
    }
}
```

> **Key point:** The Listener never stops accepting. After spawning a Connection, it immediately returns `Effect_Io{IoOp_Accept{...}}` to wait for the next client. The Connection runs independently.

---

## Step 2: Define the Connection Isolate

Each TCP connection gets its own Isolate. No shared socket table. No mutex.

```odin
package main

import tina "../src"
import "core:mem"

// ---- Type IDs (unique per Isolate type, used in TypeDescriptor and Spawn_Spec) ----
LISTENER_TYPE: u8 : 0
CONN_TYPE:     u8 : 1

// ---- Payload sent from Listener to Connection during spawn ----
ConnectionArgs :: struct {
    client_fd: tina.FD_Handle,  // the accepted socket, passed via init args
}

// ---- The Connection Isolate's state ----
// Lives in a typed arena inside the Shard. Referenced by Handle, never by pointer.
ServerConnection :: struct {
    fd:     tina.FD_Handle,  // this connection's socket
    buffer: [128]u8,         // scratch space for echoing data back
}
```

### Connection init_fn

Called once when the Isolate is spawned. Sets up the socket and parks waiting for data.

```odin
conn_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    // Cast the raw pointer to our typed struct. Debug builds verify the stride matches.
    self := tina.self_as(ServerConnection, self_raw, ctx)

    // Deserialize the init args the Listener passed during ctx_spawn.
    conn_args := tina.payload_as(ConnectionArgs, args)
    self.fd = conn_args.client_fd

    // Disable Nagle's algorithm — we want low-latency echo.
    tina.ctx_setsockopt(ctx, self.fd, .IPPROTO_TCP, .TCP_NODELAY, true)

    // Park this Isolate waiting for incoming data.
    // The scheduler wakes us when the kernel has bytes ready.
    return tina.Effect_Io{
        operation = tina.IoOp_Recv{
            fd              = self.fd,
            buffer_size_max = u32(len(self.buffer)),  // max bytes to read
        },
    }
}
```

### Connection handler_fn

Called every time a message (I/O completion, user message, or system signal) arrives.

```odin
conn_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(ServerConnection, self_raw, ctx)

    switch message.tag {

    // ---- Kernel finished reading bytes from the socket ----
    case tina.IO_TAG_RECV_COMPLETE:
        // message.io.result: bytes read (>0), 0 = EOF, <0 = error
        if message.io.result <= 0 {
            // EOF or error — close the socket and exit.
            return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
        }

        // Read the received data from the reactor's buffer pool.
        recv_len := u32(message.io.result)
        data := tina.ctx_read_buffer(ctx, message.io.buffer_index, recv_len)

        // Copy into our own stable buffer (the reactor buffer is freed after this handler returns).
        self.buffer = {}
        copy_len := min(recv_len, u32(len(self.buffer)))
        mem.copy(&self.buffer[0], raw_data(data), int(copy_len))

        // Echo it back. Tina does not allocate staging buffers for outbound I/O.
        // io_send computes the byte offset of self.buffer within the arena slot,
        // allowing the kernel to read directly from the Isolate's memory.
        return tina.io_send(self, self.fd, self.buffer[:copy_len])

    // ---- Kernel finished sending our echo response ----
    case tina.IO_TAG_SEND_COMPLETE:
        if message.io.result < 0 {
            // Send failed — close and exit.
            return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
        }
        // Send succeeded — go back to reading.
        return tina.Effect_Io{
            operation = tina.IoOp_Recv{
                fd              = self.fd,
                buffer_size_max = u32(len(self.buffer)),
            },
        }

    // ---- Socket close completed ----
    case tina.IO_TAG_CLOSE_COMPLETE:
        // Return Done to tell the supervisor this Isolate has finished cleanly.
        return tina.Effect_Done{}

    // ---- Anything else (e.g., user messages) — ignore and wait ----
    case:
        return tina.Effect_Receive{}
    }
}
```

**The read → echo → read loop:**

```
  IoOp_Recv ──▶ IO_TAG_RECV_COMPLETE ──▶ io_send ──▶ IO_TAG_SEND_COMPLETE ──▶ IoOp_Recv ──▶ ...
       │                                                                            │
       └────────────────────────────── the loop ────────────────────────────────────┘
```

---

## Step 3: Wire the Boot Spec

Register the types, define the supervision tree, and start the system.

```odin
import "core:fmt"

main :: proc() {
    // ---- 1. Register Isolate types ----
    // Each TypeDescriptor tells the framework how much memory to reserve,
    // which functions to call, and how many Isolates of this type can exist.
    types := [2]tina.TypeDescriptor{
        {
            id               = LISTENER_TYPE,               // matches LISTENER_TYPE constant
            slot_count       = 1,                            // only one listener per shard
            stride           = size_of(ServerListener),      // bytes per Isolate instance
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn          = listener_init,                // called on spawn
            handler_fn       = listener_handler,             // called on every message
            mailbox_capacity = 16,                           // max queued messages
        },
        {
            id               = CONN_TYPE,
            slot_count       = 64,                           // up to 64 concurrent connections
            stride           = size_of(ServerConnection),
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn          = conn_init,
            handler_fn       = conn_handler,
            mailbox_capacity = 16,
        },
    }

    // ---- 2. Define the supervision tree ----
    // Static children are spawned automatically when the Shard boots.
    children := [1]tina.Child_Spec{
        tina.Static_Child_Spec{
            type_id      = LISTENER_TYPE,   // spawn one Listener at boot
            restart_type = .permanent,      // always restart if it crashes
        },
    }

    // ---- 3. Define Shard specs ----
    // One Shard = one OS thread = one CPU core.
    shard_specs := [1]tina.ShardSpec{
        {
            shard_id    = 0,
            target_core = -1,  // let the OS pick the core
            root_group  = tina.Group_Spec{
                strategy              = .One_For_One,   // restart only the crashed child
                restart_count_max     = 5,              // max 5 restarts...
                window_duration_ticks = 10_000,         // ...within 10,000 ticks
                children              = children[:],
                child_count_dynamic_max = 64,           // room for dynamically spawned Connections
            },
        },
    }

    // ---- 4. System-wide configuration ----
    spec := tina.SystemSpec{
        shard_count               = 1,
        types                     = types[:],
        shard_specs               = shard_specs[:],
        timer_resolution_ns       = 1_000_000,       // 1ms timer resolution
        pool_slot_count           = 4096,             // message envelope pool
        timer_spoke_count         = 1024,
        timer_entry_count         = 1024,
         log_ring_size             = 65536, // Logging Subsystem buffer size (power of 2)
        default_ring_size         = 32,               // cross-shard channel size
        scratch_arena_size        = 65536,
        fd_table_slot_count       = 128,              // max open file descriptors per shard
        fd_entry_size             = size_of(tina.FD_Entry),
        supervision_groups_max    = 16,
        reactor_buffer_slot_count = 128,              // I/O buffer pool slots
        reactor_buffer_slot_size  = 4096,             // 4KB per I/O buffer
        transfer_slot_count       = 32,
        transfer_slot_size        = 4096,
        shutdown_timeout_ms       = 3_000,            // 3 seconds for graceful shutdown
    }

    // ---- 5. Start the system ----
    fmt.println("Starting TCP echo server on 127.0.0.1:9090...")
    tina.tina_start(&spec)  // blocks forever (runs the scheduler loop)
}
```

---

## Step 4: Build and Run

```sh
odin build examples/example_tcp_echo.odin -file -out:tina_echo
./tina_echo
```

Test it:

```sh
# In another terminal
echo "hello" | nc 127.0.0.1 9090
```

Stop it with `Ctrl+C` (sends SIGINT → graceful shutdown).

---

## What Happens When Things Go Wrong

| Failure | What Tina Does |
|---|---|
| Connection Isolate crashes (bad data, bug) | Trap boundary catches it. Supervisor sees `restart_type = .temporary` → does **not** restart. Teardown closes the socket. |
| Listener Isolate crashes | Supervisor sees `restart_type = .permanent` → restarts it. New socket, new bind, new listen. Existing connections are unaffected. |
| Too many restarts in the window | Shard gets quarantined. Other Shards keep serving. |

The key insight: each Connection is its own fault domain. One bad client cannot take down the server.
