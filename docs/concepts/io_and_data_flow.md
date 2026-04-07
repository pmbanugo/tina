# I/O, Buffers & Data Transfer

**Isolates never call syscalls directly — they return `Effect_Io` values, and the scheduler submits I/O to the platform's completion engine. All framework-provided data (reactor buffers, transfer buffers) is valid for one handler call only — copy what you need, the scheduler reclaims the rest.**

## The I/O Model

Isolates never call syscalls. They never touch file descriptors directly. They return an `Effect_Io{operation}` value, and the scheduler handles the rest.

This abstraction is not just for ergonomics — it's the simulation seam. In production, the scheduler submits I/O to the platform's completion engine (`io_uring` on Linux, `kqueue` on macOS/BSD, `IOCP` on Windows). In simulation mode, the scheduler returns scripted completions from a deterministic engine. The Isolate code is identical in both modes.

The I/O cycle:

```
Handler returns Effect_Io{IoOp_Recv{fd, buffer_size_max}}
        │
        ▼
Scheduler parks Isolate in WAITING_FOR_IO
        │
        ▼
Reactor submits to platform (io_uring/kqueue/IOCP)
        │
        ▼
Completion arrives → data written to reactor buffer pool
        │
        ▼
Scheduler wakes Isolate, delivers completion via message
        │
        ▼
Handler receives message with tag IO_TAG_RECV_COMPLETE
    message.io.result = bytes read
    message.io.buffer_index = where the data lives
```

**One I/O operation at a time.** An Isolate parked on I/O cannot submit another until the current one completes. This mirrors the `.call` pattern — one outstanding request per Isolate. If you need concurrent I/O (e.g., full-duplex read and write), decompose into multiple cooperating Isolates.

## The One Rule

Both reactor buffers and transfer buffers follow the same lifecycle principle:

> **Framework-provided data is available during this handler call only. Copy what you need.**

When your handler receives I/O completion data via `ctx_read_buffer()`, that data lives in the reactor's buffer pool — not in your Isolate's memory. When the handler returns, the scheduler reclaims the buffer slot. The same applies to `ctx_transfer_read()` — the transfer slot is freed when the handler returns.

This is a structural safety guarantee:
- **No leaked buffers.** If the handler crashes (panic or segfault), the scheduler reclaims the buffer during teardown. No manual cleanup path required.
- **Deterministic pool pressure.** Buffer slots cycle back to the free list every tick, keeping pool occupancy predictable.
- **One mental model.** Whether you're reading network data or a large payload from another Isolate, the pattern is the same: read → copy what you need → the framework handles the rest.

## Reactor Buffers: I/O Data

When an I/O read operation completes, the data lands in a slot from the **reactor buffer pool** — a pre-allocated, Shard-owned pool of fixed-size buffers. You access the data via `ctx_read_buffer()`:

```odin
case tina.IO_TAG_RECV_COMPLETE:
    if message.io.result <= 0 {
        // EOF or error
        return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.fd}}
    }

    // Read the data from the reactor buffer pool.
    // This slice is valid ONLY during this handler invocation.
    recv_len := u32(message.io.result)
    data := tina.ctx_read_buffer(ctx, message.io.buffer_index, recv_len)

    // Copy what you need into your Isolate's own memory.
    // After this handler returns, the reactor buffer slot is freed.
    mem.copy(&self.buffer[0], raw_data(data), int(recv_len))

    // Now self.buffer contains your data — it persists across handler calls.
    return tina.io_send(self, self.fd, self.buffer[:recv_len])
```

**Why reactor-owned buffers?** If an Isolate crashes while I/O is in flight, the kernel (via io_uring or DMA) is still actively writing to that memory address. If the buffer lived in the Isolate's arena, the kernel would silently corrupt the next Isolate spawned in that slot. Reactor-owned pools structurally prevent this memory corruption.

### For outbound data: write from your Isolate's struct

When sending data over a socket, you write to a buffer inside your Isolate struct and use `io_send()`:

