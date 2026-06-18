package tina

import "core:testing"

// Negative tests for the State_Transition_Integrity checker. Each test builds
// a fixture shard, corrupts one derived-state invariant, and verifies that
// simulator_run_checkers reports a Checker_Violation deterministically.
when TINA_SIMULATION_MODE {

	@(private = "file")
	_checker_fixture_for_state_tests :: proc() -> ^Test_Shard_Fixture {
		return test_shard_fixture_init(
			Test_Shard_Spec{
				type_count  = 1,
				slot_counts = {2},
				subsystems  = {.Metadata, .Dispatchable},
			},
		)
	}

	@(private = "file")
	_run_state_checker :: proc(fixture: ^Test_Shard_Fixture) -> bool {
		checker_flags := Checker_Flags{.State_Transition_Integrity}
		sim_config := SimulationConfig {
			builtin_checkers = checker_flags,
			user_checkers    = nil,
		}
		spec := SystemSpec {
			shard_count = 1,
			simulation  = &sim_config,
		}
		// Shard is large; avoid a stack-allocated array by allocating the slice
		// on the test temp allocator.
		shards := make([]Shard, 1, context.temp_allocator)
		shards[0] = fixture.shard
		// Minimal Simulator: simulator_run_checkers only needs spec, shards, and the
		// temp allocator for optional internal allocations. The State_Transition_Integrity
		// checker path does not touch sim_io_world, the network, or other simulator fields.
		sim := Simulator {
			spec      = &spec,
			shards    = shards,
			allocator = context.temp_allocator,
		}
		return simulator_run_checkers(&sim, 0)
	}

	@(test)
	test_state_checker_catches_metadata_dispatchable_without_bitmap_bit :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		// Make slot 0 dispatchable through the approved setter.
		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
		// Corrupt the bitmap without touching metadata.
		shard.dispatchable_slot_words[0][0] &= ~u64(1)
		shard.dispatchable_slot_counts[0] = 0
		// The type summary word is recomputed by the checker from the per-type
		// count, so clearing the cached count is sufficient to force a mismatch.

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when metadata is dispatchable but bitmap is clear")
	}

	@(test)
	test_state_checker_catches_bitmap_dispatchable_without_metadata :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		// Make slot 0 dispatchable, then clear the metadata state without
		// refreshing the bitmap.
		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
		_slot_set_state_no_dispatch(shard, 0, 0, .Unallocated)
		// Note: _slot_set_state_no_dispatch poisons and tracks io_awaiting but
		// leaves the dispatchable bitmap intact, so the checker sees the mismatch.

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when bitmap is set but metadata is not dispatchable")
	}

	@(test)
	test_state_checker_catches_dispatchable_slot_count_mismatch :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
		// Corrupt the cached count to disagree with the actual bitmap.
		shard.dispatchable_slot_counts[0] = 42

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when dispatchable_slot_counts disagrees with bitmap")
	}

	@(test)
	test_state_checker_catches_dispatchable_type_word_mismatch :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
		// Corrupt the type summary word without touching the per-type count.
		shard.dispatchable_type_words[0] = 0

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when dispatchable_type_words disagrees with per-type count")
	}

	@(test)
	test_state_checker_catches_dispatch_ready_type_word_mismatch :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
		// Count is already nonzero from activation. Raise credit so the checker
		// recomputes has_ready = true, but leave the ready word cleared.
		shard.dispatch_credit_counts[0] = 1
		shard.dispatch_ready_type_words[0] = 0

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when dispatch_ready_type_words disagrees with count/credit")
	}

	@(test)
	test_state_checker_catches_io_awaiting_count_mismatch :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Wait_Io)
		// Corrupt the counter to disagree with the Wait_Io metadata.
		shard.counters.io_awaiting_count = 0

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when io_awaiting_count disagrees with Wait_Io metadata")
	}

	@(test)
	test_state_checker_catches_unallocated_slot_in_dispatchable_bitmap :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		// Activate, make dispatchable, then transition to Unallocated without
		// clearing the bitmap bit.
		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
		_slot_set_state_no_dispatch(shard, 0, 0, .Unallocated)

		testing.expect(t, _run_state_checker(fixture), "expected checker violation when an Unallocated slot remains in the dispatchable bitmap")
	}

	@(test)
	test_state_checker_catches_pending_io_reuse_io_awaiting_count_mismatch :: proc(t: ^testing.T) {
		fixture := _checker_fixture_for_state_tests()
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		// Put the slot into the IO-awaiting Pending_IO_Reuse state, then corrupt
		// the counter so it no longer reflects that state.
		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Wait_Io)
		_slot_set_state(shard, 0, 0, .Pending_IO_Reuse)
		shard.counters.io_awaiting_count = 0

		testing.expect(
			t,
			_run_state_checker(fixture),
			"expected checker violation when Pending_IO_Reuse is not reflected in io_awaiting_count",
		)
	}
}
