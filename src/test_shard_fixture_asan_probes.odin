package tina

import "base:sanitizer"
import "core:mem"
import "core:testing"

// Silence unused-import warnings in non-ASan builds, where the tests below are
// erased. All three packages are used when TINA_ASAN_POISONING is true.
_ :: sanitizer
_ :: mem
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

	// Probe for the ASan-aware working arena. The allocator wrapper unpoisons
	// each fresh allocation while ctx_working_arena_reset poisons the used
	// region, so stale pointers into reset memory are visible to ASan.
	@(private = "file")
	_Working_Arena_Probe_State :: struct {
		reset_allocation_pointer:             rawptr,
		reset_allocation_is_poisoned:         bool,
		reset_reallocation_is_unpoisoned:     bool,
		free_all_allocation_is_poisoned:      bool,
		free_all_reallocation_is_unpoisoned:  bool,
	}

	@(private = "file")
	_working_arena_probe_callback :: proc(user_data: rawptr) {
		state := cast(^_Working_Arena_Probe_State)user_data
		working_allocator := ctx_working_arena()

		first := new(u64, working_allocator)
		first^ = 0xDEAD_BEEF
		state.reset_allocation_pointer = first

		ctx_working_arena_reset()
		state.reset_allocation_is_poisoned =
			sanitizer.address_region_is_poisoned_rawptr(first, size_of(u64)) != nil

		second := new(u64, working_allocator)
		second^ = 0xCAFE_BABE
		state.reset_reallocation_is_unpoisoned =
			sanitizer.address_region_is_poisoned_rawptr(second, size_of(u64)) == nil

		free_all(working_allocator)
		state.free_all_allocation_is_poisoned =
			sanitizer.address_region_is_poisoned_rawptr(second, size_of(u64)) != nil

		third := new(u64, working_allocator)
		third^ = 0xFACE_FEED
		state.free_all_reallocation_is_unpoisoned =
			sanitizer.address_region_is_poisoned_rawptr(third, size_of(u64)) == nil
	}

	@(test)
	test_working_arena_reset_poison_and_realloc_unpoison :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		state: _Working_Arena_Probe_State
		test_with_turn_frame(
			Test_Turn_Frame_Config{
				self_handle         = make_handle(0, 0, 0, 1),
				working_memory_size = 256,
			},
			&state,
			_working_arena_probe_callback,
		)

		testing.expect(
			t,
			state.reset_allocation_is_poisoned,
			"working-arena allocation must be poisoned after ctx_working_arena_reset",
		)
		testing.expect(
			t,
			state.reset_reallocation_is_unpoisoned,
			"allocation after ctx_working_arena_reset must be unpoisoned",
		)
		testing.expect(
			t,
			state.free_all_allocation_is_poisoned,
			"working-arena allocation must be poisoned after allocator Free_All",
		)
		testing.expect(
			t,
			state.free_all_reallocation_is_unpoisoned,
			"allocation after allocator Free_All must be unpoisoned",
		)
	}

	@(test)
	test_inflight_io_pool_slots_poison_and_unpoison :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		fixture := test_shard_fixture_init(
			Test_Shard_Spec{
				type_count           = 1,
				slot_counts          = {1},
				strides              = {8},
				subsystems           = {.Metadata, .Dispatchable, .Reactor},
				reactor_buffer_count = 2,
				reactor_buffer_bytes = 64,
				staging_slot_count   = 1,
				staging_slot_size    = 64,
			},
		)
		defer test_shard_fixture_deinit(fixture)
		shard := &fixture.shard

		test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Wait_Io)

		receive_index, receive_error := io_slot_pool_alloc_unzeroed_tina_owned(&shard.reactor.receive_pool)
		testing.expect_value(t, receive_error, IO_Slot_Pool_Error.None)
		receive_pointer := rawptr(_io_slot_pool_pointer(&shard.reactor.receive_pool, receive_index))

		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(receive_pointer, 64) == nil,
			"allocated receive slot must be unpoisoned before submit",
		)
		_sanitizer_address_poison_inflight_io_slot(&shard.reactor, .Receive, receive_index)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(receive_pointer, 64) != nil,
			"in-flight receive slot must be poisoned",
		)

		_slot_set_io_completion_ready(shard, 0, 0, .Recv_Complete, 8, receive_index)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(receive_pointer, 64) == nil,
			"receive completion must unpoison the handler-visible slot",
		)
		io_slot_pool_free_tina_owned(&shard.reactor.receive_pool, receive_index)
		shard.metadata[0][0].io_slot_index = IO_SLOT_INDEX_NONE

		staging_index, staging_error := io_slot_pool_alloc_tina_owned(&shard.reactor.staging_pool)
		testing.expect_value(t, staging_error, IO_Slot_Pool_Error.None)
		staging_pointer := rawptr(_io_slot_pool_pointer(&shard.reactor.staging_pool, staging_index))

		_sanitizer_address_poison_inflight_io_slot(&shard.reactor, .Staging, staging_index)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(staging_pointer, 64) != nil,
			"in-flight staging slot must be poisoned",
		)
		_sanitizer_address_unpoison_reactor_io_slot(&shard.reactor, .Staging, staging_index)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(staging_pointer, 64) == nil,
			"staging completion must unpoison the slot before handler dispatch",
		)
		io_slot_pool_free_tina_owned(&shard.reactor.staging_pool, staging_index)
	}

	@(test)
	test_fully_poisoned_io_slot_can_return_to_free_list :: proc(t: ^testing.T) {
		backing: [64]u8
		pool: IO_Slot_Pool
		io_slot_pool_init_tina_owned(&pool, backing[:], 64, 1)
		defer _sanitizer_address_unpoison_io_pool_slots(&pool)

		index, error := io_slot_pool_alloc_unzeroed_tina_owned(&pool)
		testing.expect_value(t, error, IO_Slot_Pool_Error.None)
		pointer := rawptr(_io_slot_pool_pointer(&pool, index))

		_sanitizer_address_poison_io_slot(&pool, index)
		io_slot_pool_free_tina_owned(&pool, index)

		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(pointer, size_of(IO_Slot_Index)) == nil,
			"free-list word must remain addressable after freeing a fully poisoned slot",
		)
		testing.expect(
			t,
			sanitizer.address_region_is_poisoned_rawptr(
				rawptr(uintptr(pointer) + uintptr(size_of(IO_Slot_Index))),
				64 - size_of(IO_Slot_Index),
			) != nil,
			"freed IO slot payload must be poisoned",
		)
	}
}
