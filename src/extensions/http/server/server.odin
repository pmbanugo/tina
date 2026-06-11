package http_server

import tina "../../.."
import "core:fmt"
import "core:mem"

// ═══════════════════════════════════════════════════════════════════════════
// Tina HTTP — Phase 6: System Integration & Boot Sequence
//
// Wires the parser/router/response data structures from Phases 1–5 into
// Tina's memory model: TypeDescriptors, supervision tree, working-memory
// derivation, and the explicit install entry points.
//
// References:
//   - HTTP_LIBRARY_SYSTEM_INTEGRATION.md  (Isolate types, install API, sharding)
//   - HTTP_LIBRARY_MEMORY_LAYOUT.md       (working_memory_size derivation)
//   - HTTP_LIBRARY_RUNTIME_POLICIES.md    (timeouts, drain, Date cache)
//
// Phase 6 ownership: type definitions, install/wire, derivation math,
// boot-time guards. The hot-path init/handler procedures are stubbed to
// `ISOLATE_TRANSITION_WAIT_MESSAGE` here; Phase 7+ replaces them with the real state machines.
// ═══════════════════════════════════════════════════════════════════════════

// `App` holds the user-declared route table.
App :: struct {
	routes: []Route,
}

// Multi-shard ingress strategy. `Coordinator` is the primary path; one
// exclusive ingress listener accepts locally and fans out via cross-shard FD
// handoff. `Reuse_Port` is an explicit multi-shard fallback that delegates
// accept distribution to the kernel.
Ingress_Mode :: enum u8 {
	Coordinator,
	Reuse_Port,
}

@(private = "package")
Listener_Bind_Mode :: enum u8 {
	Exclusive,
	Reuse_Port,
}

@(private = "package")
Ingress_Topology_Error :: enum u8 {
	None,
	Reuse_Port_Requires_Multi_Shard,
}

@(private = "package")
HTTP_Ingress_Topology :: struct {
	ingress_mode:             Ingress_Mode,
	bind_mode:                Listener_Bind_Mode,
	coordinator_mode_enabled: bool,
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
	ingress_mode:      Ingress_Mode,
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
	ingress_mode:           Ingress_Mode,
	limits:                 Limits,
	timeouts:               Timeouts,
	keepalive_reserve_slots: u16,
	graceful_drain_ms:      u32,
	buffered_body_size_max: u32,
	route_state_size_max:   u16,
}

// Per-request opaque token stamped at request_start. Exposed to handlers via
// `route_request_token` and intended to be embedded in pub/sub payloads so
// subscribers can detect stale notifications targeting a previous request on
// a reused keep-alive connection.
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

// Number of allocated connection slots currently tracked for runtime bookkeeping.
@(private = "package")
Active_Array_Count :: distinct u16

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
	source_handle: tina.Isolate_Handle,
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
	router:               Compiled_Router,
	connection_type_id:    tina.Isolate_Type_Id,
	date_cache:           Date_Cache,
	draining:             bool,
	next_request_token:   Request_Token, // monotonic across the shard
	keepalive_reserve:    u16, // mirrors Keepalive_Config.reserve_slots
	active_slot_indices:   []u16, // dense swap-and-pop tracker for allocated connections
	active_connections:    []^HTTP_Connection,
	active_slot_positions: []u16,
	active_count:          Active_Array_Count,
	idle_slot_indices:    []u16, // dense swap-and-pop tracker
	idle_slot_handles:    []tina.Isolate_Handle,
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
	dispatcher_handles:         []tina.Isolate_Handle,
	next_dispatcher_shard_index: u8,
	accept_backoff_ns:          u64,
}

