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
