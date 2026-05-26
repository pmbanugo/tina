package tina

import "core:fmt"
import "core:mem"
import "core:testing"

Shard_Id :: distinct u8
Isolate_Type_Id :: distinct u16
MAX_SHARD_COUNT :: 255 // Max count fits in u8. Sacrifices the 256th slot to avoid u16 counts.
REMOTE_SHARD_COUNT_MAX :: MAX_SHARD_COUNT - 1
MIN_RING_SIZE :: 16
MAX_TYPE_DESCRIPTOR_ID :: 254 // 8-bit type_id, 255 (0xFF) is reserved for Supervision Groups
CACHE_LINE_SIZE :: 128
TINA_SIMULATION_MODE :: #config(TINA_SIM, false)
// TINA_DEBUG_ASSERTS used to enable runtime asserts for cases that are fixed behaviour (runtime inputs don't change behaviour)
// but needs verify invariant/structural correctness holds in a non-simulated environment
TINA_RUNTIME_ASSERTIONS :: #config(TINA_ASSERTS, true)
TINA_ODIN_DEV :: #config(ODIN_DEV, false)

Scheduler_Work_Count :: distinct u32
Scheduler_Credit_Count :: distinct u32
Scheduler_Weight_Count :: distinct u16
Scheduler_Type_Index :: distinct u16
Reactor_Batch_Count :: distinct u16

when TINA_ODIN_DEV {
	SCHEDULER_TURN_WORK_BUDGET_COUNT_DEFAULT :: 512
	SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX_DEFAULT :: 64
	SCHEDULER_CREDIT_PER_WEIGHT_COUNT_DEFAULT :: 64
	SCHEDULER_CREDIT_COUNT_MAX_DEFAULT :: 256
	SCHEDULER_IO_SERVICE_INTERVAL_COUNT_DEFAULT :: 64
} else {
	SCHEDULER_TURN_WORK_BUDGET_COUNT_DEFAULT :: 2048
	SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX_DEFAULT :: 256
	SCHEDULER_CREDIT_PER_WEIGHT_COUNT_DEFAULT :: 256
	SCHEDULER_CREDIT_COUNT_MAX_DEFAULT :: 1024
	// How many dispatches between I/O service points inside a single scheduler turn.
	// Lower values reduce I/O completion latency (faster wakeup for Isolates waiting on I/O).
	// Higher values reduce syscall overhead on BSD/kqueue (~13us per kevent poll on macOS M1).
	// On Linux io_uring, the cost is near-zero (~3ns shared-memory read) when no I/O is in
	// flight, so this value primarily affects BSD. The service point is also gated on
	// io_awaiting_count > 0, meaning idle ticks skip the poll entirely regardless of interval.
	SCHEDULER_IO_SERVICE_INTERVAL_COUNT_DEFAULT :: 128
}

SCHEDULER_TURN_WORK_BUDGET_COUNT :: #config(
	TINA_SCHEDULER_TURN_WORK_BUDGET_COUNT,
	SCHEDULER_TURN_WORK_BUDGET_COUNT_DEFAULT,
)
SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX :: #config(
	TINA_SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX,
	SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX_DEFAULT,
)
SCHEDULER_CREDIT_PER_WEIGHT_COUNT :: #config(
	TINA_SCHEDULER_CREDIT_PER_WEIGHT_COUNT,
	SCHEDULER_CREDIT_PER_WEIGHT_COUNT_DEFAULT,
)
SCHEDULER_CREDIT_COUNT_MAX :: #config(
	TINA_SCHEDULER_CREDIT_COUNT_MAX,
	SCHEDULER_CREDIT_COUNT_MAX_DEFAULT,
)
SCHEDULER_IO_SERVICE_INTERVAL_COUNT :: #config(
	TINA_SCHEDULER_IO_SERVICE_INTERVAL_COUNT,
	SCHEDULER_IO_SERVICE_INTERVAL_COUNT_DEFAULT,
)

