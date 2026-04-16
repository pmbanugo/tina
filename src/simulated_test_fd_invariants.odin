package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {
	@(private = "file")
	_make_fd_invariant_simulator :: proc(
		t: ^testing.T,
		checker_flags: Checker_Flags,
		fd_handoff_entry_count: int = 0,
	) -> Simulator {
		types := [1]TypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_fn = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec {{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed = t.seed,
			ticks_max = 8,
			terminate_on_quiescent = true,
			builtin_checkers = checker_flags,
			checker_interval_ticks = 1,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			Sim_Test_Spec_Options {fd_handoff_entry_count = fd_handoff_entry_count},
		)

		sim: Simulator
		err := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)
		return sim
	}

	@(test)
	test_sim_checker_detects_fd_table_corruption :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		sim := _make_fd_invariant_simulator(t, {.FD_Table_Integrity})
		shard := &sim.shards[0]
		owner := make_handle(0, u16(HARNESS_NOOP_TYPE_ID), 0, 1)

		os_fd, sock_err := backend_control_socket(&shard.reactor.backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		fd_handle, fd_err := fd_table_alloc(&shard.reactor.fd_table, os_fd, owner)
		testing.expect_value(t, fd_err, FD_Table_Error.None)

		entry, lookup_err := fd_table_lookup(&shard.reactor.fd_table, fd_handle)
		testing.expect_value(t, lookup_err, FD_Table_Error.None)
		entry.os_fd = OS_FD_INVALID

		testing.expect(t, simulator_run_checkers(&sim, 0), "fd table checker should detect invalid active os fd")
	}

	@(test)
	test_sim_checker_detects_handoff_entry_corruption :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		sim := _make_fd_invariant_simulator(t, {.FD_Handoff_Integrity}, 2)
		shard := &sim.shards[0]
		target_handle := make_handle(0, u16(HARNESS_NOOP_TYPE_ID), 0, 1)

		cleanup_fd, sock_err := backend_control_socket(&shard.reactor.backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		ref, ok := fd_handoff_table_alloc(
			&shard.handoff_table,
			target_handle,
			cleanup_fd,
			Peer_Address{},
			8,
			shard.id,
		)
		testing.expect(t, ok, "handoff entry should allocate")

		entry, found := fd_handoff_table_lookup(&shard.handoff_table, ref)
		testing.expect(t, found, "handoff entry should resolve")
		entry.cleanup_fd = OS_FD_INVALID

		testing.expect(t, simulator_run_checkers(&sim, 0), "handoff checker should detect invalid cleanup fd")
	}

	@(test)
	test_sim_checker_detects_sim_fd_object_ref_mismatch :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		sim := _make_fd_invariant_simulator(t, {.Sim_FD_Integrity})
		backend := &sim.shards[0].reactor.backend

		fd, sock_err := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		desc, ok := _sim_lookup_descriptor(backend, fd)
		testing.expect(t, ok, "simulated descriptor should resolve")
		g_sim_fd_state.objects[desc.object_index].ref_count += 1

		testing.expect(t, simulator_run_checkers(&sim, 0), "sim fd checker should detect object ref mismatch")
	}
}
