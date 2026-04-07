# Designing Shard Topologies

Map your application to Shards. One Shard = one OS thread = one CPU core. The boot spec defines the topology at startup. It is immutable after `tina_start()`.

Three hard constraints shape every topology:

- `ctx_spawn()` is Shard-local only. Always.
- Isolates do not migrate between Shards. Ever.
- Cross-shard messaging uses lock-free channels with bounded capacity.

Three patterns cover the design space.

---

## Pattern 1: Symmetric (SO_REUSEPORT)

Every Shard runs its own Listener + Worker pool. Each Shard binds to the same port using `SO_REUSEPORT`. The kernel distributes incoming connections across Shards. No cross-shard messaging needed for connection handling.

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│    Shard 0      │  │    Shard 1      │  │    Shard 2      │
│                 │  │                 │  │                 │
│  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │
│  │ Listener  │  │  │  │ Listener  │  │  │  │ Listener  │  │
│  │ :8080     │  │  │  │ :8080     │  │  │  │ :8080     │  │
│  └─────┬─────┘  │  │  └─────┬─────┘  │  │  └─────┬─────┘  │
│        │        │  │        │        │  │        │        │
│  ┌─────▼─────┐  │  │  ┌─────▼─────┐  │  │  ┌─────▼─────┐  │
│  │ Workers   │  │  │  │ Workers   │  │  │  │ Workers   │  │
│  └───────────┘  │  └──└───────────┘  │  └──└───────────┘  │
└─────────────────┘  └─────────────────┘  └─────────────────┘
       ▲                    ▲                    ▲
       └────────────────────┴────────────────────┘
              kernel distributes connections
```

### Listener Init with SO_REUSEPORT

The Listener on each Shard sets both `SO_REUSEADDR` and `SO_REUSEPORT` before binding. The kernel then load-balances incoming connections across all Shards.

```odin
package main

import tina "../src"
import "core:fmt"

LISTENER_TYPE: u8 : 0
WORKER_TYPE:   u8 : 1

SymmetricListener :: struct {
    listen_fd: tina.FD_Handle,
}

symmetric_listener_init :: proc(
    self_raw: rawptr,
    args: []u8,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(SymmetricListener, self_raw, ctx)

    fd, err := tina.ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
    if err != .None {
        return tina.Effect_Crash{reason = .Init_Failed}
    }
    self.listen_fd = fd

    // Both flags required for symmetric topology.
    // SO_REUSEADDR: avoid TIME_WAIT on restart.
    // SO_REUSEPORT: allow multiple Shards to bind the same port.
    tina.ctx_setsockopt(ctx, self.listen_fd, .SOL_SOCKET, .SO_REUSEADDR, true)
    tina.ctx_setsockopt(ctx, self.listen_fd, .SOL_SOCKET, .SO_REUSEPORT, true)

    tina.ctx_bind(ctx, self.listen_fd, tina.ipv4(0, 0, 0, 0, 8080))
    tina.ctx_listen(ctx, self.listen_fd, 128)

    return tina.Effect_Io{
        operation = tina.IoOp_Accept{listen_fd = self.listen_fd},
    }
}
```

### Boot Spec

Each `ShardSpec` has the same `root_group`. Every Shard is identical.

```odin
// Static children: one Listener per Shard, spawned at boot.
children := [1]tina.Child_Spec{
    tina.Static_Child_Spec{
        type_id      = LISTENER_TYPE,
        restart_type = .permanent,
    },
}

// Build N identical ShardSpecs — one per core.
SHARD_COUNT :: 4

shard_specs: [SHARD_COUNT]tina.ShardSpec
for i in 0 ..< SHARD_COUNT {
    shard_specs[i] = tina.ShardSpec{
        shard_id   = u8(i),
        target_core = i32(i),
        root_group = tina.Group_Spec{
            strategy              = .One_For_One,
            restart_count_max     = 5,
            window_duration_ticks = 10_000,
            children              = children[:],
            child_count_dynamic_max = 256,  // room for accepted connections
        },
    }
}

