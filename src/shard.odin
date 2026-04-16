package tina

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"

DISPATCH_QUOTA_PER_WEIGHT :: 256 // Baseline message processing limit per tick, per priority weight

RECOVERY_TIER_3 :: 1
RECOVERY_WATCHDOG :: 2
RECOVERY_ROOT_ESCALATE :: 3
RECOVERY_SOFT_KILL :: 4

@(private = "package")
recovery_reason_label :: #force_inline proc "contextless" (reason: i32) -> string {
	@(static, rodata)
	labels := [5]string {
		"None",
		"Signal (SIGSEGV/BUS/FPE)",
		"Watchdog (SIGUSR1)",
		"Root Escalate",
		"Soft Kill",
	}
	if reason >= 0 && reason < i32(len(labels)) {
		return labels[reason]
	}
	return "Unknown"
}

@(thread_local)
g_current_shard_pointer: ^Shard

trigger_tier2_panic :: proc(shard: ^Shard) -> ! {
	os_trap_restore(&shard.trap_environment_inner, 1)
}

// --- Enums & Constants ---

Shard_State :: enum u8 {
	Init          = 0,
	Running       = 1,
	Quarantined   = 2,
	Shutting_Down = 3,
	Terminated    = 4,
}

Isolate_State :: enum u8 {
	Unallocated = 0,
	Runnable,
	Waiting,
	Waiting_For_Reply,
	Waiting_For_Io,
	Crashed,
}
Isolate_Flag :: enum u8 {
	Shutdown_Pending,
}
Isolate_Flags :: distinct bit_set[Isolate_Flag;u8]

// Mutually Exclusive Control Signals from Watchdog
Control_Signal :: enum u8 {
	None     = 0,
	Shutdown = 1,
	Kill     = 2,
}


// --- Core Data Structures ---

// Isolate metadata
Isolate_Metadata :: struct {
	io_peer_address:       Peer_Address,
	inbox_head:            u32,
	inbox_tail:            u32,
	pending_correlation:   u32,
	io_fd:                 FD_Handle,
	io_result:             i32,
	pending_transfer_read: Transfer_Handle,
	generation:            u32,
	working_arena_offset:  u32,
	inbox_count:           u16,
	group_id:              Supervision_Group_Id,
	io_completion_tag:     IO_Completion_Tag,
	io_buffer_index:       u16,
	state:                 Isolate_State,
	flags:                 Isolate_Flags, // Replaces shutdown_pending: u8
	io_sequence:           u8,
}

Shard_Counters :: struct {
	stale_delivery_drops:      u64,
	ring_full_drops:           u64,
	quarantine_drops:          u64,
	pool_exhaustion_drops:     u64,
	mailbox_full_drops:        u64,
	io_buffer_exhaustions:     u64,
	io_submission_exhaustions: u64,
	io_stale_completions:      u64, // TODO: In simulation, consider verifying that this counter
	// equals the number of timer-wakes + shutdown-wakes that
	// interrupted WAITING_FOR_IO Isolates. A mismatch would indicate
	// a stale completion was lost (buffer leak) or double-counted.
	// Might require tracking a separate "io_wakes" counter to compare against.
	transfer_exhaustions:      u64,
	transfer_stale_reads:      u64,
	handoff_exhaustions:       u64,
	handoff_timeouts:          u64,
	handoff_rejects:           u64,
}

Dynamic_Child_Spec :: struct {
	args_payload: [MAX_INIT_ARGS_SIZE]u8,
	type_id:      u8,
	restart_type: Restart_Type,
	args_size:    u8,
	_padding:     [5]u8,
}

Supervision_Group :: struct {
	children_handles:      []Handle,
	dynamic_specs:         []Dynamic_Child_Spec,
	boot_spec:             ^Group_Spec,
	window_start_tick:     u64,
	window_duration_ticks: u32,
	group_id:              Supervision_Group_Id,
	parent_id:             Supervision_Group_Id,
	child_count_static:    u16,
	child_count_dynamic:   u16,
	restart_count:         u16,
	restart_count_max:     u16,
	strategy:              Supervision_Strategy,
	_padding:              [3]u8,
}

when TINA_SIMULATION_MODE {
	Simulation_State :: struct {
		network:      ^SimulatedNetwork,
		fault_config: ^FaultConfig,
		crash_prng:   ^Prng,
	}
	Sim_State_Mixin :: struct {
		sim_state: Simulation_State,
	}
} else {
	Sim_State_Mixin :: struct {}
}

