package tina

import "core:testing"
import "core:mem"

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
    shard_id: u16, // TODO: I can turn this later to distinct type
    root_group: Group_Spec, // The root of the supervision tree for this Shard
}

SystemSpec :: struct {
    types: []TypeDescriptor,
    shard_specs:[]ShardSpec,
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

    shard_count: u16,
    default_ring_size: u32,
    ring_overrides:[]Ring_Override,
    simulation: ^SimulationConfig, // nil means production
}

SystemSpecError :: enum u8 {
    None,
    ScratchArenaTooSmall,
    SlotCountExceedsHandleCapacity,
    LogRingSizeNotPowerOfTwo,
}

Supervision_Strategy :: enum u8 {
    One_For_One,
    One_For_All,
    Rest_For_One,
}

Static_Child_Spec :: struct {
    type_id: u8,
    restart_type: Restart_Type,
    args_size: u8,
    args_payload:[MAX_INIT_ARGS_SIZE]u8,
}

Group_Spec :: struct {
    strategy: Supervision_Strategy,
    restart_count_max: u16,
    window_duration_ticks: u32,
    children:[]Child_Spec,
    dynamic_child_count_max: u16, // > 0 implies a dynamic one_for_one group
}

Child_Spec :: union {
    Static_Child_Spec,
    Group_Spec,
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

    if spec.log_ring_size == 0 || (spec.log_ring_size & (spec.log_ring_size - 1)) != 0 {
        return .LogRingSizeNotPowerOfTwo
    }

    return .None
}

// Computes the maximum possible sub-regions carved from the arena
// TODO: I might have to revisit later because we're implementing things incrementally.
// Revisit CONFIGURATION_VALIDATION.md later, perhaps combined with the memory management ADR
compute_max_sub_regions :: proc(spec: ^SystemSpec) -> int {
    types_count := len(spec.types)
    // 3 per type (Typed Arena, SOA Metadata, Working Memory) + 9 static framework regions + 1 for the SubRegion tracker array itself
    return (types_count * 3) + 9 + 1
    // FYI: Fixed system regions:
    // 1. Regions Array (SubRegion tracker)
    // 2. Message Pool
    // 3. Reactor Buffer Pool
    // 4. Transfer Buffer Pool
    // 5. Transfer Generations
    // 6. Timer Wheel
    // 7. FD Table
    // 8. Log Ring Buffer
    // 9. Supervision Group Table
    // 10. Scratch Arena
}

// Computes an upper-bound capacity aligned to a multiple of 8.
// This guarantees that Odin's #soa memory geometry, which aligns each field's
// slice independently, will never exceed our physical byte budget.
@(private="package")
_aligned_capacity :: #force_inline proc(count: int) -> int {
    return (count + 7) & ~int(7)
}

compute_shard_memory_total :: proc(spec: ^SystemSpec) -> int {
    total := 0
    max_regions := compute_max_sub_regions(spec)

    // In the worst case, every single sub-region allocation requires
    // CACHE_LINE_SIZE - 1 bytes of padding to align.
    padding_overhead := max_regions * CACHE_LINE_SIZE

    for t in spec.types {
        total += t.slot_count * t.stride

        // Use aligned physical capacity for SOA metadata to guarantee it absorbs Odin's field alignment padding
        aligned_count := _aligned_capacity(t.slot_count)
        total += aligned_count * t.soa_metadata_size

        total += t.slot_count * t.working_memory_size
    }

    total += spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE
    total += spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size
    total += spec.transfer_slot_count * spec.transfer_slot_size
    total += spec.transfer_slot_count * size_of(u16) // Transfer_Generations array
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
        log_ring_size = 65536,     // Provide a valid power-of-2 size!
    }

    err := validate_system_spec(&spec)
    testing.expect_value(t, err, SystemSpecError.ScratchArenaTooSmall)

    spec.scratch_arena_size = 4096 // Exactly enough
    err = validate_system_spec(&spec)
    testing.expect_value(t, err, SystemSpecError.None)
}

// --- Simulation Configuration ---

Ratio :: struct {
    numerator:   u32,
    denominator: u32,
}

FaultConfig :: struct {
    io_error_rate:               Ratio,
    io_delay_range_ticks:        [2]u32,
    network_drop_rate:           Ratio,
    network_delay_range_ticks:   [2]u32,
    network_partition_rate:      Ratio,
    network_partition_heal_rate: Ratio,
    isolate_crash_rate:          Ratio,
    init_failure_rate:           Ratio,
}

SimulationConfig :: struct {
    seed:                   u64,
    max_ticks:              u64,
    shuffle_shard_order:    bool,
    faults:                 FaultConfig,
    checker_interval_ticks: u32,
    terminate_on_quiescent: bool,
}

// --- Topology / Painter's Algorithm ---

Ring_Override_Type :: enum u8 { Pair, All_Inbound_To, All_Outbound_From }

Ring_Override :: struct {
    type:        Ring_Override_Type,
    source:      u16, // Valid for .Pair and .All_Outbound_From
    destination: u16, // Valid for .Pair and .All_Inbound_To
    size:        u32, // Must be power of 2 in production, but used as capacity here
}

// Painter's Algorithm: Computes a 2D matrix of ring capacities.
// Returns a slice of slices: sizes[src_shard][dst_shard]
compute_ring_sizes :: proc(shard_count: u16, default_size: u32, overrides: []Ring_Override, allocator: mem.Allocator) -> [][]u32 {
    sizes := make([][]u32, shard_count, allocator)

    for i in 0..<shard_count {
        sizes[i] = make([]u32, shard_count, allocator)
        for j in 0..<shard_count {
            if i != j {
                sizes[i][j] = default_size
            }
        }
    }

    // Apply overrides. Last match wins.
    for o in overrides {
        switch o.type {
        case .Pair:
            if o.source < shard_count && o.destination < shard_count && o.source != o.destination {
                sizes[o.source][o.destination] = o.size
            }
        case .All_Inbound_To:
            if o.destination < shard_count {
                for i in 0..<shard_count {
                    if u16(i) != o.destination { sizes[i][o.destination] = o.size }
                }
            }
        case .All_Outbound_From:
            if o.source < shard_count {
                for j in 0..<shard_count {
                    if o.source != u16(j) { sizes[o.source][j] = o.size }
                }
            }
        }
    }
    return sizes
}
