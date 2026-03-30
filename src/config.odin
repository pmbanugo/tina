package tina

import "core:fmt"
import "core:mem"
import "core:testing"

MAX_SHARD_COUNT :: 255 // Max count fits in u8. Sacrifices the 256th slot to avoid u16 counts.
MIN_RING_SIZE :: 16
MAX_TYPE_DESCRIPTOR_ID :: 254 // 8-bit type_id, 255 (0xFF) is reserved for Supervision Groups
CACHE_LINE_SIZE :: 128
TINA_SIMULATION_MODE :: #config(TINA_SIM, false)
// TINA_DEBUG_ASSERTS used to enable runtime asserts for cases that are fixed behaviour (runtime inputs don't change behaviour)
// but needs verify invariant/structural correctness holds in a non-simulated environment
TINA_DEBUG_ASSERTS :: #config(TINA_ASSERTS, false)

Init_Fn :: #type proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect
Handler_Fn :: #type proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect

// Defines the behavior, memory footprint, and lifecycle functions for a specific Isolate type.
TypeDescriptor :: struct {
	id:                      u8,
	slot_count:              int,
	stride:                  int,
	soa_metadata_size:       int,
	working_memory_size:     int,
	scratch_requirement_max: int,
	mailbox_capacity:        u16, // Mailbox capacity (default: 256). TODO: rename to mailbox_capacity?
	budget_weight:           u16, // (default: 1)
	init_fn:                 Init_Fn,
	handler_fn:              Handler_Fn,
}

Memory_Init_Mode :: enum u8 {
	Production,
	Development,
}

Quarantine_Policy :: enum u8 {
	Quarantine,
	Abort,
}

Watchdog_Config :: struct {
	check_interval_ms: u32,
	phase_2_threshold: u8,
	_padding:          [3]u8,
}

Dio_Config :: struct {
	target_core:          i32,
	submission_ring_size: u32,
	completion_ring_size: u32,
}

// Defines the configuration, resource pools, and root supervision tree for a single Shard (OS thread).
ShardSpec :: struct {
	shard_id:    u8, // TODO: I can turn this later to distinct type
	target_core: i32, // -1 means no specific core (or fallback to shard_id)
	root_group:  Group_Spec, // The root of the supervision tree for this Shard
}

when TINA_SIMULATION_MODE {
	Sim_Config_Mixin :: struct {
		simulation: ^SimulationConfig,
	}
} else {
	Sim_Config_Mixin :: struct {}
}

// The root, compile-time boot specification for the entire Tina process.
// All configuration parameters are immutable after initialization.
SystemSpec :: struct {
	// Process-Wide Parameters
	app_version:               u32,
	memory_init_mode:          Memory_Init_Mode,
	quarantine_policy:         Quarantine_Policy,
	_padding:                  [2]u8,
	init_timeout_ms:           u32,
	shutdown_timeout_ms:       u32,
	safety_margin:             f32,
	watchdog:                  Watchdog_Config,
	dio:                       ^Dio_Config, // nil means DIO disabled

	// Subsystem parameters
	types:                     []TypeDescriptor,
	shard_specs:               []ShardSpec,
	timer_resolution_ns:       u64,
	pool_slot_count:           int,
	reactor_buffer_slot_count: int,
	reactor_buffer_slot_size:  int,
	transfer_slot_count:       int,
	transfer_slot_size:        int,
	timer_spoke_count:         int,
	timer_entry_count:         int,
	fd_table_slot_count:       int,
	fd_entry_size:             int,
	log_ring_size:             int,
	supervision_groups_max:    int,
	scratch_arena_size:        int,
	shard_count:               u8,
	default_ring_size:         u32,
	ring_overrides:            []Ring_Override,

	// Injects `simulation: ^SimulationConfig` ONLY in sim mode.
	using _sim:                Sim_Config_Mixin,
}

SystemSpecError :: enum u8 {
	None,
	ValueOutOfBounds, // Catch-all for sizes/counts too small or too large
	ValueNotPowerOfTwo, // Catch-all for alignment/ring/pool constraints
	DuplicateTypeId,
	InvalidTypeId,
	InvalidSupervisionStrategy,
	InvalidSupervisionIntensity,
}

