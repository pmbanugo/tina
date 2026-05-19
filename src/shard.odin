package tina

import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"

RECOVERY_TIER_3 :: 1
RECOVERY_WATCHDOG :: 2
RECOVERY_ROOT_ESCALATE :: 3
RECOVERY_SOFT_KILL :: 4

@(private = "package")
recovery_reason_label :: #force_inline proc "contextless" (reason: i32) -> string {
	@(static, rodata)
	labels := [5]string {
		"None",
		"Signal (SIGSEGV/BUS/FPE)",
		"Watchdog (SIGUSR1)",
		"Root Escalate",
		"Soft Kill",
	}
	if reason >= 0 && reason < i32(len(labels)) {
		return labels[reason]
	}
	return "Unknown"
}

@(thread_local)
g_current_shard_pointer: ^Shard

trigger_tier2_panic :: proc(shard: ^Shard) -> ! {
	os_trap_restore(&shard.trap_environment_inner, 1)
}

// --- Enums & Constants ---

Shard_State :: enum u8 {
	Init          = 0,
	Running       = 1,
	Quarantined   = 2,
	Shutting_Down = 3,
	Terminated    = 4,
}

Isolate_State :: enum u8 {
	Unallocated = 0,
	Runnable,
	Waiting,
	Waiting_For_Reply,
	Waiting_For_Io,
	Crashed,
}
Isolate_Flag :: enum u8 {
	Shutdown_Pending,
}
Isolate_Flags :: distinct bit_set[Isolate_Flag;u8]

// Mutually Exclusive Control Signals from Watchdog
Control_Signal :: enum u8 {
	None     = 0,
	Shutdown = 1,
	Kill     = 2,
}


// --- Core Data Structures ---

// Isolate metadata
Isolate_Metadata :: struct {
	io_peer_address:       Peer_Address,
	inbox_head:            u32,
	inbox_tail:            u32,
	pending_correlation:   Correlation_Id,
	io_fd:                 FD_Handle,
	io_result:             i32,
	pending_transfer_read: Transfer_Handle,
	generation:            u32,
	working_arena_offset:  u32,
	inbox_count:           u16,
	group_id:              Supervision_Group_Id,
	io_completion_tag:     IO_Completion_Tag,
	io_buffer_index:       u16,
	state:                 Isolate_State,
	flags:                 Isolate_Flags, // Replaces shutdown_pending: u8
	io_sequence:           u8,
}

Shard_Counters :: struct {
	stale_delivery_drops:      u64,
	ring_full_drops:           u64,
	quarantine_drops:          u64,
	pool_exhaustion_drops:     u64,
	mailbox_full_drops:        u64,
	io_buffer_exhaustions:     u64,
	io_submission_exhaustions: u64,
	io_stale_completions:      u64, // TODO: In simulation, consider verifying that this counter
	// equals the number of timer-wakes + shutdown-wakes that
	// interrupted WAITING_FOR_IO Isolates. A mismatch would indicate
	// a stale completion was lost (buffer leak) or double-counted.
	// Might require tracking a separate "io_wakes" counter to compare against.
	transfer_exhaustions:      u64,
	transfer_stale_reads:      u64,
	handoff_exhaustions:       u64,
	handoff_timeouts:          u64,
	handoff_rejects:           u64,
	handoff_control_send_failures:    u64,
	handoff_control_retry_exhaustions: u64,
	handoff_control_retry_drops:      u64,
}

Dynamic_Child_Spec :: struct {
	args_payload: [MAX_INIT_ARGS_SIZE]u8,
	type_id:      Type_Id,
	restart_type: Restart_Type,
	args_size:    u8,
	_padding:     [5]u8,
}

Supervision_Group :: struct {
	children_handles:      []Handle,
	dynamic_specs:         []Dynamic_Child_Spec,
	boot_spec:             ^Group_Spec,
	window_start_tick:     u64,
	window_duration_ticks: u32,
	group_id:              Supervision_Group_Id,
	parent_id:             Supervision_Group_Id,
	child_count_static:    u16,
	child_count_dynamic:   u16,
	restart_count:         u16,
	restart_count_max:     u16,
	strategy:              Supervision_Strategy,
	_padding:              [3]u8,
}

when TINA_SIMULATION_MODE {
	Simulation_State :: struct {
		network:      ^SimulatedNetwork,
		fault_config: ^FaultConfig,
		crash_prng:   ^Prng,
	}
	Sim_State_Mixin :: struct {
		sim_state: Simulation_State,
	}
} else {
	Sim_State_Mixin :: struct {}
}

@(private = "package")
Shard :: struct {
	// --- Hot Pointers & Slices (8-byte aligned) ---
	outbound_rings:         []^SPSC_Ring,
	inbound_rings:          []^SPSC_Ring,
	type_descriptors:       []TypeDescriptor,
	isolate_free_heads:     []u32, // free list heads per Isolate Type
	dispatch_cursors:       []u32, // Resumption index for budgeted dispatch
	dispatch_credit_counts: []Scheduler_Credit_Count,
	dispatchable_slot_words: [][]u64,
	dispatchable_slot_counts: []u32,
	dispatchable_type_words: []u64,
	dispatch_ready_type_words: []u64,
	isolate_memory:         [][]u8,
	working_memory:         [][]u8, // Base slices for working memory
	scratch_memory:         []u8, // Base slice for scratch arena
	transfer_generations:   []u16,
	metadata:               []#soa[]Isolate_Metadata,
	supervision_groups:     []Supervision_Group,
	handoff_table:          FD_Handoff_Table,

	// --- Hot Embedded Structs (8-byte aligned) ---
	log_ring:               Log_Ring_Buffer,
	message_pool:           Message_Pool,
	transfer_pool:          Reactor_Buffer_Pool,
	counters:               Shard_Counters,

	// --- Hot Scalars (Ordered largest to smallest) ---
	current_tick:           u64, // The current time quantized to the resolution
	timer_resolution_ns:    u64, // E.g., 1_000_000 for 1ms ticks
	heartbeat_tick:         u64,
	next_context_token:     u64,
	next_correlation_id:    Correlation_Id,
	handoff_retry_head:     u32,
	handoff_retry_tail:     u32,
	handoff_retry_count:    u32,
	current_msg_slot:       u32,
	current_slot_index:     u32,
	dispatch_type_cursor:   u32,
	id:                     Shard_Id,
	shard_count:            u8,
	current_type_id:        u16,
	peer_alive_mask:        Shard_Mask, // Tracks up to 256 peers. Bit N = 1 if Shard N is alive
	control_signal:         Control_Signal, // Atomic, mutually exclusive signals from watchdog
	_padding:               [4]u8,
	watchdog_state_pointer: ^u8, // Points to external watchdog state (config or simulator backing)

	// --- Cold / Massive Storage ---
	timer_wheel:            Timer_Wheel,
	trap_environment_outer: OS_Trap_Environment,
	trap_environment_inner: OS_Trap_Environment,
	reactor:                Reactor,

	// Placed at the end to prevent possible cache-line shifting of hot fields.
	using _sim_mixin:       Sim_State_Mixin,
}

@(private = "file")
Dispatch_Kind :: enum u8 {
	None,
	Runnable,
	Inbox,
	Shutdown,
	Io_Completion,
}

@(private = "file")
_wake_type_for_shutdown :: proc "contextless" (shard: ^Shard, type_id: u16, slot_count: u32) {
	states := shard.metadata[type_id].state[:]
	flags := shard.metadata[type_id].flags[:]
	io_sequences := shard.metadata[type_id].io_sequence[:]
	pending_correlations := shard.metadata[type_id].pending_correlation[:]

	for slot_index in 0 ..< slot_count {
		if states[slot_index] == .Unallocated do continue
		_slot_add_shutdown_pending(shard, type_id, slot_index)
	}

	for slot_index in 0 ..< slot_count {
		state := states[slot_index]
		if state == .Waiting {
			_slot_set_state(shard, type_id, slot_index, .Runnable)
			continue
		}
		if state == .Waiting_For_Io {
			// Invalidate pending completion via io_sequence bump.
			// No explicit backend_cancel — the stale completion will
			// arrive naturally, fail the io_sequence check in
			// reactor_collect_completions, and have its buffer freed
			// by the stale-path reclamation. See §6.6.3 §12 design note.
			io_sequences[slot_index] += 1
			_slot_set_state(shard, type_id, slot_index, .Runnable)
			continue
		}
		if state == .Waiting_For_Reply {
			// Discard stale replies.
			pending_correlations[slot_index] = 0
			_slot_set_state(shard, type_id, slot_index, .Runnable)
		}
	}
}

@(private = "file")
_handle_shard_control_signal :: proc(shard: ^Shard) {
	switch load_shard_control_signal(shard) {
	case .None:
		return
	case .Shutdown:
		store_shard_control_signal(shard, .None)
		store_watchdog_state(shard, .Shutting_Down)

		for type_descriptor in shard.type_descriptors {
			_wake_type_for_shutdown(shard, u16(type_descriptor.id), u32(type_descriptor.slot_count))
		}

		_fd_handoff_close_all_entries(shard, true)
	case .Kill:
		os_trap_restore(&shard.trap_environment_outer, RECOVERY_SOFT_KILL)
	}
}

@(private = "file")
_dispatch_kind_for_slot :: #force_inline proc "contextless" (
	state: Isolate_State,
	flags: Isolate_Flags,
	inbox_count: u16,
	io_completion_tag: IO_Completion_Tag,
) -> Dispatch_Kind {
	if state == .Unallocated {
		return .None
	}
	if io_completion_tag != IO_TAG_NONE {
		return .Io_Completion
	}
	if .Shutdown_Pending in flags {
		return .Shutdown
	}
	if inbox_count > 0 && (state == .Runnable || state == .Waiting) {
		return .Inbox
	}
	if state == .Runnable {
		return .Runnable
	}
	return .None
}

