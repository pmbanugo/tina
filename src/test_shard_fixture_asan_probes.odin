package tina

import "base:sanitizer"
import "core:testing"

// Silence unused-import warnings in non-ASan builds, where the tests below are
// erased. Both packages are used when TINA_ASAN_POISONING is true.
_ :: sanitizer
_ :: testing

// Non-crashing probes for the fixture isolate-slot lifetime hooks. These tests
// verify that AddressSanitizer sees the same logical object lifetimes as
// production hydration: free slots are poisoned, activation unpoisons them, and
// release re-poisons them. The file compiles to nothing outside ASan builds.
when TINA_ASAN_POISONING {

	@(private = "file")
	_isolate_payload_ptr :: proc(
		shard: ^Shard,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
	) -> rawptr {
		descriptor := shard.type_descriptors[type_id]
		if descriptor.stride == 0 {
			return nil
		}
		start_index := int(slot_index) * descriptor.stride
		return rawptr(&shard.isolate_memory[type_id][start_index])
	}

	@(private = "file")
	_isolate_working_ptr :: proc(
		shard: ^Shard,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
	) -> rawptr {
		descriptor := shard.type_descriptors[type_id]
		if descriptor.working_memory_size == 0 {
			return nil
		}
		start_index := int(slot_index) * descriptor.working_memory_size
		return rawptr(&shard.working_memory[type_id][start_index])
	}

	@(test)
	test_fixture_free_isolate_slot_is_poisoned_in_asan_builds :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		fixture := test_shard_fixture_init(
			Test_Shard_Spec{
				type_count           = 1,
				slot_counts          = {2},
				strides              = {64},
				working_memory_sizes = {32},
				subsystems           = {.Metadata},
			},
		)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		payload := _isolate_payload_ptr(shard, 0, 1)
		working := _isolate_working_ptr(shard, 0, 1)

		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(payload, 64) != nil,
			"initially free isolate payload must be poisoned",
		)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(working, 32) != nil,
			"initially free isolate working memory must be poisoned",
		)
	}

	@(test)
	test_fixture_activation_unpoisons_isolate_slot_in_asan_builds :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		fixture := test_shard_fixture_init(
			Test_Shard_Spec{
				type_count           = 1,
				slot_counts          = {2},
				strides              = {64},
				working_memory_sizes = {32},
				subsystems           = {.Metadata},
			},
		)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 1, 1), .Runnable)

		payload := _isolate_payload_ptr(shard, 0, 1)
		working := _isolate_working_ptr(shard, 0, 1)

		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(payload, 64) == nil,
			"activated isolate payload must be unpoisoned",
		)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(working, 32) == nil,
			"activated isolate working memory must be unpoisoned",
		)
	}

	@(test)
	test_fixture_release_repoisons_isolate_slot_in_asan_builds :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		fixture := test_shard_fixture_init(
			Test_Shard_Spec{
				type_count           = 1,
				slot_counts          = {2},
				strides              = {64},
				working_memory_sizes = {32},
				subsystems           = {.Metadata},
			},
		)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 1, 1), .Runnable)
		test_shard_slot_release(fixture, 0, 1)

		payload := _isolate_payload_ptr(shard, 0, 1)
		working := _isolate_working_ptr(shard, 0, 1)

		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(payload, 64) != nil,
			"released isolate payload must be re-poisoned",
		)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(working, 32) != nil,
			"released isolate working memory must be re-poisoned",
		)
	}
}