// One per shard, only instantiated in multi-shard `Coordinator` mode.
// Long-lived. Receives cross-shard FD handoff adoptions and spawns
// shard-local `HTTP_Connection` per accepted FD.
// Strictly L4 — does no HTTP parsing.
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
	deadline_timer_handle:      tina.Timer_Handle,
	deadline_ns:                tina.Monotonic_Time_NS,
	fd:                         tina.FD_Handle,
	request_token:              Request_Token,
	application_expectation_kind: Application_Expectation_Kind,
	application_expected_source: tina.Isolate_Handle,
	application_expected_tag:    Message_Tag,
	application_correlation_id:  tina.Correlation_Id,
	application_timeout_ns:      u64,
	application_pending_message:  Application_Pending_Message,
	self_handle:                 tina.Isolate_Handle,
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
	request_arena_region:        mem.Arena,
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
	connection_type_id:       tina.Isolate_Type_Id,
	dispatcher_type_id:       tina.Isolate_Type_Id,
	dispatcher_shard_count:   u8,
}

@(private = "package")
HTTP_Dispatcher_Init_Args :: struct {
	server:                ^Server_Runtime,
	router:                ^Compiled_Router,
	connection_slot_count: u16,
	connection_type_id:    tina.Isolate_Type_Id,
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
// at install time, then assigns each HTTP IsolateTypeDescriptor as
// `base_type_id + HTTP_TYPE_OFFSET_<role>`. This keeps the install contract
// position-independent: callers may register their own TypeDescriptors before
// (or after) HTTP install and the wiring still resolves correctly.
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
// Library-chosen ceilings for the development installer. Production and
// mutating installers require explicit capacity from the caller.

@(private = "package")
HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT :: 128
@(private = "package")
HTTP_DEV_TIMER_RESOLUTION_NS :: 1_000_000 // 1 ms
@(private = "package")
HTTP_DEV_LOG_RING_SIZE :: 4096
@(private = "package")
HTTP_DEV_TRANSFER_SLOT_COUNT :: 16
@(private = "package")
HTTP_DEV_TRANSFER_SLOT_SIZE :: 4096
@(private = "package")
HTTP_DEV_REACTOR_BUFFER_SLOT_SIZE :: 16384
@(private = "package")
HTTP_DEV_STAGING_SLOT_COUNT :: 4
@(private = "package")
HTTP_DEV_STAGING_SLOT_SIZE :: 4096
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


// ─── Mailbox & Pool Capacity Constants ──────────────────────────────────────
//
// Derived from the HTTP connection state machine's message flow.
//
// The connection is a sequential reactive handler. The dispatch priority is:
//   IO_Completion > Shutdown > Inbox (pool-backed)
//
// Pool-backed system messages that bypass mailbox_capacity:
//   - 1 deadline timeout  (core timer wheel → _enqueue_system_msg)
//   - 1 application timer (core timer wheel → _enqueue_system_msg)
//
// Pool-backed user messages subject to mailbox_capacity:
//   - 1 application reply/notification (from expect_reply/expect_notification)
//   - 1 TAG_EVICT (from listener idle-slot eviction)
//   - 2 headroom for unsolicited application-layer messages

// User-message mailbox depth per isolate type.
@(private = "package")
HTTP_CONNECTION_MAILBOX_CAPACITY :: 4
@(private = "package")
HTTP_LISTENER_MAILBOX_CAPACITY :: 4
@(private = "package")
HTTP_DISPATCHER_MAILBOX_CAPACITY :: 4

// System messages per connection that bypass mailbox_capacity but consume pool
// envelopes: 1 deadline timeout + 1 application timer.
@(private = "package")
HTTP_SYSTEM_MESSAGES_PER_CONNECTION :: 2


// ─── Install API — Public API ───────────────────────────────────────────────
//
// Explicit API surface:
//   - `install_into_system_spec` mutates an existing SystemSpec using an
//     explicit per-shard connection capacity.
//   - `install` builds a production SystemSpec, then delegates to the mutating
//     primitive with the same explicit capacity.
//   - `install_development` builds a single-shard development SystemSpec with
//     explicit connection capacity.
//   - `install_development_defaults` is the only entry point that invents a
//     connection capacity on behalf of the caller.


// ─── Tier 1: mutate an existing SystemSpec ──────────────────────────────────

install_into_system_spec :: proc(
	spec: ^tina.SystemSpec,
	server: ^Server,
	connection_slot_count: u32,
) {
	assert(spec != nil, "install_into_system_spec: spec is nil")
	assert(server != nil, "install_into_system_spec: server is nil")
	assert(server.app != nil, "install_into_system_spec: server.app is nil — nothing to install")
	assert(
		connection_slot_count >= 1,
		"install_into_system_spec: connection_slot_count must be >= 1",
	)
	assert(
		connection_slot_count <= 65_535,
		"install_into_system_spec: connection_slot_count exceeds u16 idle-tracker width",
	)

	_normalize_server_defaults(server)
	connection_slot_count_per_shard := u16(connection_slot_count)

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

	assert(
		len(server.app.routes) <= 254,
		"too many routes (Route_Index reserves 0xFF as ROUTE_INDEX_NONE; 254 is the conservative cap)",
	)
	assert(
		spec.timer_resolution_ns <= 1_000_000_000,
		"timer_resolution_ns must be <= 1 s (Date cache lower bound)",
	)

	topology, topology_error := _derive_http_ingress_topology(spec.shard_count, server.ingress_mode)
	assert(
		topology_error == .None,
		"install_into_system_spec: `server.ingress_mode = .Reuse_Port` requires shard_count > 1; single-shard HTTP always binds exclusively",
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
	coordinator_mode_enabled := topology.coordinator_mode_enabled

	// --- Derive memory budgets ---
	working_memory_size := _compute_working_memory_size(server)
	scratch_requirement := _compute_scratch_requirement(server)

	// Raise spec.scratch_arena_size if HTTP requires more than the caller set.
	// Never lower an explicit user value.
	if spec.scratch_arena_size < scratch_requirement {
		spec.scratch_arena_size = scratch_requirement
	}

	spec.timer_entry_count = max(
		spec.timer_entry_count,
		int(connection_slot_count_per_shard),
	)

	// --- Append HTTP TypeDescriptors ---
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
	base_type_index := len(spec.types)

	listener_type_id := tina.Isolate_Type_Id(base_type_index + HTTP_TYPE_OFFSET_LISTENER)
	connection_type_id := tina.Isolate_Type_Id(base_type_index + HTTP_TYPE_OFFSET_CONNECTION)
	dispatcher_type_id := tina.Isolate_Type_Id(base_type_index + HTTP_TYPE_OFFSET_DISPATCHER)

	listener_init_args := HTTP_Listener_Init_Args {
		server                = server_runtime,
		router                = router,
		connection_slot_count = connection_slot_count_per_shard,
		connection_type_id    = connection_type_id,
		dispatcher_type_id    = dispatcher_type_id,
		dispatcher_shard_count = spec.shard_count,
	}
	listener_args_payload, listener_args_size := tina.init_args_of(&listener_init_args)

	dispatcher_init_args := HTTP_Dispatcher_Init_Args {
		server                = server_runtime,
		router                = router,
		connection_slot_count = connection_slot_count_per_shard,
		connection_type_id    = connection_type_id,
	}
	dispatcher_args_payload, dispatcher_args_size := tina.init_args_of(&dispatcher_init_args)

	new_types := make(
		[]tina.IsolateTypeDescriptor,
		len(spec.types) + http_type_count,
		context.allocator,
	)
	copy(new_types, spec.types)

	new_types[listener_type_id] = tina.IsolateTypeDescriptor {
		id                      = listener_type_id,
		slot_count              = 1,
		stride                  = size_of(HTTP_Listener),
		soa_metadata_size       = size_of(tina.Isolate_Metadata),
		working_memory_size     = _listener_working_memory_size(int(connection_slot_count_per_shard)),
		scratch_requirement_max = HTTP_INTERNAL_SCRATCH_NEED,
		mailbox_capacity        = HTTP_LISTENER_MAILBOX_CAPACITY,
		// The listener bootstraps the shard-local runtime and drives accept.
		// Its init args carry the immutable boot-time config.
		// The runtime lives in the listener's working arena.
		init_handler            = _http_listener_init,
		handler_fn              = _http_listener_handler,
	}

	new_types[connection_type_id] = tina.IsolateTypeDescriptor {
		id                      = connection_type_id,
		slot_count              = int(connection_slot_count_per_shard),
		stride                  = size_of(HTTP_Connection),
		soa_metadata_size       = size_of(tina.Isolate_Metadata),
		working_memory_size     = working_memory_size,
		scratch_requirement_max = scratch_requirement,
		mailbox_capacity        = HTTP_CONNECTION_MAILBOX_CAPACITY,
		init_handler            = _http_connection_init,
		handler_fn              = _http_connection_handler,
	}

	if include_dispatcher {
		new_types[dispatcher_type_id] = tina.IsolateTypeDescriptor {
			id                      = dispatcher_type_id,
			slot_count              = 1,
			stride                  = size_of(HTTP_Dispatcher),
			soa_metadata_size       = size_of(tina.Isolate_Metadata),
			working_memory_size     = _listener_working_memory_size(int(connection_slot_count_per_shard)),
			scratch_requirement_max = HTTP_INTERNAL_SCRATCH_NEED,
			mailbox_capacity        = HTTP_DISPATCHER_MAILBOX_CAPACITY,
			init_handler            = _http_dispatcher_init,
			handler_fn              = _http_dispatcher_handler,
		}
	}

	spec.types = new_types

	// --- Raise pool_slot_count if total mailbox demand exceeds current budget ---
	theoretical_mailbox_demand: int = 0
	for t in spec.types {
		theoretical_mailbox_demand += t.slot_count * int(t.mailbox_capacity)
	}
	// The pool must also absorb system messages (deadline timeouts, timer events)
	// that bypass mailbox_capacity but still allocate from the pool. Budget for
	// those on top of the user-message demand.
	system_message_demand := int(connection_slot_count_per_shard) * HTTP_SYSTEM_MESSAGES_PER_CONNECTION
	required_pool_slot_count := int(
		_next_power_of_two_u64(u64(theoretical_mailbox_demand + system_message_demand) * 2),
	)
	if spec.pool_slot_count < required_pool_slot_count {
		spec.pool_slot_count = required_pool_slot_count
	}

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
			connection_slot_count_per_shard,
			listener_args_payload,
			listener_args_size,
			dispatcher_args_payload,
			dispatcher_args_size,
		)
	}
}


