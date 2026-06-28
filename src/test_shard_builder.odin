package tina

import "core:mem"

// Subsystems that can be requested for a test shard fixture.
// Metadata is the mandatory base: every real fixture needs type descriptors,
// isolate memory, SOA metadata, and free lists. Other subsystems declare
// explicit dependencies so the builder can validate the fixture contract.
Test_Shard_Subsystem :: enum {
	Metadata,
	Dispatchable,
	Message_Pool,
	Timer_Wheel,
	Reactor,
	Transfer_Pool,
	Handoff_Table,
	Supervision,
	Scratch,
}

Test_Shard_Subsystems :: distinct bit_set[Test_Shard_Subsystem]

Test_Shard_Spec :: struct {
	type_count:              int,
	slot_counts:             []int,
	strides:                 []int, // per type; 0 means no isolate payload
	working_memory_sizes:    []int, // per type; 0 means no working memory
	subsystems:              Test_Shard_Subsystems,
	// Subsystem config (0 = sensible default)
	message_pool_slots:      int,
	timer_entry_count:       int,
	reactor_buffer_count:    int,
	reactor_buffer_bytes:    int,
	staging_slot_count:      int,
	staging_slot_size:       int,
	transfer_slot_count:     int,
	transfer_slot_size:      int,
	handoff_entry_count:     int,
	supervision_group_count: int,
	scratch_memory_size:      int,
	fd_table_slot_count:     int,
}

// Test_Shard_Fixture owns the Grand Arena backing and the Shard carved from it.
// Tests receive a fixture and use helper procedures; they do not allocate a
// Shard directly or remember which fields to initialize.
Test_Shard_Fixture :: struct {
	arena:                  Grand_Arena,
	shard:                  Shard,
	health_report:          Shard_Health_Report,
	// Ownership record for subsystems that completed initialization. Deinit
	// uses this to avoid tearing down subsystems that were never initialized.
	initialized_subsystems: Test_Shard_Subsystems,
}

@(private)
_test_fd_entry_size :: 64

@(private)
_test_shard_stride :: proc(spec: Test_Shard_Spec, type_index: int) -> int {
	if len(spec.strides) == 0 do return 8
	if type_index < len(spec.strides) do return spec.strides[type_index]
	return 8
}

@(private)
_test_shard_working_memory_size :: proc(spec: Test_Shard_Spec, type_index: int) -> int {
	if len(spec.working_memory_sizes) == 0 do return 0
	if type_index < len(spec.working_memory_sizes) do return spec.working_memory_sizes[type_index]
	return 0
}

// _Test_Shard_Resolved_Config holds the subsystem sizing values after defaults
// have been applied. Centralizing this logic prevents drift between the memory
// pre-computation and the actual carve.
@(private)
_Test_Shard_Resolved_Config :: struct {
	message_pool_slots:      int,
	timer_entry_count:       int,
	reactor_buffer_count:    int,
	reactor_buffer_bytes:    int,
	fd_table_slot_count:     int,
	staging_slot_count:      int,
	staging_slot_size:       int,
	transfer_slot_count:     int,
	transfer_slot_size:      int,
	handoff_entry_count:     int,
	supervision_group_count: int,
	scratch_memory_size:      int,
}

