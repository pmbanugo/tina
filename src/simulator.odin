package tina

import "core:fmt"
import "core:mem"

when TINA_SIMULATION_MODE {

	Termination_Reason :: enum u8 {
		Ticks_Max,
		Quiescent,
		Checker_Violation,
	}

	Simulator :: struct {
		spec:                    ^SystemSpec,
		allocator:               mem.Allocator,
		shards:                  []Shard, // Allocated as a flat array
		watchdog_states:         []u8, // Backing for Shard.watchdog_state_pointer (bypasses watchdog)
		shard_arena_bytes:       [][]u8,
		control_channels:        []Shard_Control_Channel,
		control_channel_cells:   [][]Shard_Control_Channel_Cell,
		shard_index_order:       []u8,
		shard_count_initialized: int,
		network:                 SimulatedNetwork,
		prng_tree:               Prng_Tree,
		fault_engine:            FaultEngine,
		sim_io_world:            ^Sim_IO_World, // shared IO world — set before shard hydration

		// For fast-forward and clock management
		tick_resolution_ns:      u64,

		// Post-run observable state
		final_round:             u64,
		termination_reason:      Termination_Reason,
	}

	// Simulation is a structural overlay over the production runtime, not a
	// separate scheduler architecture. The harness may replace the clock,
	// transport, and backend implementations, but it must preserve the
	// scheduler-facing contracts those subsystems expose.

	// ============================================================================
	// Simulation Bootstrap (§10.1 in SIMULATION_MODE_DST.md)
	// ============================================================================
	simulator_init :: proc(
		sim: ^Simulator,
		spec: ^SystemSpec,
		allocator: mem.Allocator,
	) -> mem.Allocator_Error {
		error: mem.Allocator_Error
		defer if error != .None {
			simulator_deinit(sim)
		}

		sim.spec = spec
		sim.allocator = allocator
		sim.shards, error = make([]Shard, spec.shard_count, allocator)
		if error != .None do return error
		sim.watchdog_states, error = make([]u8, spec.shard_count, allocator)
		if error != .None do return error
		sim.shard_arena_bytes, error = make([][]u8, spec.shard_count, allocator)
		if error != .None do return error
		sim.control_channels, error = make([]Shard_Control_Channel, spec.shard_count, allocator)
		if error != .None do return error
		sim.control_channel_cells, error = make([][]Shard_Control_Channel_Cell, spec.shard_count, allocator)
		if error != .None do return error
		sim.shard_index_order, error = make([]u8, spec.shard_count, allocator)
		if error != .None do return error

		control_source_count := int(spec.shard_count)
		for target_index in 0 ..< spec.shard_count {
			sim.control_channel_cells[target_index], error = make(
				[]Shard_Control_Channel_Cell,
				control_source_count,
				allocator,
			)
			if error != .None do return error
			shard_control_channel_init(
				&sim.control_channels[target_index],
				control_source_count,
				sim.control_channel_cells[target_index],
			)
		}

		// Use the validated timer resolution from the spec (uniform across all shards)
		sim.tick_resolution_ns = spec.timer_resolution_ns

		// Create a shared IO world for all shard backends — owned by the simulator
		io_world: ^Sim_IO_World
		io_world, error = new(Sim_IO_World, allocator)
		if error != .None do return error
		_sim_world_init(io_world)
		sim.sim_io_world = io_world
		spec.simulation.sim_io_world = cast(rawptr)io_world

		// SI-1: Initialize PRNG Tree
		seed := spec.simulation.seed
		error = prng_tree_init(&sim.prng_tree, seed, int(spec.shard_count), allocator)
		if error != .None do return error

		// SI-3: Initialize Simulated Network
		// Calculate ring sizes using painter's algorithm
		ring_counts: [][]u32
		ring_counts, error = compute_ring_sizes(
			spec.shard_count,
			spec.default_ring_size,
			spec.ring_overrides,
			allocator,
		)
		if error != .None do return error
		defer {
			for row in ring_counts do delete(row, allocator)
			delete(ring_counts, allocator)
		}
		error = sim_network_init(
			&sim.network,
			spec.shard_count,
			ring_counts,
			&sim.prng_tree.network_drop,
			allocator,
		)
		if error != .None do return error

		// SI-5: Initialize Fault Engine
		sim.fault_engine = FaultEngine {
			partition_prng = &sim.prng_tree.partition,
			fault_config   = &spec.simulation.faults,
			network        = &sim.network,
			shard_count    = spec.shard_count,
		}

		// SI-4: Allocate Grand Arenas and Hydrate Shards sequentially (No OS threads!)
		shard_memory_size := compute_shard_memory_total(spec)

		for i in 0 ..< spec.shard_count {
			shard := &sim.shards[i]
			shard.id = Shard_Id(i)
			shard.shard_count = spec.shard_count
			remote_shard_count := int(spec.shard_count) - 1
			shard.outbound_control_channels, error = make([]^Shard_Control_Channel, remote_shard_count, allocator)
			if error != .None do return error
			shard.inbound_control_channel = &sim.control_channels[i]
			for peer_index in 0 ..< spec.shard_count {
				if peer_index == i do continue
				outbound_index := remote_route_index_from_shard_id(Shard_Id(i), Shard_Id(peer_index))
				shard.outbound_control_channels[outbound_index] = &sim.control_channels[peer_index]
			}
			shard.sim_state.network = &sim.network
			shard.sim_state.fault_config = &spec.simulation.faults
			shard.sim_state.crash_prng = &sim.prng_tree.shard_crash[i]

			// Use standard memory allocation for the Grand Arena in simulation
			// (we bypass mmap/guard pages because we are single-threaded and testing logic)
			arena_mem: []u8
			arena_mem, error = make([]u8, shard_memory_size, allocator)
			if error != .None do return error
			sim.shard_arena_bytes[i] = arena_mem

			arena := Grand_Arena{}
			error = grand_arena_init_from_memory(&arena, arena_mem, shard_memory_size)
			if error != .None do return error

			// Hydrate the Shard
			error = hydrate_shard(&arena, spec, shard)
			if error != .None {
				fmt.eprintfln("[SIM FATAL] Failed to hydrate Shard %d: %v", i, error)
				return error
			}

			// Allocate the simulation-only diagnostic table. Capacity is a
			// control-plane resource: handlers write scalar facts while payload
			// memory is live, and tests read them after simulator_run. The table
			// is intentionally not part of the Grand Arena — it belongs to the
			// simulator's control-plane allocator.
			diagnostic_capacity := u32(64)
			if spec.simulation != nil && spec.simulation.diagnostic_record_count_per_shard != 0 {
				diagnostic_capacity = spec.simulation.diagnostic_record_count_per_shard
			}
			shard.diagnostics.records, error = make([]Diagnostic_Record, diagnostic_capacity, allocator)
			if error != .None do return error
			shard.diagnostics.record_count = 0

			sim.shard_count_initialized += 1

			// Wire up watchdog_state_pointer before tree building (ctx_spawn reads it)
			sim.watchdog_states[i] = u8(Shard_State.Running)
			shard.watchdog_state_pointer = &sim.watchdog_states[i]

			// Initialize Supervision Tree
			alloc_data := Grand_Arena_Allocator_Data {
				arena = &arena,
			}
			arena_alloc := grand_arena_allocator(&alloc_data)

			if int(i) < len(spec.shard_specs) {
				build_result, build_error := shard_build_supervision_tree(
					shard,
					&spec.shard_specs[i].root_group,
					arena_alloc,
					&alloc_data,
				)
				if build_error != .None {
					fmt.eprintfln("[SIM FATAL] Failed to build supervision tree for Shard %d: %v", i, build_error)
					error = build_error
					return error
				}
				if build_result != .Ok {
					fmt.eprintfln("[SIM FATAL] Supervision tree build escalated for Shard %d", i)
					error = .Out_Of_Memory
					return error
				}
			}
		}

		return .None
	}

	// ============================================================================
	// Global Simulation Loop (§3 in SIMULATION_MODE_DST.md)
	// ============================================================================
	simulator_run :: proc(sim: ^Simulator) {
		fmt.printfln(
			"[SIM] Starting deterministic simulation. Seed: 0x%16X",
			sim.spec.simulation.seed,
		)

		round: u64 = 0
		ticks_max := sim.spec.simulation.ticks_max
		reason := Termination_Reason.Ticks_Max

		// Reuse the simulator-owned shard order buffer. The simulation loop is not
		// allowed to allocate; only the contents change from round to round.
		order := sim.shard_index_order
		for i in 0 ..< sim.spec.shard_count do order[i] = u8(i)

		loop: for round < ticks_max {
			// Round contract:
			// - every shard ticks exactly once
			// - interleaving diversity comes from execution order, not skipping
			// - all shards observe the same simulated "now" for the round
			// 1. Advance simulated time globally & Fast-Forward Logic
			if sim.spec.simulation.terminate_on_quiescent && simulator_is_globally_idle(sim) {
				earliest_deadline: u64 = max(u64)

				for i in 0 ..< sim.spec.shard_count {
					timer_deadline_tick := timer_earliest_deadline(&sim.shards[i].timer_wheel)
					if timer_deadline_tick != max(u64) {
						if timer_deadline_tick < earliest_deadline do earliest_deadline = timer_deadline_tick
					}
				}

				if earliest_deadline == max(u64) {
					reason = .Quiescent
					break loop
				} else if earliest_deadline > round {
					// Time Travel: Instantly fast-forward to the exact tick the next timer fires
					round = earliest_deadline
				}
			}
			// 2. Fault engine: per-round decisions (partitions, heals, jitter)
			fault_engine_tick(&sim.fault_engine, round)

			// 3. Determine Shard execution order for this round
			if sim.spec.simulation.shuffle_shard_order {
				// Fisher-Yates shuffle using the scheduling PRNG
				for i := u32(sim.spec.shard_count) - 1; i > 0; i -= 1 {
					j := prng_uint_less_than(&sim.prng_tree.scheduling, i + 1)
					order[i], order[j] = order[j], order[i]
				}
			}

			// 4. Tick each Shard exactly once
			for shard_id in order {
				shard := &sim.shards[shard_id]
				// The clock advances synchronously for all shards in the sim
				shard.current_tick = round
				scheduler_tick(shard)
			}

			// 5. Run structural checkers at interval
			if sim.spec.simulation.checker_interval_ticks > 0 &&
			   round % u64(sim.spec.simulation.checker_interval_ticks) == 0 {
				if simulator_run_checkers(sim, round) {
					reason = .Checker_Violation
					break loop
				}
			}

			// 6. Quiescence Check
			if sim.spec.simulation.terminate_on_quiescent {
				if simulator_is_globally_idle(sim) {
					reason = .Quiescent
					break loop
				}
			}

			round += 1
		}

		sim.final_round = round
		sim.termination_reason = reason

		// Unconditional final checker run at simulation end
		if reason != .Checker_Violation {
			if simulator_run_checkers(sim, round) {
				sim.termination_reason = .Checker_Violation
			}
		}

		simulator_print_summary(sim)
	}

	// ============================================================================
	// Simulation Teardown
	// ============================================================================
	simulator_deinit :: proc(sim: ^Simulator) {
		if sim == nil || sim.allocator.procedure == nil {
			return
		}

	for shard_index in 0 ..< sim.shard_count_initialized {
		reactor_deinit(&sim.shards[shard_index].reactor)
		_sanitizer_address_unpoison_shard_memory(&sim.shards[shard_index])
		delete(sim.shards[shard_index].diagnostics.records, sim.allocator)
		delete(sim.shards[shard_index].outbound_control_channels, sim.allocator)
	}

		// Partially-hydrated shards: hydration failed after ASan poison was
		// applied but before shard_count_initialized was incremented. The
		// backing arena contains poisoned subregions that must be unpoisoned
		// before the raw bytes are freed. Structured unpoison iteration
		// would be unsafe on partially-built metadata, so we unpoison
		// the entire backing allocation as a single raw region.
		for shard_index in sim.shard_count_initialized ..< len(sim.shard_arena_bytes) {
			arena_bytes := sim.shard_arena_bytes[shard_index]
			if len(arena_bytes) > 0 {
				_sanitizer_address_unpoison_raw(raw_data(arena_bytes), len(arena_bytes))
				reactor_deinit(&sim.shards[shard_index].reactor)
				delete(sim.shards[shard_index].outbound_control_channels, sim.allocator)
			}
		}

		sim_network_deinit(&sim.network, sim.allocator)
		prng_tree_deinit(&sim.prng_tree, sim.allocator)
		for target_index in 0 ..< len(sim.control_channel_cells) {
			delete(sim.control_channel_cells[target_index], sim.allocator)
		}

		for shard_arena_bytes in sim.shard_arena_bytes {
			if len(shard_arena_bytes) > 0 {
				delete(shard_arena_bytes, sim.allocator)
			}
		}
		delete(sim.shard_arena_bytes, sim.allocator)
		delete(sim.control_channel_cells, sim.allocator)
		delete(sim.control_channels, sim.allocator)
		delete(sim.shard_index_order, sim.allocator)
		delete(sim.watchdog_states, sim.allocator)
		delete(sim.shards, sim.allocator)

		if sim.sim_io_world != nil {
			free(sim.sim_io_world, sim.allocator)
		}

		if sim.spec != nil && sim.spec.simulation != nil {
			sim.spec.simulation.sim_io_world = nil
		}

		sim^ = {}
	}

	// ============================================================================
	// End-of-Simulation Summary
	// ============================================================================
	@(private = "file")
	simulator_print_summary :: proc(sim: ^Simulator) {
		reason_label: string
		switch sim.termination_reason {
		case .Ticks_Max:
			reason_label = "maximum ticks reached"
		case .Quiescent:
			reason_label = "quiescent (no pending work or timers)"
		case .Checker_Violation:
			reason_label = "checker violation"
		}

		fmt.printfln(
			"[SIM] Simulation complete: seed=0x%16X, rounds=%d, termination=%s",
			sim.spec.simulation.seed,
			sim.final_round,
			reason_label,
		)

		// Aggregate counters across shards
		total_stale_delivery: u64 = 0
		total_ring_full: u64 = 0
		total_quarantine: u64 = 0
		total_pool_exhaustion: u64 = 0
		total_mailbox_full: u64 = 0
		total_io_receive_exhaustion: u64 = 0
		total_io_staging_exhaustion: u64 = 0
		total_io_stale: u64 = 0
		total_transfer_exhaustion: u64 = 0
		total_transfer_stale: u64 = 0

		for i in 0 ..< sim.spec.shard_count {
			c := &sim.shards[i].counters
			total_stale_delivery += c.stale_delivery_drops
			total_ring_full += c.ring_full_drops
			total_quarantine += c.quarantine_drops
			total_pool_exhaustion += c.pool_exhaustion_drops
			total_mailbox_full += c.mailbox_full_drops
			total_io_receive_exhaustion += c.io_receive_exhaustions
			total_io_staging_exhaustion += c.io_staging_exhaustions
			total_io_stale += c.io_stale_completions
			total_transfer_exhaustion += c.transfer_exhaustions
			total_transfer_stale += c.transfer_stale_reads
		}

		fmt.printfln(
			"[SIM] Backpressure: mailbox_full=%d, pool_exhaustion=%d, ring_full=%d, stale_delivery=%d, quarantine=%d",
			total_mailbox_full,
			total_pool_exhaustion,
			total_ring_full,
			total_stale_delivery,
			total_quarantine,
		)
		fmt.printfln(
			"[SIM] I/O: stale_completions=%d, receive_exhaustions=%d, staging_exhaustions=%d, transfer_exhaustions=%d, transfer_stale=%d",
			total_io_stale,
			total_io_receive_exhaustion,
			total_io_staging_exhaustion,
			total_transfer_exhaustion,
			total_transfer_stale,
		)
	}
}
