package tina

import "core:fmt"
import "core:mem"
import "core:testing"

SubRegion :: struct {
	name:      string,
	qualifier: int,
	offset:    int,
	size:      int,
}

Grand_Arena :: struct {
	base:         []u8,
	offset:       int,
	total_size:   int,
	regions:      []SubRegion, // A dynamic slice backed by the Arena itself
	region_count: int,
}

grand_arena_init_from_memory :: proc "contextless" (
	arena: ^Grand_Arena,
	backing_memory: []u8,
	total_size: int,
) -> mem.Allocator_Error {
	if total_size > len(backing_memory) {
		arena^ = {}
		return .Out_Of_Memory
	}

	arena.base = backing_memory
	arena.offset = 0
	arena.total_size = total_size
	arena.region_count = 0
	arena.regions = nil // Remains nil until carve_shard_memory explicitly allocates it
	return .None
}

grand_arena_init :: proc "contextless" (
	arena: ^Grand_Arena,
	total_size: int,
) -> mem.Allocator_Error {
	data, error := os_reserve_arena_with_guard(uint(total_size))
	if error != .None {
		return error
	}
	init_error := grand_arena_init_from_memory(arena, data, total_size)
	if init_error != .None {
		os_release_arena_with_guard(data)
		return init_error
	}
	return .None
}

grand_arena_alloc_named :: proc(
	arena: ^Grand_Arena,
	name: string,
	size: int,
	alignment: int = CACHE_LINE_SIZE,
	qualifier: int = -1,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	assert(size >= 0, "size must be non-negative")

	if size == 0 {
		return {}, .None
	}

	assert(alignment > 0 && (alignment & (alignment - 1)) == 0, "alignment must be a power of two")

	// Align the absolute address, not only the byte offset. OS-backed arenas are
	// page-aligned, but test/simulation arenas may be ordinary []u8 allocations.
	base_address := uintptr(raw_data(arena.base))
	current_address := base_address + uintptr(arena.offset)
	if current_address < base_address {
		return {}, .Out_Of_Memory
	}
	alignment_mask := uintptr(alignment - 1)
	aligned_address := (current_address + alignment_mask) & ~alignment_mask
	if aligned_address < current_address {
		return {}, .Out_Of_Memory
	}
	actual_offset := int(aligned_address - base_address)

	if actual_offset > arena.total_size || size > arena.total_size - actual_offset {
		return {}, .Out_Of_Memory
	}

	memory := arena.base[actual_offset:actual_offset + size]
	arena.offset = actual_offset + size

	// Only record if the tracking array has been allocated
	if arena.regions != nil && arena.region_count < len(arena.regions) {
		arena.regions[arena.region_count] = SubRegion {
			name      = name,
			qualifier = qualifier,
			offset    = actual_offset,
			size      = size,
		}
		arena.region_count += 1
	}

	return memory, .None
}

grand_arena_alloc_slice :: #force_inline proc(
	arena: ^Grand_Arena,
	name: string,
	size: int,
	qualifier: int = -1,
) -> (
	result: []u8,
	error: mem.Allocator_Error,
) {
	return grand_arena_alloc_named(arena, name, size, qualifier = qualifier)
}

// Custom Allocator Wrapper for Grand_Arena
Grand_Arena_Allocator_Data :: struct {
	arena:             ^Grand_Arena,
	current_name:      string,
	current_qualifier: int,
}

grand_arena_allocator_set_name :: #force_inline proc "contextless" (
	data: ^Grand_Arena_Allocator_Data,
	name: string,
	qualifier: int = -1,
) {
	data.current_name = name
	data.current_qualifier = qualifier
}

