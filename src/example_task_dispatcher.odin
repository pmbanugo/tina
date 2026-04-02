package tina

import "core:fmt"
import "core:os"

DEMO_CRASH_EVERY :: #config(TINA_DEMO_CRASH_EVERY, 5)
DEMO_ROOT_RESTART_MAX :: #config(TINA_DEMO_ROOT_RESTART_MAX, 10)
DEMO_ROOT_WINDOW_TICKS :: #config(TINA_DEMO_ROOT_WINDOW_TICKS, 5_000)
DEMO_SHARD_RESTART_MAX :: #config(TINA_DEMO_SHARD_RESTART_MAX, 3)
DEMO_SHARD_RESTART_WINDOW_MS :: #config(TINA_DEMO_SHARD_RESTART_WINDOW_MS, 30_000)
DEMO_ABORT_ON_QUARANTINE :: #config(TINA_DEMO_ABORT_ON_QUARANTINE, false)

// ============================================================================
// Type IDs & Message Tags
// ============================================================================

DISPATCHER_ISOLATE_TYPE: u8 : 0
WORKER_ISOLATE_TYPE: u8 : 1

TAG_WORKER_READY: Message_Tag : USER_MESSAGE_TAG_BASE + 1
TAG_JOB: Message_Tag : USER_MESSAGE_TAG_BASE + 2
TAG_JOB_DONE: Message_Tag : USER_MESSAGE_TAG_BASE + 3
TAG_DISPATCH_TICK: Message_Tag : USER_MESSAGE_TAG_BASE + 4

// ============================================================================
// Payloads & Init Args (Max 96 bytes for payload, 64 bytes for args)
// ============================================================================

// Passed to Worker during spawn, so it knows who its boss is.
WorkerInitArgs :: struct {
	id:         u32,
	dispatcher: Handle,
}

WorkerReadyMsg :: struct {
	id:     u32,
	handle: Handle,
}

JobMsg :: struct {
	job_id: u32,
}

JobDoneMsg :: struct {
	job_id:    u32,
	worker_id: u32,
}

// ============================================================================
// The Worker Isolate
// ============================================================================

WorkerIsolate :: struct {
	id:         u32,
	dispatcher: Handle,
}

worker_init :: proc(self_raw: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
	self := self_as(WorkerIsolate, self_raw, ctx)

	// 1. Parse the initialization arguments
	init_args := payload_as(WorkerInitArgs, args)
	self.id = init_args.id
	self.dispatcher = init_args.dispatcher

	// 2. The Check-in Pattern: Tell the boss we are alive and hand over our ephemeral Handle.
	// If we just crashed and restarted, ctx.self_handle is now a brand new Handle!
	ready_msg := WorkerReadyMsg {
		id     = self.id,
		handle = ctx.self_handle,
	}
	_ = ctx_send(ctx, self.dispatcher, TAG_WORKER_READY, &ready_msg)

	return Effect_Receive{}
}

worker_handler :: proc(self_raw: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
	using self := self_as(WorkerIsolate, self_raw, ctx)
	// log_buf: [128]u8

	switch message.tag {
	case TAG_JOB:
		msg := payload_as(JobMsg, message.user.payload[:])

		if DEMO_CRASH_EVERY > 0 && msg.job_id % u32(DEMO_CRASH_EVERY) == 0 {
			str := fmt.bprintf(
				ctx.scratch_arena.data, // log_buf[:],
				"Worker %d: Job %d is cursed! I am PANICKING!",
				id,
				msg.job_id,
			)
			ctx_log(ctx, .ERROR, USER_LOG_TAG_BASE, transmute([]u8)str)

			// Returning .Crash triggers the Trap Boundary. The Supervisor will instantly tear us down.
			return Effect_Crash{reason = .None}
		}

		// Happy Path: Do the job and report success.
		// str := fmt.bprintf(log_buf[:], "Worker %d: Completed Job %d.", id, msg.job_id)
		str := fmt.bprintf(ctx.scratch_arena.data, "Worker %d: Completed Job %d.", id, msg.job_id)
		ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)str)

		done_msg := JobDoneMsg {
			job_id    = msg.job_id,
			worker_id = id,
		}
		_ = ctx_send(ctx, dispatcher, TAG_JOB_DONE, &done_msg)
		return Effect_Receive{}

	case:
		return Effect_Receive{}
	}
}

// ============================================================================
// The Dispatcher Isolate
// ============================================================================

