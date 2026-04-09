# Tina HTTP — Design Document

**Status:** Proposed  
**Date:** 2026-04-08  
**Author:** Peter Mbanugo (with oracle advisory)

---

## 1. Architecture Overview

### 1.1 Goals

Tina HTTP is a strict HTTP/1.1 server library layered on Tina. It provides:

- Request parsing (incremental, zero-alloc)
- URL routing (compiled trie, matched by specificity)
- Response writing (corked by default, streaming, backpressure-aware)
- Request body streaming
- Timeouts (idle, header, body, drain)
- Graceful shutdown (automatic drain of in-flight requests)
- Shard-local Date header caching

### 1.2 Key Term: Cork

**Cork** means: accumulate all response bytes (status line, headers, body) into a single contiguous buffer during the handler callback, then flush everything as one `io_send` syscall when the callback returns.

The name comes from "corking a bottle" — hold back the flow, then release at once. In Tina, corking is structurally natural and is the *only* mode. A handler is a plain function that returns an `Effect`. All response writes during the handler (`status()`, `header_set()`, `end()`) are memory writes to the Isolate's egress buffer. The I/O happens *after* the return, when the scheduler interprets the `Effect_Io{IoOp_Send{...}}`. There is no "uncorked" path — issuing I/O mid-handler is not possible in Tina's Effect model.

This differs from uWebSockets, where corking is an explicit opt-in (`res->cork(lambda)`). In Tina HTTP, corking is a structural guarantee, not a performance hint.

### 1.3 Non-Goals (Never In Scope)

- TLS/SSL
- WebSocket protocol
- Compression (deflate/gzip)
- HTTP/2

Connection: Upgrade is detected as a **seam** only — no upgrade protocol is implemented.

### 1.4 High-Level Layering

```
Application handlers
    ↓
http package
  - route table (compiled trie)
  - parser (incremental, strict)
  - request/response facade
  - graceful shutdown/drain
    ↓
Tina
  - Listener Isolate(s)
  - Connection Isolate(s)
  - Timer Wheel
  - I/O Reactor
  - Shard Scheduler
```

### 1.5 Primary Runtime Shape

- **1 Listener Isolate per Shard**
- Each Shard binds the same address/port with `SO_REUSEPORT`
- Each accepted socket becomes **1 Connection Isolate on the same Shard**
- Each connection runs: recv → parse → dispatch handler → cork/send → repeat / close

This keeps the hot path:

- Single-writer per socket
- No cross-shard message on accept path
- No extra FD handoff
- No coordinator bottleneck

### 1.6 Why One Connection Isolate (Not Reader + Writer Split)

HTTP/1.1 request/response is ordered. Tina permits only one outstanding I/O per Isolate. Most server behavior is naturally: read request → maybe stream body → write response → next request.

Splitting reader/writer adds protocol coordination complexity immediately and is not justified for HTTP/1.1.

**Explicit trade-off:** True simultaneous read/write on the same connection is not a v1 goal. If the server sends a final response before fully consuming the request body, the library closes the connection after send rather than trying to keep it alive.

---

## 2. Package / Module Structure

The HTTP library is a separate Odin package (`http`) importing `tina`.

```
http/
  api.odin              — public types, builders, handler signatures
  server.odin           — Server/App config, install/bootstrap into Tina
  listener.odin         — Listener Isolate
  connection.odin       — Connection Isolate + main state machine
  router.odin           — route compilation + matching
  parser.odin           — HTTP/1.1 incremental parser
  headers.odin          — known header parsing, bloom/hash helpers
  response.odin         — status line, header encoding, chunked writer
  query.odin            — query parsing + percent decode helpers
  date_cache.odin       — shard-local Date cache
  shutdown.odin         — drain behavior
  limits.odin           — limits, timeouts, validation
  messages.odin         — internal timer/message tags
  errors.odin           — default error responses
```

### Public API Surface

- `Server`, `App`, `Route`
- Route builders: `get`, `post`, `put`, `delete`, `patch`, `head`, `options`, `any`
- `Request`, `Response`
- `Write_Result`
- `Limits`, `Timeouts`
- Query/param helpers
- `install` (wires HTTP types into a Tina SystemSpec)

### Internal (Package-Private)

- `Http_Listener`, `Http_Connection`
- `Compiled_Router`, `Parser_State`, `Response_State`
- `Date_Cache`, `Http_Shard_Runtime`

---

## 3. Isolate Types