Shard :: struct {
	// --- Hot Pointers & Slices (8-byte aligned) ---
	outbound_rings:         []^SPSC_Ring,
	inbound_rings:          []^SPSC_Ring,
	type_descriptors:       []TypeDescriptor,
	isolate_free_heads:     []u32, // free list heads per Isolate Type
	dispatch_cursors:       []u32, // Resumption index for budgeted dispatch
	isolate_memory:         [][]u8,
	working_memory:         [][]u8, // Base slices for working memory
	scratch_memory:         []u8, // Base slice for scratch arena
	transfer_generations:   []u16,
	metadata:               []#soa[]Isolate_Metadata,
	supervision_groups:     []Supervision_Group,
	handoff_table:          FD_Handoff_Table,

	// --- Hot Embedded Structs (8-byte aligned) ---
	log_ring:               Log_Ring_Buffer,
	message_pool:           Message_Pool,
	transfer_pool:          Reactor_Buffer_Pool,
	counters:               Shard_Counters,

	// --- Hot Scalars (Ordered largest to smallest) ---
	current_tick:           u64, // The current time quantized to the resolution
	timer_resolution_ns:    u64, // E.g., 1_000_000 for 1ms ticks
	heartbeat_tick:         u64,
	next_correlation_id:    u32,
	current_msg_slot:       u32,
	current_slot_index:     u32,
	id:                     u8,
	current_type_id:        u16,
	peer_alive_mask:        Shard_Mask, // Tracks up to 256 peers. Bit N = 1 if Shard N is alive
	control_signal:         Control_Signal, // Atomic, mutually exclusive signals from watchdog
	_padding:               [5]u8,
	shared_state:           ^u8, // Points to external shared state (config or simulator backing)

	// --- Cold / Massive Storage ---
	timer_wheel:            Timer_Wheel,
	trap_environment_outer: OS_Trap_Environment,
	trap_environment_inner: OS_Trap_Environment,
	reactor:                Reactor,

	// Placed at the end to prevent possible cache-line shifting of hot fields.
	using _sim_mixin:       Sim_State_Mixin,
}

// --- Scheduler Loop ---

