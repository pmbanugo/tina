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
			group.static_child_count == u16(len(group.boot_spec.children)),
			"static_child_count must match boot_spec child count",
		)
		assert(
			group.static_child_count + group.dynamic_child_count <= u16(len(group.children_handles)),
			"group child counts exceed children_handles capacity",
		)
		assert(
			group.dynamic_child_count <= u16(len(group.dynamic_specs)),
			"group dynamic_child_count exceeds dynamic_specs capacity",
		)
	}
}

@(private = "package")
_group_total_child_count :: #force_inline proc(group: ^Supervision_Group) -> u16 {
	_assert_group_layout(group)
	return group.static_child_count + group.dynamic_child_count
}

@(private = "package")
_find_child_index :: proc(group: ^Supervision_Group, handle: Handle) -> (u16, bool) {
	for i in 0 ..< _group_total_child_count(group) {
		if group.children_handles[i] == handle do return i, true
	}
	return 0, false
}

@(private = "package")
_remove_child_at :: proc(group: ^Supervision_Group, index: u16) {
	_assert_group_layout(group)
	if index < group.static_child_count {
		group.children_handles[index] = HANDLE_NONE
		return
	}

	dynamic_index := index - group.static_child_count
	last_dynamic_index := group.dynamic_child_count - 1

	for i in dynamic_index ..< last_dynamic_index {
		target := group.static_child_count + i
		source := target + 1
		group.children_handles[target] = group.children_handles[source]
		group.dynamic_specs[i] = group.dynamic_specs[i + 1]
	}

	last_slot := group.static_child_count + last_dynamic_index
	group.children_handles[last_slot] = HANDLE_NONE
	group.dynamic_child_count -= 1
}

@(private = "package")
_get_child_restart_type :: proc(group: ^Supervision_Group, index: u16) -> Restart_Type {
	_assert_group_layout(group)
	if index < group.static_child_count {
		child_spec_pointer := &group.boot_spec.children[index]
		#partial switch &s in child_spec_pointer {
		case Static_Child_Spec:
			return s.restart_type
		case Group_Spec:
			return .permanent
		}
		return .temporary
	}

	return group.dynamic_specs[index - group.static_child_count].restart_type
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
	group.dynamic_child_count = 0

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

	for i in group.static_child_count ..< _group_total_child_count(group) {
		group.children_handles[i] = HANDLE_NONE
	}
	group.dynamic_child_count = 0
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
}

@(private = "package")
_spawn_static_child_at :: proc(shard: ^Shard, group: ^Supervision_Group, index: u16) -> bool {
	_assert_group_layout(group)
	spec: Spawn_Spec
	spec.group_id = group.group_id
	spec.handoff_fd = FD_HANDLE_NONE
	spec.handoff_mode = .Full

	child_spec_pointer := &group.boot_spec.children[index]
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
		group.children_handles[index] = handle
		return true
	}
	return false
}

@(private = "package")
_respawn_child_at :: proc(shard: ^Shard, group: ^Supervision_Group, index: u16) -> Build_Result {
	_assert_group_layout(group)
	if index < group.static_child_count {
		child_spec_pointer := &group.boot_spec.children[index]
		#partial switch &s in child_spec_pointer {
		case Static_Child_Spec:
			if _spawn_static_child_at(shard, group, index) {
				return .Ok
			}
		case Group_Spec:
			sub_handle := group.children_handles[index]
			sub_index := extract_slot(sub_handle)
			return _rebuild_subgroup(shard, &shard.supervision_groups[sub_index])
		}
	} else {
		dynamic_index := index - group.static_child_count
		dyn := &group.dynamic_specs[dynamic_index]

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
			group.children_handles[index] = handle
			return .Ok
		}
	}

	_escalate(shard, group)
	return .Escalated
}

