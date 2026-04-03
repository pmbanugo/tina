package main

import tina "../src"
import "core:fmt"
import "core:os"

DEMO_CRASH_EVERY :: #config(TINA_DEMO_CRASH_EVERY, 3)
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

TAG_WORKER_READY: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1
TAG_JOB: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 2
TAG_JOB_DONE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 3
TAG_DISPATCH_TICK: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 4

// ============================================================================
// Payloads & Init Args (Max 96 bytes for payload, 64 bytes for args)
// ============================================================================

// Passed to Worker during spawn, so it knows who its boss is.
WorkerInitArgs :: struct {
	id:         u32,
	dispatcher: tina.Handle,
}

WorkerReadyMsg :: struct {
	id:     u32,
	handle: tina.Handle,
}

JobMsg :: struct {
	job_id: u32,
}

JobDoneMsg :: struct {
	job_id:    u32,
	worker_id: u32,
}

// ============================================================================
// The Worker: crash, reboot, check in with a new identity
// ============================================================================

WorkerIsolate :: struct {
	id:         u32,
	dispatcher: tina.Handle,
}

worker_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(WorkerIsolate, self_raw, ctx)

	// 1. Parse the initialization arguments
	init_args := tina.payload_as(WorkerInitArgs, args)
	self.id = init_args.id
	self.dispatcher = init_args.dispatcher

	// After restart, the worker gets a new handle — the old one is dead.
	// If you know Elixir, this is like a process re-registering its PID.
	// If you know Go, there's no shared state to clean up from the dead worker.
	// If you know Rust, the old handle is a revoked capability, not a dangling pointer.

	// 2. The Check-in Pattern: Tell the boss we are alive and hand over our ephemeral Handle.
	// If we just crashed and restarted, ctx.self_handle is now a brand new Handle!
	ready_msg := WorkerReadyMsg {
		id     = self.id,
		handle = ctx.self_handle,
	}
	_ = tina.ctx_send(ctx, self.dispatcher, TAG_WORKER_READY, &ready_msg)

	str := fmt.bprintf(
		ctx.scratch_arena.data,
		"[RECOVER] Worker %d checked in with handle %X",
		self.id,
		u64(ctx.self_handle),
	)
	tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

	return tina.Effect_Receive{}
}

worker_handler :: proc(
	self_raw: rawptr,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	using self := tina.self_as(WorkerIsolate, self_raw, ctx)
	// log_buf: [128]u8

	switch message.tag {
	case TAG_JOB:
		msg := tina.payload_as(JobMsg, message.user.payload[:])

		if DEMO_CRASH_EVERY > 0 && msg.job_id % u32(DEMO_CRASH_EVERY) == 0 {
			str := fmt.bprintf(
				ctx.scratch_arena.data, // log_buf[:],
				"[FAIL] Worker %d crashed on Job %d. Watch: it will come back with a NEW handle.",
				id,
				msg.job_id,
			)
			tina.ctx_log(ctx, .ERROR, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

			// The supervisor tears it down and rebuilds from the boot spec.
			// Old handle becomes permanently stale — sends to it return .stale_handle.
			return tina.Effect_Crash{reason = .None}
		}

		// Happy Path: Do the job and report success.
		// str := fmt.bprintf(log_buf[:], "Worker %d: Completed Job %d.", id, msg.job_id)
		str := fmt.bprintf(ctx.scratch_arena.data, "Worker %d: Completed Job %d.", id, msg.job_id)
		tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

		done_msg := JobDoneMsg {
			job_id    = msg.job_id,
			worker_id = id,
		}
		_ = tina.ctx_send(ctx, dispatcher, TAG_JOB_DONE, &done_msg)
		return tina.Effect_Receive{}

	case:
		return tina.Effect_Receive{}
	}
}

// ============================================================================
// The Dispatcher: keep assigning work, shed load for the dead
// ============================================================================

NUM_WORKERS :: 3

DispatcherIsolate :: struct {
	workers:     [NUM_WORKERS]tina.Handle,
	job_counter: u32,
}

dispatcher_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
	self := tina.self_as(DispatcherIsolate, self_raw, ctx)

	tina.ctx_log(
		ctx,
		.INFO,
		tina.USER_LOG_TAG_BASE,
		transmute([]u8)string("Dispatcher booting. Spawning workforce..."),
	)

	// 1. Spawn the workers
	for i in 0 ..< NUM_WORKERS {
		self.workers[i] = tina.HANDLE_NONE // We don't know their handles yet!

		init_args := WorkerInitArgs {
			id         = u32(i),
			dispatcher = ctx.self_handle,
		}
		payload, size := tina.init_args_of(&init_args)

		spec := tina.Spawn_Spec {
			type_id      = WORKER_ISOLATE_TYPE,
			group_id     = tina.ctx_supervision_group_id(ctx),
			restart_type = .permanent,
			args_payload = payload,
			args_size    = size,
		}
		_ = tina.ctx_spawn(ctx, spec)
	}

	// 2. Start the work loop (fires every 400ms)
	tina.ctx_register_timer(ctx, 400 * 1_000_000, TAG_DISPATCH_TICK)

	return tina.Effect_Receive{}
}