### 3.1 `Http_Listener` — One Per Shard

**Responsibility:** create/bind/listen socket, accept connections, spawn `Http_Connection`, stop accepting on shutdown.

**Restart type:** `.permanent`

**Hot path:**
```
IoOp_Accept → IO_TAG_ACCEPT_COMPLETE → spawn conn → IoOp_Accept
```

### 3.2 `Http_Connection` — One Per Accepted Socket

**Responsibility:** own the socket, hold parser state, hold current request/response state, manage timeouts, dispatch app callbacks, send/close.

**Restart type:** `.temporary`

If it crashes, close the socket and die. Restarting a dead connection is meaningless.

### 3.4 Static Type, Dynamic Instance

Both `Http_Listener` and `Http_Connection` are **static TypeDescriptors** registered at boot via `http.install()`. The `install` function adds them to `SystemSpec.types` and wires the supervision tree. Arena slots for connections are pre-allocated in the Grand Arena at startup (bounded by `slot_count` in the TypeDescriptor — this *is* the max concurrent connection limit).

Connection **instances** are activated at runtime via `ctx_spawn`. Despite the name, `ctx_spawn` performs **no heap allocation**. Internally (`_make_isolate`), it: (1) pops a slot from the type's LIFO free list — O(1), (2) zeros the Isolate memory — `mem.zero(ptr, stride)`, (3) transfers FD ownership in the FD table if `handoff_fd` is set, (4) initializes the working memory arena pointing into the pre-allocated per-slot region, (5) calls `init_fn`, (6) interprets the returned Effect to park the Isolate. The cost is `mem.zero` + `init_fn` — the minimum work to activate any Isolate regardless of approach.

**Why not pre-spawn all connection slots as static children?** Three reasons:
1. **FD availability.** The accepted socket FD does not exist until `IO_TAG_ACCEPT_COMPLETE`. Tina's only FD handoff mechanism is `Spawn_Spec.handoff_fd` — there is no `ctx_transfer_fd` API for sending an FD to an already-running Isolate via message.
2. **Wasted resources.** Pre-spawned Isolates would occupy all slots at boot, each with an active state, mailbox overhead, and scheduling overhead (the dispatch loop checks every non-`Unallocated` slot). With `ctx_spawn`, idle slots are `Unallocated` and skipped in O(1) by the fast-path reject (`if state == .Unallocated do continue`).
3. **No benefit.** `ctx_spawn` is already effectively "activate a pre-allocated slot." The memory exists at boot. The per-activation cost is the same work any approach would require (zero + init).

The Listener is a **static child** in the supervision tree — spawned automatically when the Shard boots, `.permanent` restart type. Connections are **dynamic children** — spawned by the Listener at runtime, `.temporary` restart type, tracked in the supervision group's `dynamic_specs` for proper teardown on shutdown.

### 3.3 `Http_Coordinator` — Optional Advanced Path Only

Not built in v1. Only needed for the non-`SO_REUSEPORT` design (single listener distributing connections across Shards). Requires Tina-level cross-shard FD handoff/spawn support.

---

## 4. Core Data Structures

### 4.1 Public Configuration

```odin
Server :: struct {
    address:         tina.Socket_Address,
    backlog:         u32,
    distribution:    Distribution_Mode, // .Reuse_Port | .Coordinator
    app:             ^App,
    limits:          Limits,
    timeouts:        Timeouts,
    keepalive:       Keepalive_Config,
    graceful_drain:  u64, // ticks
}

App :: struct {
    routes: []Route,
}

Route :: struct {
    method:  Method,
    pattern: string,
    handler: Handler,
}

Distribution_Mode :: enum u8 {
    Reuse_Port,
    Coordinator,
}
```

### 4.2 Router Structures

A **compiled immutable route trie**, built once at boot.

```odin
Route_Node :: struct {
    static_begin:    u32,
    static_count:    u16,
    param_child:     u32,       // NODE_NONE if absent
    wildcard_child:  u32,       // NODE_NONE if absent
    terminal_route:  u32,       // ROUTE_NONE if absent
    methods_mask:    Method_Mask, // for 405 + Allow header
}

Static_Edge :: struct {
    segment_off: u32,
    segment_len: u16,
    child:       u32,
}

Compiled_Router :: struct {
    nodes:        []Route_Node,
    static_edges: []Static_Edge,
    strings:      []u8,           // packed segment strings
    routes:       []Route_Def_Compiled,
}
```

