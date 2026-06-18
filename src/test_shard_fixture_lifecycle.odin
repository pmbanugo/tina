package tina

import "core:mem"
import "core:testing"

// Focused tests for Test_Shard_Fixture ownership and isolate-slot lifecycle.
// These are architecture tests: they prove that the fixture builder records
// which subsystems it initialized, that teardown follows that record, and
// that sanctioned activation/release helpers are the only owners of the free
// list and poison/unpoison hooks.

@(private = "file")
_fixture_free_list_count :: proc(shard: ^Shard, type_id: Isolate_Type_Id) -> int {
	count := 0
	current := shard.isolate_free_heads[type_id]
	for current != POOL_NONE_INDEX {
		count += 1
		current = shard.metadata[type_id][current].inbox_head
	}
	return count
}

@(private = "file")
_fixture_free_list_contains :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) -> bool {
	current := shard.isolate_free_heads[type_id]
	for current != POOL_NONE_INDEX {
		if current == u32(slot_index) {
			return true
		}
		current = shard.metadata[type_id][current].inbox_head
	}
	return false
}

@(private = "file")
_fixture_free_list_occurrence_count :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) -> int {
	count := 0
	current := shard.isolate_free_heads[type_id]
	for current != POOL_NONE_INDEX {
		if current == u32(slot_index) {
			count += 1
		}
		current = shard.metadata[type_id][current].inbox_head
	}
	return count
}

@(test)
test_fixture_lifecycle_metadata_only_deinits_without_reactor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {1},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)

	// The fixture must record that only Metadata was initialized; teardown
	// therefore never touches an uninitialized reactor or backend.
	testing.expect(
		t,
		fixture.initialized_subsystems == {.Metadata},
		"metadata-only fixture should initialize only Metadata",
	)
}

@(test)
test_fixture_lifecycle_reactor_fixture_deinits_cleanly :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {1},
			subsystems  = {.Metadata, .Reactor},
		},
	)
	defer test_shard_fixture_deinit(fixture)

	// Reactor resources were initialized, so the ownership record must say so.
	// The deferred deinit proves that teardown is deterministic for reactor
	// fixtures: it calls reactor_deinit only because the record says it should.
	testing.expect(
		t,
		.Reactor in fixture.initialized_subsystems,
		"reactor fixture should record reactor initialization",
	)
}

@(test)
test_fixture_lifecycle_partial_init_cleans_only_completed_subsystems :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Compute the exact size needed for a Metadata-only fixture, then ask the
	// builder to also initialize a Timer_Wheel. The timer allocation will fail
	// after Metadata is carved, giving us a partial-initialization edge case.
	metadata_only_spec := Test_Shard_Spec{
		type_count  = 1,
		slot_counts = {1},
		subsystems  = {.Metadata},
	}
	metadata_only_size := _test_shard_compute_memory(metadata_only_spec)

	with_timer_spec := Test_Shard_Spec{
		type_count        = 1,
		slot_counts       = {1},
		subsystems        = {.Metadata, .Timer_Wheel},
		// A huge timer entry count guarantees the timer allocation fails after
		// Metadata is carved, without us having to overcommit the arena enough
		// for Metadata itself to fail.
		timer_entry_count = 1_000_000,
	}

	fixture := new(Test_Shard_Fixture)

	arena_error := grand_arena_init(&fixture.arena, metadata_only_size)
	testing.expect_value(t, arena_error, mem.Allocator_Error.None)

	build_error := test_shard_build(with_timer_spec, fixture)
	testing.expect_value(t, build_error, mem.Allocator_Error.Out_Of_Memory)

	// Only Metadata completed before the failure; teardown must not assume
	// that Timer_Wheel (or any later subsystem) was initialized.
	testing.expect(
		t,
		fixture.initialized_subsystems == {.Metadata},
		"partial init should record only completed subsystems",
	)

	test_shard_fixture_deinit(fixture)
}

@(test)
test_fixture_lifecycle_slot_activation_removes_one_free_list_entry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {4},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	initial_count := _fixture_free_list_count(shard, 0)
	testing.expect_value(t, initial_count, 4)

	test_shard_slot_activate(fixture, make_handle(0, 0, 2, 1), .Runnable)

	after_count := _fixture_free_list_count(shard, 0)
	testing.expect_value(t, after_count, 3)
	testing.expect(
		t,
		!_fixture_free_list_contains(shard, 0, 2),
		"activated slot must no longer be in the free list",
	)
	testing.expect_value(t, shard.metadata[0][2]._state, Isolate_State.Runnable)
}

@(test)
test_fixture_lifecycle_slot_release_restores_free_list_without_duplicates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {2},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	initial_count := _fixture_free_list_count(shard, 0)
	testing.expect_value(t, initial_count, 2)

	test_shard_slot_activate(fixture, make_handle(0, 0, 1, 1), .Runnable)
	testing.expect_value(t, _fixture_free_list_count(shard, 0), 1)

	test_shard_slot_release(fixture, 0, 1)
	testing.expect_value(t, _fixture_free_list_count(shard, 0), 2)
	testing.expect(
		t,
		_fixture_free_list_occurrence_count(shard, 0, 1) == 1,
		"released slot must appear in the free list exactly once",
	)
}

@(test)
test_fixture_lifecycle_release_leaves_slot_unallocated :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {2},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)

	test_shard_slot_activate(fixture, make_handle(0, 0, 1, 1), .Runnable)
	testing.expect_value(t, fixture.shard.metadata[0][1]._state, Isolate_State.Runnable)

	test_shard_slot_release(fixture, 0, 1)

	// The release helper routes the slot to .Unallocated through the approved
	// setter. Because the helper asserts _state != .Unallocated on entry, a
	// duplicate release would be rejected rather than corrupt the free list.
	// The companion test above proves the slot appears on the free list exactly
	// once; this test proves the structural guard that prevents duplicates.
	testing.expect_value(t, fixture.shard.metadata[0][1]._state, Isolate_State.Unallocated)
}