@(private = "package")
_dispatch_word_count :: #force_inline proc "contextless" (bit_count: int) -> int {
	if bit_count <= 0 {
		return 0
	}
	return (bit_count + 63) / 64
}

@(private = "file")
_bitset_set :: #force_inline proc "contextless" (words: []u64, bit_index: u32) {
	if len(words) == 0 {
		return
	}
	word_index := int(bit_index >> 6)
	bit_offset := bit_index & 63
	words[word_index] |= u64(1) << bit_offset
}

@(private = "file")
_bitset_clear :: #force_inline proc "contextless" (words: []u64, bit_index: u32) {
	if len(words) == 0 {
		return
	}
	word_index := int(bit_index >> 6)
	bit_offset := bit_index & 63
	words[word_index] &= ~(u64(1) << bit_offset)
}

@(private = "file")
_dispatchable_type_refresh :: #force_inline proc "contextless" (shard: ^Shard, type_id: u16) {
	if int(type_id) >= len(shard.dispatchable_slot_counts) {
		return
	}
	bit_index := u32(type_id)
	if shard.dispatchable_slot_counts[type_id] > 0 {
		_bitset_set(shard.dispatchable_type_words, bit_index)
	} else {
		_bitset_clear(shard.dispatchable_type_words, bit_index)
	}

	if int(type_id) < len(shard.dispatch_credit_counts) &&
	   shard.dispatchable_slot_counts[type_id] > 0 &&
	   shard.dispatch_credit_counts[type_id] > 0 {
		_bitset_set(shard.dispatch_ready_type_words, bit_index)
	} else {
		_bitset_clear(shard.dispatch_ready_type_words, bit_index)
	}
}

@(private = "file")
_dispatchable_slot_set_present :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	if int(type_id) >= len(shard.dispatchable_slot_words) {
		return
	}
	words := shard.dispatchable_slot_words[type_id]
	if len(words) == 0 {
		return
	}
	word_index := int(slot_index >> 6)
	bit_offset := slot_index & 63
	bit_mask := u64(1) << bit_offset
	if words[word_index] & bit_mask != 0 {
		return
	}
	words[word_index] |= bit_mask
	shard.dispatchable_slot_counts[type_id] += 1
	_dispatchable_type_refresh(shard, type_id)
}

@(private = "file")
_dispatchable_slot_set_absent :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	if int(type_id) >= len(shard.dispatchable_slot_words) {
		return
	}
	words := shard.dispatchable_slot_words[type_id]
	if len(words) == 0 {
		return
	}
	word_index := int(slot_index >> 6)
	bit_offset := slot_index & 63
	bit_mask := u64(1) << bit_offset
	if words[word_index] & bit_mask == 0 {
		return
	}
	words[word_index] &= ~bit_mask
	shard.dispatchable_slot_counts[type_id] -= 1
	_dispatchable_type_refresh(shard, type_id)
}

@(private = "package")
_dispatchable_refresh_slot :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	if int(type_id) >= len(shard.metadata) {
		return
	}
	soa_meta := shard.metadata[type_id]
	if int(slot_index) >= len(soa_meta) {
		return
	}
	dispatch_kind := _dispatch_kind_for_slot(
		soa_meta[slot_index].state,
		soa_meta[slot_index].flags,
		soa_meta[slot_index].inbox_count,
		soa_meta[slot_index].io_completion_tag,
	)
	if dispatch_kind == .None {
		_dispatchable_slot_set_absent(shard, type_id, slot_index)
	} else {
		_dispatchable_slot_set_present(shard, type_id, slot_index)
	}
}

@(private = "file")
_bitset_find_next_set_bit :: proc "contextless" (
	words: []u64,
	start_bit_index: u32,
	bit_count: u32,
) -> (
	u32,
	bool,
) {
	if len(words) == 0 || bit_count == 0 {
		return 0, false
	}

	start_word_index := int(start_bit_index >> 6)
	start_bit_offset := start_bit_index & 63
	last_word_index := len(words) - 1
	last_word_bit_count := bit_count & 63
	last_word_mask := ~u64(0)
	if last_word_bit_count != 0 {
		last_word_mask = (u64(1) << last_word_bit_count) - 1
	}

	for word_index in start_word_index ..< len(words) {
		word := words[word_index]
		if word_index == last_word_index {
			word &= last_word_mask
		}
		if word_index == start_word_index && start_bit_offset > 0 {
			word &= ~((u64(1) << start_bit_offset) - 1)
		}
		if word == 0 {
			continue
		}

		bit_offset := bits.trailing_zeros(word)
		bit_index := u32(word_index * 64) + u32(bit_offset)
		if bit_index < bit_count {
			return bit_index, true
		}
	}

	if start_word_index > 0 || start_bit_offset > 0 {
		for word_index in 0 ..< min(start_word_index + 1, len(words)) {
			word := words[word_index]
			if word_index == last_word_index {
				word &= last_word_mask
			}
			if word_index == start_word_index {
				if start_bit_offset == 0 {
					break
				}
				word &= (u64(1) << start_bit_offset) - 1
			}
			if word == 0 {
				continue
			}

			bit_offset := bits.trailing_zeros(word)
			bit_index := u32(word_index * 64) + u32(bit_offset)
			if bit_index < bit_count {
				return bit_index, true
			}
		}
	}

	return 0, false
}

@(private = "file")
_dispatchable_find_next_slot :: proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	start_slot_index: u32,
	slot_count: u32,
) -> (
	u32,
	bool,
) {
	return _bitset_find_next_set_bit(shard.dispatchable_slot_words[type_id], start_slot_index, slot_count)
}

@(private = "package")
_slot_set_state :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
	state: Isolate_State,
) {
	shard.metadata[type_id][slot_index].state = state
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_set_waiting_for_reply :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
	correlation_id: Correlation_Id,
) {
	shard.metadata[type_id][slot_index].pending_correlation = correlation_id
	shard.metadata[type_id][slot_index].state = .Waiting_For_Reply
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_set_io_completion_tag :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
	completion_tag: IO_Completion_Tag,
) {
	shard.metadata[type_id][slot_index].io_completion_tag = completion_tag
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_add_shutdown_pending :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	shard.metadata[type_id][slot_index].flags += {.Shutdown_Pending}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_clear_shutdown_pending :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	shard.metadata[type_id][slot_index].flags -= {.Shutdown_Pending}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_increment_inbox_count :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	shard.metadata[type_id][slot_index].inbox_count += 1
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_decrement_inbox_count :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
) {
	shard.metadata[type_id][slot_index].inbox_count -= 1
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_set_io_completion_ready :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
	completion_tag: IO_Completion_Tag,
	completion_result: i32,
	buffer_index: u16,
) {
	meta := &shard.metadata[type_id][slot_index]
	meta.io_completion_tag = completion_tag
	meta.io_result = completion_result
	meta.io_buffer_index = buffer_index
	if meta.state == .Waiting_For_Io {
		meta.state = .Runnable
	}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_set_io_submit_failure :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot_index: u32,
	completion_tag: IO_Completion_Tag,
	completion_result: i32,
) {
	meta := &shard.metadata[type_id][slot_index]
	meta.io_completion_tag = completion_tag
	meta.io_result = completion_result
	meta.io_buffer_index = BUFFER_INDEX_NONE
	meta.state = .Runnable
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "file")
_dispatch_ready_find_next_type :: proc "contextless" (
	shard: ^Shard,
	start_type_index: u32,
	type_count: u32,
) -> (
	u32,
	bool,
) {
	return _bitset_find_next_set_bit(shard.dispatch_ready_type_words, start_type_index, type_count)
}

