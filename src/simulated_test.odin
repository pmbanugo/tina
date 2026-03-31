package tina

import "core:fmt"
import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {

	// ===========
	// QA Helpers
	// ===========
	assert_spawn_success :: proc(
		res: Spawn_Result,
		name: string,
		loc := #caller_location,
	) -> Handle {
		switch v in res {
		case Handle:
			return v
		case Spawn_Error:
			// panic() diverges (never returns), so no return statement is needed after it
			panic(fmt.tprintf("[QA FATAL] Spawn failed for '%s'. Error Code: %v", name, v), loc)
		}
		unreachable()
	}

	COORDINATOR_TYPE_ID: u8 : 0
	PING_TYPE_ID: u8 : 1
	PONG_TYPE_ID: u8 : 2
	SUPERVISOR_TYPE_ID: u8 : 3
	EXITER_TYPE_ID: u8 : 4
	BYSTANDER_TYPE_ID: u8 : 5

	APP_TAG_PING: Message_Tag : USER_MESSAGE_TAG_BASE + 1
	APP_TAG_PONG: Message_Tag : USER_MESSAGE_TAG_BASE + 2

	PingMsg :: struct {
		seq: u32,
	}
	PongMsg :: struct {
		seq: u32,
	}

	PingInitArgs :: struct {
		pong_handle: Handle,
	}

	Coordinator :: struct {}
	PingIsolate :: struct {
		pong_handle: Handle,
		count:       u32,
	}
	PongIsolate :: struct {}

	// ======================================
	// Coordinator (Spawns Ping and Pong)
	// ======================================
	coordinator_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		// 1. Spawn Pong
		pong_spec := Spawn_Spec {
			type_id      = PONG_TYPE_ID,
			group_id     = ctx_supervision_group_id(ctx), // Inherit the coordinator's group
			restart_type = .temporary,
		}
		pong_res := ctx_spawn(ctx, pong_spec)
		pong_handle := assert_spawn_success(pong_res, "Pong")

		// 2. Spawn Ping, passing Pong's Handle via init_args
		ping_args := PingInitArgs {
			pong_handle = pong_handle,
		}
		payload, payload_len := make_spawn_args(&ping_args)

		ping_spec := Spawn_Spec {
			type_id      = PING_TYPE_ID,
			group_id     = ctx_supervision_group_id(ctx), // Inherit the coordinator's group
			restart_type = .temporary,
			args_payload = payload,
			args_size    = payload_len,
		}
		ping_res := ctx_spawn(ctx, ping_spec)
		_ = assert_spawn_success(ping_res, "Ping")

		// Park forever
		return Effect_Receive{}
	}

	coordinator_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	// =================
	// Ping Isolate
	// =================
	ping_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		p := cast(^PingIsolate)self
		init_args := payload_as(PingInitArgs, args)
		p.pong_handle = init_args.pong_handle
		p.count = 0

		msg := PingMsg {
			seq = 0,
		}
		_ = ctx_send(ctx, p.pong_handle, APP_TAG_PING, &msg)

		return Effect_Receive{}
	}

	ping_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		using p := cast(^PingIsolate)self
		pong := payload_as(PongMsg, message.user.payload[:])

		count += 1

		// Stop after 100 round trips
		if count >= 100 {
			return Effect_Done{}
		}

		msg := PingMsg {
			seq = pong.seq + 1,
		}
		_ = ctx_send(ctx, p.pong_handle, APP_TAG_PING, &msg)
		return Effect_Receive{}
	}

	// ================
	// Pong Isolate
	// ================
	pong_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	pong_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		ping := payload_as(PingMsg, message.user.payload[:])

		msg := PongMsg {
			seq = ping.seq,
		}
		_ = ctx_send(ctx, message.user.source, APP_TAG_PONG, &msg)

		return Effect_Receive{}
	}

	// (Test) ---
	@(test)
	test_ping_pong_simulation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [3]TypeDescriptor {
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
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = COORDINATOR_TYPE_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			dynamic_child_count_max = 10,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10_000,
			terminate_on_quiescent = true,
			checker_interval_ticks = 100,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 1024,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 4096,
			transfer_slot_count       = 4,
			transfer_slot_size        = 4096,
			timer_spoke_count         = 1024,
			timer_entry_count         = 1024,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_arena_size        = 65536,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		simulator_run(&sim)

		shard := &sim.shards[0]

		// Assert Ping terminated cleanly
		ping_state := shard.metadata[PING_TYPE_ID].state[0]
		testing.expect_value(t, ping_state, Isolate_State.Unallocated)

		// Assert Pong is quiescent
		pong_state := shard.metadata[PONG_TYPE_ID].state[0]
		testing.expect_value(t, pong_state, Isolate_State.Waiting)

		// Prove Ping hit 100 iterations
		ping_pointer := _get_isolate_ptr(shard, u16(PING_TYPE_ID), 0)
		ping_memory := cast(^PingIsolate)ping_pointer
		testing.expect_value(t, ping_memory.count, 100)

		fmt.printfln(
			"\n[TEST SUCCESS] Ping completed exactly %d round trips before terminating.",
			ping_memory.count,
		)
	}

	// ============================================================================
	// Supervision: Temporary child exit does not restart or escalate
	// ============================================================================
	Supervisor :: struct {}
	Exiter :: struct {}
	Bystander :: struct {}

	supervisor_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		bystander_spec := Spawn_Spec {
			type_id      = BYSTANDER_TYPE_ID,
			group_id     = ctx_supervision_group_id(ctx),
			restart_type = .temporary,
		}
		_ = assert_spawn_success(ctx_spawn(ctx, bystander_spec), "Bystander")

		exiter_spec := Spawn_Spec {
			type_id      = EXITER_TYPE_ID,
			group_id     = ctx_supervision_group_id(ctx),
			restart_type = .temporary,
		}
		_ = assert_spawn_success(ctx_spawn(ctx, exiter_spec), "Exiter")

		return Effect_Receive{}
	}

	supervisor_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	exiter_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	exiter_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Done{}
	}

	bystander_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	bystander_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	// ============================================================================
	// io_sequence structural guarantee: timer-wake + stale completion reclamation
	// ============================================================================
	//
	// This test verifies the core safety invariant that makes explicit
	// backend_cancel unnecessary:
	//   1. An Isolate submits .recv and enters WAITING_FOR_IO
	//   2. A timer fires before I/O completes → io_sequence bumped, state → Runnable
	//   3. The Isolate receives the timeout, returns .done
	//   4. The stale I/O completion arrives later → io_sequence mismatch → buffer freed
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

		// Create a socket (synchronous — no I/O slot consumed)
		fd, err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
		if err != .None {
			return Effect_Crash{reason = .Init_Failed}
		}
		iso.fd = fd

		// Register a timer that will fire in 2 ticks (before I/O completes)
		ctx_register_timer(
			ctx,
			2 * _ctx_extract_shard(ctx).timer_resolution_ns,
			APP_TAG_IO_TIMEOUT,
		)

		// Submit a recv — I/O delay is configured to be much longer than the timer
		iso.state = .Waiting_For_Io
		return Effect_Io{operation = IoOp_Recv{fd = iso.fd, buffer_size_max = 512}}
	}

	io_timeout_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		iso := cast(^IoTimeoutIsolate)self

		if message.tag == APP_TAG_IO_TIMEOUT {
			// Timer fired before I/O completed — this is the expected path.
			// The io_sequence was already bumped by _advance_timers.
			iso.state = .Timed_Out
			return Effect_Done{}
		}

		// If we receive an I/O completion, the timer didn't fire first.
		// In this test setup (delay >> timer), this shouldn't happen.
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
			dynamic_child_count_max = 4,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 500,
			terminate_on_quiescent = true,
			checker_interval_ticks = 10,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			// I/O delay must be much longer than the timer (2 ticks) so the
			// timer fires first and the completion becomes stale.
			reactor_buffer_slot_count = 8,
			reactor_buffer_slot_size  = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			timer_resolution_ns       = 1_000_000, // 1ms per tick
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 8,
			scratch_arena_size        = 8192,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		// Override I/O delay to ensure the recv completes AFTER the timer fires.
		// Timer fires at tick ~2, I/O completion arrives at tick ~50+.
		sim.shards[0].reactor.backend.config.delay_range_ticks = {50, 100}

		simulator_run(&sim)

		shard := &sim.shards[0]

		// 1. The Isolate should have been torn down (returned .done after timeout)
		iso_state := shard.metadata[IO_TIMEOUT_TYPE_ID].state[0]
		testing.expect_value(t, iso_state, Isolate_State.Unallocated)

		// 2. At least one stale completion should have been discarded
		testing.expect(
			t,
			shard.counters.io_stale_completions >= 1,
			"Expected at least one stale I/O completion from the timer-wake sequence",
		)

		// 3. The reactor buffer pool must be whole — no leaks.
		// This is the critical invariant: the stale completion path freed the
		// buffer that was allocated at submission time, even though no explicit
		// backend_cancel was issued.
		pool := &shard.reactor.buffer_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] io_sequence stale completion reclamation verified. Stale completions: %d, buffer pool: %d/%d free.",
			shard.counters.io_stale_completions,
			pool.free_count,
			pool.slot_count,
		)
	}

	@(test)
	test_temporary_child_exit_no_escalation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [6]TypeDescriptor {
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
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = SUPERVISOR_TYPE_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			dynamic_child_count_max = 10,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 100,
			terminate_on_quiescent = true,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 4096,
			transfer_slot_count       = 4,
			transfer_slot_size        = 4096,
			timer_spoke_count         = 256,
			timer_entry_count         = 256,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_arena_size        = 65536,
		}

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		shard := &sim.shards[0]

		// Send a message to Exiter to trigger its handler (which returns Effect_Done)
		exiter_handle := make_handle(
			0,
			u16(EXITER_TYPE_ID),
			0,
			shard.metadata[EXITER_TYPE_ID].generation[0],
		)
		ctx := TinaContext {
			_shard      = shard,
			self_handle = HANDLE_NONE,
		}
		_ = ctx_send(&ctx, exiter_handle, APP_TAG_PING, &PingMsg{seq = 0})

		simulator_run(&sim)

		// Exiter should be torn down (temporary + normal exit = no restart)
		exiter_state := shard.metadata[EXITER_TYPE_ID].state[0]
		testing.expect_value(t, exiter_state, Isolate_State.Unallocated)

		// Bystander must still be alive — no escalation should have occurred
		bystander_state := shard.metadata[BYSTANDER_TYPE_ID].state[0]
		testing.expect_value(t, bystander_state, Isolate_State.Waiting)
	}

	// ============================================================================
	// Teardown step 2b: write/send buffer reclamation via one_for_all
	// ============================================================================
	//
	// Regression test for the bug where _teardown_isolate only freed buffers
	// for READ/RECV/RECVFROM completions, leaking WRITE/SEND/SENDTO buffers.
	//
	// Scenario:
	//   1. Writer submits .send in init → buffer allocated (copy-on-submit)
	//   2. Send completes → SEND_COMPLETE + buffer_index sit in Writer's SOA
	//   3. Crasher (lower type_id, dispatched first) crashes on the same tick
	//   4. one_for_all tears down Writer while SEND_COMPLETE is undispatched
	//   5. Teardown step 2b must free the write buffer
	//   6. After quiescence, reactor buffer pool must be whole (no leaks)

	WRITE_CRASHER_TYPE_ID: u8 : 0 // Must be lower than Writer for dispatch ordering
	WRITE_WRITER_TYPE_ID: u8 : 1

	WriteCrasherIsolate :: struct {}
	WriteWriterIsolate :: struct {
		fd:       FD_Handle,
		send_buf: [32]u8,
	}

	write_crasher_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Yield{} // Runnable every tick — dispatched before Writer (lower type_id)
	}

	write_crasher_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		// Crash exactly on tick 1 (when Writer's send completion arrives).
		// On any other tick (after restart), exit cleanly.
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
		// On receiving SEND_COMPLETE (after restart), exit cleanly.
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

		// I/O delay {1,1}: send completes on tick 1 (same tick Crasher crashes).
		// Crasher (type 7) dispatched before Writer (type 8) in Step 3.
		// one_for_all tears down Writer while SEND_COMPLETE sits in SOA.
		sim.shards[0].reactor.backend.config.delay_range_ticks = {1, 2}

		simulator_run(&sim)

		shard := &sim.shards[0]

		// Buffer pool must be whole — the write buffer allocated by .send
		// must have been freed by teardown step 2b during one_for_all teardown.
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
	//
	// Verifies that when an Isolate has both a pending I/O completion AND
	// shutdown_pending set simultaneously, the I/O completion is dispatched
	// first. This prevents the I/O overwrite bug described in GRACEFUL_SHUTDOWN
	// §4.2 — if TAG_SHUTDOWN were delivered first, the handler might submit
	// new I/O, overwriting the old completion and leaking its buffer.
	//
	// Approach: directly inject both states into SOA metadata, then tick once
	// and verify the handler received I/O first via a recorded tag sequence.

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
		return Effect_Yield{} // Stay runnable to receive the next message
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
			terminate_on_quiescent = false, // We control ticking manually
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

		// After init, the Isolate is in Waiting state (from Effect_Receive).
		// Manually inject the simultaneous I/O completion + shutdown state:

		// 1. Allocate a buffer to simulate a recv completion with data
		buffer_index, buffer_error := reactor_buffer_pool_alloc(&shard.reactor.buffer_pool)
		testing.expect_value(t, buffer_error, Buffer_Pool_Error.None)

		// 2. Set I/O completion in SOA metadata
		soa := shard.metadata[PRIORITY_TYPE_ID]
		soa[0].io_completion_tag = IO_TAG_RECV_COMPLETE
		soa[0].io_buffer_index = buffer_index
		soa[0].io_result = 128
		soa[0].state = .Runnable

		// 3. Set shutdown_pending simultaneously
		soa[0].flags += {.Shutdown_Pending}

		// 4. Tick once — dispatch must deliver I/O completion first (not TAG_SHUTDOWN)
		shard.current_tick = 1
		scheduler_tick(shard)

		// 5. Tick again — dispatch must deliver TAG_SHUTDOWN second
		shard.current_tick = 2
		scheduler_tick(shard)

		// 6. Verify the received tag order
		isolate_pointer := _get_isolate_ptr(shard, u16(PRIORITY_TYPE_ID), 0)
		iso := cast(^PriorityTestIsolate)isolate_pointer
		testing.expect_value(t, iso.received_count, 2)
		testing.expect_value(t, iso.received_tags[0], Message_Tag(IO_TAG_RECV_COMPLETE))
		testing.expect_value(t, iso.received_tags[1], TAG_SHUTDOWN)

		// 7. Buffer must have been freed after the I/O completion dispatch
		pool := &shard.reactor.buffer_pool
		testing.expect_value(t, pool.free_count, pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] Shutdown dispatch priority verified: I/O completion (0x%04X) delivered before TAG_SHUTDOWN (0x%04X).",
			u16(iso.received_tags[0]),
			u16(iso.received_tags[1]),
		)
	}

	// ============================================================================
	// Intra-Type Starvation Prevention (Dispatch Cursor Verification)
	// ============================================================================

	STARVATION_COORD_ID: u8 : 0
	STARVATION_WORKER_ID: u8 : 1

	StarvationWorker :: struct {
		run_count: u32,
	}

	starvation_coord_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		// Spawn 300 workers to exceed the 256 DISPATCH_QUOTA_PER_WEIGHT
		for i in 0 ..< 300 {
			spec := Spawn_Spec {
				type_id      = STARVATION_WORKER_ID,
				group_id     = ctx_supervision_group_id(ctx),
				restart_type = .temporary,
			}
			_ = assert_spawn_success(ctx_spawn(ctx, spec), "StarvationWorker")
		}
		return Effect_Receive{}
	}

	starvation_coord_handler :: proc(
		self: rawptr,
		message: ^Message,
		ctx: ^TinaContext,
	) -> Effect {
		return Effect_Receive{}
	}

	starvation_worker_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Yield{}
	}

	starvation_worker_handler :: proc(
		self: rawptr,
		message: ^Message,
		ctx: ^TinaContext,
	) -> Effect {
		w := cast(^StarvationWorker)self
		w.run_count += 1
		// Yielding keeps us in .Runnable state, ensuring we always consume budget
		return Effect_Yield{}
	}

	@(test)
	test_intra_type_starvation_prevention :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]TypeDescriptor {
			{
				id                = STARVATION_COORD_ID,
				slot_count        = 1,
				stride            = 0, // Zero-sized, purely behavioral
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn           = starvation_coord_init,
				handler_fn        = starvation_coord_handler,
			},
			{
				id                = STARVATION_WORKER_ID,
				slot_count        = 300,
				stride            = size_of(StarvationWorker),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn           = starvation_worker_init,
				handler_fn        = starvation_worker_handler,
				budget_weight     = 1, // Quota = 1 * 256 = 256 dispatches per tick
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = STARVATION_COORD_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			dynamic_child_count_max = 305, // Room for 1 Coord + 300 Workers + padding/wiggle-room
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10, // Exactly 10 ticks. 10 * 256 budget = 2560 dispatches
			terminate_on_quiescent = false, // Never quiescent because workers always yield
			checker_interval_ticks = 10,
		}

		spec := SystemSpec {
			shard_count               = 1,
			types                     = types[:],
			shard_specs               = shard_specs[:],
			simulation                = &sim_config,
			pool_slot_count           = 256,
			reactor_buffer_slot_count = 4,
			reactor_buffer_slot_size  = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 1024,
			timer_spoke_count         = 64,
			timer_entry_count         = 64,
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

		// Run the 10 ticks
		simulator_run(&sim)

		shard := &sim.shards[0]
		starved_count: u32 = 0
		min_runs: u32 = max(u32)
		max_runs: u32 = 0

		// Verify every single worker got a fair share of the 2,560 total dispatches
		for i in 0 ..< 300 {
			worker_pointer := _get_isolate_ptr(shard, u16(STARVATION_WORKER_ID), u32(i))
			worker := cast(^StarvationWorker)worker_pointer

			if worker.run_count == 0 {
				starved_count += 1
			}

			if worker.run_count < min_runs do min_runs = worker.run_count
			if worker.run_count > max_runs do max_runs = worker.run_count
		}

		// If the bug exists, starved_count will be exactly 44 (slots 256 to 299)
		testing.expect_value(t, starved_count, 0)

		// Mathematical fairness check: 2560 total dispatches / 300 isolates = ~8.5
		// Every isolate should have run 8 or 9 times.
		testing.expect(t, min_runs >= 8, "Fairness violation: some isolates ran too rarely")
		testing.expect(t, max_runs <= 9, "Fairness violation: some isolates ran too often")

		fmt.printfln(
			"\n[TEST SUCCESS] Intra-type starvation prevented. All 300 isolates ran fairly (Min: %d, Max: %d).",
			min_runs,
			max_runs,
		)
	}

	// ============================================================================
	// Software Panic Containment (§6.5.1)
	// ============================================================================
	// End-to-end verification of assert(false) → tina_assertion_failure_proc →
	// siglongjmp → trap boundary recovery cannot be tested inside `odin test`.
	//
	// Reason: Odin's test runner owns process-wide signal handlers (SIGILL,
	// SIGTRAP, SIGABRT via libc.signal) and overrides context.assertion_failure_proc
	// with its own test_assertion_failure_proc. These conflict with Tina's
	// siglongjmp-based containment model — the test runner intercepts the signal
	// before siglongjmp can transfer control.
	//
	// Production coverage: The inner trap boundary (scheduler_tick's sigsetjmp)
	// and outer trap boundary (bootstrap_shard's sigsetjmp) are exercised by
	// hardware fault paths (SIGSEGV, SIGBUS, SIGFPE) in production, which share
	// the identical siglongjmp recovery mechanism.
	//
	// To verify the full software panic path, use a standalone subprocess harness
	// that runs shard_thread_entry directly, without Odin's test runner.
	// ============================================================================
}
