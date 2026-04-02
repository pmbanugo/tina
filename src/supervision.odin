package tina

import "core:fmt"
import "core:mem"

Build_Result :: enum u8 {
	Ok,
	Escalated,
}

@(private = "package")
_assert_group_layout :: #force_inline proc(group: ^Supervision_Group) {
	when TINA_DEBUG_ASSERTS {
		assert(
			group.child_count_static == u16(len(group.boot_spec.children)),
			"child_count_static must match boot_spec child count",
		)
		assert(
			group.child_count_static + group.child_count_dynamic <= u16(len(group.children_handles)),
			"group child counts exceed children_handles capacity",
		)
		assert(
			group.child_count_dynamic <= u16(len(group.dynamic_specs)),
			"group child_count_dynamic exceeds dynamic_specs capacity",
		)
	}
}

@(private = "package")
_group_total_child_count :: #force_inline proc(group: ^Supervision_Group) -> u16 {
	_assert_group_layout(group)
	return group.child_count_static + group.child_count_dynamic
}

@(private = "package")
_find_child_index :: proc(group: ^Supervision_Group, handle: Handle) -> (u16, bool) {
	for i in 0 ..< _group_total_child_count(group) {
		if group.children_handles[i] == handle do return i, true
	}
	return 0, false
}

@(private = "package")
_remove_child_at :: proc(group: ^Supervision_Group, child_index: u16) {
	_assert_group_layout(group)
	if child_index < group.child_count_static {
		group.children_handles[child_index] = HANDLE_NONE
		return
	}

	child_index_dynamic := child_index - group.child_count_static
	child_index_dynamic_last := group.child_count_dynamic - 1

	for i in child_index_dynamic ..< child_index_dynamic_last {
		target := group.child_count_static + i
		source := target + 1
		group.children_handles[target] = group.children_handles[source]
		group.dynamic_specs[i] = group.dynamic_specs[i + 1]
	}

	last_slot := group.child_count_static + child_index_dynamic_last
	group.children_handles[last_slot] = HANDLE_NONE
	group.child_count_dynamic -= 1
}

@(private = "package")
_get_child_restart_type :: proc(group: ^Supervision_Group, child_index: u16) -> Restart_Type {
	_assert_group_layout(group)
	if child_index < group.child_count_static {
		child_spec_pointer := &group.boot_spec.children[child_index]
		#partial switch &s in child_spec_pointer {
		case Static_Child_Spec:
			return s.restart_type
		case Group_Spec:
			return .permanent
		}
		return .temporary
	}

	return group.dynamic_specs[child_index - group.child_count_static].restart_type
}

@(private = "package")
_check_and_record_restart :: proc(shard: ^Shard, group: ^Supervision_Group) -> bool {
	now := shard.current_tick
	if now - group.window_start_tick >= u64(group.window_duration_ticks) {
		group.window_start_tick = now
		group.restart_count = 1
		return false
	}
	group.restart_count += 1
	return group.restart_count > group.restart_count_max
}

@(private = "package")
_escalate :: proc(shard: ^Shard, group: ^Supervision_Group) {
	for i := _group_total_child_count(group); i > 0; i -= 1 {
		handle := group.children_handles[i - 1]
		if handle != HANDLE_NONE {
			if extract_type_id(handle) != u16(SUPERVISION_SUBGROUP_TYPE_ID) {
				_teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
			} else {
				_teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
			}
		}
	}
	group.child_count_dynamic = 0

	if group.parent_id == SUPERVISION_GROUP_ID_NONE {
		os_trap_restore(&shard.trap_environment_outer, RECOVERY_ROOT_ESCALATE)
	} else {
		group_handle := make_handle(
			shard.id,
			u16(SUPERVISION_SUBGROUP_TYPE_ID),
			u32(group.group_id),
			0,
		)
		_on_child_exit(shard, group.parent_id, group_handle, .Crashed)
	}
}

@(private = "package")
_teardown_subgroup :: proc(shard: ^Shard, group: ^Supervision_Group) {
	for i := _group_total_child_count(group); i > 0; i -= 1 {
		handle := group.children_handles[i - 1]
		if handle != HANDLE_NONE {
			if extract_type_id(handle) != u16(SUPERVISION_SUBGROUP_TYPE_ID) {
				_teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
			} else {
				_teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
			}
		}
	}

	for i in group.child_count_static ..< _group_total_child_count(group) {
		group.children_handles[i] = HANDLE_NONE
	}
	group.child_count_dynamic = 0
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
}