Supervision_Strategy :: enum u8 {
	One_For_One,
	One_For_All,
	Rest_For_One,
}

Static_Child_Spec :: struct {
	type_id:      u8,
	restart_type: Restart_Type,
	args_size:    u8,
	args_payload: [MAX_INIT_ARGS_SIZE]u8,
}

Group_Spec :: struct {
	strategy:                Supervision_Strategy,
	restart_count_max:       u16,
	window_duration_ticks:   u32,
	children:                []Child_Spec,
	dynamic_child_count_max: u16, // > 0 implies a dynamic one_for_one group
}

Child_Spec :: union {
	Static_Child_Spec,
	Group_Spec,
}

@(private = "package")
validate_system_spec :: proc(spec: ^SystemSpec) -> SystemSpecError {
	// Global & Type Constraints (What you've mostly done)
	if err := _validate_globals_and_types(spec); err != .None do return err

	// SPSC Ring Topology (Checks 8, 9, 16)
	if err := _validate_ring_topology(spec); err != .None do return err

	// Shard & Supervision Tree Rules (Checks 12, 13, 14, 15)
	if err := _validate_shard_specs(spec); err != .None do return err

	// DIO is currently out of scope, but added to SystemSpec (with bootstrap assertion).
	// This validation is to keep the spec validation complete for when it gets implemented
	if err := _validate_dio_config(spec); err != .None do return err

	// Simulation Constraints (Check 20)
	when TINA_SIMULATION_MODE {
		if err := _validate_simulation(spec); err != .None do return err
	}

	// Advisory Warnings (A1 - A6)
	_emit_advisory_warnings(spec)

	return .None
}

@(private = "file")
_validate_globals_and_types :: proc(spec: ^SystemSpec) -> SystemSpecError {
	// Shard Count Validity (ADR Checks 1 & 3)
	if spec.shard_count < 1 || spec.shard_count > MAX_SHARD_COUNT {
		fmt.eprintfln(
			"[FATAL] shard_count must be 1-%v, got %v",
			MAX_SHARD_COUNT,
			spec.shard_count,
		)
		return .ValueOutOfBounds
	}
	if len(spec.shard_specs) != int(spec.shard_count) {
		fmt.eprintfln(
			"[FATAL] shard_specs length (%v) != shard_count (%v)",
			len(spec.shard_specs),
			spec.shard_count,
		)
		return .ValueOutOfBounds
	}

	// Type ID Uniqueness & Bounds (ADR Checks 2, 4, & 5)
	if len(spec.types) < 1 || len(spec.types) > MAX_TYPE_DESCRIPTOR_ID {
		fmt.eprintfln(
			"[FATAL] type_registry: need 1-%v types, got %v",
			MAX_TYPE_DESCRIPTOR_ID,
			len(spec.types),
		)
		return .ValueOutOfBounds
	}

	isolate_types_seen: [256]bool
	scratch_max := 0

	for t in spec.types {
		if t.id > MAX_TYPE_DESCRIPTOR_ID {
			fmt.eprintfln("[FATAL] Type ID %v exceeds max (%v)", t.id, MAX_TYPE_DESCRIPTOR_ID)
			return .InvalidTypeId
		}
		if isolate_types_seen[t.id] {
			fmt.eprintfln("[FATAL] Duplicate type_id: %v", t.id)
			return .DuplicateTypeId
		}
		isolate_types_seen[t.id] = true

		if t.slot_count > MAX_ISOLATES_PER_TYPE {
			fmt.eprintfln(
				"[FATAL] Type ID %v slot_count (%v) exceeds 20-bit max (%v)",
				t.id,
				t.slot_count,
				MAX_ISOLATES_PER_TYPE,
			)
			return .ValueOutOfBounds
		}
		if t.scratch_requirement_max > scratch_max do scratch_max = t.scratch_requirement_max
	}

	// ADR Check 10: Scratch arena adequacy
	if spec.scratch_arena_size < scratch_max {
		fmt.eprintfln(
			"[FATAL] scratch_arena_size (%v) is smaller than max requirement (%v)",
			spec.scratch_arena_size,
			scratch_max,
		)
		return .ValueOutOfBounds
	}

	// ADR Check 7: Power of 2 Constraints
	if spec.pool_slot_count == 0 || (spec.pool_slot_count & (spec.pool_slot_count - 1)) != 0 {
		fmt.eprintfln("[FATAL] pool_slot_count (%v) must be a power of two", spec.pool_slot_count)
		return .ValueNotPowerOfTwo
	}

	if spec.log_ring_size == 0 || (spec.log_ring_size & (spec.log_ring_size - 1)) != 0 {
		fmt.eprintfln("[FATAL] log_ring_size (%v) must be a power of two", spec.log_ring_size)
		return .ValueNotPowerOfTwo
	}

	if spec.timer_spoke_count == 0 ||
	   (spec.timer_spoke_count & (spec.timer_spoke_count - 1)) != 0 {
		fmt.eprintfln(
			"[FATAL] timer_spoke_count (%v) must be a power of two",
			spec.timer_spoke_count,
		)
		return .ValueNotPowerOfTwo
	}

	// 12-bit buffer_index field in Submission_Token; 0x0FFF (4095) is the NONE sentinel
	if spec.reactor_buffer_slot_count > 4094 {
		fmt.eprintfln(
			"[FATAL] reactor_buffer_slot_count (%v) exceeds 12-bit max (4094)",
			spec.reactor_buffer_slot_count,
		)
		return .ValueOutOfBounds
	}

	return .None
}