**Match rules:**
- Static > Parameter > Wildcard (structural priority, not insertion order)
- Wildcard must be terminal
- Routes compiled at boot; duplicate effective routes are boot errors
- HEAD checks HEAD first, then falls back to GET

### 4.3 Parser State

```odin
Parse_Phase :: enum u8 {
    Request_Line,
    Headers,
    Body_Fixed,
    Chunk_Size,
    Chunk_Data,
    Chunk_Data_CRLF,
    Trailers,
    Complete,
    Error,
}

Parser_Flags :: distinct bit_set[Parser_Flag; u16]
Parser_Flag :: enum u8 {
    Has_Content_Length,
    Has_Transfer_Encoding,
    Chunked_Request,
    Connection_Close,
    Expect_100,
    Upgrade_Request,
    Head_Method,
    Keep_Alive_Allowed,
}

Parser_State :: struct {
    phase:              Parse_Phase,
    header_bytes:       u32,
    request_line_bytes: u16,
    body_remaining:     u64,
    chunk_remaining:    u64,
    chunk_size_value:   u64,
    header_count:       u16,
    flags:              Parser_Flags,
}
```

### 4.4 Parsed Request Metadata

```odin
Header_View :: struct {
    name_off:   u32,
    name_len:   u16,
    value_off:  u32,
    value_len:  u16,
    hash:       u32,
}

Param_View :: struct {
    name_off:   u32,
    name_len:   u16,
    value_off:  u32,
    value_len:  u16,
}

Request_State :: struct {
    method:          Method,
    status_flags:    Request_Flags,
    target_off:      u32,
    target_len:      u16,
    path_off:        u32,
    path_len:        u16,
    query_off:       u32,
    query_len:       u16,
    headers_begin:   u16,
    headers_count:   u16,
    params_begin:    u8,
    params_count:    u8,
    route_index:     u32,
    header_bloom:    u64,
    peer:            tina.Peer_Address,
}
```

### 4.5 Response State

```odin
Response_Mode :: enum u8 {
    Not_Started,
    Fixed_Length,
    Chunked,
    Head_Suppressed,
    Closed,
}

Response_Flags :: distinct bit_set[Response_Flag; u8]
Response_Flag :: enum u8 {
    Headers_Committed,
    Close_After_Send,
    Backpressured,
    Aborted,
    In_Drain,
    Interim_100_Sent,
}

Response_State :: struct {
    mode:               Response_Mode,
    status_code:        u16,
    header_count:       u16,
    body_total:         u64,
    body_sent:          u64,
    egress_len:         u32,
    egress_sent:        u32,
    flags:              Response_Flags,
}
```

### 4.6 Shard-Local Runtime Sidecar

```odin
Http_Shard_Runtime :: struct {
    server:              ^Server_Runtime,
    date_cache:          Date_Cache,
    draining:            bool,
    drain_deadline_tick: u64,
}

Date_Cache :: struct {
    tick:     u64,
    len:      u8,
    bytes:    [29]u8, // RFC 7231 Date, e.g. "Sun, 06 Nov 1994 08:49:37 GMT"
}
```

Shard-local, single-thread-owned. No locking. Date is computed once per tick, reused for all responses in that tick.

### 4.7 Connection Isolate Struct

```odin
HTTP_CORK_BUFFER_SIZE :: 4096

Http_Connection :: struct {
    fd:                 tina.FD_Handle,
    shard_runtime:      ^Http_Shard_Runtime,
    state:              Conn_State,
    parser:             Parser_State,
    request:            Request_State,
    response:           Response_State,

    current_route:      u32,
    peer:               tina.Peer_Address,

    idle_deadline:      u64,
    header_deadline:    u64,
    body_deadline:      u64,
    drain_deadline:     u64,

    on_data_fn:         Data_Handler,
    on_writable_fn:     Writable_Handler,
    on_aborted_fn:      Aborted_Handler,

    request_seq:        u32, // bumps per request; helps stale timer logic
    ingress_used:       u32,
    ingress_parsed:     u32,

    egress_buffer:      [HTTP_CORK_BUFFER_SIZE]u8,
}
```

---

## 5. Memory Layout

Tina's memory model is a major advantage. This section makes explicit what lives where.

### 5.1 Isolate Struct — Hot, Persistent, Sent-From