NUM_WORKERS :: 3

DispatcherIsolate :: struct {
	workers:     [NUM_WORKERS]Handle,
	job_counter: u32,
}

dispatcher_init :: proc(self_raw: rawptr, args: []u8, ctx: ^TinaContext) -> Effect {
	self := self_as(DispatcherIsolate, self_raw, ctx)

	ctx_log(
		ctx,
		.INFO,
		USER_LOG_TAG_BASE,
		transmute([]u8)string("Dispatcher booting. Spawning workforce..."),
	)

	// 1. Spawn the workers
	for i in 0 ..< NUM_WORKERS {
		self.workers[i] = HANDLE_NONE // We don't know their handles yet!

		init_args := WorkerInitArgs {
			id         = u32(i),
			dispatcher = ctx.self_handle,
		}
		payload, size := init_args_of(&init_args)

		spec := Spawn_Spec {
			type_id      = WORKER_ISOLATE_TYPE,
			group_id     = ctx_supervision_group_id(ctx),
			restart_type = .permanent,
			args_payload = payload,
			args_size    = size,
		}
		_ = ctx_spawn(ctx, spec)
	}

	// 2. Start the work loop (fires every 400ms)
	ctx_register_timer(ctx, 400 * 1_000_000, TAG_DISPATCH_TICK)

	return Effect_Receive{}
}

dispatcher_handler :: proc(self_raw: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect {
	using self := self_as(DispatcherIsolate, self_raw, ctx)
	log_buf: [128]u8

	switch message.tag {
	case TAG_WORKER_READY:
		// A worker checked in! This happens at boot, AND after a worker recovers from a crash.
		msg := payload_as(WorkerReadyMsg, message.user.payload[:])
		workers[msg.id] = msg.handle

		str := fmt.bprintf(
			log_buf[:],
			"Dispatcher: Worker %d checked in. (Handle: %X)",
			msg.id,
			u64(msg.handle),
		)
		ctx_log(ctx, .DEBUG, USER_LOG_TAG_BASE, transmute([]u8)str)
		return Effect_Receive{}

	case TAG_JOB_DONE:
		msg := payload_as(JobDoneMsg, message.user.payload[:])
		str := fmt.bprintf(
			log_buf[:],
			"Dispatcher: Acknowledged Job %d done by Worker %d.",
			msg.job_id,
			msg.worker_id,
		)
		ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)str)
		return Effect_Receive{}

	case TAG_DISPATCH_TICK:
		// job_counter += 1
		// target_id := job_counter % NUM_WORKERS
		// target_handle := workers[target_id]

		// if target_handle != HANDLE_NONE {
		// 	// Try to send the job
		// 	job := JobMsg {
		// 		job_id = job_counter,
		// 	}
		// 	res := ctx_send(ctx, target_handle, TAG_JOB, &job)

		// 	// LOAD SHEDDING: If the handle is stale, the worker crashed and hasn't checked back in yet!
		// 	if res == .stale_handle {
		// 		str := fmt.bprintf(
		// 			log_buf[:],
		// 			"Dispatcher: Worker %d is dead! Dropping Job %d. Awaiting respawn...",
		// 			target_id,
		// 			job_counter,
		// 		)
		// 		ctx_log(ctx, .WARN, USER_LOG_TAG_BASE, transmute([]u8)str)

		// 		// Clear the stale handle so we don't try again until it checks in
		// 		workers[target_id] = HANDLE_NONE
		// 	} else {
		// 		str := fmt.bprintf(
		// 			log_buf[:],
		// 			"Dispatcher: Assigned Job %d to Worker %d.",
		// 			job_counter,
		// 			target_id,
		// 		)
		// 		ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)str)
		// 	}
		// } else {
		// 	str := fmt.bprintf(
		// 		log_buf[:],
		// 		"Dispatcher: Worker %d is offline. Job %d dropped.",
		// 		target_id,
		// 		job_counter,
		// 	)
		// 	ctx_log(ctx, .WARN, USER_LOG_TAG_BASE, transmute([]u8)str)
		// }

		for target_id in 0 ..< len(workers) {
			job_counter += 1
			target_handle := workers[target_id]
			if target_handle != HANDLE_NONE {
				// Try to send the job
				job := JobMsg {
					job_id = job_counter,
				}
				res := ctx_send(ctx, target_handle, TAG_JOB, &job)

				// LOAD SHEDDING: If the handle is stale, the worker crashed and hasn't checked back in yet!
				if res == .stale_handle {
					str := fmt.bprintf(
						log_buf[:],
						"Dispatcher: Worker %d is dead! Dropping Job %d. Awaiting respawn...",
						target_id,
						job_counter,
					)
					ctx_log(ctx, .WARN, USER_LOG_TAG_BASE, transmute([]u8)str)

					// Clear the stale handle so we don't try again until it checks in
					workers[target_id] = HANDLE_NONE
				} else {
					str := fmt.bprintf(
						log_buf[:],
						"Dispatcher: Assigned Job %d to Worker %d.",
						job_counter,
						target_id,
					)
					ctx_log(ctx, .INFO, USER_LOG_TAG_BASE, transmute([]u8)str)
				}
			} else {
				str := fmt.bprintf(
					log_buf[:],
					"Dispatcher: Worker %d is offline. Job %d dropped.",
					target_id,
					job_counter,
				)
				ctx_log(ctx, .WARN, USER_LOG_TAG_BASE, transmute([]u8)str)
			}
		}

		// Re-arm the loop
		ctx_register_timer(ctx, 300 * 1_000_000, TAG_DISPATCH_TICK)
		return Effect_Receive{}

	case:
		return Effect_Receive{}
	}
}

