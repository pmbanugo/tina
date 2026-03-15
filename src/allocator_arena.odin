package tina

import "core:fmt"
import "core:mem"
import "core:testing"

SubRegion :: struct {
	name:   string,
	offset: int,
	size:   int,
}

Grand_Arena :: struct {
	base:         []u8,
	offset:       int,
	total_size:   int,
	regions:      []SubRegion, // A dynamic slice backed by the Arena itself
	region_count: int,
}

grand_arena_init :: proc "contextless" (
	arena: ^Grand_Arena,
	total_size: int,
) -> mem.Allocator_Error {
	data, err := os_reserve_arena_with_guard(uint(total_size))
	if err != .None {
		return err
	}
	arena.base = data
	arena.offset = 0
	arena.total_size = total_size
	arena.region_count = 0
	arena.regions = nil // Remains nil until carve_shard_memory explicitly allocates it
	return .None
}

grand_arena_alloc_named :: proc "contextless" (
	arena: ^Grand_Arena,
	name: string,
	size: int,
	alignment: int = CACHE_LINE_SIZE,
) -> (
	rawptr,
	mem.Allocator_Error,
) {
	if size == 0 {
		return nil, .None
	}

	base_ptr := uintptr(raw_data(arena.base))
	curr_ptr := base_ptr + uintptr(arena.offset)
	align_offset := int(
		(uintptr(alignment) - (curr_ptr % uintptr(alignment))) % uintptr(alignment),
	)

	actual_offset := arena.offset + align_offset
	total_alloc := size + align_offset

	if arena.offset + total_alloc > arena.total_size {
		return nil, .Out_Of_Memory
	}

	ptr := rawptr(base_ptr + uintptr(actual_offset))
	arena.offset += total_alloc

	// Only record if the tracking array has been allocated
	if arena.regions != nil && arena.region_count < len(arena.regions) {
		arena.regions[arena.region_count] = SubRegion {
			name   = name,
			offset = actual_offset,
			size   = size,
		}
		arena.region_count += 1
	}

	return ptr, .None
}