// Maximum submissions accumulated before flushing to the backend.
// Must be large enough to batch efficiently (io_uring: 31ns/op at 256 SQEs vs 332ns at 1),
// but small enough to bound latency for pending completions.
REACTOR_SUBMISSION_BATCH_COUNT :: #config(TINA_REACTOR_SUBMISSION_BATCH_COUNT, 256)
// Maximum completions harvested per collect call. Sized symmetrically with submissions.
// On Linux, copy_cqes reads shared memory at ~3ns when empty. On BSD, each kevent poll
// costs ~13us regardless of result count, so larger batches amortize that floor cost.
REACTOR_COMPLETION_BATCH_COUNT :: #config(TINA_REACTOR_COMPLETION_BATCH_COUNT, 256)
// Trigger an early flush when pending submissions reach this count during dispatch,
// rather than waiting for the end-of-turn flush at Step 4. Set to 75% of the
// submission batch to balance latency (flush sooner) against batch efficiency
// (fewer flushes per turn).
REACTOR_SUBMISSION_FLUSH_THRESHOLD_COUNT :: #config(TINA_REACTOR_SUBMISSION_FLUSH_THRESHOLD_COUNT, 192)
// BSD/kqueue only: after this many consecutive EAGAIN/EWOULDBLOCK results on a
// stream direction, skip the optimistic syscall and register readiness directly.
// Lower values reduce wasted syscalls under congestion; higher values preserve
// the cheap immediate-success path for bursty sockets.
//
// Tuning: a failed optimistic recv costs ~288ns (macOS M1 Pro). After 2 consecutive
// failures the backend skips the try and goes straight to kevent registration (~280ns).
// Value of 1 is aggressive (one failure = skip); 3+ keeps trying longer but wastes
// more cycles under sustained congestion. Default 2 balances responsiveness vs waste.
REACTOR_POSIX_OPTIMISTIC_SKIP_DEFERRED_STREAK_COUNT :: #config(
	TINA_REACTOR_POSIX_OPTIMISTIC_SKIP_DEFERRED_STREAK_COUNT,
	2,
)
// BSD/kqueue write side only: after this many successful write-readiness cycles,
// keep the write filter armed with EV_CLEAR instead of re-registering ONESHOT.
// Reads intentionally stay ONESHOT because Tina currently performs one read per
// completion; unread bytes could otherwise remain without a new edge.
//
// Tuning: EV_CLEAR saves ~440-500ns per cycle vs ONESHOT re-registration (macOS M1
// Pro: EV_CLEAR cycle ~997ns, ONESHOT cycle ~1441ns). The threshold counts successful
// write-readiness events before switching to EV_CLEAR. Default 2 means the FD must
// produce two consecutive ready events before upgrading. Higher values delay the
// transition and are more conservative. Read-side EV_CLEAR is deliberately disabled
// because Tina's one-read-per-completion model may leave unread bytes in the socket,
// and kqueue would not produce another edge for those remaining bytes.
REACTOR_POSIX_WRITE_EDGE_CLEAR_READY_STREAK_COUNT :: #config(
	TINA_REACTOR_POSIX_WRITE_EDGE_CLEAR_READY_STREAK_COUNT,
	2,
)
REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT_DEFAULT :: REACTOR_SUBMISSION_BATCH_COUNT
REACTOR_LINUX_SENDFILE_ENTRY_COUNT_DEFAULT :: (REACTOR_SUBMISSION_BATCH_COUNT + 7) / 8
REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT :: #config(
	TINA_REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT,
	REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT_DEFAULT,
)
REACTOR_LINUX_SENDFILE_ENTRY_COUNT :: #config(
	TINA_REACTOR_LINUX_SENDFILE_ENTRY_COUNT,
	REACTOR_LINUX_SENDFILE_ENTRY_COUNT_DEFAULT,
)