scheduler_tick :: proc(shard: ^Shard) {
	signal := cast(Control_Signal)sync.atomic_load_explicit(
		cast(^u8)&shard.control_signal,
		.Relaxed,
	)
	if signal != .None {
		switch signal {
		case .None: // Unreachable but satisfies switch exhaustion
		case .Shutdown:
			// Consume the signal, transition Shard state to Shutting_Down
			sync.atomic_store_explicit(
				cast(^u8)&shard.control_signal,
				u8(Control_Signal.None),
				.Relaxed,
			)
			sync.atomic_store_explicit(shard.shared_state, u8(Shard_State.Shutting_Down), .Release)

			// Phase 1 Notification: wake all parked isolates
			for type_desc in shard.type_descriptors {
				type_id := type_desc.id
				slot_count := u32(type_desc.slot_count)

				// Extract 1D slices to bypass 2D lookups
				states := shard.metadata[type_id].state[:]
				flags := shard.metadata[type_id].flags[:]
				io_sequences := shard.metadata[type_id].io_sequence[:]
				pending_correlations := shard.metadata[type_id].pending_correlation[:]

				for index in 0 ..< slot_count {
					if states[index] != .Unallocated {
						flags[index] += {.Shutdown_Pending}
					}
				}

				for index in 0 ..< slot_count {
					#partial switch states[index] {
					case .Waiting:
						states[index] = .Runnable
					case .Waiting_For_Io:
						// Invalidate pending completion via io_sequence bump.
						// No explicit backend_cancel — the stale completion will
						// arrive naturally, fail the io_sequence check in
						// reactor_collect_completions, and have its buffer freed
						// by the stale-path reclamation. See §6.6.3 §12 design note.
						io_sequences[index] += 1
						states[index] = .Runnable
					case .Waiting_For_Reply:
						// Discard stale replies
						pending_correlations[index] = 0
						states[index] = .Runnable
					}
				}
			}
		case .Kill:
			os_trap_restore(&shard.trap_environment_outer, RECOVERY_SOFT_KILL)
		}
	}

	when !TINA_SIMULATION_MODE {
		now_ns := os_monotonic_time_ns()
		// Quantize to timer wheel ticks.
		// If timer_resolution_ns is a power of 2, the compiler should be able to
		// turn this into a bit-shift.
		shard.current_tick = now_ns / shard.timer_resolution_ns
		// Watchdog heartbeat
		sync.atomic_store_explicit(&shard.heartbeat_tick, shard.current_tick, .Relaxed)
	}
	now := shard.current_tick

	// ========================================================================
	// Step 1: Drain inbound cross-shard rings → deliver to local mailboxes
	// ========================================================================
	transport_drain_inbound(shard, now)

	// ========================================================================
	// Step 2: Collect I/O completions
	// ========================================================================
	reactor_collect_completions(&shard.reactor, shard, 0)

	// ========================================================================
	// Step 3: Isolate Dispatch (Budget-limited by type)
	// ========================================================================
	for type_descriptor in shard.type_descriptors {
		type_id := type_descriptor.id
		slot_count := u32(type_descriptor.slot_count)

		// Extract 1D slices to bypass 2D lookups for the entire dispatch inner-loop
		states := shard.metadata[type_id].state[:]
		flags := shard.metadata[type_id].flags[:]
		inbox_counts := shard.metadata[type_id].inbox_count[:]
		io_completions := shard.metadata[type_id].io_completion_tag[:]
		generations := shard.metadata[type_id].generation[:]
		io_results := shard.metadata[type_id].io_result[:]
		io_fds := shard.metadata[type_id].io_fd[:]
		io_buffer_indices := shard.metadata[type_id].io_buffer_index[:]
		io_peer_addresses := shard.metadata[type_id].io_peer_address[:]
		working_arena_offsets := shard.metadata[type_id].working_arena_offset[:]
		pending_transfer_reads := shard.metadata[type_id].pending_transfer_read[:]

		// Determine dynamic budget for this type batch
		dispatch_budget := u32(type_descriptor.budget_weight) * DISPATCH_QUOTA_PER_WEIGHT
		dispatched_count: u32 = 0

		shard.current_type_id = u16(type_id)

		// Capture original cursor before trap to calculate distance if a crash occurs
		original_cursor := shard.dispatch_cursors[type_id]
		slots_to_check := slot_count

		if os_trap_save(&shard.trap_environment_inner) != 0 {
			when !TINA_SIMULATION_MODE {
				// Sweep orphaned temp allocations from panic string formatting.
				free_all(context.temp_allocator)
				// Unblock signals masked by the OS during handler execution.
				os_signals_restore_thread_mask()
			}

			if shard.current_msg_slot != POOL_NONE_INDEX {
				pool_free_unchecked(&shard.message_pool, shard.current_msg_slot)
				shard.current_msg_slot = POOL_NONE_INDEX
			}
			_teardown_isolate(shard, shard.current_type_id, shard.current_slot_index, .Crashed)

			// TRAP RECOVERY: Advance the cursor past the crashed isolate
			next_cursor := shard.current_slot_index + 1
			if next_cursor >= slot_count do next_cursor = 0
			shard.dispatch_cursors[type_id] = next_cursor

			// siglongjmp wipes the loop counter. We must calculate
			// how many slots was evaluated before the crash so it doesn't wrap around
			// and double-evaluate slots in the same tick.
			checked: u32 = 0
			if shard.current_slot_index >= original_cursor {
				checked = shard.current_slot_index - original_cursor
			} else {
				checked = shard.current_slot_index + u32(slot_count) - original_cursor
			}
			checked += 1 // Include the slot that just crashed

			if checked >= slot_count {
				slots_to_check = 0 // We checked the whole arena
			} else {
				slots_to_check = slot_count - checked
			}
		}

		cursor := shard.dispatch_cursors[type_id]

		// Loop runs 'slots_to_check' times, calculating physical slot with fast wrap-around
		slot_loop: for i in 0 ..< slots_to_check {
			slot := cursor + i
			if slot >= slot_count do slot -= slot_count

			state := states[slot]

			// FAST-PATH REJECT: If empty, skip immediately.
			if state == .Unallocated do continue

			// Use the extracted 1D slices
			has_work :=
				(state == .Runnable) ||
				(state == .Waiting && inbox_counts[slot] > 0) ||
				(io_completions[slot] != IO_TAG_NONE) ||
				(.Shutdown_Pending in flags[slot])

			if has_work {
				if dispatched_count >= dispatch_budget {
					// Budget exhausted: save the CURRENT slot to resume exactly here on the next tick
					shard.dispatch_cursors[type_id] = slot
					break slot_loop
				}
				dispatched_count += 1

				shard.current_slot_index = slot
				shard.current_msg_slot = POOL_NONE_INDEX

				message: Message
				message_pointer: ^Message = nil
				correlation: u32 = 0
				envelope_flags: Envelope_Flags = {}

				is_io_completion := false
				buffer_to_free: u16 = BUFFER_INDEX_NONE

				// Dispatch Priority: I/O > Shutdown > Inbox (ADR §6.13.4)
				if io_completions[slot] != IO_TAG_NONE {
					message.tag = io_completions[slot]
					message.io.result = io_results[slot]
					message.io.fd = io_fds[slot]
					message.io.buffer_index = io_buffer_indices[slot]
					message.io.peer_address = io_peer_addresses[slot]

					message_pointer = &message
					is_io_completion = true
					buffer_to_free = io_buffer_indices[slot]
				} else if .Shutdown_Pending in flags[slot] {
					message.tag = TAG_SHUTDOWN
					message.user.source = HANDLE_NONE
					message.user.payload_size = 0

					message_pointer = &message
					flags[slot] -= {.Shutdown_Pending}
				} else if inbox_counts[slot] > 0 {
					shard.current_msg_slot = _dequeue(
						shard,
						u16(type_id),
						slot,
						&message,
						&correlation,
						&envelope_flags,
					)
					if shard.current_msg_slot != POOL_NONE_INDEX {
						message_pointer = &message
					}
				}

				ctx_flags: Context_Flags
				if .Is_Call in envelope_flags do ctx_flags += {.Is_Call}

				ctx := TinaContext {
					_shard                 = shard,
					self_handle            = make_handle(
						shard.id,
						u16(type_id),
						slot,
						generations[slot],
					),
					current_message_source = message_pointer != nil && !is_io_completion && message.tag != TAG_SHUTDOWN ? message.user.source : HANDLE_NONE,
					current_correlation    = correlation,
					flags                  = ctx_flags,
				}

				// Initialize Context Arenas
				mem.arena_init(&ctx.scratch_arena, shard.scratch_memory)

				working_stride := type_descriptor.working_memory_size
				if working_stride > 0 {
					start_index := int(slot) * working_stride
					working_slice := shard.working_memory[type_id][start_index:start_index +
					working_stride]
					ctx.working_arena = mem.Arena {
						data   = working_slice,
						offset = int(working_arena_offsets[slot]),
					}
				}

				isolate_pointer := _get_isolate_ptr(shard, u16(type_id), slot)

				// Set up the implicit context for the user handler
				context.allocator = mem.arena_allocator(&ctx.scratch_arena)
				context.temp_allocator = mem.arena_allocator(&ctx.scratch_arena)

				when TINA_SIMULATION_MODE {
					if ratio_chance(
						shard.sim_state.fault_config.isolate_crash_rate,
						shard.sim_state.crash_prng,
					) {
						if shard.current_msg_slot != POOL_NONE_INDEX {
							pool_free_unchecked(&shard.message_pool, shard.current_msg_slot)
							shard.current_msg_slot = POOL_NONE_INDEX
						}
						_teardown_isolate(shard, u16(type_id), slot, .Crashed)
						continue slot_loop
					}
				}

				effect := type_descriptor.handler_fn(isolate_pointer, message_pointer, &ctx)

				// Write back working arena offset
				if working_stride > 0 {
					working_arena_offsets[slot] = u32(ctx.working_arena.offset)
				}

				if is_io_completion {
					io_completions[slot] = IO_TAG_NONE
					io_peer_addresses[slot] = {}
					if buffer_to_free != BUFFER_INDEX_NONE {
						reactor_buffer_pool_free(&shard.reactor.buffer_pool, buffer_to_free)
					}
				}

				// Transfer Buffer Auto-Free (§6.9 §8.3)
				if pending_transfer_reads[slot] != TRANSFER_HANDLE_NONE {
					t_handle := pending_transfer_reads[slot]
					_transfer_pool_free(shard, transfer_handle_index(t_handle))
					pending_transfer_reads[slot] = TRANSFER_HANDLE_NONE
				}

				if shard.current_msg_slot != POOL_NONE_INDEX {
					pool_free_unchecked(&shard.message_pool, shard.current_msg_slot)
					shard.current_msg_slot = POOL_NONE_INDEX
				}

				_interpret_effect(shard, u16(type_id), slot, effect, &ctx)
			}
		}

		// If we drained all work without exhausting the budget, reset the cursor
		if dispatched_count < dispatch_budget {
			shard.dispatch_cursors[type_id] = 0
		}
	}

	// ========================================================================
	// Step 4: Flush I/O submissions
	// ========================================================================
	reactor_flush_submissions(&shard.reactor, shard)
	_fd_handoff_timeout_scan(shard, now)

	// ========================================================================
	// Step 5: Flush outbound cross-shard rings
	// ========================================================================
	transport_flush_outbound(shard)

	// ========================================================================
	// Step 6 & 7: Advance timers and Flush logs
	// ========================================================================
	_advance_timers(shard)
	log_flush(shard)
}

