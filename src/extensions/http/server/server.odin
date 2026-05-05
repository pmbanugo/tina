package http_server

import tina "../../.."
import "core:fmt"
import "core:mem"

// ═══════════════════════════════════════════════════════════════════════════
// Tina HTTP — Phase 6: System Integration & Boot Sequence
//
// Wires the parser/router/response data structures from Phases 1–5 into
// Tina's memory model: TypeDescriptors, supervision tree, working-memory
// derivation, and the install() public entry points.
//
// References:
//   - HTTP_LIBRARY_SYSTEM_INTEGRATION.md  (Isolate types, install API, sharding)
//   - HTTP_LIBRARY_MEMORY_LAYOUT.md       (working_memory_size derivation)
//   - HTTP_LIBRARY_RUNTIME_POLICIES.md    (timeouts, drain, Date cache)
//
// Phase 6 ownership: type definitions, install/wire, derivation math,
// boot-time guards. The hot-path init/handler procedures are stubbed to
// `Effect_Receive` here; Phase 7+ replaces them with the real state machines.
// ═══════════════════════════════════════════════════════════════════════════

// `App` holds the user-declared route table.
App :: struct {
	routes: []Route,
}

// Multi-shard distribution strategy. `Coordinator` is the primary path; an
// L4-only ingress listener fans out via cross-shard FD handoff.
// `Reuse_Port` is a platform-specific fallback for environments where
// SO_REUSEPORT semantics are acceptable.
Distribution_Mode :: enum u8 {
	Coordinator,
	Reuse_Port,
}

// Keep-alive shedding policy.
Keepalive_Config :: struct {
	reserve_slots: u16,
}

// `Server` is the user-facing root configuration. One `Server` produces an
// HTTP listener and connection topology from a single compiled `App`.
//
// Naming: `graceful_drain_ms` mirrors `Timeouts.timeout_ms_*` units (ms) for
// API consistency. The library converts to ticks internally.
Server :: struct {
	address:           tina.Socket_Address,
	backlog:           u32,
	distribution:      Distribution_Mode,
	app:               ^App,
	limits:            Limits,
	timeouts:          Timeouts,
	keepalive:         Keepalive_Config,
	graceful_drain_ms: u32,
}

// Baked, immutable runtime configuration derived at install time.
// This intentionally excludes user-facing route tables and other boot-only input.
@(private = "package")
Server_Runtime :: struct {
	address:                tina.Socket_Address,
	backlog:                u32,
	distribution:           Distribution_Mode,
	limits:                 Limits,
	timeouts:               Timeouts,
	keepalive_reserve_slots: u16,
	graceful_drain_ms:      u32,
	buffered_body_size_max: u32,
	route_state_size_max:   u16,
}

// Strictly monotonic shard tick clock. Derived from `ctx_monotonic_time_ns`.
@(private = "package")
Monotonic_Time_NS :: distinct u64

@(private = "package")
Request_Token :: distinct u32

// Total bytes currently in the ingress buffer (request frame region only).
// Body bytes never inflate this; they flow through the reactor buffer or
// the buffered-body region.
@(private = "package")
Ingress_Size :: distinct u16

// Parser cursor inside the ingress buffer. Frame-relative — `0` is always
// the first byte of the current request line.
@(private = "package")
Ingress_Offset :: distinct u16

// Position within `HTTP_Shard_Runtime.idle_slot_indices`. Valid only while
// the connection is in `Keep_Alive_Idle`.
@(private = "package")
Idle_Array_Index :: distinct u16

// Number of valid entries in `idle_slot_indices`.
@(private = "package")
Idle_Array_Count :: distinct u16

@(private = "package")
IDLE_ARRAY_INDEX_NONE :: Idle_Array_Index(0xFFFF)

@(private = "package")
Connection_Phase :: enum u8 {
	// Recv path
	Recv_Headers, // accumulating request line + headers
	Recv_Body_Streamed, // body bytes delivered as Body_Chunk events
	Recv_Body_Buffered, // body bytes copied into the buffered-body region
	Application_Expectation, // parked waiting for downstream Reply/Notification
	// Send path
	Sending, // egress_buffer issued via io_send
	// Idle / shutdown path
	Keep_Alive_Idle, // request complete, awaiting next pipelined request or recv
	Drain, // server shutting down; finish current response then close
	Closing, // io_close issued; waiting for IO_TAG_CLOSE_COMPLETE
}

Application_Expectation_Kind :: enum u8 {
	Reply,
	Notification,
}

@(private = "package")
Application_Pending_Message :: struct {
	source_handle: tina.Handle,
	message_tag:   Message_Tag,
	correlation_id: tina.Correlation_Id,
	payload_size:  u16,
	payload:       [tina.MAX_PAYLOAD_SIZE]u8,
}


// ─── Shard-Local Runtime ───
//
// One per shard. Allocated by the listener from its working_arena at boot
// and broadcast to children via init args. All connections + the dispatcher
// share this struct read-mostly. Single-writer is preserved by phase
// transitions: only the connection in a given slot mutates fields keyed by
// its own slot index.
@(private = "package")
HTTP_Shard_Runtime :: struct {
	server:               Server_Runtime,
	router:               ^Compiled_Router,
	connection_type_id:    u8,
	date_cache:           Date_Cache,
	draining:             bool,
	deadline_ns_drain:    Monotonic_Time_NS,
	next_request_token:   Request_Token, // monotonic across the shard
	keepalive_reserve:    u16, // mirrors Keepalive_Config.reserve_slots
	idle_slot_indices:    []u16, // dense swap-and-pop tracker
	idle_slot_handles:    []tina.Handle,
	idle_slot_positions:  []u16,
	idle_count:           Idle_Array_Count,
	free_count:           u16, // free connection slots (dropped on spawn, restored on close)
	connection_slot_count: u16, // hard cap for cross-checking spawn / eviction
	accept_backoff_ns:     u64,
}


