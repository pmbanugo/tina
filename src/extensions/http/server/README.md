# Tina HTTP

A strict, secure, and zero-allocation-at-runtime HTTP/1.1 server library for Odin, built on the [Tina concurrency framework](https://github.com/pmbanugo/tina).

> **Compliance:** 33/33 passing on `uNetworking/h1spec`. See [Compliance Check](./compliance_check/README.md).

Tina HTTP is designed for high-throughput web server workloads with a predictable p99 latency. By layering on Tina's Thread-per-Core architecture, it guarantees deterministic memory bounds, cross-core routing, and completely isolated connection lifecycles. 

Run your web server on dedicated [Shards](/docs/concepts/thread_per_core.md), and seamlessly dispatch background tasks or Pub/Sub events to other Shards using native Tina messaging.

## The Architectural Mental Model

*   **One Connection = One Isolate:** Every accepted socket becomes a lightweight Tina Isolate. A crash in one connection affects only that connection.
*   **Zero Dynamic Allocation**.
*   **Event-Driven, Not Callback Spaghetti:** Complex flows (like Server-Sent Events or downstream database calls) suspend the connection via the `Route_Step` enum and resume natively on `Route_Event` arrivals.

```
      [ OS Network Stack ]
              │ (accept)
      ┌───────▼─────────────────────────┐
      │  HTTP_Listener                  │  ← 1 per Shard (Static)
      └───────┬─────────────────────────┘
              │ (ctx_spawn)
      ┌───────▼─────────────────────────┐
      │ HTTP_Connection                 │  ← N per Shard (Dynamic)
      │ ┌─────────────────────────────┐ │
      │ │ recv → parse → route handler│ │
      │ │ → (park) → resume → flush   │ │
      │ └─────────────────────────────┘ │
      └─────────────────────────────────┘
```

## Quick Start

A complete, production-ready HTTP server with routing requires minimal boilerplate. 

```odin
package main

import http "tina/extensions/http/server"
import tina "tina/src"

health :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
    return http.respond_text(response, http.HTTP_STATUS_OK, "ok")
}

get_user :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
    id := http.param(request, "id")
    return http.respond_bytes(response, http.HTTP_STATUS_OK, "application/json", /* ... JSON bytes ... */)
}

main :: proc() {
    app := http.App {
        routes =[]http.Route{
            http.get("/health", health),
            http.get("/users/:id", get_user),
        },
    }

    server := http.Server {
        address = tina.ipv4(0, 0, 0, 0, 8080),
        app     = &app,
    }

    // Installs HTTP isolates into a Tina SystemSpec (Single-shard dev mode)
    spec := http.install_development_defaults(&server)
    tina.tina_start(&spec)
}
```

*For advanced use-cases like **Server-Sent Events (SSE)** or downstream I/O ops, see the [`/examples`](/examples) directory.*

## API Reference

The API is intentionally flat and explicit. Handlers are simple functions that read from `Request`, write to `Response`, and return a `Route_Step` to instruct the framework on what to do next.

### Routing & Setup
```odin
// Route Builders
http.get(pattern: string, handler: Request_Handler, body_size_max: u32 = 0, body_mode: Route_Body_Mode = .None) -> Route
http.post(pattern: string, handler: Request_Handler, body_size_max: u32 = 0, body_mode: Route_Body_Mode = .None) -> Route

// Evented Builders (for streaming, downstream I/O, or SSE)
http.get_event(pattern: string, handler: Route_Event_Handler, state_size: u16 = 0, body_size_max: u32 = 0, body_mode: Route_Body_Mode = .None) -> Route

// Bootstrap
http.install_development_defaults(server: ^Server) -> tina.SystemSpec
http.install(server: ^Server, shard_count: u8, connection_slot_count: u32) -> tina.SystemSpec
```

### Request Reading
Helpers to extract data from the incoming `Request`. Slices returned by these functions are valid for the lifetime of the handler call.
```odin
http.method(request: ^Request) -> Method
http.path(request: ^Request) ->[]u8
http.header(request: ^Request, name: string) ->[]u8
http.param(request: ^Request, name: string) ->[]u8
http.query_value(request: ^Request, name: string) -> []u8
http.query_value_decoded(request: ^Request, name: string) -> (decoded: []u8, result: Query_Value_Result)

// For .Buffered routes only: returns the complete body
http.body_buffered(request: ^Request) ->[]u8  
```

### Response Writing (Simple)
Helpers that construct a full response and return `.Flush_Final`. Headers staged
with `header_set` / `header_add` before these calls are preserved, except
`Content-Type` which each helper sets to its own value (`text/plain; charset=utf-8`,
`application/json`, etc.). Framework-owned headers (`Date`, `Content-Length`,
`Transfer-Encoding`, `Connection`) are ignored by policy and reported as
`.Reserved_Name`.
```odin
http.header_set(response: ^Response, name: string, value: string) -> Header_Result
http.header_add(response: ^Response, name: string, value: string) -> Header_Result

http.respond_text(response: ^Response, status_code: HTTP_Status, body: string) -> Route_Step
http.respond_json(response: ^Response, status_code: HTTP_Status, body: string) -> Route_Step
http.respond_bytes(response: ^Response, status_code: HTTP_Status, content_type: string, body:[]u8) -> Route_Step

// Zero-copy file-to-socket transfer
http.respond_file(response: ^Response, fd_file: tina.FD_Handle, file_size: u64, content_type: string) -> Route_Step

// Send 100 Continue to a client that sent Expect: 100-continue
http.continue_100(response: ^Response)
```

### Response Writing (Streaming & SSE)
For chunked transfer encoding or manual flushing. Stage application headers first,
then begin the response. `begin_stream` commits the HTTP response head and uses
HTTP/1.1 chunked transfer encoding; Tina owns `Connection`, `Content-Length`, and
`Transfer-Encoding` so callers cannot create invalid framing.
```odin
http.header_set(response: ^Response, name: string, value: string) -> Header_Result
http.header_add(response: ^Response, name: string, value: string) -> Header_Result

http.begin_stream(response: ^Response, status_code: HTTP_Status, content_type: string) -> Response_Begin_Result
http.begin_fixed_stream(response: ^Response, status_code: HTTP_Status, content_type: string, total_size: u64) -> Response_Begin_Result

http.write_bytes(response: ^Response, data:[]u8) -> u16

// Exact reservation for one atomic body record. Useful for protocols such as SSE
// that must not commit partial records on backpressure.
http.reserve_body_exact(response: ^Response, body_size: u32) -> (Body_Reservation, Body_Reservation_Result)
http.commit_body(response: ^Response, reservation: Body_Reservation) -> Body_Commit_Result

// Return .Read_Body to pause the handler until the next body chunk arrives (streamed routes).
http.read_body() -> Route_Step

http.flush(final: bool = false) -> Route_Step
http.close() -> Route_Step
```

Minimal SSE setup:

```odin
_ = http.header_set(response, "Cache-Control", "no-cache")
_ = http.header_set(response, "X-Accel-Buffering", "no")
if http.begin_stream(response, http.HTTP_STATUS_OK, "text/event-stream") != .Begun {
    return http.close()
}
_ = http.write_bytes(response, transmute([]u8)string("retry: 2000\n\n"))
return http.flush()
```

### Downstream Messaging & Async Events
Available only in `Route_Event_Handler` routes. Use these to pause the HTTP connection while waiting for background workers, database shards, or any downstream I/O.
```odin
// Send a message to another isolate, and park the HTTP connection waiting for a reply.
http.expect_reply(ctx: Route_Context, target: tina.Handle, tag: tina.Message_Tag, payload:[]u8, timeout_ns: u64) -> tina.Send_Result

// Park the HTTP connection waiting for a push notification (e.g., SSE broadcasts).
http.expect_notification(ctx: Route_Context, timeout_ns: u64, source: tina.Handle, tag: Message_Tag) -> Route_Step

// Synchronously send a message to another Tina isolate without parking.
http.route_send(ctx: Route_Context, to: tina.Handle, tag: Message_Tag, payload:[]u8) -> tina.Send_Result
```

## Performance & Benchmarks

Preliminary local benchmarks demonstrate highly stable throughput under load, which you can preview [on Twitter/X](https://x.com/p_mbanugo/status/2052130653076947133?s=20). A formal, reproducible benchmark suite comparing Tina HTTP against other library/framework is gradually being built.

*Note: You can run your own benchmark and share the result. Make sure you set the right config/limits when setting up Tina. Although it should be minimal for a simple test using e.g. `spec := http.install(&server, 1, 512)` if you expect around 250 - 500 simultaneous connections*

## Non-Goals (Never In Scope)

To maintain absolute structural safety and performance, the following are explicitly out of scope for this library:

- **TLS/SSL:** Terminate TLS at your reverse proxy or load balancer. 
- **Compression (deflate/gzip):** Rely on a CDN/proxy, or compress your response payloads in application code before passing them to the response buffer.
- **WebSocket Protocol**.
- **HTTP/2**. If HTTP/3 is supported in the future, it will be added as a separate extension, not retrofitted into this HTTP/1.1 parser.

If you require WebSocket framing or HTTP/3, you can fund its development. Reach out to me directly or support the project as a [GitHub sponsor](https://github.com/sponsors/pmbanugo).