// --- Effect Interpreter ---

@(rodata, private = "package")
CRASH_REASONS_INTERPRETED := [Crash_Reason]string {
	.None                 = "Voluntary crash reason: None",
	.Spawn_Failed         = "Voluntary crash reason: Spawn_Failed",
	.Unimplemented_Effect = "Voluntary crash reason: Unimplemented_Effect",
	.Init_Failed          = "Voluntary crash reason: Init_Failed",
}

_interpret_effect :: proc(
	shard: ^Shard,
	type_id: u16,
	slot: u32,
	effect: Effect,
	ctx: ^TinaContext,
) {
	soa_meta := shard.metadata[type_id]
	switch e in effect {
	case Effect_Done:
		_teardown_isolate(shard, type_id, slot, .Normal)
	case Effect_Yield:
		soa_meta[slot].state = .Runnable
	case Effect_Receive:
		soa_meta[slot].state = .Waiting
	case Effect_Crash:
		reason_str := CRASH_REASONS_INTERPRETED[e.reason]
		_shard_log(
			shard,
			ctx.self_handle,
			.ERROR,
			LOG_TAG_ISOLATE_CRASHED,
			transmute([]u8)reason_str,
		)
		_teardown_isolate(shard, type_id, slot, .Crashed)
	case Effect_Call:
		shard.next_correlation_id += 1
		if shard.next_correlation_id == 0 do shard.next_correlation_id = 1
		correlation_id := shard.next_correlation_id

		// Set state before fast-fail enqueue so the timeout message is accepted
		soa_meta[slot].pending_correlation = correlation_id
		soa_meta[slot].state = .Waiting_For_Reply

		// Quarantine Fast-Fail Check (§6.4.5.4 Step 4b)
		destination_shard := extract_shard_id(e.to)
		if destination_shard != shard.id &&
		   !shard_mask_contains(&shard.peer_alive_mask, destination_shard) {
			// Target is dead. Abort .call setup and fast-fail with an immediate timeout.
			timeout_env: Message_Envelope
			timeout_env.source = HANDLE_NONE
			timeout_env.destination = ctx.self_handle
			timeout_env.tag = TAG_CALL_TIMEOUT
			timeout_env.correlation = correlation_id

			_enqueue_system_msg(shard, ctx.self_handle, &timeout_env)
			shard.counters.quarantine_drops += 1
			return
		}

		timeout_ticks := (e.timeout + shard.timer_resolution_ns - 1) / shard.timer_resolution_ns
		_register_system_timer(
			shard,
			ctx.self_handle,
			timeout_ticks,
			TAG_CALL_TIMEOUT,
			correlation_id,
		)

		local_msg := e.message // Make "e.message" it addressable
		envelope: Message_Envelope
		envelope.source = ctx.self_handle
		envelope.destination = e.to
		envelope.correlation = correlation_id
		envelope.flags += {.Is_Call}
		envelope.tag = local_msg.tag
		envelope.payload_size = local_msg.user.payload_size
		copy(envelope.payload[:], local_msg.user.payload[:])

		_route_envelope_user(shard, e.to, &envelope)

	case Effect_Reply:
		if .Is_Call not_in ctx.flags {
			// if !(.Is_Call in ctx.flags) {
			_shard_log(
				shard,
				ctx.self_handle,
				.ERROR,
				LOG_TAG_ISOLATE_CRASHED,
				transmute([]u8)string("Reply effect without call context"),
			)
			_teardown_isolate(shard, type_id, slot, .Crashed)
			return
		}
		soa_meta[slot].state = .Waiting

		local_msg := e.message // Make "e.message" it addressable
		envelope: Message_Envelope
		envelope.source = ctx.self_handle
		envelope.destination = ctx.current_message_source
		envelope.correlation = ctx.current_correlation
		envelope.flags += {.Is_Reply}
		envelope.tag = local_msg.tag
		envelope.payload_size = local_msg.user.payload_size
		copy(envelope.payload[:], local_msg.user.payload[:])

		_route_envelope_user(shard, ctx.current_message_source, &envelope)

	case Effect_Io:
		err := reactor_submit_io(&shard.reactor, shard, ctx.self_handle, e.operation)
		if err != IO_ERR_NONE {
			if err == IO_ERR_RESOURCE_EXHAUSTED do shard.counters.io_buffer_exhaustions += 1
			soa_meta[slot].io_completion_tag = _io_op_to_completion_tag(e.operation)
			soa_meta[slot].io_result = i32(err)
			soa_meta[slot].io_buffer_index = BUFFER_INDEX_NONE
			soa_meta[slot].state = .Runnable
		} else {
			soa_meta[slot].state = .Waiting_For_Io
		}
	}
}