// ─── Isolate Structs ───

// One per shard. Owns the listening socket and the compiled router pointer
// that all connection slots inherit on spawn.
//
// Restart type: `.permanent` (HTTP_LIBRARY_SYSTEM_INTEGRATION.md §1.1).
@(private = "package")
HTTP_Listener :: struct {
	listen_fd:                  tina.FD_Handle,
	shard_runtime:              ^HTTP_Shard_Runtime,
	dispatcher_handles:         []tina.Handle,
	next_dispatcher_shard_index: u8,
	accept_backoff_ns:          u64,
}

// One per shard, only instantiated in multi-shard `Coordinator` mode.
// Long-lived. Receives cross-shard FD handoff adoptions and spawns
// shard-local `HTTP_Connection` per accepted FD.
// Strictly L4 — does no HTTP parsing (DR-4).
//
// Restart type: `.permanent`.
@(private = "package")
HTTP_Dispatcher :: struct {
	shard_runtime: ^HTTP_Shard_Runtime,
}

// Per-connection, per-Isolate-slot state.
@(private = "package")
HTTP_Connection_State :: struct {
	// --- scheduler hot path ---
	shard_runtime:              ^HTTP_Shard_Runtime,
	deadline_ns_idle:           Monotonic_Time_NS,
	deadline_ns_header:         Monotonic_Time_NS,
	deadline_ns_body:           Monotonic_Time_NS,
	deadline_ns_send:           Monotonic_Time_NS,
	deadline_ns_drain:          Monotonic_Time_NS,
	fd:                         tina.FD_Handle,
	request_token:              Request_Token,
	application_expectation_kind: Application_Expectation_Kind,
	application_expected_source: tina.Handle,
	application_expected_tag:    Message_Tag,
	application_correlation_id:  tina.Correlation_Id,
	application_timeout_ns:      u64,
	application_pending_message:  Application_Pending_Message,
	request_body_size_received:   u64,
	sendfile_offset:             u64,
	sendfile_size_remaining:     u64,

	// --- Recv / parse ingress cursors ---
	ingress_size:               Ingress_Size,
	ingress_parsed_offset:      Ingress_Offset,
	state:                      Connection_Phase,
	idle_array_index:           Idle_Array_Index,
	request_frame_size:          u16,
	pipeline_tail_size:         u16,
	buffered_body_size:         u32,
	sendfile_file_fd:           tina.FD_Handle,
	response_flush_final:       bool,
	sendfile_active:            bool,
	application_pending_message_valid: bool,
	request_body_complete_notified: bool,

	// --- Sub-state machines (sized by Phase 1–5 types) ---
	parser:                     Parser_State,
	response:                   Response_State,
	request:                    Request_State,
	header_views:                []Header_View,
	response_header_bytes:       []u8,
	route_state_bytes:           []u8,
	request_frame_bytes:         []u8,
	buffered_body_bytes:         []u8,
	pipeline_tail_bytes:         []u8,

	// --- Cold: read only by `peer_address(request)` helper ---
	peer:                       tina.Peer_Address,
}

// The TypedArena Isolate. The egress buffer trails the connection state so
// `payload_offset_of(self, self.egress_buffer[:])` resolves to a stable u16
// offset addressable by Tina's reactor.
@(private = "package")
HTTP_Connection :: struct {
	using connection_state: HTTP_Connection_State,
	egress_buffer:          [HTTP_EGRESS_BUFFER_SIZE]u8,
}

// Boot-time invariant: the entire HTTP_Connection payload (state + egress
// buffer) must fit inside Tina's u16 payload_offset coordinate space. This
// asserts at the top, not inside an init proc, so any future struct growth
// fails at compile time.
#assert(
	size_of(HTTP_Connection) <= 65535,
	"HTTP_Connection exceeds Tina's u16 payload_offset coordinate space",
)


// ─── Init Args (passed via Spawn_Spec.args_payload — 64-byte budget) ────────

@(private = "package")
HTTP_Listener_Init_Args :: struct {
	server:                  ^Server_Runtime,
	router:                  ^Compiled_Router,
	connection_slot_count:    u16,
	connection_type_id:       u8,
	dispatcher_type_id:       u8,
	dispatcher_shard_count:   u8,
}

@(private = "package")
HTTP_Dispatcher_Init_Args :: struct {
	server:                ^Server_Runtime,
	router:                ^Compiled_Router,
	connection_slot_count: u16,
	connection_type_id:    u8,
}

@(private = "package")
HTTP_Connection_Init_Args :: struct {
	shard_runtime:  ^HTTP_Shard_Runtime,
	client_fd:      tina.FD_Handle,
}

#assert(size_of(HTTP_Listener_Init_Args) <= tina.MAX_INIT_ARGS_SIZE)
#assert(size_of(HTTP_Dispatcher_Init_Args) <= tina.MAX_INIT_ARGS_SIZE)
#assert(size_of(HTTP_Connection_Init_Args) <= tina.MAX_INIT_ARGS_SIZE)


// ─── Type-ID Offsets ────────────────────────────────────────────────────────
//
// These are *positional offsets* relative to `base_type_id`, not absolute
// type IDs. `install_into_system_spec` derives `base_type_id := len(spec.types)`
// at install time, then assigns each HTTP TypeDescriptor as
// `base_type_id + HTTP_TYPE_OFFSET_<role>`. This keeps the install contract
// position-independent: callers may register their own TypeDescriptors before
// (or after) `install()` and the HTTP wiring still resolves correctly.
//
// The runtime never reads these constants directly. Every place that needs
// the actual type id reads it from a runtime field that was populated from
// install-time args (e.g. `HTTP_Shard_Runtime.connection_type_id`,
// `HTTP_Listener_Init_Args.dispatcher_type_id`).

