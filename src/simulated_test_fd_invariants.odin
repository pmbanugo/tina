package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {
	FD_Invariant_Corruptor_Procedure :: #type proc(t: ^testing.T, sim: ^Simulator)

	// Build a simulator for fd invariant checker tests, run the corruptor
	// callback, then run the builtin checkers once.
	@(private = "file")
	_run_fd_invariant_checker :: proc(
		t: ^testing.T,
		checker_flags: Checker_Flags,
		fd_handoff_entry_count: int,
		corruptor: FD_Invariant_Corruptor_Procedure,
	) -> bool {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = HARNESS_NOOP_TYPE_ID,
				slot_count = 1,
				stride = size_of(HarnessNoopIsolate),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = harness_noop_init,
				handler_fn = harness_noop_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = HARNESS_NOOP_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 8,
			terminate_on_quiescent = true,
			builtin_checkers       = checker_flags,
			checker_interval_ticks = 1,
		}

		spec := sim_test_make_spec(
			&sim_config,
			types[:],
			shard_specs[:],
			Sim_Test_Spec_Options{fd_handoff_entry_count = fd_handoff_entry_count},
		)

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		if error != .None {
			return false
		}
		defer simulator_deinit(&sim)

		corruptor(t, &sim)

		return simulator_run_checkers(&sim, 0)
	}

	@(private = "file")
	_corrupt_fd_table_entry :: proc(t: ^testing.T, sim: ^Simulator) {
		shard := &sim.shards[0]
		owner := make_handle(0, HARNESS_NOOP_TYPE_ID, 0, 1)

		os_fd, sock_error := backend_control_socket(&shard.reactor.backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		fd_handle, fd_error := fd_table_alloc(&shard.reactor.fd_table, os_fd, owner)
		testing.expect_value(t, fd_error, FD_Table_Error.None)

		entry_index, lookup_error := fd_table_lookup_index(&shard.reactor.fd_table, fd_handle)
		testing.expect_value(t, lookup_error, FD_Table_Error.None)
		entry := &shard.reactor.fd_table.entries[entry_index]
		entry.os_fd = OS_FD_INVALID
	}

	@(private = "file")
	_corrupt_fd_handoff_entry :: proc(t: ^testing.T, sim: ^Simulator) {
		shard := &sim.shards[0]
		target_handle := make_handle(0, HARNESS_NOOP_TYPE_ID, 0, 1)

		cleanup_fd, sock_error := backend_control_socket(
			&shard.reactor.backend,
			.AF_INET,
			.STREAM,
			.TCP,
		)
		testing.expect_value(t, sock_error, Backend_Error.None)

		ref, alloc_error := fd_handoff_table_alloc(
			&shard.handoff_table,
			target_handle,
			cleanup_fd,
			Peer_Address{},
			8,
			shard.id,
		)
		testing.expect_value(t, alloc_error, FD_Handoff_Table_Error.None)

		entry_index, lookup_error := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
		testing.expect_value(t, lookup_error, FD_Handoff_Table_Error.None)
		entry := &shard.handoff_table.entries[entry_index]
		entry.cleanup_fd = OS_FD_INVALID
	}

	@(private = "file")
	_corrupt_sim_fd_object :: proc(t: ^testing.T, sim: ^Simulator) {
		backend := &sim.shards[0].reactor.backend

		fd, socket_error := backend_control_socket(backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, socket_error, Backend_Error.None)

		descriptor, ok := _sim_lookup_descriptor(backend, fd)
		testing.expect(t, ok, "simulated descriptor should resolve")
		backend.sim_world.objects[descriptor.object_index].ref_count += 1
	}

	@(test)
	test_sim_checker_detects_fd_table_corruption :: proc(t: ^testing.T) {
		detected := _run_fd_invariant_checker(t, {.FD_Table_Integrity}, 0, _corrupt_fd_table_entry)
		testing.expect(
			t,
			detected,
			"fd table checker should detect invalid active os fd",
		)
	}

	@(test)
	test_sim_checker_detects_handoff_entry_corruption :: proc(t: ^testing.T) {
		detected := _run_fd_invariant_checker(t, {.FD_Handoff_Integrity}, 2, _corrupt_fd_handoff_entry)
		testing.expect(
			t,
			detected,
			"handoff checker should detect invalid cleanup fd",
		)
	}

	@(test)
	test_sim_checker_detects_sim_fd_object_ref_mismatch :: proc(t: ^testing.T) {
		detected := _run_fd_invariant_checker(t, {.Sim_FD_Integrity}, 0, _corrupt_sim_fd_object)
		testing.expect(
			t,
			detected,
			"sim fd checker should detect object ref mismatch",
		)
	}
}
