package tina

import "core:mem"

Test_Turn_Frame_Proc :: #type proc(user_data: rawptr)

Test_Turn_Frame_Config :: struct {
	self_handle:         Isolate_Handle,
	message_source:      Isolate_Handle,
	correlation_id:      Correlation_Id,
	flags:               Isolate_Turn_Flags,
	monotonic_time_ns:   Monotonic_Time_NS,
	timer_resolution_ns: u64,
	shutting_down:       bool,
	working_memory_size: int,
}

Test_Local_Turn_Frame_Config :: struct {
	self_handle:             Isolate_Handle,
	target_handle:           Isolate_Handle,
	monotonic_time_ns:       Monotonic_Time_NS,
	current_tick:            u64,
	flags:                   Isolate_Turn_Flags,
	timer_resolution_ns:     u64,
	target_mailbox_capacity: u32,
	target_state:            Isolate_State,
	working_memory_size:     int,
}

test_with_turn_frame :: proc(
	config: Test_Turn_Frame_Config,
	user_data: rawptr,
	callback: Test_Turn_Frame_Proc,
) {
	self_type_id := extract_type_id(config.self_handle)
	self_slot_index := extract_slot(config.self_handle)
	type_count := int(self_type_id) + 1

	slot_counts := make([]int, type_count)
	defer delete(slot_counts)
	slot_counts[self_type_id] = int(self_slot_index) + 1

	working_size := config.working_memory_size
	if working_size == 0 do working_size = 4096

	working_memory_sizes := make([]int, type_count)
	defer delete(working_memory_sizes)
	working_memory_sizes[self_type_id] = working_size

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count           = type_count,
			slot_counts          = slot_counts,
			working_memory_sizes = working_memory_sizes,
			subsystems           = {.Metadata, .Timer_Wheel, .Scratch},
			timer_entry_count    = 16,
			scratch_memory_size   = 4096,
		},
	)
	defer test_shard_fixture_deinit(fixture)

	shard := &fixture.shard
	if config.shutting_down {
		fixture.health_report.reported_state = u8(Shard_State.Shutting_Down)
	}

	shard.timer_resolution_ns = config.timer_resolution_ns
	if shard.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1
		shard.current_tick = u64(config.monotonic_time_ns)
	} else {
		shard.current_tick = u64(config.monotonic_time_ns) / shard.timer_resolution_ns
	}

	test_shard_slot_activate(fixture, config.self_handle, .Runnable)

	frame := Isolate_Turn_Frame {
		previous_isolate_turn_frame = shard.current_isolate_turn_frame,
		isolate_handle              = config.self_handle,
		message_source_handle       = config.message_source,
		message_correlation_id      = config.correlation_id,
		turn_flags                  = config.flags,
		timer_resolution_ns         = shard.timer_resolution_ns,
		current_tick                = shard.current_tick,
		isolate_type_id             = self_type_id,
		isolate_slot_index          = self_slot_index,
		staging_slot_index          = IO_SLOT_INDEX_NONE,
		transfer_read_handle        = TRANSFER_HANDLE_NONE,
		message_pool_index          = POOL_NONE_INDEX,
	}
	mem.arena_init(&frame.scratch_arena, shard.scratch_memory)

	working_slice, working_slice_ok := _get_isolate_working_memory_row_if_present(shard, self_type_id, self_slot_index)
	if working_slice_ok {
		mem.arena_init(&frame.working_arena, working_slice)
	} else {
		assert(shard.type_descriptors[self_type_id].working_memory_size == 0, "working memory row unavailable")
		frame.working_arena = {}
	}

	previous_shard := g_current_shard_pointer
	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_shard_pointer = shard
	shard.current_isolate_turn_frame = &frame
	context.allocator = _working_arena_allocator(&frame.working_arena)
	context.temp_allocator = mem.arena_allocator(&frame.scratch_arena)

	callback(user_data)

	context.allocator = previous_allocator
	context.temp_allocator = previous_temp_allocator
	shard.current_isolate_turn_frame = frame.previous_isolate_turn_frame
	g_current_shard_pointer = previous_shard
}

