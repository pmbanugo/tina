package tina

import "core:fmt"
import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {
	// ============================================================================
	// io_sequence structural guarantee: timer-wake + stale completion reclamation
	// ============================================================================
	//
	// This test verifies the core safety invariant that makes explicit
	// backend_cancel unnecessary:
	//   1. An Isolate submits .recv and enters WAITING_FOR_IO
	//   2. A timer fires before I/O completes -> io_sequence bumped, state -> Runnable
	//   3. The Isolate receives the timeout, returns .done
	//   4. The stale I/O completion arrives later -> io_sequence mismatch -> buffer freed
	//   5. After quiescence, the reactor buffer pool is whole (no leaks)

	IO_TIMEOUT_TYPE_ID: u8 : 6
	APP_TAG_IO_TIMEOUT: Message_Tag : USER_MESSAGE_TAG_BASE + 3

	IoTimeoutIsolate :: struct {
		fd:    FD_Handle,
		state: enum u8 {
			Init,
			Waiting_For_Io,
			Timed_Out,
		},
	}

	io_timeout_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		iso := cast(^IoTimeoutIsolate)self

		fd, err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
		if err != .None {
			return Effect_Crash{reason = .Init_Failed}
		}
		iso.fd = fd

		ctx_register_timer(
			ctx,
			2 * _ctx_extract_shard(ctx).timer_resolution_ns,
			APP_TAG_IO_TIMEOUT,
		)

		iso.state = .Waiting_For_Io
		return Effect_Io{operation = IoOp_Recv{fd = iso.fd, buffer_size_max = 512}}
	}

	io_timeout_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		iso := cast(^IoTimeoutIsolate)self

		if message.tag == APP_TAG_IO_TIMEOUT {
			iso.state = .Timed_Out
			return Effect_Done{}
		}

		return Effect_Done{}
	}

	@(test)
	test_io_sequence_stale_completion_reclamation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [7]TypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Coordinator),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = coordinator_init,
				handler_fn = coordinator_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(PingIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = ping_init,
				handler_fn = ping_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(PongIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = pong_init,
				handler_fn = pong_handler,
			},
			{
				id = SUPERVISOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Supervisor),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = supervisor_init,
				handler_fn = supervisor_handler,
			},
			{
				id = EXITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Exiter),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = exiter_init,
				handler_fn = exiter_handler,
			},
			{
				id = BYSTANDER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Bystander),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = bystander_init,
				handler_fn = bystander_handler,
			},
			{
				id = IO_TIMEOUT_TYPE_ID,
				slot_count = 1,
				stride = size_of(IoTimeoutIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = io_timeout_init,
				handler_fn = io_timeout_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = IO_TIMEOUT_TYPE_ID, restart_type = .temporary},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			child_count_dynamic_max = 4,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 500,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 10,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 8,
			reactor_buffer_slot_size  = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 8,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {50, 100}

		simulator_run(&sim)

		shard := &sim.shards[0]

		iso_state := shard.metadata[IO_TIMEOUT_TYPE_ID].state[0]
		testing.expect_value(t, iso_state, Isolate_State.Unallocated)
		testing.expect(
			t,
			shard.counters.io_stale_completions >= 1,
			"Expected at least one stale I/O completion from the timer-wake sequence",
		)

		pool := &shard.reactor.buffer_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] io_sequence stale completion reclamation verified. Stale completions: %d, buffer pool: %d/%d free.",
			shard.counters.io_stale_completions,
			pool.free_count,
			pool.slot_count,
		)
	}

	// ============================================================================
	// Teardown step 2b: write/send buffer reclamation via one_for_all
	// ============================================================================

	WRITE_CRASHER_TYPE_ID: u8 : 0 // Must be lower than Writer for dispatch ordering
	WRITE_WRITER_TYPE_ID: u8 : 1

	WriteCrasherIsolate :: struct {}
	WriteWriterIsolate :: struct {
		fd:       FD_Handle,
		send_buf: [32]u8,
	}

	write_crasher_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Yield{}
	}

	write_crasher_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		if _ctx_extract_shard(ctx).current_tick == 1 do return Effect_Crash{reason = .None}
		return Effect_Done{}
	}

	write_writer_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		w := cast(^WriteWriterIsolate)self

		fd, err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
		if err != .None do return Effect_Crash{reason = .Init_Failed}
		w.fd = fd
		w.send_buf[0] = 0x42

		return Effect_Io {
			operation = IoOp_Send {
				fd = w.fd,
				payload_offset = u16(offset_of(WriteWriterIsolate, send_buf)),
				payload_size = 32,
			},
		}
	}

	write_writer_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Done{}
	}

	@(test)
	test_write_buffer_reclamation_on_teardown :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]TypeDescriptor {
			{
				id = WRITE_CRASHER_TYPE_ID,
				slot_count = 1,
				stride = size_of(WriteCrasherIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = write_crasher_init,
				handler_fn = write_crasher_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
			{
				id = WRITE_WRITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(WriteWriterIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = write_writer_init,
				handler_fn = write_writer_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}

		children := [2]Child_Spec {
			Static_Child_Spec{type_id = WRITE_CRASHER_TYPE_ID, restart_type = .transient},
			Static_Child_Spec{type_id = WRITE_WRITER_TYPE_ID, restart_type = .transient},
		}

		root_group := Group_Spec {
			strategy              = .One_For_All,
			restart_count_max     = 5,
			window_duration_ticks = 10000,
			children              = children[:],
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 200,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 10,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 8,
			reactor_buffer_slot_size  = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 4,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {1, 2}

		simulator_run(&sim)

		shard := &sim.shards[0]
		pool := &shard.reactor.buffer_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] Write buffer reclamation on one_for_all teardown verified. Buffer pool: %d/%d free.",
			pool.free_count,
			pool.slot_count,
		)
	}

	// ============================================================================
	// Shutdown dispatch priority: I/O completion > TAG_SHUTDOWN > inbox
	// ============================================================================

	PRIORITY_TYPE_ID: u8 : 0

	PriorityTestIsolate :: struct {
		received_tags:  [4]Message_Tag,
		received_count: u8,
	}

	priority_test_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	priority_test_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		iso := cast(^PriorityTestIsolate)self
		if iso.received_count < 4 {
			iso.received_tags[iso.received_count] = message.tag
			iso.received_count += 1
		}
		return Effect_Receive{}
	}

	@(test)
	test_shutdown_dispatch_priority_io_before_shutdown :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]TypeDescriptor {
			{
				id = PRIORITY_TYPE_ID,
				slot_count = 1,
				stride = size_of(PriorityTestIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = priority_test_init,
				handler_fn = priority_test_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = PRIORITY_TYPE_ID, restart_type = .temporary},
		}

		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10,
			terminate_on_quiescent = false,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 8,
			reactor_buffer_slot_size  = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 4,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		shard := &sim.shards[0]

		buffer_index, buffer_error := reactor_buffer_pool_alloc(&shard.reactor.buffer_pool)
		testing.expect_value(t, buffer_error, Buffer_Pool_Error.None)

		soa := shard.metadata[PRIORITY_TYPE_ID]
		soa[0].io_completion_tag = IO_TAG_RECV_COMPLETE
		soa[0].io_buffer_index = buffer_index
		soa[0].io_result = 128
		soa[0].state = .Runnable
		soa[0].flags += {.Shutdown_Pending}

		simulator_run(&sim)

		received := cast(^PriorityTestIsolate)_get_isolate_ptr(shard, u16(PRIORITY_TYPE_ID), 0)
		testing.expect_value(t, received.received_count, u8(2))
		testing.expect_value(t, received.received_tags[0], Message_Tag(IO_TAG_RECV_COMPLETE))
		testing.expect_value(t, received.received_tags[1], TAG_SHUTDOWN)

		pool := &shard.reactor.buffer_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] Shutdown dispatch priority verified: I/O completion (0x%04X) delivered before TAG_SHUTDOWN (0x%04X).",
			u16(received.received_tags[0]),
			u16(received.received_tags[1]),
		)
	}
}