spec := tina.SystemSpec{
    shard_count       = SHARD_COUNT,
    types             = types[:],
    shard_specs       = shard_specs[:],
    // ... remaining SystemSpec fields ...
}
tina.tina_start(&spec)
```

**When to use:** Stateless services, protocol gateways, edge proxies. Each connection is self-contained — no need to route to a specific Shard.

---

## Pattern 2: Asymmetric (Network Shard + Compute Shards)

One Shard (Shard 0) runs the Listener and accepts all connections. It routes work to Compute Shards via cross-shard messaging using `key_to_shard(key, shard_count)`. Compute Shards run Workers only.

```
┌────────────────────┐
│      Shard 0       │
│   (Network Shard)  │
│                    │
│  ┌──────────────┐  │
│  │   Listener   │  │
│  └──────┬───────┘  │
│         │          │
│  ┌──────▼───────┐  │         cross-shard
│  │    Router    │──┼────────────────────────────────┐
│  └──────────────┘  │                                │
└────────────────────┘                                │
                                                      │
          ┌───────────────────────────────────────────┤
          │                    │                       │
          ▼                    ▼                       ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│     Shard 1      │  │     Shard 2      │  │     Shard 3      │
│  (Compute Shard) │  │  (Compute Shard) │  │  (Compute Shard) │
│                  │  │                  │  │                  │
│  ┌────────────┐  │  │  ┌────────────┐  │  │  ┌────────────┐  │
│  │Coordinator │  │  │  │Coordinator │  │  │  │Coordinator │  │
│  └────────────┘  │  │  └────────────┘  │  │  └────────────┘  │
│  ┌────────────┐  │  │  ┌────────────┐  │  │  ┌────────────┐  │
│  │  Workers   │  │  │  │  Workers   │  │  │  │  Workers   │  │
│  └────────────┘  │  └──└────────────┘  │  └──└────────────┘  │
└──────────────────┘  └──────────────────┘  └──────────────────┘
```

### Routing Work to a Compute Shard

After accepting a connection, the Router on Shard 0 determines the target shard via `key_to_shard` and sends work there.

```odin
APP_TAG_WORK_REQUEST: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1

// Message sent from Router to a Worker on a Compute Shard.
WorkRequest :: struct {
    client_id:  u64,
    client_fd:  tina.FD_Handle,
    request_id: u32,
}

Router :: struct {
    // Handles to the Coordinator on each Compute Shard.
    // Populated from init args or a registry during boot.
    coordinators: [4]tina.Handle,
    shard_count:  u8,
}

router_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(Router, self_raw, ctx)

    switch message.tag {

    case tina.IO_TAG_ACCEPT_COMPLETE:
        if message.io.result >= 0 {
            // Determine which Compute Shard owns this client.
            client_id := u64(message.io.fd)  // use FD as a simple key
            target := tina.key_to_shard(client_id, self.shard_count)

            // Send work to the Coordinator on the target Shard.
            req := WorkRequest{
                client_id  = client_id,
                client_fd  = message.io.fd,
                request_id = u32(client_id & 0xFFFF_FFFF),
            }
            _ = tina.ctx_send(ctx, self.coordinators[target], APP_TAG_WORK_REQUEST, &req)
        }
        // Keep accepting.
        return tina.Effect_Io{
            operation = tina.IoOp_Accept{listen_fd = /* listen_fd */ {}},
        }

    case:
        return tina.Effect_Receive{}
    }
}
```

### Boot Spec

Shard 0 has the Listener and Router. Shards 1..N have the Coordinator and Workers.

```odin
// Shard 0: Network Shard — Listener + Router
network_children := [2]tina.Child_Spec{
    tina.Static_Child_Spec{type_id = LISTENER_TYPE, restart_type = .permanent},
    tina.Static_Child_Spec{type_id = ROUTER_TYPE,   restart_type = .permanent},
}

// Shards 1..3: Compute Shards — Coordinator + dynamic Workers
compute_children := [1]tina.Child_Spec{
    tina.Static_Child_Spec{type_id = COORDINATOR_TYPE, restart_type = .permanent},
}