dispatcher_handler :: proc(
	self_raw: rawptr,
	message: ^tina.Message,
	ctx: ^tina.TinaContext,
) -> tina.Effect {
	using self := tina.self_as(DispatcherIsolate, self_raw, ctx)
	log_buf: [128]u8

	switch message.tag {
	case TAG_WORKER_READY:
		// A worker checked in! This happens at boot, AND after a worker recovers from a crash.
		msg := tina.payload_as(WorkerReadyMsg, message.user.payload[:])

		old_handle := workers[msg.id]
		workers[msg.id] = msg.handle

		if old_handle != tina.HANDLE_NONE && old_handle != msg.handle {
			str := fmt.bprintf(
				log_buf[:],
				"[RECOVER] Worker %d reborn. old=%X new=%X",
				msg.id,
				u64(old_handle),
				u64(msg.handle),
			)
			tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

			str2 := fmt.bprintf(
				ctx.scratch_arena.data,
				"[INSIGHT] Same role. New identity. Stale sends fail safely.",
			)
			tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str2)
		} else {
			str := fmt.bprintf(
				log_buf[:],
				"[RECOVER] Worker %d online. (Handle: %X)",
				msg.id,
				u64(msg.handle),
			)
			tina.ctx_log(ctx, .DEBUG, tina.USER_LOG_TAG_BASE, transmute([]u8)str)
		}
		return tina.Effect_Receive{}

	case TAG_JOB_DONE:
		msg := tina.payload_as(JobDoneMsg, message.user.payload[:])
		str := fmt.bprintf(
			log_buf[:],
			"Dispatcher: Acknowledged Job %d done by Worker %d.",
			msg.job_id,
			msg.worker_id,
		)
		tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)
		return tina.Effect_Receive{}

	case TAG_DISPATCH_TICK:
		for target_id in 0 ..< len(workers) {
			job_counter += 1
			target_handle := workers[target_id]
			if target_handle != tina.HANDLE_NONE {
				// Try to send the job
				job := JobMsg {
					job_id = job_counter,
				}
				res := tina.ctx_send(ctx, target_handle, TAG_JOB, &job)

				// The worker died, so this job gets dropped. No retry, no coordination needed.
				if res == .stale_handle {
					str := fmt.bprintf(
						log_buf[:],
						"[FAIL] Worker %d handle is stale! Dropping Job %d.",
						target_id,
						job_counter,
					)
					tina.ctx_log(ctx, .WARN, tina.USER_LOG_TAG_BASE, transmute([]u8)str)

					// Clear the stale handle so we don't try again until it checks in
					workers[target_id] = tina.HANDLE_NONE
				} else {
					str := fmt.bprintf(
						log_buf[:],
						"Dispatcher: Assigned Job %d to Worker %d.",
						job_counter,
						target_id,
					)
					tina.ctx_log(ctx, .INFO, tina.USER_LOG_TAG_BASE, transmute([]u8)str)
				}
			} else {
				str := fmt.bprintf(
					log_buf[:],
					"Dispatcher: Worker %d is offline. Job %d dropped.",
					target_id,
					job_counter,
				)
				tina.ctx_log(ctx, .WARN, tina.USER_LOG_TAG_BASE, transmute([]u8)str)
			}
		}

		// Re-arm the loop
		tina.ctx_register_timer(ctx, 300 * 1_000_000, TAG_DISPATCH_TICK)
		return tina.Effect_Receive{}

	case:
		return tina.Effect_Receive{}
	}
}