test_with_local_turn_frame :: proc(
	config: Test_Local_Turn_Frame_Config,
	user_data: rawptr,
	callback: Test_Turn_Frame_Proc,
) -> (
	message_count: u16,
	message: Message,
) {
	self_type_id := extract_type_id(config.self_handle)
	target_type_id := extract_type_id(config.target_handle)
	target_slot_index := extract_slot(config.target_handle)
	type_count := max(int(self_type_id), int(target_type_id)) + 1

	slot_counts := make([]int, type_count)
	defer delete(slot_counts)
	slot_counts[target_type_id] = int(target_slot_index) + 1

	working_size := config.working_memory_size
	if working_size == 0 do working_size = 4096

	working_memory_sizes := make([]int, type_count)
	defer delete(working_memory_sizes)
	working_memory_sizes[target_type_id] = working_size

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count           = type_count,
			slot_counts          = slot_counts,
			working_memory_sizes = working_memory_sizes,
			subsystems           = {.Metadata, .Dispatchable, .Message_Pool, .Timer_Wheel, .Scratch},
			message_pool_slots   = 8,
			timer_entry_count    = 16,
			scratch_memory_size   = 4096,
		},
	)
	defer test_shard_fixture_deinit(fixture)

	shard := &fixture.shard
	shard.timer_resolution_ns = config.timer_resolution_ns
	if shard.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1
	}
	shard.current_tick = config.current_tick

	mailbox_capacity := config.target_mailbox_capacity
	if mailbox_capacity == 0 {
		mailbox_capacity = 8
	}
	shard.type_descriptors[target_type_id].mailbox_capacity = u16(mailbox_capacity)

	test_shard_slot_activate(fixture, config.target_handle, config.target_state)

	frame := Isolate_Turn_Frame {
		previous_isolate_turn_frame = shard.current_isolate_turn_frame,
		isolate_handle              = config.self_handle,
		message_source_handle       = ISOLATE_HANDLE_NONE,
		message_correlation_id      = CORRELATION_ID_NONE,
		turn_flags                  = config.flags,
		timer_resolution_ns         = shard.timer_resolution_ns,
		current_tick                = config.current_tick,
		isolate_type_id             = self_type_id,
		isolate_slot_index          = extract_slot(config.self_handle),
		staging_slot_index          = IO_SLOT_INDEX_NONE,
		transfer_read_handle        = TRANSFER_HANDLE_NONE,
		message_pool_index          = POOL_NONE_INDEX,
	}
	mem.arena_init(&frame.scratch_arena, shard.scratch_memory)

	working_slice, working_slice_ok := _get_isolate_working_memory_row_if_present(shard, target_type_id, target_slot_index)
	if working_slice_ok {
		mem.arena_init(&frame.working_arena, working_slice)
	} else {
		assert(shard.type_descriptors[target_type_id].working_memory_size == 0, "working memory row unavailable")
		frame.working_arena = {}
	}

	previous_shard := g_current_shard_pointer
	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_shard_pointer = shard
	shard.current_isolate_turn_frame = &frame
	context.allocator = _working_arena_allocator(&frame.working_arena)
	context.temp_allocator = mem.arena_allocator(&frame.scratch_arena)

	callback(user_data)

	context.allocator = previous_allocator
	context.temp_allocator = previous_temp_allocator
	shard.current_isolate_turn_frame = frame.previous_isolate_turn_frame
	g_current_shard_pointer = previous_shard

	soa_meta := shard.metadata[target_type_id]
	message_count = soa_meta[target_slot_index].inbox_count
	if message_count == 0 {
		return
	}

	envelope := pool_get_ptr_unchecked(&shard.message_pool, soa_meta[target_slot_index].inbox_head)
	message.tag = envelope.tag
	message.correlation = envelope.correlation
	message.user.source = envelope.source
	message.user.payload_size = envelope.payload_size
	if envelope.payload_size > 0 {
		copy(message.user.payload[:], envelope.payload[:int(envelope.payload_size)])
	}
	return
}