@(private = "package")
HTTP_TYPE_OFFSET_LISTENER :: 0
@(private = "package")
HTTP_TYPE_OFFSET_CONNECTION :: 1
@(private = "package")
HTTP_TYPE_OFFSET_DISPATCHER :: 2
@(private = "package")
HTTP_TYPE_OFFSET_MAX :: HTTP_TYPE_OFFSET_DISPATCHER


// ─── Library-internal scratch headroom (parser percent-decode, formatting) ──
//
// Boot-time floor for the parser/responder's own scratch use, independent of
// the application's `handler_scratch_max`. Keep proportional to the largest
// single internal scratch consumer — currently percent-decoding the longest
// possible URL slice.
@(private = "package")
HTTP_INTERNAL_SCRATCH_NEED :: 4096


// ─── Default sizing constants ───────────────────────────────────────────────
//
// Library-chosen ceilings for the convenience installers. Production callers
// should pass their own values via `install_make_system_spec`.

@(private = "package")
HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT :: 128
@(private = "package")
HTTP_DEV_TIMER_RESOLUTION_NS :: 1_000_000 // 1 ms
@(private = "package")
HTTP_DEV_TIMER_SPOKE_COUNT :: 1024
@(private = "package")
HTTP_DEV_LOG_RING_SIZE :: 4096
@(private = "package")
HTTP_DEV_TRANSFER_SLOT_COUNT :: 16
@(private = "package")
HTTP_DEV_TRANSFER_SLOT_SIZE :: 4096
@(private = "package")
HTTP_DEV_REACTOR_BUFFER_SLOT_SIZE :: 16384
@(private = "package")
HTTP_DEV_SUPERVISION_GROUPS_MAX :: 4
@(private = "package")
HTTP_DEV_DEFAULT_RING_SIZE :: 16
@(private = "package")
HTTP_DEV_SHUTDOWN_TIMEOUT_MS :: 3_000
@(private = "package")
HTTP_PROD_SHUTDOWN_TIMEOUT_MS :: 30_000
@(private = "package")
HTTP_PROD_DEFAULT_RING_SIZE :: 1024
@(private = "package")
HTTP_DEFAULT_BACKLOG :: 1024


// ─── install Procedure Group — Public API ───────────────────────────────────
//
// Tier 1 (`install_into_system_spec`) is the primitive: mutate an existing
// SystemSpec by appending HTTP TypeDescriptors and wiring children into each
// shard's supervision tree. Tier 2 (`install_make_system_spec`) builds a
// production SystemSpec from scratch, then delegates to Tier 1.
// `install_development_defaults` is a separate name because "dev mode" is a
// semantic preset (single-shard, .Development memory, .Abort quarantine), not
// a signature variant — see HTTP_LIBRARY_SYSTEM_INTEGRATION.md §3.1.

install :: proc {
	install_into_system_spec,
	install_make_system_spec,
}

install_development_defaults :: proc {
	install_development_defaults_default,
	install_development_defaults_with_connection_slot_count,
}


// ─── Tier 1: mutate an existing SystemSpec ──────────────────────────────────