Contains:
- Socket handle (`fd`)
- Parser phase/flags
- Current request/response state
- Deadlines
- Callback function pointers
- Route index
- **Egress cork buffer** (outbound `io_send` reads directly from stable Isolate memory)
- Small counters/offsets

**Why the egress buffer is in the Isolate struct, not working memory:** Tina's `io_send` reads directly from the Isolate's arena slot. The helper `payload_offset_of` computes a byte offset from the Isolate's base address and debug-asserts that the buffer lives within `size_of(Isolate)`. Working memory is a separate memory region that `payload_offset_of` cannot address. Placing the egress buffer in the struct enables zero-copy sends — no staging, no extra memcpy. The 4KB buffer is part of the struct's fixed size, pre-allocated in the typed arena at boot. If 1024 connection slots are configured, that is 1024 × `size_of(Http_Connection)` carved from the Grand Arena at startup — predictable, bounded, no fragmentation.

### 5.2 Working Memory — Persistent Across Handler Calls, Reset Manually

Used for:

1. **Ingress carry buffer** — partial request line/headers split across recv calls, partial chunk-size line/trailer carryover
2. **Parsed request tables** — `Header_View[]`, `Param_View[]`, lazy query parse tables
3. **Request-lifetime arena** — app per-request state, small request-scoped allocations

Suggested internal layout:
```
[ingress_bytes........]
[header_views........]
[param_views.........]
[query_views.........]
[user request arena..]
```

**Reset when the request fully completes**, not every callback.

### 5.3 Scratch Arena — Callback-Local

Used for:
- Percent-decoding
- Query decode output
- Temporary header formatting
- Short-lived app scratch

Resets every handler invocation automatically (Tina does this).

### 5.4 Reactor Buffers

Inbound recv data arrives in reactor buffers and is valid for one handler call only.

**v1 design:** Copy required bytes into working memory for parser continuity. This is the simplest correct design. Optimize direct reactor-buffer body delivery later if upload profiling justifies it.

---

## 6. Router Design

### 6.1 Boot-Time Compilation

Routes are registered at boot and compiled once into an immutable trie. No runtime mutation after start. This gives:
- No locks
- No route registration races
- Better locality
- Deterministic boot validation

### 6.2 Match Semantics

Priority is structural, not insertion order:

1. **Static** — `/users/me`
2. **Parameter** — `/users/:id`
3. **Wildcard** — `/users/*rest`

Examples:
- `/users/me` beats `/users/:id`
- `/users/:id` beats `/users/*rest`

### 6.3 Method Handling

Store terminal route method mask per node. At match time:
- Path match + method match → handler
- Path match + no method match → `405 Method Not Allowed` (generate `Allow` from method mask)
- No path match → `404 Not Found`

### 6.4 Path Handling

Route on **raw path bytes**, not percent-decoded path. This avoids ambiguity, avoids pre-route allocation, preserves exact bytes, keeps matching fast.

Decoded access is opt-in:
- `req.param_decoded(name)`
- `req.query_decoded(name)`

---

## 7. Parser Design

### 7.1 Supported Request Forms

v1 supports:
- **origin-form:** `/foo?bar=baz`
- **asterisk-form:** `*` for `OPTIONS *`

v1 rejects:
- absolute-form proxy requests
- CONNECT tunneling
- any version other than `HTTP/1.1` → `505 HTTP Version Not Supported`

### 7.2 Header Parsing Strategy

- Incremental, in-place over working-memory ingress bytes
- No heap allocations
- Header names compared case-insensitively
- Store raw slices + hash
- 64-bit bloom filter for fast negative lookup

Known headers tracked directly during parse: `host`, `content-length`, `transfer-encoding`, `connection`, `expect`, `upgrade`.

### 7.3 Request Smuggling Guardrails

- `Transfer-Encoding` + `Content-Length` together → **400 + close** (RFC 9112 §6.3)
- Duplicate `Content-Length` → **400 + close**
- Unsupported transfer-coding → **501 + close**
- obs-fold header continuation → **400 + close**
- Invalid chunk size syntax → **400 + close**

### 7.4 Body Modes

| Condition | Body Length |
|---|---|
| No `Content-Length`, no `Transfer-Encoding` | 0 |
| `Content-Length: N` | Fixed N bytes |
| `Transfer-Encoding: chunked` | Chunked: parse hex size, deliver chunks, zero-size terminates |

Trailers: parsed and discarded in v1.

---

## 8. Connection State Machine

### 8.1 Connection Lifecycle

