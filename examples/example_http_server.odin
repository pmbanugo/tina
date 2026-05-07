package main

import tina "../src"
import http "../src/extensions/http/server"

health :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_text(response, http.HTTP_STATUS_OK, "ok")
}

root :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	return http.respond_text(response, http.HTTP_STATUS_OK, "")
}

main :: proc() {
	app := http.App {
		routes = []http.Route{http.get("/health", health), http.get("/", root)},
	}

	server := http.Server {
		address = tina.ipv4(0, 0, 0, 0, 8080),
		app     = &app,
	}

	spec := http.install_development_defaults(&server)
	tina.tina_start(&spec)
}