// Custom Allocator Wrapper for Grand_Arena
Grand_Arena_Allocator_Data :: struct {
	arena:        ^Grand_Arena,
	current_name: string,
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
		// Enforce cache-line alignment to prevent false sharing between sub-regions (ADR §6.9 §5)
		actual_alignment := max(alignment, CACHE_LINE_SIZE)
		ptr, err := grand_arena_alloc_named(data.arena, data.current_name, size, actual_alignment)
		if err != .None do return nil, err
		return (cast([^]byte)ptr)[:size], .None
	case .Resize:
		if old_size >= size do return (cast([^]byte)old_memory)[:size], .None
		return nil, .Mode_Not_Implemented
	case .Free, .Free_All:
		return nil, .None // Silently ignore, arenas free all at once structurally
	case .Query_Features, .Query_Info, .Alloc_Non_Zeroed, .Resize_Non_Zeroed:
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
	max_regions := compute_max_sub_regions(spec)
	tracker_size := max_regions * size_of(SubRegion)
	tracker_ptr := grand_arena_alloc_named(arena, "Arena_Regions_Tracker", tracker_size) or_return

	arena.regions = (cast([^]SubRegion)tracker_ptr)[:max_regions]
	arena.regions[0] = SubRegion{"Arena_Regions_Tracker", 0, tracker_size}
	arena.region_count = 1

	// Setup the custom allocator
	alloc_data := Grand_Arena_Allocator_Data {
		arena = arena,
	}
	alloc := grand_arena_allocator(&alloc_data)

	types_count := len(spec.types)

	// 2. Allocate the Slice Headers
	alloc_data.current_name = "Slice_Headers"
	shard.type_descriptors = make([]TypeDescriptor, types_count, alloc)
	shard.isolate_memory = make([][]u8, types_count, alloc)
	shard.working_memory = make([][]u8, types_count, alloc)
	shard.metadata = make([]#soa[]Isolate_Metadata, types_count, alloc)
	shard.isolate_free_heads = make([]u32, types_count, alloc)

	// 3. Allocate Type-Specific Data (Inner slices)
	for t, i in spec.types {
		shard.type_descriptors[i] = t
		shard.isolate_free_heads[i] = POOL_NONE_INDEX // Initialize

		if t.slot_count > 0 && t.stride > 0 {
			alloc_data.current_name = fmt.tprintf("Typed_Arena_%d", t.id)
			shard.isolate_memory[i] = make([]u8, t.slot_count * t.stride, alloc)
		}

		aligned_count := _aligned_capacity(t.slot_count)
		if aligned_count > 0 {
			alloc_data.current_name = fmt.tprintf("SOA_Metadata_%d", t.id)
			shard.metadata[i] = make(#soa[]Isolate_Metadata, aligned_count, alloc)

			// Build the intrusive free list for this Type Arena
			// We iterate backwards so slot 0 is at the head of the free list
			for slot := int(t.slot_count) - 1; slot >= 0; slot -= 1 {
				shard.metadata[i][slot].inbox_head = shard.isolate_free_heads[i]
				shard.metadata[i][slot].state = .Unallocated
				shard.metadata[i][slot].generation = 1 // Enforce ADR rule: generations start at 1
				shard.isolate_free_heads[i] = u32(slot)
			}
		}
		if t.working_memory_size > 0 {
			alloc_data.current_name = fmt.tprintf("Working_Memory_%d", t.id)
			shard.working_memory[i] = make([]u8, t.slot_count * t.working_memory_size, alloc)
		}
	}

	// 4. Subsystems
	alloc_data.current_name = "Message_Pool"
	msg_pool_buf := make([]u8, spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE, alloc)
	pool_init(&shard.message_pool, msg_pool_buf, MESSAGE_ENVELOPE_SIZE)

	alloc_data.current_name = "Transfer_Buffer_Pool"
	transfer_buf := make([]u8, spec.transfer_slot_count * spec.transfer_slot_size, alloc)
	reactor_buffer_pool_init(
		&shard.transfer_pool,
		transfer_buf,
		u32(spec.transfer_slot_size),
		u16(spec.transfer_slot_count),
	)

	alloc_data.current_name = "Transfer_Generations"
	shard.transfer_generations = make([]u16, spec.transfer_slot_count, alloc)
	for i in 0 ..< spec.transfer_slot_count {
		shard.transfer_generations[i] = 1
	}

	alloc_data.current_name = "Timer_Wheel_Spokes"
	spoke_buf := make([]u32, spec.timer_spoke_count, alloc)

	alloc_data.current_name = "Timer_Wheel_Entries"
	entry_buf := make([]Timer_Entry, spec.timer_entry_count, alloc)

	timer_wheel_init(&shard.timer_wheel, spoke_buf, entry_buf)

	alloc_data.current_name = "Log_Ring_Buffer"
	log_buf := make([]u8, spec.log_ring_size, alloc)
	log_init(&shard.log_ring, log_buf)

	alloc_data.current_name = "Supervision_Group_Table"
	shard.supervision_groups = make([]Supervision_Group, spec.supervision_groups_max, alloc)

	alloc_data.current_name = "Scratch_Arena"
	shard.scratch_memory = make([]u8, spec.scratch_arena_size, alloc)

	// 5. Reactor
	alloc_data.current_name = "FD_Table"
	fd_buf := make([]FD_Entry, spec.fd_table_slot_count, alloc)

	alloc_data.current_name = "Reactor_Buffer_Pool"
	rx_buf := make([]u8, spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size, alloc)

	backend_config := Backend_Config {
		queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
	}
	when TINA_SIMULATION_MODE {
		if spec.simulation != nil {
			backend_config.sim_config = Simulation_IO_Config {
				fault_rate        = spec.simulation.faults.io_error_rate,
				delay_range_ticks = spec.simulation.faults.io_delay_range_ticks,
				reorder           = true,
			}
		}}

	reactor_err := reactor_init(
		&shard.reactor,
		backend_config,
		fd_buf,
		rx_buf,
		u32(spec.reactor_buffer_slot_size),
		u16(spec.reactor_buffer_slot_count),
	)
	if reactor_err != .None {
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
		fmt.eprintf(
			"  [0x%08X - 0x%08X] %-30s (%v bytes)\n",
			r.offset,
			r.offset + r.size,
			r.name,
			r.size,
		)
	}
}

// === TESTS ===
@(test)
test_grand_arena :: proc(t: ^testing.T) {
	types := [1]TypeDescriptor {
		{
			id = 1,
			slot_count = 10,
			stride = 64,
			soa_metadata_size = size_of(Isolate_Metadata),
			working_memory_size = 0,
			max_scratch_requirement = 0,
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
		timer_spoke_count         = 64, // Power of 2 spoke count
		timer_entry_count         = 64, // Timer entry pool capacity
		supervision_groups_max    = 4,
		fd_table_slot_count       = 16,
		fd_entry_size             = size_of(FD_Entry),
		log_ring_size             = 1024, // Power of 2
	}

	shard_spec := ShardSpec {
		shard_id = 1,
	}
	total_mem := compute_shard_memory_total(&spec)

	arena := Grand_Arena{}
	err := grand_arena_init(&arena, total_mem)
	testing.expect_value(t, err, mem.Allocator_Error.None)

	defer os_release_arena_with_guard(arena.base)

	shard := new(Shard)
	defer free(shard)

	carve_err := hydrate_shard(&arena, &spec, shard)
	testing.expect_value(t, carve_err, mem.Allocator_Error.None)

	testing.expect(t, arena.region_count > 1, "Arena should have carved regions")
	testing.expect(
		t,
		arena.regions[0].name == "Arena_Regions_Tracker",
		"First region should be the tracker",
	)
	testing.expect(t, shard.type_descriptors != nil, "Shard type descriptors should be mapped")
	testing.expect(t, shard.metadata[0] != nil, "Shard SOA arrays should be mapped")
}