@(private = "package")
_spawn_static_child_at :: proc(shard: ^Shard, group: ^Supervision_Group, child_index: u16) -> bool {
	_assert_group_layout(group)
	spec: Spawn_Spec
	spec.group_id = group.group_id
	spec.handoff_fd = FD_HANDLE_NONE
	spec.handoff_mode = .Full

	child_spec_pointer := &group.boot_spec.children[child_index]
	#partial switch &s in child_spec_pointer {
	case Static_Child_Spec:
		spec.type_id = s.type_id
		spec.restart_type = s.restart_type
		spec.args_size = s.args_size
		spec.args_payload = s.args_payload
	case Group_Spec:
		return false
	}

	res := _make_isolate(shard, spec, HANDLE_NONE)
	if handle, ok := res.(Handle); ok {
		group.children_handles[child_index] = handle
		return true
	}
	return false
}

@(private = "package")
_respawn_child_at :: proc(shard: ^Shard, group: ^Supervision_Group, child_index: u16) -> Build_Result {
	_assert_group_layout(group)
	if child_index < group.child_count_static {
		child_spec_pointer := &group.boot_spec.children[child_index]
		#partial switch &s in child_spec_pointer {
		case Static_Child_Spec:
			if _spawn_static_child_at(shard, group, child_index) {
				return .Ok
			}
		case Group_Spec:
			subgroup_handle := group.children_handles[child_index]
			subgroup_index := extract_slot(subgroup_handle)
			return _rebuild_subgroup(shard, &shard.supervision_groups[subgroup_index])
		}
	} else {
		child_index_dynamic := child_index - group.child_count_static
		dyn := &group.dynamic_specs[child_index_dynamic]

		spec := Spawn_Spec {
			group_id     = group.group_id,
			handoff_fd   = FD_HANDLE_NONE,
			handoff_mode = .Full,
			type_id      = dyn.type_id,
			restart_type = dyn.restart_type,
			args_size    = dyn.args_size,
			args_payload = dyn.args_payload,
		}

		res := _make_isolate(shard, spec, HANDLE_NONE)
		if handle, ok := res.(Handle); ok {
			group.children_handles[child_index] = handle
			return .Ok
		}
	}

	_escalate(shard, group)
	return .Escalated
}

@(private = "package")
_apply_strategy :: proc(shard: ^Shard, group: ^Supervision_Group, child_index_crashed: u16) -> Build_Result {
	_assert_group_layout(group)
	child_index_start: u16 = group.strategy == .Rest_For_One ? child_index_crashed + 1 : 0
	child_count := _group_total_child_count(group)

	if group.strategy == .One_For_All || group.strategy == .Rest_For_One {
		for i := child_count; i > child_index_start; i -= 1 {
			child_index_target := i - 1
			if child_index_target == child_index_crashed do continue

			handle := group.children_handles[child_index_target]
			if handle != HANDLE_NONE {
				if extract_type_id(handle) != u16(SUPERVISION_SUBGROUP_TYPE_ID) {
					_teardown_isolate(
						shard,
						extract_type_id(handle),
						extract_slot(handle),
						.Shutdown,
					)
					group.children_handles[child_index_target] = HANDLE_NONE
				} else {
					_teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
				}
			}
		}
	}

	restart_start: u16
	restart_end: u16

	switch group.strategy {
	case .One_For_One:
		restart_start = child_index_crashed; restart_end = child_index_crashed + 1
	case .One_For_All:
		restart_start = 0; restart_end = child_count
	case .Rest_For_One:
		restart_start = child_index_crashed; restart_end = child_count
	}

	for i in restart_start ..< restart_end {
		if _respawn_child_at(shard, group, i) == .Escalated {
			return .Escalated
		}
	}

	return .Ok
}