@(private = "file")
_dispatch_type_batch :: proc(
	shard: ^Shard,
	type_descriptor: TypeDescriptor,
	work_budget_count: Scheduler_Work_Count,
) -> Scheduler_Work_Count {
	if work_budget_count == 0 {
		return 0
	}

		type_id := u16(type_descriptor.id)
	slot_count := u32(type_descriptor.slot_count)

	// Hoisted
	invocation := Isolate_Invocation {
		previous               = g_current_isolate_invocation,
		shard                  = shard,
		context_token          = 0, // Assigned per invocation
		self_handle            = HANDLE_NONE, // Assigned per invocation
		current_message_source = HANDLE_NONE, // Assigned per invocation
		current_correlation    = CORRELATION_ID_NONE, // Assigned per invocation
		flags                  = {}, // Assigned per invocation
		timer_resolution_ns    = shard.timer_resolution_ns,
		current_tick           = shard.current_tick,
		type_id                = u16(type_id),
		slot_index             = 0, // Assigned per invocation
		shard_id               = shard.id,
	}

	// Extract 1D slices to bypass 2D lookups for the entire dispatch inner-loop.
	states := shard.metadata[type_id].state[:]
	flags := shard.metadata[type_id].flags[:]
	inbox_counts := shard.metadata[type_id].inbox_count[:]
	io_completions := shard.metadata[type_id].io_completion_tag[:]
	generations := shard.metadata[type_id].generation[:]
	io_results := shard.metadata[type_id].io_result[:]
	io_fds := shard.metadata[type_id].io_fd[:]
	io_buffer_indices := shard.metadata[type_id].io_buffer_index[:]
	io_peer_addresses := shard.metadata[type_id].io_peer_address[:]
	working_arena_offsets := shard.metadata[type_id].working_arena_offset[:]
	pending_transfer_reads := shard.metadata[type_id].pending_transfer_read[:]

	dispatch_budget := u32(work_budget_count)
	dispatched_count: u32 = 0

	shard.current_type_id = u16(type_id)

	if os_trap_save(&shard.trap_environment_inner) != 0 {
		when !TINA_SIMULATION_MODE {
			// Sweep orphaned temp allocations from panic string formatting.
			free_all(context.temp_allocator)
			// Unblock signals masked by the OS during handler execution.
			os_signals_restore_thread_mask()
		}

		if shard.current_msg_slot != POOL_NONE_INDEX {
			pool_free_unchecked(&shard.message_pool, shard.current_msg_slot)
			shard.current_msg_slot = POOL_NONE_INDEX
		}
		_teardown_isolate(shard, shard.current_type_id, shard.current_slot_index, .Crashed)

		// Advance the cursor past the crashed isolate.
		next_cursor := shard.current_slot_index + 1
		if next_cursor >= slot_count do next_cursor = 0
		shard.dispatch_cursors[type_id] = next_cursor
	}

	cursor := shard.dispatch_cursors[type_id]
	if cursor >= slot_count {
		cursor = 0
		shard.dispatch_cursors[type_id] = 0
	}

	slot_loop: for dispatched_count < dispatch_budget {
		slot_index, found := _dispatchable_find_next_slot(shard, type_id, cursor, slot_count)
		if !found {
			shard.dispatch_cursors[type_id] = 0
			break slot_loop
		}

		next_cursor := slot_index + 1
		if next_cursor >= slot_count do next_cursor = 0
		shard.dispatch_cursors[type_id] = next_cursor

		dispatch_kind := _dispatch_kind_for_slot(
			states[slot_index],
			flags[slot_index],
			inbox_counts[slot_index],
			io_completions[slot_index],
		)
		if dispatch_kind == .None {
			_dispatchable_slot_set_absent(shard, type_id, slot_index)
			cursor = shard.dispatch_cursors[type_id]
			continue
		}
		dispatched_count += 1

		shard.current_slot_index = slot_index
		shard.current_msg_slot = POOL_NONE_INDEX

		message: Message
		message_pointer: ^Message = nil
		correlation: Correlation_Id = CORRELATION_ID_NONE
		envelope_flags: Envelope_Flags = {}

		is_io_completion := false
		buffer_to_free: u16 = BUFFER_INDEX_NONE

		switch dispatch_kind {
		case .None:
		case .Io_Completion:
			message.tag = io_completions[slot_index]
			message.correlation = CORRELATION_ID_NONE
			message.io.result = io_results[slot_index]
			message.io.fd = io_fds[slot_index]
			message.io.buffer_index = io_buffer_indices[slot_index]
			message.io.peer_address = io_peer_addresses[slot_index]

			message_pointer = &message
			is_io_completion = true
			buffer_to_free = io_buffer_indices[slot_index]
		case .Shutdown:
			message.tag = TAG_SHUTDOWN
			message.correlation = CORRELATION_ID_NONE
			message.user.source = HANDLE_NONE
			message.user.payload_size = 0

			message_pointer = &message
			_slot_clear_shutdown_pending(shard, type_id, slot_index)
		case .Inbox:
			dequeue_result := _dequeue(shard, u16(type_id), slot_index)
			shard.current_msg_slot = dequeue_result.pool_index
			if shard.current_msg_slot != POOL_NONE_INDEX {
				message = dequeue_result.message
				message.correlation = dequeue_result.correlation
				correlation = dequeue_result.correlation
				envelope_flags = dequeue_result.flags
				message_pointer = &message
			}
		case .Runnable:
		}

		ctx_flags: Context_Flags
		if .Is_Call in envelope_flags do ctx_flags += {.Is_Call}

		invocation.context_token = make_tina_context_token(shard)
		invocation.self_handle = make_handle(
			shard.id,
			u16(type_id),
			slot_index,
			generations[slot_index],
		)
		invocation.current_message_source = message_pointer != nil && !is_io_completion && message.tag != TAG_SHUTDOWN ? message.user.source : HANDLE_NONE
		invocation.current_correlation = correlation
		invocation.flags = ctx_flags
		invocation.slot_index = slot_index
		ctx := invocation.context_token

		mem.arena_init(&invocation.scratch_arena, shard.scratch_memory)

		working_stride := type_descriptor.working_memory_size
		if working_stride > 0 {
			start_index := int(slot_index) * working_stride
			working_slice := shard.working_memory[type_id][start_index:start_index + working_stride]
			invocation.working_arena = mem.Arena {
				data   = working_slice,
				offset = int(working_arena_offsets[slot_index]),
			}
		} else {
			invocation.working_arena = {}
		}

		isolate_pointer := _get_isolate_ptr(shard, u16(type_id), slot_index)

		when TINA_SIMULATION_MODE {
			if ratio_chance(
				shard.sim_state.fault_config.isolate_crash_rate,
				shard.sim_state.crash_prng,
			) {
				if shard.current_msg_slot != POOL_NONE_INDEX {
					pool_free_unchecked(&shard.message_pool, shard.current_msg_slot)
					shard.current_msg_slot = POOL_NONE_INDEX
				}
				_teardown_isolate(shard, u16(type_id), slot_index, .Crashed)
				cursor = shard.dispatch_cursors[type_id]
				continue slot_loop
			}
		}

		previous_allocator := context.allocator
		previous_temp_allocator := context.temp_allocator
		g_current_isolate_invocation = &invocation
		context.allocator = mem.arena_allocator(&invocation.working_arena)
		context.temp_allocator = mem.arena_allocator(&invocation.scratch_arena)

		effect := type_descriptor.handler_fn(isolate_pointer, message_pointer, ctx)

		context.allocator = previous_allocator
		context.temp_allocator = previous_temp_allocator
		g_current_isolate_invocation = invocation.previous

		if working_stride > 0 {
			working_arena_offsets[slot_index] = u32(invocation.working_arena.offset)
		}

		if is_io_completion {
			io_completions[slot_index] = IO_TAG_NONE
			io_peer_addresses[slot_index] = {}
			if buffer_to_free != BUFFER_INDEX_NONE {
				reactor_buffer_pool_free(&shard.reactor.buffer_pool, buffer_to_free)
			}
		}

		if pending_transfer_reads[slot_index] != TRANSFER_HANDLE_NONE {
			t_handle := pending_transfer_reads[slot_index]
			_transfer_pool_free(shard, transfer_handle_index(t_handle))
			pending_transfer_reads[slot_index] = TRANSFER_HANDLE_NONE
		}

		if shard.current_msg_slot != POOL_NONE_INDEX {
			pool_free_unchecked(&shard.message_pool, shard.current_msg_slot)
			shard.current_msg_slot = POOL_NONE_INDEX
		}

		_interpret_effect(shard, u16(type_id), slot_index, effect, &invocation)
		cursor = shard.dispatch_cursors[type_id]
	}

	return Scheduler_Work_Count(dispatched_count)
}

@(private = "file")
_scheduler_dispatch_batch_count_limit :: #force_inline proc "contextless" (
	credit_count: u32,
	turn_work_budget_count: u32,
	dispatch_since_io_service_count: u32,
) -> u32 {
	type_dispatch_batch_count_max := u32(SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX)
	io_service_interval_count := u32(SCHEDULER_IO_SERVICE_INTERVAL_COUNT)
	io_service_remaining_count := io_service_interval_count - dispatch_since_io_service_count

	batch_count := min(credit_count, type_dispatch_batch_count_max)
	batch_count = min(batch_count, turn_work_budget_count)
	batch_count = min(batch_count, io_service_remaining_count)
	return batch_count
}

@(private = "file")
_scheduler_replenish_dispatch_credits :: proc(shard: ^Shard) {
	credit_count_max := u32(SCHEDULER_CREDIT_COUNT_MAX)
	credit_per_weight_count := u32(SCHEDULER_CREDIT_PER_WEIGHT_COUNT)

	for type_descriptor, type_index in shard.type_descriptors {
		weight_count := u32(type_descriptor.budget_weight)
		if weight_count == 0 do weight_count = 1

		credit_count := u32(shard.dispatch_credit_counts[type_index])
		credit_count += weight_count * credit_per_weight_count
		if credit_count > credit_count_max do credit_count = credit_count_max
		shard.dispatch_credit_counts[type_index] = Scheduler_Credit_Count(credit_count)
		_dispatchable_type_refresh(shard, u16(type_index))
	}
}

@(private = "file")
_scheduler_run_dispatch_turn :: proc(shard: ^Shard) {
	type_count := u32(len(shard.type_descriptors))
	if type_count == 0 {
		return
	}

	turn_work_budget_count := u32(SCHEDULER_TURN_WORK_BUDGET_COUNT)
	io_service_interval_count := u32(SCHEDULER_IO_SERVICE_INTERVAL_COUNT)
	dispatch_since_io_service_count: u32 = 0
	scanned_type_count: u32 = 0

	for turn_work_budget_count > 0 && scanned_type_count < type_count {
		if dispatch_since_io_service_count >= io_service_interval_count {
			reactor_service_nonblocking(&shard.reactor, shard)
			dispatch_since_io_service_count = 0
		}

		type_index, found := _dispatch_ready_find_next_type(shard, shard.dispatch_type_cursor, type_count)
		if !found {
			break
		}
		shard.dispatch_type_cursor = type_index + 1
		if shard.dispatch_type_cursor >= type_count do shard.dispatch_type_cursor = 0
		scanned_type_count += 1

		credit_count := u32(shard.dispatch_credit_counts[type_index])
		if credit_count == 0 {
			_dispatchable_type_refresh(shard, u16(type_index))
			continue
		}

		type_work_budget_count := _scheduler_dispatch_batch_count_limit(
			credit_count,
			turn_work_budget_count,
			dispatch_since_io_service_count,
		)

		dispatched_count := u32(_dispatch_type_batch(
			shard,
			shard.type_descriptors[type_index],
			Scheduler_Work_Count(type_work_budget_count),
		))

		if dispatched_count == 0 {
			_dispatchable_type_refresh(shard, u16(type_index))
			continue
		}

		scanned_type_count = 0
		shard.dispatch_credit_counts[type_index] = Scheduler_Credit_Count(credit_count - dispatched_count)
		_dispatchable_type_refresh(shard, u16(type_index))
		turn_work_budget_count -= dispatched_count
		dispatch_since_io_service_count += dispatched_count

		if dispatch_since_io_service_count >= io_service_interval_count {
			reactor_service_nonblocking(&shard.reactor, shard)
			dispatch_since_io_service_count = 0
		}
	}
}