```
Accepted
  ↓
Reading_Headers
  ↓
Dispatching_Handler
  ↓
[optional] Reading_Body
  ↓
Writing_Response
  ↓
Idle_KeepAlive → Reading_Headers
  or
Closing → Closed (Effect_Done)
```

### 8.2 State Details

**Reading_Headers:**
- Recv into reactor buffer
- Copy/append into working ingress
- Parse request line + headers
- Arm header timeout
- If incomplete → re-arm recv
- If complete → route match + handler dispatch

**Dispatching_Handler:**
- Build transient `Request`/`Response` facades
- Invoke matched route handler
- Auto-cork until callback returns

**Reading_Body:**
- Deliver `on_data(req, res, chunk, final)`
- Arm body timeout (re-arm after each progress)
- Continue until final chunk / remaining bytes = 0

**Writing_Response:**
- Send egress buffer via `io_send`
- If partial send → send remainder
- If backpressure drained and `on_writable` registered → invoke
- If response complete → next request or close

**Idle_KeepAlive:**
- Response complete
- If buffered bytes already contain next request → parse immediately
- Else arm idle timeout and issue `recv`

**Closing:**
- Close socket
- On `IO_TAG_CLOSE_COMPLETE` → `Effect_Done{}`

### 8.3 100 Continue

After headers are parsed, if `Expect: 100-continue` and body expected:
- Pause before reading body
- Route handler decides:
  - `res.continue_100()` → send interim `100 Continue`, then read body
  - Final response → send final response, close after send

---

## 9. Response Assembly / Corking

### 9.1 Default Behavior — Cork by Default

During a route callback, `res.status(...)`, `res.header(...)`, `res.end(...)` only mutate connection-local response state and append to the Isolate's egress buffer. The library issues the first `io_send` only **after the callback returns**.

This is the Tina-shaped version of uWebSockets' corking — natural because the Effect is returned at the callback boundary.

### 9.2 Egress Buffer Policy

Fixed per-connection `egress_buffer` in the Isolate struct: **4 KB**.

Enough for: status line + common headers + Date + small text/JSON bodies.

### 9.3 `end(body)` Fast Path

If headers + body fit in `egress_buffer` and no response bytes have been committed: encode full response into `egress_buffer`, issue a single `io_send`.

This is the primary fast path.

### 9.4 Response Exceeds Cork Buffer

Do **not** auto-copy arbitrarily large bodies into package-owned staging memory. Instead:
- `end(body)` — convenience for small bodies
- `try_end(body_slice, total_size)` — backpressured fixed-length path
- `write(body_slice)` — chunked streaming path

This keeps memory bounded and puts ownership of large body generation on the caller.

### 9.5 Partial Kernel Sends

`IO_TAG_SEND_COMPLETE.result` may indicate a partial send. The connection tracks `egress_sent` / `egress_len` and re-issues `io_send` with the unsent suffix from the same Isolate buffer. State advances only when fully flushed.

---

## 10. Streaming Responses / Backpressure

### 10.1 Public Semantics

| API | Behavior |
|---|---|
| `res.end(body)` | Fixed-length convenience. Copies body during call. Finishes response immediately. |
| `res.try_end(body, total_size)` | Fixed-length backpressured writer. First call fixes `Content-Length`. May accept only prefix. Caller retries on `on_writable`. |
| `res.write(chunk)` | Chunked streaming. Auto-switches to `Transfer-Encoding: chunked` on first body write. May accept only prefix. |
| `res.end_stream()` | Only valid in chunked mode. Writes final `0\r\n\r\n`. |

### 10.2 Write_Result

```odin
Write_Result :: struct {
    accepted:       int,  // bytes now owned by response stream
    backpressured:  bool, // true if caller should wait for on_writable
    finished:       bool, // true if total_size fully sent
}
```

**Contract:** Bytes after `accepted` were not consumed. Caller retains responsibility for the remainder.

### 10.3 `on_writable`

Invoked when a previously backpressured response has flushed enough to accept more bytes. It is a readiness signal, not a fairness guarantee.

---

## 11. Streaming Request Bodies

### 11.1 Public Model

```odin
Data_Handler :: #type proc(req: ^Request, res: ^Response, chunk: []u8, final: bool)
```

Behavior:
- Zero or more callbacks, in-order delivery
- `final=true` exactly once on successful completion
- Chunk slice valid only for that callback
- If client aborts early, no final callback — `on_aborted` fires instead

### 11.2 Simplification