// --- Message Routing ---

@(private = "package")
_route_envelope_user :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, true)
}

@(private = "package")
_route_envelope_system :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, false)
}

@(private = "file")
_route_envelope_internal :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
	is_user: bool,
) -> Send_Result {
	destination := extract_shard_id(to)

	if destination == shard.id {
		return _enqueue_internal(shard, to, envelope, is_user)
	} else {
		return transport_route_envelope(shard, destination, envelope)
	}
}

@(private = "package")
_enqueue_user_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, true)
}

@(private = "package")
_enqueue_system_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, false)
}

// Hot path: must remain contextless (no assert/fmt/make/default-allocator calls).
// Index validity is structurally guaranteed by pool alloc/free lifecycle.
@(private = "file")
_enqueue_internal :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
	is_user: bool,
) -> Send_Result {
	type_id := extract_type_id(to)
	slot := extract_slot(to)
	soa_meta := shard.metadata[type_id]

	if soa_meta[slot].generation != extract_generation(to) {
		shard.counters.stale_delivery_drops += 1
		return .stale_handle
	}

	is_reply := .Is_Reply in envelope.flags
	is_timeout := envelope.tag == TAG_CALL_TIMEOUT

	// Validation Only (No Mutation Yet)
	if is_reply || is_timeout {
		if soa_meta[slot].state != .Waiting_For_Reply ||
		   soa_meta[slot].pending_correlation != envelope.correlation {
			shard.counters.stale_delivery_drops += 1
			return .stale_handle
		}
	} else if is_user {
		// Capacity Check ONLY for normal user messages
		// Replies and timeouts bypass mailbox limits to prevent deadlocks
		if soa_meta[slot].inbox_count >= shard.type_descriptors[type_id].mailbox_capacity {
			shard.counters.mailbox_full_drops += 1
			return .mailbox_full
		}
	}

	// Pool Allocation
	pool_index: u32
	err: Pool_Error
	// Because `is_user` is passed as a constant from the wrapper,
	// I expect the compiler will dead-code-eliminate this IF statement.
	if is_user {
		pool_index, err = pool_alloc_user(&shard.message_pool)
	} else {
		pool_index, err = pool_alloc_system(&shard.message_pool)
	}

	if err != .None {
		shard.counters.pool_exhaustion_drops += 1
		return .pool_exhausted
	}

	// Safe State Mutation (We are guaranteed to enqueue now)
	if is_reply || is_timeout {
		soa_meta[slot].pending_correlation = 0
		soa_meta[slot].state = .Runnable
	}

	// Link into Mailbox
	envelope_destination := cast(^Message_Envelope)pool_get_ptr_unchecked(
		&shard.message_pool,
		pool_index,
	)
	envelope_destination^ = envelope^
	envelope_destination.next_in_mailbox = POOL_NONE_INDEX

	if soa_meta[slot].inbox_head == POOL_NONE_INDEX {
		soa_meta[slot].inbox_head = pool_index
	} else {
		tail_envelope := cast(^Message_Envelope)pool_get_ptr_unchecked(
			&shard.message_pool,
			soa_meta[slot].inbox_tail,
		)
		tail_envelope.next_in_mailbox = pool_index
	}

	soa_meta[slot].inbox_tail = pool_index
	soa_meta[slot].inbox_count += 1

	if soa_meta[slot].state == .Waiting {soa_meta[slot].state = .Runnable}
	return .ok
}

