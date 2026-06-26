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
	) -> Isolate_Handle {
		switch v in res {
		case Isolate_Handle:
			return v
		case Spawn_Error:
			// panic() diverges (never returns), so no return statement is needed after it
			panic(fmt.tprintf("[QA FATAL] Spawn failed for '%s'. Error Code: %v", name, v), loc)
		}
		unreachable()
	}

	COORDINATOR_TYPE_ID: Isolate_Type_Id : 0
	PING_TYPE_ID: Isolate_Type_Id : 1
	PONG_TYPE_ID: Isolate_Type_Id : 2
	SUPERVISOR_TYPE_ID: Isolate_Type_Id : 3
	EXITER_TYPE_ID: Isolate_Type_Id : 4
	BYSTANDER_TYPE_ID: Isolate_Type_Id : 5

	APP_TAG_PING: Message_Tag : USER_MESSAGE_TAG_BASE + 1
	APP_TAG_PONG: Message_Tag : USER_MESSAGE_TAG_BASE + 2

	PingMsg :: struct {
		seq: u32,
	}
	PongMsg :: struct {
		seq: u32,
	}

	PingInitArgs :: struct {
		pong_handle: Isolate_Handle,
	}

	// Simulation-only diagnostic field IDs for Ping observation.
	PING_DIAGNOSTIC_COUNT: Diagnostic_Field_Id : 0

	Coordinator :: struct {}
	PingIsolate :: struct {
		pong_handle: Isolate_Handle,
		count:       u32,
	}
	PongIsolate :: struct {}

	// ======================================
	// Coordinator (Spawns Ping and Pong)
	// ======================================
	coordinator_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		// 1. Spawn Pong
		pong_spec := Spawn_Spec {
			type_id      = PONG_TYPE_ID,
			group_id     = ctx_supervision_group_id(), // Inherit the coordinator's group
			restart_type = .temporary,
		}
		pong_res := ctx_spawn(pong_spec)
		pong_handle := assert_spawn_success(pong_res, "Pong")

		// 2. Spawn Ping, passing Pong's Handle via init_args
		ping_args := PingInitArgs {
			pong_handle = pong_handle,
		}
		payload, payload_len := make_spawn_args(&ping_args)

		ping_spec := Spawn_Spec {
			type_id      = PING_TYPE_ID,
			group_id     = ctx_supervision_group_id(), // Inherit the coordinator's group
			restart_type = .temporary,
			args_payload = payload,
			args_size    = payload_len,
		}
		ping_res := ctx_spawn(ping_spec)
		_ = assert_spawn_success(ping_res, "Ping")

		// Park forever
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	coordinator_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	// =================
	// Ping Isolate
	// =================
	ping_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		p := cast(^PingIsolate)self
		init_args := payload_as(PingInitArgs, args)
		p.pong_handle = init_args.pong_handle
		p.count = 0

		msg := PingMsg {
			seq = 0,
		}
		_ = ctx_send(p.pong_handle, APP_TAG_PING, &msg)

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	ping_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		using p := cast(^PingIsolate)self
		pong := payload_as(PongMsg, message.user.payload[:])

		count += 1

		// Write a control-plane diagnostic on every invocation so fault-
		// injected runs that crash midway still capture the last known count.
		// Tests read this scalar record after simulator_run instead of
		// accessing freed isolate payload memory.
		ctx_test_diagnostic_write_u64(PING_DIAGNOSTIC_COUNT, u64(count))

		if count >= 100 {
			return ISOLATE_TRANSITION_DONE
		}

		msg := PingMsg {
			seq = pong.seq + 1,
		}
		_ = ctx_send(p.pong_handle, APP_TAG_PING, &msg)
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	// ================
	// Pong Isolate
	// ================
	pong_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	pong_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		ping := payload_as(PingMsg, message.user.payload[:])

		msg := PongMsg {
			seq = ping.seq,
		}
		_ = ctx_send(message.user.source, APP_TAG_PONG, &msg)

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	// (Test) ---
	@(test)
	test_ping_pong_simulation :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [3]IsolateTypeDescriptor {
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
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = COORDINATOR_TYPE_ID, restart_type = .permanent},
		}

		root_group := Group_Spec {
			strategy                = .One_For_One,
			restart_count_max       = 3,
			window_duration_ticks   = 1000,
			children                = children[:],
			child_count_dynamic_max = 10,
		}

		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 10_000,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
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
			staging_slot_count        = 2,
			staging_slot_size         = 1024,
			transfer_slot_count       = 4,
			transfer_slot_size        = 4096,
			timer_entry_count         = 1024,
			fd_table_slot_count       = 16,
			fd_entry_size             = size_of(FD_Entry),
			log_ring_size             = 4096,
			supervision_groups_max    = 16,
			scratch_memory_size        = 65536,
		}

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		simulator_run(&sim)

		shard := &sim.shards[0]

		// Assert Ping terminated cleanly
		ping_state := shard.metadata[PING_TYPE_ID]._state[0]
		testing.expect_value(t, ping_state, Isolate_State.Unallocated)

		// Assert Pong is quiescent
		pong_state := shard.metadata[PONG_TYPE_ID]._state[0]
		testing.expect_value(t, pong_state, Isolate_State.Wait_Message)

		// Prove Ping hit 100 iterations. The count is captured by the
		// handler on every invocation, so it survives isolate teardown.
		shard_test_diagnostic_expect_u64(t, shard, PING_TYPE_ID, 0, PING_DIAGNOSTIC_COUNT, 100)
		ping_count, _ := shard_diagnostic_read(shard, PING_TYPE_ID, 0, PING_DIAGNOSTIC_COUNT)

		fmt.printfln(
			"\n[TEST SUCCESS] Ping completed exactly %d round trips before terminating.",
			ping_count,
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
