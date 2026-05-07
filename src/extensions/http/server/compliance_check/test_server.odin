package main

import http "../"
import tina "../../../.."

health :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_text(response, http.HTTP_STATUS_OK, "ok")
}

root :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	body := http.body_buffered(request)
	return http.respond_bytes(response, http.HTTP_STATUS_OK, "text/plain", body)
}

main :: proc() {
	app := http.App {
		routes = []http.Route {
			http.get("/health", health),
			http.any(
				"/",
				root,
				body_size_max = 4 * 1024,
				body_mode = http.Route_Body_Mode.Buffered,
			),
		},
	}

	server := http.Server {
		address = tina.ipv4(0, 0, 0, 0, 8080),
		app     = &app,
	}

	spec := http.install_development_defaults(&server)
	tina.tina_start(&spec)
}
