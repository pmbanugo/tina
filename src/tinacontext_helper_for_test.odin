package tina

import "core:mem"


Test_Context_Proc :: #type proc(user_data: rawptr, ctx: TinaContext)

Test_Context_Config :: struct {
	self_handle:         Handle,
	message_source:      Handle,
	correlation_id:      Correlation_Id,
	flags:               Context_Flags,
	monotonic_time_ns:   Monotonic_Time_NS,
	timer_resolution_ns: u64,
	shutting_down:       bool,
	working_memory_size: int,
}

Test_Local_Context_Config :: struct {
	self_handle:             Handle,
	target_handle:           Handle,
	monotonic_time_ns:       Monotonic_Time_NS,
	current_tick:            u64,
	flags:                   Context_Flags,
	timer_resolution_ns:     u64,
	target_mailbox_capacity: u32,
	target_state:            Isolate_State,
	working_memory_size:     int,
}

test_with_context :: proc(
	config: Test_Context_Config,
	user_data: rawptr,
	callback: Test_Context_Proc,
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
		current_time_ns        = u64(config.monotonic_time_ns),
		watchdog_state_pointer = &watchdog_state,
	}
	if shard.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1
		shard.current_tick = u64(config.monotonic_time_ns)
		shard.current_time_ns = u64(config.monotonic_time_ns)
	}

	spokes := make([]u32, 8)
	defer delete(spokes)
	entries := make([]Timer_Entry, 16)
	defer delete(entries)
	timer_wheel_init(&shard.timer_wheel, spokes, entries, shard.current_tick)
	renewable_deliver_at := make([]u64, 16)
	defer delete(renewable_deliver_at)
	renewable_target := make([]Handle, 16)
	defer delete(renewable_target)
	renewable_tag := make([]Message_Tag, 16)
	defer delete(renewable_tag)
	renewable_correlation := make([]Correlation_Id, 16)
	defer delete(renewable_correlation)
	renewable_armed_words := make([]u64, 1)
	defer delete(renewable_armed_words)
	timer_wheel_init_renewable(
		&shard.timer_wheel,
		renewable_deliver_at,
		renewable_target,
		renewable_tag,
		renewable_correlation,
		renewable_armed_words,
	)

	scratch_bytes := make([]u8, 4096)
	defer delete(scratch_bytes)

	working_size := config.working_memory_size
	if working_size == 0 do working_size = 4096
	working_bytes := make([]u8, working_size)
	defer delete(working_bytes)

	invocation := Isolate_Invocation {
		previous               = g_current_isolate_invocation,
		shard                  = shard,
		context_token          = make_tina_context_token(shard),
		self_handle            = config.self_handle,
		current_message_source = config.message_source,
		current_correlation    = config.correlation_id,
		flags                  = config.flags,
		timer_resolution_ns    = shard.timer_resolution_ns,
		current_tick           = u64(config.monotonic_time_ns) / shard.timer_resolution_ns,
		current_time_ns        = u64(config.monotonic_time_ns),
		type_id                = extract_type_id(config.self_handle),
		slot_index             = extract_slot(config.self_handle),
		shard_id               = shard.id,
	}
	mem.arena_init(&invocation.scratch_arena, scratch_bytes)
	mem.arena_init(&invocation.working_arena, working_bytes)

	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_isolate_invocation = &invocation
	context.allocator = mem.arena_allocator(&invocation.working_arena)
	context.temp_allocator = mem.arena_allocator(&invocation.scratch_arena)

	callback(user_data, invocation.context_token)

	context.allocator = previous_allocator
	context.temp_allocator = previous_temp_allocator
	g_current_isolate_invocation = invocation.previous
}

test_with_local_context :: proc(
	config: Test_Local_Context_Config,
	user_data: rawptr,
	callback: Test_Context_Proc,
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
		current_time_ns        = config.current_tick * max(u64(config.timer_resolution_ns), u64(1)),
		watchdog_state_pointer = &watchdog_state,
	}
	if shard.timer_resolution_ns == 0 {
		shard.timer_resolution_ns = 1
		shard.current_time_ns = config.current_tick
	}

	pool_backing := make([]u8, MESSAGE_ENVELOPE_SIZE * 8)
	defer delete(pool_backing)
	pool_init(&shard.message_pool, pool_backing, MESSAGE_ENVELOPE_SIZE)

	spokes := make([]u32, 8)
	defer delete(spokes)
	entries := make([]Timer_Entry, 16)
	defer delete(entries)
	timer_wheel_init(&shard.timer_wheel, spokes, entries, config.current_tick)
	renewable_deliver_at := make([]u64, 16)
	defer delete(renewable_deliver_at)
	renewable_target := make([]Handle, 16)
	defer delete(renewable_target)
	renewable_tag := make([]Message_Tag, 16)
	defer delete(renewable_tag)
	renewable_correlation := make([]Correlation_Id, 16)
	defer delete(renewable_correlation)
	renewable_armed_words := make([]u64, 1)
	defer delete(renewable_armed_words)
	timer_wheel_init_renewable(
		&shard.timer_wheel,
		renewable_deliver_at,
		renewable_target,
		renewable_tag,
		renewable_correlation,
		renewable_armed_words,
	)

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

	invocation := Isolate_Invocation {
		previous               = g_current_isolate_invocation,
		shard                  = shard,
		context_token          = make_tina_context_token(shard),
		self_handle            = config.self_handle,
		current_message_source = HANDLE_NONE,
		current_correlation    = CORRELATION_ID_NONE,
		flags                  = config.flags,
		timer_resolution_ns    = shard.timer_resolution_ns,
		current_tick           = config.current_tick,
		current_time_ns        = shard.current_time_ns,
		type_id                = extract_type_id(config.self_handle),
		slot_index             = extract_slot(config.self_handle),
		shard_id               = shard.id,
	}
	mem.arena_init(&invocation.scratch_arena, scratch_bytes)
	mem.arena_init(&invocation.working_arena, working_bytes)

	previous_allocator := context.allocator
	previous_temp_allocator := context.temp_allocator
	g_current_isolate_invocation = &invocation
	context.allocator = mem.arena_allocator(&invocation.working_arena)
	context.temp_allocator = mem.arena_allocator(&invocation.scratch_arena)

	callback(user_data, invocation.context_token)

	context.allocator = previous_allocator
	context.temp_allocator = previous_temp_allocator
	g_current_isolate_invocation = invocation.previous

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
