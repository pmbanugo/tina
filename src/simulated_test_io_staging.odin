package tina

import "core:fmt"
import "core:mem"
import "core:testing"

// =============================================================================
// Staging slot lifecycle (ADR IO_SUBSYSTEM_ZERO_COPY_EVOLUTION §5.5)
//
// The claim-based staging API lets an Isolate write directly into a pool slot
// that the kernel will read from. The framework must guarantee that the slot
// is freed on EVERY exit path through the handler lifecycle — successful
// commit, abandoned claim, handler crash, simulated fault, mass teardown.
//
// These tests exercise the structural fix for the three correctness bugs
// found during the Phase-4 review:
//   1. Staging slot double-free after successful Wait_Io (auto-free unconditionally).
//   2. Staging slot leak on Isolate crash (no metadata record of the claim).
//   3. Mass teardown double-freeing in-flight pool slots (ADR §5.3 rename
//      regression — tag is now set at submission time, not completion time).
//
// The Pool_Integrity checker (extended to cover staging_pool) catches Bug 1
// because the double-free inflates staging_pool.free_count beyond slot_count.
// =============================================================================

when TINA_SIMULATION_MODE {

	// Each test uses a single IsolateTypeDescriptor, so the type id is
	// always 0 to match the dense descriptor index required by hydrate_shard.
	STAGING_TYPE_ID: Isolate_Type_Id : 0

	StagingStager :: struct {
		fd:    FD_Handle,
		fired: bool,
	}

	StagingCrash :: struct {
		fired: bool,
	}

	StagingNoop :: struct {}

	// Simulation-only diagnostic field IDs for staging observation.
	STAGING_DIAG_FIRED:        Diagnostic_Field_Id : 0
	STAGING_DIAG_SEND_RESULT:  Diagnostic_Field_Id : 1
	STAGING_DIAG_RESULT_CHECK: Diagnostic_Field_Id : 2

	// ----------------------------------------------------------------------------
	// Test 1: Claim → send-staged → Wait_Io → completion → slot freed exactly once
	//
	// Catches Bug 1: the post-commit auto-free at shard.odin:1281 used to fire
	// unconditionally. With the fix, the success branch of _commit_staged_io
	// clears turn_frame.staging_slot_index so the auto-free is a no-op, and the
	// slot is freed exactly once on I/O completion.
	// ----------------------------------------------------------------------------

	staging_stager_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		s := cast(^StagingStager)self

		fd, error := ctx_socket(.AF_INET, .STREAM, .TCP)
		if error != .None do return transition_to_crash(.Init_Failed)
		s.fd = fd

		stage := ctx_claim_send_slot()
		if stage == nil do return transition_to_crash(.Contract_Violation)

		// Write a few bytes of payload. The simulated backend ignores the bytes
		// (no actual data transfer) but the staging slot must be populated for
		// the submission to be well-formed.
		stage[0] = 0xDE
		stage[1] = 0xAD
		stage[2] = 0xBE
		stage[3] = 0xEF

		submit := ctx_io_send_staged(s.fd, 4)
		if submit != .ok do return transition_to_crash(.Contract_Violation)

		return ISOLATE_TRANSITION_WAIT_IO
	}

	staging_stager_handler :: proc(
		self: rawptr,
		message: ^Message,
	) -> Isolate_Transition {
		s := cast(^StagingStager)self
		if message != nil && message.tag == IO_TAG_SEND_COMPLETE {
			s.fired = true
			ctx_test_diagnostic_write_u64(STAGING_DIAG_FIRED, 1)
			return ISOLATE_TRANSITION_DONE
		}
		return ISOLATE_TRANSITION_DONE
	}

	@(test)
	test_staging_slot_commit_frees_slot_exactly_once :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = STAGING_TYPE_ID,
				slot_count = 1,
				stride = size_of(StagingStager),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = staging_stager_init,
				handler_fn = staging_stager_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}
		children := [1]Child_Spec {
			Static_Child_Spec{type_id = STAGING_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 200,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 1,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			{
				staging_slot_count = 2,
				staging_slot_size  = 1024,
			},
		)

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		sim.shards[0].reactor.backend.config.delay_range_ticks = {1, 2}
		simulator_run(&sim)

		shard := &sim.shards[0]
		shard_test_diagnostic_expect_u64(t, shard, STAGING_TYPE_ID, 0, STAGING_DIAG_FIRED, 1)

		stage_pool := &shard.reactor.staging_pool
		testing.expect_value(t, stage_pool.free_count, stage_pool.slot_count)
		testing.expect_value(t, shard.reactor.io_in_flight_count, u32(0))

		fmt.printfln(
			"\n[TEST SUCCESS] Staging commit frees slot exactly once. Staging pool: %d/%d free.",
			stage_pool.free_count,
			stage_pool.slot_count,
		)
	}

	// ----------------------------------------------------------------------------
	// Test 2: Claim → handler returns Wait_Message (no commit) → slot auto-freed
	//
	// The Isolate claims a slot, fills it with some bytes, but then changes
	// its mind and waits for an inbox message. The framework must auto-free
	// the claim on the Wait_Message exit path.
	// ----------------------------------------------------------------------------

	staging_noop_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		stage := ctx_claim_send_slot()
		if stage == nil do return transition_to_crash(.Contract_Violation)
		stage[0] = 0xAA
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	staging_noop_handler :: proc(
		self: rawptr,
		message: ^Message,
	) -> Isolate_Transition {
		return ISOLATE_TRANSITION_DONE
	}

	@(test)
	test_staging_slot_claim_then_wait_message_auto_frees :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = STAGING_TYPE_ID,
				slot_count = 1,
				stride = size_of(StagingNoop),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = staging_noop_init,
				handler_fn = staging_noop_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}
		children := [1]Child_Spec {
			Static_Child_Spec{type_id = STAGING_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 50,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 1,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			{
				staging_slot_count = 2,
				staging_slot_size  = 1024,
			},
		)

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		simulator_run(&sim)

		shard := &sim.shards[0]
		stage_pool := &shard.reactor.staging_pool
		testing.expect_value(t, stage_pool.free_count, stage_pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] Uncommitted claim auto-freed on Wait_Message. Staging pool: %d/%d free.",
			stage_pool.free_count,
			stage_pool.slot_count,
		)
	}

	// ----------------------------------------------------------------------------
	// Test 3: Claim → handler crashes → slot reclaimed by teardown
	//
	// Catches Bug 2: the Isolate claims a slot then crashes before any commit.
	// _teardown_isolate must reclaim the slot from the metadata mirror
	// (staging_slot_index) so the staging pool stays whole.
	//
	// Uses a handler crash (not init crash) because the simulator's init crash
	// path escalates through os_trap_restore which is not set up under
	// simulator_init. The handler crash goes through _interpret_transition
	// → _teardown_isolate → _on_child_exit, which is the path we need to
	// exercise.
	// ----------------------------------------------------------------------------

	staging_crash_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		s := cast(^StagingCrash)self
		stage := ctx_claim_send_slot()
		if stage == nil do return transition_to_crash(.Contract_Violation)
		stage[0] = 0xCC
		// Mark the claim so the handler can crash and exercise the teardown path.
		s.fired = true
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	staging_crash_handler :: proc(
		self: rawptr,
		message: ^Message,
	) -> Isolate_Transition {
		// Crash on first message — staging_slot_index in the turn frame still
		// holds the claim from init, so teardown must reclaim it.
		return transition_to_crash(.Contract_Violation)
	}

	@(test)
	test_staging_slot_claim_then_crash_reclaimed_by_teardown :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = STAGING_TYPE_ID,
				slot_count = 1,
				stride = size_of(StagingCrash),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = staging_crash_init,
				handler_fn = staging_crash_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}
		// Temporary restart with a one_for_all/one_for_one crash cycle. We
		// don't care about restart policy here — we just need the crash to
		// reach _teardown_isolate, which is exercised on the first crash.
		children := [1]Child_Spec {
			Static_Child_Spec{type_id = STAGING_TYPE_ID, restart_type = .transient},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 200,
			terminate_on_quiescent = false,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 1,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			{
				staging_slot_count = 2,
				staging_slot_size  = 1024,
			},
		)

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		simulator_run(&sim)

		shard := &sim.shards[0]
		stage_pool := &shard.reactor.staging_pool
		testing.expect_value(t, stage_pool.free_count, stage_pool.slot_count)

		fmt.printfln(
			"\n[TEST SUCCESS] Teardown reclaims staging slot on crash. Staging pool: %d/%d free.",
			stage_pool.free_count,
			stage_pool.slot_count,
		)
	}

	// ----------------------------------------------------------------------------
	// Test 4: Claim → ctx_io_send (struct source) → returns .already_staged
	//
	// Catches Gap 6: the struct-source helpers (ctx_io_send / ctx_io_write /
	// ctx_io_sendto) used to silently drop a prior staging claim. The fix
	// returns .already_staged so the handler cannot leak the slot into a
	// different I/O.
	// ----------------------------------------------------------------------------

	StagingAlreadyStaged :: struct {
		fd:           FD_Handle,
		send_result:  Io_Submit_Result,
		result_check: bool,
	}

	staging_already_staged_init :: proc(
		self: rawptr,
		args: []u8,
	) -> Isolate_Transition {
		s := cast(^StagingAlreadyStaged)self

		// Open a socket so ctx_io_send has a valid FD to stage against.
		fd, error := ctx_socket(.AF_INET, .STREAM, .TCP)
		if error != .None do return transition_to_crash(.Init_Failed)
		s.fd = fd
		_ = ctx_send_raw(ctx_self_handle(), USER_MESSAGE_TAG_BASE, nil)
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	staging_already_staged_handler :: proc(
		self: rawptr,
		message: ^Message,
	) -> Isolate_Transition {
		s := cast(^StagingAlreadyStaged)self

		// Claim a staging slot (writes to the turn frame).
		stage := ctx_claim_send_slot()
		if stage == nil do return transition_to_crash(.Contract_Violation)
		stage[0] = 0x55

		// Now try to send from struct — must return .already_staged because
		// a previous claim has not been committed. The struct needs a known
		// type so ctx_io_send can resolve its polymorphic ^$Isolate parameter.
		noop := struct {
			_payload: [1]u8,
		}{_payload = {0x33}}
		s.send_result = ctx_io_send(&noop, s.fd, noop._payload[:])
		s.result_check = true
		ctx_test_diagnostic_write_u64(STAGING_DIAG_SEND_RESULT, u64(s.send_result))
		ctx_test_diagnostic_write_u64(STAGING_DIAG_RESULT_CHECK, s.result_check ? 1 : 0)

		// The rejected struct-source send must leave the existing staging claim
		// under normal turn cleanup. Crash-path reclamation is covered separately
		// by test_staging_slot_claim_then_crash_reclaims.
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_staging_slot_already_staged_rejected :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = STAGING_TYPE_ID,
				slot_count = 1,
				stride = size_of(StagingAlreadyStaged),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = staging_already_staged_init,
				handler_fn = staging_already_staged_handler,
				mailbox_capacity = 16,
				budget_weight = 1,
			},
		}
		children := [1]Child_Spec {
			Static_Child_Spec{type_id = STAGING_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 50,
			terminate_on_quiescent = true,
			builtin_checkers       = CHECKER_FLAGS_ALL,
			checker_interval_ticks = 1,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			{
				staging_slot_count = 2,
				staging_slot_size  = 1024,
			},
		)

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		simulator_run(&sim)

		shard := &sim.shards[0]
		shard_test_diagnostic_expect_u64(t, shard, STAGING_TYPE_ID, 0, STAGING_DIAG_RESULT_CHECK, 1)
		shard_test_diagnostic_expect_u64(
			t,
			shard,
			STAGING_TYPE_ID,
			0,
			STAGING_DIAG_SEND_RESULT,
			u64(Io_Submit_Result.already_staged),
		)

		stage_pool := &shard.reactor.staging_pool
		testing.expect_value(t, stage_pool.free_count, stage_pool.slot_count)
		testing.expect_value(t, shard.metadata[STAGING_TYPE_ID]._state[0], Isolate_State.Wait_Message)

		fmt.printfln(
			"\n[TEST SUCCESS] Staging claim is rejected by struct-source helper and reclaimed by turn cleanup. Staging pool: %d/%d free.",
			stage_pool.free_count,
			stage_pool.slot_count,
		)
	}

	// ----------------------------------------------------------------------------
	// Test 5: Mass teardown must not free in-flight pool slots
	//
	// Catches Bug 3: the rename of io_completion_tag → io_operation_kind
	// (ADR §5.3) caused the field to be set at submission time, not just at
	// completion time. The mass teardown sweep used the field as a "has
	// completed I/O" signal and would free in-flight receive pool slots
	// while the kernel is still writing to them.
	//
	// The fix gates the sweep on .IO_Completion_Ready. We construct a shard
	// directly, hand-craft one slot with an in-flight recv and one slot
	// with a completed recv, then call shard_mass_teardown and verify the
	// in-flight slot's pool entry is preserved.
	// ----------------------------------------------------------------------------

	@(test)
	test_mass_teardown_preserves_in_flight_pool_slots :: proc(t: ^testing.T) {
		fixture := _make_teardown_test_shard_with_slots(t, 2)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		// Use the same type/slot as the helper provides. Reserve a fresh
		// receive pool slot for the in-flight case and another for the
		// completed case so we can check both behaviors.
		in_flight_index, in_flight_error := io_slot_pool_alloc_tina_owned(&shard.reactor.receive_pool)
		testing.expect_value(t, in_flight_error, IO_Slot_Pool_Error.None)

		completed_index, completed_error := io_slot_pool_alloc_tina_owned(&shard.reactor.receive_pool)
		testing.expect_value(t, completed_error, IO_Slot_Pool_Error.None)

		receive_pool := &shard.reactor.receive_pool
		// 2 slots consumed above out of pool.slot_count
		testing.expect_value(t, receive_pool.free_count, receive_pool.slot_count - 2)

		// Hand-craft slot state: in-flight recv on one slot, completed recv
		// on another. Mass teardown must free only the completed one.
		soa_meta := shard.metadata[0]

		// Slot 0: in-flight recv. io_operation_kind is set at
		// submission (the regression), but IO_Completion_Ready is NOT set.
		// Pre-fix mass teardown would free the receive pool slot here.
		_slot_set_state(shard, 0, 0, .Wait_Io)
		soa_meta[0].io_operation_kind = .Recv_Complete
		soa_meta[0].io_slot_index = in_flight_index
		soa_meta[0].flags = {}

		// Slot 1: completed recv. IO_Completion_Ready IS set. Mass teardown
		// must free this receive pool slot.
		_slot_set_state(shard, 0, 1, .Runnable)
		soa_meta[1].io_operation_kind = .Recv_Complete
		soa_meta[1].io_slot_index = completed_index
		soa_meta[1].flags = {.IO_Completion_Ready}

		shard_mass_teardown(shard)

		// After mass teardown:
		//   - The completed slot's pool entry was freed (+1).
		//   - The in-flight slot's pool entry was NOT freed (preserved).
		// So receive_pool.free_count should be slot_count - 1 (only the
		// in-flight entry is still in use).
		testing.expect(
			t,
			receive_pool.free_count == receive_pool.slot_count - 1,
			"in-flight pool slot must NOT be freed by mass teardown",
		)

		fmt.printfln(
			"\n[TEST SUCCESS] Mass teardown preserved in-flight pool slot. Receive pool: %d/%d free (one in-flight preserved).",
			receive_pool.free_count,
			receive_pool.slot_count,
		)
	}

	// =========================================================================
	// Test 6: Pending_IO_Reuse resolution via stale completion (ADR §5.3)
	//
	// Verifies the full liveness path: an Isolate with an in-flight struct-
	// source write is torn down → slot enters Pending_IO_Reuse → stale
	// completion arrives → slot resolves to Unallocated and returns to the
	// free list. The slot must never be permanently leaked.
	// =========================================================================
	@(test)
	test_pending_io_reuse_resolves_on_stale_completion :: proc(t: ^testing.T) {
		fixture := _make_teardown_test_shard_with_slots(t, 1)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		soa_meta := shard.metadata[0]
		type_id: Isolate_Type_Id = 0
		slot_index: u32 = 0
		generation: u32 = 1
		io_sequence: u8 = 1

		// --- Setup: simulate a live Isolate with in-flight struct-source write ---
		// Activate the slot through the fixture helper, then specialize it for
		// the teardown scenario. The helper removes the slot from the free list
		// and unpoisons payload memory; the test then sets the I/O metadata.
		test_shard_slot_activate(
			fixture,
			make_handle(0, type_id, Isolate_Slot_Index(slot_index), generation),
			.Runnable,
		)
		soa_meta[slot_index].io_operation_kind = .Send_Complete
		soa_meta[slot_index].io_slot_index = IO_SLOT_INDEX_NONE // struct-source: no pool slot
		soa_meta[slot_index].io_fd = FD_HANDLE_NONE
		soa_meta[slot_index].io_sequence = io_sequence
		soa_meta[slot_index].flags = {} // IO_Completion_Ready NOT set (still in-flight)
		soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
		soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
		soa_meta[slot_index].inbox_count = 0
		soa_meta[slot_index].group_id = SUPERVISION_GROUP_ID_NONE

		_slot_set_state(shard, type_id, Isolate_Slot_Index(slot_index), .Wait_Io)
		// Counter must reflect the Wait_Io state.
		when TINA_RUNTIME_ASSERTIONS {
			assert(shard.counters.io_awaiting_count == 1)
		}

		// --- Step 1: Teardown — should enter Pending_IO_Reuse, not Unallocated ---
		_teardown_isolate(shard, type_id, Isolate_Slot_Index(slot_index), .Normal)

		testing.expect_value(t, soa_meta[slot_index]._state, Isolate_State.Pending_IO_Reuse)
		// Counter must still be 1 — the slot is still I/O-blocked.
		testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))
		// Free list must still be empty — slot is NOT reusable yet.
		testing.expect_value(t, shard.isolate_free_heads[type_id], POOL_NONE_INDEX)

		// --- Step 2: Inject stale completion into simulated backend ---
		// The token uses the OLD generation (before teardown bumped it).
		stale_token := submission_token_pack(
			u8(type_id), slot_index, u8(generation), io_sequence,
			IO_SLOT_INDEX_NONE, .Send_Complete,
		)

		backend := &shard.reactor.backend
		backend.completed[backend.completed_tail] = Raw_Completion {
			token   = stale_token,
			outcome = Completion_Transfer{byte_count = 42},
			flags   = {},
		}
		backend.completed_tail = (backend.completed_tail + 1) % MAX_SIMULATED_COMPLETED
		backend.completed_count += 1
		shard.reactor.io_in_flight_count = 1

		// --- Step 3: Collect completions — should resolve Pending_IO_Reuse ---
		reactor_collect_completions(&shard.reactor, shard, 0)

		testing.expect_value(t, soa_meta[slot_index]._state, Isolate_State.Unallocated)
		testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))
		testing.expect_value(t, shard.isolate_free_heads[type_id], slot_index)
		testing.expect_value(t, shard.reactor.io_in_flight_count, u32(0))
		testing.expect_value(t, shard.counters.io_stale_completions, u64(1))

		fmt.println("\n[TEST SUCCESS] Pending_IO_Reuse resolved via stale completion — slot returned to free list.")
	}

	// =========================================================================
	// Test 7: Receive teardown preserves completion-owned metadata
	//
	// The stale completion needs both the pool index and FD lifecycle identity.
	// Therefore receive I/O seals the slot exactly like zero-copy writes until
	// the accepted obligation reaches the common stale-completion path.
	// =========================================================================
	@(test)
	test_recv_teardown_preserves_metadata_until_completion :: proc(t: ^testing.T) {
		fixture := _make_teardown_test_shard_with_slots(t, 1)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		soa_meta := shard.metadata[0]
		type_id: Isolate_Type_Id = 0
		slot_index: u32 = 0
		generation: u32 = 1
		io_sequence: u8 = 1

		// Activate the slot through the fixture helper, then specialize it for
		// the teardown scenario.
		test_shard_slot_activate(
			fixture,
			make_handle(0, type_id, Isolate_Slot_Index(slot_index), generation),
			.Runnable,
		)

		// Allocate a receive pool slot to simulate in-flight recv.
		recv_slot, recv_error := io_slot_pool_alloc_tina_owned(&shard.reactor.receive_pool)
		testing.expect_value(t, recv_error, IO_Slot_Pool_Error.None)

		soa_meta[slot_index].io_operation_kind = .Recv_Complete
		soa_meta[slot_index].io_slot_index = recv_slot // receive pool slot
		soa_meta[slot_index].io_fd = FD_HANDLE_NONE
		soa_meta[slot_index].io_sequence = io_sequence
		soa_meta[slot_index].flags = {} // Still in-flight
		soa_meta[slot_index].inbox_head = POOL_NONE_INDEX
		soa_meta[slot_index].inbox_tail = POOL_NONE_INDEX
		soa_meta[slot_index].inbox_count = 0
		soa_meta[slot_index].group_id = SUPERVISION_GROUP_ID_NONE

		_slot_set_state(shard, type_id, Isolate_Slot_Index(slot_index), .Wait_Io)
		when TINA_RUNTIME_ASSERTIONS {
			assert(shard.counters.io_awaiting_count == 1)
		}

		// Teardown seals the metadata until the stale completion can reclaim it.
		_teardown_isolate(shard, type_id, Isolate_Slot_Index(slot_index), .Normal)

		testing.expect_value(t, soa_meta[slot_index]._state, Isolate_State.Pending_IO_Reuse)
		testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))
		testing.expect_value(t, shard.isolate_free_heads[type_id], u32(POOL_NONE_INDEX))

		fmt.println("\n[TEST SUCCESS] Recv teardown preserved metadata for stale completion cleanup.")
	}
}