@(private = "file")
_validate_ring_topology :: proc(spec: ^SystemSpec) -> SystemSpecError {
	if spec.default_ring_size < MIN_RING_SIZE {
		fmt.eprintfln(
			"[FATAL] default_ring_size must be >= %v, got %v",
			MIN_RING_SIZE,
			spec.default_ring_size,
		)
		return .ValueOutOfBounds
	}
	if (spec.default_ring_size & (spec.default_ring_size - 1)) != 0 {
		fmt.eprintfln(
			"[FATAL] default_ring_size (%v) is not a power of two",
			spec.default_ring_size,
		)
		return .ValueNotPowerOfTwo
	}

	for o in spec.ring_overrides {
		if o.size < MIN_RING_SIZE || (o.size & (o.size - 1)) != 0 {
			fmt.eprintfln(
				"[FATAL] Ring override size %v is invalid (must be >= %v and power-of-two)",
				o.size,
				MIN_RING_SIZE,
			)
			return .ValueNotPowerOfTwo
		}

		#partial switch o.type {
		case .Pair, .All_Outbound_From:
			if o.source >= spec.shard_count {
				fmt.eprintfln(
					"[FATAL] Ring override src %v >= shard_count %v",
					o.source,
					spec.shard_count,
				)
				return .ValueOutOfBounds
			}
		}

		#partial switch o.type {
		case .Pair, .All_Inbound_To:
			if o.destination >= spec.shard_count {
				fmt.eprintfln(
					"[FATAL] Ring override dst %v >= shard_count %v",
					o.destination,
					spec.shard_count,
				)
				return .ValueOutOfBounds
			}
		}
	}
	return .None
}

@(private = "file")
_validate_shard_specs :: proc(spec: ^SystemSpec) -> SystemSpecError {
	if spec.timer_resolution_ns == 0 {
		fmt.eprintfln("[FATAL] timer_resolution_ns must be > 0")
		return .ValueOutOfBounds
	}

	// build a mask of valid type IDs to check children against
	// Sized exactly to the maximum possible user type ID + 1
	valid_types: [MAX_TYPE_DESCRIPTOR_ID + 1]bool
	for t in spec.types {
		// We already know from _validate_globals_and_types that t.id <= MAX_TYPE_DESCRIPTOR_ID
		valid_types[t.id] = true
	}

	for &shard_spec in spec.shard_specs {
		if err := _validate_supervision_group(&shard_spec.root_group, &valid_types); err != .None {
			return err
		}
	}
	return .None
}

