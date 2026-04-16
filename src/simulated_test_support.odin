package tina

when TINA_SIMULATION_MODE {
	Sim_Test_Spec_Options :: struct {
		pool_slot_count:           int,
		reactor_buffer_slot_count: int,
		reactor_buffer_slot_size:  int,
		transfer_slot_count:       int,
		transfer_slot_size:        int,
		fd_handoff_entry_count:    int,
		timer_spoke_count:         int,
		timer_entry_count:         int,
		timer_resolution_ns:       u64,
		fd_table_slot_count:       int,
		log_ring_size:             int,
		supervision_groups_max:    int,
		scratch_arena_size:        int,
		default_ring_size:         u32,
	}

	SIM_TEST_SPEC_DEFAULTS :: Sim_Test_Spec_Options {
		pool_slot_count = 256,
		reactor_buffer_slot_count = 4,
		reactor_buffer_slot_size = 1024,
		transfer_slot_count = 4,
		transfer_slot_size = 1024,
		fd_handoff_entry_count = 0,
		timer_spoke_count = 64,
		timer_entry_count = 64,
		timer_resolution_ns = 1_000_000,
		fd_table_slot_count = 16,
		log_ring_size = 4096,
		supervision_groups_max = 4,
		scratch_arena_size = 8192,
		default_ring_size = 16,
	}

	@(private = "package")
	sim_test_make_root_group :: #force_inline proc "contextless" (
		children: []Child_Spec,
		strategy: Supervision_Strategy = .One_For_One,
		child_count_dynamic_max: u16 = 0,
	) -> Group_Spec {
		return Group_Spec {
			strategy = strategy,
			restart_count_max = 3,
			window_duration_ticks = 1000,
			children = children,
			child_count_dynamic_max = child_count_dynamic_max,
		}
	}

	@(private = "package")
	sim_test_pack_init_args :: proc "contextless" (args: []u8) -> (u8, [MAX_INIT_ARGS_SIZE]u8) {
		payload: [MAX_INIT_ARGS_SIZE]u8
		copy(payload[:], args)
		return u8(len(args)), payload
	}

	@(private = "package")
	sim_test_make_spec :: #force_inline proc "contextless" (
		sim_config: ^SimulationConfig,
		types: []TypeDescriptor,
		shard_specs: []ShardSpec,
		options: Sim_Test_Spec_Options = {},
	) -> SystemSpec {
		opts := SIM_TEST_SPEC_DEFAULTS

		if options.pool_slot_count != 0 do opts.pool_slot_count = options.pool_slot_count
		if options.reactor_buffer_slot_count != 0 do opts.reactor_buffer_slot_count = options.reactor_buffer_slot_count
		if options.reactor_buffer_slot_size != 0 do opts.reactor_buffer_slot_size = options.reactor_buffer_slot_size
		if options.transfer_slot_count != 0 do opts.transfer_slot_count = options.transfer_slot_count
		if options.transfer_slot_size != 0 do opts.transfer_slot_size = options.transfer_slot_size
		opts.fd_handoff_entry_count = options.fd_handoff_entry_count
		if options.timer_spoke_count != 0 do opts.timer_spoke_count = options.timer_spoke_count
		if options.timer_entry_count != 0 do opts.timer_entry_count = options.timer_entry_count
		if options.timer_resolution_ns != 0 do opts.timer_resolution_ns = options.timer_resolution_ns
		if options.fd_table_slot_count != 0 do opts.fd_table_slot_count = options.fd_table_slot_count
		if options.log_ring_size != 0 do opts.log_ring_size = options.log_ring_size
		if options.supervision_groups_max != 0 do opts.supervision_groups_max = options.supervision_groups_max
		if options.scratch_arena_size != 0 do opts.scratch_arena_size = options.scratch_arena_size
		if options.default_ring_size != 0 do opts.default_ring_size = options.default_ring_size

		return SystemSpec {
			shard_count = u8(len(shard_specs)),
			types = types,
			shard_specs = shard_specs,
			simulation = sim_config,
			pool_slot_count = opts.pool_slot_count,
			reactor_buffer_slot_count = opts.reactor_buffer_slot_count,
			reactor_buffer_slot_size = opts.reactor_buffer_slot_size,
			transfer_slot_count = opts.transfer_slot_count,
			transfer_slot_size = opts.transfer_slot_size,
			fd_handoff_entry_count = opts.fd_handoff_entry_count,
			timer_spoke_count = opts.timer_spoke_count,
			timer_entry_count = opts.timer_entry_count,
			timer_resolution_ns = opts.timer_resolution_ns,
			fd_table_slot_count = opts.fd_table_slot_count,
			fd_entry_size = size_of(FD_Entry),
			log_ring_size = opts.log_ring_size,
			supervision_groups_max = opts.supervision_groups_max,
			scratch_arena_size = opts.scratch_arena_size,
			default_ring_size = opts.default_ring_size,
		}
	}
}