```odin
// Write data into the Isolate's own buffer
copy(self.buffer[:], "hello"[:])

// io_send computes the byte offset of self.buffer within the Isolate struct.
// The reactor reads directly from the Isolate's arena slot during the write.
return tina.io_send(self, self.fd, self.buffer[:5])
```

No allocation. No copy to a staging buffer. The reactor reads directly from your struct. This works because the Isolate is parked during the I/O operation — its memory is stable.

## Transfer Buffers: Large Payloads Between Isolates

Message envelopes carry up to 96 bytes of inline payload. For most messages — a Handle (8 bytes), a request struct (20–60 bytes), a status update — this is plenty.

When you need to send more than 96 bytes to another Isolate, use the **Transfer Buffer Pool**:

```odin
// ---- Sender ----

// 1. Allocate a transfer buffer slot.
handle_result := tina.ctx_transfer_alloc(ctx)
handle, ok := handle_result.(tina.Transfer_Handle)
if !ok {
    // Pool exhausted — shed load or retry later.
    return tina.Effect_Yield{}
}

// 2. Write your large payload into the transfer slot.
tina.ctx_transfer_write(ctx, handle, &my_large_struct)

// 3. Send a small reference message to the receiver.
//    The message payload is just the Transfer_Handle (4 bytes).
_ = tina.ctx_transfer_send(ctx, target, handle)
```

```odin
// ---- Receiver ----

case tina.TAG_TRANSFER:
    // The message payload contains a Transfer_Handle.
    handle := (cast(^tina.Transfer_Handle)&message.user.payload[0])^

    // Read the large payload from the transfer buffer.
    // This slice is valid ONLY during this handler invocation.
    read_result := tina.ctx_transfer_read(ctx, handle)
    data, ok := read_result.([]u8)
    if !ok {
        // Stale handle — the transfer slot was already freed.
        return tina.Effect_Receive{}
    }

    // Copy what you need into your own state.
    mem.copy(&self.staging[0], raw_data(data), len(data))

    // After this handler returns, the transfer slot is auto-freed.
    return tina.Effect_Receive{}
```

### Transfer buffer lifecycle

```
Sender: ctx_transfer_alloc()  →  ctx_transfer_write()  →  ctx_transfer_send()
                                                                   │
                                                                   ▼
                                                          Message delivered
                                                                   │
                                                                   ▼
Receiver: ctx_transfer_read()  →  copy what you need  →  handler returns
                                                                   │
                                                                   ▼
                                                       Slot auto-freed by scheduler
```

**Key properties:**
- The transfer pool is **Shard-local only**. It lives in the Shard's Grand Arena. Cross-shard large payloads require decomposition into multiple standard messages or an application-level multipart protocol.
- Each slot has a **generation counter**. A stale `Transfer_Handle` (from a previously freed slot) is detected by `ctx_transfer_read()` and returns an error — not corrupted data.
- `ctx_transfer_read()` should be called **once per handler invocation**. The scheduler tracks which transfer slot was read and auto-frees it on handler return.

## Tradeoffs Accepted

**One I/O operation at a time per Isolate.** An Isolate parked on I/O cannot issue another I/O request until the first completes. For full-duplex protocols, decompose into a Reader Isolate and a Writer Isolate. This keeps the scheduling model simple and deterministic — no interleaved I/O state to track.

**I/O buffer data must be copied.** The reactor buffer is reclaimed after the handler returns. If you need the data across multiple handler invocations, copy it into your Isolate's struct or working arena. This is a small cost for a large structural benefit: no leaked buffers, no manual free, no crash-safety concerns.

**Transfer buffers are Shard-local.** You cannot send a Transfer_Handle to an Isolate on another Shard — the receiving Shard has no access to the sending Shard's transfer pool. For cross-shard large payloads, decompose into standard 96-byte messages with sequence numbers and reassemble on the receiver.

**Transfer pool size is fixed at boot.** Like all memory in Tina, the transfer pool is pre-allocated and bounded. If all transfer slots are in use, `ctx_transfer_alloc()` returns an error. Size the pool for the expected number of concurrent large transfers.