install_into_system_spec :: proc(spec: ^tina.SystemSpec, server: ^Server) {
	assert(spec != nil, "install_into_system_spec: spec is nil")
	assert(server != nil, "install_into_system_spec: server is nil")
	assert(server.app != nil, "install_into_system_spec: server.app is nil — nothing to install")

	_normalize_server_defaults(server)

	when ODIN_OS == .Windows {
		assert(
			spec.shard_count == 1,
			"HTTP v1 multi-shard mode is unsupported on Windows (Tina core lacks cross-shard FD handoff)",
		)
	}

	// Boot-time runtime guards (HTTP_LIBRARY_SYSTEM_INTEGRATION.md §3.6).
	limits := server.limits
	assert(
		u32(limits.request_line_size_max) + u32(limits.header_size_max) <= 65_535,
		"limits: request_line_size_max + header_size_max exceeds u16 frame width",
	)
	assert(
		u32(limits.pipeline_size_max) <= 65_535,
		"limits: pipeline_size_max exceeds u16 width",
	)

	connection_slot_count := _route_connection_slot_count(spec)
	assert(
		connection_slot_count <= 65_535,
		"connection_slot_count exceeds u16 idle-tracker width",
	)
	assert(
		len(server.app.routes) <= 254,
		"too many routes (Route_Index reserves 0xFF as ROUTE_INDEX_NONE; 254 is the conservative cap)",
	)
	assert(
		spec.timer_resolution_ns <= 1_000_000_000,
		"timer_resolution_ns must be <= 1 s (Date cache lower bound)",
	)

	// Compile the route table once at boot and keep it alive for the lifetime
	// of the system spec.
	router_value, router_error, router_error_index := compile_router(server.app.routes, context.allocator)
	assert(
		router_error == .None,
		fmt.tprintf("install_into_system_spec: route compilation failed at index %d with %v", router_error_index, router_error),
	)
	router_storage := make([]Compiled_Router, 1, context.allocator)
	router_storage[0] = router_value
	router := &router_storage[0]
	server_runtime_storage := make([]Server_Runtime, 1, context.allocator)
	server_runtime_storage[0] = _bake_server_runtime(server)
	server_runtime := &server_runtime_storage[0]

	// --- Derive memory budgets ---
	working_memory_size := _compute_working_memory_size(server)
	scratch_requirement := _compute_scratch_requirement(server)

	// Raise spec.scratch_arena_size if HTTP requires more than the caller set.
	// Never lower an explicit user value.
	if spec.scratch_arena_size < scratch_requirement {
		spec.scratch_arena_size = scratch_requirement
	}

	// --- Append HTTP TypeDescriptors ---
	coordinator_mode_enabled := spec.shard_count > 1 && server.distribution == .Coordinator
	include_dispatcher := coordinator_mode_enabled
	http_type_count := 2 + (include_dispatcher ? 1 : 0)
	if coordinator_mode_enabled {
		for shard_index in 0 ..< len(spec.shard_specs) {
			assert(
				spec.shard_specs[shard_index].shard_id == tina.Shard_Id(u8(shard_index)),
				"Coordinator mode requires contiguous shard ids (0..shard_count-1) for dispatcher handoff routing",
			)
		}
	}
	// Position-independence: HTTP types are appended after whatever the caller
	// has already registered. Guard against u8 overflow before we cast — failing
	// loud here is far better than silently wrapping a type id and producing
	// undeliverable handles at runtime.
	assert(
		len(spec.types) + http_type_count <= tina.MAX_TYPE_DESCRIPTOR_ID + 1,
		"install_into_system_spec: appending HTTP types would exceed MAX_TYPE_DESCRIPTOR_ID; reduce pre-existing types or split installs",
	)
	base_type_id := u8(len(spec.types))

	listener_type_id := base_type_id + HTTP_TYPE_OFFSET_LISTENER
	connection_type_id := base_type_id + HTTP_TYPE_OFFSET_CONNECTION
	dispatcher_type_id := base_type_id + HTTP_TYPE_OFFSET_DISPATCHER

	listener_init_args := HTTP_Listener_Init_Args {
		server                = server_runtime,
		router                = router,
		connection_slot_count = u16(connection_slot_count),
		connection_type_id    = connection_type_id,
		dispatcher_type_id    = dispatcher_type_id,
		dispatcher_shard_count = spec.shard_count,
	}
	listener_args_payload, listener_args_size := tina.init_args_of(&listener_init_args)

	dispatcher_init_args := HTTP_Dispatcher_Init_Args {
		server                = server_runtime,
		router                = router,
		connection_slot_count = u16(connection_slot_count),
		connection_type_id    = connection_type_id,
	}
	dispatcher_args_payload, dispatcher_args_size := tina.init_args_of(&dispatcher_init_args)

	new_types := make(
		[]tina.TypeDescriptor,
		len(spec.types) + http_type_count,
		context.allocator,
	)
	copy(new_types, spec.types)

	new_types[listener_type_id] = tina.TypeDescriptor {
		id                      = listener_type_id,
		slot_count              = 1,
		stride                  = size_of(HTTP_Listener),
		soa_metadata_size       = size_of(tina.Isolate_Metadata),
		working_memory_size     = _listener_working_memory_size(int(connection_slot_count)),
		scratch_requirement_max = HTTP_INTERNAL_SCRATCH_NEED,
		mailbox_capacity        = 16,
		// The listener bootstraps the shard-local runtime and drives accept.
		// Its init args carry the immutable boot-time config.
		// The runtime lives in the listener's working arena.
		init_handler            = _http_listener_init,
		handler_fn              = _http_listener_handler,
	}

	new_types[connection_type_id] = tina.TypeDescriptor {
		id                      = connection_type_id,
		slot_count              = int(connection_slot_count),
		stride                  = size_of(HTTP_Connection),
		soa_metadata_size       = size_of(tina.Isolate_Metadata),
		working_memory_size     = working_memory_size,
		scratch_requirement_max = scratch_requirement,
		mailbox_capacity        = 32,
		init_handler            = _http_connection_init,
		handler_fn              = _http_connection_handler,
	}

	if include_dispatcher {
		new_types[dispatcher_type_id] = tina.TypeDescriptor {
			id                      = dispatcher_type_id,
			slot_count              = 1,
			stride                  = size_of(HTTP_Dispatcher),
			soa_metadata_size       = size_of(tina.Isolate_Metadata),
			working_memory_size     = _listener_working_memory_size(int(connection_slot_count)),
			scratch_requirement_max = HTTP_INTERNAL_SCRATCH_NEED,
			mailbox_capacity        = 16,
			init_handler            = _http_dispatcher_init,
			handler_fn              = _http_dispatcher_handler,
		}
	}

	spec.types = new_types

	// --- Wire the supervision tree on each shard ---
	for shard_index in 0 ..< len(spec.shard_specs) {
		shard_spec := &spec.shard_specs[shard_index]
		include_listener := !coordinator_mode_enabled || shard_index == 0
		_attach_http_children(
			shard_spec,
			listener_type_id,
			dispatcher_type_id,
			include_listener,
			include_dispatcher,
			u16(connection_slot_count),
			listener_args_payload,
			listener_args_size,
			dispatcher_args_payload,
			dispatcher_args_size,
		)
	}
}


// ─── Tier 2: build a production SystemSpec, then delegate ───────────────────

install_make_system_spec :: proc(
	server: ^Server,
	shard_count: u8,
	connection_slot_count: u32,
) -> tina.SystemSpec {
	assert(server != nil, "install_make_system_spec: server is nil")
	assert(server.app != nil, "install_make_system_spec: server.app is nil")
	assert(shard_count >= 1, "install_make_system_spec: shard_count must be >= 1")
	assert(
		connection_slot_count >= 1,
		"install_make_system_spec: connection_slot_count must be >= 1",
	)

	spec := _make_base_system_spec(
		server,
		shard_count,
		connection_slot_count,
		.Production,
		HTTP_PROD_SHUTDOWN_TIMEOUT_MS,
		HTTP_PROD_DEFAULT_RING_SIZE,
	)
	install_into_system_spec(&spec, server)
	return spec
}


// ─── Development presets ────────────────────────────────────────────────────

install_development_defaults_default :: proc(server: ^Server) -> tina.SystemSpec {
	return install_development_defaults_with_connection_slot_count(
		server,
		HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT,
	)
}

install_development_defaults_with_connection_slot_count :: proc(
	server: ^Server,
	connection_slot_count: u32,
) -> tina.SystemSpec {
	assert(server != nil, "install_development_defaults: server is nil")
	assert(server.app != nil, "install_development_defaults: server.app is nil")
	assert(connection_slot_count >= 1, "connection_slot_count must be >= 1")

	// Force single-shard regardless of caller's distribution preference.
	server.distribution = .Reuse_Port

	spec := _make_base_system_spec(
		server,
		1, // single shard
		connection_slot_count,
		.Development,
		HTTP_DEV_SHUTDOWN_TIMEOUT_MS,
		HTTP_DEV_DEFAULT_RING_SIZE,
	)
	spec.quarantine_policy = .Abort
	install_into_system_spec(&spec, server)
	return spec
}


