package http_server

import tina "../../.."

// Internal control-plane tags. These stay package-private and never leak into
// the public HTTP surface.
@(private = "package")
TAG_HEADER_TIMEOUT :: tina.Message_Tag(0xFFF0)

@(private = "package")
TAG_BODY_TIMEOUT :: tina.Message_Tag(0xFFF1)

@(private = "package")
TAG_SEND_TIMEOUT :: tina.Message_Tag(0xFFF2)

@(private = "package")
TAG_IDLE_TIMEOUT :: tina.Message_Tag(0xFFF3)

@(private = "package")
TAG_DRAIN_TIMEOUT :: tina.Message_Tag(0xFFF4)

@(private = "package")
TAG_EVICT :: tina.Message_Tag(0xFFF5)

@(private = "package")
TAG_ACCEPT_BACKOFF :: tina.Message_Tag(0xFFFD)
