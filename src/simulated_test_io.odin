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
	//   1. An Isolate submits .recv and enters WAIT_IO
	//   2. A timer fires before I/O completes -> io_sequence bumped, state -> Runnable
	//   3. The Isolate receives the timeout, returns DONE
	//   4. The stale I/O completion arrives later -> io_sequence mismatch -> buffer freed
	//   5. After quiescence, the reactor buffer pool is whole (no leaks)

	IO_TIMEOUT_TYPE_ID: Isolate_Type_Id : 6
	APP_TAG_IO_TIMEOUT: Message_Tag : USER_MESSAGE_TAG_BASE + 3

	IoTimeoutIsolate :: struct {
		fd:    FD_Handle,
		state: enum u8 {
			Init,
			Wait_Io,
			Timed_Out,
		},
	}

	io_timeout_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		iso := cast(^IoTimeoutIsolate)self

		fd, error := ctx_socket(.AF_INET, .STREAM, .TCP)
		if error != .None {
			return transition_to_crash(.Init_Failed)
		}
		iso.fd = fd

		_, frame := _current_isolate_turn_frame()
		ctx_register_timer(
			2 * frame.timer_resolution_ns,
			APP_TAG_IO_TIMEOUT,
		)

		iso.state = .Wait_Io
		return transition_to_wait_io_or_crash(ctx_submit_io(IoOp_Recv{fd = iso.fd, buffer_size_max = 512}))
	}

	io_timeout_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		iso := cast(^IoTimeoutIsolate)self

		if message.tag == APP_TAG_IO_TIMEOUT {
			iso.state = .Timed_Out
			return ISOLATE_TRANSITION_DONE
		}

		return ISOLATE_TRANSITION_DONE
	}

	@(test)
	test_io_sequence_stale_completion_reclamation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [7]IsolateTypeDescriptor {
			{
				id = COORDINATOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Coordinator),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = coordinator_init,
				handler_fn = coordinator_handler,
			},
			{
				id = PING_TYPE_ID,
				slot_count = 1,
				stride = size_of(PingIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = ping_init,
				handler_fn = ping_handler,
			},
			{
				id = PONG_TYPE_ID,
				slot_count = 1,
				stride = size_of(PongIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = pong_init,
				handler_fn = pong_handler,
			},
			{
				id = SUPERVISOR_TYPE_ID,
				slot_count = 1,
				stride = size_of(Supervisor),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = supervisor_init,
				handler_fn = supervisor_handler,
			},
			{
				id = EXITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Exiter),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = exiter_init,
				handler_fn = exiter_handler,
			},
			{
				id = BYSTANDER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Bystander),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = bystander_init,
				handler_fn = bystander_handler,
			},
			{
				id = IO_TIMEOUT_TYPE_ID,
				slot_count = 1,
				stride = size_of(IoTimeoutIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = io_timeout_init,
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
			staging_slot_count        = 2,
			staging_slot_size         = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 8,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {50, 100}

		simulator_run(&sim)

		shard := &sim.shards[0]

		iso_state := shard.metadata[IO_TIMEOUT_TYPE_ID]._state[0]
		testing.expect_value(t, iso_state, Isolate_State.Unallocated)
		testing.expect(
			t,
			shard.counters.io_stale_completions >= 1,
			"Expected at least one stale I/O completion from the timer-wake sequence",
		)

		pool := &shard.reactor.receive_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)
		testing.expect_value(t, shard.reactor.io_in_flight_count, u32(0))

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

	WRITE_CRASHER_TYPE_ID: Isolate_Type_Id : 0 // Must be lower than Writer for dispatch ordering
	WRITE_WRITER_TYPE_ID: Isolate_Type_Id : 1

	WriteCrasherIsolate :: struct {}
	WriteWriterIsolate :: struct {
		fd:       FD_Handle,
		send_buf: [32]u8,
	}

	write_crasher_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_YIELD
	}

	write_crasher_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		shard, _ := _current_isolate_turn_frame()
		if shard.current_tick == 1 do return transition_to_crash(.None)
		return ISOLATE_TRANSITION_DONE
	}

	write_writer_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		w := cast(^WriteWriterIsolate)self

		fd, error := ctx_socket(.AF_INET, .STREAM, .TCP)
		if error != .None do return transition_to_crash(.Init_Failed)
		w.fd = fd
		w.send_buf[0] = 0x42

		return transition_to_wait_io_or_crash(
			ctx_io_send(w, w.fd, w.send_buf[:]),
		)
	}

	write_writer_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_DONE
	}

	@(test)
	test_write_buffer_reclamation_on_teardown :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]IsolateTypeDescriptor {
			{
				id = WRITE_CRASHER_TYPE_ID,
				slot_count = 1,
				stride = size_of(WriteCrasherIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = write_crasher_init,
				handler_fn = write_crasher_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
			{
				id = WRITE_WRITER_TYPE_ID,
				slot_count = 1,
				stride = size_of(WriteWriterIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = write_writer_init,
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
			staging_slot_count        = 2,
			staging_slot_size         = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 4,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {1, 2}

		simulator_run(&sim)

		shard := &sim.shards[0]
		pool := &shard.reactor.receive_pool
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

	PRIORITY_TYPE_ID: Isolate_Type_Id : 0

	PriorityTestIsolate :: struct {
		received_tags:  [4]Message_Tag,
		received_count: u8,
	}

	PRIORITY_DIAG_RECEIVED_COUNT: Diagnostic_Field_Id : 0
	PRIORITY_DIAG_TAG_0:          Diagnostic_Field_Id : 1
	PRIORITY_DIAG_TAG_1:          Diagnostic_Field_Id : 2
	PRIORITY_DIAG_TAG_2:          Diagnostic_Field_Id : 3
	PRIORITY_DIAG_TAG_3:          Diagnostic_Field_Id : 4

	priority_test_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	priority_test_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		iso := cast(^PriorityTestIsolate)self
		if iso.received_count < 4 {
			iso.received_tags[iso.received_count] = message.tag
			tag_field := Diagnostic_Field_Id(int(PRIORITY_DIAG_TAG_0) + int(iso.received_count))
			ctx_test_diagnostic_write_u64(tag_field, u64(message.tag))
			iso.received_count += 1
			ctx_test_diagnostic_write_u64(PRIORITY_DIAG_RECEIVED_COUNT, u64(iso.received_count))
		}
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_shutdown_dispatch_priority_io_before_shutdown :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = PRIORITY_TYPE_ID,
				slot_count = 1,
				stride = size_of(PriorityTestIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = priority_test_init,
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
			staging_slot_count        = 2,
			staging_slot_size         = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 4,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]

		buffer_index, buffer_error := io_slot_pool_alloc_tina_owned(&shard.reactor.receive_pool)
		testing.expect_value(t, buffer_error, IO_Slot_Pool_Error.None)

		soa := shard.metadata[PRIORITY_TYPE_ID]
		_slot_set_state(shard, PRIORITY_TYPE_ID, 0, .Runnable)
		soa[0].flags += {.Shutdown_Pending}
		_slot_set_io_completion_ready(
			shard,
			PRIORITY_TYPE_ID,
			0,
			.Recv_Complete,
			128,
			buffer_index,
		)

		simulator_run(&sim)

		shard_test_diagnostic_expect_u64(t, shard, PRIORITY_TYPE_ID, 0, PRIORITY_DIAG_RECEIVED_COUNT, 2)
		tag_0, tag_0_found := shard_diagnostic_read(shard, PRIORITY_TYPE_ID, 0, PRIORITY_DIAG_TAG_0)
		tag_1, tag_1_found := shard_diagnostic_read(shard, PRIORITY_TYPE_ID, 0, PRIORITY_DIAG_TAG_1)
		testing.expect(t, tag_0_found, "priority tag-0 diagnostic not found")
		testing.expect(t, tag_1_found, "priority tag-1 diagnostic not found")
		testing.expect_value(t, Message_Tag(tag_0), IO_TAG_RECV_COMPLETE)
		testing.expect_value(t, Message_Tag(tag_1), TAG_SHUTDOWN)

		pool := &shard.reactor.receive_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] Shutdown dispatch priority verified: I/O completion (0x%04X) delivered before TAG_SHUTDOWN (0x%04X).",
			u16(Message_Tag(tag_0)),
			u16(Message_Tag(tag_1)),
		)
	}
}