scheduler_tick :: proc(shard: ^Shard) {
	_handle_shard_control_signal(shard)

	when !TINA_SIMULATION_MODE {
		now_ns := os_monotonic_time_ns()
		// Quantize to timer wheel ticks.
		// If timer_resolution_ns is a power of 2, the compiler should be able to
		// turn this into a bit-shift.
		shard.current_tick = now_ns / shard.timer_resolution_ns
		// Watchdog heartbeat
		sync.atomic_store_explicit(&shard.heartbeat_tick, shard.current_tick, .Relaxed)
	}
	now := shard.current_tick
	backend_set_current_tick(&shard.reactor.backend, now)

	// ========================================================================
	// Step 1: Drain inbound cross-shard rings → deliver to local mailboxes
	// ========================================================================
	transport_drain_inbound(shard, now)

	// ========================================================================
	// Step 2: Initial nonblocking I/O service point
	// ========================================================================
	reactor_service_nonblocking(&shard.reactor, shard)

	// ========================================================================
	// Step 3: Replenish credits and run weighted dispatch
	// ========================================================================
	_scheduler_replenish_dispatch_credits(shard)
	_scheduler_run_dispatch_turn(shard)

	// ========================================================================
	// Step 4: Final I/O service point and handoff scans
	// ========================================================================
	reactor_flush_submissions(&shard.reactor, shard)
	reactor_service_nonblocking(&shard.reactor, shard)
	_fd_handoff_retry_scan(shard)
	_fd_handoff_timeout_scan(shard, now)

	// ========================================================================
	// Step 5: Flush outbound cross-shard rings
	// ========================================================================
	transport_flush_outbound(shard)

	// ========================================================================
	// Step 6 & 7: Advance timers and Flush logs
	// ========================================================================
	_advance_timers(shard)
	log_flush(shard)
}

// --- Effect Interpreter ---

@(rodata, private = "package")
CRASH_REASONS_INTERPRETED := [Crash_Reason]string {
	.None                 = "Voluntary crash reason: None",
	.Spawn_Failed         = "Voluntary crash reason: Spawn_Failed",
	.Unimplemented_Effect = "Voluntary crash reason: Unimplemented_Effect",
	.Init_Failed          = "Voluntary crash reason: Init_Failed",
}

_interpret_effect :: proc(
	shard: ^Shard,
	type_id: u16,
	slot: u32,
	effect: Effect,
	invocation: ^Isolate_Invocation,
) {
	soa_meta := shard.metadata[type_id]
	switch e in effect {
	case Effect_Done:
		_teardown_isolate(shard, type_id, slot, .Normal)
	case Effect_Yield:
		_slot_set_state(shard, type_id, slot, .Runnable)
	case Effect_Receive:
		_slot_set_state(shard, type_id, slot, .Waiting)
	case Effect_Crash:
		reason_str := CRASH_REASONS_INTERPRETED[e.reason]
		_shard_log(
			shard,
			invocation.self_handle,
			.ERROR,
			LOG_TAG_ISOLATE_CRASHED,
			transmute([]u8)reason_str,
		)
		_teardown_isolate(shard, type_id, slot, .Crashed)
	case Effect_Call:
		shard.next_correlation_id += 1
		if shard.next_correlation_id == 0 do shard.next_correlation_id = 1
		correlation_id := shard.next_correlation_id

		// Set state before fast-fail enqueue so the timeout message is accepted
		_slot_set_waiting_for_reply(shard, type_id, slot, correlation_id)

		// Quarantine Fast-Fail Check (§6.4.5.4 Step 4b)
		destination_shard := extract_shard_id(e.to)
		if destination_shard != shard.id &&
		   !shard_mask_contains(&shard.peer_alive_mask, destination_shard) {
			// Target is dead. Abort .call setup and fast-fail with an immediate timeout.
			timeout_env: Message_Envelope
			timeout_env.source = HANDLE_NONE
			timeout_env.destination = invocation.self_handle
			timeout_env.tag = TAG_CALL_TIMEOUT
			timeout_env.correlation = correlation_id

			_enqueue_system_msg(shard, invocation.self_handle, &timeout_env)
			shard.counters.quarantine_drops += 1
			return
		}

		timeout_ticks := (e.timeout + shard.timer_resolution_ns - 1) / shard.timer_resolution_ns
		_register_system_timer(
			shard,
			invocation.self_handle,
			timeout_ticks,
			TAG_CALL_TIMEOUT,
			correlation_id,
		)

		local_msg := e.message // Make "e.message" it addressable
		envelope: Message_Envelope
		envelope.source = invocation.self_handle
		envelope.destination = e.to
		envelope.correlation = correlation_id
		envelope.flags += {.Is_Call}
		envelope.tag = local_msg.tag
		envelope.payload_size = local_msg.user.payload_size
		copy(envelope.payload[:], local_msg.user.payload[:])

		_route_envelope_user(shard, e.to, &envelope)

	case Effect_Reply:
		if .Is_Call not_in invocation.flags {
			// if !(.Is_Call in ctx.flags) {
			_shard_log(
				shard,
				invocation.self_handle,
				.ERROR,
				LOG_TAG_ISOLATE_CRASHED,
				transmute([]u8)string("Reply effect without call context"),
			)
			_teardown_isolate(shard, type_id, slot, .Crashed)
			return
		}
		_slot_set_state(shard, type_id, slot, .Waiting)

		local_msg := e.message // Make "e.message" it addressable
		envelope: Message_Envelope
		envelope.source = invocation.self_handle
		envelope.destination = invocation.current_message_source
		envelope.correlation = invocation.current_correlation
		envelope.flags += {.Is_Reply}
		envelope.tag = local_msg.tag
		envelope.payload_size = local_msg.user.payload_size
		copy(envelope.payload[:], local_msg.user.payload[:])

		_route_envelope_user(shard, invocation.current_message_source, &envelope)

	case Effect_Io:
		err := reactor_submit_io(&shard.reactor, shard, invocation.self_handle, e.operation)
		if err != IO_ERR_NONE {
			if err == IO_ERR_RESOURCE_EXHAUSTED do shard.counters.io_buffer_exhaustions += 1
			_slot_set_io_submit_failure(
				shard,
				type_id,
				slot,
				_io_op_to_completion_tag(e.operation),
				i32(err),
			)
		} else {
			_slot_set_state(shard, type_id, slot, .Waiting_For_Io)
		}
	}
}

// --- Message Routing ---

@(private = "package")
_route_envelope_user :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, true)
}

@(private = "package")
_route_envelope_system :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, false)
}

@(private = "file")
_route_envelope_internal :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
	is_user: bool,
) -> Send_Result {
	destination := extract_shard_id(to)

	if destination == shard.id {
		return _enqueue_internal(shard, to, envelope, is_user)
	} else {
		return transport_route_envelope(shard, destination, envelope)
	}
}

@(private = "package")
_enqueue_user_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, true)
}

@(private = "package")
_enqueue_system_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, false)
}

// Hot path: must remain contextless (no assert/fmt/make/default-allocator calls).
// Index validity is structurally guaranteed by pool alloc/free lifecycle.
@(private = "file")
_enqueue_internal :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Handle,
	envelope: ^Message_Envelope,
	is_user: bool,
) -> Send_Result {
	type_id := extract_type_id(to)
	slot := extract_slot(to)
	soa_meta := shard.metadata[type_id]

	if soa_meta[slot].generation != extract_generation(to) {
		shard.counters.stale_delivery_drops += 1
		return .stale_handle
	}

	is_reply := .Is_Reply in envelope.flags
	is_timeout := envelope.tag == TAG_CALL_TIMEOUT

	// Validation Only (No Mutation Yet)
	if is_reply || is_timeout {
		if soa_meta[slot].state != .Waiting_For_Reply ||
		   soa_meta[slot].pending_correlation != envelope.correlation {
			shard.counters.stale_delivery_drops += 1
			return .stale_handle
		}
	} else if is_user {
		// Capacity Check ONLY for normal user messages
		// Replies and timeouts bypass mailbox limits to prevent deadlocks
		if soa_meta[slot].inbox_count >= shard.type_descriptors[type_id].mailbox_capacity {
			shard.counters.mailbox_full_drops += 1
			return .mailbox_full
		}
	}

	// Pool Allocation
	pool_index: u32
	err: Pool_Error
	// Because `is_user` is passed as a constant from the wrapper,
	// I expect the compiler will dead-code-eliminate this IF statement.
	if is_user {
		pool_index, err = pool_alloc_user(&shard.message_pool)
	} else {
		pool_index, err = pool_alloc_system(&shard.message_pool)
	}

	if err != .None {
		shard.counters.pool_exhaustion_drops += 1
		return .pool_exhausted
	}

	// Safe State Mutation (We are guaranteed to enqueue now)
	if is_reply || is_timeout {
		soa_meta[slot].pending_correlation = 0
		_slot_set_state(shard, type_id, slot, .Runnable)
	}

	// Link into Mailbox
	envelope_destination := pool_get_ptr_unchecked(
		&shard.message_pool,
		pool_index,
	)
	envelope_destination^ = envelope^
	envelope_destination.next_in_mailbox = POOL_NONE_INDEX

	if soa_meta[slot].inbox_head == POOL_NONE_INDEX {
		soa_meta[slot].inbox_head = pool_index
	} else {
		tail_envelope := pool_get_ptr_unchecked(
			&shard.message_pool,
			soa_meta[slot].inbox_tail,
		)
		tail_envelope.next_in_mailbox = pool_index
	}

	soa_meta[slot].inbox_tail = pool_index
	_slot_increment_inbox_count(shard, type_id, slot)

	if soa_meta[slot].state == .Waiting {
		_slot_set_state(shard, type_id, slot, .Runnable)
	}
	return .ok
}

