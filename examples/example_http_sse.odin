package main

import tina "../src"
import http "../src/extensions/http/server"
import "core:fmt"

// ============================================================================
// Tina HTTP — Server-Sent Events with Fan-Out
//
// One Publisher isolate emits a tick every second. Every browser connected to
// GET /events receives the same tick broadcast via EventSource. Open
// http://localhost:8080 in two windows to watch the counters move in lock-step.
// ============================================================================

// ─── Tags & topology ────────────────────────────────────────────────────────

PUBLISHER_TYPE_OFFSET :: 0
SSE_TICK_INTERVAL_NS :: u64(1_000_000_000)
SUBSCRIBERS_MAX :: 256

TAG_PUBLISHER_TICK: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1
TAG_SUBSCRIBE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 2
TAG_UNSUBSCRIBE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 3
TAG_FEED_EVENT: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 4

// Isolate handle of the singleton publisher. HANDLE_NONE before init completes.
publisher_handle: tina.Isolate_Handle = tina.ISOLATE_HANDLE_NONE

// ─── Wire payloads ──────────────────────────────────────────────────────────

Sub_Msg :: struct {
	request_token: http.Request_Token,
}

Feed_Msg :: struct {
	request_token: http.Request_Token,
	counter:       u32,
}

// ─── Publisher isolate ──────────────────────────────────────────────────────

Subscriber :: struct {
	handle:        tina.Isolate_Handle,
	request_token: http.Request_Token,
}

PublisherIsolate :: struct {
	subscribers:      [SUBSCRIBERS_MAX]Subscriber,
	subscriber_count: u32,
	counter:          u32,
}

publisher_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
	self := tina.self_as(PublisherIsolate, self_raw)
	self.subscriber_count = 0
	self.counter = 0

	publisher_handle = tina.ctx_self_handle()
	tina.ctx_register_timer(SSE_TICK_INTERVAL_NS, TAG_PUBLISHER_TICK)
	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

