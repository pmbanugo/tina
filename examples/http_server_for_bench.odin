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

main :: proc() {
	shard_count: u8 = 1
	// Pass "2" to exercise the dual-shard path.
	if len(os.args) > 1 && os.args[1] == "2" {
		shard_count = 2
	}

	app := http.App {
		routes = []http.Route{http.get("/health", health), http.get("/", root)},
	}

	server := http.Server {
		address      = tina.ipv4(0, 0, 0, 0, 8080),
		backlog      = 4096,
		distribution = .Coordinator,
		app          = &app,
	}

	// The installer's timer sizing now tracks sparse waits; hot HTTP transport
	// deadlines are bounded by the connection slots below.
	spec := http.install(&server, 4, 1024)
	tina.tina_start(&spec)
}