@(private = "package")
Dequeue_Result :: struct {
	pool_index:   u32,
	correlation:  Correlation_Id,
	message:      Message,
	flags:        Envelope_Flags,
}

@(private = "package")
_dequeue :: proc "contextless" (
	shard: ^Shard,
	type_id: u16,
	slot: u32,
) -> Dequeue_Result {
	result := Dequeue_Result {
		pool_index = POOL_NONE_INDEX,
	}

	soa_meta := shard.metadata[type_id]
	head_index := soa_meta[slot].inbox_head
	if head_index == POOL_NONE_INDEX {return result}

	envelope := pool_get_ptr_unchecked(&shard.message_pool, head_index)

	result.pool_index = head_index
	result.message.tag = envelope.tag
	result.message.user.source = envelope.source
	result.message.user.payload_size = envelope.payload_size
	copy(result.message.user.payload[:], envelope.payload[:])

	result.correlation = envelope.correlation
	result.flags = envelope.flags

	next_index := envelope.next_in_mailbox
	soa_meta[slot].inbox_head = next_index
	if next_index == POOL_NONE_INDEX {soa_meta[slot].inbox_tail = POOL_NONE_INDEX}
	_slot_decrement_inbox_count(shard, type_id, slot)

	return result
}

@(private = "package")
_fd_handoff_close_entry :: proc "contextless" (shard: ^Shard, ref: FD_Handoff_Ref) -> bool {
	entry_index, lookup_err := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
	if lookup_err != .None {
		return false
	}
	entry := &shard.handoff_table.entries[entry_index]

	cleanup_fd := entry.cleanup_fd
	free_err := fd_handoff_table_free(&shard.handoff_table, ref)
	if free_err != .None {
		return false
	}

	if cleanup_fd != OS_FD_INVALID {
		_ = backend_control_close(&shard.reactor.backend, cleanup_fd)
	}
	return true
}

@(private = "file")
FD_Handoff_Control_Send :: enum u8 {
	Sent,
	Deferred,
	Failed,
}

@(private = "file")
_fd_handoff_retry_enqueue :: proc "contextless" (
	shard: ^Shard,
	envelope: ^Message_Envelope,
) -> bool {
	retry_pool_index, pool_error := pool_alloc_system(&shard.message_pool)
	if pool_error != .None {
		return false
	}

	retry_envelope := pool_get_ptr_unchecked(&shard.message_pool, retry_pool_index)
	retry_envelope^ = envelope^
	retry_envelope.next_in_mailbox = POOL_NONE_INDEX

	if shard.handoff_retry_head == POOL_NONE_INDEX {
		shard.handoff_retry_head = retry_pool_index
	} else {
		tail_envelope := pool_get_ptr_unchecked(
			&shard.message_pool,
			shard.handoff_retry_tail,
		)
		tail_envelope.next_in_mailbox = retry_pool_index
	}

	shard.handoff_retry_tail = retry_pool_index
	shard.handoff_retry_count += 1
	return true
}

@(private = "file")
_fd_handoff_retry_scan :: proc "contextless" (shard: ^Shard) {
	retry_pool_index := shard.handoff_retry_head
	previous_pool_index: u32 = POOL_NONE_INDEX

	for retry_pool_index != POOL_NONE_INDEX {
		retry_envelope := pool_get_ptr_unchecked(
			&shard.message_pool,
			retry_pool_index,
		)
		next_pool_index := retry_envelope.next_in_mailbox

		route_result := _route_envelope_system(shard, retry_envelope.destination, retry_envelope)
		should_keep_retry := route_result == .mailbox_full || route_result == .pool_exhausted

		if should_keep_retry {
			previous_pool_index = retry_pool_index
		} else {
			if route_result != .ok {
				shard.counters.handoff_control_retry_drops += 1
			}

			if previous_pool_index == POOL_NONE_INDEX {
				shard.handoff_retry_head = next_pool_index
			} else {
				previous_envelope := pool_get_ptr_unchecked(
					&shard.message_pool,
					previous_pool_index,
				)
				previous_envelope.next_in_mailbox = next_pool_index
			}

			if shard.handoff_retry_tail == retry_pool_index {
				shard.handoff_retry_tail = previous_pool_index
			}

			pool_free_unchecked(&shard.message_pool, retry_pool_index)
			shard.handoff_retry_count -= 1
		}

		retry_pool_index = next_pool_index
	}

	if shard.handoff_retry_head == POOL_NONE_INDEX {
		shard.handoff_retry_tail = POOL_NONE_INDEX
	}
}

@(private = "file")
_fd_handoff_send_or_defer :: proc "contextless" (
	shard: ^Shard,
	envelope: ^Message_Envelope,
) -> FD_Handoff_Control_Send {
	route_result := _route_envelope_system(shard, envelope.destination, envelope)
	if route_result == .ok {
		return .Sent
	}

	shard.counters.handoff_control_send_failures += 1
	if route_result != .mailbox_full && route_result != .pool_exhausted {
		return .Failed
	}

	if _fd_handoff_retry_enqueue(shard, envelope) {
		return .Deferred
	}

	shard.counters.handoff_control_retry_exhaustions += 1
	return .Failed
}

@(private = "file")
_fd_handoff_send_abort :: proc "contextless" (
	shard: ^Shard,
	destination: Handle,
	ref: FD_Handoff_Ref,
	os_fd: OS_FD,
) -> FD_Handoff_Control_Send {
	env: Message_Envelope
	env.source = HANDLE_NONE
	env.destination = destination
	env.tag = TAG_FD_HANDOFF_ABORT
	env.payload_size = u16(size_of(FD_Handoff_Abort))
	(cast(^FD_Handoff_Abort)&env.payload[0])^ = FD_Handoff_Abort {
		handoff = ref,
		os_fd   = os_fd,
	}
	return _fd_handoff_send_or_defer(shard, &env)
}

@(private = "file")
Target_Slot :: struct {
	type_id:    u16,
	slot_index: u32,
}

@(private = "file")
_resolve_target_slot :: #force_inline proc "contextless" (
	shard: ^Shard,
	target: Handle,
) -> (
	Target_Slot,
	bool,
) {
	type_id := extract_type_id(target)
	if int(type_id) >= len(shard.metadata) {
		return {}, false
	}

	slot_index := extract_slot(target)
	soa_meta := shard.metadata[type_id]
	if int(slot_index) >= len(soa_meta) {
		return {}, false
	}
	if soa_meta[slot_index].generation != extract_generation(target) {
		return {}, false
	}

	return Target_Slot {
		type_id    = type_id,
		slot_index = slot_index,
	}, true
}

@(private = "file")
_fd_handoff_close_in_flight_entry :: proc "contextless" (
	shard: ^Shard,
	handoff_index: int,
	entry: ^FD_Handoff_Entry,
	send_abort: bool,
) {
	ref := fd_handoff_ref_make(u16(handoff_index), entry.generation, shard.id)
	target_handle := entry.target_handle
	cleanup_fd := entry.cleanup_fd

	if send_abort {
		if _fd_handoff_send_abort(shard, target_handle, ref, cleanup_fd) == .Sent {
			entry.cleanup_fd = OS_FD_INVALID
		}
	}

	_ = _fd_handoff_close_entry(shard, ref)
}

@(private = "file")
_fd_handoff_close_entries_for_target_shard :: proc "contextless" (
	shard: ^Shard,
	target_shard: Shard_Id,
	send_abort: bool,
) {
	for handoff_index in 0 ..< int(shard.handoff_table.entry_count) {
		entry := &shard.handoff_table.entries[handoff_index]
		if entry.state != .In_Flight {
			continue
		}
		if extract_shard_id(entry.target_handle) != target_shard {
			continue
		}

		_fd_handoff_close_in_flight_entry(shard, handoff_index, entry, send_abort)
	}
}

@(private = "package")
_fd_handoff_close_all_entries :: proc "contextless" (shard: ^Shard, send_abort: bool) {
	for handoff_index in 0 ..< int(shard.handoff_table.entry_count) {
		entry := &shard.handoff_table.entries[handoff_index]
		if entry.state != .In_Flight {
			continue
		}

		_fd_handoff_close_in_flight_entry(shard, handoff_index, entry, send_abort)
	}
}

@(private = "file")
_fd_handoff_send_ack :: proc "contextless" (
	shard: ^Shard,
	destination: Handle,
	source: Handle,
	ref: FD_Handoff_Ref,
) -> FD_Handoff_Control_Send {
	env: Message_Envelope
	env.source = source
	env.destination = destination
	env.tag = TAG_FD_HANDOFF_ACK
	env.payload_size = u16(size_of(FD_Handoff_Ack))
	(cast(^FD_Handoff_Ack)&env.payload[0])^ = FD_Handoff_Ack {
		handoff = ref,
	}
	return _fd_handoff_send_or_defer(shard, &env)
}

@(private = "file")
_fd_handoff_send_reject :: proc "contextless" (
	shard: ^Shard,
	destination: Handle,
	source: Handle,
	ref: FD_Handoff_Ref,
	reason: FD_Handoff_Reject_Reason,
) -> FD_Handoff_Control_Send {
	env: Message_Envelope
	env.source = source
	env.destination = destination
	env.tag = TAG_FD_HANDOFF_REJECT
	env.payload_size = u16(size_of(FD_Handoff_Reject))
	(cast(^FD_Handoff_Reject)&env.payload[0])^ = FD_Handoff_Reject {
		handoff = ref,
		reason  = reason,
	}
	return _fd_handoff_send_or_defer(shard, &env)
}

