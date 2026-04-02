package tina

import "core:fmt"
import "core:mem"
import "core:os"

DEMO_ECHO_ROOT_RESTART_MAX :: #config(TINA_DEMO_ECHO_ROOT_RESTART_MAX, 5)
DEMO_ECHO_ROOT_WINDOW_TICKS :: #config(TINA_DEMO_ECHO_ROOT_WINDOW_TICKS, 10_000)
DEMO_ECHO_CHAOS_RESTART_MAX :: #config(TINA_DEMO_ECHO_CHAOS_RESTART_MAX, 3)
DEMO_ECHO_CHAOS_WINDOW_TICKS :: #config(TINA_DEMO_ECHO_CHAOS_WINDOW_TICKS, 1_000)
DEMO_ECHO_SHARD_RESTART_MAX :: #config(TINA_DEMO_ECHO_SHARD_RESTART_MAX, 2)
DEMO_ECHO_SHARD_RESTART_WINDOW_MS :: #config(TINA_DEMO_ECHO_SHARD_RESTART_WINDOW_MS, 30_000)
DEMO_ECHO_ABORT_ON_QUARANTINE :: #config(TINA_DEMO_ECHO_ABORT_ON_QUARANTINE, false)
DEMO_ECHO_CHAOS_START_TICK :: #config(TINA_DEMO_ECHO_CHAOS_START_TICK, 5_000)
DEMO_ECHO_CHAOS_END_TICK :: #config(TINA_DEMO_ECHO_CHAOS_END_TICK, 6_000)

// ============================================================================
// Type Identifiers and Message Tags
// ============================================================================

SERVER_LISTENER_ISOLATE_TYPE: u8 : 0
SERVER_CONN_ISOLATE_TYPE: u8 : 1
CLIENT_ISOLATE_TYPE: u8 : 2
CHAOS_ISOLATE_TYPE: u8 : 3

TAG_CLIENT_TIMER: Message_Tag : USER_MESSAGE_TAG_BASE + 1

// ============================================================================
// Payloads and Message Structs
// ============================================================================

Packet :: struct {
	sequence_number: u32,
	payload:         [16]u8, // e.g., "PING" or "PONG"
}

ConnectionArgs :: struct {
	client_file_descriptor: FD_Handle,
}

// ============================================================================
// Server Listener Isolate
// ============================================================================

ServerListenerIsolate :: struct {
	listen_file_descriptor: FD_Handle,
}

server_listener_init :: proc(self_raw: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
	self := self_as(ServerListenerIsolate, self_raw, ctx)

	file_descriptor, socket_err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
	if socket_err != .None {
		return Effect_Crash{reason = .Init_Failed}
	}
	self.listen_file_descriptor = file_descriptor

	ctx_setsockopt(ctx, self.listen_file_descriptor, .SOL_SOCKET, .SO_REUSEADDR, true)
	ctx_bind(ctx, self.listen_file_descriptor, ipv4(127, 0, 0, 1, 9090))
	ctx_listen(ctx, self.listen_file_descriptor, 128)

	str := fmt.bprintf(ctx.scratch_arena.data, "TCP Server listening on 127.0.0.1:9090")
	ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)str)

	return Effect_Io{operation = IoOp_Accept{listen_fd = self.listen_file_descriptor}}
}

server_listener_handler :: proc(self_raw: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
	self := self_as(ServerListenerIsolate, self_raw, ctx)

	switch message.tag {
	case IO_TAG_ACCEPT_COMPLETE:
		if message.io.result >= 0 {
			connection_args := ConnectionArgs {
				client_file_descriptor = message.io.fd,
			}
			payload_buffer, payload_size := init_args_of(&connection_args)

			spec := Spawn_Spec {
				type_id      = SERVER_CONN_ISOLATE_TYPE,
				group_id     = ctx_supervision_group_id(ctx),
				restart_type = .temporary,
				args_payload = payload_buffer,
				args_size    = payload_size,
				handoff_fd   = message.io.fd,
				handoff_mode = .Full,
			}
			_ = ctx_spawn(ctx, spec)
		}
		return Effect_Io{operation = IoOp_Accept{listen_fd = self.listen_file_descriptor}}

	case:
		return Effect_Receive{}
	}
}

