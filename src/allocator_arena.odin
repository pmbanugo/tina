package tina

import "core:fmt"
import vmem "core:mem/virtual"
import "core:testing"

SubRegion :: struct {
    name: string,
    offset: int,
    size: int,
}

Grand_Arena :: struct {
    base: []u8,
    offset: int,
    total_size: int,
    regions: []SubRegion, // A dynamic slice backed by the Arena itself
    region_count: int,
}

grand_arena_init :: proc(arena: ^Grand_Arena, total_size: int) -> vmem.Allocator_Error {
    data, err := vmem.reserve_and_commit(uint(total_size))
    if err != nil {
        return err
    }
    arena.base = data
    arena.offset = 0
    arena.total_size = total_size
    arena.region_count = 0
    arena.regions = nil // Remains nil until carve_shard_memory explicitly allocates it
    return nil
}

grand_arena_alloc_named :: proc(arena: ^Grand_Arena, name: string, size: int, alignment: int = CACHE_LINE_SIZE) -> (rawptr, vmem.Allocator_Error) {
    if size == 0 {
        return nil, nil
    }

    base_ptr := uintptr(raw_data(arena.base))
    curr_ptr := base_ptr + uintptr(arena.offset)
    align_offset := int((uintptr(alignment) - (curr_ptr % uintptr(alignment))) % uintptr(alignment))

    actual_offset := arena.offset + align_offset
    total_alloc := size + align_offset

    if arena.offset + total_alloc > arena.total_size {
        return nil, .Out_Of_Memory
    }

    ptr := rawptr(base_ptr + uintptr(actual_offset))
    arena.offset += total_alloc

    // Only record if the tracking array has been allocated
    if arena.regions != nil && arena.region_count < len(arena.regions) {
        arena.regions[arena.region_count] = SubRegion{
            name = name,
            offset = actual_offset,
            size = size,
        }
        arena.region_count += 1
    }

    return ptr, nil
}

carve_shard_memory :: proc(arena: ^Grand_Arena, spec: ^SystemSpec, shard: ^ShardSpec) -> vmem.Allocator_Error {
    // 1. First, allocate the tracking array FOR the arena, FROM the arena!
    max_regions := compute_max_sub_regions(spec)
    tracker_size := max_regions * size_of(SubRegion)
    tracker_ptr := grand_arena_alloc_named(arena, "Arena_Regions_Tracker", tracker_size) or_return

    // Cast the raw memory into our slice
    arena.regions = (cast([^]SubRegion)tracker_ptr)[:max_regions]

    // Manually record this first allocation, since `arena.regions` was nil when it happened
    arena.regions[0] = SubRegion{"Arena_Regions_Tracker", 0, tracker_size} // offset 0 (first alloc)
    arena.region_count = 1

    // 2. Allocate everything else
    for t in spec.types {
        grand_arena_alloc_named(arena, "Typed_Arena", t.slot_count * t.stride) or_return
        grand_arena_alloc_named(arena, "SOA_Metadata", t.slot_count * t.soa_metadata_size) or_return
        if t.working_memory_size > 0 {
            grand_arena_alloc_named(arena, "Working_Memory", t.slot_count * t.working_memory_size) or_return
        }
    }

    grand_arena_alloc_named(arena, "Message_Pool", spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE) or_return
    grand_arena_alloc_named(arena, "Reactor_Buffer_Pool", spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size) or_return
    grand_arena_alloc_named(arena, "Transfer_Buffer_Pool", spec.transfer_slot_count * spec.transfer_slot_size) or_return
    grand_arena_alloc_named(arena, "Timer_Wheel", spec.timer_wheel_memory) or_return
    grand_arena_alloc_named(arena, "FD_Table", spec.fd_table_slot_count * spec.fd_entry_size) or_return
    grand_arena_alloc_named(arena, "Log_Ring_Buffer", spec.log_ring_size) or_return
    grand_arena_alloc_named(arena, "Supervision_Group_Table", spec.supervision_group_table_memory) or_return
    grand_arena_alloc_named(arena, "Scratch_Arena", spec.scratch_arena_size) or_return

    return nil
}

arena_print_layout :: proc(arena: ^Grand_Arena) {
    fmt.eprintf("Grand Arena Memory Map (Total: %v bytes):\n", arena.total_size)
    for i in 0..<arena.region_count {
        r := arena.regions[i]
        fmt.eprintf("  [0x%08X - 0x%08X] %-30s (%v bytes)\n", r.offset, r.offset + r.size, r.name, r.size)
    }
}

// === TESTS ===
@(test)
test_grand_arena :: proc(t: ^testing.T) {
    types := [1]TypeDescriptor{
        {id = 1, slot_count = 10, stride = 64, soa_metadata_size = 8, working_memory_size = 0, max_scratch_requirement = 0},
    }

    spec := SystemSpec{
        types = types[:],
        pool_slot_count = 10,
        scratch_arena_size = 1024,
    }

    shard_spec := ShardSpec{shard_id = 1}
    total_mem := compute_shard_memory_total(&spec)

    arena := Grand_Arena{}
    err := grand_arena_init(&arena, total_mem)
    testing.expect_value(t, err, vmem.Allocator_Error.None)

    // Ensure we release the OS memory mapping at the end of the test
    defer vmem.release(raw_data(arena.base), uint(arena.total_size))

    carve_err := carve_shard_memory(&arena, &spec, &shard_spec)
    testing.expect_value(t, carve_err, vmem.Allocator_Error.None)

    testing.expect(t, arena.region_count > 1, "Arena should have carved regions")
    testing.expect(t, arena.regions[0].name == "Arena_Regions_Tracker", "First region should be the tracker")
}