While streaming a request body, the connection remains in **read phase**. The library does not try to simultaneously read request body and stream an arbitrary response on the same connection in v1.

Allowed:
- `100 Continue`
- Read body fully, then respond
- Reject early with final response, then close after send

Not supported as keep-alive:
- Send final response and continue reusing the connection without fully consuming body

---

## 12. Public API Surface

### 12.1 Handler Signatures

```odin
Handler          :: #type proc(req: ^Request, res: ^Response)
Data_Handler     :: #type proc(req: ^Request, res: ^Response, chunk: []u8, final: bool)
Writable_Handler :: #type proc(req: ^Request, res: ^Response)
Aborted_Handler  :: #type proc(req: ^Request)
```

### 12.2 Request API

- `method(req) -> Method`
- `path(req) -> []u8`
- `target(req) -> []u8`
- `query(req) -> []u8`
- `header(req, name) -> []u8`
- `param(req, name) -> []u8`
- `param_decoded(req, name) -> []u8` (uses scratch arena)
- `query_value(req, name) -> []u8`
- `expects_continue(req) -> bool`
- `is_head(req) -> bool`
- `is_upgrade_requested(req) -> bool`
- `peer_address(req) -> tina.Peer_Address`
- `request_arena(req) -> mem.Allocator` (request-lifetime, from working memory)
- `request_scratch(req) -> mem.Allocator` (callback-lifetime)
- `on_data(req, res, fn)`

### 12.3 Response API

- `status(res, code)`
- `header_set(res, name, value)`
- `end(res, body)`
- `try_end(res, body, total_size) -> Write_Result`
- `write(res, chunk) -> Write_Result`
- `end_stream(res)`
- `continue_100(res)`
- `close(res)`
- `on_writable(res, fn)`
- `on_aborted(res, fn)`

### 12.4 Route Builders

```odin
get     :: proc(pattern: string, handler: Handler) -> Route
post    :: proc(pattern: string, handler: Handler) -> Route
put     :: proc(pattern: string, handler: Handler) -> Route
delete  :: proc(pattern: string, handler: Handler) -> Route
patch   :: proc(pattern: string, handler: Handler) -> Route
head    :: proc(pattern: string, handler: Handler) -> Route
options :: proc(pattern: string, handler: Handler) -> Route
any     :: proc(pattern: string, handler: Handler) -> Route
```

### 12.5 Bootstrap

```odin
// Wires HTTP Isolate types and config into a Tina SystemSpec
install :: proc(spec: ^tina.SystemSpec, server: ^Server)
```

### 12.6 Example Usage

```odin
import http "../http"
import tina "../src"

health :: proc(req: ^http.Request, res: ^http.Response) {
    http.header_set(res, "content-type", "text/plain")
    http.end(res, transmute([]u8)string("ok"))
}

get_user :: proc(req: ^http.Request, res: ^http.Response) {
    id := http.param(req, "id")
    http.header_set(res, "content-type", "application/json")
    // build response using scratch arena, then end
    http.end(res, response_bytes)
}

upload :: proc(req: ^http.Request, res: ^http.Response) {
    http.on_aborted(res, proc(req: ^http.Request) { /* cleanup */ })

    if http.expects_continue(req) {
        http.continue_100(res)
    }

    http.on_data(req, res, proc(req: ^http.Request, res: ^http.Response, chunk: []u8, final: bool) {
        if final {
            http.status(res, 201)
            http.header_set(res, "content-type", "text/plain")
            http.end(res, transmute([]u8)string("uploaded"))
        }
    })
}

main :: proc() {
    app := http.App{
        routes = []http.Route{
            http.get("/health", health),
            http.get("/users/:id", get_user),
            http.post("/upload/:id", upload),
        },
    }

    server := http.Server{
        address      = tina.ipv4(0, 0, 0, 0, 8080),
        backlog      = 128,
        distribution = .Reuse_Port,
        app          = &app,
    }

    spec := tina.SystemSpec{
        // ... standard Tina config ...
    }

    http.install(&spec, &server)
    tina.tina_start(&spec)
}
```

---

## 13. Data Flow: Request Arrival → Response Completion

### 13.1 Accept Path

1. `Http_Listener.init`: socket → SO_REUSEADDR → SO_REUSEPORT → bind → listen → `IoOp_Accept`
2. `IO_TAG_ACCEPT_COMPLETE`: spawn `Http_Connection` with `handoff_fd = client_fd`, `handoff_mode = .Full`, re-arm accept