@(private = "file")
_inject_fd_handoff_accept :: proc "contextless" (
	shard: ^Shard,
	target: Handle,
	fd: FD_Handle,
	peer_address: Peer_Address,
) -> FD_Handoff_Reject_Reason {
	target_slot, ok := _resolve_target_slot(shard, target)
	if !ok {
		return .Invalid_Target
	}

	soa_meta := shard.metadata[target_slot.type_id]
	if soa_meta[target_slot.slot_index].state == .Unallocated || soa_meta[target_slot.slot_index].state == .Crashed {
		return .Invalid_Target
	}
	if soa_meta[target_slot.slot_index].state == .Waiting_For_Io || soa_meta[target_slot.slot_index].io_completion_tag != IO_TAG_NONE {
		return .Target_Busy
	}

	_slot_set_io_completion_tag(shard, target_slot.type_id, target_slot.slot_index, IO_TAG_ACCEPT_COMPLETE)
	soa_meta[target_slot.slot_index].io_result = 0
	soa_meta[target_slot.slot_index].io_fd = fd
	soa_meta[target_slot.slot_index].io_buffer_index = BUFFER_INDEX_NONE
	soa_meta[target_slot.slot_index].io_peer_address = peer_address
	return .None
}

@(private = "file")
_clear_fd_handoff_accept :: proc "contextless" (
	shard: ^Shard,
	target: Handle,
	fd: FD_Handle,
) {
	target_slot, ok := _resolve_target_slot(shard, target)
	if !ok {
		return
	}

	soa_meta := shard.metadata[target_slot.type_id]
	if soa_meta[target_slot.slot_index].io_completion_tag != IO_TAG_ACCEPT_COMPLETE {
		return
	}
	if soa_meta[target_slot.slot_index].io_fd != fd {
		return
	}

	_slot_set_io_completion_tag(shard, target_slot.type_id, target_slot.slot_index, IO_TAG_NONE)
	soa_meta[target_slot.slot_index].io_result = 0
	soa_meta[target_slot.slot_index].io_fd = FD_HANDLE_NONE
	soa_meta[target_slot.slot_index].io_buffer_index = BUFFER_INDEX_NONE
	soa_meta[target_slot.slot_index].io_peer_address = Peer_Address{}
}

@(private = "file")
_process_fd_handoff_offer :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Offer)) {
		return
	}

	offer := (cast(^FD_Handoff_Offer)&envelope.payload[0])^
	adopted_fd, adopt_reason := reactor_adopt_fd_handoff(
		&shard.reactor,
		envelope.destination,
		offer.os_fd,
		offer.peer_address,
	)
	if adopt_reason != .None {
		_ = _fd_handoff_send_reject(
			shard,
			envelope.source,
			envelope.destination,
			offer.handoff,
			adopt_reason,
		)
		return
	}

	inject_reason := _inject_fd_handoff_accept(
		shard,
		envelope.destination,
		adopted_fd,
		offer.peer_address,
	)
	if inject_reason != .None {
		reactor_internal_close_fd(&shard.reactor, adopted_fd)
		_ = _fd_handoff_send_reject(
			shard,
			envelope.source,
			envelope.destination,
			offer.handoff,
			inject_reason,
		)
		return
	}

	ack_send := _fd_handoff_send_ack(shard, envelope.source, envelope.destination, offer.handoff)
	if ack_send == .Failed {
		_clear_fd_handoff_accept(shard, envelope.destination, adopted_fd)
		reactor_internal_close_fd(&shard.reactor, adopted_fd)
		_ = _fd_handoff_send_reject(
			shard,
			envelope.source,
			envelope.destination,
			offer.handoff,
			.Adopt_Failed,
		)
	}
}

@(private = "file")
_process_fd_handoff_ack :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Ack)) {
		return
	}
	ack := (cast(^FD_Handoff_Ack)&envelope.payload[0])^
	_ = _fd_handoff_close_entry(shard, ack.handoff)
}

@(private = "file")
_process_fd_handoff_reject :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Reject)) {
		return
	}
	reject := (cast(^FD_Handoff_Reject)&envelope.payload[0])^
	if _fd_handoff_close_entry(shard, reject.handoff) {
		shard.counters.handoff_rejects += 1
	}
}

@(private = "file")
_process_fd_handoff_abort :: proc "contextless" (shard: ^Shard, envelope: ^Message_Envelope) {
	if envelope.payload_size < u16(size_of(FD_Handoff_Abort)) {
		return
	}
	abort := (cast(^FD_Handoff_Abort)&envelope.payload[0])^

	target_slot, ok := _resolve_target_slot(shard, envelope.destination)
	if ok {
		soa_meta := shard.metadata[target_slot.type_id]
		if soa_meta[target_slot.slot_index].io_completion_tag == IO_TAG_ACCEPT_COMPLETE {
			fd := soa_meta[target_slot.slot_index].io_fd
			_clear_fd_handoff_accept(shard, envelope.destination, fd)
			reactor_internal_close_fd(&shard.reactor, fd)
		}
	}

	if abort.os_fd != OS_FD_INVALID {
		_ = backend_control_close(&shard.reactor.backend, abort.os_fd)
	}
}

@(private = "file")
_fd_handoff_timeout_scan :: proc(shard: ^Shard, now: u64) {
	for handoff_index in 0 ..< int(shard.handoff_table.entry_count) {
		entry := &shard.handoff_table.entries[handoff_index]
		if entry.state != .In_Flight || entry.deadline_tick == 0 || now < entry.deadline_tick {
			continue
		}

		shard.counters.handoff_timeouts += 1
		entry.deadline_tick = 0
	}
}

// --- Mass Teardown & Recovery ---

@(private = "package")
shard_mass_teardown :: proc(shard: ^Shard) {
	log_flush(shard)

	// 1. Reset Pools (Message & Transfer)
	shard.message_pool.free_count = shard.message_pool.slot_count
	shard.message_pool.free_head = POOL_NONE_INDEX
	for i := int(shard.message_pool.slot_count) - 1; i >= 0; i -= 1 {
		slot_pointer := pool_get_ptr(&shard.message_pool, u32(i))
		slot_pointer.next_free_slot = shard.message_pool.free_head
		shard.message_pool.free_head = u32(i)
	}
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0

	reactor_buffer_pool_reset(&shard.transfer_pool)
	for i in 0 ..< shard.transfer_pool.slot_count {
		shard.transfer_generations[i] += 1
		if shard.transfer_generations[i] == 0 do shard.transfer_generations[i] = 1
	}

	// Sweep unsubmitted I/O buffers from the reactor's pending queue.
	// If a Level 2 fault interrupted the thread during Step 3 (Dispatch),
	// these buffers were allocated but never reached the OS kernel.
	for i in 0 ..< shard.reactor.pending_count {
		sub := &shard.reactor.pending_submissions[i]
		buffer_index := submission_token_buffer_index(sub.token)
		if buffer_index != BUFFER_INDEX_NONE {
			reactor_buffer_pool_free(&shard.reactor.buffer_pool, buffer_index)
		}
	}
	shard.reactor.pending_count = 0

	for i in 0 ..< shard.reactor.fd_table.slot_count {
		entry := &shard.reactor.fd_table.entries[i]

		if entry.reader_isolate != HANDLE_NONE || entry.writer_isolate != HANDLE_NONE {
			backend_control_close(&shard.reactor.backend, entry.os_fd)
			fd_handle := fd_handle_make(u16(i), entry.generation)
			fd_table_free(&shard.reactor.fd_table, fd_handle)
		}
	}
	for handoff_index in 0 ..< int(shard.handoff_table.entry_count) {
		entry := &shard.handoff_table.entries[handoff_index]
		if entry.state != .In_Flight {
			continue
		}
		if entry.cleanup_fd != OS_FD_INVALID {
			_ = backend_control_close(&shard.reactor.backend, entry.cleanup_fd)
		}
	}
	fd_handoff_table_init(&shard.handoff_table, shard.handoff_table.entries)
	for type_desc in shard.type_descriptors {
		type_id := u16(type_desc.id)
		soa_meta := shard.metadata[type_id]

		// Reset the free head for this type
		shard.isolate_free_heads[type_id] = POOL_NONE_INDEX
		shard.dispatch_cursors[type_id] = 0

		for slot := int(type_desc.slot_count) - 1; slot >= 0; slot -= 1 {
			// SWEEP: Reclaim completed but undispatched I/O buffers before wiping metadata
			if soa_meta[slot].io_completion_tag != IO_TAG_NONE {
				if soa_meta[slot].io_buffer_index != BUFFER_INDEX_NONE {
					reactor_buffer_pool_free(
						&shard.reactor.buffer_pool,
						soa_meta[slot].io_buffer_index,
					)
				}
			}

			new_generation := (soa_meta[slot].generation + 1) & 0x0FFFFFFF
			if new_generation == 0 do new_generation = 1

			soa_meta[slot].generation = new_generation
			soa_meta[slot].state = .Unallocated
			soa_meta[slot].inbox_count = 0
			soa_meta[slot].inbox_tail = POOL_NONE_INDEX
			soa_meta[slot].pending_correlation = 0
			soa_meta[slot].pending_transfer_read = TRANSFER_HANDLE_NONE
			soa_meta[slot].io_completion_tag = IO_TAG_NONE
			soa_meta[slot].working_arena_offset = 0
			soa_meta[slot].flags = {}

			// Re-link the intrusive free list!
			soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = u32(slot)
		}
	}

	for type_index in 0 ..< len(shard.dispatch_credit_counts) {
		shard.dispatch_credit_counts[type_index] = 0
		shard.dispatchable_slot_counts[type_index] = 0
		for word_index in 0 ..< len(shard.dispatchable_slot_words[type_index]) {
			shard.dispatchable_slot_words[type_index][word_index] = 0
		}
	}
	for word_index in 0 ..< len(shard.dispatchable_type_words) {
		shard.dispatchable_type_words[word_index] = 0
	}
	for word_index in 0 ..< len(shard.dispatch_ready_type_words) {
		shard.dispatch_ready_type_words[word_index] = 0
	}
	shard.dispatch_type_cursor = 0
	shard.current_type_id = 0
	shard.current_slot_index = 0
	shard.current_msg_slot = POOL_NONE_INDEX

	timer_wheel_reset(&shard.timer_wheel, shard.current_tick)

	shard.next_correlation_id = 0
	// Control Signal reset
	store_shard_control_signal(shard, .None)

	// Step 6: Notify peers via SHARD_RESTARTED
	env: Message_Envelope
	env.source = HANDLE_NONE
	env.destination = HANDLE_NONE
	env.tag = TAG_SHARD_RESTARTED
	transport_broadcast_envelope(shard, &env)
}