publisher_handler :: proc(
	self_raw: rawptr,
	message: ^tina.Message,
) -> tina.Isolate_Transition {
	self := tina.self_as(PublisherIsolate, self_raw)

	switch message.tag {
	case TAG_SUBSCRIBE:
		if self.subscriber_count >= SUBSCRIBERS_MAX {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE // shed quietly; subscriber will time out
		}
		msg := tina.payload_as(Sub_Msg, message.user.payload[:])
		self.subscribers[self.subscriber_count] = Subscriber {
			handle        = message.user.source,
			request_token = msg.request_token,
		}
		self.subscriber_count += 1

	case TAG_UNSUBSCRIBE:
		// Linear scan, swap-with-last. Identity is the source handle.
		for index := u32(0); index < self.subscriber_count; index += 1 {
			if self.subscribers[index].handle == message.user.source {
				self.subscriber_count -= 1
				self.subscribers[index] = self.subscribers[self.subscriber_count]
				break
			}
		}

	case TAG_PUBLISHER_TICK:
		self.counter += 1
		// drop stale handles (dead connection isolates).
		write_index := u32(0)
		for read_index := u32(0); read_index < self.subscriber_count; read_index += 1 {
			subscriber := self.subscribers[read_index]
			feed := Feed_Msg {
				request_token = subscriber.request_token,
				counter       = self.counter,
			}
			result := tina.ctx_send(subscriber.handle, TAG_FEED_EVENT, &feed)
			if result == .stale_handle {
				continue
			}
			// .ok and .mailbox_full keep the subscriber; slow clients just drop this tick.
			self.subscribers[write_index] = subscriber
			write_index += 1
		}
		self.subscriber_count = write_index

		tina.ctx_register_timer(SSE_TICK_INTERVAL_NS, TAG_PUBLISHER_TICK)
	}

	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

// ─── HTTP routes ────────────────────────────────────────────────────────────

INDEX_HTML :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Tina SSE Broadcast Demo</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; padding: 2rem; max-width: 48rem; }
  pre  { background: #111; color: #0f0; padding: 1rem; min-height: 14rem; overflow-y: auto; max-height: 24rem; }
  .meta { color: #666; font-size: 0.85rem; }
  code { background: #eee; padding: 0.1rem 0.3rem; border-radius: 3px; }
</style>
</head>
<body>
  <h1>Tina SSE — Broadcast (one Publisher, many subscribers)</h1>
  <p class="meta">
    Open this page in two browser windows. Both will receive the SAME tick
    number at the SAME time — emitted once per second by a single Publisher
    isolate and fanned out to every subscriber via Tina's mailbox.
  </p>
  <pre id="log"></pre>
  <script>
    const log = document.getElementById('log');
    const es  = new EventSource('/events');
    es.onmessage = (e) => {
      log.textContent += e.data + '\n';
      log.scrollTop = log.scrollHeight;
    };
    es.onerror = () => { log.textContent += '[disconnected]\n'; };
  </script>
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

// Per-connection state. Arena-allocated by the framework at `state_size`.
SSE_State :: struct {
	tick_seen:  u32,
	subscribed: bool,
}

events_stream :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	state: rawptr,
) -> http.Route_Step {
	sse_state := cast(^SSE_State)state

	switch ev in event {
	case http.Request_Start:
		// Bail early if the publisher hasn't booted — EventSource auto-reconnects.
		if publisher_handle == tina.ISOLATE_HANDLE_NONE {
			return http.respond_text(
				response,
				http.HTTP_STATUS_SERVICE_UNAVAILABLE,
				"publisher not ready",
			)
		}
		http.begin_stream(response, http.HTTP_STATUS_OK, "text/event-stream")
		_ = http.header_set(response, "Cache-Control", "no-cache")
		_ = http.header_set(response, "X-Accel-Buffering", "no")
		_ = http.write_bytes(response, transmute([]u8)string("retry: 2000\n\n"))
		return http.flush()

	case http.Send_Ready:
		// Register with the publisher on first arrival; re-park on subsequent.
		if !sse_state.subscribed {
			publisher := publisher_handle
			if publisher == tina.ISOLATE_HANDLE_NONE {
				return http.close()
			}
			sub := Sub_Msg {
				request_token = http.route_request_token(route_context),
			}
			if http.route_send(route_context, publisher, TAG_SUBSCRIBE, tina.bytes_of(&sub)) !=
			   .ok {
				return http.close()
			}
			sse_state.subscribed = true
		}
		return http.expect_notification(
			route_context,
			60 * SSE_TICK_INTERVAL_NS, // relaxed parking window; ticks should arrive far sooner
			source_handle = publisher_handle,
			message_tag = TAG_FEED_EVENT,
		)

	case http.Application_Notification:
		// Validate request_token: reject stale notifications from a previous request on this keep-alive connection.
		feed := (cast(^Feed_Msg)raw_data(ev.payload_bytes))^
		if feed.request_token != http.route_request_token(route_context) {
			return http.expect_notification(
				route_context,
				60 * SSE_TICK_INTERVAL_NS,
				source_handle = publisher_handle,
				message_tag = TAG_FEED_EVENT,
			)
		}
		sse_state.tick_seen = feed.counter
		scratch_buffer := make([]u8, 64, http.request_scratch(request))
		frame := fmt.bprintf(scratch_buffer, "data: tick=%d\n\n", feed.counter)
		_ = http.write_bytes(response, transmute([]u8)frame)
		return http.flush()

	case http.Application_Reply:
		// Parking window elapsed without a tick. Drop so the browser reconnects.
		_ = ev
		return _unsubscribe_and_close(route_context)

	case http.Body_Chunk:
		return http.close()

	case http.Peer_Closed, http.Server_Drain:
		return _unsubscribe_and_close(route_context)

	case:
		return http.close()
	}
}

_unsubscribe_and_close :: proc(route_context: http.Route_Context) -> http.Route_Step {
	publisher := publisher_handle
	if publisher != tina.ISOLATE_HANDLE_NONE {
		empty: [0]u8
		_ = http.route_send(route_context, publisher, TAG_UNSUBSCRIBE, empty[:])
	}
	return http.close()
}

// ─── Boot wiring ────────────────────────────────────────────────────────────
//
// Extend the HTTP-only spec: register the Publisher type and wire it as a
// static child so the supervisor starts it before the listener.

main :: proc() {
	app := http.App {
		routes = []http.Route {
			http.get("/", index),
			http.get("/health", health),
			http.get_event("/events", events_stream, state_size = u16(size_of(SSE_State))),
		},
	}
	server := http.Server {
		address = tina.ipv4(0, 0, 0, 0, 8080),
		app     = &app,
	}

	spec := http.install_development_defaults(&server)

	publisher_type_id := tina.Isolate_Type_Id(len(spec.types))
	new_types := make([]tina.IsolateTypeDescriptor, len(spec.types) + 1)
	copy(new_types, spec.types)
	new_types[publisher_type_id] = tina.IsolateTypeDescriptor {
		id                = publisher_type_id,
		slot_count        = 1,
		stride            = size_of(PublisherIsolate),
		soa_metadata_size = size_of(tina.Isolate_Metadata),
		mailbox_capacity  = 64,
		init_handler      = publisher_init,
		handler_fn        = publisher_handler,
	}
	spec.types = new_types

	// Prepend the Publisher so subscribers can resolve the handle at first request.
	root := &spec.shard_specs[0].root_group
	new_children := make([]tina.Child_Spec, len(root.children) + 1)
	new_children[0] = tina.Static_Child_Spec {
		type_id      = publisher_type_id,
		restart_type = .permanent,
	}
	copy(new_children[1:], root.children)
	root.children = new_children

	fmt.println("Tina SSE broadcast demo — open http://localhost:8080 in TWO windows.")
	fmt.println("Both windows will receive the same tick from one Publisher isolate.")
	fmt.println("Stream endpoint:    GET /events   (text/event-stream)")
	fmt.println("Health endpoint:    GET /health")

	tina.tina_start(&spec)
}