@(private = "file")
_validate_supervision_group :: proc(
	group: ^Group_Spec,
	valid_types: ^[MAX_TYPE_DESCRIPTOR_ID + 1]bool,
) -> SystemSpecError {
	if group.restart_count_max < 1 {
		fmt.eprintfln("[FATAL] Supervision group max_restarts must be >= 1")
		return .InvalidSupervisionIntensity
	}
	if group.window_duration_ticks == 0 {
		fmt.eprintfln("[FATAL] Supervision group window_duration_ticks must be > 0")
		return .InvalidSupervisionIntensity
	}

	if group.strategy != .One_For_One && group.dynamic_child_count_max > 0 {
		fmt.eprintfln("[FATAL] Only .One_For_One groups may have dynamic children")
		return .InvalidSupervisionStrategy
	}

	for &child in group.children {
		switch &c in child {
		case Static_Child_Spec:
			if !valid_types[c.type_id] {
				fmt.eprintfln("[FATAL] ChildSpec references unregistered type_id: %v", c.type_id)
				return .InvalidTypeId
			}
		case Group_Spec:
			if err := _validate_supervision_group(&c, valid_types); err != .None {
				return err
			}
		}
	}
	return .None
}

@(private = "file")
_emit_advisory_warnings :: proc(spec: ^SystemSpec) {
	// Warning A1: Mailbox Capacity Risk
	theoretical_max_messages: u32 = 0
	for t in spec.types {
		theoretical_max_messages += u32(t.slot_count) * u32(t.mailbox_capacity)
	}

	pool_threshold := u32(spec.pool_slot_count) / 2
	if theoretical_max_messages > pool_threshold {
		fmt.printfln(
			"[WARN] Theoretical max mailbox occupancy (%v) exceeds 50%% of pool capacity (%v). " +
			"Consider increasing pool_slot_count or reducing mailbox_capacity.",
			theoretical_max_messages,
			spec.pool_slot_count,
		)
	}

	// Warning A4: Core Affinity Overlap
	seen_cores: [256]bool
	for s in spec.shard_specs {
		if s.target_core >= 0 && s.target_core < 256 {
			if seen_cores[s.target_core] {
				fmt.printfln(
					"[WARN] Multiple shards target core %v. " +
					"This violates shared-nothing threading under heavy load.",
					s.target_core,
				)
			}
			seen_cores[s.target_core] = true
		}
	}
}

when TINA_SIMULATION_MODE {
	@(private = "file")
	_validate_simulation :: proc(spec: ^SystemSpec) -> SystemSpecError {
		if spec.simulation == nil do return .None

		// ADR Check 20: Uniform timer resolution in simulation
		// Note: In the current SystemSpec, timer_resolution_ns is process-wide,
		// but we validate it here anyway to future-proof against per-shard configs.
		if spec.timer_resolution_ns == 0 {
			fmt.eprintfln("[FATAL] Simulation requires timer_resolution_ns > 0")
			return .ValueOutOfBounds
		}

		// Fault ratio denominators must be non-zero when the numerator is non-zero.
		// A user writing Ratio{1, 0} likely intends 100% but would silently get 0%.
		// Ratio{0, 0} is fine — it means "disabled" (numerator == 0 → always false).
		f := spec.simulation.faults
		_bad_ratio :: proc(r: Ratio) -> bool { return r.numerator > 0 && r.denominator == 0 }
		if _bad_ratio(f.io_error_rate) ||
		   _bad_ratio(f.network_drop_rate) ||
		   _bad_ratio(f.network_partition_rate) ||
		   _bad_ratio(f.network_partition_heal_rate) ||
		   _bad_ratio(f.isolate_crash_rate) ||
		   _bad_ratio(f.init_failure_rate) {
			fmt.eprintfln("[FATAL] Simulation fault ratio has non-zero numerator with zero denominator")
			return .ValueOutOfBounds
		}

		return .None
	}
}