// ============================================================================
// Server Connection Isolate (Echo Response)
// ============================================================================

ServerConnIsolate :: struct {
	client_file_descriptor: FD_Handle,
	buffer:                 [128]u8,
}

server_conn_init :: proc(self_raw: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
	self := self_as(ServerConnIsolate, self_raw, ctx)
	connection_args := payload_as(ConnectionArgs, args)
	self.client_file_descriptor = connection_args.client_file_descriptor

	ctx_setsockopt(ctx, self.client_file_descriptor, .IPPROTO_TCP, .TCP_NODELAY, true)

	return Effect_Io {
		operation = IoOp_Recv {
			fd = self.client_file_descriptor,
			buffer_size_max = u32(len(self.buffer)),
		},
	}
}

server_conn_handler :: proc(self_raw: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
	self := self_as(ServerConnIsolate, self_raw, ctx)

	switch message.tag {
	case IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			return Effect_Io{operation = IoOp_Close{fd = self.client_file_descriptor}}
		}

		recv_len := u32(message.io.result)
		data := ctx_read_buffer(ctx, message.io.buffer_index, recv_len)

		self.buffer = {}
		copy_len := min(recv_len, u32(len(self.buffer)))
		mem.copy(&self.buffer[0], raw_data(data), int(copy_len))

		return io_send(self, self.client_file_descriptor, self.buffer[:copy_len])

	case IO_TAG_SEND_COMPLETE:
		if message.io.result < 0 {
			return Effect_Io{operation = IoOp_Close{fd = self.client_file_descriptor}}
		}
		return Effect_Io {
			operation = IoOp_Recv {
				fd = self.client_file_descriptor,
				buffer_size_max = u32(len(self.buffer)),
			},
		}

	case IO_TAG_CLOSE_COMPLETE:
		return Effect_Done{}

	case:
		return Effect_Receive{}
	}
}

// ============================================================================
// Client Isolate
// ============================================================================

ClientIsolate :: struct {
	client_file_descriptor: FD_Handle,
	sequence_number:        u32,
	buffer:                 [128]u8,
}

client_init :: proc(self_raw: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
	self := self_as(ClientIsolate, self_raw, ctx)

	file_descriptor, socket_err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
	if socket_err != .None {
		return Effect_Crash{reason = .Init_Failed}
	}
	self.client_file_descriptor = file_descriptor

	return Effect_Io{operation = IoOp_Connect{fd = self.client_file_descriptor, address = ipv4(127, 0, 0, 1, 9090)}}
}