@(private = "package")
_dequeue :: proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot: u32,
	out_message: ^Message,
	out_correlation: ^u32,
	out_flags: ^Envelope_Flags,
) -> u32 {
	soa_meta := shard.metadata[type_id]
	head_index := soa_meta[slot].inbox_head
	if head_index == POOL_NONE_INDEX {return POOL_NONE_INDEX}

	envelope := cast(^Message_Envelope)pool_get_ptr_unchecked(&shard.message_pool, head_index)

	out_message.tag = envelope.tag
	out_message.user.source = envelope.source
	out_message.user.payload_size = envelope.payload_size
	copy(out_message.user.payload[:], envelope.payload[:])

	out_correlation^ = envelope.correlation
	out_flags^ = envelope.flags

	next_index := envelope.next_in_mailbox
	soa_meta[slot].inbox_head = next_index
	if next_index == POOL_NONE_INDEX {soa_meta[slot].inbox_tail = POOL_NONE_INDEX}
	soa_meta[slot].inbox_count -= 1

	return head_index
}

@(private = "package")
_fd_handoff_close_entry :: proc "contextless" (shard: ^Shard, ref: FD_Handoff_Ref) -> bool {
	entry, ok := fd_handoff_table_lookup(&shard.handoff_table, ref)
	if !ok {
		return false
	}

	cleanup_fd := entry.cleanup_fd
	_ = fd_handoff_table_free(&shard.handoff_table, ref)

	if cleanup_fd != OS_FD_INVALID {
		_ = backend_control_close(&shard.reactor.backend, cleanup_fd)
	}
	return true
}

@(private = "file")
_fd_handoff_send_ack :: proc "contextless" (
	shard: ^Shard,
	destination: Handle,
	source: Handle,
	ref: FD_Handoff_Ref,
) {
	env: Message_Envelope
	env.source = source
	env.destination = destination
	env.tag = TAG_FD_HANDOFF_ACK
	env.payload_size = u16(size_of(FD_Handoff_Ack))
	(cast(^FD_Handoff_Ack)&env.payload[0])^ = FD_Handoff_Ack {handoff = ref}
	_ = _route_envelope_system(shard, destination, &env)
}

@(private = "file")
_fd_handoff_send_reject :: proc "contextless" (
	shard: ^Shard,
	destination: Handle,
	source: Handle,
	ref: FD_Handoff_Ref,
	reason: FD_Handoff_Reject_Reason,
) {
	env: Message_Envelope
	env.source = source
	env.destination = destination
	env.tag = TAG_FD_HANDOFF_REJECT
	env.payload_size = u16(size_of(FD_Handoff_Reject))
	(cast(^FD_Handoff_Reject)&env.payload[0])^ = FD_Handoff_Reject {
		handoff = ref,
		reason = reason,
	}
	_ = _route_envelope_system(shard, destination, &env)
}

@(private = "file")
_inject_fd_handoff_accept :: proc "contextless" (
	shard: ^Shard,
	target: Handle,
	fd: FD_Handle,
	peer_address: Peer_Address,
) -> FD_Handoff_Reject_Reason {
	type_id := extract_type_id(target)
	if int(type_id) >= len(shard.metadata) {
		return .Invalid_Target
	}

	soa_meta := shard.metadata[type_id]
	slot := extract_slot(target)
	if int(slot) >= len(soa_meta) {
		return .Invalid_Target
	}
	if soa_meta[slot].generation != extract_generation(target) {
		return .Invalid_Target
	}
	if soa_meta[slot].state == .Unallocated || soa_meta[slot].state == .Crashed {
		return .Invalid_Target
	}
	if soa_meta[slot].state == .Waiting_For_Io || soa_meta[slot].io_completion_tag != IO_TAG_NONE {
		return .Target_Busy
	}

	soa_meta[slot].io_completion_tag = IO_TAG_ACCEPT_COMPLETE
	soa_meta[slot].io_result = 0
	soa_meta[slot].io_fd = fd
	soa_meta[slot].io_buffer_index = BUFFER_INDEX_NONE
	soa_meta[slot].io_peer_address = peer_address
	return .None
}

@(private = "file")
_process_fd_handoff_offer :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Offer)) {
		return
	}

	offer := (cast(^FD_Handoff_Offer)&envelope.payload[0])^
	adopted_fd, adopt_reason := reactor_adopt_fd_handoff(
		&shard.reactor,
		envelope.destination,
		offer.os_fd,
		offer.peer_address,
	)
	if adopt_reason != .None {
		_fd_handoff_send_reject(shard, envelope.source, envelope.destination, offer.handoff, adopt_reason)
		return
	}

	inject_reason := _inject_fd_handoff_accept(
		shard,
		envelope.destination,
		adopted_fd,
		offer.peer_address,
	)
	if inject_reason != .None {
		reactor_internal_close_fd(&shard.reactor, adopted_fd)
		_fd_handoff_send_reject(shard, envelope.source, envelope.destination, offer.handoff, inject_reason)
		return
	}

	_fd_handoff_send_ack(shard, envelope.source, envelope.destination, offer.handoff)
}

