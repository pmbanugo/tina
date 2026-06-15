# Tina Datastar SDK

Small Odin helpers for Datastar's Server-Sent Event protocol on Tina HTTP.
The SDK is deliberately thin: it stages the correct SSE response headers,
serializes Datastar events, and reads incoming `datastar` signal JSON.

## Start a Datastar SSE response

```odin
sse, error := datastar.start_sse(response)
if error != .None {
    return http.close()
}
```

The constructor accepts only the response. Request data belongs to
`read_signals`; retaining the request pointer would add unused state to every
generator.

Tina sends HTTP/1.1 SSE as chunked transfer encoding. It sets:

- `Content-Type: text/event-stream`
- `Cache-Control: no-cache`
- `X-Accel-Buffering: no`

It does **not** set `Connection: keep-alive`: HTTP/1.1 persistence is the
default, and Tina owns hop-by-hop/framing headers.

After a non-final flush, resume with the existing response:

```odin
sse := datastar.resume(response)
```

## Send DOM patches

```odin
error := datastar.patch_elements(
    &sse,
    `<div id="message">Hello</div>`,
)
```

With options:

```odin
error := datastar.patch_elements(
    &sse,
    `<li>new</li>`,
    datastar.Patch_Elements_Options {
        selector = "#items",
        mode     = .Append,
    },
)
```

Options only emit non-default fields. Use flags for opt-in features:

```odin
datastar.Patch_Elements_Options {
    selector = "#main",
    flags    = {.Use_View_Transition},
}
```

## Send signal patches

Signals are JSON Merge Patch strings.

```odin
error := datastar.patch_signals(&sse, "{\"count\": 42}")
```

Only-if-missing uses a flag:

```odin
error := datastar.patch_signals(
    &sse,
    "{\"theme\": \"dark\"}",
    datastar.Patch_Signals_Options{flags = {.Only_If_Missing}},
)
```

## Execute a script

Scripts are sent as an appended `<script>` element. The default lifetime is
`.Auto_Remove`, which adds `data-effect="el.remove()"`.

```odin
error := datastar.execute_script(&sse, "console.log('ready')")

error = datastar.execute_script(
    &sse,
    "console.log('keep me')",
    datastar.Execute_Script_Options{lifetime = .Persistent},
)
```

## Read signals from a request

```odin
Store :: struct {
    Count: u32 `json:"count"`,
}

store: Store
if datastar.read_signals(request, &store) != .None {
    return http.respond_text(response, http.HTTP_STATUS_BAD_REQUEST, "invalid signals")
}
```

`GET` and `DELETE` read URL-decoded query parameter `datastar`. `POST`, `PUT`,
and `PATCH` read the buffered JSON body. Routes using body-based reads must
register `body_mode = .Buffered` with a non-zero `body_size_max`, e.g.
`http.post("/path", handler, body_size_max = 4096, body_mode = .Buffered)`.
Without this, `http.body_buffered(request)` returns `nil` and `read_signals`
returns `.Missing` for valid JSON payloads.

## Performance contract

Each Datastar event is serialized into one exact Tina body reservation and then
committed. There is no heap allocation, no temporary event buffer, and no partial
SSE event committed when the egress buffer is backpressured.

`retry_duration_ms = 0` means "use Datastar's default" and is not emitted.
Values other than `0` and `1000` are emitted as `retry: <milliseconds>`.