// ============================================================================
// System Boot Specification
// ============================================================================

main :: proc() {
	quarantine_policy := Quarantine_Policy.Quarantine
	if DEMO_ABORT_ON_QUARANTINE do quarantine_policy = .Abort

	types := [2]TypeDescriptor {
		{
			id = DISPATCHER_ISOLATE_TYPE,
			slot_count = 1,
			stride = size_of(DispatcherIsolate),
			soa_metadata_size = size_of(Isolate_Metadata),
			init_fn = dispatcher_init,
			handler_fn = dispatcher_handler,
			mailbox_capacity = 64,
		},
		{
			id = WORKER_ISOLATE_TYPE,
			slot_count = 10,
			stride = size_of(WorkerIsolate),
			soa_metadata_size = size_of(Isolate_Metadata),
			init_fn = worker_init,
			handler_fn = worker_handler,
			mailbox_capacity = 16,
		},
	}

	children := [1]Child_Spec {
		Static_Child_Spec{type_id = DISPATCHER_ISOLATE_TYPE, restart_type = .temporary},
	}

	root_group := Group_Spec {
		strategy                = .One_For_One,
		restart_count_max       = DEMO_ROOT_RESTART_MAX,
		window_duration_ticks   = DEMO_ROOT_WINDOW_TICKS,
		children                = children[:],
		child_count_dynamic_max = 10,
	}

	shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group, target_core = -1}}

	spec := SystemSpec {
		quarantine_policy = quarantine_policy,
		watchdog = Watchdog_Config {
			check_interval_ms = 500,
			shard_restart_window_ms = DEMO_SHARD_RESTART_WINDOW_MS,
			shard_restart_max = DEMO_SHARD_RESTART_MAX,
			phase_2_threshold = 2,
		},
		shard_count = 1,
		types = types[:],
		shard_specs = shard_specs[:],
		timer_resolution_ns = 1_000_000,
		pool_slot_count = 4096,
		timer_spoke_count = 1024,
		timer_entry_count = 1024,
		log_ring_size = 65536,
		default_ring_size = 16,
		scratch_arena_size = 65536,
		fd_table_slot_count = 16,
		fd_entry_size = size_of(FD_Entry),
		supervision_groups_max = 4,
		reactor_buffer_slot_count = 16,
		reactor_buffer_slot_size = 4096,
		transfer_slot_count = 16,
		transfer_slot_size = 4096,
		shutdown_timeout_ms = 3_000,
	}

	fmt.println("Starting Tina Task Dispatcher. Press Ctrl+C to shut down.")
	fmt.printfln(
		"[DEMO] crash_every=%d root_max=%d root_window_ticks=%d shard_max=%d shard_window_ms=%d quarantine_policy=%v pid=%d",
		DEMO_CRASH_EVERY,
		DEMO_ROOT_RESTART_MAX,
		DEMO_ROOT_WINDOW_TICKS,
		DEMO_SHARD_RESTART_MAX,
		DEMO_SHARD_RESTART_WINDOW_MS,
		quarantine_policy,
		os.get_pid(),
	)
	when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		fmt.println("[DEMO] To recover quarantined shards, run: kill -USR2 <pid>")
	}
	tina_start(&spec)
}