@(private)
_test_shard_resolve_config :: proc(spec: Test_Shard_Spec) -> _Test_Shard_Resolved_Config {
	config := _Test_Shard_Resolved_Config{}

	config.message_pool_slots = spec.message_pool_slots
	if config.message_pool_slots == 0 do config.message_pool_slots = 16

	config.timer_entry_count = spec.timer_entry_count
	if config.timer_entry_count == 0 do config.timer_entry_count = 16

	config.reactor_buffer_count = spec.reactor_buffer_count
	if config.reactor_buffer_count == 0 do config.reactor_buffer_count = 4

	config.reactor_buffer_bytes = spec.reactor_buffer_bytes
	if config.reactor_buffer_bytes == 0 do config.reactor_buffer_bytes = 1024

	config.fd_table_slot_count = spec.fd_table_slot_count
	if config.fd_table_slot_count == 0 do config.fd_table_slot_count = 8

	config.staging_slot_count = spec.staging_slot_count
	if config.staging_slot_count == 0 do config.staging_slot_count = 2

	config.staging_slot_size = spec.staging_slot_size
	if config.staging_slot_size == 0 do config.staging_slot_size = 1024

	config.transfer_slot_count = spec.transfer_slot_count
	if config.transfer_slot_count == 0 do config.transfer_slot_count = 4

	config.transfer_slot_size = spec.transfer_slot_size
	if config.transfer_slot_size == 0 do config.transfer_slot_size = 1024

	config.handoff_entry_count = spec.handoff_entry_count
	if config.handoff_entry_count == 0 do config.handoff_entry_count = 8

	config.supervision_group_count = spec.supervision_group_count
	if config.supervision_group_count == 0 do config.supervision_group_count = 4

	config.scratch_memory_size = spec.scratch_memory_size
	if config.scratch_memory_size == 0 do config.scratch_memory_size = 4096

	return config
}

@(private = "package")
_test_shard_validate_spec :: proc(spec: Test_Shard_Spec) {
	when TINA_RUNTIME_ASSERTIONS {
		assert(spec.type_count > 0, "test shard fixture must have at least one type")
		assert(len(spec.slot_counts) == spec.type_count, "slot_counts must match type_count")
		assert(
			len(spec.strides) == 0 || len(spec.strides) == spec.type_count,
			"strides must be empty or match type_count",
		)
		assert(
			len(spec.working_memory_sizes) == 0 ||
			len(spec.working_memory_sizes) == spec.type_count,
			"working_memory_sizes must be empty or match type_count",
		)
		assert(.Metadata in spec.subsystems, "Metadata is a mandatory base subsystem")
	}
}

