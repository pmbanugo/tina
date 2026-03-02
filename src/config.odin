package tina

import "core:testing"

CACHE_LINE_SIZE :: 128 // CPU Cache Line size for alignment.

Init_Fn :: #type proc(self: rawptr, args:[]u8, ctx: ^TinaContext) -> Effect
Handler_Fn :: #type proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect

TypeDescriptor :: struct {
    id: u8,
    slot_count: int,
    stride: int,
    soa_metadata_size: int,
    working_memory_size: int,
    max_scratch_requirement: int,
    init_fn: Init_Fn,
    handler_fn: Handler_Fn,
}

ShardSpec :: struct {
    shard_id: u16,
}

SystemSpec :: struct {
    types: []TypeDescriptor,
    pool_slot_count: int,
    reactor_buffer_slot_count: int,
    reactor_buffer_slot_size: int,
    transfer_slot_count: int,
    transfer_slot_size: int,
    timer_wheel_memory: int,
    fd_table_slot_count: int,
    fd_entry_size: int,
    log_ring_size: int,
    supervision_group_table_memory: int,
    scratch_arena_size: int,
}

SystemSpecError :: enum u8 {
    None,
    ScratchArenaTooSmall,
    SlotCountExceedsHandleCapacity,
}

validate_system_spec :: proc(spec: ^SystemSpec) -> SystemSpecError {
    max_scratch := 0
    for t in spec.types {
	    if t.slot_count > MAX_ISOLATES_PER_TYPE {
	            return .SlotCountExceedsHandleCapacity
	        }
        if t.max_scratch_requirement > max_scratch {
            max_scratch = t.max_scratch_requirement
        }
    }
    if spec.scratch_arena_size < max_scratch {
        return .ScratchArenaTooSmall
    }
    return .None
}

// Computes the maximum possible sub-regions carved from the arena
// TODO: I might have to revisit later because we're implementing things incrementally.
// Revisit CONFIGURATION_VALIDATION.md later, perhaps combined with the memory management ADR
compute_max_sub_regions :: proc(spec: ^SystemSpec) -> int {
    types_count := len(spec.types)
    // 3 per type (Typed Arena, SOA Metadata, Working Memory) + 8 static framework regions + 1 for the SubRegion tracker array itself
    return (types_count * 3) + 8 + 1
    // FYI: Fixed system regions:
    // 1. Regions Array (SubRegion tracker)
    // 2. Message Pool
    // 3. Reactor Buffer Pool
    // 4. Transfer Buffer Pool
    // 5. Timer Wheel
    // 6. FD Table
    // 7. Log Ring Buffer
    // 8. Supervision Group Table
    // 9. Scratch Arena
}

compute_shard_memory_total :: proc(spec: ^SystemSpec) -> int {
    total := 0
    max_regions := compute_max_sub_regions(spec)

    // In the worst case, every single sub-region allocation requires
    // CACHE_LINE_SIZE - 1 bytes of padding to align.
    padding_overhead := max_regions * CACHE_LINE_SIZE

    for t in spec.types {
        total += t.slot_count * t.stride
        total += t.slot_count * t.soa_metadata_size
        total += t.slot_count * t.working_memory_size
    }

    total += spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE
    total += spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size
    total += spec.transfer_slot_count * spec.transfer_slot_size
    total += spec.timer_wheel_memory
    total += spec.fd_table_slot_count * spec.fd_entry_size
    total += spec.log_ring_size
    total += spec.supervision_group_table_memory
    total += spec.scratch_arena_size

    // Account for the memory required to hold the sub-region tracking array itself
    total += max_regions * size_of(SubRegion)


    return total + padding_overhead
}

// === TESTS ===
@(test)
test_system_spec_validation :: proc(t: ^testing.T) {
    types := [2]TypeDescriptor{
        {id = 1, max_scratch_requirement = 1024},
        {id = 2, max_scratch_requirement = 4096},
    }

    spec := SystemSpec{
        types = types[:],
        scratch_arena_size = 2048, // Intentionally too small
    }

    err := validate_system_spec(&spec)
    testing.expect_value(t, err, SystemSpecError.ScratchArenaTooSmall)

    spec.scratch_arena_size = 4096 // Exactly enough
    err = validate_system_spec(&spec)
    testing.expect_value(t, err, SystemSpecError.None)
}