// ═══════════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════════

// Apply DEFAULT_LIMITS / DEFAULT_TIMEOUTS when the caller passed a whole-zero
// struct. Idempotent. Does not field-by-field merge — mixing zero and non-zero
// fields in the same struct is rejected by validation downstream rather than
// silently filled in (HTTP_LIBRARY_SYSTEM_INTEGRATION.md §3.3 normalization rule).
@(private = "package")
_normalize_server_defaults :: proc(server: ^Server) {
	if _is_zero_limits(server.limits) {
		server.limits = DEFAULT_LIMITS
	}
	if _is_zero_timeouts(server.timeouts) {
		server.timeouts = DEFAULT_TIMEOUTS
	}
	if server.backlog == 0 {
		server.backlog = HTTP_DEFAULT_BACKLOG
	}
	if server.graceful_drain_ms == 0 {
		server.graceful_drain_ms = HTTP_DEV_SHUTDOWN_TIMEOUT_MS
	}
}

@(private = "file")
_is_zero_limits :: #force_inline proc "contextless" (limits: Limits) -> bool {
	zero: Limits
	return limits == zero
}

@(private = "file")
_is_zero_timeouts :: #force_inline proc "contextless" (timeouts: Timeouts) -> bool {
	zero: Timeouts
	return timeouts == zero
}

// Builds a production-shaped SystemSpec from HTTP-derived parameters. Sized
// from `connection_slot_count` so doubling capacity scales every internal
// pool/ring/timer in lockstep — no manual re-tuning per knob.
@(private = "package")
_make_base_system_spec :: proc(
	server: ^Server,
	shard_count: u8,
	connection_slot_count: u32,
	memory_mode: tina.Memory_Init_Mode,
	shutdown_timeout_ms: u32,
	default_ring_size: u32,
) -> tina.SystemSpec {
	shard_specs := make([]tina.ShardSpec, int(shard_count), context.allocator)
	for i in 0 ..< int(shard_count) {
		shard_specs[i] = tina.ShardSpec {
			shard_id    = tina.Shard_Id(u8(i)),
			target_core = -1,
			root_group  = tina.Group_Spec {
				strategy              = .One_For_One,
				restart_count_max     = 5,
				window_duration_ticks = 10_000,
				children              = nil, // installed by install_into_system_spec
			},
		}
	}

	pool_slot_count := int(_next_power_of_two_u64(max(u64(1024), u64(connection_slot_count) * 8)))
	timer_entry_count := int(
		_next_power_of_two_u64(max(u64(256), u64(connection_slot_count) * 4)),
	)
	reactor_buffer_slot_count := int(
		_next_power_of_two_u64(min(u64(4094), max(u64(64), u64(connection_slot_count)))),
	)

	fd_handoff_entry_count := 0
	if shard_count > 1 {
		fd_handoff_entry_count = int(_next_power_of_two_u64(u64(connection_slot_count) / 4))
		if fd_handoff_entry_count == 0 {
			fd_handoff_entry_count = 16
		}
	}

	spec := tina.SystemSpec {
		shard_count               = shard_count,
		shard_specs               = shard_specs,
		memory_init_mode          = memory_mode,
		quarantine_policy         = .Quarantine,
		init_timeout_ms           = 30_000,
		shutdown_timeout_ms       = shutdown_timeout_ms,
		safety_margin             = 0.9,
		watchdog                  = tina.Watchdog_Config {
			check_interval_ms       = 500,
			shard_restart_window_ms = 30_000,
			shard_restart_max       = 3,
			phase_2_threshold       = 2,
		},
		timer_resolution_ns       = HTTP_DEV_TIMER_RESOLUTION_NS,
		pool_slot_count           = pool_slot_count,
		reactor_buffer_slot_count = reactor_buffer_slot_count,
		reactor_buffer_slot_size  = HTTP_DEV_REACTOR_BUFFER_SLOT_SIZE,
		transfer_slot_count       = HTTP_DEV_TRANSFER_SLOT_COUNT,
		transfer_slot_size        = HTTP_DEV_TRANSFER_SLOT_SIZE,
		fd_handoff_entry_count    = fd_handoff_entry_count,
		timer_spoke_count         = HTTP_DEV_TIMER_SPOKE_COUNT,
		timer_entry_count         = timer_entry_count,
		fd_table_slot_count       = int(connection_slot_count) + 16, // listener + headroom
		fd_entry_size             = size_of(tina.FD_Entry),
		log_ring_size             = HTTP_DEV_LOG_RING_SIZE,
		supervision_groups_max    = HTTP_DEV_SUPERVISION_GROUPS_MAX,
		default_ring_size         = default_ring_size,
		// types and scratch_arena_size are filled in by install_into_system_spec.
	}
	return spec
}

// Compute the per-Connection working_memory_size from limits + route metadata.
// Math is exact and boot-computable — under-provisioning is caught here, not
// at parse time. See HTTP_LIBRARY_MEMORY_LAYOUT.md §2.5.
@(private = "package")
_compute_working_memory_size :: proc(server: ^Server) -> int {
	server_runtime := _bake_server_runtime(server)
	limits := server_runtime.limits

	// Pre-compute u32 sums to keep arithmetic in one width and avoid surprise
	// promotions deep inside the formula.
	frame_size := int(limits.request_line_size_max) + int(limits.header_size_max)
	header_table_size := int(limits.header_count_max) * size_of(Header_View)

	total :=
		_align_up(frame_size) +
		_align_up(int(server_runtime.buffered_body_size_max)) +
		_align_up(int(limits.pipeline_size_max)) +
		_align_up(header_table_size) +
		_align_up(int(server_runtime.route_state_size_max)) +
		int(limits.request_arena_size) +
		_align_up(int(limits.response_header_bytes_max))

	return total
}

