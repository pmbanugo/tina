package tina

import "core:fmt"
import "core:mem"
import "core:os"

@(private = "package")
_find_child_index :: proc(group: ^Supervision_Group, handle: Handle) -> (u16, bool) {
	for i in 0 ..< group.child_count {
		if group.children_handles[i] == handle do return i, true
	}
	return 0, false
}

@(private = "package")
_remove_child_at :: proc(group: ^Supervision_Group, index: u16) {
	for i in index ..< group.child_count - 1 {
		group.children_handles[i] = group.children_handles[i + 1]
		if len(group.dynamic_specs) > 0 {
			group.dynamic_specs[i] = group.dynamic_specs[i + 1]
		}
	}
	group.child_count -= 1
}

@(private = "package")
_get_child_restart_type :: proc(group: ^Supervision_Group, index: u16) -> Restart_Type {
	if len(group.dynamic_specs) > 0 {
		return group.dynamic_specs[index].restart_type
	} else {
		child_spec_ptr := &group.boot_spec.children[index]
		#partial switch &s in child_spec_ptr {
		case Static_Child_Spec:
			return s.restart_type
		case Group_Spec:
			return .permanent // Subgroups are permanent
		}
	}
	return .temporary
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
	for i := group.child_count; i > 0; i -= 1 {
		handle := group.children_handles[i - 1]
		if handle != HANDLE_NONE {
			if extract_type_id(handle) != u16(SUPERVISION_SUBGROUP_TYPE_ID) {
				_teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
			} else {
				_teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
			}
		}
	}
	group.child_count = 0

	if group.parent_id == SUPERVISION_GROUP_ID_NONE {
		// Root group failure. Jump to the outer recovery loop.
		os_trap_restore(&shard.trap_environment_outer, 3)
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
	for i := group.child_count; i > 0; i -= 1 {
		handle := group.children_handles[i - 1]
		if handle != HANDLE_NONE {
			if extract_type_id(handle) != u16(SUPERVISION_SUBGROUP_TYPE_ID) {
				_teardown_isolate(shard, extract_type_id(handle), extract_slot(handle), .Shutdown)
			} else {
				_teardown_subgroup(shard, &shard.supervision_groups[extract_slot(handle)])
			}
		}
	}
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
}

@(private = "package")
_respawn_child_at :: proc(shard: ^Shard, group: ^Supervision_Group, index: u16) {
	spec: Spawn_Spec
	spec.group_id = group.group_id
	spec.handoff_fd = FD_HANDLE_NONE
	spec.handoff_mode = .Full

	if len(group.dynamic_specs) > 0 {
		dyn := &group.dynamic_specs[index]
		spec.type_id = dyn.type_id
		spec.restart_type = dyn.restart_type
		spec.args_size = dyn.args_size
		spec.args_payload = dyn.args_payload
	} else {
		child_spec_ptr := &group.boot_spec.children[index]
		#partial switch &s in child_spec_ptr {
		case Static_Child_Spec:
			spec.type_id = s.type_id
			spec.restart_type = s.restart_type
			spec.args_size = s.args_size
			spec.args_payload = s.args_payload
		case Group_Spec:
			sub_handle := group.children_handles[index]
			sub_index := extract_slot(sub_handle)
			_rebuild_subgroup(shard, &shard.supervision_groups[sub_index])
			return
		}
	}

	// Directly allocate and execute init. Skips array append logic.
	res := _make_isolate(shard, spec, HANDLE_NONE)

	if handle, ok := res.(Handle); ok {
		// IN-PLACE OVERWRITE! Solves the array-exhaustion deadlock.
		group.children_handles[index] = handle
	} else {
		_escalate(shard, group)
	}
}