@(private)
_test_shard_compute_memory :: proc(spec: Test_Shard_Spec) -> int {
	_test_shard_validate_spec(spec)

	config := _test_shard_resolve_config(spec)

	total := 0
	types_count := spec.type_count

	regions_max := 32
	total += regions_max * size_of(SubRegion)

	total += types_count * size_of(IsolateTypeDescriptor)
	total += types_count * size_of([]u8) // isolate_memory
	total += types_count * size_of([]u8) // working_memory
	total += types_count * size_of(#soa[]Isolate_Metadata) // metadata
	total += types_count * size_of(u32)      // isolate_free_heads
	total += types_count * size_of(u32)      // dispatch_cursors
	total += types_count * size_of(Scheduler_Credit_Count) // dispatch_credit_counts
	total += types_count * size_of(u32)      // dispatchable_slot_counts
	total += types_count * size_of([]u64)    // dispatchable_slot_words

	dispatch_word_type_count := _dispatch_word_count(int(types_count))
	total += dispatch_word_type_count * size_of(u64) // dispatchable_type_words
	total += dispatch_word_type_count * size_of(u64) // dispatch_ready_type_words

	for type_index in 0 ..< types_count {
		slot_count := spec.slot_counts[type_index]
		stride := _test_shard_stride(spec, type_index)
		working_memory_size := _test_shard_working_memory_size(spec, type_index)

		total += slot_count * stride
		aligned_count := _aligned_capacity(slot_count)
		total += aligned_count * size_of(Isolate_Metadata)
		total += _dispatch_word_count(slot_count) * size_of(u64)
		total += slot_count * working_memory_size
	}

	if .Message_Pool in spec.subsystems {
		total += config.message_pool_slots * MESSAGE_ENVELOPE_SIZE
	}

	if .Timer_Wheel in spec.subsystems {
		entries := config.timer_entry_count
		total += entries * size_of(u64)
		total += entries * size_of(Isolate_Handle)
		total += entries * size_of(Message_Tag)
		total += entries * size_of(Correlation_Id)
		total += bitmap_word_count_from_bit_count(entries) * size_of(u64)
	}

	if .Reactor in spec.subsystems {
		total += config.fd_table_slot_count * _test_fd_entry_size
		total += config.reactor_buffer_count * config.reactor_buffer_bytes
		total += config.staging_slot_count * config.staging_slot_size
	}

	if .Transfer_Pool in spec.subsystems {
		total += config.transfer_slot_count * config.transfer_slot_size
		total += config.transfer_slot_count * size_of(u16) // transfer_generations
	}

	if .Handoff_Table in spec.subsystems {
		total += config.handoff_entry_count * size_of(FD_Handoff_Entry)
	}

	if .Supervision in spec.subsystems {
		total += config.supervision_group_count * size_of(Supervision_Group)
	}

	if .Scratch in spec.subsystems {
		total += config.scratch_memory_size
	}

	total += regions_max * CACHE_LINE_SIZE

	return total
}

@(private = "package")
test_shard_build :: proc(spec: Test_Shard_Spec, fixture: ^Test_Shard_Fixture) -> mem.Allocator_Error {
	_test_shard_validate_spec(spec)

	config := _test_shard_resolve_config(spec)

	shard := &fixture.shard
	arena := &fixture.arena
	types_count := spec.type_count
	regions_max := 32

	tracker_size := regions_max * size_of(SubRegion)
	tracker_memory := grand_arena_alloc_named(arena, "Arena_Regions_Tracker", tracker_size) or_return
	arena.regions = mem.slice_ptr(cast(^SubRegion)raw_data(tracker_memory), regions_max)
	arena.regions[0] = SubRegion{name = "Arena_Regions_Tracker", qualifier = -1, offset = 0, size = tracker_size}
	arena.region_count = 1

	alloc_data := Grand_Arena_Allocator_Data{arena = arena}
	alloc := grand_arena_allocator(&alloc_data)

	// --- Slice headers ---
	grand_arena_allocator_set_name(&alloc_data, "Slice_Headers")
	shard.type_descriptors = make([]IsolateTypeDescriptor, types_count, alloc) or_return
	shard.isolate_memory = make([][]u8, types_count, alloc) or_return
	shard.working_memory = make([][]u8, types_count, alloc) or_return
	shard.metadata = make([]#soa[]Isolate_Metadata, types_count, alloc) or_return
	shard.isolate_free_heads = make([]u32, types_count, alloc) or_return
	shard.dispatchable_slot_words = make([][]u64, types_count, alloc) or_return
	shard.dispatchable_slot_counts = make([]u32, types_count, alloc) or_return
	shard.dispatchable_type_words = make([]u64, _dispatch_word_count(types_count), alloc) or_return
	shard.dispatch_ready_type_words = make([]u64, _dispatch_word_count(types_count), alloc) or_return

	grand_arena_allocator_set_name(&alloc_data, "Dispatch_Cursors")
	shard.dispatch_cursors = make([]u32, types_count, alloc) or_return

	grand_arena_allocator_set_name(&alloc_data, "Dispatch_Credit_Counts")
	shard.dispatch_credit_counts = make([]Scheduler_Credit_Count, types_count, alloc) or_return

	// --- Per-type data ---
	for type_index in 0 ..< types_count {
		slot_count := spec.slot_counts[type_index]
		stride := _test_shard_stride(spec, type_index)
		working_memory_size := _test_shard_working_memory_size(spec, type_index)

		shard.isolate_free_heads[type_index] = POOL_NONE_INDEX
		shard.type_descriptors[type_index] = IsolateTypeDescriptor{
			id                = Isolate_Type_Id(type_index),
			slot_count        = slot_count,
			stride            = stride,
			working_memory_size = working_memory_size,
			soa_metadata_size = size_of(Isolate_Metadata),
		}

		if slot_count > 0 {
			grand_arena_allocator_set_name(&alloc_data, "Typed_Arena", type_index)
			if stride > 0 {
				shard.isolate_memory[type_index] = make([]u8, slot_count * stride, alloc) or_return
			}

			grand_arena_allocator_set_name(&alloc_data, "Dispatchable_Slots", type_index)
			shard.dispatchable_slot_words[type_index] = make(
				[]u64,
				_dispatch_word_count(slot_count),
				alloc,
			) or_return

			grand_arena_allocator_set_name(&alloc_data, "SOA_Metadata", type_index)
			aligned_count := _aligned_capacity(slot_count)
			shard.metadata[type_index] = make(#soa[]Isolate_Metadata, aligned_count, alloc) or_return

			for slot := slot_count - 1; slot >= 0; slot -= 1 {
				shard.metadata[type_index][slot].inbox_head = shard.isolate_free_heads[type_index]
				_slot_set_state_bare(
					shard,
					Isolate_Type_Id(type_index),
					Isolate_Slot_Index(slot),
					.Unallocated,
					"builder bootstrap: no invariants active during memory carving",
				)
				shard.metadata[type_index][slot].generation = 1
				shard.isolate_free_heads[type_index] = u32(slot)
			}

			if working_memory_size > 0 {
				grand_arena_allocator_set_name(&alloc_data, "Working_Memory", type_index)
				shard.working_memory[type_index] = make(
					[]u8,
					slot_count * working_memory_size,
					alloc,
				) or_return
			}

			// Poison every initially free slot so fixture lifetime matches
			// production hydrate_shard. Activation unpoisons; release re-poisons.
			for slot in 0 ..< slot_count {
				_sanitizer_address_poison_isolate_slot(
					shard,
					Isolate_Type_Id(type_index),
					Isolate_Slot_Index(slot),
				)
			}
		}
	}
	fixture.initialized_subsystems += {.Metadata}

	// --- Message Pool ---
	if .Message_Pool in spec.subsystems {
		msg_pool_buf := grand_arena_alloc_slice(arena, "Message_Pool", config.message_pool_slots * MESSAGE_ENVELOPE_SIZE) or_return
		msg_pool_backing := mem.slice_ptr(cast(^Message_Envelope)raw_data(msg_pool_buf), config.message_pool_slots)
		pool_init_tina_owned(&shard.message_pool, msg_pool_backing)
		shard.handoff_retry_head = POOL_NONE_INDEX
		shard.handoff_retry_tail = POOL_NONE_INDEX
		shard.handoff_retry_count = 0
		fixture.initialized_subsystems += {.Message_Pool}
	}

	// --- Timer Wheel ---
	if .Timer_Wheel in spec.subsystems {
		grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Deadlines")
		timer_deadlines := make([]u64, config.timer_entry_count, alloc) or_return

		grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Targets")
		timer_targets := make([]Isolate_Handle, config.timer_entry_count, alloc) or_return

		grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Tags")
		timer_tags := make([]Message_Tag, config.timer_entry_count, alloc) or_return

		grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Correlations")
		timer_correlations := make([]Correlation_Id, config.timer_entry_count, alloc) or_return

		grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Armed_Words")
		timer_armed_words := make([]u64, bitmap_word_count_from_bit_count(config.timer_entry_count), alloc) or_return

		timer_wheel_init(&shard.timer_wheel, timer_deadlines, timer_targets, timer_tags, timer_correlations, timer_armed_words)
		fixture.initialized_subsystems += {.Timer_Wheel}
	}

	// --- Reactor ---
	if .Reactor in spec.subsystems {
		grand_arena_allocator_set_name(&alloc_data, "FD_Table")
		fd_buf := make([]FD_Entry, config.fd_table_slot_count, alloc) or_return

		rx_buf := grand_arena_alloc_slice(arena, "Reactor_Receive_Pool", config.reactor_buffer_count * config.reactor_buffer_bytes) or_return
		staging_buf := grand_arena_alloc_slice(arena, "Reactor_Staging_Pool", config.staging_slot_count * config.staging_slot_size) or_return

		backend_config := Backend_Config{queue_size = REACTOR_SUBMISSION_BATCH_COUNT}
		reactor_error := reactor_init_tina_owned(
			&shard.reactor,
			backend_config,
			fd_buf,
			IO_Slot_Pool_Config{backing_memory = rx_buf, slot_size = u32(config.reactor_buffer_bytes), slot_count = u16(config.reactor_buffer_count)},
			IO_Slot_Pool_Config{backing_memory = staging_buf, slot_size = u32(config.staging_slot_size), slot_count = u16(config.staging_slot_count)},
		)
		if reactor_error != .None {
			return .Out_Of_Memory
		}
		fixture.initialized_subsystems += {.Reactor}
	}

	// --- Transfer Pool ---
	if .Transfer_Pool in spec.subsystems {
		transfer_buf := grand_arena_alloc_slice(arena, "Transfer_Buffer_Pool", config.transfer_slot_count * config.transfer_slot_size) or_return
		io_slot_pool_init_tina_owned(
			&shard.transfer_pool,
			transfer_buf,
			u32(config.transfer_slot_size),
			u16(config.transfer_slot_count),
		)

		grand_arena_allocator_set_name(&alloc_data, "Transfer_Generations")
		shard.transfer_generations = make([]u16, config.transfer_slot_count, alloc) or_return
		for i in 0 ..< config.transfer_slot_count {
			shard.transfer_generations[i] = 1
		}
		fixture.initialized_subsystems += {.Transfer_Pool}
	}

	// --- Handoff Table ---
	if .Handoff_Table in spec.subsystems {
		grand_arena_allocator_set_name(&alloc_data, "FD_Handoff_Table")
		handoff_buffer := make([]FD_Handoff_Entry, config.handoff_entry_count, alloc) or_return
		fd_handoff_table_init(&shard.handoff_table, handoff_buffer)
		fixture.initialized_subsystems += {.Handoff_Table}
	}

	// --- Supervision ---
	if .Supervision in spec.subsystems {
		grand_arena_allocator_set_name(&alloc_data, "Supervision_Group_Table")
		shard.supervision_groups = make([]Supervision_Group, config.supervision_group_count, alloc) or_return
		fixture.initialized_subsystems += {.Supervision}
	}

	// --- Scratch ---
	if .Scratch in spec.subsystems {
		shard.scratch_memory = grand_arena_alloc_slice(arena, "Scratch_Memory", config.scratch_memory_size) or_return
		fixture.initialized_subsystems += {.Scratch}
	}

	return .None
}

@(private = "package")
test_shard_fixture_init :: proc(spec: Test_Shard_Spec) -> ^Test_Shard_Fixture {
	fixture := new(Test_Shard_Fixture)
	total := _test_shard_compute_memory(spec)
	error := grand_arena_init(&fixture.arena, total)
	when TINA_RUNTIME_ASSERTIONS {
		assert(error == .None, "failed to initialize test shard fixture arena")
	}
	if error != .None {
		free(fixture)
		return nil
	}

	carve_error := test_shard_build(spec, fixture)
	when TINA_RUNTIME_ASSERTIONS {
		assert(carve_error == .None, "failed to build test shard fixture")
	}
	if carve_error != .None {
		test_shard_fixture_deinit(fixture)
		return nil
	}

	fixture.shard.id = 0
	fixture.shard.shard_count = 1
	fixture.health_report.reported_state = u8(Shard_State.Running)
	fixture.shard.health_report = &fixture.health_report

	return fixture
}

@(private = "package")
test_shard_fixture_deinit :: proc(fixture: ^Test_Shard_Fixture) {
	if fixture == nil do return
	if .Reactor in fixture.initialized_subsystems {
		reactor_deinit(&fixture.shard.reactor)
	}
	// Unpoison the fixture's memory before returning it to the OS so the ASan
	// shadow state matches the backing allocation's lifetime, consistent with
	// simulator_deinit. The helper is a no-op for uninitialized pools.
	_sanitizer_address_unpoison_shard_memory(&fixture.shard)
	os_release_arena_with_guard(fixture.arena.base)
	free(fixture)
}

@(private)
_test_fixture_free_list_remove :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	head := shard.isolate_free_heads[type_id]
	if head == u32(slot_index) {
		shard.isolate_free_heads[type_id] = shard.metadata[type_id][slot_index].inbox_head
		return
	}
	current := head
	for current != POOL_NONE_INDEX {
		next := shard.metadata[type_id][current].inbox_head
		if next == u32(slot_index) {
			shard.metadata[type_id][current].inbox_head = shard.metadata[type_id][slot_index].inbox_head
			return
		}
		current = next
	}
	when TINA_RUNTIME_ASSERTIONS {
		panic("fixture activate: slot was not present in the free list")
	}
}

// Activate a free isolate slot for test use. The slot is removed from the free
// list, its metadata is reset to the supplied generation, payload/working memory
// is unpoisoned in ASan builds, and the final state is routed through the
// approved state setter.
@(private = "package")
test_shard_slot_activate :: proc(
	fixture: ^Test_Shard_Fixture,
	handle: Isolate_Handle,
	state: Isolate_State,
) {
	shard := &fixture.shard
	type_id := extract_type_id(handle)
	slot_index := extract_slot(handle)
	generation := extract_generation(handle)

	when TINA_RUNTIME_ASSERTIONS {
		assert(int(type_id) < len(shard.type_descriptors), "activated type_id out of range")
		assert(
			int(slot_index) < shard.type_descriptors[type_id].slot_count,
			"activated slot_index out of range",
		)
		assert(generation != 0, "activated slot must have a non-zero generation")
		assert(
			shard.metadata[type_id][slot_index]._state == .Unallocated,
			"activated slot must be free",
		)
	}

	_test_fixture_free_list_remove(shard, type_id, slot_index)

	// Reset metadata while preserving the new generation. The slot is no longer
	// on the free list, so inbox links must be cleared. We reset each scalar
	// field explicitly rather than assigning a zero struct to the #soa row,
	// because SOA row assignment can corrupt adjacent slots in some Odin
	// versions when the compiler treats the row as an AOS temporary.
	shard.metadata[type_id][slot_index].generation = generation
	shard.metadata[type_id][slot_index].io_peer_address = {}
	shard.metadata[type_id][slot_index].inbox_head = POOL_NONE_INDEX
	shard.metadata[type_id][slot_index].inbox_tail = POOL_NONE_INDEX
	shard.metadata[type_id][slot_index].pending_correlation = 0
	shard.metadata[type_id][slot_index].io_fd = FD_HANDLE_NONE
	shard.metadata[type_id][slot_index].io_result = 0
	shard.metadata[type_id][slot_index].working_arena_offset = 0
	shard.metadata[type_id][slot_index].inbox_count = 0
	shard.metadata[type_id][slot_index].group_id = SUPERVISION_GROUP_ID_NONE
	shard.metadata[type_id][slot_index].io_operation_kind = .None
	shard.metadata[type_id][slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	shard.metadata[type_id][slot_index].flags = {}
	shard.metadata[type_id][slot_index].io_sequence = 0

	_sanitizer_address_unpoison_isolate_slot(shard, type_id, slot_index)
	_slot_set_state(shard, type_id, slot_index, state)
}

// Release an isolate slot back to the fixture's free list. The state transition
// routes through the approved setter so ASan poison is applied in production
// builds and the dispatchable bitmap is refreshed.
@(private = "package")
test_shard_slot_release :: proc(
	fixture: ^Test_Shard_Fixture,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	shard := &fixture.shard

	when TINA_RUNTIME_ASSERTIONS {
		assert(int(type_id) < len(shard.type_descriptors), "released type_id out of range")
		assert(
			int(slot_index) < shard.type_descriptors[type_id].slot_count,
			"released slot_index out of range",
		)
		assert(
			shard.metadata[type_id][slot_index]._state != .Unallocated,
			"released slot must be active",
		)
	}

	_slot_set_state(shard, type_id, slot_index, .Unallocated)
	shard.metadata[type_id][slot_index].inbox_head = shard.isolate_free_heads[type_id]
	shard.isolate_free_heads[type_id] = u32(slot_index)
}