@(private = "package")
_bake_server_runtime :: proc(server: ^Server) -> Server_Runtime {
	return Server_Runtime {
		address                = server.address,
		backlog                = server.backlog,
		distribution           = server.distribution,
		limits                 = server.limits,
		timeouts               = server.timeouts,
		keepalive_reserve_slots = server.keepalive.reserve_slots,
		graceful_drain_ms      = server.graceful_drain_ms,
		buffered_body_size_max = _max_buffered_body_size(server.app.routes),
		route_state_size_max   = _max_route_state_size(server.app.routes),
	}
}

@(private = "package")
_compute_scratch_requirement :: proc(server: ^Server) -> int {
	return HTTP_INTERNAL_SCRATCH_NEED + int(server.limits.handler_scratch_max)
}

// The listener's working memory holds the shared HTTP_Shard_Runtime plus the
// idle-slot tracker array. Sized to the connection capacity.
@(private = "package")
_listener_working_memory_size :: #force_inline proc "contextless" (
	connection_slot_count: int,
) -> int {
	return _align_up(size_of(HTTP_Shard_Runtime)) +
		_align_up(connection_slot_count * size_of(u16)) +
		_align_up(connection_slot_count * size_of(tina.Handle)) +
		_align_up(connection_slot_count * size_of(u16))
}

@(private = "package")
_make_shard_runtime :: proc(
	allocator: mem.Allocator,
	server: ^Server_Runtime,
	router: ^Compiled_Router,
	connection_slot_count: u16,
	connection_type_id: u8,
) -> ^HTTP_Shard_Runtime {
	runtime_storage := make([]HTTP_Shard_Runtime, 1, allocator)
	idle_slot_indices := make([]u16, int(connection_slot_count), allocator)
	idle_slot_handles := make([]tina.Handle, int(connection_slot_count), allocator)
	idle_slot_positions := make([]u16, int(connection_slot_count), allocator)
	for index in 0 ..< len(idle_slot_positions) {
		idle_slot_positions[index] = u16(IDLE_ARRAY_INDEX_NONE)
	}

	runtime := &runtime_storage[0]
	runtime^ = HTTP_Shard_Runtime {
		server                = server^,
		router                = router,
		connection_type_id    = connection_type_id,
		keepalive_reserve     = server.keepalive_reserve_slots,
		idle_slot_indices     = idle_slot_indices,
		idle_slot_handles     = idle_slot_handles,
		idle_slot_positions   = idle_slot_positions,
		idle_count            = 0,
		free_count            = connection_slot_count,
		connection_slot_count = connection_slot_count,
		accept_backoff_ns     = 50_000_000,
	}
	return runtime
}

// Resolves the connection capacity used to size HTTP TypeDescriptor fields
// when the user mutates an existing spec. We trust the connection
// TypeDescriptor that was set up alongside install (Tier 2 / dev), and fall
// back to the dev default for hand-rolled specs.
@(private = "file")
_route_connection_slot_count :: proc(spec: ^tina.SystemSpec) -> u32 {
	for desc in spec.types {
		if desc.stride == size_of(HTTP_Connection) && desc.slot_count > 0 {
			return u32(desc.slot_count)
		}
	}
	return HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT
}

@(private = "file")
_max_buffered_body_size :: proc(routes: []Route) -> u32 {
	max_size: u32
	for route in routes {
		if route.body_mode == .Buffered && route.body_size_max > max_size {
			max_size = route.body_size_max
		}
	}
	return max_size
}

@(private = "package")
_max_route_state_size :: proc(routes: []Route) -> u16 {
	max_size: u16
	for route in routes {
		if route.state_size > max_size do max_size = route.state_size
	}
	return max_size
}

// Aligns to `align_of(uintptr)` (8 bytes on 64-bit). Keeps `Header_View[]`,
// `Param_View[]`, route-state casts, and sub-region boundaries naturally
// aligned without per-region custom math.
@(private = "package")
_align_up :: #force_inline proc "contextless" (n: int) -> int {
	a :: int(align_of(uintptr)) // 8 on 64-bit
	return (n + (a - 1)) & ~(a - 1)
}

@(private = "package")
_next_power_of_two_u64 :: proc "contextless" (n: u64) -> u64 {
	if n <= 1 do return 1
	v := n - 1
	v |= v >> 1
	v |= v >> 2
	v |= v >> 4
	v |= v >> 8
	v |= v >> 16
	v |= v >> 32
	return v + 1
}


// ─── Supervision tree wiring ────────────────────────────────────────────────
//
// Append shard infrastructure as static children of the shard's root group.
// In coordinator mode this is one ingress listener (shard 0) plus one
// dispatcher on every shard. Reserve `connection_slot_count` dynamic child
// slots so spawned connections have somewhere to live in the tree.

@(private = "file")
_attach_http_children :: proc(
	shard_spec: ^tina.ShardSpec,
	listener_type_id: u8,
	dispatcher_type_id: u8,
	include_listener: bool,
	include_dispatcher: bool,
	connection_slot_count: u16,
	listener_args_payload: [tina.MAX_INIT_ARGS_SIZE]u8,
	listener_args_size: u8,
	dispatcher_args_payload: [tina.MAX_INIT_ARGS_SIZE]u8,
	dispatcher_args_size: u8,
) {
	root := &shard_spec.root_group

	// Dynamic child capacity must accommodate every connection.
	if root.child_count_dynamic_max < connection_slot_count {
		root.child_count_dynamic_max = connection_slot_count
	}

	// Both listener and dispatcher get immutable boot-time args (server config,
	// compiled router pointer, slot sizing, and dynamic type ids).
	new_static := _append_static_children(
		root.children,
		listener_type_id,
		dispatcher_type_id,
		include_listener,
		include_dispatcher,
		listener_args_payload,
		listener_args_size,
		dispatcher_args_payload,
		dispatcher_args_size,
	)
	root.children = new_static
}