// ─── Production convenience installer ───────────────────────────────────────

install :: proc(
	server: ^Server,
	shard_count: u8,
	connection_slot_count: u32,
) -> tina.SystemSpec {
	assert(server != nil, "install: server is nil")
	assert(server.app != nil, "install: server.app is nil")
	assert(shard_count >= 1, "install: shard_count must be >= 1")
	assert(
		connection_slot_count >= 1,
		"install: connection_slot_count must be >= 1",
	)

	spec := _make_base_system_spec(
		server,
		shard_count,
		connection_slot_count,
		.Production,
		HTTP_PROD_SHUTDOWN_TIMEOUT_MS,
		HTTP_PROD_DEFAULT_RING_SIZE,
	)
	install_into_system_spec(&spec, server, connection_slot_count)
	return spec
}


// ─── Development installers ─────────────────────────────────────────────────

install_development_defaults :: proc(server: ^Server) -> tina.SystemSpec {
	return install_development(server, HTTP_DEV_CONNECTION_SLOT_COUNT_DEFAULT)
}

install_development :: proc(
	server: ^Server,
	connection_slot_count: u32,
) -> tina.SystemSpec {
	assert(server != nil, "install_development: server is nil")
	assert(server.app != nil, "install_development: server.app is nil")
	assert(connection_slot_count >= 1, "connection_slot_count must be >= 1")

	spec := _make_base_system_spec(
		server,
		1, // single shard
		connection_slot_count,
		.Development,
		HTTP_DEV_SHUTDOWN_TIMEOUT_MS,
		HTTP_DEV_DEFAULT_RING_SIZE,
	)
	spec.quarantine_policy = .Abort
	install_into_system_spec(&spec, server, connection_slot_count)
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

// Derives the runtime ingress topology from the public configuration.
// Single-shard HTTP always binds exclusively. `Reuse_Port` is valid only in
// multi-shard mode, where it replaces coordinator routing with kernel-level
// accept distribution.
@(private = "package")
_derive_http_ingress_topology :: proc(
	shard_count: u8,
	ingress_mode: Ingress_Mode,
) -> (
	HTTP_Ingress_Topology,
	Ingress_Topology_Error,
) {
	topology := HTTP_Ingress_Topology {
		ingress_mode             = ingress_mode,
		bind_mode                = .Exclusive,
		coordinator_mode_enabled = false,
	}

	if shard_count <= 1 {
		if ingress_mode == .Reuse_Port {
			return topology, .Reuse_Port_Requires_Multi_Shard
		}
		return topology, .None
	}

	if ingress_mode == .Reuse_Port {
		topology.bind_mode = .Reuse_Port
		return topology, .None
	}

	topology.coordinator_mode_enabled = true
	return topology, .None
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

// Builds a production-shaped SystemSpec from HTTP-derived parameters.
// Capacity is derived from actual structural pressure points: pool-backed
// queues keep power-of-two sizing where the core requires it, while direct
// counts stay exact so validators can enforce the real ceiling.
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

	// Pool must cover user messages (bounded by mailbox_capacity per slot) plus
	// system messages that bypass capacity but still consume pool envelopes.
	// the 2× factor ensures the user-message ceiling
	// stays below that threshold with headroom for system messages.
	pool_user_demand :=
		int(connection_slot_count) * int(HTTP_CONNECTION_MAILBOX_CAPACITY) +
		int(HTTP_LISTENER_MAILBOX_CAPACITY) +
		(shard_count > 1 ? int(HTTP_DISPATCHER_MAILBOX_CAPACITY) : 0)
	pool_system_demand := int(connection_slot_count) * HTTP_SYSTEM_MESSAGES_PER_CONNECTION
	pool_slot_count := int(_next_power_of_two_u64(max(u64(1024), u64(pool_user_demand + pool_system_demand) * 2)))
	timer_entry_count := _derive_timer_entry_count(connection_slot_count, shard_count)
	reactor_buffer_slot_count := int(min(u64(4094), max(u64(64), u64(connection_slot_count))))

	fd_handoff_entry_count := 0
	if shard_count > 1 {
		fd_handoff_entry_count = int(max(u64(16), u64(connection_slot_count) / 4))
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
		staging_slot_count        = HTTP_DEV_STAGING_SLOT_COUNT,
		staging_slot_size         = HTTP_DEV_STAGING_SLOT_SIZE,
		transfer_slot_count       = HTTP_DEV_TRANSFER_SLOT_COUNT,
		transfer_slot_size        = HTTP_DEV_TRANSFER_SLOT_SIZE,
		fd_handoff_entry_count    = fd_handoff_entry_count,
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

@(private = "file")
_derive_timer_entry_count :: proc "contextless" (
	connection_slot_count: u32,
	shard_count: u8,
) -> int {
	// Both renewable (reserved) and one-shot timers share the unified timer pool.
	// Budget includes connection deadlines plus headroom for application timers,
	// listener accept backoff, and route-owned timers.
	entry_count := u64(connection_slot_count) * 4
	entry_count += u64(shard_count) * 64
	if entry_count < 2048 {
		entry_count = 2048
	}
	return int(entry_count)
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
		ingress_mode           = server.ingress_mode,
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
// active/idle slot tracker arrays. Sized to the connection capacity.
@(private = "package")
_listener_working_memory_size :: #force_inline proc "contextless" (
	connection_slot_count: int,
) -> int {
	return _align_up(size_of(HTTP_Shard_Runtime)) +
		_align_up(connection_slot_count * size_of(u16)) +
		_align_up(connection_slot_count * size_of(^HTTP_Connection)) +
		_align_up(connection_slot_count * size_of(u16)) +
		_align_up(connection_slot_count * size_of(u16)) +
		_align_up(connection_slot_count * size_of(tina.Isolate_Handle)) +
		_align_up(connection_slot_count * size_of(u16))
}

@(private = "package")
_make_shard_runtime :: proc(
		allocator: mem.Allocator,
		server: ^Server_Runtime,
		router: ^Compiled_Router,
		connection_slot_count: u16,
		connection_type_id: tina.Isolate_Type_Id,
	) -> ^HTTP_Shard_Runtime {
	runtime_storage := make([]HTTP_Shard_Runtime, 1, allocator)
	active_slot_indices := make([]u16, int(connection_slot_count), allocator)
	active_connections := make([]^HTTP_Connection, int(connection_slot_count), allocator)
	active_slot_positions := make([]u16, int(connection_slot_count), allocator)
	idle_slot_indices := make([]u16, int(connection_slot_count), allocator)
	idle_slot_handles := make([]tina.Isolate_Handle, int(connection_slot_count), allocator)
	idle_slot_positions := make([]u16, int(connection_slot_count), allocator)
	for index in 0 ..< len(active_slot_positions) {
		active_slot_positions[index] = u16(IDLE_ARRAY_INDEX_NONE)
	}
	for index in 0 ..< len(idle_slot_positions) {
		idle_slot_positions[index] = u16(IDLE_ARRAY_INDEX_NONE)
	}

	runtime := &runtime_storage[0]
	runtime^ = HTTP_Shard_Runtime {
		server                = server^,
		router                = router^,
		connection_type_id    = connection_type_id,
		keepalive_reserve     = server.keepalive_reserve_slots,
		active_slot_indices   = active_slot_indices,
		active_connections    = active_connections,
		active_slot_positions = active_slot_positions,
		active_count          = 0,
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
	listener_type_id: tina.Isolate_Type_Id,
	dispatcher_type_id: tina.Isolate_Type_Id,
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
	listener_type_id: tina.Isolate_Type_Id,
	dispatcher_type_id: tina.Isolate_Type_Id,
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

	// Locate the connection IsolateTypeDescriptor and verify it carries the
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
	testing.expect(t, found_connection, "HTTP_Connection IsolateTypeDescriptor must be installed")
}

@(test)
test_install_development_respects_explicit_connection_capacity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	app := App{}
	server := Server {
		address = tina.ipv4(127, 0, 0, 1, 8080),
		app     = &app,
	}

	spec := install_development(&server, 257)

	root := spec.shard_specs[0].root_group
	testing.expect_value(t, root.child_count_dynamic_max, u16(257))

	found_connection := false
	for desc in spec.types {
		if desc.stride == size_of(HTTP_Connection) {
			testing.expect_value(t, desc.slot_count, 257)
			found_connection = true
		}
	}
	testing.expect(t, found_connection, "HTTP_Connection IsolateTypeDescriptor must be installed")
}

@(test)
test_install_multi_shard_includes_dispatcher :: proc(t: ^testing.T) {
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
		ingress_mode = .Coordinator,
	}

	spec := install(&server, 2, 64)

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
test_derive_http_ingress_topology_single_shard_is_exclusive :: proc(t: ^testing.T) {
	topology, topology_error := _derive_http_ingress_topology(1, .Coordinator)

	testing.expect_value(t, topology_error, Ingress_Topology_Error.None)
	testing.expect_value(t, topology.bind_mode, Listener_Bind_Mode.Exclusive)
	testing.expect(t, !topology.coordinator_mode_enabled, "single-shard HTTP must not enable coordinator routing")
}

@(test)
test_derive_http_ingress_topology_single_shard_rejects_reuse_port :: proc(t: ^testing.T) {
	_, topology_error := _derive_http_ingress_topology(1, .Reuse_Port)

	testing.expect_value(t, topology_error, Ingress_Topology_Error.Reuse_Port_Requires_Multi_Shard)
}

@(test)
test_derive_http_ingress_topology_multi_shard_coordinator_is_exclusive :: proc(t: ^testing.T) {
	topology, topology_error := _derive_http_ingress_topology(4, .Coordinator)

	testing.expect_value(t, topology_error, Ingress_Topology_Error.None)
	testing.expect_value(t, topology.bind_mode, Listener_Bind_Mode.Exclusive)
	testing.expect(t, topology.coordinator_mode_enabled, "multi-shard coordinator mode must enable explicit dispatcher routing")
}

@(test)
test_derive_http_ingress_topology_multi_shard_reuse_port_is_kernel_distributed :: proc(t: ^testing.T) {
	topology, topology_error := _derive_http_ingress_topology(4, .Reuse_Port)

	testing.expect_value(t, topology_error, Ingress_Topology_Error.None)
	testing.expect_value(t, topology.bind_mode, Listener_Bind_Mode.Reuse_Port)
	testing.expect(t, !topology.coordinator_mode_enabled, "reuse-port mode must not instantiate coordinator routing")
}

@(test)
test_install_multi_shard_defaults_to_coordinator :: proc(t: ^testing.T) {
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

	spec := install(&server, 2, 64)

	// Derive expected type ids from the spec rather than from constants:
	// after install, HTTP types occupy the tail of `spec.types`. Reading the
	// ids back out of the descriptor table is the same lookup the supervision
	// tree did at install time.
	base_type_index := len(spec.types) - 3 // listener + connection + dispatcher
	listener_type_id := tina.Isolate_Type_Id(base_type_index + HTTP_TYPE_OFFSET_LISTENER)
	dispatcher_type_id := tina.Isolate_Type_Id(base_type_index + HTTP_TYPE_OFFSET_DISPATCHER)

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
// IDs. We seed the spec with a stub IsolateTypeDescriptor first so the HTTP types
// are forced off the [0..2] offsets and any accidental hardcoding of those
// values would surface as a mismatch between the supervision wiring (which
// reads the dynamic id) and the installed descriptor table. This also verifies
// that Tier 1 uses the caller's explicit connection capacity instead of any
// pre-existing descriptor inference or hidden default.
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
	stub_init :: proc(self: rawptr, args: []u8) -> tina.Isolate_Transition {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
	stub_handler :: proc(self: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
	external_types := []tina.IsolateTypeDescriptor {
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

	install_into_system_spec(&spec, &server, 257)

	// HTTP types must be appended *after* the stub at the documented offsets.
	expected_listener_id := tina.Isolate_Type_Id(1 + HTTP_TYPE_OFFSET_LISTENER)
	expected_connection_id := tina.Isolate_Type_Id(1 + HTTP_TYPE_OFFSET_CONNECTION)

	testing.expect_value(t, len(spec.types), 3) // stub + listener + connection (single shard, no dispatcher)
	testing.expect_value(t, spec.types[0].id, tina.Isolate_Type_Id(0))
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
		testing.expect(t, static_child.type_id != tina.Isolate_Type_Id(0), "HTTP wiring must not collide with pre-installed type")
	}
	testing.expect(t, found_listener_child, "listener child must use dynamic type id")

	// Connection IsolateTypeDescriptor's stored id must equal the dynamic id, so
	// `runtime.connection_type_id` (set from install args) and the descriptor
	// table agree at boot.
	testing.expect_value(t, spec.types[expected_connection_id].stride, size_of(HTTP_Connection))
	testing.expect_value(t, spec.types[expected_connection_id].slot_count, 257)
	testing.expect_value(t, root.child_count_dynamic_max, u16(257))
}