grand_arena_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	data := cast(^Grand_Arena_Allocator_Data)allocator_data
	switch mode {
	case .Alloc:
		// Enforce cache-line alignment to ensure clean hardware prefetching and
		// prevent cache-line splits on dense array iteration.
		// over-padded: The bytes wasted on dispatch_cursors/dispatch_credit_counts/isolate_free_heads
		// is a harmless casualty of a blunt, safe default.
		//
		// Switching to e.g. Bimodal Alignment,
		// I risk misaligning the start of a massive SOA array.
		// Optimise post-V1 if profiling shows L1d eviction pressure.
		//
		// Bimodal Alignment (rough idea):
		// massive chunks of memory (Message Pools, Reactor Buffers, Typed Arenas)
		// should be cache-line aligned for prefetching and SIMD efficiency.
		// But tiny metadata slices (Slice Headers, dispatch_cursors, dispatch_credit_counts, isolate_free_heads)
		// should be tightly packed.
		actual_alignment := max(alignment, CACHE_LINE_SIZE)
		memory, error := grand_arena_alloc_named(
			data.arena,
			data.current_name,
			size,
			actual_alignment,
			data.current_qualifier,
		)
		if error != .None do return nil, error
		return memory, .None
	case .Resize:
		if old_size >= size do return mem.byte_slice(old_memory, size), .None
		return nil, .Mode_Not_Implemented
	case .Free, .Free_All:
		return nil, .None // Silently ignore, arenas free all at once structurally
	case .Alloc_Non_Zeroed:
		// Arena bumps a pointer; non-zeroed is identical to zeroed allocation
		actual_alignment := max(alignment, CACHE_LINE_SIZE)
		memory, error := grand_arena_alloc_named(
			data.arena,
			data.current_name,
			size,
			actual_alignment,
			data.current_qualifier,
		)
		if error != .None do return nil, error
		return memory, .None
	case .Query_Features, .Query_Info, .Resize_Non_Zeroed:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

grand_arena_allocator :: proc "contextless" (data: ^Grand_Arena_Allocator_Data) -> mem.Allocator {
	return mem.Allocator{procedure = grand_arena_allocator_proc, data = data}
}

// --- The Hydrator ---
// Allocates and wires all structures directly into the Shard pointer.
hydrate_shard :: proc(
	arena: ^Grand_Arena,
	spec: ^SystemSpec,
	shard: ^Shard,
) -> mem.Allocator_Error {
	// 1. Allocate the tracking array FOR the arena, FROM the arena!
	regions_max := compute_max_sub_regions(spec)
	tracker_size := regions_max * size_of(SubRegion)
	tracker_memory := grand_arena_alloc_named(
		arena,
		"Arena_Regions_Tracker",
		tracker_size,
	) or_return

	arena.regions = mem.slice_ptr(cast(^SubRegion)raw_data(tracker_memory), regions_max)
	arena.regions[0] = SubRegion {
		name      = "Arena_Regions_Tracker",
		qualifier = -1,
		offset    = 0,
		size      = tracker_size,
	}
	arena.region_count = 1

	// Setup the custom allocator
	alloc_data := Grand_Arena_Allocator_Data {
		arena = arena,
	}
	alloc := grand_arena_allocator(&alloc_data)

	types_count := len(spec.types)

	if spec.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1_048_576 // Default to ~1ms (power-of-2). Later I can experiement with 524,288 (~500ns)
	} else {shard.timer_resolution_ns = spec.timer_resolution_ns}

	shard.peer_alive_mask = {~u64(0), ~u64(0), ~u64(0), ~u64(0)} // All peers alive by default

	// 2. Allocate the Slice Headers
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

	// 3. Allocate Type-Specific Data (Inner slices)
	for t, i in spec.types {
		// Apply defaults at startup
		type_descriptor := t
		type_index := int(type_descriptor.id)
		assert(type_index == i, "IsolateTypeDescriptor ids must match dense descriptor index")
		if type_descriptor.budget_weight == 0 do type_descriptor.budget_weight = 1
		if type_descriptor.mailbox_capacity == 0 do type_descriptor.mailbox_capacity = 256

		shard.type_descriptors[type_index] = type_descriptor
		shard.isolate_free_heads[type_index] = POOL_NONE_INDEX // Initialize

		if type_descriptor.slot_count > 0 && type_descriptor.stride > 0 {
			grand_arena_allocator_set_name(&alloc_data, "Typed_Arena", type_index)
			shard.isolate_memory[type_index] = make([]u8, type_descriptor.slot_count * type_descriptor.stride, alloc) or_return
		}
		if type_descriptor.slot_count > 0 {
			grand_arena_allocator_set_name(&alloc_data, "Dispatchable_Slots", type_index)
			shard.dispatchable_slot_words[type_index] = make(
				[]u64,
				_dispatch_word_count(type_descriptor.slot_count),
				alloc,
			) or_return
		}

		aligned_count := _aligned_capacity(type_descriptor.slot_count)
		if aligned_count > 0 {
			grand_arena_allocator_set_name(&alloc_data, "SOA_Metadata", type_index)
			shard.metadata[type_index] = make(#soa[]Isolate_Metadata, aligned_count, alloc) or_return

			// Build the intrusive free list for this Type Arena
			// We iterate backwards so slot 0 is at the head of the free list
			for slot := int(type_descriptor.slot_count) - 1; slot >= 0; slot -= 1 {
				shard.metadata[type_index][slot].inbox_head = shard.isolate_free_heads[type_index]
				_slot_set_state_bare(shard, Isolate_Type_Id(type_index), Isolate_Slot_Index(slot), .Unallocated,
					"hydrate_shard bootstrap: no invariants active during memory carving")
				shard.metadata[type_index][slot].generation = 1 // Enforce ADR rule: generations start at 1
				shard.isolate_free_heads[type_index] = u32(slot)
			}
		}
		if type_descriptor.working_memory_size > 0 {
			shard.working_memory[type_index] = grand_arena_alloc_slice(
				arena,
				"Working_Memory",
				type_descriptor.slot_count * type_descriptor.working_memory_size,
				type_index,
			) or_return
		}

		for slot in 0 ..< type_descriptor.slot_count {
			_sanitizer_address_poison_isolate_slot(
				shard,
				Isolate_Type_Id(type_index),
				Isolate_Slot_Index(slot),
			)
		}
	}

	// 4. Subsystems (raw byte buffers bypass zeroing — OS guarantees zero-filled pages from mmap/VirtualAlloc)
	msg_pool_buf := grand_arena_alloc_slice(
		arena,
		"Message_Pool",
		spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE,
	) or_return
	msg_pool_backing := mem.slice_ptr(cast(^Message_Envelope)raw_data(msg_pool_buf), spec.pool_slot_count)
	pool_init_tina_owned(&shard.message_pool, msg_pool_backing)
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0

	transfer_buf := grand_arena_alloc_slice(
		arena,
		"Transfer_Buffer_Pool",
		spec.transfer_slot_count * spec.transfer_slot_size,
	) or_return
	io_slot_pool_init_tina_owned(
		&shard.transfer_pool,
		transfer_buf,
		u32(spec.transfer_slot_size),
		u16(spec.transfer_slot_count),
	)

	grand_arena_allocator_set_name(&alloc_data, "Transfer_Generations")
	shard.transfer_generations = make([]u16, spec.transfer_slot_count, alloc) or_return
	for i in 0 ..< spec.transfer_slot_count {
		shard.transfer_generations[i] = 1
	}

	grand_arena_allocator_set_name(&alloc_data, "FD_Handoff_Table")
	handoff_buffer := make([]FD_Handoff_Entry, spec.fd_handoff_entry_count, alloc) or_return
	fd_handoff_table_init(&shard.handoff_table, handoff_buffer)

	grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Deadlines")
	timer_deadlines := make([]u64, spec.timer_entry_count, alloc) or_return

	grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Targets")
	timer_targets := make([]Isolate_Handle, spec.timer_entry_count, alloc) or_return

	grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Tags")
	timer_tags := make([]Message_Tag, spec.timer_entry_count, alloc) or_return

	grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Correlations")
	timer_correlations := make([]Correlation_Id, spec.timer_entry_count, alloc) or_return

	grand_arena_allocator_set_name(&alloc_data, "Timer_Wheel_Armed_Words")
	timer_armed_word_count := bitmap_word_count_from_bit_count(spec.timer_entry_count)
	timer_armed_words := make([]u64, timer_armed_word_count, alloc) or_return

	timer_wheel_init(
		&shard.timer_wheel,
		timer_deadlines,
		timer_targets,
		timer_tags,
		timer_correlations,
		timer_armed_words,
	)

	grand_arena_allocator_set_name(&alloc_data, "Log_Ring_Buffer")
	log_buf := make([]u8, spec.log_ring_size, alloc) or_return
	log_init_tina_owned(&shard.log_ring, log_buf)

	grand_arena_allocator_set_name(&alloc_data, "Supervision_Group_Table")
	shard.supervision_groups = make([]Supervision_Group, spec.supervision_groups_max, alloc) or_return

	shard.scratch_memory = grand_arena_alloc_slice(
		arena,
		"Scratch_Arena",
		spec.scratch_arena_size,
	) or_return

	// 5. Reactor
	grand_arena_allocator_set_name(&alloc_data, "FD_Table")
	fd_buf := make([]FD_Entry, spec.fd_table_slot_count, alloc) or_return

	rx_buf := grand_arena_alloc_slice(
		arena,
		"Reactor_Receive_Pool",
		spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size,
	) or_return

	staging_buf := grand_arena_alloc_slice(
		arena,
		"Reactor_Staging_Pool",
		spec.staging_slot_count * spec.staging_slot_size,
	) or_return

	backend_config := Backend_Config {
		queue_size = REACTOR_SUBMISSION_BATCH_COUNT,
	}
	when TINA_SIMULATION_MODE {
		if spec.simulation != nil {
			// Derive a per-shard I/O seed from the simulation master seed and shard ID.
			// This is a bootstrap seed — the full Prng_Tree wiring replaces it during
			// simulator setup when the tree is available.
			io_seed := spec.simulation.seed ~ (u64(shard.id) * ~u64(0x9E3779B97F4A7C15))
			backend_config.sim_config = Simulation_IO_Config {
				fault_rate        = spec.simulation.faults.io_error_rate,
				delay_range_ticks = spec.simulation.faults.io_delay_range_ticks,
				reorder           = true,
				seed              = io_seed,
				world             = cast(rawptr)spec.simulation.sim_io_world,
			}
		}
	}

	reactor_error := reactor_init_tina_owned(
		&shard.reactor,
		backend_config,
		fd_buf,
		IO_Slot_Pool_Config{backing_memory = rx_buf, slot_size = u32(spec.reactor_buffer_slot_size), slot_count = u16(spec.reactor_buffer_slot_count)},
		IO_Slot_Pool_Config{backing_memory = staging_buf, slot_size = u32(spec.staging_slot_size), slot_count = u16(spec.staging_slot_count)},
	)
	if reactor_error != .None {
		return .Out_Of_Memory // Standardizing to allocator error to bubble up cleanly
	}

	return .None
}

// Retrieves a carved sub-region as a raw byte slice. Returns nil if not found.
// Used primarily for testing now that hydration is automatic.
@(private)
grand_arena_get_region :: proc "contextless" (arena: ^Grand_Arena, name: string) -> []u8 {
	for i in 0 ..< arena.region_count {
		if arena.regions[i].name == name {
			return(
				arena.base[arena.regions[i].offset:arena.regions[i].offset +
				arena.regions[i].size] \
			)
		}
	}
	return nil
}

arena_print_layout :: proc(arena: ^Grand_Arena) {
	fmt.eprintf("Grand Arena Memory Map (Total: %v bytes):\n", arena.total_size)
	for i in 0 ..< arena.region_count {
		r := arena.regions[i]
		if r.qualifier >= 0 {
			fmt.eprintf(
				"  [0x%08X - 0x%08X] %s_%d (%v bytes)\n",
				r.offset,
				r.offset + r.size,
				r.name,
				r.qualifier,
				r.size,
			)
		} else {
			fmt.eprintf(
				"  [0x%08X - 0x%08X] %s (%v bytes)\n",
				r.offset,
				r.offset + r.size,
				r.name,
				r.size,
			)
		}
	}
}

// === TESTS ===
// ALLOWLIST_FILE(hydrate_shard_fixture): The tests below exercise the real
// hydrate_shard production path. They are approved hydrate-shard fixtures,
// not partial hardcoded Shard fixtures.
@(test)
test_grand_arena_alloc_named_aligns_absolute_address :: proc(t: ^testing.T) {
	MESSAGE_ALIGNMENT :: align_of(Message_Envelope)
	backing_memory: [size_of(Message_Envelope) + MESSAGE_ALIGNMENT * 2]u8

	misaligned_offset := -1
	for offset in 1 ..< MESSAGE_ALIGNMENT {
		candidate_memory := backing_memory[offset:]
		if uintptr(raw_data(candidate_memory)) % uintptr(MESSAGE_ALIGNMENT) != 0 {
			misaligned_offset = offset
			break
		}
	}

	testing.expect(t, misaligned_offset >= 0, "test must find a misaligned arena base")
	if misaligned_offset < 0 do return

	arena_memory := backing_memory[misaligned_offset:]
	arena := Grand_Arena{}
	init_error := grand_arena_init_from_memory(&arena, arena_memory, len(arena_memory))
	testing.expect_value(t, init_error, mem.Allocator_Error.None)

	memory, allocation_error := grand_arena_alloc_named(
		&arena,
		"Message_Pool",
		size_of(Message_Envelope),
		MESSAGE_ALIGNMENT,
	)
	testing.expect_value(t, allocation_error, mem.Allocator_Error.None)
	testing.expect_value(t, len(memory), size_of(Message_Envelope))
	testing.expect(
		t,
		uintptr(raw_data(memory)) % uintptr(MESSAGE_ALIGNMENT) == 0,
		"arena allocation must align the absolute address",
	)
}

@(test)
test_grand_arena :: proc(t: ^testing.T) {
	types := [1]IsolateTypeDescriptor {
		{
			id = 0,
			slot_count = 10,
			stride = 64,
			soa_metadata_size = size_of(Isolate_Metadata),
			working_memory_size = 0,
			scratch_requirement_max = 0,
		},
	}
	REACTOR_SLOTS :: 4
	REACTOR_SIZE :: 4096
	TRANSFER_SLOTS :: 4
	TRANSFER_SIZE :: 4096

	spec := SystemSpec {
		types                     = types[:],
		pool_slot_count           = 10,
		scratch_arena_size        = 1024,

		// Provide valid sizes to satisfy the subsystem initializers
		reactor_buffer_slot_count = REACTOR_SLOTS,
		reactor_buffer_slot_size  = REACTOR_SIZE,
		transfer_slot_count       = TRANSFER_SLOTS,
		transfer_slot_size        = TRANSFER_SIZE,
		staging_slot_count        = 2,
		staging_slot_size         = 1024,
		timer_entry_count         = 64, // Timer entry pool capacity
		supervision_groups_max    = 4,
		fd_table_slot_count       = 16,
		fd_entry_size             = size_of(FD_Entry),
		log_ring_size             = 1024, // Power of 2
	}

	total_mem := compute_shard_memory_total(&spec)

	arena := Grand_Arena{}
	error := grand_arena_init(&arena, total_mem)
	testing.expect_value(t, error, mem.Allocator_Error.None)

	// ALLOWLIST(hydrate_shard_fixture): This test exercises the production
	// hydrate_shard path itself; the Shard must be allocated separately so
	// hydration can carve into it.
	shard := new(Shard)
	defer free(shard)

	carve_error := hydrate_shard(&arena, &spec, shard)
	// Teardown order matters for ASan: reactor pools, then all isolate slots,
	// then the backing arena. hydrate_shard poisons free isolate slots and the
	// reactor pools; we must unpoison them before the arena backing is released.
	defer {
		reactor_deinit(&shard.reactor)
		_sanitizer_address_unpoison_shard_memory(shard)
		os_release_arena_with_guard(arena.base)
	}
	testing.expect_value(t, carve_error, mem.Allocator_Error.None)

	testing.expect(t, arena.region_count > 1, "Arena should have carved regions")
	testing.expect(
		t,
		arena.regions[0].name == "Arena_Regions_Tracker",
		"First region should be the tracker",
	)
	testing.expect(t, shard.type_descriptors != nil, "Shard type descriptors should be mapped")
	testing.expect(t, shard.metadata[0] != nil, "Shard SOA arrays should be mapped")
}

@(test)
test_hydrate_shard_reports_undersized_arena_make_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	types := [1]IsolateTypeDescriptor {
		{
			id = 0,
			slot_count = 10,
			stride = 64,
			soa_metadata_size = size_of(Isolate_Metadata),
			working_memory_size = 0,
			scratch_requirement_max = 0,
		},
	}
	REACTOR_SLOTS :: 4
	REACTOR_SIZE :: 4096
	TRANSFER_SLOTS :: 4
	TRANSFER_SIZE :: 4096

	spec := SystemSpec {
		types                     = types[:],
		pool_slot_count           = 10,
		scratch_arena_size        = 1024,

		// Provide valid sizes to satisfy the subsystem initializers
		reactor_buffer_slot_count = REACTOR_SLOTS,
		reactor_buffer_slot_size  = REACTOR_SIZE,
		transfer_slot_count       = TRANSFER_SLOTS,
		transfer_slot_size        = TRANSFER_SIZE,
		staging_slot_count        = 2,
		staging_slot_size         = 1024,
		timer_entry_count         = 64,
		supervision_groups_max    = 4,
		fd_table_slot_count       = 16,
		fd_entry_size             = size_of(FD_Entry),
		log_ring_size             = 1024,
	}

	// The tracker fits, but the first allocator-backed make in hydrate_shard must fail.
	undersized_memory_size := compute_max_sub_regions(&spec) * size_of(SubRegion)
	undersized_memory, memory_error := make([]u8, undersized_memory_size, context.temp_allocator)
	testing.expect_value(t, memory_error, mem.Allocator_Error.None)

	arena := Grand_Arena{}
	init_error := grand_arena_init_from_memory(&arena, undersized_memory, undersized_memory_size)
	testing.expect_value(t, init_error, mem.Allocator_Error.None)

	// ALLOWLIST(hydrate_shard_fixture): This test intentionally drives
	// hydrate_shard into an OOM path; the Shard must be stack/heap separate.
	shard := new(Shard)
	defer free(shard)

	carve_error := hydrate_shard(&arena, &spec, shard)
	testing.expect_value(t, carve_error, mem.Allocator_Error.Out_Of_Memory)
}
