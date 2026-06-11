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
	watchdog_state := u8(Shard_State.Running)
	if config.shutting_down {
		watchdog_state = u8(Shard_State.Shutting_Down)
	}

	shard := new(Shard)
	defer free(shard)
	shard^ = Shard {
		id                     = extract_shard_id(config.self_handle),
		timer_resolution_ns    = config.timer_resolution_ns,
		current_tick           = u64(config.monotonic_time_ns) / max(u64(config.timer_resolution_ns), u64(1)),
		watchdog_state_pointer = &watchdog_state,
	}
	if shard.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1
		shard.current_tick = u64(config.monotonic_time_ns)
	}

	timer_deadlines := make([]u64, 16)
	defer delete(timer_deadlines)
	timer_targets := make([]Isolate_Handle, 16)
	defer delete(timer_targets)
	timer_tags := make([]Message_Tag, 16)
	defer delete(timer_tags)
	timer_correlations := make([]Correlation_Id, 16)
	defer delete(timer_correlations)
	timer_armed_words := make([]u64, 1)
	defer delete(timer_armed_words)
	timer_wheel_init(&shard.timer_wheel, timer_deadlines, timer_targets, timer_tags, timer_correlations, timer_armed_words)

	scratch_bytes := make([]u8, 4096)
	defer delete(scratch_bytes)

	self_type_id := extract_type_id(config.self_handle)
	self_slot_index := extract_slot(config.self_handle)
	self_slot_count := int(self_slot_index) + 1
	type_descriptor_count := int(self_type_id) + 1

	shard.type_descriptors = make([]IsolateTypeDescriptor, type_descriptor_count)
	defer delete(shard.type_descriptors)
	shard.metadata = make([]#soa[]Isolate_Metadata, type_descriptor_count)
	defer delete(shard.metadata)
	shard.metadata[self_type_id] = make(#soa[]Isolate_Metadata, self_slot_count)
	defer delete(shard.metadata[self_type_id])

	shard.metadata[self_type_id][self_slot_index] = Isolate_Metadata {
		generation     = extract_generation(config.self_handle),
		io_slot_index  = IO_SLOT_INDEX_NONE,
		io_operation_kind = .None,
		flags          = {},
		state          = .Runnable,
	}

	working_size := config.working_memory_size
	if working_size == 0 do working_size = 4096
	working_bytes := make([]u8, working_size)
	defer delete(working_bytes)

	frame := Isolate_Turn_Frame {
		previous_isolate_turn_frame = shard.current_isolate_turn_frame,
		isolate_handle              = config.self_handle,
		message_source_handle       = config.message_source,
		message_correlation_id      = config.correlation_id,
		turn_flags                  = config.flags,
		timer_resolution_ns         = shard.timer_resolution_ns,
		current_tick                = u64(config.monotonic_time_ns) / shard.timer_resolution_ns,
		isolate_type_id             = self_type_id,
		isolate_slot_index          = self_slot_index,
		staging_slot_index          = IO_SLOT_INDEX_NONE,
		transfer_read_handle        = TRANSFER_HANDLE_NONE,
		message_pool_index          = POOL_NONE_INDEX,
	}
	mem.arena_init(&frame.scratch_arena, scratch_bytes)
	mem.arena_init(&frame.working_arena, working_bytes)

	previous_shard := g_current_shard_pointer
	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_shard_pointer = shard
	shard.current_isolate_turn_frame = &frame
	context.allocator = mem.arena_allocator(&frame.working_arena)
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
	watchdog_state := u8(Shard_State.Running)
	shard := new(Shard)
	defer free(shard)
	shard^ = Shard {
		id                     = extract_shard_id(config.target_handle),
		timer_resolution_ns    = config.timer_resolution_ns,
		current_tick           = config.current_tick,
		watchdog_state_pointer = &watchdog_state,
	}
	if shard.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1
	}

	pool_backing := make([]u8, MESSAGE_ENVELOPE_SIZE * 8)
	defer delete(pool_backing)
	pool_init(&shard.message_pool, pool_backing, MESSAGE_ENVELOPE_SIZE)

	timer_deadlines := make([]u64, 16)
	defer delete(timer_deadlines)
	timer_targets := make([]Isolate_Handle, 16)
	defer delete(timer_targets)
	timer_tags := make([]Message_Tag, 16)
	defer delete(timer_tags)
	timer_correlations := make([]Correlation_Id, 16)
	defer delete(timer_correlations)
	timer_armed_words := make([]u64, 1)
	defer delete(timer_armed_words)
	timer_wheel_init(&shard.timer_wheel, timer_deadlines, timer_targets, timer_tags, timer_correlations, timer_armed_words)

	type_count :=
		max(int(extract_type_id(config.self_handle)), int(extract_type_id(config.target_handle))) +
		1
	shard.type_descriptors = make([]IsolateTypeDescriptor, type_count)
	defer delete(shard.type_descriptors)
	shard.metadata = make([]#soa[]Isolate_Metadata, type_count)
	defer delete(shard.metadata)
	shard.dispatchable_slot_words = make([][]u64, type_count)
	defer delete(shard.dispatchable_slot_words)
	shard.dispatchable_slot_counts = make([]u32, type_count)
	defer delete(shard.dispatchable_slot_counts)
	shard.dispatch_credit_counts = make([]Scheduler_Credit_Count, type_count)
	defer delete(shard.dispatch_credit_counts)
	shard.dispatchable_type_words = make([]u64, _dispatch_word_count(type_count))
	defer delete(shard.dispatchable_type_words)
	shard.dispatch_ready_type_words = make([]u64, _dispatch_word_count(type_count))
	defer delete(shard.dispatch_ready_type_words)

	target_type_id := extract_type_id(config.target_handle)
	target_slot_index := extract_slot(config.target_handle)
	target_slot_count := int(target_slot_index) + 1
	shard.metadata[target_type_id] = make(#soa[]Isolate_Metadata, target_slot_count)
	defer delete(shard.metadata[target_type_id])
	shard.dispatchable_slot_words[target_type_id] = make(
		[]u64,
		_dispatch_word_count(target_slot_count),
	)
	defer delete(shard.dispatchable_slot_words[target_type_id])

	mailbox_capacity := config.target_mailbox_capacity
	if mailbox_capacity == 0 {
		mailbox_capacity = 8
	}
	shard.type_descriptors[target_type_id].mailbox_capacity = u16(mailbox_capacity)
	shard.type_descriptors[target_type_id].id = Isolate_Type_Id(target_type_id)
	shard.metadata[target_type_id][target_slot_index].generation = extract_generation(
		config.target_handle,
	)
	shard.metadata[target_type_id][target_slot_index].state = config.target_state
	_dispatchable_refresh_slot(shard, target_type_id, target_slot_index)

	scratch_bytes := make([]u8, 4096)
	defer delete(scratch_bytes)

	working_size := config.working_memory_size
	if working_size == 0 do working_size = 4096
	working_bytes := make([]u8, working_size)
	defer delete(working_bytes)

	frame := Isolate_Turn_Frame {
		previous_isolate_turn_frame = shard.current_isolate_turn_frame,
		isolate_handle              = config.self_handle,
		message_source_handle       = ISOLATE_HANDLE_NONE,
		message_correlation_id      = CORRELATION_ID_NONE,
		turn_flags                  = config.flags,
		timer_resolution_ns         = shard.timer_resolution_ns,
		current_tick                = config.current_tick,
		isolate_type_id             = extract_type_id(config.self_handle),
		isolate_slot_index          = extract_slot(config.self_handle),
		staging_slot_index          = IO_SLOT_INDEX_NONE,
		transfer_read_handle        = TRANSFER_HANDLE_NONE,
		message_pool_index          = POOL_NONE_INDEX,
	}
	mem.arena_init(&frame.scratch_arena, scratch_bytes)
	mem.arena_init(&frame.working_arena, working_bytes)

	previous_shard := g_current_shard_pointer
	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_shard_pointer = shard
	shard.current_isolate_turn_frame = &frame
	context.allocator = mem.arena_allocator(&frame.working_arena)
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