client_handler :: proc(self_raw: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
	self := self_as(ClientIsolate, self_raw, ctx)

	switch message.tag {
	case IO_TAG_CONNECT_COMPLETE:
		if message.io.result < 0 {
			return Effect_Io{operation = IoOp_Close{fd = self.client_file_descriptor}}
		}

		self.sequence_number += 1
		self.buffer = {}
		packet := cast(^Packet)&self.buffer[0]
		packet.sequence_number = self.sequence_number
		packet.payload[0] = 'P'
		packet.payload[1] = 'I'
		packet.payload[2] = 'N'
		packet.payload[3] = 'G'

		return io_send(self, self.client_file_descriptor, self.buffer[:size_of(Packet)])

	case IO_TAG_SEND_COMPLETE:
		if message.io.result < 0 {
			return Effect_Io{operation = IoOp_Close{fd = self.client_file_descriptor}}
		}
		return Effect_Io {
			operation = IoOp_Recv {
				fd = self.client_file_descriptor,
				buffer_size_max = u32(size_of(Packet)),
			},
		}

	case IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			return Effect_Io{operation = IoOp_Close{fd = self.client_file_descriptor}}
		}

		data := ctx_read_buffer(ctx, message.io.buffer_index, u32(message.io.result))
		if len(data) >= size_of(Packet) {
			packet := payload_as(Packet, data)

			str := fmt.bprintf(
				ctx.scratch_arena.data,
				"Client on Shard %d: Received PONG for sequence number %d",
				ctx_shard_id(ctx),
				packet.sequence_number,
			)
			ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)str)
		}

		ctx_register_timer(ctx, 1_000_000_000, TAG_CLIENT_TIMER) // Re-fire in 1 second
		return Effect_Receive{}

	case TAG_CLIENT_TIMER:
		self.sequence_number += 1
		self.buffer = {}
		packet := cast(^Packet)&self.buffer[0]
		packet.sequence_number = self.sequence_number
		packet.payload[0] = 'P'
		packet.payload[1] = 'I'
		packet.payload[2] = 'N'
		packet.payload[3] = 'G'

		return io_send(self, self.client_file_descriptor, self.buffer[:size_of(Packet)])

	case IO_TAG_CLOSE_COMPLETE:
		return Effect_Done{}

	case:
		return Effect_Receive{}
	}
}

// ============================================================================
// Chaos Isolate (Trips Shard 1 Quarantine by Repeated Escalation)
// ============================================================================

ChaosIsolate :: struct {}

chaos_init :: proc(self_raw: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
	shard := _ctx_extract_shard(ctx)
	tick := shard.current_tick

	// Force quarantine loop within the configured tick window
	if shard.id == 1 && tick >= DEMO_ECHO_CHAOS_START_TICK && tick <= DEMO_ECHO_CHAOS_END_TICK {
		str := fmt.bprintf(
			ctx.scratch_arena.data,
			"[QUARANTINE HAZARD] Chaos on Shard 1: crashing init at tick %d",
			tick,
		)
		ctx_log(ctx, .ERROR, USER_LOG_TAG_BASE, transmute([]u8)str)
		return Effect_Crash{reason = .Init_Failed}
	}

	ctx_register_timer(ctx, 1_000_000_000, TAG_CLIENT_TIMER) // Dummy timer to stay alive
	return Effect_Receive{}
}

chaos_handler :: proc(self_raw: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
	shard := _ctx_extract_shard(ctx)

	// Self-crash once the chaos start tick hits
	if message.tag == TAG_CLIENT_TIMER {
		if shard.id == 1 && shard.current_tick >= DEMO_ECHO_CHAOS_START_TICK {
			return Effect_Crash{reason = .None}
		}
		ctx_register_timer(ctx, 1_000_000_000, TAG_CLIENT_TIMER)
	}
	return Effect_Receive{}
}


// ============================================================================
// System Boot Specification
// ============================================================================

