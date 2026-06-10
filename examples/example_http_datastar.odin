package main

import tina "../src"
import datastar "../src/extensions/http/datastar"
import http "../src/extensions/http/server"
import "core:fmt"

// ============================================================================
// Tina HTTP — Datastar SDK Hello World
//
// Recreates the Datastar homepage Hello World demo using Tina's Datastar SDK.
// Open http://localhost:8080, set interval to 0 for one-shot HTML-style
// patching, or non-zero for progressive SSE patches.
// ============================================================================

HELLO_MESSAGE :: "Hello world!"
DATASTAR_CDN_URL :: "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.1/bundles/datastar.js"
ODIN_LOGO_URL :: "https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/odin.svg"
SILKSCREEN_CSS_URL :: "https://fonts.googleapis.com/css2?family=Silkscreen:wght@400;700&display=swap"
STREAM_TIMEOUT_TAG :: tina.Message_Tag(0)

Store :: struct {
	Interval:       u32 `json:"interval"`,
	LastClassIndex: int `json:"lastClassIndex"`,
}

Hello_State :: struct {
	store:      Store,
	next_index: u32,
	streaming:  bool,
}

INDEX_HTML :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tina Datastar Hello World</title>
<script type="module" src="` + DATASTAR_CDN_URL + `"></script>
<style>
@import url('` + SILKSCREEN_CSS_URL + `');
:root{color-scheme:light dark;font-family:-apple-system,system-ui,sans-serif;--font-pixel:Silkscreen,sans-serif;--red-6:oklch(57.7% .245 27.325);--orange-6:oklch(64.6% .222 41.116);--green-6:oklch(62.7% .194 149.214);--blue-6:oklch(54.6% .245 262.881);--purple-6:oklch(55.8% .288 302.321);--_color:var(--blue-6)}
body{margin:0;padding:2rem;background:Canvas;color:CanvasText}main{max-width:64rem;margin:0 auto;display:grid;gap:1.5rem}.hero{display:grid;justify-items:center;gap:.75rem;text-align:center}.odin-logo{width:clamp(4rem,12vw,7rem);height:auto;filter:brightness(0) invert(1) drop-shadow(0 0 1.25rem color-mix(in oklab,var(--blue-6) 45%,transparent))}section{border:1px solid color-mix(in oklab,CanvasText 20%,transparent);border-radius:.75rem;padding:1.25rem}.grid{display:grid;grid-template-columns:minmax(0,1fr) minmax(20rem,1fr);gap:1rem;align-items:start}label,input,button{font:inherit}input{max-width:8rem;padding:.45rem .6rem}button{padding:.5rem .85rem;border:0;border-radius:.5rem;background:#2563eb;color:white;cursor:pointer}button:disabled,input:disabled{opacity:.6;cursor:wait}
#message{font-family:var(--font-pixel);font-size:clamp(2rem,8vw,5rem);font-weight:400;line-height:1.1;letter-spacing:.12em;text-transform:uppercase;-webkit-font-smoothing:none;-moz-osx-font-smoothing:auto;margin:1rem 0 0;background:var(--_color);background-clip:text;-webkit-background-clip:text;-webkit-text-fill-color:transparent}.success{--_color:linear-gradient(to right in oklab,var(--red-6),var(--orange-6),var(--green-6),var(--blue-6))}.warning{--_color:linear-gradient(to right in oklab,var(--orange-6),var(--green-6),var(--blue-6),var(--purple-6))}.error{--_color:linear-gradient(to right in oklab,var(--red-6),var(--orange-6),var(--purple-6))}.sse{--_color:linear-gradient(to right in oklab,var(--red-6),var(--orange-6),var(--green-6),var(--blue-6),var(--purple-6))}
.console{margin:0;min-height:18rem;max-height:26rem;overflow:auto;background:#0b1020;color:#d1e7ff;border-radius:.75rem;padding:0}.console header{position:sticky;top:0;padding:.75rem 1rem;background:#111827;color:white}.console div{padding:1rem}code{color:inherit;white-space:pre-wrap}@media(max-width:760px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<main>
  <header class="hero">
    <img class="odin-logo" alt="Odin logo" src="` + ODIN_LOGO_URL + `">
    <h1>Tina Datastar SDK — Hello World</h1>
  </header>
  <section id="hello">
    <div class="grid">
      <div>
        <p>Datastar accepts <code>text/html</code> and <code>text/event-stream</code> content types, so the backend can send HTML patches or progressive SSE patches.</p>
        <p>Try <strong>0</strong> and <strong>400</strong> millisecond intervals.</p>
        <div data-signals:last-class-index="-1" data-signals:fetching="false">
          <label for="interval">Interval in ms:</label>
          <div>
            <input data-bind:interval data-attr:disabled="$fetching" id="interval" type="number" step="100" min="0" max="1000" value="400">
            <button class="info" data-on:click="message.innerHTML = networkResponse.innerHTML = '&nbsp;'; @get('/api/hello-world')" data-indicator:fetching data-attr:disabled="$fetching">Start</button>
          </div>
        </div>
        <h3 id="message">Hello world!</h3>
      </div>
      <div>
        <pre class="console"><header>Network Response</header><div id="networkResponse"></div></pre>
      </div>
    </div>
  </section>
</main>
</body>
</html>
`

index :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_bytes(
		response,
		http.HTTP_STATUS_OK,
		"text/html; charset=utf-8",
		transmute([]u8)string(INDEX_HTML),
	)
}

health :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_text(response, http.HTTP_STATUS_OK, "ok")
}

hello_world :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	state: rawptr,
) -> http.Route_Step {
	hello_state := cast(^Hello_State)state

	switch ev in event {
	case http.Request_Start:
		hello_state^ = Hello_State{}
		if error := datastar.read_signals(request, &hello_state.store); error != .None {
			return http.respond_text(response, http.HTTP_STATUS_BAD_REQUEST, "invalid datastar signals")
		}

		sse := datastar.server_sent_event_generator(request, response)
		if hello_state.store.Interval == 0 {
			classes := []string{"success", "warning", "error"}
			class_index := hello_state.store.LastClassIndex + 1
			if class_index >= len(classes) || class_index < 0 do class_index = 0

			datastar.patch_elements(&sse, hello_element(HELLO_MESSAGE, classes[class_index]))

			code_buffer := make([]u8, 512, context.temp_allocator)
			datastar.patch_elements(
				&sse,
				fmt.bprintf(code_buffer, `<code>HTTP/1.1 200 OK<br>Content-Type: text/html<br><br>&lt;h3 id="message"&gt;%s&lt;/h3&gt;</code>`, HELLO_MESSAGE),
				datastar.Patch_Elements_Options{selector = "#networkResponse", mode = .Inner},
			)

			signal_buffer: [64]u8
			datastar.patch_signals(&sse, fmt.bprintf(signal_buffer[:], `{{"lastClassIndex": %d}}`, class_index))
			return http.flush(final = true)
		}

		hello_state.streaming = true
		datastar.patch_elements(
			&sse,
			`<code>HTTP/1.1 200 OK<br>Content-Type: text/event-stream<br><br></code>`,
			datastar.Patch_Elements_Options{selector = "#networkResponse", mode = .Inner},
		)
		return http.flush()

	case http.Send_Ready:
		if !hello_state.streaming do return http.close()
		return http.expect_notification(
			route_context,
			u64(hello_state.store.Interval) * 1_000_000,
			tina.ISOLATE_HANDLE_NONE,
			STREAM_TIMEOUT_TAG,
		)

	case http.Application_Reply:
		if ev.reply_result != .Timeout || !hello_state.streaming do return http.close()

		message := string(HELLO_MESSAGE)
		next_index := hello_state.next_index
		for next_index < u32(len(message)) && message[next_index] == ' ' {
			next_index += 1
		}
		if next_index >= u32(len(message)) {
			return http.flush(final = true)
		}

		hello_state.next_index = next_index + 1
		msg := message[:int(next_index)+1]
		sse := datastar.ServerSentEventGenerator{request = request, response = response}
		datastar.patch_elements(&sse, hello_element(msg, "sse"))

		code_buffer := make([]u8, 512, context.temp_allocator)
		datastar.patch_elements(
			&sse,
			fmt.bprintf(
				code_buffer,
				`<code>event: datastar-patch-elements<br>data: elements &lt;h3 id="message"&gt;%s&lt;/h3&gt;<br><br></code>`,
				msg,
			),
			datastar.Patch_Elements_Options{selector = "#networkResponse", mode = .Append},
		)
		datastar.execute_script(&sse, "networkResponse.scrollTop = networkResponse.scrollHeight")
		return http.flush()

	case http.Body_Chunk, http.Application_Notification, http.Peer_Closed, http.Server_Drain:
		return http.close()
	}

	return http.close()
}

hello_element :: proc(message: string, class: string) -> string {
	buffer := make([]u8, 256, context.temp_allocator)
	return fmt.bprintf(buffer, `<h3 id="message" class="%s">%s</h3>`, class, message)
}

main :: proc() {
	app := http.App {
		routes = []http.Route {
			http.get("/", index),
			http.get("/health", health),
			http.get_event("/api/hello-world", hello_world, state_size = u16(size_of(Hello_State))),
		},
	}
	server := http.Server {
		address = tina.ipv4(0, 0, 0, 0, 8080),
		app     = &app,
	}

	spec := http.install_development_defaults(&server)

	fmt.println("Tina Datastar SDK demo — open http://localhost:8080")
	fmt.println("Health endpoint: GET /health")
	fmt.println("Datastar endpoint: GET /api/hello-world")

	tina.tina_start(&spec)
}