@(private = "file")
_append_static_children :: proc(
	existing: []tina.Child_Spec,
	listener_type_id: u8,
	dispatcher_type_id: u8,
	include_listener: bool,
	include_dispatcher: bool,
	listener_args_payload: [tina.MAX_INIT_ARGS_SIZE]u8,
	listener_args_size: u8,
	dispatcher_args_payload: [tina.MAX_INIT_ARGS_SIZE]u8,
	dispatcher_args_size: u8,
) -> []tina.Child_Spec {
	added := (include_listener ? 1 : 0) + (include_dispatcher ? 1 : 0)
	new_children := make([]tina.Child_Spec, len(existing) + added, context.allocator)
	copy(new_children, existing)
	child_index := len(existing)

	if include_listener {
		new_children[child_index] = tina.Static_Child_Spec {
			type_id      = listener_type_id,
			restart_type = .permanent,
			args_size    = listener_args_size,
			args_payload = listener_args_payload,
		}
		child_index += 1
	}

	if include_dispatcher {
		new_children[child_index] = tina.Static_Child_Spec {
			type_id      = dispatcher_type_id,
			restart_type = .permanent,
			args_size    = dispatcher_args_size,
			args_payload = dispatcher_args_payload,
		}
	}

	return new_children
}
// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

import "core:testing"

@(test)
test_normalize_zero_limits :: proc(t: ^testing.T) {
	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
	}
	_normalize_server_defaults(&server)

	testing.expect_value(t, server.limits, DEFAULT_LIMITS)
	testing.expect_value(t, server.timeouts, DEFAULT_TIMEOUTS)
	testing.expect_value(t, server.backlog, u32(HTTP_DEFAULT_BACKLOG))
}

@(test)
test_normalize_preserves_user_values :: proc(t: ^testing.T) {
	app := App{}
	custom_limits := DEFAULT_LIMITS
	custom_limits.header_count_max = 16
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
		limits  = custom_limits,
		backlog = 256,
	}
	_normalize_server_defaults(&server)

	testing.expect_value(t, server.limits.header_count_max, 16)
	testing.expect_value(t, server.backlog, u32(256))
}

@(test)
test_align_up :: proc(t: ^testing.T) {
	testing.expect_value(t, _align_up(0), 0)
	testing.expect_value(t, _align_up(1), 8)
	testing.expect_value(t, _align_up(7), 8)
	testing.expect_value(t, _align_up(8), 8)
	testing.expect_value(t, _align_up(9), 16)
	testing.expect_value(t, _align_up(127), 128)
}

@(test)
test_next_power_of_two_u64 :: proc(t: ^testing.T) {
	testing.expect_value(t, _next_power_of_two_u64(0), u64(1))
	testing.expect_value(t, _next_power_of_two_u64(1), u64(1))
	testing.expect_value(t, _next_power_of_two_u64(2), u64(2))
	testing.expect_value(t, _next_power_of_two_u64(3), u64(4))
	testing.expect_value(t, _next_power_of_two_u64(127), u64(128))
	testing.expect_value(t, _next_power_of_two_u64(128), u64(128))
	testing.expect_value(t, _next_power_of_two_u64(129), u64(256))
}

@(test)
test_compute_working_memory_size_bounded :: proc(t: ^testing.T) {
	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
		limits  = DEFAULT_LIMITS,
	}

	working_memory_size := _compute_working_memory_size(&server)

	// Floor: must include at least the request frame region + request arena.
	min_expected :=
		_align_up(int(DEFAULT_LIMITS.request_line_size_max) + int(DEFAULT_LIMITS.header_size_max)) +
		int(DEFAULT_LIMITS.request_arena_size)
	testing.expect(t, working_memory_size >= min_expected, "working_memory_size below floor")

	// Boundedness: every region is u16-bounded so total stays in a sane range.
	testing.expect(t, working_memory_size < 1 << 20, "working_memory_size suspiciously large")
}

@(test)
test_compute_working_memory_size_alignment :: proc(t: ^testing.T) {
	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
		limits  = DEFAULT_LIMITS,
	}

	working_memory_size := _compute_working_memory_size(&server)
	testing.expect(
		t,
		working_memory_size % align_of(uintptr) == 0,
		"working_memory_size must be aligned to uintptr",
	)
}

@(test)
test_install_development_defaults_produces_valid_spec :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
	}

	spec := install_development_defaults(&server)

	testing.expect_value(t, spec.shard_count, u8(1))
	testing.expect_value(t, spec.memory_init_mode, tina.Memory_Init_Mode.Development)
	testing.expect_value(t, spec.quarantine_policy, tina.Quarantine_Policy.Abort)
	testing.expect_value(t, spec.fd_handoff_entry_count, 0)
	testing.expect(t, len(spec.types) == 2, "dev install registers 2 HTTP types (no dispatcher)")
	testing.expect(t, len(spec.shard_specs) == 1, "dev install installs 1 shard spec")

	// Each shard's root group has the listener as a static child and
	// reserves dynamic capacity for the connection pool.
	root := spec.shard_specs[0].root_group
	testing.expect(t, len(root.children) >= 1, "root group must include the listener")
	testing.expect_value(
		t,
		root.child_count_dynamic_max,
		u16(HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT),
	)

	// Locate the connection TypeDescriptor and verify it carries the
	// derived working_memory_size and matching slot_count.
	found_connection := false
	for desc in spec.types {
		if desc.stride == size_of(HTTP_Connection) {
			testing.expect_value(t, desc.slot_count, HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT)
			testing.expect(t, desc.working_memory_size > 0, "connection working memory must be > 0")
			testing.expect(
				t,
				desc.scratch_requirement_max >= HTTP_INTERNAL_SCRATCH_NEED,
				"scratch must include internal floor",
			)
			found_connection = true
		}
	}
	testing.expect(t, found_connection, "HTTP_Connection TypeDescriptor must be installed")
}