@(private = "package")
_apply_strategy :: proc(shard: ^Shard, group: ^Supervision_Group, crashed_index: u16) -> Build_Result {
	_assert_group_layout(group)
	start_index: u16 = group.strategy == .Rest_For_One ? crashed_index + 1 : 0
	total_children := _group_total_child_count(group)

	if group.strategy == .One_For_All || group.strategy == .Rest_For_One {
		for i := total_children; i > start_index; i -= 1 {
			target_index := i - 1
			if target_index == crashed_index do continue

			handle := group.children_handles[target_index]
			if handle != HANDLE_NONE {
				if extract_type_id(handle) != u16(SUPERVISION_SUBGROUP_TYPE_ID) {
					_teardown_isolate(
						shard,
						extract_type_id(handle),
						extract_slot(handle),
						.Shutdown,
					)
					group.children_handles[target_index] = HANDLE_NONE
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
		restart_start = crashed_index; restart_end = crashed_index + 1
	case .One_For_All:
		restart_start = 0; restart_end = total_children
	case .Rest_For_One:
		restart_start = crashed_index; restart_end = total_children
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

	index, found := _find_child_index(group, child_handle)
	if !found do return

	restart_type := _get_child_restart_type(group, index)

	should_restart := false
	switch exit_kind {
	case .Normal:
		should_restart = (restart_type == .permanent)
	case .Crashed:
		should_restart = (restart_type != .temporary)
	case .Shutdown:
	}

	if !should_restart {
		_remove_child_at(group, index)
		return
	}

	if _check_and_record_restart(shard, group) {
		_escalate(shard, group)
		return
	}

	_ = _apply_strategy(shard, group, index)
}

@(private = "package")
shard_build_supervision_tree :: proc(
	shard: ^Shard,
	root_spec: ^Group_Spec,
	alloc: mem.Allocator,
	alloc_data: ^Grand_Arena_Allocator_Data = nil,
) {
	next_group_index: u16 = 0
	_ = _build_group(shard, root_spec, SUPERVISION_GROUP_ID_NONE, &next_group_index, alloc, alloc_data)
}

@(private = "package")
_build_group :: proc(
	shard: ^Shard,
	group_spec: ^Group_Spec,
	parent_id: Supervision_Group_Id,
	next_group_index: ^u16,
	alloc: mem.Allocator,
	alloc_data: ^Grand_Arena_Allocator_Data,
) -> Build_Result {
	group_index := next_group_index^
	next_group_index^ += 1

	group := &shard.supervision_groups[group_index]
	group.group_id = Supervision_Group_Id(group_index)
	group.parent_id = parent_id
	group.strategy = group_spec.strategy
	group.boot_spec = group_spec
	group.window_duration_ticks = group_spec.window_duration_ticks
	group.restart_count_max = group_spec.restart_count_max
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
	group.static_child_count = u16(len(group_spec.children))
	group.dynamic_child_count = 0
	_assert_group_layout(group)

	capacity := len(group_spec.children) + int(group_spec.dynamic_child_count_max)
	if len(group.children_handles) == 0 && capacity > 0 {
		if alloc_data != nil do alloc_data.current_name = fmt.tprintf("Group_%d_Handles", group_index)
		group.children_handles = make([]Handle, capacity, alloc)
	}

	if group_spec.dynamic_child_count_max > 0 && len(group.dynamic_specs) == 0 {
		if alloc_data != nil do alloc_data.current_name = fmt.tprintf("Group_%d_Dynamic_Specs", group_index)
		group.dynamic_specs = make([]Dynamic_Child_Spec, group_spec.dynamic_child_count_max, alloc)
	}

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
			sub_index := next_group_index^
			group.children_handles[i] = make_handle(
				shard.id,
				u16(SUPERVISION_SUBGROUP_TYPE_ID),
				u32(sub_index),
				0,
			)

			if _build_group(
				shard,
				&s,
				Supervision_Group_Id(group_index),
				next_group_index,
				alloc,
				alloc_data,
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