#assert(size_of(Shard_Id) == 1)
#assert(size_of(Isolate_Type_Id) == 2)
#assert(MAX_SHARD_COUNT > 0)
#assert(MAX_SHARD_COUNT == 255)
#assert(REMOTE_SHARD_COUNT_MAX == MAX_SHARD_COUNT - 1)
#assert(REMOTE_SHARD_COUNT_MAX > 0)
#assert(MIN_RING_SIZE > 0)
#assert((MIN_RING_SIZE & (MIN_RING_SIZE - 1)) == 0)
#assert(SCHEDULER_TURN_WORK_BUDGET_COUNT > 0)
#assert(SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX > 0)
#assert(SCHEDULER_CREDIT_PER_WEIGHT_COUNT > 0)
#assert(SCHEDULER_CREDIT_COUNT_MAX > 0)
#assert(SCHEDULER_IO_SERVICE_INTERVAL_COUNT > 0)
#assert(SCHEDULER_TURN_WORK_BUDGET_COUNT <= int(max(u32)))
#assert(SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX <= int(max(u32)))
#assert(SCHEDULER_CREDIT_PER_WEIGHT_COUNT <= int(max(u32)))
#assert(SCHEDULER_CREDIT_COUNT_MAX <= int(max(u32)))
#assert(SCHEDULER_IO_SERVICE_INTERVAL_COUNT <= int(max(u32)))
#assert(REACTOR_SUBMISSION_BATCH_COUNT > 0)
#assert(REACTOR_COMPLETION_BATCH_COUNT > 0)
#assert(REACTOR_SUBMISSION_BATCH_COUNT <= int(max(u16)))
#assert(REACTOR_COMPLETION_BATCH_COUNT <= int(max(u16)))
#assert(REACTOR_SUBMISSION_FLUSH_THRESHOLD_COUNT > 0)
#assert(REACTOR_SUBMISSION_FLUSH_THRESHOLD_COUNT <= REACTOR_SUBMISSION_BATCH_COUNT)
#assert(REACTOR_POSIX_OPTIMISTIC_SKIP_DEFERRED_STREAK_COUNT > 0)
#assert(REACTOR_POSIX_OPTIMISTIC_SKIP_DEFERRED_STREAK_COUNT <= int(max(u8)))
#assert(REACTOR_POSIX_WRITE_EDGE_CLEAR_READY_STREAK_COUNT > 0)
#assert(REACTOR_POSIX_WRITE_EDGE_CLEAR_READY_STREAK_COUNT <= int(max(u8)))
#assert(REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT > 0)
#assert(REACTOR_LINUX_PENDING_ADDR_ENTRY_COUNT <= int(max(u16)))
#assert(REACTOR_LINUX_SENDFILE_ENTRY_COUNT > 0)
#assert(REACTOR_LINUX_SENDFILE_ENTRY_COUNT <= int(max(u16)))

Init_Handler :: #type proc(self: rawptr, args: []u8, ctx: TinaContext) -> Effect
Handler_Fn :: #type proc(self: rawptr, message: ^Message, ctx: TinaContext) -> Effect

// Defines the behavior, memory footprint, and lifecycle functions for a specific Isolate type.
IsolateTypeDescriptor :: struct {
	id:                      Isolate_Type_Id,
	slot_count:              int,
	stride:                  int,
	soa_metadata_size:       int,
	working_memory_size:     int,
	scratch_requirement_max: int,
	mailbox_capacity:        u16, // Mailbox capacity (default: 256). TODO: rename to mailbox_capacity?
	budget_weight:           u16, // (default: 1)
	init_handler:            Init_Handler,
	handler_fn:              Handler_Fn,
}

Memory_Init_Mode :: enum u8 {
	Production, // Pin to core, NUMA bind, HugePages, pre-fault.
	Development, // Lazy commit (OS-default).
}

Quarantine_Policy :: enum u8 {
	Quarantine,
	Abort,
}

Watchdog_Config :: struct {
	check_interval_ms:       u32,
	shard_restart_window_ms: u32,
	shard_restart_max:       u16,
	phase_2_threshold:       u8,
	_padding:                u8,
}

Dio_Config :: struct {
	target_core:          i32,
	submission_ring_size: u32,
	completion_ring_size: u32,
}

// Defines the configuration, resource pools, and root supervision tree for a single Shard (OS thread).
ShardSpec :: struct {
	shard_id:    Shard_Id,
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
	types:                     []IsolateTypeDescriptor,
	shard_specs:               []ShardSpec,
	timer_resolution_ns:       u64,
	pool_slot_count:           int,
	reactor_buffer_slot_count: int,
	reactor_buffer_slot_size:  int,
	transfer_slot_count:       int,
	transfer_slot_size:        int,
	fd_handoff_entry_count:    int,
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
	UnsupportedPlatform,
}

