package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {

	// ============================================================================
	// Core regression tests from TINA_CORE_REVIEW_FINDINGS.md.
	// These encode settled scheduler/supervision contracts before the fixes land.
	// ============================================================================

	INIT_CONTRACT_PARENT_TYPE_ID: Isolate_Type_Id : 0
	INIT_CONTRACT_CHILD_TYPE_ID:  Isolate_Type_Id : 1

	Init_Contract_Parent :: struct {
		child_handle:       Isolate_Handle,
		spawn_succeeded:    bool,
		init_failed_result: bool,
	}
	Init_Contract_Child :: struct {}

	init_contract_child_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_REPLY
	}

	init_contract_child_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	init_contract_parent_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		parent := cast(^Init_Contract_Parent)self
		child_spec := Spawn_Spec {
			type_id      = INIT_CONTRACT_CHILD_TYPE_ID,
			group_id     = ctx_supervision_group_id(),
			restart_type = .temporary,
		}

		spawn_result := ctx_spawn(child_spec)
		switch result in spawn_result {
		case Isolate_Handle:
			parent.child_handle = result
			parent.spawn_succeeded = true
		case Spawn_Error:
			parent.init_failed_result = result == .init_failed
		}

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	init_contract_parent_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_init_contract_violation_returns_spawn_error :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]IsolateTypeDescriptor {
			{
				id = INIT_CONTRACT_PARENT_TYPE_ID,
				slot_count = 1,
				stride = size_of(Init_Contract_Parent),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = init_contract_parent_init,
				handler_fn = init_contract_parent_handler,
			},
			{
				id = INIT_CONTRACT_CHILD_TYPE_ID,
				slot_count = 1,
				stride = size_of(Init_Contract_Child),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = init_contract_child_init,
				handler_fn = init_contract_child_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = INIT_CONTRACT_PARENT_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:], .One_For_One, 1)
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 1,
			terminate_on_quiescent = true,
		}

		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		parent := cast(^Init_Contract_Parent)_get_isolate_ptr(
			shard,
			INIT_CONTRACT_PARENT_TYPE_ID,
			0,
		)

		testing.expect(t, parent.init_failed_result, "contract-violating init must return Spawn_Error.init_failed")
		testing.expect(t, !parent.spawn_succeeded, "contract-violating init must not return a stale child handle")
		testing.expect_value(t, shard.supervision_groups[0].child_count_dynamic, u16(0))
		testing.expect_value(t, shard.metadata[INIT_CONTRACT_CHILD_TYPE_ID].state[0], Isolate_State.Unallocated)
	}

	REENTRANT_PARENT_TYPE_ID: Isolate_Type_Id : 0
	REENTRANT_FIRST_CHILD_TYPE_ID: Isolate_Type_Id : 1
	REENTRANT_SECOND_CHILD_TYPE_ID: Isolate_Type_Id : 2

	Reentrant_Parent :: struct {
		child_handle:    Isolate_Handle,
		spawn_succeeded: bool,
		spawn_failed:    bool,
	}
	Reentrant_First_Child :: struct {
		nested_spawn_group_full: bool,
		nested_spawn_succeeded:  bool,
	}
	Reentrant_Second_Child :: struct {}

	reentrant_second_child_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	reentrant_second_child_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	reentrant_first_child_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		child := cast(^Reentrant_First_Child)self
		nested_spec := Spawn_Spec {
			type_id      = REENTRANT_SECOND_CHILD_TYPE_ID,
			group_id     = ctx_supervision_group_id(),
			restart_type = .temporary,
		}

		nested_result := ctx_spawn(nested_spec)
		switch result in nested_result {
		case Isolate_Handle:
			child.nested_spawn_succeeded = true
		case Spawn_Error:
			child.nested_spawn_group_full = result == .group_full
		}

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	reentrant_first_child_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	reentrant_parent_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		parent := cast(^Reentrant_Parent)self
		child_spec := Spawn_Spec {
			type_id      = REENTRANT_FIRST_CHILD_TYPE_ID,
			group_id     = ctx_supervision_group_id(),
			restart_type = .temporary,
		}

		spawn_result := ctx_spawn(child_spec)
		switch result in spawn_result {
		case Isolate_Handle:
			parent.child_handle = result
			parent.spawn_succeeded = true
		case Spawn_Error:
			parent.spawn_failed = true
		}

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	reentrant_parent_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_dynamic_spawn_reserves_capacity_before_child_init :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [3]IsolateTypeDescriptor {
			{
				id = REENTRANT_PARENT_TYPE_ID,
				slot_count = 1,
				stride = size_of(Reentrant_Parent),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = reentrant_parent_init,
				handler_fn = reentrant_parent_handler,
			},
			{
				id = REENTRANT_FIRST_CHILD_TYPE_ID,
				slot_count = 1,
				stride = size_of(Reentrant_First_Child),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = reentrant_first_child_init,
				handler_fn = reentrant_first_child_handler,
			},
			{
				id = REENTRANT_SECOND_CHILD_TYPE_ID,
				slot_count = 1,
				stride = size_of(Reentrant_Second_Child),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = reentrant_second_child_init,
				handler_fn = reentrant_second_child_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = REENTRANT_PARENT_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:], .One_For_One, 1)
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 1,
			terminate_on_quiescent = true,
		}

		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		parent := cast(^Reentrant_Parent)_get_isolate_ptr(shard, REENTRANT_PARENT_TYPE_ID, 0)
		child := cast(^Reentrant_First_Child)_get_isolate_ptr(shard, REENTRANT_FIRST_CHILD_TYPE_ID, 0)

		testing.expect(t, parent.spawn_succeeded, "outer dynamic spawn must succeed")
		testing.expect(t, !parent.spawn_failed, "outer dynamic spawn must not fail")
		testing.expect(t, child.nested_spawn_group_full, "nested spawn must see the reserved final group slot")
		testing.expect(t, !child.nested_spawn_succeeded, "nested spawn must not consume stale dynamic capacity")
		testing.expect_value(t, shard.supervision_groups[0].child_count_dynamic, u16(1))
		testing.expect_value(t, shard.supervision_groups[0].dynamic_specs[0].type_id, REENTRANT_FIRST_CHILD_TYPE_ID)
		testing.expect_value(t, shard.metadata[REENTRANT_FIRST_CHILD_TYPE_ID].state[0], Isolate_State.Wait_Message)
		testing.expect_value(t, shard.metadata[REENTRANT_SECOND_CHILD_TYPE_ID].state[0], Isolate_State.Unallocated)
	}

	INVALID_TYPE_PARENT_TYPE_ID: Isolate_Type_Id : 0
	INVALID_TYPE_ID:             Isolate_Type_Id : 99

	Invalid_Type_Parent :: struct {
		spawn_succeeded:             bool,
		type_not_allocated_returned: bool,
	}

	invalid_type_parent_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		parent := cast(^Invalid_Type_Parent)self
		invalid_spec := Spawn_Spec {
			type_id      = INVALID_TYPE_ID,
			group_id     = ctx_supervision_group_id(),
			restart_type = .temporary,
		}

		spawn_result := ctx_spawn(invalid_spec)
		switch result in spawn_result {
		case Isolate_Handle:
			parent.spawn_succeeded = true
		case Spawn_Error:
			parent.type_not_allocated_returned = result == .type_not_allocated
		}

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	invalid_type_parent_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_ctx_spawn_rejects_invalid_type_id_before_indexing :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [1]IsolateTypeDescriptor {
			{
				id = INVALID_TYPE_PARENT_TYPE_ID,
				slot_count = 1,
				stride = size_of(Invalid_Type_Parent),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = invalid_type_parent_init,
				handler_fn = invalid_type_parent_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = INVALID_TYPE_PARENT_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:], .One_For_One, 1)
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 1,
			terminate_on_quiescent = true,
		}

		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		parent := cast(^Invalid_Type_Parent)_get_isolate_ptr(shard, INVALID_TYPE_PARENT_TYPE_ID, 0)

		testing.expect(t, parent.type_not_allocated_returned, "invalid type_id must return Spawn_Error.type_not_allocated")
		testing.expect(t, !parent.spawn_succeeded, "invalid type_id must not return a handle")
		testing.expect_value(t, shard.supervision_groups[0].child_count_dynamic, u16(0))
	}

	INVALID_GROUP_PARENT_TYPE_ID: Isolate_Type_Id : 0
	INVALID_GROUP_CHILD_TYPE_ID:  Isolate_Type_Id : 1
	INVALID_GROUP_ID:             Supervision_Group_Id : 99

	Invalid_Group_Parent :: struct {
		spawn_succeeded: bool,
		spawn_rejected:  bool,
	}
	Invalid_Group_Child :: struct {}

	invalid_group_child_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	invalid_group_child_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	invalid_group_parent_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		parent := cast(^Invalid_Group_Parent)self
		invalid_spec := Spawn_Spec {
			type_id      = INVALID_GROUP_CHILD_TYPE_ID,
			group_id     = INVALID_GROUP_ID,
			restart_type = .temporary,
		}

		spawn_result := ctx_spawn(invalid_spec)
		switch result in spawn_result {
		case Isolate_Handle:
			parent.spawn_succeeded = true
		case Spawn_Error:
			parent.spawn_rejected = true
		}

		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	invalid_group_parent_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_ctx_spawn_rejects_invalid_group_id_before_indexing :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]IsolateTypeDescriptor {
			{
				id = INVALID_GROUP_PARENT_TYPE_ID,
				slot_count = 1,
				stride = size_of(Invalid_Group_Parent),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = invalid_group_parent_init,
				handler_fn = invalid_group_parent_handler,
			},
			{
				id = INVALID_GROUP_CHILD_TYPE_ID,
				slot_count = 1,
				stride = size_of(Invalid_Group_Child),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = invalid_group_child_init,
				handler_fn = invalid_group_child_handler,
			},
		}

		children := [1]Child_Spec {
			Static_Child_Spec{type_id = INVALID_GROUP_PARENT_TYPE_ID, restart_type = .temporary},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 1,
			terminate_on_quiescent = true,
		}

		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:])

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		parent := cast(^Invalid_Group_Parent)_get_isolate_ptr(shard, INVALID_GROUP_PARENT_TYPE_ID, 0)

		testing.expect(t, parent.spawn_rejected, "invalid group_id must return Spawn_Error")
		testing.expect(t, !parent.spawn_succeeded, "invalid group_id must not return a handle")
		testing.expect_value(t, shard.metadata[INVALID_GROUP_CHILD_TYPE_ID].state[0], Isolate_State.Unallocated)
	}

	TIMEOUT_CALLEE_TYPE_ID: Isolate_Type_Id : 0
	TIMEOUT_CALLER_TYPE_ID: Isolate_Type_Id : 1
	TIMEOUT_REQUEST_TAG:    Message_Tag : USER_MESSAGE_TAG_BASE + 31

	Timeout_Callee :: struct {}
	Timeout_Caller :: struct {
		call_staged: bool,
	}
	Timeout_Caller_Args :: struct {
		callee_handle: Isolate_Handle,
	}
	Timeout_Request :: struct {
		value: u32,
	}

	timeout_callee_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	timeout_callee_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	timeout_caller_init :: proc(self: rawptr, args: []u8) -> Isolate_Transition {
		caller := cast(^Timeout_Caller)self
		init_args := payload_as(Timeout_Caller_Args, args)
		request := Timeout_Request{value = 7}

		call_result := ctx_call(init_args.callee_handle, TIMEOUT_REQUEST_TAG, &request, 1)
		caller.call_staged = call_result == .ok
		return ISOLATE_TRANSITION_WAIT_REPLY
	}

	timeout_caller_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
		return ISOLATE_TRANSITION_WAIT_MESSAGE
	}

	@(test)
	test_call_timeout_wakes_wait_reply_when_message_pool_exhausted :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		types := [2]IsolateTypeDescriptor {
			{
				id = TIMEOUT_CALLEE_TYPE_ID,
				slot_count = 1,
				stride = size_of(Timeout_Callee),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = timeout_callee_init,
				handler_fn = timeout_callee_handler,
			},
			{
				id = TIMEOUT_CALLER_TYPE_ID,
				slot_count = 1,
				stride = size_of(Timeout_Caller),
				soa_metadata_size = size_of(Isolate_Metadata),
				init_handler = timeout_caller_init,
				handler_fn = timeout_caller_handler,
			},
		}

		callee_handle := make_handle(0, TIMEOUT_CALLEE_TYPE_ID, 0, 1)
		caller_args := Timeout_Caller_Args{callee_handle = callee_handle}
		args_payload, args_size := make_spawn_args(&caller_args)
		children := [2]Child_Spec {
			Static_Child_Spec{type_id = TIMEOUT_CALLEE_TYPE_ID, restart_type = .temporary},
			Static_Child_Spec{
				type_id      = TIMEOUT_CALLER_TYPE_ID,
				restart_type = .temporary,
				args_size    = args_size,
				args_payload = args_payload,
			},
		}
		root_group := sim_test_make_root_group(children[:])
		shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

		sim_config := SimulationConfig {
			seed                   = t.seed,
			ticks_max              = 1,
			terminate_on_quiescent = true,
		}
		spec_options := Sim_Test_Spec_Options {
			pool_slot_count = 8,
		}
		spec := sim_test_make_spec(&sim_config, types[:], shard_specs[:], spec_options)

		sim: Simulator
		error := simulator_init(&sim, &spec, context.temp_allocator)
		testing.expect_value(t, error, mem.Allocator_Error.None)
		defer simulator_deinit(&sim)

		shard := &sim.shards[0]
		caller := cast(^Timeout_Caller)_get_isolate_ptr(shard, TIMEOUT_CALLER_TYPE_ID, 0)
		testing.expect(t, caller.call_staged, "caller init must stage the request before waiting for timeout")
		testing.expect_value(t, shard.metadata[TIMEOUT_CALLER_TYPE_ID].state[0], Isolate_State.Wait_Reply)
		testing.expect(t, shard.metadata[TIMEOUT_CALLER_TYPE_ID].pending_correlation[0] != 0, "caller must have a pending call correlation")

		for shard.message_pool.free_count > 0 {
			_, pool_error := pool_alloc_system(&shard.message_pool)
			testing.expect_value(t, pool_error, Pool_Error.None)
		}
		testing.expect_value(t, shard.message_pool.free_count, u32(0))

		shard.current_tick = 1
		_advance_timers(shard)

		testing.expect_value(t, shard.metadata[TIMEOUT_CALLER_TYPE_ID].state[0], Isolate_State.Runnable)
		testing.expect_value(t, shard.metadata[TIMEOUT_CALLER_TYPE_ID].pending_correlation[0], Correlation_Id(0))
	}
}
