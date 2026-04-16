package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {
	FD_HANDOFF_LISTENER_TYPE_ID: u8 : 0
	FD_HANDOFF_DISPATCHER_TYPE_ID: u8 : 1
	FD_HANDOFF_BUSY_DISPATCHER_TYPE_ID: u8 : 1

	FDHandoffListener :: struct {
		listen_fd:       FD_Handle,
		target_handle:   Handle,
		handoff_result:  FD_Handoff_Result,
		hand_offered:    bool,
	}

	FDHandoffDispatcher :: struct {
		received_accept: bool,
		client_fd:       FD_Handle,
		peer_port:       u16,
	}

	FDHandoffBusyDispatcher :: struct {
		fd: FD_Handle,
	}

	fd_handoff_listener_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		iso := cast(^FDHandoffListener)self
		fd, err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
		if err != .None {
			return Effect_Crash{reason = .Init_Failed}
		}

		iso.listen_fd = fd
		iso.target_handle = (cast(^Handle)&args[0])^

		bind_err := ctx_bind(ctx, fd, Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 8080})
		if bind_err != .None {
			return Effect_Crash{reason = .Init_Failed}
		}
		if ctx_listen(ctx, fd, 16) != .None {
			return Effect_Crash{reason = .Init_Failed}
		}

		return Effect_Io{operation = IoOp_Accept{listen_fd = fd}}
	}

	fd_handoff_listener_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		iso := cast(^FDHandoffListener)self
		if message != nil && message.tag == IO_TAG_ACCEPT_COMPLETE {
			iso.handoff_result = ctx_fd_handoff(ctx, iso.target_handle, message.io.fd)
			iso.hand_offered = iso.handoff_result == .ok
			return Effect_Receive{}
		}
		return Effect_Receive{}
	}

	fd_handoff_dispatcher_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	fd_handoff_dispatcher_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		iso := cast(^FDHandoffDispatcher)self
		if message != nil && message.tag == IO_TAG_ACCEPT_COMPLETE {
			iso.received_accept = true
			iso.client_fd = message.io.fd
			iso.peer_port = message.io.peer_address.port
		}
		return Effect_Receive{}
	}

	fd_handoff_busy_dispatcher_init :: proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
		iso := cast(^FDHandoffBusyDispatcher)self
		fd, err := ctx_socket(ctx, .AF_INET, .STREAM, .TCP)
		if err != .None {
			return Effect_Crash{reason = .Init_Failed}
		}
		iso.fd = fd
		return Effect_Io{operation = IoOp_Recv{fd = fd, buffer_size_max = 64}}
	}

	fd_handoff_busy_dispatcher_handler :: proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
		return Effect_Receive{}
	}

	@(test)
	test_fd_handoff_accept_completion_reaches_remote_dispatcher :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		target_handle := make_handle(1, u16(FD_HANDOFF_DISPATCHER_TYPE_ID), 0, 1)
		listener_args_size, listener_args_payload := sim_test_pack_init_args(bytes_of(&target_handle))

		types := [2]TypeDescriptor {
			{
				id = FD_HANDOFF_LISTENER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffListener),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_listener_init,
				handler_fn = fd_handoff_listener_handler,
				mailbox_capacity = 8,
				budget_weight = 1,
			},
			{
				id = FD_HANDOFF_DISPATCHER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffDispatcher),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_dispatcher_init,
				handler_fn = fd_handoff_dispatcher_handler,
				mailbox_capacity = 1,
				budget_weight = 1,
			},
		}

		shard_0_children := [1]Child_Spec {
			Static_Child_Spec {
				type_id = FD_HANDOFF_LISTENER_TYPE_ID,
				restart_type = .permanent,
				args_size = listener_args_size,
				args_payload = listener_args_payload,
			},
		}
		shard_1_children := [1]Child_Spec {
			Static_Child_Spec {type_id = FD_HANDOFF_DISPATCHER_TYPE_ID, restart_type = .permanent},
		}
		root_group_0 := sim_test_make_root_group(shard_0_children[:])
		root_group_1 := sim_test_make_root_group(shard_1_children[:])
		shard_specs := [2]ShardSpec {
			{shard_id = 0, root_group = root_group_0},
			{shard_id = 1, root_group = root_group_1},
		}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 64,
			terminate_on_quiescent = true,
			builtin_checkers = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 8,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			Sim_Test_Spec_Options {
				reactor_buffer_slot_count = 8,
				fd_handoff_entry_count = 4,
				timer_spoke_count = 256,
				timer_entry_count = 256,
				supervision_groups_max = 8,
			},
		)

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {0, 0}
		sim.shards[1].reactor.backend.config.delay_range_ticks = {0, 0}
		simulator_run(&sim)

		listener := cast(^FDHandoffListener)_get_isolate_ptr(&sim.shards[0], u16(FD_HANDOFF_LISTENER_TYPE_ID), 0)
		dispatcher := cast(^FDHandoffDispatcher)_get_isolate_ptr(&sim.shards[1], u16(FD_HANDOFF_DISPATCHER_TYPE_ID), 0)

		testing.expect_value(t, listener.handoff_result, FD_Handoff_Result.ok)
		testing.expect(t, listener.hand_offered, "listener should successfully initiate handoff")
		testing.expect(t, dispatcher.received_accept, "dispatcher should receive injected accept completion")
		testing.expect(t, dispatcher.client_fd != FD_HANDLE_NONE, "dispatcher should receive adopted FD")
		testing.expect_value(t, dispatcher.peer_port, u16(9999))
		testing.expect_value(
			t,
			sim.shards[0].handoff_table.free_count,
			sim.shards[0].handoff_table.entry_count,
		)
	}

	@(test)
	test_fd_handoff_rejects_when_dispatcher_is_busy :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		target_handle := make_handle(1, u16(FD_HANDOFF_BUSY_DISPATCHER_TYPE_ID), 0, 1)
		listener_args_size, listener_args_payload := sim_test_pack_init_args(bytes_of(&target_handle))

		types := [2]TypeDescriptor {
			{
				id = FD_HANDOFF_LISTENER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffListener),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_listener_init,
				handler_fn = fd_handoff_listener_handler,
				mailbox_capacity = 8,
				budget_weight = 1,
			},
			{
				id = FD_HANDOFF_BUSY_DISPATCHER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffBusyDispatcher),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_busy_dispatcher_init,
				handler_fn = fd_handoff_busy_dispatcher_handler,
				mailbox_capacity = 1,
				budget_weight = 1,
			},
		}

		shard_0_children := [1]Child_Spec {
			Static_Child_Spec {
				type_id = FD_HANDOFF_LISTENER_TYPE_ID,
				restart_type = .permanent,
				args_size = listener_args_size,
				args_payload = listener_args_payload,
			},
		}
		shard_1_children := [1]Child_Spec {
			Static_Child_Spec {type_id = FD_HANDOFF_BUSY_DISPATCHER_TYPE_ID, restart_type = .permanent},
		}
		root_group_0 := sim_test_make_root_group(shard_0_children[:])
		root_group_1 := sim_test_make_root_group(shard_1_children[:])
		shard_specs := [2]ShardSpec {
			{shard_id = 0, root_group = root_group_0},
			{shard_id = 1, root_group = root_group_1},
		}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 8,
			terminate_on_quiescent = false,
			builtin_checkers = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 8,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			Sim_Test_Spec_Options {
				reactor_buffer_slot_count = 8,
				fd_handoff_entry_count = 4,
				timer_spoke_count = 256,
				timer_entry_count = 256,
				supervision_groups_max = 8,
			},
		)

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {0, 0}
		sim.shards[1].reactor.backend.config.delay_range_ticks = {64, 64}
		simulator_run(&sim)

		listener := cast(^FDHandoffListener)_get_isolate_ptr(&sim.shards[0], u16(FD_HANDOFF_LISTENER_TYPE_ID), 0)
		testing.expect_value(t, listener.handoff_result, FD_Handoff_Result.ok)
		testing.expect_value(t, sim.shards[0].counters.handoff_rejects, u64(1))
		testing.expect_value(
			t,
			sim.shards[0].handoff_table.free_count,
			sim.shards[0].handoff_table.entry_count,
		)
	}

	// Regression test: the OFFER is delayed past the timeout threshold.
	// The source must NOT close the offered FDs on timeout — doing so causes
	// an ABA vulnerability in production (kernel reuses the FD integer) and
	// adopt failure in simulation (descriptor closed before dup).
	// The dispatcher must still receive the adopted socket after the delayed
	// OFFER is delivered.
	@(test)
	test_fd_handoff_late_offer_still_adopts_after_timeout :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		target_handle := make_handle(1, u16(FD_HANDOFF_DISPATCHER_TYPE_ID), 0, 1)
		listener_args_size, listener_args_payload := sim_test_pack_init_args(bytes_of(&target_handle))

		types := [2]TypeDescriptor {
			{
				id = FD_HANDOFF_LISTENER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffListener),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_listener_init,
				handler_fn = fd_handoff_listener_handler,
				mailbox_capacity = 8,
				budget_weight = 1,
			},
			{
				id = FD_HANDOFF_DISPATCHER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffDispatcher),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_dispatcher_init,
				handler_fn = fd_handoff_dispatcher_handler,
				mailbox_capacity = 1,
				budget_weight = 1,
			},
		}

		shard_0_children := [1]Child_Spec {
			Static_Child_Spec {
				type_id = FD_HANDOFF_LISTENER_TYPE_ID,
				restart_type = .permanent,
				args_size = listener_args_size,
				args_payload = listener_args_payload,
			},
		}
		shard_1_children := [1]Child_Spec {
			Static_Child_Spec {type_id = FD_HANDOFF_DISPATCHER_TYPE_ID, restart_type = .permanent},
		}
		root_group_0 := sim_test_make_root_group(shard_0_children[:])
		root_group_1 := sim_test_make_root_group(shard_1_children[:])
		shard_specs := [2]ShardSpec {
			{shard_id = 0, root_group = root_group_0},
			{shard_id = 1, root_group = root_group_1},
		}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 64,
			terminate_on_quiescent = true,
			builtin_checkers = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 8,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			Sim_Test_Spec_Options {
				reactor_buffer_slot_count = 8,
				fd_handoff_entry_count = 4,
				timer_spoke_count = 256,
				timer_entry_count = 256,
				supervision_groups_max = 8,
			},
		)

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {0, 0}
		sim.shards[1].reactor.backend.config.delay_range_ticks = {0, 0}

		// Key difference from late-ACK test: delay the OFFER (source→destination)
		// past the timeout threshold, while keeping ACK path fast.
		for round in u64(0) ..< (FD_HANDOFF_TIMEOUT_TICKS + 8) {
			sim.shards[0].current_tick = round
			sim.network.channels[0][1].delay_ticks = u32(FD_HANDOFF_TIMEOUT_TICKS + 4)
			scheduler_tick(&sim.shards[0])

			sim.shards[1].current_tick = round
			sim.network.channels[1][0].delay_ticks = 0
			scheduler_tick(&sim.shards[1])
		}

		listener := cast(^FDHandoffListener)_get_isolate_ptr(&sim.shards[0], u16(FD_HANDOFF_LISTENER_TYPE_ID), 0)
		dispatcher := cast(^FDHandoffDispatcher)_get_isolate_ptr(&sim.shards[1], u16(FD_HANDOFF_DISPATCHER_TYPE_ID), 0)

		testing.expect_value(t, listener.handoff_result, FD_Handoff_Result.ok)
		// The critical assertion: even though the source observed a timeout,
		// the destination must still successfully adopt the socket from the
		// delayed OFFER. If this fails, the offered FD was closed prematurely.
		testing.expect(t, dispatcher.received_accept, "late OFFER must still be adoptable after source timeout")
		testing.expect(t, dispatcher.client_fd != FD_HANDLE_NONE, "dispatcher should receive adopted FD")
		testing.expect_value(t, dispatcher.peer_port, u16(9999))
		testing.expect_value(t, sim.shards[0].counters.handoff_timeouts, u64(1))
		testing.expect_value(
			t,
			sim.shards[0].handoff_table.free_count,
			sim.shards[0].handoff_table.entry_count,
		)
	}

	@(test)
	test_fd_handoff_timeout_ignores_late_ack :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		target_handle := make_handle(1, u16(FD_HANDOFF_DISPATCHER_TYPE_ID), 0, 1)
		listener_args_size, listener_args_payload := sim_test_pack_init_args(bytes_of(&target_handle))

		types := [2]TypeDescriptor {
			{
				id = FD_HANDOFF_LISTENER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffListener),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_listener_init,
				handler_fn = fd_handoff_listener_handler,
				mailbox_capacity = 8,
				budget_weight = 1,
			},
			{
				id = FD_HANDOFF_DISPATCHER_TYPE_ID,
				slot_count = 1,
				stride = size_of(FDHandoffDispatcher),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = fd_handoff_dispatcher_init,
				handler_fn = fd_handoff_dispatcher_handler,
				mailbox_capacity = 1,
				budget_weight = 1,
			},
		}

		shard_0_children := [1]Child_Spec {
			Static_Child_Spec {
				type_id = FD_HANDOFF_LISTENER_TYPE_ID,
				restart_type = .permanent,
				args_size = listener_args_size,
				args_payload = listener_args_payload,
			},
		}
		shard_1_children := [1]Child_Spec {
			Static_Child_Spec {type_id = FD_HANDOFF_DISPATCHER_TYPE_ID, restart_type = .permanent},
		}
		root_group_0 := sim_test_make_root_group(shard_0_children[:])
		root_group_1 := sim_test_make_root_group(shard_1_children[:])
		shard_specs := [2]ShardSpec {
			{shard_id = 0, root_group = root_group_0},
			{shard_id = 1, root_group = root_group_1},
		}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 64,
			terminate_on_quiescent = true,
			builtin_checkers = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 8,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			Sim_Test_Spec_Options {
				reactor_buffer_slot_count = 8,
				fd_handoff_entry_count = 4,
				timer_spoke_count = 256,
				timer_entry_count = 256,
				supervision_groups_max = 8,
			},
		)

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {0, 0}
		sim.shards[1].reactor.backend.config.delay_range_ticks = {0, 0}

		for round in u64(0) ..< (FD_HANDOFF_TIMEOUT_TICKS + 8) {
			sim.shards[0].current_tick = round
			sim.network.channels[0][1].delay_ticks = 0
			scheduler_tick(&sim.shards[0])

			sim.shards[1].current_tick = round
			sim.network.channels[1][0].delay_ticks = u32(FD_HANDOFF_TIMEOUT_TICKS + 4)
			scheduler_tick(&sim.shards[1])
		}

		listener := cast(^FDHandoffListener)_get_isolate_ptr(&sim.shards[0], u16(FD_HANDOFF_LISTENER_TYPE_ID), 0)
		dispatcher := cast(^FDHandoffDispatcher)_get_isolate_ptr(&sim.shards[1], u16(FD_HANDOFF_DISPATCHER_TYPE_ID), 0)

		testing.expect_value(t, listener.handoff_result, FD_Handoff_Result.ok)
		testing.expect(t, dispatcher.received_accept, "dispatcher should still receive adopted socket before timeout")
		testing.expect_value(t, sim.shards[0].counters.handoff_timeouts, u64(1))
		testing.expect_value(t, sim.shards[0].counters.handoff_rejects, u64(0))
		testing.expect_value(
			t,
			sim.shards[0].handoff_table.free_count,
			sim.shards[0].handoff_table.entry_count,
		)
	}
}