// Checks if any Isolates are still alive across all types on this Shard.
@(private)
shard_has_live_isolates :: proc(shard: ^Shard) -> bool {
	for type_desc in shard.type_descriptors {
		states := shard.metadata[u16(type_desc.id)].state[:]
		for i in 0 ..< type_desc.slot_count {
			if states[i] != .Unallocated {
				return true
			}
		}
	}
	return false
}

@(private = "package")
_process_inbound_envelope :: #force_inline proc "contextless" (
	shard: ^Shard,
	source_shard: Shard_Id,
	envelope: ^Message_Envelope,
) {
	// System Broadcast Intercept
	if envelope.destination == HANDLE_NONE {
		if envelope.tag == TAG_SHARD_RESTARTED {
			// Peer recovered, un-quarantine it
			shard_mask_include(&shard.peer_alive_mask, source_shard)
			// NOTE (§7.5.4): We could optionally perform an O(N) scan of
			// all local Isolates here to "fast-fail" any pending .call requests to this
			// restarted shard (since we know they are now stale). For now, we rely on
			// the Timer Wheel timeouts to naturally wake and fail the callers.
		} else if envelope.tag == TAG_SHARD_QUARANTINED {
			// Peer died, quarantine it
			shard_mask_exclude(&shard.peer_alive_mask, source_shard)
			_fd_handoff_close_entries_for_target_shard(shard, source_shard, false)
			// NOTE: Same concern as above if-block. Pending calls will naturally time out.
		}
		return
	}

	switch envelope.tag {
	case TAG_FD_HANDOFF_OFFER:
		_process_fd_handoff_offer(shard, envelope)
	case TAG_FD_HANDOFF_ACK:
		_process_fd_handoff_ack(shard, envelope)
	case TAG_FD_HANDOFF_REJECT:
		_process_fd_handoff_reject(shard, envelope)
	case TAG_FD_HANDOFF_ABORT:
		_process_fd_handoff_abort(shard, envelope)
	case:
		_ = _enqueue_user_msg(shard, envelope.destination, envelope)
	}
}

@(private = "file")
_init_handoff_test_shard :: proc(
	t: ^testing.T,
	shard: ^Shard,
	handoff_backing: []FD_Handoff_Entry,
) {
	shard.id = 0
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0
	fd_handoff_table_init(&shard.handoff_table, handoff_backing)
	backend_config := Backend_Config {
		queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
		sim_config = Simulation_IO_Config{},
	}
	err := backend_init(&shard.reactor.backend, backend_config)
	testing.expect_value(t, err, Backend_Error.None)
}

@(private = "file")
_alloc_handoff_test_entry :: proc(
	t: ^testing.T,
	shard: ^Shard,
	target_handle: Handle,
	deadline_tick: u64,
) -> FD_Handoff_Ref {
	cleanup_fd, sock_err := backend_control_socket(&shard.reactor.backend, .AF_INET, .STREAM, .TCP)
	testing.expect_value(t, sock_err, Backend_Error.None)

	ref, alloc_err := fd_handoff_table_alloc(
		&shard.handoff_table,
		target_handle,
		cleanup_fd,
		Peer_Address{},
		deadline_tick,
		shard.id,
	)
	testing.expect_value(t, alloc_err, FD_Handoff_Table_Error.None)
	return ref
}

@(private = "file")
_make_teardown_test_shard :: proc(t: ^testing.T) -> (^Shard, ^Grand_Arena) {
	types := [1]TypeDescriptor {
		{
			id                      = 0,
			slot_count              = 1,
			stride                  = 8,
			soa_metadata_size       = size_of(Isolate_Metadata),
			working_memory_size     = 0,
			scratch_requirement_max = 0,
		},
	}
	root_children := [1]Child_Spec{Static_Child_Spec{type_id = 0, restart_type = .temporary}}
	root_group := Group_Spec {
		strategy              = .One_For_One,
		restart_count_max     = 1,
		window_duration_ticks = 1,
		children              = root_children[:],
	}
	shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}
	spec := SystemSpec {
		shard_count                = 1,
		types                      = types[:],
		shard_specs                = shard_specs[:],
		pool_slot_count            = 16,
		reactor_buffer_slot_count  = 4,
		reactor_buffer_slot_size   = 1024,
		transfer_slot_count        = 4,
		transfer_slot_size         = 1024,
		fd_table_slot_count        = 8,
		fd_entry_size              = size_of(FD_Entry),
		timer_spoke_count          = 16,
		timer_entry_count          = 16,
		log_ring_size              = 16,
		supervision_groups_max     = 4,
		scratch_arena_size         = 16,
		default_ring_size          = 16,
	}

	total_memory_size := compute_shard_memory_total(&spec)
	arena := new(Grand_Arena)
	err := grand_arena_init(arena, total_memory_size)
	testing.expect_value(t, err, mem.Allocator_Error.None)

	shard := new(Shard)
	carve_err := hydrate_shard(arena, &spec, shard)
	testing.expect_value(t, carve_err, mem.Allocator_Error.None)
	return shard, arena
}

@(test)
test_dispatchable_refresh_slot_updates_type_summary :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)

	shard.metadata = make([]#soa[]Isolate_Metadata, 1)
	defer delete(shard.metadata)
	shard.metadata[0] = make(#soa[]Isolate_Metadata, 2)
	defer delete(shard.metadata[0])
	shard.dispatchable_slot_words = make([][]u64, 1)
	defer delete(shard.dispatchable_slot_words)
	shard.dispatchable_slot_words[0] = make([]u64, _dispatch_word_count(2))
	defer delete(shard.dispatchable_slot_words[0])
	shard.dispatchable_slot_counts = make([]u32, 1)
	defer delete(shard.dispatchable_slot_counts)
	shard.dispatch_credit_counts = make([]Scheduler_Credit_Count, 1)
	defer delete(shard.dispatch_credit_counts)
	shard.dispatchable_type_words = make([]u64, _dispatch_word_count(1))
	defer delete(shard.dispatchable_type_words)
	shard.dispatch_ready_type_words = make([]u64, _dispatch_word_count(1))
	defer delete(shard.dispatch_ready_type_words)

	shard.dispatch_credit_counts[0] = 1
	shard.metadata[0][1].state = .Runnable
	_dispatchable_refresh_slot(shard, 0, 1)

	testing.expect_value(t, shard.dispatchable_slot_counts[0], u32(1))
	testing.expect_value(t, shard.dispatchable_slot_words[0][0], u64(1 << 1))
	testing.expect_value(t, shard.dispatchable_type_words[0], u64(1))
	testing.expect_value(t, shard.dispatch_ready_type_words[0], u64(1))

	shard.dispatch_credit_counts[0] = 0
	_dispatchable_type_refresh(shard, 0)
	testing.expect_value(t, shard.dispatchable_type_words[0], u64(1))
	testing.expect_value(t, shard.dispatch_ready_type_words[0], u64(0))

	shard.dispatch_credit_counts[0] = 1
	_dispatchable_type_refresh(shard, 0)

	shard.metadata[0][1].state = .Waiting_For_Io
	_dispatchable_refresh_slot(shard, 0, 1)

	testing.expect_value(t, shard.dispatchable_slot_counts[0], u32(0))
	testing.expect_value(t, shard.dispatchable_slot_words[0][0], u64(0))
	testing.expect_value(t, shard.dispatchable_type_words[0], u64(0))
	testing.expect_value(t, shard.dispatch_ready_type_words[0], u64(0))
}

@(test)
test_dispatchable_find_next_slot_wraps_within_single_word :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)

	shard.dispatchable_slot_words = make([][]u64, 1)
	defer delete(shard.dispatchable_slot_words)
	shard.dispatchable_slot_words[0] = make([]u64, 1)
	defer delete(shard.dispatchable_slot_words[0])
	shard.dispatchable_slot_words[0][0] = (u64(1) << 5) | (u64(1) << 63)

	slot_index, found := _dispatchable_find_next_slot(shard, 0, 6, 64)
	testing.expect(t, found, "expected to find wrapped dispatchable slot")
	testing.expect_value(t, slot_index, u32(63))

	slot_index, found = _dispatchable_find_next_slot(shard, 0, 6, 63)
	testing.expect(t, found, "expected wrapped search to reach lower bits in same word")
	testing.expect_value(t, slot_index, u32(5))
}

