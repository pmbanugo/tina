// for benchmark purpose. The config allows for about 250 - 500 concurrent connections.
// You start the app and use `oha -n 10m -c 200 http://0.0.0.0:8080/ --no-tui` (or equivalent)

package main

import tina "../src"
import http "../src/extensions/http/server"
import "core:os"

health :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_text(response, http.HTTP_STATUS_OK, "ok")
}

root :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_text(response, http.HTTP_STATUS_OK, "")
}

parse_shard_count_argument :: proc(argument: string) -> (u8, bool) {
	if len(argument) == 0 {
		return 0, false
	}

	shard_count: u16
	for digit_byte in transmute([]u8)argument {
		if digit_byte < '0' || digit_byte > '9' {
			return 0, false
		}
		shard_count = shard_count * 10 + u16(digit_byte - '0')
		if shard_count > u16(max(u8)) {
			return 0, false
		}
	}
	if shard_count == 0 {
		return 0, false
	}
	return u8(shard_count), true
}

main :: proc() {
	shard_count: u8 = 1
	if len(os.args) > 1 {
		parsed_shard_count, parsed := parse_shard_count_argument(os.args[1])
		if parsed {
			shard_count = parsed_shard_count
		}
	}

	app := http.App {
		routes = []http.Route{http.get("/health", health), http.get("/", root)},
	}

	server := http.Server {
		address      = tina.ipv4(0, 0, 0, 0, 8080),
		backlog      = 256,
		ingress_mode = .Coordinator,
		app          = &app,
	}

	// The installer's timer sizing now tracks sparse waits; hot HTTP transport
	// deadlines are bounded by the connection slots below.
	spec := http.install(&server, shard_count, 1024)
	tina.tina_start(&spec)
}
