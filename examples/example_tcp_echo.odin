package main

import "core:fmt"
import "core:mem"
import "core:os"
import tina "../src"

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

TAG_CLIENT_TIMER: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1

// ============================================================================
// Payloads and Message Structs
// ============================================================================

Packet :: struct {
	sequence_number: u32,
	payload:         [16]u8, // e.g., "PING" or "PONG"
}

ConnectionArgs :: struct {
	client_file_descriptor: tina.FD_Handle,
}

// ============================================================================
// Server Listener Isolate
// ============================================================================

ServerListenerIsolate :: struct {
	listen_file_descriptor: tina.FD_Handle,
}

server_listener_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ServerListenerIsolate, self_raw, ctx)

	file_descriptor, socket_err := tina.ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
	if socket_err != .None {
		return tina.Effect_Crash{reason = .Init_Failed}
	}
	self.listen_file_descriptor = file_descriptor

	tina.ctx_setsockopt(ctx, self.listen_file_descriptor, .SOL_SOCKET, .SO_REUSEADDR, true)
	tina.ctx_bind(ctx, self.listen_file_descriptor, tina.ipv4(127, 0, 0, 1, 9090))
	tina.ctx_listen(ctx, self.listen_file_descriptor, 128)

	str := fmt.bprintf(ctx.scratch_arena.data, "TCP Server listening on 127.0.0.1:9090")
	tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

	return tina.Effect_Io{operation = tina.IoOp_Accept{listen_fd = self.listen_file_descriptor}}
}

server_listener_handler :: proc(self_raw: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ServerListenerIsolate, self_raw, ctx)

	switch message.tag {
	case tina.IO_TAG_ACCEPT_COMPLETE:
		if message.io.result >= 0 {
			connection_args := ConnectionArgs {
				client_file_descriptor = message.io.fd,
			}
			payload_buffer, payload_size := tina.init_args_of(&connection_args)

			spec := tina.Spawn_Spec {
				type_id      = SERVER_CONN_ISOLATE_TYPE,
				group_id     = tina.ctx_supervision_group_id(ctx),
				restart_type = .temporary,
				args_payload = payload_buffer,
				args_size    = payload_size,
				handoff_fd   = message.io.fd,
				handoff_mode = .Full,
			}
			_ = tina.ctx_spawn(ctx, spec)
		}
		return tina.Effect_Io{operation = tina.IoOp_Accept{listen_fd = self.listen_file_descriptor}}

	case:
		return tina.Effect_Receive{}
	}
}

// ============================================================================
// Server Connection Isolate (Echo Response)
// ============================================================================

ServerConnIsolate :: struct {
	client_file_descriptor: tina.FD_Handle,
	buffer:                 [128]u8,
}

server_conn_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ServerConnIsolate, self_raw, ctx)
	connection_args := tina.payload_as(ConnectionArgs, args)
	self.client_file_descriptor = connection_args.client_file_descriptor

	tina.ctx_setsockopt(ctx, self.client_file_descriptor, .IPPROTO_TCP, .TCP_NODELAY, true)

	return tina.Effect_Io {
		operation = tina.IoOp_Recv {
			fd = self.client_file_descriptor,
			buffer_size_max = u32(len(self.buffer)),
		},
	}
}

server_conn_handler :: proc(self_raw: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ServerConnIsolate, self_raw, ctx)

	switch message.tag {
	case tina.IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.client_file_descriptor}}
		}

		recv_len := u32(message.io.result)
		data := tina.ctx_read_buffer(ctx, message.io.buffer_index, recv_len)

		self.buffer = {}
		copy_len := min(recv_len, u32(len(self.buffer)))
		mem.copy(&self.buffer[0], raw_data(data), int(copy_len))

		return tina.io_send(self, self.client_file_descriptor, self.buffer[:copy_len])

	case tina.IO_TAG_SEND_COMPLETE:
		if message.io.result < 0 {
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.client_file_descriptor}}
		}
		return tina.Effect_Io {
			operation = tina.IoOp_Recv {
				fd = self.client_file_descriptor,
				buffer_size_max = u32(len(self.buffer)),
			},
		}

	case tina.IO_TAG_CLOSE_COMPLETE:
		return tina.Effect_Done{}

	case:
		return tina.Effect_Receive{}
	}
}

// ============================================================================
// Client Isolate
// ============================================================================

ClientIsolate :: struct {
	client_file_descriptor: tina.FD_Handle,
	sequence_number:        u32,
	buffer:                 [128]u8,
}

client_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ClientIsolate, self_raw, ctx)

	file_descriptor, socket_err := tina.ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
	if socket_err != .None {
		return tina.Effect_Crash{reason = .Init_Failed}
	}
	self.client_file_descriptor = file_descriptor

	return tina.Effect_Io{operation = tina.IoOp_Connect{fd = self.client_file_descriptor, address = tina.ipv4(127, 0, 0, 1, 9090)}}
}