@(test)
test_install_make_system_spec_multi_shard_includes_dispatcher :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	when ODIN_OS == .Windows {
		// Multi-shard HTTP install is rejected on Windows; covered by the
		// _windows_ test below. Skip here.
		return
	}

	app := App{}
	server := Server {
		address      = tina.ipv4(127, 0, 0, 1, 8080),
		app          = &app,
		distribution = .Coordinator,
	}

	spec := install_make_system_spec(&server, 2, 64)

	testing.expect_value(t, spec.shard_count, u8(2))
	testing.expect_value(t, spec.memory_init_mode, tina.Memory_Init_Mode.Production)
	testing.expect(t, spec.fd_handoff_entry_count > 0, "multi-shard requires fd_handoff_entry_count > 0")
	testing.expect_value(t, len(spec.types), 3) // listener + connection + dispatcher

	// Coordinator topology: one ingress listener on shard 0, one dispatcher on
	// every shard.
	for shard_index in 0 ..< len(spec.shard_specs) {
		root := spec.shard_specs[shard_index].root_group
		static_count := 0
		for child in root.children {
			if _, is_static := child.(tina.Static_Child_Spec); is_static {
				static_count += 1
			}
		}
		expected_static_count := 1
		if shard_index == 0 {
			expected_static_count = 2
		}
		testing.expect(
			t,
			static_count == expected_static_count,
			fmt.tprintf("shard %d static children mismatch", shard_index),
		)
	}
}

@(test)
test_install_make_system_spec_multi_shard_defaults_to_coordinator :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	when ODIN_OS == .Windows {
		return
	}

	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
	}

	spec := install_make_system_spec(&server, 2, 64)

	// Derive expected type ids from the spec rather than from constants:
	// after install, HTTP types occupy the tail of `spec.types`. Reading the
	// ids back out of the descriptor table is the same lookup the supervision
	// tree did at install time.
	base_type_id := u8(len(spec.types) - 3) // listener + connection + dispatcher
	listener_type_id := base_type_id + HTTP_TYPE_OFFSET_LISTENER
	dispatcher_type_id := base_type_id + HTTP_TYPE_OFFSET_DISPATCHER

	for shard_index in 0 ..< len(spec.shard_specs) {
		root := spec.shard_specs[shard_index].root_group
		listener_count := 0
		dispatcher_count := 0
		for child in root.children {
			static_child, ok := child.(tina.Static_Child_Spec)
			if !ok do continue
			if static_child.type_id == listener_type_id do listener_count += 1
			if static_child.type_id == dispatcher_type_id do dispatcher_count += 1
		}
		expected_listener_count := 0
		if shard_index == 0 {
			expected_listener_count = 1
		}
		testing.expect_value(t, listener_count, expected_listener_count)
		testing.expect_value(t, dispatcher_count, 1)
	}
}

// Verifies that `install_into_system_spec` appends HTTP TypeDescriptors at
// `len(spec.types) + HTTP_TYPE_OFFSET_<role>` rather than at fixed absolute
// IDs. We seed the spec with a stub TypeDescriptor first so the HTTP types
// are forced off the [0..2] offsets and any accidental hardcoding of those
// values would surface as a mismatch between the supervision wiring (which
// reads the dynamic id) and the installed descriptor table.
@(test)
test_install_into_system_spec_is_position_independent :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
	}

	// Build a single-shard spec by hand and pre-register one external type at
	// id 0 so HTTP types cannot land at offset 0.
	stub_init :: proc(self: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
		return tina.Effect_Receive{}
	}
	stub_handler :: proc(self: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
		return tina.Effect_Receive{}
	}
	external_types := []tina.TypeDescriptor {
		{
			id                      = 0,
			slot_count              = 1,
			stride                  = 8,
			soa_metadata_size       = size_of(tina.Isolate_Metadata),
			working_memory_size     = 0,
			scratch_requirement_max = 0,
			mailbox_capacity        = 4,
			init_handler            = stub_init,
			handler_fn              = stub_handler,
		},
	}

	spec := _make_base_system_spec(
		&server,
		1,
		HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT,
		.Development,
		HTTP_DEV_SHUTDOWN_TIMEOUT_MS,
		HTTP_DEV_DEFAULT_RING_SIZE,
	)
	spec.types = external_types

	install_into_system_spec(&spec, &server)

	// HTTP types must be appended *after* the stub at the documented offsets.
	expected_listener_id := u8(1) + HTTP_TYPE_OFFSET_LISTENER
	expected_connection_id := u8(1) + HTTP_TYPE_OFFSET_CONNECTION

	testing.expect_value(t, len(spec.types), 3) // stub + listener + connection (single shard, no dispatcher)
	testing.expect_value(t, spec.types[0].id, u8(0))
	testing.expect_value(t, spec.types[expected_listener_id].id, expected_listener_id)
	testing.expect_value(t, spec.types[expected_connection_id].id, expected_connection_id)

	// The supervision tree must reference the *dynamic* listener id, not the
	// HTTP_TYPE_OFFSET_LISTENER constant.
	root := spec.shard_specs[0].root_group
	found_listener_child := false
	for child in root.children {
		static_child, ok := child.(tina.Static_Child_Spec)
		if !ok do continue
		if static_child.type_id == expected_listener_id {
			found_listener_child = true
		}
		// No HTTP child should reference the stub type id.
		testing.expect(t, static_child.type_id != 0, "HTTP wiring must not collide with pre-installed type")
	}
	testing.expect(t, found_listener_child, "listener child must use dynamic type id")

	// Connection TypeDescriptor's stored id must equal the dynamic id, so
	// `runtime.connection_type_id` (set from install args) and the descriptor
	// table agree at boot.
	testing.expect_value(t, spec.types[expected_connection_id].stride, size_of(HTTP_Connection))
}