@(test)
test_fd_handoff_send_ack_defers_and_retries_when_ring_is_full :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)

	shard.id = 1
	shard.shard_count = 2
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0
	shard_mask_include(&shard.peer_alive_mask, 0)

	msg_pool_backing: [MESSAGE_ENVELOPE_SIZE * 4]u8
	pool_init(&shard.message_pool, msg_pool_backing[:], MESSAGE_ENVELOPE_SIZE)

	when TINA_SIMULATION_MODE {
		defer free_all(context.temp_allocator)

		ring_sizes := make([][]u32, 2, context.temp_allocator)
		ring_sizes[0] = make([]u32, 2, context.temp_allocator)
		ring_sizes[1] = make([]u32, 2, context.temp_allocator)
		ring_sizes[0][1] = 1
		ring_sizes[1][0] = 1

		drop_prng: Prng
		prng_init(&drop_prng, 0xD10D)

		network: SimulatedNetwork
		sim_network_init(&network, 2, ring_sizes, &drop_prng, context.temp_allocator)

		fault_config := FaultConfig{}
		shard.sim_state.network = &network
		shard.sim_state.fault_config = &fault_config

		prefill_envelope := Message_Envelope {source = make_handle(1, 1, 0, 1), destination = HANDLE_NONE}
		prefill_result := sim_network_enqueue(
			&network,
			shard,
			0,
			prefill_envelope,
			0,
			shard.sim_state.fault_config,
		)
		testing.expect_value(t, prefill_result, Send_Result.ok)
	} else {
		ring_backing: [1]Message_Envelope
		ring: SPSC_Ring
		spsc_ring_init(&ring, 1, ring_backing[:])

		prefill_envelope := Message_Envelope{source = make_handle(1, 1, 0, 1), destination = make_handle(0, 1, 0, 1)}
		testing.expect_value(t, spsc_ring_enqueue(&ring, &prefill_envelope), Enqueue_Result.Success)

		outbound_rings: [1]^SPSC_Ring
		outbound_rings[0] = &ring
		shard.outbound_rings = outbound_rings[:]
	}

	ack_send := _fd_handoff_send_ack(
		shard,
		make_handle(0, 1, 0, 1),
		make_handle(1, 1, 0, 1),
		FD_HANDOFF_REF_NONE,
	)

	testing.expect_value(t, ack_send, FD_Handoff_Control_Send.Deferred)
	testing.expect_value(t, shard.handoff_retry_count, u32(1))
	testing.expect_value(t, shard.counters.handoff_control_send_failures, u64(1))

	when TINA_SIMULATION_MODE {
		target_shard := Shard {id = 0}
		target_shard.sim_state.network = shard.sim_state.network
		target_shard.sim_state.fault_config = shard.sim_state.fault_config
		sim_network_drain(shard.sim_state.network, &target_shard, shard.id, 0)
	} else {
		outbound_ring := shard.outbound_rings[0]
		spsc_ring_flush_producer(outbound_ring)
		available_to_read := spsc_ring_available_to_read(outbound_ring)
		spsc_ring_commit_read(outbound_ring, available_to_read)
	}

	_fd_handoff_retry_scan(shard)
	testing.expect_value(t, shard.handoff_retry_count, u32(0))
	testing.expect_value(t, shard.handoff_retry_head, u32(POOL_NONE_INDEX))
	testing.expect_value(t, shard.handoff_retry_tail, u32(POOL_NONE_INDEX))
	testing.expect_value(t, shard.counters.handoff_control_retry_drops, u64(0))
}

@(test)
test_shard_mass_teardown_resets_scheduler_state :: proc(t: ^testing.T) {
	shard, arena := _make_teardown_test_shard(t)
	defer {
		os_release_arena_with_guard(arena.base)
		free(arena)
		free(shard)
	}

	shard.dispatch_credit_counts[0] = 7
	shard.dispatch_type_cursor = 1
	shard.current_type_id = 1
	shard.current_slot_index = 1
	shard.current_msg_slot = 3

	shard_mass_teardown(shard)

	testing.expect_value(t, shard.dispatch_credit_counts[0], Scheduler_Credit_Count(0))
	testing.expect_value(t, shard.dispatch_type_cursor, u32(0))
	testing.expect_value(t, shard.current_type_id, u16(0))
	testing.expect_value(t, shard.current_slot_index, u32(0))
	testing.expect_value(t, shard.current_msg_slot, POOL_NONE_INDEX)
}

@(test)
test_fd_handoff_retry_scan_drops_unroutable_control_messages :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)

	shard.id = 0
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0

	msg_pool_backing: [MESSAGE_ENVELOPE_SIZE * 2]u8
	pool_init(&shard.message_pool, msg_pool_backing[:], MESSAGE_ENVELOPE_SIZE)

	retry_envelope := Message_Envelope {
		source = make_handle(0, 1, 0, 1),
		destination = make_handle(1, 1, 0, 1),
		tag = TAG_FD_HANDOFF_REJECT,
		payload_size = u16(size_of(FD_Handoff_Reject)),
	}

	testing.expect(
		t,
		_fd_handoff_retry_enqueue(shard, &retry_envelope),
		"retry enqueue should succeed for unroutable test envelope",
	)
	testing.expect_value(t, shard.handoff_retry_count, u32(1))

	_fd_handoff_retry_scan(shard)
	testing.expect_value(t, shard.handoff_retry_count, u32(0))
	testing.expect_value(t, shard.handoff_retry_head, u32(POOL_NONE_INDEX))
	testing.expect_value(t, shard.handoff_retry_tail, u32(POOL_NONE_INDEX))
	testing.expect_value(t, shard.counters.handoff_control_retry_drops, u64(1))
}

@(test)
test_fd_handoff_peer_quarantine_closes_entries_targeting_that_shard :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)
	handoff_backing: [4]FD_Handoff_Entry
	_init_handoff_test_shard(t, shard, handoff_backing[:])
	defer backend_deinit(&shard.reactor.backend)

	ref_target_1_a := _alloc_handoff_test_entry(t, shard, make_handle(1, 1, 0, 1), 100)
	ref_target_1_b := _alloc_handoff_test_entry(t, shard, make_handle(1, 1, 1, 1), 100)
	ref_target_2 := _alloc_handoff_test_entry(t, shard, make_handle(2, 1, 0, 1), 100)

	quarantine_envelope := Message_Envelope {
		source = HANDLE_NONE,
		destination = HANDLE_NONE,
		tag = TAG_SHARD_QUARANTINED,
	}
	_process_inbound_envelope(shard, 1, &quarantine_envelope)

	_, lookup_err_target_1_a := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_1_a)
	_, lookup_err_target_1_b := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_1_b)
	_, lookup_err_target_2 := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_2)

	testing.expect(t, lookup_err_target_1_a != .None, "quarantined target shard entries should be reclaimed")
	testing.expect(t, lookup_err_target_1_b != .None, "all quarantined target shard entries should be reclaimed")
	testing.expect_value(t, lookup_err_target_2, FD_Handoff_Table_Error.None)
}

@(test)
test_fd_handoff_close_all_entries_reclaims_all_in_flight_entries :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)
	handoff_backing: [4]FD_Handoff_Entry
	_init_handoff_test_shard(t, shard, handoff_backing[:])
	defer backend_deinit(&shard.reactor.backend)

	ref_a := _alloc_handoff_test_entry(t, shard, make_handle(1, 1, 0, 1), 100)
	ref_b := _alloc_handoff_test_entry(t, shard, make_handle(2, 1, 0, 1), 100)

	_fd_handoff_close_all_entries(shard, false)

	_, lookup_err_a := fd_handoff_table_lookup_index(&shard.handoff_table, ref_a)
	_, lookup_err_b := fd_handoff_table_lookup_index(&shard.handoff_table, ref_b)

	testing.expect(t, lookup_err_a != .None, "close_all should reclaim first in-flight entry")
	testing.expect(t, lookup_err_b != .None, "close_all should reclaim second in-flight entry")
	testing.expect_value(t, shard.handoff_table.free_count, shard.handoff_table.entry_count)
}

@(test)
test_fd_handoff_timeout_scan_counts_but_keeps_entry :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)
	handoff_backing: [2]FD_Handoff_Entry
	_init_handoff_test_shard(t, shard, handoff_backing[:])
	defer backend_deinit(&shard.reactor.backend)

	target_handle := make_handle(1, 1, 0, 1)
	ref := _alloc_handoff_test_entry(t, shard, target_handle, 5)

	_fd_handoff_timeout_scan(shard, 6)

	entry_index, lookup_err := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
	testing.expect_value(t, lookup_err, FD_Handoff_Table_Error.None)
	entry := &shard.handoff_table.entries[entry_index]
	testing.expect_value(t, entry.deadline_tick, u64(0))
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(1))

	_fd_handoff_timeout_scan(shard, 100)
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(1))
}

@(test)
test_scheduler_dispatch_batch_count_limit_respects_io_service_interval :: proc(t: ^testing.T) {
	limit_start := _scheduler_dispatch_batch_count_limit(1024, 1024, 0)
	expected_start := min(
		u32(SCHEDULER_TYPE_DISPATCH_BATCH_COUNT_MAX),
		u32(SCHEDULER_IO_SERVICE_INTERVAL_COUNT),
	)
	testing.expect_value(t, limit_start, expected_start)

	limit_edge := _scheduler_dispatch_batch_count_limit(
		1024,
		1024,
		u32(SCHEDULER_IO_SERVICE_INTERVAL_COUNT) - 1,
	)
	testing.expect_value(t, limit_edge, u32(1))
}

@(test)
test_shard_mass_teardown_reclaims_in_flight_handoff_entries :: proc(t: ^testing.T) {
	shard := new(Shard)
	defer free(shard)
	handoff_backing: [2]FD_Handoff_Entry
	_init_handoff_test_shard(t, shard, handoff_backing[:])
	defer backend_deinit(&shard.reactor.backend)

	target_handle := make_handle(1, 1, 0, 1)
	ref := _alloc_handoff_test_entry(t, shard, target_handle, 100)

	shard_mass_teardown(shard)

	_, lookup_err := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
	testing.expect(t, lookup_err != .None, "mass teardown should reclaim in-flight handoff entries")
	testing.expect_value(t, shard.handoff_table.free_count, shard.handoff_table.entry_count)
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(0))
}
