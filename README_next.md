# Tina - Designed For Massive Concurrency, Safety, Fault-tolerance

**A strictly bounded, thread-per-core concurrency framework for Odin.**
> Write simple, synchronous-looking state machines. Get massive multi-core throughput, automatic fault isolation, and 100% deterministic simulation testing.

[![Odin Version](https://img.shields.io/badge/Odin-2026-blue)](#)
[![License](https://img.shields.io/badge/License-Apache%202.0-green)](./LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/Dependencies-0-orange)](#)

## A Simple TCP Echo Server

In Tina, you don't write colored `async/await` functions, and you don't lock mutexes. You write **Isolates** — lightweight state machines that react to messages and return **Effects**. The framework handles the rest.

Here's a complete, non-blocking TCP echo handler. Notice what *isn't* here: no allocations, no locks, no callbacks, no colored functions.

```odin
// Each connection is its own Isolate — no shared socket table, no lock.
EchoConnection :: struct {
    fd:     tina.FD_Handle,
    buffer: [128]u8,
}

// Initialize: set TCP_NODELAY and wait for data.
echo_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(EchoConnection, self_raw, ctx)
    conn := tina.payload_as(ConnectionArgs, args)
    self.fd = conn.client_fd

    tina.ctx_setsockopt(ctx, self.fd, .IPPROTO_TCP, .TCP_NODELAY, true)

    return tina.Effect_Io{operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = size_of(self.buffer)}}
}

// Handle I/O completions. Read → echo back → read again. If anything fails: let it crash.
echo_handler :: proc(self_raw: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
    self := tina.self_as(EchoConnection, self_raw, ctx)

    switch message.tag {
    case tina.IO_TAG_RECV_COMPLETE:
        if message.io.result <= 0 { return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}} }
        data := tina.ctx_read_buffer(ctx, message.io.buffer_index, u32(message.io.result))
        copy(self.buffer[:], data)
        return tina.io_send(self, self.fd, self.buffer[:len(data)])

    case tina.IO_TAG_SEND_COMPLETE:
        if message.io.result < 0 { return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}} }
        return tina.Effect_Io{operation = tina.IoOp_Recv{fd = self.fd, buffer_size_max = size_of(self.buffer)}}

    case tina.IO_TAG_CLOSE_COMPLETE:
        return tina.Effect_Done{}

    case:
        return tina.Effect_Receive{}
    }
}
```

If this Isolate crashes — or *segfaults* — the Shard's trap boundary catches the fault, wipes the Isolate, and the supervisor restarts it. The other Isolates on the same core never notice.

![tcp echo demo](media_assets/tcp_echo.gif)

## Design Constraints

Tina achieves C-level performance and Erlang-level reliability by strictly limiting what you can do. Architecture solves problems better than language features.

*   🚫 **No Garbage Collection.** Memory is managed via typed arenas and Shard-owned pools. No GC pauses, no manual `free()`. Lifetimes are structurally guaranteed.
*   🚫 **No `async` / `await`.** Colored functions fragment ecosystems. Tina uses a cooperative user-space scheduler. Handlers are standard functions that return `Effect` values.
*   🚫 **No Mutexes. Shared-Nothing.** Tina runs thread-per-core. Isolates never share memory. All cross-core communication uses lock-free SPSC ring buffers.
*   🚫 **No Hidden Allocations.** All memory is sized and pre-allocated at startup via a static boot spec. If your workload exceeds capacity, Tina sheds load predictably rather than OOM-crashing.
*   ✅ **100% Deterministic Simulation.** The clock, network, and I/O are abstracted behind the scheduler. Tina supports TigerBeetle-style Deterministic Simulation Testing. *Same seed + same config = same execution, every time.*

## Architecture at a Glance

```
┌──────────────────────────────────────────┐  ┌──────────────────────────────────────────┐
│            SHARD 0 (Core 0)              │  │            SHARD 1 (Core 1)              │
│                                          │  │                                          │
│  ┌──────────────────────────────────┐    │  │    ┌──────────────────────────────────┐  │
│  │  Typed Arenas (per Isolate type) │    │  │    │  Typed Arenas (per Isolate type) │  │
│  │  [Session][Session][Session]...  │    │  │    │  [Timer][Timer][Timer]...        │  │
│  └──────────────────────────────────┘    │  │    └──────────────────────────────────┘  │
│                                          │  │                                          │
│  Scheduler (smart & adaptive batching)   │  │    Scheduler (smart & adaptive batching) │
│  Message Pool (128-byte envelopes)       │  │    Message Pool (128-byte envelopes)     │
│  I/O Reactor (kqueue / io_uring / IOCP)  │  │    I/O Reactor (kqueue / io_uring / IOCP)│
│  Timer Wheel · Logging · Supervision     │  │    Timer Wheel · Logging · Supervision   │
│                                          │  │                                          │
└─────────────────┬────────────────────────┘  └────────────────────────┬─────────────────┘
                  │                    Mailboxes                       │
                  └────────────────────────────────────────────────────┘
                        Lock-free cross-core messaging
```

**Shards** are OS threads, one per CPU core, pinned permanently. Each Shard owns everything it touches: arenas, scheduler, mailboxes, I/O reactor, and timers. Shards share no memory.

**Isolates** are typed structs living in dense, cache-friendly arenas inside a Shard. They are referenced by generational handles (never raw pointers), executed by the scheduler via handler functions, and can be safely invalidated without dangling references.

**SPSC Rings** are the only way data crosses core boundaries — single-producer, single-consumer, lock-free. No atomics on the intra-shard path. No mutexes.

**The Grand Arena** — at boot, each Shard requests one contiguous block of memory from the OS. Every Isolate, every message envelope, every I/O buffer is carved from this block. After boot, `malloc` is never called.

## Deterministic Simulation Testing

Because Tina controls the clock, the network, and the I/O, you can simulate network partitions, dropped messages, and disk failures on a single thread with a reproducible seed.

This is the same technique used by [TigerBeetle](https://tigerbeetle.com/) and [FoundationDB](https://www.youtube.com/watch?v=4fFDFbi3toc) to find bugs that stress tests miss. In simulation mode, the Effect interpreter is swapped — `.io` returns canned completions, time advances deterministically. Your Isolate code is identical in both modes.

**Same seed + same config = same execution order.** Every race condition, every edge case, reproducible on demand. See the [full DST guide](./src/README_DST.md) for writing simulation tests, configuring fault injection, and reproducing failures.

## Quickstart

```sh
# Clone
git clone https://github.com/pmbanugo/tina.git && cd tina

# Build and run the TCP echo example (two shards, fault injection, supervisor recovery)
odin build examples/example_tcp_echo.odin -file -out:tina_echo
./tina_echo

# Build and run the task dispatcher (workers crash, supervisors restart them)
odin build examples/example_task_dispatcher.odin -file -out:tina_dispatch
./tina_dispatch
```

The echo example runs a two-shard TCP server. A chaos client crashes after a few round-trips, so you can watch the supervisor restart it while the other shard keeps serving. See [`/examples`](./examples) for full walkthroughs and compile-time knobs.

## Documentation

| Document | What it covers |
|---|---|
| [`examples/`](./examples) | Runnable examples with detailed walkthroughs |
| [`src/README_DST.md`](./src/README_DST.md) | Deterministic Simulation Testing — writing tests, fault injection, checkers, reproducing failures |

## Production Readiness & Status

**Status: Alpha.**

Tina is in an early but functional state. The core architecture is implemented and working:

- ✅ Thread-per-core scheduler with budget-batched execution
- ✅ Fault isolation (trap boundary catches panics *and* segfaults)
- ✅ Supervision trees with restart budgets and shard quarantine
- ✅ Async I/O via kqueue (macOS), io_uring (Linux), and IOCP (Windows)
- ✅ Cross-shard SPSC messaging
- ✅ Two working examples demonstrating fault recovery under load
- ✅ Deterministic simulation testing with fault injection, structural checkers, and seed-based replay
- 🚧 Documentation beyond examples and design notes

Tested primarily on macOS (Apple Silicon). CI tests pass on Linux. If you find a bug, open an issue. If you want to discuss the design, open a GitHub Discussion.

## Inspirations & Acknowledgments

Tina did not invent its ideas. It synthesizes them:

| Idea | Source |
|---|---|
| Supervision trees, "Let it Crash", Error Kernel | Joe Armstrong — Erlang/OTP |
| Thread-per-core, shared-nothing, reactor loop | Seastar — ScyllaDB |
| Deterministic simulation testing, static allocation, Tiger Style | TigerBeetle — FoundationDB |
| Ring buffer design, mechanical sympathy | Martin Thompson — LMAX Disruptor, Aeron |
| Memory Lifetimes | Casey Muratori |
| Pool allocators, intrusive free lists | Ginger Bill |

## Following the Build

I'm writing about the engineering decisions behind Tina — the tradeoffs, the influences, and the ideas that didn't make it.

→ [pmbanugo.me](https://pmbanugo.me)

## License

[Apache 2.0](./LICENSE)