client_handler :: proc(self_raw: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ClientIsolate, self_raw, ctx)

	switch message.tag {
	case tina.IO_TAG_CONNECT_COMPLETE:
		if message.io.result < 0 {
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.client_file_descriptor}}
		}

		self.sequence_number += 1
		self.buffer = {}
		packet := cast(^Packet)&self.buffer[0]
		packet.sequence_number = self.sequence_number
		packet.payload[0] = 'P'
		packet.payload[1] = 'I'
		packet.payload[2] = 'N'
		packet.payload[3] = 'G'

		return tina.io_send(self, self.client_file_descriptor, self.buffer[:size_of(Packet)])

	case tina.IO_TAG_SEND_COMPLETE:
		if message.io.result < 0 {
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.client_file_descriptor}}
		}
		return tina.Effect_Io {
			operation = tina.IoOp_Recv {
				fd = self.client_file_descriptor,
				buffer_size_max = u32(size_of(Packet)),
			},
		}

	case tina.IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			return tina.Effect_Io{operation = tina.IoOp_Close{fd = self.client_file_descriptor}}
		}

		data := tina.ctx_read_buffer(ctx, message.io.buffer_index, u32(message.io.result))
		if len(data) >= size_of(Packet) {
			packet := tina.payload_as(Packet, data)

			str := fmt.bprintf(
				ctx.scratch_arena.data,
				"Client on Shard %d: Received PONG for sequence number %d",
				tina.ctx_shard_id(ctx),
				packet.sequence_number,
			)
			tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)
		}

		tina.ctx_register_timer(ctx, 1_000_000_000, TAG_CLIENT_TIMER) // Re-fire in 1 second
		return tina.Effect_Receive{}

	case TAG_CLIENT_TIMER:
		self.sequence_number += 1
		self.buffer = {}
		packet := cast(^Packet)&self.buffer[0]
		packet.sequence_number = self.sequence_number
		packet.payload[0] = 'P'
		packet.payload[1] = 'I'
		packet.payload[2] = 'N'
		packet.payload[3] = 'G'

		return tina.io_send(self, self.client_file_descriptor, self.buffer[:size_of(Packet)])

	case tina.IO_TAG_CLOSE_COMPLETE:
		return tina.Effect_Done{}

	case:
		return tina.Effect_Receive{}
	}
}

// ============================================================================
// Chaos Isolate (Trips Shard 1 Quarantine by Repeated Escalation)
// ============================================================================

ChaosIsolate :: struct {
	counter: u32,
}

chaos_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ChaosIsolate, self_raw, ctx)
	self.counter = 0

	tina.ctx_register_timer(ctx, 1_000_000_000, TAG_CLIENT_TIMER) // Dummy timer to stay alive
	return tina.Effect_Receive{}
}

chaos_handler :: proc(self_raw: rawptr, message: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(ChaosIsolate, self_raw, ctx)
	shard_id := tina.ctx_shard_id(ctx)

	if message.tag == TAG_CLIENT_TIMER {
		self.counter += 1

		// Only cause chaos on shard 1 within the configured window
		if shard_id == 1 && self.counter >= DEMO_ECHO_CHAOS_START_TICK && self.counter <= DEMO_ECHO_CHAOS_END_TICK {
			str := fmt.bprintf(
				ctx.scratch_arena.data,
				"[QUARANTINE HAZARD] Chaos on Shard 1: crashing at counter %d",
				self.counter,
			)
			tina.ctx_log(ctx, .ERROR, tina.USER_LOG_TAG_BASE, transmute([]u8)str)
			return tina.Effect_Crash{reason = .None}
		}

		tina.ctx_register_timer(ctx, 1_000_000_000, TAG_CLIENT_TIMER)
	}
	return tina.Effect_Receive{}
}


// ============================================================================
// System Boot Specification
// ============================================================================

main :: proc() {
	quarantine_policy := tina.Quarantine_Policy.Quarantine
	if DEMO_ECHO_ABORT_ON_QUARANTINE do quarantine_policy = .Abort

	types := [4]tina.TypeDescriptor {
		{
			id = SERVER_LISTENER_ISOLATE_TYPE,
			slot_count = 1,
			stride = size_of(ServerListenerIsolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			init_fn = server_listener_init,
			handler_fn = server_listener_handler,
			mailbox_capacity = 16,
		},
		{
			id = SERVER_CONN_ISOLATE_TYPE,
			slot_count = 32,
			stride = size_of(ServerConnIsolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			init_fn = server_conn_init,
			handler_fn = server_conn_handler,
			mailbox_capacity = 16,
		},
		{
			id = CLIENT_ISOLATE_TYPE,
			slot_count = 32,
			stride = size_of(ClientIsolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			init_fn = client_init,
			handler_fn = client_handler,
			mailbox_capacity = 16,
		},
		{
			id = CHAOS_ISOLATE_TYPE,
			slot_count = 1,
			stride = size_of(ChaosIsolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			init_fn = chaos_init,
			handler_fn = chaos_handler,
			mailbox_capacity = 16,
		},
	}

	shard_zero_children := [3]tina.Child_Spec {
		tina.Static_Child_Spec{type_id = SERVER_LISTENER_ISOLATE_TYPE, restart_type = .permanent},
		tina.Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
		tina.Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
	}

	shard_one_children := [3]tina.Child_Spec {
		tina.Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
		tina.Static_Child_Spec{type_id = CLIENT_ISOLATE_TYPE, restart_type = .permanent},
		tina.Static_Child_Spec{type_id = CHAOS_ISOLATE_TYPE, restart_type = .permanent},
	}

	shard_specs := [2]tina.ShardSpec {
		{
			shard_id = 0,
			target_core = -1,
			root_group = tina.Group_Spec {
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
			root_group = tina.Group_Spec {
				strategy              = .One_For_One,
				restart_count_max     = DEMO_ECHO_CHAOS_RESTART_MAX,
				window_duration_ticks = DEMO_ECHO_CHAOS_WINDOW_TICKS,
				children              = shard_one_children[:],
			},
		},
	}

	spec := tina.SystemSpec {
		shard_count = 2,
		types = types[:],
		shard_specs = shard_specs[:],
		timer_resolution_ns = 1_000_000,
		quarantine_policy = quarantine_policy,
		watchdog = tina.Watchdog_Config {
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
		fd_entry_size = size_of(tina.FD_Entry),
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
	tina.tina_start(&spec)
}