@(private = "file")
_validate_dio_config :: proc(spec: ^SystemSpec) -> SystemSpecError {
	if spec.dio == nil do return .None

	if spec.dio.submission_ring_size == 0 ||
	   (spec.dio.submission_ring_size & (spec.dio.submission_ring_size - 1)) != 0 {
		fmt.eprintfln(
			"[FATAL] DIO submission_ring_size (%v) must be a power of two",
			spec.dio.submission_ring_size,
		)
		return .ValueNotPowerOfTwo
	}
	if spec.dio.completion_ring_size == 0 ||
	   (spec.dio.completion_ring_size & (spec.dio.completion_ring_size - 1)) != 0 {
		fmt.eprintfln(
			"[FATAL] DIO completion_ring_size (%v) must be a power of two",
			spec.dio.completion_ring_size,
		)
		return .ValueNotPowerOfTwo
	}

	// Check 19: Core overlap
	for s in spec.shard_specs {
		if s.target_core == spec.dio.target_core {
			fmt.eprintfln(
				"[FATAL] DIO target_core (%v) conflicts with a Shard's target_core",
				spec.dio.target_core,
			)
			return .ValueOutOfBounds
		}
	}

	return .None
}

// Computes the maximum possible sub-regions carved from the arena
// TODO: I might have to revisit later because we're implementing things incrementally.
// Revisit CONFIGURATION_VALIDATION.md later, perhaps combined with the memory management ADR
compute_max_sub_regions :: proc(spec: ^SystemSpec) -> int {
	types_count := len(spec.types)
	// 3 per type (Typed Arena, SOA Metadata, Working Memory)
	// + 10 static framework regions
	// + 1 for the SubRegion tracker array itself
	// + 2 for the Slice Headers and Dispatch Cursors tracking
	return (types_count * 3) + 10 + 1 + 2
	// FYI: Fixed system regions:
	// 1. Regions Array (SubRegion tracker)
	// 2. Message Pool
	// 3. Reactor Buffer Pool
	// 4. Transfer Buffer Pool
	// 5. Transfer Generations
	// 6. Timer Wheel Spokes
	// 7. Timer Wheel Entries
	// 8. FD Table
	// 9. Log Ring Buffer
	// 10. Supervision Group Table
	// 11. Scratch Arena
}

// Computes an upper-bound capacity aligned to a multiple of 8.
// This guarantees that Odin's #soa memory geometry, which aligns each field's
// slice independently, will never exceed our physical byte budget.
@(private = "package")
_aligned_capacity :: #force_inline proc(count: int) -> int {
	return (count + 7) & ~int(7)
}

// Walks a Group_Spec tree to calculate the exact bytes needed for its dynamic arrays
@(private = "package")
_compute_group_capacity :: proc(group: ^Group_Spec) -> int {
	mem_size := 0
	cap := int(group.dynamic_child_count_max)
	if cap == 0 do cap = len(group.children)

	mem_size += cap * size_of(Handle) // children_handles array
	if group.dynamic_child_count_max > 0 {
		mem_size += cap * size_of(Dynamic_Child_Spec) // dynamic_specs array
	}

	// Recurse for sub-groups
	for i in 0 ..< len(group.children) {
		child_ptr := &group.children[i]
		#partial switch &s in child_ptr {
		case Group_Spec:
			mem_size += _compute_group_capacity(&s)
		}
	}
	return mem_size
}