main :: proc() {
	quarantine_policy := Quarantine_Policy.Quarantine
	if DEMO_ECHO_ABORT_ON_QUARANTINE do quarantine_policy = .Abort

	types := [4]TypeDescriptor {
		{
			id = SERVER_LISTENER_ISOLATE_TYPE,
			slot_count = 1,
			stride = size_of(ServerListenerIsolate),
			soa_metadata_size = size_of(Isolate_Metadata),
			init_fn = server_listener_init,
			handler_fn = server_listener_handler,
			mailbox_capacity = 16,
		},
		{
			id = SERVER_CONN_ISOLATE_TYPE,
			slot_count = 32,
			stride = size_of(ServerConnIsolate),
			soa_metadata_size = size_of(Isolate_Metadata),
			init_fn = server_conn_init,
			handler_fn = server_conn_handler,
			mailbox_capacity = 16,
		},
		{
			id = CLIENT_ISOLATE_TYPE,
			slot_count = 32,
			stride = size_of(ClientIsolate),
			soa_metadata_size = size_of(Isolate_Metadata),
			init_fn = client_init,
			handler_fn = client_handler,
			mailbox_capacity = 16,
		},
		{
			id = CHAOS_ISOLATE_TYPE,
			slot_count = 1,
			stride = size_of(ChaosIsolate),
			soa_metadata_size = size_of(Isolate_Metadata),
			init_fn = chaos_init,
			handler_fn = chaos_handler,
			mailbox_capacity = 16,
		},
	}

	shard_zero_children := [3]Child_Spec {
		Static_Child_Spec{type_id = SERVER_LISTENER_ISOLATE_TYPE, restart_type = .permanent},
		Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
		Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
	}

	shard_one_children := [3]Child_Spec {
		Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
		Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
		Static_Child_Spec{type_id = CHAOS_ISOLATE_TYPE, restart_type = .permanent},
	}

	shard_specs := [2]ShardSpec {
		{
			shard_id = 0,
			target_core = -1,
			root_group = Group_Spec {
				strategy              = .One_For_One,
				restart_count_max     = DEMO_ECHO_ROOT_RESTART_MAX,
				window_duration_ticks = DEMO_ECHO_ROOT_WINDOW_TICKS,
				children              = shard_zero_children[:],
				child_count_dynamic_max = 32,
			},
		},
		{
			shard_id = 1,
			target_core = -1,
			root_group = Group_Spec {
				strategy              = .One_For_One,
				restart_count_max     = DEMO_ECHO_CHAOS_RESTART_MAX,
				window_duration_ticks = DEMO_ECHO_CHAOS_WINDOW_TICKS,
				children              = shard_one_children[:],
			},
		},
	}

	spec := SystemSpec {
		shard_count = 2,
		types = types[:],
		shard_specs = shard_specs[:],
		timer_resolution_ns = 1_000_000,
		quarantine_policy = quarantine_policy,
		watchdog = Watchdog_Config {
			check_interval_ms       = 500,
			shard_restart_window_ms = DEMO_ECHO_SHARD_RESTART_WINDOW_MS,
			shard_restart_max       = DEMO_ECHO_SHARD_RESTART_MAX,
			phase_2_threshold       = 2,
		},
		pool_slot_count = 4096,
		timer_spoke_count = 1024,
		timer_entry_count = 1024,
		log_ring_size = 65536,
		default_ring_size = 32,
		scratch_arena_size = 65536,
		fd_table_slot_count = 128,
		fd_entry_size = size_of(FD_Entry),
		supervision_groups_max = 16,
		reactor_buffer_slot_count = 128,
		reactor_buffer_slot_size = 4096,
		transfer_slot_count = 32,
		transfer_slot_size = 4096,
		shutdown_timeout_ms = 3_000,
	}

	fmt.println("Starting TCP Ping-Pong Echo Server. Press Ctrl+C to shut down.")
	fmt.printfln(
		"[DEMO] root_max=%d root_window=%d chaos_max=%d chaos_window=%d shard_max=%d shard_window_ms=%d chaos_ticks=%d..%d quarantine_policy=%v pid=%d",
		DEMO_ECHO_ROOT_RESTART_MAX,
		DEMO_ECHO_ROOT_WINDOW_TICKS,
		DEMO_ECHO_CHAOS_RESTART_MAX,
		DEMO_ECHO_CHAOS_WINDOW_TICKS,
		DEMO_ECHO_SHARD_RESTART_MAX,
		DEMO_ECHO_SHARD_RESTART_WINDOW_MS,
		DEMO_ECHO_CHAOS_START_TICK,
		DEMO_ECHO_CHAOS_END_TICK,
		quarantine_policy,
		os.get_pid(),
	)
	when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		fmt.println("[DEMO] To recover quarantined shards, run: kill -USR2 <pid>")
	}
	tina_start(&spec)
}