@(private = "package")
_apply_strategy :: proc(shard: ^Shard, group: ^Supervision_Group, crashed_index: u16) {
	start_index: u16 = group.strategy == .Rest_For_One ? crashed_index + 1 : 0

	if group.strategy == .One_For_All || group.strategy == .Rest_For_One {
		for i := group.child_count; i > start_index; i -= 1 {
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
		restart_start = 0; restart_end = group.child_count
	case .Rest_For_One:
		restart_start = crashed_index; restart_end = group.child_count
	}

	for i in restart_start ..< restart_end {
		_respawn_child_at(shard, group, i)
	}
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
		// Do not physically remove/shift the array. 
		// _apply_strategy is iterating over it and will overwrite it.
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

	_apply_strategy(shard, group, index)
}

@(private = "package")
shard_build_supervision_tree :: proc(
	shard: ^Shard,
	root_spec: ^Group_Spec,
	alloc: mem.Allocator,
	alloc_data: ^Grand_Arena_Allocator_Data = nil,
) {
	next_group_index: u16 = 0
	_build_group(shard, root_spec, SUPERVISION_GROUP_ID_NONE, &next_group_index, alloc, alloc_data)
}

@(private = "package")
_build_group :: proc(
	shard: ^Shard,
	group_spec: ^Group_Spec,
	parent_id: Supervision_Group_Id,
	next_group_index: ^u16,
	alloc: mem.Allocator,
	alloc_data: ^Grand_Arena_Allocator_Data,
) -> u16 {
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

	capacity: int = int(group_spec.dynamic_child_count_max)
	if capacity == 0 {
		capacity = len(group_spec.children)
	}

	// Only allocate if we haven't already! (Crucial for Level 2 recovery)
	if len(group.children_handles) == 0 && capacity > 0 {
		if alloc_data != nil do alloc_data.current_name = fmt.tprintf("Group_%d_Handles", group_index)
		group.children_handles = make([]Handle, capacity, alloc)
	}

	if group_spec.dynamic_child_count_max > 0 && len(group.dynamic_specs) == 0 {
		if alloc_data != nil do alloc_data.current_name = fmt.tprintf("Group_%d_Dynamic_Specs", group_index)
		group.dynamic_specs = make([]Dynamic_Child_Spec, capacity, alloc)
	}

	group.child_count = 0
	for i in 0 ..< len(group_spec.children) {
		child_spec_ptr := &group_spec.children[i]

		#partial switch &s in child_spec_ptr {
		case Static_Child_Spec:
			spec := Spawn_Spec {
				args_payload = s.args_payload,
				group_id     = Supervision_Group_Id(group_index),
				type_id      = s.type_id,
				restart_type = s.restart_type,
				args_size    = s.args_size,
				handoff_fd   = FD_HANDLE_NONE,
				handoff_mode = .Full,
			}
			ctx := TinaContext {
				_shard      = shard,
				self_handle = HANDLE_NONE,
			}

			spawn_loop: for {
				res := ctx_spawn(&ctx, spec)
				if _, ok := res.(Handle); ok {
					break spawn_loop
				} else {
					// Init failed!
					if _check_and_record_restart(shard, group) {
						fmt.eprintfln(
							"[FATAL] Supervision intensity exceeded during boot/recovery for group %d",
							group_index,
						)
						os.exit(1) // Level 3 abort
					}
				}
			}

		case Group_Spec:
			sub_index := _build_group(
				shard,
				&s,
				Supervision_Group_Id(group_index),
				next_group_index,
				alloc,
				alloc_data,
			)
			sub_handle := make_handle(
				shard.id,
				u16(SUPERVISION_SUBGROUP_TYPE_ID),
				u32(sub_index),
				0,
			)
			group.children_handles[group.child_count] = sub_handle
			group.child_count += 1
		}
	}

	return group_index
}

@(private = "package")
_rebuild_subgroup :: proc(shard: ^Shard, group: ^Supervision_Group) {
	group.child_count = 0
	for i in 0 ..< len(group.boot_spec.children) {
		_respawn_child_at(shard, group, u16(i))
		group.child_count += 1
	}
	group.restart_count = 0
	group.window_start_tick = shard.current_tick
}