// ============================================================================
// System Boot Specification
// ============================================================================

main :: proc() {
	quarantine_policy := tina.Quarantine_Policy.Quarantine
	if DEMO_ABORT_ON_QUARANTINE do quarantine_policy = .Abort

	types := [2]tina.TypeDescriptor {
		{
			id = DISPATCHER_ISOLATE_TYPE,
			slot_count = 1,
			stride = size_of(DispatcherIsolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			init_fn = dispatcher_init,
			handler_fn = dispatcher_handler,
			mailbox_capacity = 64,
		},
		{
			id = WORKER_ISOLATE_TYPE,
			slot_count = 10,
			stride = size_of(WorkerIsolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			init_fn = worker_init,
			handler_fn = worker_handler,
			mailbox_capacity = 16,
		},
	}

	children := [1]tina.Child_Spec {
		tina.Static_Child_Spec{type_id = DISPATCHER_ISOLATE_TYPE, restart_type = .temporary},
	}

	root_group := tina.Group_Spec {
		strategy                = .One_For_One,
		restart_count_max       = DEMO_ROOT_RESTART_MAX,
		window_duration_ticks   = DEMO_ROOT_WINDOW_TICKS,
		children                = children[:],
		child_count_dynamic_max = 10,
	}

	shard_specs := [1]tina.ShardSpec{{shard_id = 0, root_group = root_group, target_core = -1}}

	spec := tina.SystemSpec {
		quarantine_policy = quarantine_policy,
		watchdog = tina.Watchdog_Config {
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
		fd_entry_size = size_of(tina.FD_Entry),
		supervision_groups_max = 4,
		reactor_buffer_slot_count = 16,
		reactor_buffer_slot_size = 4096,
		transfer_slot_count = 16,
		transfer_slot_size = 4096,
		shutdown_timeout_ms = 3_000,
	}

	fmt.println(
		"═══════════════════════════════════════════════════════════════",
	)
	fmt.println(" Tina Task Dispatcher — \"A Dead Worker Is Not a Dead System\"")
	fmt.println(
		"═══════════════════════════════════════════════════════════════",
	)
	fmt.println("")
	fmt.printfln("[WATCH] Every %dth job is cursed. A worker WILL crash.", DEMO_CRASH_EVERY)
	fmt.println("[QUESTION] Will the dispatcher panic, block, or keep assigning work?")
	fmt.println("[WATCH] Notice what changes after restart: the handle, not the role.")
	fmt.println("")
	fmt.printfln(
		"  crash_every=%d  restart_budget=%d  window_ticks=%d  pid=%d",
		DEMO_CRASH_EVERY,
		DEMO_ROOT_RESTART_MAX,
		DEMO_ROOT_WINDOW_TICKS,
		os.get_pid(),
	)
	when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		fmt.printfln("[RECOVER] To revive quarantined shards: kill -USR2 %d", os.get_pid())
	}
	fmt.println("")
	tina.tina_start(&spec)
}