@(private = "file")
_process_fd_handoff_ack :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Ack)) {
		return
	}
	ack := (cast(^FD_Handoff_Ack)&envelope.payload[0])^
	_ = _fd_handoff_close_entry(shard, ack.handoff)
}

@(private = "file")
_process_fd_handoff_reject :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Reject)) {
		return
	}
	reject := (cast(^FD_Handoff_Reject)&envelope.payload[0])^
	if _fd_handoff_close_entry(shard, reject.handoff) {
		shard.counters.handoff_rejects += 1
	}
}

@(private = "file")
_fd_handoff_timeout_scan :: proc(shard: ^Shard, now: u64) {
	for handoff_index in 0 ..< int(shard.handoff_table.entry_count) {
		entry := &shard.handoff_table.entries[handoff_index]
		if entry.state != .In_Flight || entry.deadline_tick == 0 || now < entry.deadline_tick {
			continue
		}

		shard.counters.handoff_timeouts += 1
		entry.deadline_tick = 0
	}
}

// --- Mass Teardown & Recovery ---

@(private = "package")
shard_mass_teardown :: proc(shard: ^Shard) {
	log_flush(shard)

	// 1. Reset Pools (Message & Transfer)
	shard.message_pool.free_count = shard.message_pool.slot_count
	shard.message_pool.free_head = POOL_NONE_INDEX
	for i := int(shard.message_pool.slot_count) - 1; i >= 0; i -= 1 {
		slot_pointer := pool_get_ptr(&shard.message_pool, u32(i))
		(cast(^u32)slot_pointer)^ = shard.message_pool.free_head
		shard.message_pool.free_head = u32(i)
	}

	shard.transfer_pool.free_count = shard.transfer_pool.slot_count
	shard.transfer_pool.free_head = BUFFER_INDEX_NONE
	for i := int(shard.transfer_pool.slot_count) - 1; i >= 0; i -= 1 {
		slot_pointer := reactor_buffer_pool_slot_ptr(&shard.transfer_pool, u16(i))
		(cast(^u16)slot_pointer)^ = shard.transfer_pool.free_head
		shard.transfer_pool.free_head = u16(i)
		shard.transfer_generations[i] += 1
		if shard.transfer_generations[i] == 0 do shard.transfer_generations[i] = 1
	}

	// Sweep unsubmitted I/O buffers from the reactor's pending queue.
	// If a Level 2 fault interrupted the thread during Step 3 (Dispatch),
	// these buffers were allocated but never reached the OS kernel.
	for i in 0 ..< shard.reactor.pending_count {
		sub := &shard.reactor.pending_submissions[i]
		buffer_index := submission_token_buffer_index(sub.token)
		if buffer_index != BUFFER_INDEX_NONE {
			reactor_buffer_pool_free(&shard.reactor.buffer_pool, buffer_index)
		}
	}
	shard.reactor.pending_count = 0

	for i in 0 ..< shard.reactor.fd_table.slot_count {
		entry := &shard.reactor.fd_table.entries[i]

		if entry.read_owner != HANDLE_NONE || entry.write_owner != HANDLE_NONE {
			backend_control_close(&shard.reactor.backend, entry.os_fd)
			fd_handle := fd_handle_make(u16(i), entry.generation)
			fd_table_free(&shard.reactor.fd_table, fd_handle)
		}
	}
	for handoff_index in 0 ..< int(shard.handoff_table.entry_count) {
		entry := &shard.handoff_table.entries[handoff_index]
		if entry.state != .In_Flight {
			continue
		}
		if entry.cleanup_fd != OS_FD_INVALID {
			_ = backend_control_close(&shard.reactor.backend, entry.cleanup_fd)
		}
	}
	fd_handoff_table_init(&shard.handoff_table, shard.handoff_table.entries)
	for type_desc in shard.type_descriptors {
		type_id := type_desc.id
		soa_meta := shard.metadata[type_id]

		// Reset the free head for this type
		shard.isolate_free_heads[type_id] = POOL_NONE_INDEX
		shard.dispatch_cursors[type_id] = 0

		for slot := int(type_desc.slot_count) - 1; slot >= 0; slot -= 1 {
			// SWEEP: Reclaim completed but undispatched I/O buffers before wiping metadata
			if soa_meta[slot].io_completion_tag != IO_TAG_NONE {
				if soa_meta[slot].io_buffer_index != BUFFER_INDEX_NONE {
					reactor_buffer_pool_free(
						&shard.reactor.buffer_pool,
						soa_meta[slot].io_buffer_index,
					)
				}
			}

			new_generation := (soa_meta[slot].generation + 1) & 0x0FFFFFFF
			if new_generation == 0 do new_generation = 1

			soa_meta[slot].generation = new_generation
			soa_meta[slot].state = .Unallocated
			soa_meta[slot].inbox_count = 0
			soa_meta[slot].inbox_tail = POOL_NONE_INDEX
			soa_meta[slot].pending_correlation = 0
			soa_meta[slot].pending_transfer_read = TRANSFER_HANDLE_NONE
			soa_meta[slot].io_completion_tag = IO_TAG_NONE
			soa_meta[slot].working_arena_offset = 0
			soa_meta[slot].flags = {}

			// Re-link the intrusive free list!
			soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = u32(slot)
		}
	}

	timer_wheel_reset(&shard.timer_wheel, shard.current_tick)

	shard.next_correlation_id = 0
	// Control Signal reset
	sync.atomic_store_explicit(cast(^u8)&shard.control_signal, u8(Control_Signal.None), .Relaxed)

	// Step 6: Notify peers via SHARD_RESTARTED
	env: Message_Envelope
	env.source = HANDLE_NONE
	env.destination = HANDLE_NONE
	env.tag = TAG_SHARD_RESTARTED
	transport_broadcast_envelope(shard, &env)
}