Supervision_Strategy :: enum u8 {
	One_For_One,
	One_For_All,
	Rest_For_One,
}

Static_Child_Spec :: struct {
	type_id:      Isolate_Type_Id,
	restart_type: Restart_Type,
	args_size:    u8,
	args_payload: [MAX_INIT_ARGS_SIZE]u8,
}

Group_Spec :: struct {
	strategy:                Supervision_Strategy,
	restart_count_max:       u16,
	window_duration_ticks:   u32,
	children:                []Child_Spec,
	child_count_dynamic_max: u16, // > 0 implies a dynamic one_for_one group
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

	for t, type_index in spec.types {
		if u16(t.id) > MAX_TYPE_DESCRIPTOR_ID {
			fmt.eprintfln("[FATAL] Type ID %v exceeds max (%v)", t.id, MAX_TYPE_DESCRIPTOR_ID)
			return .InvalidTypeId
		}

		expected_type_id := Isolate_Type_Id(type_index)
		if t.id != expected_type_id {
			fmt.eprintfln(
				"[FATAL] Type ID %v must equal dense descriptor index %v",
				t.id,
				expected_type_id,
			)
			return .InvalidTypeId
		}

		if isolate_types_seen[u16(t.id)] {
			fmt.eprintfln("[FATAL] Duplicate type_id: %v", t.id)
			return .DuplicateTypeId
		}
		isolate_types_seen[u16(t.id)] = true

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

	// 12-bit buffer_index field in Submission_Token; 0x0FFF (4095) is the NONE sentinel
	if spec.reactor_buffer_slot_count > 4094 {
		fmt.eprintfln(
			"[FATAL] reactor_buffer_slot_count (%v) exceeds 12-bit max (4094)",
			spec.reactor_buffer_slot_count,
		)
		return .ValueOutOfBounds
	}

	if spec.fd_handoff_entry_count < 0 ||
	   spec.fd_handoff_entry_count > int(FD_HANDOFF_NONE_INDEX) - 1 {
		fmt.eprintfln(
			"[FATAL] fd_handoff_entry_count (%v) must be 0-%v",
			spec.fd_handoff_entry_count,
			int(FD_HANDOFF_NONE_INDEX) - 1,
		)
		return .ValueOutOfBounds
	}

	when !TINA_SIMULATION_MODE {
		when ODIN_OS == .Windows {
			if spec.shard_count > 1 && spec.fd_handoff_entry_count > 0 {
				fmt.eprintfln(
					"[FATAL] cross-shard FD handoff is unsupported on Windows in this version",
				)
				return .UnsupportedPlatform
			}
		}
	}

	if spec.shard_count > 1 && spec.fd_handoff_entry_count == 0 {
		fmt.eprintfln(
			"[WARN] shard_count > 1 but fd_handoff_entry_count is 0 — cross-shard FD handoff is disabled",
		)
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
			if o.source >= Shard_Id(spec.shard_count) {
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
			if o.destination >= Shard_Id(spec.shard_count) {
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

	if group.strategy != .One_For_One && group.child_count_dynamic_max > 0 {
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

		sim := spec.simulation

		// ticks_max must be > 0
		if sim.ticks_max == 0 {
			fmt.eprintfln("[FATAL] Simulation ticks_max must be > 0")
			return .ValueOutOfBounds
		}

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
		f := sim.faults
		_bad_ratio :: proc(r: Ratio) -> bool {return r.numerator > 0 && r.denominator == 0}
		if _bad_ratio(f.io_error_rate) ||
		   _bad_ratio(f.network_drop_rate) ||
		   _bad_ratio(f.network_partition_rate) ||
		   _bad_ratio(f.network_partition_heal_rate) ||
		   _bad_ratio(f.isolate_crash_rate) ||
		   _bad_ratio(f.init_failure_rate) {
			fmt.eprintfln(
				"[FATAL] Simulation fault ratio has non-zero numerator with zero denominator",
			)
			return .ValueOutOfBounds
		}

		// Numerator must not exceed denominator (would mean > 100% probability)
		_over_ratio :: proc(r: Ratio) -> bool {
			return r.denominator > 0 && r.numerator > r.denominator
		}
		if _over_ratio(f.io_error_rate) ||
		   _over_ratio(f.network_drop_rate) ||
		   _over_ratio(f.network_partition_rate) ||
		   _over_ratio(f.network_partition_heal_rate) ||
		   _over_ratio(f.isolate_crash_rate) ||
		   _over_ratio(f.init_failure_rate) {
			fmt.eprintfln("[FATAL] Simulation fault ratio has numerator exceeding denominator")
			return .ValueOutOfBounds
		}

		// Delay range validation: min <= max
		if f.io_delay_range_ticks[0] > f.io_delay_range_ticks[1] && f.io_delay_range_ticks[1] > 0 {
			fmt.eprintfln(
				"[FATAL] Simulation io_delay_range_ticks min (%v) > max (%v)",
				f.io_delay_range_ticks[0],
				f.io_delay_range_ticks[1],
			)
			return .ValueOutOfBounds
		}
		if f.network_delay_range_ticks[0] > f.network_delay_range_ticks[1] &&
		   f.network_delay_range_ticks[1] > 0 {
			fmt.eprintfln(
				"[FATAL] Simulation network_delay_range_ticks min (%v) > max (%v)",
				f.network_delay_range_ticks[0],
				f.network_delay_range_ticks[1],
			)
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
	// 3 per type (Typed Arena, Isolate Metadata, Working Memory)
	// + 23 static framework regions, including the SubRegion tracker array.
	return (types_count * 3) + 23
	// FYI: Fixed system regions:
	// 1. Regions Array (SubRegion tracker)
	// 2-6. Slice headers for IsolateTypeDescriptor/isolate/working/metadata/free-head arrays
	// 7. Dispatch Cursors
	// 8. Dispatch Credit Counts
	// 9. Message Pool
	// 10. Transfer Buffer Pool
	// 11. Transfer Generations
	// 12. FD Handoff Table
	// 13. Timer Wheel Deadlines
	// 14. Timer Wheel Targets
	// 15. Timer Wheel Tags
	// 16. Timer Wheel Correlations
	// 17. Timer Wheel Armed Words
	// 18. Log Ring Buffer
	// 19. Supervision Group Table
	// 20. Scratch Arena
	// 21. FD Table
	// 22. Reactor Buffer Pool
	// 23. Spare fixed region for optional platform/runtime allocation
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
	cap := len(group.children) + int(group.child_count_dynamic_max)

	mem_size += cap * size_of(Handle) // children_handles array
	if group.child_count_dynamic_max > 0 {
		mem_size += int(group.child_count_dynamic_max) * size_of(Dynamic_Child_Spec)
	}

	// Recurse for sub-groups
	for i in 0 ..< len(group.children) {
		child_pointer := &group.children[i]
		#partial switch &s in child_pointer {
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
		total += _dispatch_word_count(t.slot_count) * size_of(u64)
	}

	total += spec.pool_slot_count * MESSAGE_ENVELOPE_SIZE
	total += spec.reactor_buffer_slot_count * spec.reactor_buffer_slot_size
	total += spec.transfer_slot_count * spec.transfer_slot_size
	total += spec.transfer_slot_count * size_of(u16)
	total += spec.fd_handoff_entry_count * size_of(FD_Handoff_Entry)
	total += spec.timer_entry_count * size_of(u64)            // deadlines
	total += spec.timer_entry_count * size_of(Handle)          // targets
	total += spec.timer_entry_count * size_of(Message_Tag)     // tags
	total += spec.timer_entry_count * size_of(Correlation_Id)  // correlations
	total += bitmap_word_count_from_bit_count(spec.timer_entry_count) * size_of(u64) // armed_words
	total += spec.fd_table_slot_count * spec.fd_entry_size
	total += spec.log_ring_size
	total += spec.supervision_groups_max * size_of(Supervision_Group)
	total += spec.scratch_arena_size
	total += regions_max * size_of(SubRegion)

	types_count := len(spec.types)
	slice_headers_overhead :=
		types_count *
		(size_of(IsolateTypeDescriptor) + size_of([]u8) * 2 + size_of(#soa[]Isolate_Metadata))
	total += slice_headers_overhead
	// Account for scheduler/type arrays: isolate_free_heads, dispatch_cursors, and dispatch_credit_counts.
	total += types_count * size_of(u32) * 2
	total += types_count * size_of(Scheduler_Credit_Count)
	total += types_count * size_of([]u64)
	total += types_count * size_of(u32)
	total += _dispatch_word_count(types_count) * size_of(u64)
	total += _dispatch_word_count(types_count) * size_of(u64)

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
	types := [2]IsolateTypeDescriptor {
		{id = 0, scratch_requirement_max = 1024},
		{id = 1, scratch_requirement_max = 4096},
	}

	children := [1]Child_Spec{Static_Child_Spec{type_id = 0, restart_type = .permanent}}
	root_group := Group_Spec {
		strategy              = .One_For_One,
		restart_count_max     = 3,
		window_duration_ticks = 1000,
		children              = children[:],
	}
	shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

	spec := SystemSpec {
		shard_count         = 1,
		types               = types[:],
		shard_specs         = shard_specs[:],
		scratch_arena_size  = 2048, // Intentionally too small
		pool_slot_count     = 1024,
		log_ring_size       = 65536,
		timer_entry_count   = 64,
		timer_resolution_ns = 1_000_000,
		default_ring_size   = 16,
	}

	err := validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)

	spec.scratch_arena_size = 4096 // Exactly enough
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.None)

	// Test reactor_buffer_slot_count exceeds 12-bit token capacity
	spec.reactor_buffer_slot_count = 4095
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)

	spec.reactor_buffer_slot_count = 4094 // Exactly at limit
	err = validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.None)

	spec.reactor_buffer_slot_count = 0 // Restore

	when !TINA_SIMULATION_MODE {
		when ODIN_OS == .Windows {
			spec.shard_count = 2
			win_shards := [2]ShardSpec {
				{shard_id = 0, root_group = root_group},
				{shard_id = 1, root_group = root_group},
			}
			spec.shard_specs = win_shards[:]
			spec.fd_handoff_entry_count = 4
			err = validate_system_spec(&spec)
			testing.expect_value(t, err, SystemSpecError.UnsupportedPlatform)
		}
	}
}

@(test)
test_system_spec_validation_rejects_non_dense_type_ids :: proc(t: ^testing.T) {
	types := [2]IsolateTypeDescriptor {
		{id = 0},
		{id = 2},
	}

	children := [1]Child_Spec{Static_Child_Spec{type_id = 0, restart_type = .permanent}}
	root_group := Group_Spec {
		strategy              = .One_For_One,
		restart_count_max     = 1,
		window_duration_ticks = 1,
		children              = children[:],
	}
	shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

	spec := SystemSpec {
		shard_count         = 1,
		types               = types[:],
		shard_specs         = shard_specs[:],
		scratch_arena_size  = 1,
		pool_slot_count     = 16,
		log_ring_size       = 16,
		timer_entry_count   = 16,
		default_ring_size   = 16,
	}

	err := validate_system_spec(&spec)
	testing.expect_value(t, err, SystemSpecError.InvalidTypeId)
}

when TINA_SIMULATION_MODE {
	@(test)
	test_simulation_config_validation :: proc(t: ^testing.T) {
		types := [1]IsolateTypeDescriptor{{id = 0, scratch_requirement_max = 0}}

		children := [1]Child_Spec{Static_Child_Spec{type_id = 0, restart_type = .permanent}}
		root_group := Group_Spec {
			strategy              = .One_For_One,
			restart_count_max     = 3,
			window_duration_ticks = 1000,
			children              = children[:],
		}
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		// Base valid simulation config
		sim_config := SimulationConfig {
			seed             = 42,
			ticks_max        = 1000,
			builtin_checkers = CHECKER_FLAGS_ALL,
		}

		spec := SystemSpec {
			shard_count         = 1,
			types               = types[:],
			shard_specs         = shard_specs[:],
			pool_slot_count     = 1024,
			log_ring_size       = 4096,
			timer_entry_count   = 64,
			timer_resolution_ns = 1_000_000,
			default_ring_size   = 16,
			simulation          = &sim_config,
		}

		// Valid config should pass
		err := validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.None)

		// ticks_max = 0 should fail
		sim_config.ticks_max = 0
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)
		sim_config.ticks_max = 1000

		// Bad ratio: numerator > 0 with denominator = 0
		sim_config.faults.io_error_rate = Ratio{1, 0}
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)
		sim_config.faults.io_error_rate = Ratio{0, 0} // disabled, OK

		// Bad ratio: numerator > denominator
		sim_config.faults.network_drop_rate = Ratio{10, 5}
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)
		sim_config.faults.network_drop_rate = Ratio{0, 1}

		// Bad delay range: min > max (with max > 0)
		sim_config.faults.io_delay_range_ticks = {10, 5}
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)
		sim_config.faults.io_delay_range_ticks = {0, 0}

		// Bad network delay range: min > max
		sim_config.faults.network_delay_range_ticks = {100, 50}
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.ValueOutOfBounds)
		sim_config.faults.network_delay_range_ticks = {0, 0}

		// Valid delay range: min == max is OK
		sim_config.faults.io_delay_range_ticks = {5, 5}
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.None)
		sim_config.faults.io_delay_range_ticks = {0, 0}

		// Valid ratio: numerator == denominator (100%)
		sim_config.faults.io_error_rate = Ratio{100, 100}
		err = validate_system_spec(&spec)
		testing.expect_value(t, err, SystemSpecError.None)
		sim_config.faults.io_error_rate = Ratio{0, 0}
	}
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