shard_specs := [4]tina.ShardSpec{
    // Shard 0: Network
    {
        shard_id   = 0,
        target_core = 0,
        root_group = tina.Group_Spec{
            strategy              = .One_For_One,
            restart_count_max     = 5,
            window_duration_ticks = 10_000,
            children              = network_children[:],
        },
    },
    // Shards 1-3: Compute
    {
        shard_id   = 1,
        target_core = 1,
        root_group = tina.Group_Spec{
            strategy              = .One_For_One,
            restart_count_max     = 5,
            window_duration_ticks = 10_000,
            children              = compute_children[:],
            child_count_dynamic_max = 128,  // Workers spawned by Coordinator
        },
    },
    {
        shard_id   = 2,
        target_core = 2,
        root_group = tina.Group_Spec{
            strategy              = .One_For_One,
            restart_count_max     = 5,
            window_duration_ticks = 10_000,
            children              = compute_children[:],
            child_count_dynamic_max = 128,
        },
    },
    {
        shard_id   = 3,
        target_core = 3,
        root_group = tina.Group_Spec{
            strategy              = .One_For_One,
            restart_count_max     = 5,
            window_duration_ticks = 10_000,
            children              = compute_children[:],
            child_count_dynamic_max = 128,
        },
    },
}
```

**When to use:** Stateful services where work must be partitioned by key — user sessions, database shards, ordered processing per key. `key_to_shard` guarantees that the same key always lands on the same Shard.

---

## Pattern 3: The Coordinator Pattern (Cross-Shard Spawning)

`ctx_spawn()` is Shard-local only. You cannot spawn an Isolate on another Shard directly. The Coordinator pattern solves this.

The protocol:

1. Each Shard that accepts dynamic children has a permanent Coordinator Isolate.
2. When Shard A needs an Isolate on Shard B, it sends a `SpawnRequest` message to Shard B's Coordinator via `Effect_Call`.
3. The Coordinator on Shard B calls `ctx_spawn()` locally and replies with the new Handle.
4. Shard A can now communicate with the new Isolate directly.

### Message Types

```odin
APP_TAG_SPAWN_REQUEST:  tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 10
APP_TAG_SPAWN_RESPONSE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 11

// Sent from any Shard to the target Shard's Coordinator.
SpawnRequest :: struct {
    type_id:    u8,       // which TypeDescriptor to instantiate
    client_id:  u64,      // key that determined this Shard (for logging/debug)
    client_fd:  tina.FD_Handle,  // FD to hand off to the new Isolate
}

// Reply from the Coordinator back to the requester.
SpawnResponse :: struct {
    handle: tina.Handle,  // Handle of the newly spawned Isolate, or HANDLE_NONE on failure
}
```

### The Coordinator Isolate

A permanent Isolate on each Compute Shard. Receives `SpawnRequest` messages and spawns children locally.

```odin
COORDINATOR_TYPE: u8 : 2

Coordinator :: struct {}

coordinator_init :: proc(
    self_raw: rawptr,
    args: []u8,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    // No setup needed. Park and wait for spawn requests.
    return tina.Effect_Receive{}
}