### 13.2 Read / Parse Path

1. `Http_Connection.init`: TCP_NODELAY → arm header timeout → `IoOp_Recv`
2. `IO_TAG_RECV_COMPLETE`: `result <= 0` → aborted/close. Otherwise copy bytes into working ingress → parse incrementally → if incomplete, re-arm recv → if complete, route match + handler dispatch

### 13.3 Dispatch Path

1. Build transient `Request`/`Response` facades
2. Invoke route handler
3. Handler may: `end(...)`, register `on_data`, `continue_100()`, `write(...)`, `try_end(...)`

### 13.4 Send Path

1. Encode status + headers + maybe body into `egress_buffer`
2. Return `io_send(self, fd, egress_buffer[..n])`
3. `IO_TAG_SEND_COMPLETE`: partial → send remainder. Error → aborted/close. Done → more data? continue. Backpressure cleared? `on_writable`. Response complete? next request or close.

### 13.5 Keep-Alive Path

When a request finishes:
- If `Connection: close`, draining, parse error, or early-final-before-body-consumed → close
- If ingress already holds bytes for next request → parse immediately
- Else arm idle timeout and `recv`

---

## 14. Cross-Shard Strategy

### Primary: `SO_REUSEPORT`

- Zero cross-shard traffic on accept hot path
- No coordinator bottleneck
- No cross-shard FD handoff required
- Natural fit for Tina's shard ownership model
- Single-writer per socket preserved trivially
- One Listener per Shard, same address/port, same app/router config

### Alternative (Future): Coordinator

Only if:
- Platform lacks acceptable `SO_REUSEPORT`
- Explicit distribution policy needed
- Tina gains first-class cross-shard FD handoff/spawn

Flow: one Listener accepts → choose target Shard (round-robin or hash) → hand off FD → spawn Connection on target Shard.

Not the first implementation.

---

## 15. Timeout Strategy

Use the timer wheel with **deadline fields** in the connection Isolate. Ignore stale timeout messages by comparing current tick vs. deadline.

**Recommended Tina addition:** Expose `ctx_current_tick(ctx) -> u64` as public API. This simplifies timeout stale-filtering, Date cache comparison, and drain deadline checks.

### 15.1 Idle Timeout

- Applies when connection is keep-alive idle, waiting for next request bytes
- Arm after response completion when connection remains open
- On expiry: close (no 408 for pure idle; the client sent nothing)

### 15.2 Header Timeout

- Applies from accept/next-request start until full headers parsed
- On expiry: `408 Request Timeout` + `Connection: close` + close

### 15.3 Body Timeout

- Applies from start of body read until final body byte / zero chunk parsed
- Re-arm after each successful body progress
- On expiry: `408` + close

### 15.4 Drain Timeout

- Applies once Shard/server is shutting down
- On expiry: force close active connections

---

## 16. Graceful Shutdown

The HTTP library abstracts this fully. No app code should need to manage it.

### 16.1 Listener Behavior

On shutdown:
- Stop re-arming accept
- Close listen socket
- Return `Effect_Done{}` after close completion

### 16.2 Connection Behavior

On shutdown:
- Mark `In_Drain`
- Set `Close_After_Send`
- If idle → close immediately
- If active request/response → allow completion up to drain deadline
- No new keep-alive requests after current response

### 16.3 Drain Rules

- Request not yet dispatched + shutdown → close
- Handler active + response starts → inject `Connection: close`
- Response already streaming → finish if possible before drain deadline
- After deadline → force close

---

## 17. Date Header Caching

Because Tina time advances per tick, Date caching is naturally shard-local.

### Design

Each `Http_Shard_Runtime` has a `Date_Cache`:

On response start:
1. Compare `date_cache.tick` with current tick
2. If changed: fetch wall clock once, format RFC 7231 Date once, store bytes
3. Append cached bytes to every response in that tick

### Rules

- Auto-insert `Date` unless the user already set one
- No per-response time formatting
- No locks (shard-local, single-thread-owned)

---

## 18. Error Handling / Default Responses

### Parse / Protocol Errors

| Error | Response | Connection |
|---|---|---|
| Malformed request | 400 Bad Request | Close |
| Request timeout | 408 Request Timeout | Close |
| Body too large | 413 Payload Too Large | Close |
| Headers too large | 431 Request Header Fields Too Large | Close |
| Wrong HTTP version | 505 HTTP Version Not Supported | Close |
| Unsupported transfer-coding | 501 Not Implemented | Close |