@(private = "package")
_on_child_exit :: proc(
	shard: ^Shard,
	group_id: Supervision_Group_Id,
	child_handle: Handle,
	exit_kind: Exit_Kind,
) {
	group := &shard.supervision_groups[u16(group_id)]

	if exit_kind == .Shutdown {
		return
	}

	child_index, found := _find_child_index(group, child_handle)
	if !found do return

	restart_type := _get_child_restart_type(group, child_index)

	should_restart := false
	switch exit_kind {
	case .Normal:
		should_restart = (restart_type == .permanent)
	case .Crashed:
		should_restart = (restart_type != .temporary)
	case .Shutdown:
	}

	if !should_restart {
		_remove_child_at(group, child_index)
		return
	}

	if _check_and_record_restart(shard, group) {
		_escalate(shard, group)
		return
	}

	_ = _apply_strategy(shard, group, child_index)
}

@(private = "package")
shard_build_supervision_tree :: proc(
	shard: ^Shard,
	root_spec: ^Group_Spec,
	alloc: mem.Allocator,
	arena_alloc_data: ^Grand_Arena_Allocator_Data = nil,
) {
	group_index_next: u16 = 0
	_ = _build_group(
		shard,
		root_spec,
		SUPERVISION_GROUP_ID_NONE,
		&group_index_next,
		alloc,
		arena_alloc_data,
	)
}

@(private = "package")
_build_group :: proc(
	shard: ^Shard,
	group_spec: ^Group_Spec,
	parent_id: Supervision_Group_Id,
	group_index_next: ^u16,
	alloc: mem.Allocator,
	arena_alloc_data: ^Grand_Arena_Allocator_Data,
) -> Build_Result {
	group_index := group_index_next^
	group_index_next^ += 1

	group := &shard.supervision_groups[group_index]
	group.group_id = Supervision_Group_Id(group_index)
	group.parent_id = parent_id
	group.strategy = group_spec.strategy
	group.boot_spec = group_spec
	group.window_duration_ticks = group_spec.window_duration_ticks
	group.restart_count_max = group_spec.restart_count_max
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
	group.child_count_static = u16(len(group_spec.children))
	group.child_count_dynamic = 0

	child_capacity_count := len(group_spec.children) + int(group_spec.child_count_dynamic_max)
	if len(group.children_handles) == 0 && child_capacity_count > 0 {
		if arena_alloc_data != nil do arena_alloc_data.current_name = fmt.tprintf("Group_%d_Handles", group_index)
		group.children_handles = make([]Handle, child_capacity_count, alloc)
	}

	if group_spec.child_count_dynamic_max > 0 && len(group.dynamic_specs) == 0 {
		if arena_alloc_data != nil do arena_alloc_data.current_name = fmt.tprintf("Group_%d_Dynamic_Specs", group_index)
		group.dynamic_specs = make([]Dynamic_Child_Spec, group_spec.child_count_dynamic_max, alloc)
	}

	_assert_group_layout(group)

	for i in 0 ..< len(group.children_handles) {
		group.children_handles[i] = HANDLE_NONE
	}

	for i in 0 ..< len(group_spec.children) {
		child_spec_pointer := &group_spec.children[i]

		#partial switch &s in child_spec_pointer {
		case Static_Child_Spec:
			spawn_loop: for {
				if _spawn_static_child_at(shard, group, u16(i)) {
					break spawn_loop
				}

				if _check_and_record_restart(shard, group) {
					_escalate(shard, group)
					return .Escalated
				}
			}

		case Group_Spec:
			subgroup_index := group_index_next^
			group.children_handles[i] = make_handle(
				shard.id,
				u16(SUPERVISION_SUBGROUP_TYPE_ID),
				u32(subgroup_index),
				0,
			)

			if _build_group(
				shard,
				&s,
				Supervision_Group_Id(group_index),
				group_index_next,
				alloc,
				arena_alloc_data,
			) == .Escalated {
				return .Escalated
			}
		}
	}

	return .Ok
}

@(private = "package")
_rebuild_subgroup :: proc(shard: ^Shard, group: ^Supervision_Group) -> Build_Result {
	_assert_group_layout(group)
	for i in 0 ..< len(group.boot_spec.children) {
		if _respawn_child_at(shard, group, u16(i)) == .Escalated {
			return .Escalated
		}
	}
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
	return .Ok
}