coordinator_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {

    switch message.tag {

    case APP_TAG_SPAWN_REQUEST:
        // Deserialize the request from the caller's payload.
        req := tina.payload_as(SpawnRequest, message.user.payload[:message.user.payload_size])

        // Spawn the child locally on this Shard.
        spec := tina.Spawn_Spec{
            type_id      = req.type_id,
            group_id     = tina.ctx_supervision_group_id(ctx),
            restart_type = .temporary,
            handoff_fd   = req.client_fd,
            handoff_mode = .Full,
        }
        result := tina.ctx_spawn(ctx, spec)

        // Build the response.
        resp: SpawnResponse
        switch h in result {
        case tina.Handle:
            resp.handle = h
        case tina.Spawn_Error:
            resp.handle = tina.HANDLE_NONE
        }

        // Reply to the caller. This completes the caller's Effect_Call.
        reply_msg: tina.Message
        reply_msg.tag = APP_TAG_SPAWN_RESPONSE
        reply_msg.user.payload_size = size_of(SpawnResponse)
        (cast(^SpawnResponse)&reply_msg.user.payload)^ = resp

        return tina.Effect_Reply{message = reply_msg}

    case tina.TAG_SHUTDOWN:
        return tina.Effect_Done{}

    case:
        return tina.Effect_Receive{}
    }
}
```

### Requesting a Remote Spawn

The requesting Isolate (e.g., a Router on Shard 0) uses `Effect_Call` with a timeout. The call blocks the Isolate until the Coordinator replies or the timeout fires.

```odin
request_remote_spawn :: proc(
    coordinator_handle: tina.Handle,
    type_id: u8,
    client_id: u64,
    client_fd: tina.FD_Handle,
) -> tina.Effect {
    // Build the request message.
    req := SpawnRequest{
        type_id   = type_id,
        client_id = client_id,
        client_fd = client_fd,
    }

    call_msg: tina.Message
    call_msg.tag = APP_TAG_SPAWN_REQUEST
    call_msg.user.payload_size = size_of(SpawnRequest)
    (cast(^SpawnRequest)&call_msg.user.payload)^ = req

    // Issue the call. The scheduler parks this Isolate until
    // the Coordinator replies or the timeout expires.
    return tina.Effect_Call{
        to      = coordinator_handle,
        message = call_msg,
        timeout = 5000,  // 5 seconds — spawns should be fast
    }
}
```

Handle the response in the caller's handler:

```odin
case APP_TAG_SPAWN_RESPONSE:
    resp := tina.payload_as(SpawnResponse, message.user.payload[:message.user.payload_size])
    if resp.handle != tina.HANDLE_NONE {
        // Success — communicate with the new Isolate directly.
        _ = tina.ctx_send(ctx, resp.handle, APP_TAG_START_WORK, &work_payload)
    }
    // Continue normal operation.
    return tina.Effect_Receive{}

case tina.TAG_CALL_TIMEOUT:
    // Coordinator didn't respond in time. Shard may be overloaded or quarantined.
    // Shed load — refuse the connection.
    return tina.Effect_Receive{}
```

Use `key_to_shard` to decide which Coordinator to target:

```odin
target_shard := tina.key_to_shard(client_id, shard_count)
coordinator  := coordinator_handles[target_shard]
return request_remote_spawn(coordinator, WORKER_TYPE, client_id, client_fd)
```

---

## Choosing Your Topology

| Workload | Pattern | Why |
|---|---|---|
| Stateless, uniform | Symmetric | No routing overhead, linear scaling |
| Stateful, key-partitioned | Asymmetric | Data locality, ordered processing per key |
| Mixed | Hybrid | Listeners symmetric, compute asymmetric |

A hybrid topology combines both patterns. Each Shard runs its own Listener (symmetric), but routes stateful work to key-partitioned Compute Shards (asymmetric). The Listener accepts and does protocol parsing locally; the parsed request is forwarded to the correct Compute Shard via `key_to_shard`.

---

## Tradeoffs Accepted

**SO_REUSEPORT depends on kernel support.** Linux 3.9+, macOS, FreeBSD. Not available on all platforms. If your target lacks `SO_REUSEPORT`, use the Asymmetric pattern with a single Listener Shard.

**Asymmetric topologies introduce cross-shard messaging latency.** The cost is one scheduler tick per hop. For most workloads this is sub-microsecond. Measure before optimizing.

**The Coordinator pattern adds one `.call` round-trip per remote spawn.** This is acceptable because spawns are rare relative to message processing. A spawn happens once per connection or session; messages flow thousands of times per second after that.

**No runtime rebalancing.** If traffic shifts, redeploy with a new boot spec. The operator knows the workload shape. The boot spec (`SystemSpec` with `shard_specs`) defines the topology at startup. It is immutable after `tina_start()`.