### Router Errors

| Error | Response | Connection |
|---|---|---|
| No matching path | 404 Not Found | Keep-Alive |
| Path matches, wrong method | 405 Method Not Allowed + `Allow` header | Keep-Alive |

### Internal Handler Failures

If a user handler crashes:
- The Connection Isolate dies (Tina's trap boundary catches it)
- Socket is torn down by teardown/close path
- No restart (`.temporary`)
- Other connections on the same Shard are unaffected

---

## 19. LSP Application: Explicit Public Contracts

Per Hillel Wayne's article, LSP applies to any substitution — including version evolution. Every public API function documents its preconditions and postconditions explicitly.

| API | Preconditions | Strong Postconditions | Not Guaranteed (Incidental) |
|---|---|---|---|
| `route(method, pattern, handler)` | Pattern starts with `/` or is `*`; wildcard terminal only | Boot-time validation error on violation; match precedence stable | Internal trie shape |
| `header(req, name)` | Any ASCII case name | Returns first matching raw value or empty slice; no alloc | Duplicate merge behavior |
| `param(req, name)` | Route matched with that param | Raw slice valid for request lifetime | Decoded form |
| `on_data(req, res, fn)` | Called in initial handler before body consumed | Body callbacks delivered in order; `final=true` at most once | Chunk size distribution |
| `status(res, code)` | Before headers committed | Response will use that status | Reason phrase text |
| `end(res, body)` | Response not ended | Body copied during call; full response started | Single-send fast path |
| `try_end(res, body, total)` | Fixed total known; same total on subsequent calls | Accepted prefix counted; `finished=true` only at total | Bytes accepted per call |
| `write(res, chunk)` | Response not ended | Accepted prefix queued in order as chunked | One callback per chunk |
| `on_writable(res, fn)` | Only useful after backpressure | Called when response can accept more bytes | Fairness or cadence |
| `on_aborted(res, fn)` | Before response completes | Called at most once if peer disconnects | Exact abort cause |
| `request_arena(req)` | Request active | Allocations survive across request callbacks, reset at request end | Exact offset/layout |
| `request_scratch(req)` | Current callback active | Valid until callback returns | Persistence |

### Versioning Guidance

**Safe evolution (weaker preconditions / stronger postconditions):**
- Adding optional config fields
- Adding helper methods
- Adding new route builders

**Breaking (stronger preconditions / weaker postconditions):**
- Making optional config required
- Changing response framing ownership rules
- Changing request/body lifetime guarantees

---

## 20. Trade-Offs Accepted

1. **No true full-duplex HTTP behavior.** HTTP/1.1 is ordered; one I/O at a time per Isolate is sufficient.
2. **Early final response during body upload implies close-after-send.** Simpler state machine.
3. **Large fixed-length bodies should use `try_end`, not `end`.** Keeps memory bounded.
4. **Request pipelining is serialized, not parallelized.** Correct per HTTP/1.1 semantics.
5. **Coordinator distribution is not the default.** `SO_REUSEPORT` is simpler and sufficient for Linux/macOS.
6. **Trailers parsed and discarded in v1.**

---

## 21. Risks and Guardrails

### Risks

1. **Working memory under-sizing** — headers/params/query tables may overflow
2. **User retains invalid slices** — body chunk slices or Request/Response facade pointers
3. **Timer stale messages** — unavoidable without cancel; must be ignored by deadline/state checks
4. **Large body misuse with `end()`** — may overflow cork path

### Guardrails

- Explicit limits: request-line max, headers max, header count max, params max
- Strong docs on slice lifetimes
- `end()` documented as small-body convenience
- Debug asserts for invalid API sequencing
- Strict parser on ambiguous framing (request smuggling guardrails)

---

## 22. Open Questions

1. **Should v1 reject absolute-form request-targets outright, or accept and normalize?**  
   *Recommendation: reject.*

2. **Should v1 expose trailer headers for chunked request bodies, or just parse/ignore?**  
   *Recommendation: parse/ignore.*

3. **On listener spawn failure / connection slot exhaustion, should the accepted socket be closed immediately or sent a minimal 503 first?**  
   *Recommendation: close immediately in v1.*

4. **Should `ctx_current_tick()` be added to Tina's public API?**  
   *Recommendation: yes; it materially simplifies timeouts and Date caching.*