compute_shard_memory_total :: proc(spec: ^SystemSpec) -> int {
	total := 0
	regions_max := compute_max_sub_regions(spec)

	// In the worst case, every single sub-region allocation requires
	// CACHE_LINE_SIZE - 1 bytes of padding to align.
	padding_overhead := regions_max * CACHE_LINE_SIZE

	for t in spec.types {
		total += t.slot_count * t.stride
		aligned_count := _aligned_capacity(t.slot_count)
		total += aligned_count * t.soa_metadata_size
		total += t.slot_count * t.working_memory_size
	}

	total += spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE
	total += spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size
	total += spec.transfer_slot_count * spec.transfer_slot_size
	total += spec.transfer_slot_count * size_of(u16)
	total += spec.timer_spoke_count * size_of(u32) // Spoke head array
	total += spec.timer_entry_count * size_of(Timer_Entry) // Timer entry pool
	total += spec.fd_table_slot_count * spec.fd_entry_size
	total += spec.log_ring_size
	total += spec.supervision_groups_max * size_of(Supervision_Group)
	total += spec.scratch_arena_size
	total += regions_max * size_of(SubRegion)

	types_count := len(spec.types)
	slice_headers_overhead :=
		types_count *
		(size_of(TypeDescriptor) + size_of([]u8) * 2 + size_of(#soa[]Isolate_Metadata))
	total += slice_headers_overhead
	// Account for the bytes of BOTH u32 arrays: isolate_free_heads AND dispatch_cursors
	total += types_count * size_of(u32) * 2

	// Find the largest supervision tree across all shards and budget for its arrays
	tree_memory_max := 0
	for &s in spec.shard_specs {
		tree_memory := _compute_group_capacity(&s.root_group)
		if tree_memory > tree_memory_max do tree_memory_max = tree_memory
	}
	// We add an extra padding allowance per group to ensure the alignments don't overflow
	total += tree_memory_max + (spec.supervision_groups_max * CACHE_LINE_SIZE)

	return total + padding_overhead
}

// === TESTS ===
@(test)
test_system_spec_validation :: proc(t: ^testing.T) {
	types := [2]TypeDescriptor {
		{id = 1, scratch_requirement_max = 1024},
		{id = 2, scratch_requirement_max = 4096},
	}

	children := [1]Child_Spec {
		Static_Child_Spec{type_id = 1, restart_type = .permanent},
	}
	root_group := Group_Spec {
		strategy              = .One_For_One,
		restart_count_max     = 3,
		window_duration_ticks = 1000,
		children              = children[:],
	}
	shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

	spec := SystemSpec {
		shard_count        = 1,
		types              = types[:],
		shard_specs        = shard_specs[:],
		scratch_arena_size = 2048, // Intentionally too small
		pool_slot_count    = 1024,
		log_ring_size      = 65536,
		timer_spoke_count  = 4096,
		timer_entry_count  = 64,
		timer_resolution_ns = 1_000_000,
		default_ring_size  = 16,
	}

	err := validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)

	spec.scratch_arena_size = 4096 // Exactly enough
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.None)

	// Test timer_spoke_count power-of-2 validation
	spec.timer_spoke_count = 100 // Not power of 2
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.ValueNotPowerOfTwo)

	spec.timer_spoke_count = 4096 // Restore valid value

	// Test reactor_buffer_slot_count exceeds 12-bit token capacity
	spec.reactor_buffer_slot_count = 4095
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)

	spec.reactor_buffer_slot_count = 4094 // Exactly at limit
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.None)

	spec.reactor_buffer_slot_count = 0 // Restore
}

// --- Simulation Configuration ---

Ratio :: struct {
	numerator:   u32,
	denominator: u32,
}

when TINA_SIMULATION_MODE {

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
} else {
	FaultConfig :: struct {}
}

SimulationConfig :: struct {
	seed:                   u64,
	ticks_max:              u64,
	shuffle_shard_order:    bool,
	faults:                 FaultConfig,
	checker_interval_ticks: u32,
	terminate_on_quiescent: bool,
}

// --- Topology / Painter's Algorithm ---

Ring_Override_Type :: enum u8 {
	Pair,
	All_Inbound_To,
	All_Outbound_From,
}

Ring_Override :: struct {
	type:        Ring_Override_Type,
	source:      u8, // Valid for .Pair and .All_Outbound_From
	destination: u8, // Valid for .Pair and .All_Inbound_To
	size:        u32, // Must be power of 2 in production, but used as capacity here
}

// Painter's Algorithm: Computes a 2D matrix of ring capacities.
// Returns a slice of slices: sizes[source_shard][target_shard]
compute_ring_sizes :: proc(
	shard_count: u8,
	default_size: u32,
	overrides: []Ring_Override,
	allocator: mem.Allocator,
) -> [][]u32 {
	sizes := make([][]u32, shard_count, allocator)

	for i in 0 ..< shard_count {
		sizes[i] = make([]u32, shard_count, allocator)
		for j in 0 ..< shard_count {
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
				for i in 0 ..< shard_count {
					if i != o.destination {sizes[i][o.destination] = o.size}
				}
			}
		case .All_Outbound_From:
			if o.source < shard_count {
				for j in 0 ..< shard_count {
					if o.source != j {sizes[o.source][j] = o.size}
				}
			}
		}
	}
	return sizes
}
