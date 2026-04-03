# Tina - Erlang's fault tolerance. System-level performance. No VM, no GC, no async/await.

Tina is a thread-per-core concurrency engine built in Odin, inspired by Erlang's supervision and Seastar's hardware sympathy. It is designed for **Safety, Performance, Simplicity and Predictability**. There is no `async/await`, no hidden mutexes, no garbage collector pausing your threads.

Instead, Tina enforces strict physical laws on your software. You trade the illusion of "easy" concurrency for actual, deterministic control over your hardware and fault boundaries.

[![asciicast](https://asciinema.org/a/WdF4hD8OLTEV2M8n.svg)](https://asciinema.org/a/WdF4hD8OLTEV2M8n)

*↑ Three workers. Every 5th job intentionally panics one of them. Watch the Supervisor catch the fault, 
tear down the Isolate, and restart it — while the others never pause. 
This is not a demo mode. This is just how Tina works today, and you can [try it](./examples).*

## The Laws of Physics in Tina:
1. **Thread-per-Core (Shared-Nothing):** Each core is an isolated Shard. Cores communicate exclusively via messaging. 
2. **Static Allocation:** Zero dynamic memory allocation on the hot path.
3. **Let It Crash:** You do not write defensive spaghetti code. If an Isolate panics, the framework's Trap Boundary catches it, tears it down, and the Supervisor restarts it in microseconds. 
4. **Synchronous-Looking Handlers:** No colored functions. No promise chaining. You write asynchonous code like they're regular synchronous functions

## The Architecture

### 1. The Shard — One Core, One Thread, No Sharing
Each CPU core runs exactly one OS thread, pinned permanently (optional). Shards share no memory. 
Cross-shard communication happens exclusively via messaging and pre-allocated mailboxes.

### 2. The Isolate — A unit of work and smallest unit of isolation
Isolates are lightweight, typed state machines that live inside a Shard. They receive a message, return an Effect, and exit. 
If one panics — or segfaults — the Shard's **Trap Boundary** catches the fault, wipes the Isolate's memory, and notifies the Supervisor, then it is rebuilt in microseconds. 

> In Erlang, a C extension (NIF) segfault kills the entire VM. Those exceptional cases in the BEAM are safe in Tina.

### 3. The Grand Arena — Pre-Allocate the Universe, Then Never Call malloc
At boot, each Shard requests one block of memory from the OS. Every Isolate, every message pool, every I/O buffer is carved from this space.
If memory runs out, the system applies structural backpressure — it does not crash.

## Tina Is Not For You If...

- You want a the status-quo async ecosystem → use Tokio, Node.js 
- You're building a quick script or service → use Go  
- You want hidden magic to handle concurrency for you → use anything else  

**Tina is for engineers who are tired of invisible state machines, unpredictable latency spikes, and systems that collapse because one background task panicked.**

## How to Understand Tina

Go to [`/examples`](./examples). Run the **TCP Echo Chaos Test** or Job scheduler, and read what the logs are telling you. 
That is the fastest path to understanding what Tina does and why it is structured the way it is.

[![asciicast](https://asciinema.org/a/x3ysgs51MXyaQntr.svg)](https://asciinema.org/a/x3ysgs51MXyaQntr)

👉 **[Read the Examples README](./examples/README.md)**

The documentation is but the engine is at a stable and usable state. So feel free to play with the code, open discussions here on GitHub if you need help or have questions

## Following the Build

I'm writing about the engineering decisions behind Tina — the tradeoffs, the influences, and the ideas that didn't make it.

Go to → [pmbanugo.me](https://pmbanugo.me) — subscribe if you want to follow along.

## Prior Art & Influences

Tina did not invent its ideas. It synthesizes them:

| Idea | Source |
|---|---|
| Supervision trees & Let It Crash | Joe Armstrong / Erlang OTP |
| Thread-per-core, shared-nothing | Seastar / ScyllaDB |
| Deterministic simulation testing | TigerBeetle / FoundationDB |
| Static allocation | TigerBeetle |