// Checks if any Isolates are still alive across all types on this Shard.
@(private)
shard_has_live_isolates :: proc(shard: ^Shard) -> bool {
	for type_desc in shard.type_descriptors {
		states := shard.metadata[type_desc.id].state[:]
		for i in 0 ..< type_desc.slot_count {
			if states[i] != .Unallocated {
				return true
			}
		}
	}
	return false
}

@(private = "package")
_process_inbound_envelope :: #force_inline proc "contextless" (
	shard: ^Shard,
	source_shard: u8,
	envelope: ^Message_Envelope,
) {
	// System Broadcast Intercept
	if envelope.destination == HANDLE_NONE {
		if envelope.tag == TAG_SHARD_RESTARTED {
			// Peer recovered, un-quarantine it
			shard_mask_include(&shard.peer_alive_mask, source_shard)
			// NOTE (§7.5.4): We could optionally perform an O(N) scan of
			// all local Isolates here to "fast-fail" any pending .call requests to this
			// restarted shard (since we know they are now stale). For now, we rely on
			// the Timer Wheel timeouts to naturally wake and fail the callers.
		} else if envelope.tag == TAG_SHARD_QUARANTINED {
			// Peer died, quarantine it
			shard_mask_exclude(&shard.peer_alive_mask, source_shard)
			// NOTE: Same concern as above if-block. Pending calls will naturally time out.
		}
		return
	}

	switch envelope.tag {
	case TAG_FD_HANDOFF_OFFER:
		_process_fd_handoff_offer(shard, envelope)
	case TAG_FD_HANDOFF_ACK:
		_process_fd_handoff_ack(shard, envelope)
	case TAG_FD_HANDOFF_REJECT:
		_process_fd_handoff_reject(shard, envelope)
	case:
		_ = _enqueue_user_msg(shard, envelope.destination, envelope)
	}
}

@(private = "file")
_init_handoff_test_shard :: proc(
	t: ^testing.T,
	shard: ^Shard,
	handoff_backing: []FD_Handoff_Entry,
) {
	shard.id = 0
	fd_handoff_table_init(&shard.handoff_table, handoff_backing)
	backend_config := Backend_Config {
		queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
		sim_config = Simulation_IO_Config {},
	}
	err := backend_init(&shard.reactor.backend, backend_config)
	testing.expect_value(t, err, Backend_Error.None)
}

@(private = "file")
_alloc_handoff_test_entry :: proc(
	t: ^testing.T,
	shard: ^Shard,
	target_handle: Handle,
	deadline_tick: u64,
) -> FD_Handoff_Ref {
	cleanup_fd, sock_err := backend_control_socket(&shard.reactor.backend, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_err, Backend_Error.None)

	ref, ok := fd_handoff_table_alloc(
		&shard.handoff_table,
		target_handle,
		cleanup_fd,
		Peer_Address{},
		deadline_tick,
		shard.id,
	)
	testing.expect(t, ok, "handoff entry should allocate")
	return ref
}

@(test)
test_fd_handoff_timeout_scan_counts_but_keeps_entry :: proc(t: ^testing.T) {
	shard: Shard
	handoff_backing: [2]FD_Handoff_Entry
	_init_handoff_test_shard(t, &shard, handoff_backing[:])
	defer backend_deinit(&shard.reactor.backend)

	target_handle := make_handle(1, 1, 0, 1)
	ref := _alloc_handoff_test_entry(t, &shard, target_handle, 5)

	_fd_handoff_timeout_scan(&shard, 6)

	entry, found := fd_handoff_table_lookup(&shard.handoff_table, ref)
	testing.expect(t, found, "timed out entry must remain in-flight (FDs still live)")
	testing.expect_value(t, entry.deadline_tick, u64(0))
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(1))

	_fd_handoff_timeout_scan(&shard, 100)
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(1))
}

@(test)
test_shard_mass_teardown_reclaims_in_flight_handoff_entries :: proc(t: ^testing.T) {
	shard: Shard
	handoff_backing: [2]FD_Handoff_Entry
	_init_handoff_test_shard(t, &shard, handoff_backing[:])
	defer backend_deinit(&shard.reactor.backend)

	target_handle := make_handle(1, 1, 0, 1)
	ref := _alloc_handoff_test_entry(t, &shard, target_handle, 100)

	shard_mass_teardown(&shard)

	_, found := fd_handoff_table_lookup(&shard.handoff_table, ref)
	testing.expect(t, !found, "mass teardown should reclaim in-flight handoff entries")
	testing.expect_value(t, shard.handoff_table.free_count, shard.handoff_table.entry_count)
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(0))
}