Checker_Fn :: #type proc(shards: []Shard, tick: u64) -> Check_Result

Check_Result :: union {
	Check_Ok,
	Check_Violation,
}

Check_Ok :: struct {}

Check_Violation :: struct {
	message: string,
}

Checker_Flags :: bit_set[Checker_Flag;u16]

Checker_Flag :: enum u8 {
	Pool_Integrity,
	Generation_Monotonic,
	FD_Table_Integrity,
	FD_Handoff_Integrity,
	Sim_FD_Integrity,
}

CHECKER_FLAGS_ALL :: Checker_Flags {
	.Pool_Integrity,
	.Generation_Monotonic,
	.FD_Table_Integrity,
	.FD_Handoff_Integrity,
	.Sim_FD_Integrity,
}
CHECKER_FLAGS_NONE :: Checker_Flags{}

SimulationConfig :: struct {
	seed:                   u64,
	ticks_max:              u64,
	single_threaded:        bool,
	shuffle_shard_order:    bool,
	terminate_on_quiescent: bool,
	faults:                 FaultConfig,
	builtin_checkers:       Checker_Flags,
	user_checkers:          []Checker_Fn,
	checker_interval_ticks: u32,
	sim_io_world:           rawptr, // ^Sim_IO_World; set by simulator_init before hydration
}

// --- Topology / Painter's Algorithm ---

Ring_Override_Type :: enum u8 {
	Pair,
	All_Inbound_To,
	All_Outbound_From,
}

Ring_Override :: struct {
	type:        Ring_Override_Type,
	source:      Shard_Id, // Valid for .Pair and .All_Outbound_From
	destination: Shard_Id, // Valid for .Pair and .All_Inbound_To
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
			if o.source < Shard_Id(shard_count) &&
			   o.destination < Shard_Id(shard_count) &&
			   o.source != o.destination {
				sizes[o.source][o.destination] = o.size
			}
		case .All_Inbound_To:
			if o.destination < Shard_Id(shard_count) {
				for i in 0 ..< shard_count {
					if Shard_Id(i) != o.destination {sizes[i][o.destination] = o.size}
				}
			}
		case .All_Outbound_From:
			if o.source < Shard_Id(shard_count) {
				for j in 0 ..< shard_count {
					if o.source != Shard_Id(j) {sizes[o.source][j] = o.size}
				}
			}
		}
	}
	return sizes
}
