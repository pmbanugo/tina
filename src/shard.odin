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
	trap_environment := shard.current_trap_environment
	if trap_environment == nil {
		trap_environment = &shard.trap_environment_inner
	}
	os_trap_restore(trap_environment, 1)
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
	Wait_Message,
	Wait_Reply,
	Wait_Io,
	Crashed,
	Pending_IO_Reuse, // Torn down, awaiting stale write I/O completion before slot reuse.
}
Isolate_Flag :: enum u8 {
	Shutdown_Pending,
	IO_Completion_Ready,
	Call_Timeout_Ready,
}
Isolate_Flags :: distinct bit_set[Isolate_Flag;u8]

// Flags that must be cleared when a slot is allocated to a new Isolate.
// Stale flag bits from a previous incarnation must not persist. When a
// new flag variant is added, the author must decide: should it survive
// slot reuse? If not, add it here.
ISOLATE_FLAGS_CLEARED_ON_ALLOC :: Isolate_Flags{.IO_Completion_Ready, .Call_Timeout_Ready}

// Mutually Exclusive Control Signals from Watchdog
Control_Signal :: enum u8 {
	None     = 0,
	Shutdown = 1,
	Kill     = 2,
}


// --- Core Data Structures ---

// Isolate metadata
Isolate_Metadata :: struct {
	io_peer_address:      Peer_Address,
	inbox_head:           u32,
	inbox_tail:           u32,
	pending_correlation:  Correlation_Id,
	io_fd:                FD_Handle,
	io_result:            i32,
	generation:           u32,
	working_arena_offset: u32,
	inbox_count:          u16,
	group_id:             Supervision_Group_Id,
	io_operation_kind:    IO_Operation_Kind,
	io_slot_index:        IO_Slot_Index,
	_state:               Isolate_State,
	flags:                Isolate_Flags, // Replaces shutdown_pending: u8
	io_sequence:          u8,
}

Shard_Counters :: struct {
	stale_delivery_drops:              u64,
	ring_full_drops:                   u64,
	quarantine_drops:                  u64,
	pool_exhaustion_drops:             u64,
	mailbox_full_drops:                u64,
	io_receive_exhaustions:            u64,
	io_staging_exhaustions:            u64,
	io_submission_exhaustions:         u64,
	io_awaiting_count:                 u64,
	io_stale_completions:              u64, // TODO: In simulation, consider verifying that this counter
	// equals the number of timer-wakes + shutdown-wakes that
	// interrupted WAITING_FOR_IO Isolates. A mismatch would indicate
	// a stale completion was lost (buffer leak) or double-counted.
	// Might require tracking a separate "io_wakes" counter to compare against.
	io_recv_no_buffers_count:          u64,
	staging_slot_leaks:                u64, // leak signal.
	transfer_exhaustions:              u64,
	transfer_stale_reads:              u64,
	handoff_exhaustions:               u64,
	handoff_timeouts:                  u64,
	handoff_rejects:                   u64,
	handoff_control_send_failures:     u64,
	handoff_control_retry_exhaustions: u64,
	handoff_control_retry_drops:       u64,
	liveness_control_publish_count:    u64,
}

Dynamic_Child_Spec :: struct {
	args_payload: [MAX_INIT_ARGS_SIZE]u8,
	type_id:      Isolate_Type_Id,
	restart_type: Restart_Type,
	args_size:    u8,
	_padding:     [5]u8,
}

Supervision_Group :: struct {
	children_handles:      []Isolate_Handle,
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

	Diagnostic_Field_Id :: distinct u16

	Diagnostic_Record :: struct {
		isolate_type_id: Isolate_Type_Id,
		slot_index:      Isolate_Slot_Index,
		field_id:        Diagnostic_Field_Id,
		value:           u64,
		write_count:     u32,
	}

	Diagnostic_Table :: struct {
		records:      []Diagnostic_Record,
		record_count: u32,
	}

	Sim_State_Mixin :: struct {
		sim_state:   Simulation_State,
		diagnostics: Diagnostic_Table,
	}
} else {
	Sim_State_Mixin :: struct {}
}

@(private = "package")
Shard :: struct {
	// --- Hot Pointers & Slices (8-byte aligned) ---
	outbound_rings:                  []^SPSC_Ring,
	inbound_rings:                   []^SPSC_Ring,
	outbound_control_channels:       []^Shard_Control_Channel,
	inbound_control_channel:         ^Shard_Control_Channel,
	type_descriptors:                []IsolateTypeDescriptor,
	isolate_free_heads:              []u32, // free list heads per Isolate Type
	dispatch_cursors:                []u32, // Resumption index for budgeted dispatch
	dispatch_credit_counts:          []Scheduler_Credit_Count,
	dispatchable_slot_words:         [][]u64,
	dispatchable_slot_counts:        []u32,
	dispatchable_type_words:         []u64,
	dispatch_ready_type_words:       []u64,
	isolate_memory:                  [][]u8,
	working_memory:                  [][]u8, // Base slices for working memory
	scratch_memory:                  []u8, // Base slice for scratch arena
	transfer_generations:            []u16,
	metadata:                        []#soa[]Isolate_Metadata,
	supervision_groups:              []Supervision_Group,
	handoff_table:                   FD_Handoff_Table,

	// --- Hot Embedded Structs (8-byte aligned) ---
	log_ring:                        Log_Ring_Buffer,
	message_pool:                    Message_Pool,
	transfer_pool:                   IO_Slot_Pool,
	counters:                        Shard_Counters,

	// --- Hot Scalars (Ordered largest to smallest) ---
	current_tick:                    u64, // The current time quantized to the resolution
	timer_resolution_ns:             u64, // E.g., 1_000_000 for 1ms ticks
	heartbeat_tick:                  u64,
	current_isolate_turn_frame:      ^Isolate_Turn_Frame,
	current_trap_environment:        ^OS_Trap_Environment,
	next_correlation_id:             Correlation_Id,
	handoff_retry_head:              u32,
	handoff_retry_tail:              u32,
	handoff_retry_count:             u32,
	dispatch_type_cursor:            u32,
	liveness_epoch:                  u32,
	liveness_broadcast_epoch:        u32,
	id:                              Shard_Id,
	shard_count:                     u8,
	liveness_broadcast_state:        Shard_State,
	peer_alive_mask:                 Shard_Mask, // Tracks up to 256 peers. Bit N = 1 if Shard N is alive
	control_signal:                  Control_Signal, // Atomic, mutually exclusive signals from watchdog
	watchdog_state_pointer:          ^u8, // Points to external watchdog state (config or simulator backing)

	// --- Cold / Massive Storage ---
	timer_wheel:                     Timer_Wheel,
	trap_environment_outer:          OS_Trap_Environment,
	trap_environment_inner:          OS_Trap_Environment,
	trap_environment_init:           OS_Trap_Environment,
	reactor:                         Reactor,
	liveness_epoch_seen:             [MAX_SHARDS]u32,
	liveness_broadcast_pending_mask: Shard_Mask,

	// Placed at the end to prevent possible cache-line shifting of hot fields.
	using _sim_mixin:                Sim_State_Mixin,
}

@(private = "file")
Dispatch_Kind :: enum u8 {
	None,
	Runnable,
	Inbox,
	Shutdown,
	Io_Completion,
	Call_Timeout,
}

@(private = "file")
_wake_type_for_shutdown :: proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_count: u32,
) {
	states := shard.metadata[type_id]._state[:]
	flags := shard.metadata[type_id].flags[:]
	io_sequences := shard.metadata[type_id].io_sequence[:]
	pending_correlations := shard.metadata[type_id].pending_correlation[:]

	for slot_index in 0 ..< slot_count {
		if states[slot_index] == .Unallocated do continue
		flags[slot_index] -= {.Call_Timeout_Ready}
		_slot_add_shutdown_pending(shard, type_id, Isolate_Slot_Index(slot_index))
	}

	for slot_index in 0 ..< slot_count {
		state := states[slot_index]
		if state == .Wait_Message {
			_slot_set_state(shard, type_id, Isolate_Slot_Index(slot_index), .Runnable)
			continue
		}
		if state == .Wait_Io {
			// Invalidate pending completion via io_sequence bump.
			// No explicit backend_cancel — the stale completion will
			// arrive naturally, fail the io_sequence check in
			// reactor_collect_completions, and have its buffer freed
			// by the stale-path reclamation. See §6.6.3 §12 design note.
			io_sequences[slot_index] += 1
			_slot_set_state(shard, type_id, Isolate_Slot_Index(slot_index), .Runnable)
			continue
		}
		if state == .Wait_Reply {
			// Discard stale replies.
			pending_correlations[slot_index] = 0
			_slot_set_state(shard, type_id, Isolate_Slot_Index(slot_index), .Runnable)
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
			_wake_type_for_shutdown(shard, type_descriptor.id, u32(type_descriptor.slot_count))
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
	io_operation_kind: IO_Operation_Kind,
) -> Dispatch_Kind {
	if state == .Unallocated || state == .Pending_IO_Reuse {
		return .None
	}
	if .IO_Completion_Ready in flags && io_operation_kind != .None {
		return .Io_Completion
	}
	if .Shutdown_Pending in flags {
		return .Shutdown
	}
	if .Call_Timeout_Ready in flags {
		return .Call_Timeout
	}
	if inbox_count > 0 && (state == .Runnable || state == .Wait_Message) {
		return .Inbox
	}
	if state == .Runnable {
		return .Runnable
	}
	return .None
}

// Package-private helper for simulation checkers. Returns true if the scheduler
// would consider this slot dispatchable given its current metadata and flags.
// This intentionally reuses the production dispatchability rule so checkers do
// not drift from scheduler behavior.
@(private = "package")
_slot_should_be_dispatchable :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) -> bool {
	soa_meta := shard.metadata[type_id]
	dispatch_kind := _dispatch_kind_for_slot(
		soa_meta[slot_index]._state,
		soa_meta[slot_index].flags,
		soa_meta[slot_index].inbox_count,
		soa_meta[slot_index].io_operation_kind,
	)
	return dispatch_kind != .None
}

@(private = "package")
_dispatch_word_count :: #force_inline proc "contextless" (bit_count: int) -> int {
	return bitmap_word_count_from_bit_count(bit_count)
}

@(private = "file")
_bitset_set :: #force_inline proc "contextless" (words: []u64, bit_index: u32) {
	if len(words) == 0 {
		return
	}
	word_index := bitmap_word_index_from_bit_index(bit_index)
	words[word_index] |= bitmap_mask_from_bit_index(bit_index)
}

@(private = "file")
_bitset_clear :: #force_inline proc "contextless" (words: []u64, bit_index: u32) {
	if len(words) == 0 {
		return
	}
	word_index := bitmap_word_index_from_bit_index(bit_index)
	words[word_index] &= ~bitmap_mask_from_bit_index(bit_index)
}

@(private = "package")
_bitset_is_set :: #force_inline proc "contextless" (words: []u64, bit_index: u32) -> bool {
	if len(words) == 0 {
		return false
	}
	word_index := bitmap_word_index_from_bit_index(bit_index)
	return words[word_index] & bitmap_mask_from_bit_index(bit_index) != 0
}

@(private = "file")
_dispatchable_type_refresh :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
) {
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
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	if int(type_id) >= len(shard.dispatchable_slot_words) {
		return
	}
	words := shard.dispatchable_slot_words[type_id]
	if len(words) == 0 {
		return
	}
	slot := u32(slot_index)
	word_index := bitmap_word_index_from_bit_index(slot)
	bit_mask := bitmap_mask_from_bit_index(slot)
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
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	if int(type_id) >= len(shard.dispatchable_slot_words) {
		return
	}
	words := shard.dispatchable_slot_words[type_id]
	if len(words) == 0 {
		return
	}
	word_index := bitmap_word_index_from_bit_index(u32(slot_index))
	bit_mask := bitmap_mask_from_bit_index(u32(slot_index))
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
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	if int(type_id) >= len(shard.metadata) {
		return
	}
	soa_meta := shard.metadata[type_id]
	if int(slot_index) >= len(soa_meta) {
		return
	}
	dispatch_kind := _dispatch_kind_for_slot(
		soa_meta[slot_index]._state,
		soa_meta[slot_index].flags,
		soa_meta[slot_index].inbox_count,
		soa_meta[slot_index].io_operation_kind,
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

	start_word_index := bitmap_word_index_from_bit_index(start_bit_index)
	start_word_bit_index := bitmap_word_bit_index_from_bit_index(start_bit_index)
	last_word_index := len(words) - 1
	last_word_bit_count := bitmap_word_bit_index_from_bit_index(bit_count)
	last_word_mask := ~u64(0)
	if last_word_bit_count != 0 {
		last_word_mask = (u64(1) << last_word_bit_count) - 1
	}

	for word_index in start_word_index ..< len(words) {
		word := words[word_index]
		if word_index == last_word_index {
			word &= last_word_mask
		}
		if word_index == start_word_index && start_word_bit_index > 0 {
			word &= ~((u64(1) << start_word_bit_index) - 1)
		}
		if word == 0 {
			continue
		}

		word_bit_index := u32(bits.trailing_zeros(word))
		bit_index := bitmap_bit_index_from_word_index_and_word_bit_index(
			word_index,
			word_bit_index,
		)
		if bit_index < bit_count {
			return bit_index, true
		}
	}

	if start_word_index > 0 || start_word_bit_index > 0 {
		for word_index in 0 ..< min(start_word_index + 1, len(words)) {
			word := words[word_index]
			if word_index == last_word_index {
				word &= last_word_mask
			}
			if word_index == start_word_index {
				if start_word_bit_index == 0 {
					break
				}
				word &= (u64(1) << start_word_bit_index) - 1
			}
			if word == 0 {
				continue
			}

			word_bit_index := u32(bits.trailing_zeros(word))
			bit_index := bitmap_bit_index_from_word_index_and_word_bit_index(
				word_index,
				word_bit_index,
			)
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
	type_id: Isolate_Type_Id,
	start_slot_index: Isolate_Slot_Index,
	slot_count: u32,
) -> (
	Isolate_Slot_Index,
	bool,
) {
	result, found := _bitset_find_next_set_bit(
		shard.dispatchable_slot_words[type_id],
		u32(start_slot_index),
		slot_count,
	)
	return Isolate_Slot_Index(result), found
}

@(private = "package")
_slot_track_io_awaiting_transition :: #force_inline proc "contextless" (
	shard: ^Shard,
	old_state: Isolate_State,
	new_state: Isolate_State,
) {
	if old_state == new_state {
		return
	}
	old_io_blocked := old_state == .Wait_Io || old_state == .Pending_IO_Reuse
	new_io_blocked := new_state == .Wait_Io || new_state == .Pending_IO_Reuse

	if old_io_blocked && !new_io_blocked {
		if shard.counters.io_awaiting_count > 0 {
			shard.counters.io_awaiting_count -= 1
		}
	} else if !old_io_blocked && new_io_blocked {
		shard.counters.io_awaiting_count += 1
	}
}

@(private = "package")
_slot_set_state :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	state: Isolate_State,
) {
	old_state := shard.metadata[type_id][slot_index]._state
	_slot_track_io_awaiting_transition(shard, old_state, state)
	shard.metadata[type_id][slot_index]._state = state // ALLOWLIST_STATE_SETTER
	if state == .Unallocated {
		_sanitizer_address_poison_isolate_slot(shard, type_id, slot_index)
	}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

// _slot_set_state_no_dispatch tracks io_awaiting and poisons but does NOT
// refresh the dispatchable bitmap. For production composite procedures and
// tests that want to manually control dispatchable state.
@(private = "package")
_slot_set_state_no_dispatch :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	state: Isolate_State,
) {
	old_state := shard.metadata[type_id][slot_index]._state
	_slot_track_io_awaiting_transition(shard, old_state, state)
	shard.metadata[type_id][slot_index]._state = state // ALLOWLIST_STATE_SETTER
	if state == .Unallocated {
		_sanitizer_address_poison_isolate_slot(shard, type_id, slot_index)
	}
}

// _slot_set_state_bare writes state directly with NO invariant maintenance.
// Caller is responsible for track_io_awaiting, dispatchable_refresh, and poison.
// The reason parameter documents WHY the invariants are being bypassed.
// This is for production composite procedures and tests that decompose the invariants.
@(private = "package")
_slot_set_state_bare :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	state: Isolate_State,
	reason: string,
) {
	_ = reason
	shard.metadata[type_id][slot_index]._state = state // ALLOWLIST_STATE_SETTER
}

when TINA_SIMULATION_MODE {
	// Table-level diagnostic write. This is the canonical implementation; the
	// shard wrapper below is just a convenience for simulation code that owns
	// the Shard. Keeping the logic here lets focused tests verify the table
	// behavior without fabricating a full Shard lifetime.
	@(private = "package")
	diagnostic_table_write :: proc(
		table: ^Diagnostic_Table,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
		field_id: Diagnostic_Field_Id,
		value: u64,
	) {
		for i in 0 ..< table.record_count {
			record := &table.records[i]
			if record.isolate_type_id == type_id &&
			   record.slot_index == slot_index &&
			   record.field_id == field_id {
				record.value = value
				record.write_count += 1
				return
			}
		}
		if int(table.record_count) < len(table.records) {
			table.records[table.record_count] = Diagnostic_Record {
				isolate_type_id = type_id,
				slot_index      = slot_index,
				field_id        = field_id,
				value           = value,
				write_count     = 1,
			}
			table.record_count += 1
			return
		}
		panic("diagnostic record capacity exhausted; increase diagnostic_record_count_per_shard")
	}

	@(private = "package")
	diagnostic_table_read :: proc(
		table: ^Diagnostic_Table,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
		field_id: Diagnostic_Field_Id,
	) -> (
		value: u64,
		found: bool,
	) {
		for i in 0 ..< table.record_count {
			rec := &table.records[i]
			if rec.isolate_type_id == type_id &&
			   rec.slot_index == slot_index &&
			   rec.field_id == field_id {
				return rec.value, true
			}
		}
		return 0, false
	}

	shard_diagnostic_write :: proc(
		shard: ^Shard,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
		field_id: Diagnostic_Field_Id,
		value: u64,
	) {
		diagnostic_table_write(&shard.diagnostics, type_id, slot_index, field_id, value)
	}

	shard_diagnostic_read :: proc(
		shard: ^Shard,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
		field_id: Diagnostic_Field_Id,
	) -> (
		value: u64,
		found: bool,
	) {
		return diagnostic_table_read(&shard.diagnostics, type_id, slot_index, field_id)
	}

	shard_test_diagnostic_expect_u64 :: proc(
		t: ^testing.T,
		shard: ^Shard,
		type_id: Isolate_Type_Id,
		slot_index: Isolate_Slot_Index,
		field_id: Diagnostic_Field_Id,
		expected: u64,
		loc := #caller_location,
	) {
		value, found := shard_diagnostic_read(shard, type_id, slot_index, field_id)
		testing.expect(t, found, "diagnostic record not found", loc = loc)
		if found {
			testing.expect_value(t, value, expected, loc = loc)
		}
	}
}

@(private = "package")
_slot_set_waiting_for_reply :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	correlation_id: Correlation_Id,
) {
	meta := &shard.metadata[type_id][slot_index]
	_slot_track_io_awaiting_transition(shard, meta._state, .Wait_Reply)
	meta.pending_correlation = correlation_id
	_slot_set_state_bare(
		shard,
		type_id,
		slot_index,
		.Wait_Reply,
		"_slot_set_waiting_for_reply: track_io above, dispatchable_refresh below",
	)
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_wake_call_timeout :: #force_inline proc "contextless" (
	shard: ^Shard,
	target: Isolate_Handle,
	correlation: Correlation_Id,
) -> bool {
	type_id := extract_type_id(target)
	slot_index := extract_slot(target)
	generation := extract_generation(target)

	if int(type_id) >= len(shard.metadata) || int(slot_index) >= len(shard.metadata[type_id]) {
		shard.counters.stale_delivery_drops += 1
		return false
	}

	meta := &shard.metadata[type_id][slot_index]
	if meta.generation != generation ||
	   meta._state != .Wait_Reply ||
	   meta.pending_correlation != correlation {
		shard.counters.stale_delivery_drops += 1
		return false
	}

	// Keep pending_correlation until dispatch so the synthetic timeout message
	// preserves the call token. The state change is what rejects late replies.
	_slot_track_io_awaiting_transition(shard, meta._state, .Runnable)
	meta.flags += {.Call_Timeout_Ready}
	_slot_set_state_bare(
		shard,
		type_id,
		slot_index,
		.Runnable,
		"_wake_call_timeout: flags interleaved; track_io above, dispatchable below",
	)
	_dispatchable_refresh_slot(shard, type_id, slot_index)
	return true
}

@(private = "package")
_slot_set_io_operation_kind :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	operation_kind: IO_Operation_Kind,
) {
	shard.metadata[type_id][slot_index].io_operation_kind = operation_kind
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_add_shutdown_pending :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	shard.metadata[type_id][slot_index].flags += {.Shutdown_Pending}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_clear_shutdown_pending :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	shard.metadata[type_id][slot_index].flags -= {.Shutdown_Pending}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_increment_inbox_count :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	shard.metadata[type_id][slot_index].inbox_count += 1
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_decrement_inbox_count :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
) {
	shard.metadata[type_id][slot_index].inbox_count -= 1
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_set_io_completion_ready :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	operation_kind: IO_Operation_Kind,
	completion_result: i32,
	buffer_index: IO_Slot_Index,
) {
	meta := &shard.metadata[type_id][slot_index]
	meta.io_operation_kind = operation_kind
	meta.io_result = completion_result
	meta.io_slot_index = buffer_index
	meta.flags += {.IO_Completion_Ready}
	_sanitizer_address_unpoison_reactor_io_slot(
		&shard.reactor,
		io_operation_pool_affinity(operation_kind),
		buffer_index,
	)
	if meta._state == .Wait_Io {
		_slot_track_io_awaiting_transition(shard, meta._state, .Runnable)
		_slot_set_state_bare(
			shard,
			type_id,
			slot_index,
			.Runnable,
			"_slot_set_io_completion_ready: conditional; io fields set above, dispatchable below",
		)
	}
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

@(private = "package")
_slot_set_io_submit_failure :: #force_inline proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
	operation_kind: IO_Operation_Kind,
	completion_result: i32,
) {
	meta := &shard.metadata[type_id][slot_index]
	meta.io_operation_kind = operation_kind
	meta.io_result = completion_result
	meta.io_slot_index = IO_SLOT_INDEX_NONE
	meta.flags += {.IO_Completion_Ready}
	_slot_track_io_awaiting_transition(shard, meta._state, .Runnable)
	_slot_set_state_bare(
		shard,
		type_id,
		slot_index,
		.Runnable,
		"_slot_set_io_submit_failure: io fields set above; track_io above, dispatchable below",
	)
	_dispatchable_refresh_slot(shard, type_id, slot_index)
}

// Returns a buffer slot to its owning pool based on the operation's pool
// affinity. For receive-pool buffers, handles provided buffer ring
// replenishment when active on Linux.
@(private = "package")
_io_slot_return_to_pool :: #force_inline proc(
	reactor: ^Reactor,
	affinity: IO_Slot_Pool_Affinity,
	slot_index: IO_Slot_Index,
) {
	if slot_index == IO_SLOT_INDEX_NONE do return
	switch affinity {
	case .Receive:
		if backend_recv_uses_provided_buffers(&reactor.backend) {
			when TINA_ASAN_POISONING {
				_sanitizer_address_poison_io_slot(&reactor.receive_pool, slot_index)
			}
			backend_replenish_recv_buffer(&reactor.backend, slot_index)
		} else {
			_reactor_receive_pool_free(reactor, slot_index)
		}
	case .Staging:
		_reactor_staging_pool_free(reactor, slot_index)
	case .None:
	// No pool slot involved — nothing to return
	}
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
	type_descriptor: IsolateTypeDescriptor,
	work_budget_count: Scheduler_Work_Count,
) -> Scheduler_Work_Count {
	if work_budget_count == 0 {
		return 0
	}
	type_id := type_descriptor.id
	slot_count := u32(type_descriptor.slot_count)

	// Hoisted
	turn_frame := Isolate_Turn_Frame {
		previous_isolate_turn_frame = shard.current_isolate_turn_frame,
		isolate_handle              = ISOLATE_HANDLE_NONE, // Assigned per turn
		message_source_handle       = ISOLATE_HANDLE_NONE, // Assigned per turn
		message_correlation_id      = CORRELATION_ID_NONE, // Assigned per turn
		transfer_read_handle        = TRANSFER_HANDLE_NONE,
		turn_flags                  = {}, // Assigned per turn
		timer_resolution_ns         = shard.timer_resolution_ns,
		current_tick                = shard.current_tick,
		isolate_type_id             = type_id,
		isolate_slot_index          = 0, // Assigned per turn
		message_pool_index          = POOL_NONE_INDEX,
		staging_slot_index          = IO_SLOT_INDEX_NONE,
	}

	// Extract 1D slices to bypass 2D lookups for the entire dispatch inner-loop.
	states := shard.metadata[type_id]._state[:]
	flags := shard.metadata[type_id].flags[:]
	inbox_counts := shard.metadata[type_id].inbox_count[:]
	io_operation_kinds := shard.metadata[type_id].io_operation_kind[:]
	generations := shard.metadata[type_id].generation[:]
	io_results := shard.metadata[type_id].io_result[:]
	io_fds := shard.metadata[type_id].io_fd[:]
	io_slot_indices := shard.metadata[type_id].io_slot_index[:]
	io_peer_addresses := shard.metadata[type_id].io_peer_address[:]
	working_arena_offsets := shard.metadata[type_id].working_arena_offset[:]
	pending_correlations := shard.metadata[type_id].pending_correlation[:]

	dispatch_budget := u32(work_budget_count)
	dispatched_count: u32 = 0

	if os_trap_save(&shard.trap_environment_inner) != 0 {
		when !TINA_SIMULATION_MODE {
			// Sweep orphaned temp allocations from panic string formatting.
			free_all(context.temp_allocator)
			// Unblock signals masked by the OS during handler execution.
			os_signals_restore_thread_mask()
		}

		frame := shard.current_isolate_turn_frame
		if frame == nil {
			shard.current_trap_environment = nil
			os_trap_restore(&shard.trap_environment_outer, RECOVERY_ROOT_ESCALATE)
		}
		if frame.phase == .Scheduler_Commit {
			context.allocator = frame.previous_allocator
			context.temp_allocator = frame.previous_temp_allocator
			shard.current_isolate_turn_frame = nil
			shard.current_trap_environment = nil
			os_trap_restore(&shard.trap_environment_outer, RECOVERY_ROOT_ESCALATE)
		}

		context.allocator = frame.previous_allocator
		context.temp_allocator = frame.previous_temp_allocator
		shard.current_trap_environment = nil
		_turn_cleanup_resources(shard, frame)
		_teardown_isolate(shard, frame.isolate_type_id, frame.isolate_slot_index, .Crashed)

		// Advance the cursor past the crashed isolate.
		next_cursor := u32(frame.isolate_slot_index) + 1
		if next_cursor >= slot_count do next_cursor = 0
		shard.dispatch_cursors[type_id] = next_cursor
		shard.current_isolate_turn_frame = frame.previous_isolate_turn_frame
	}

	cursor := shard.dispatch_cursors[type_id]
	if cursor >= slot_count {
		cursor = 0
		shard.dispatch_cursors[type_id] = 0
	}

	slot_loop: for dispatched_count < dispatch_budget {
		slot_index, found := _dispatchable_find_next_slot(
			shard,
			type_id,
			Isolate_Slot_Index(cursor),
			slot_count,
		)
		if !found {
			shard.dispatch_cursors[type_id] = 0
			break slot_loop
		}

		next_cursor := u32(slot_index) + 1
		if next_cursor >= slot_count do next_cursor = 0
		shard.dispatch_cursors[type_id] = next_cursor

		dispatch_kind := _dispatch_kind_for_slot(
			states[slot_index],
			flags[slot_index],
			inbox_counts[slot_index],
			io_operation_kinds[slot_index],
		)
		if dispatch_kind == .None {
			_dispatchable_slot_set_absent(shard, type_id, slot_index)
			cursor = shard.dispatch_cursors[type_id]
			continue
		}
		dispatched_count += 1

		turn_frame.message_pool_index = POOL_NONE_INDEX

		message: Message
		message_pointer: ^Message = nil
		correlation: Correlation_Id = CORRELATION_ID_NONE
		envelope_flags: Envelope_Flags = {}

		is_io_completion := false
		buffer_to_free: IO_Slot_Index = IO_SLOT_INDEX_NONE
		dispatch_io_operation_kind := IO_Operation_Kind.None

		switch dispatch_kind {
		case .None:
		case .Io_Completion:
			dispatch_io_operation_kind = io_operation_kinds[slot_index]
			message.tag = Message_Tag(u16(dispatch_io_operation_kind))
			message.correlation = CORRELATION_ID_NONE
			message.io.result = io_results[slot_index]
			message.io.fd = io_fds[slot_index]
			message.io.buffer_index = io_slot_indices[slot_index]
			message.io.peer_address = io_peer_addresses[slot_index]

			message_pointer = &message
			is_io_completion = true
			buffer_to_free = io_slot_indices[slot_index]
		case .Shutdown:
			message.tag = TAG_SHUTDOWN
			message.correlation = CORRELATION_ID_NONE
			message.user.source = ISOLATE_HANDLE_NONE
			message.user.payload_size = 0

			message_pointer = &message
			_slot_clear_shutdown_pending(shard, type_id, slot_index)
		case .Call_Timeout:
			correlation = pending_correlations[slot_index]
			message.tag = TAG_CALL_TIMEOUT
			message.correlation = correlation
			message.user.source = ISOLATE_HANDLE_NONE
			message.user.payload_size = 0

			message_pointer = &message
			flags[slot_index] -= {.Call_Timeout_Ready}
			pending_correlations[slot_index] = CORRELATION_ID_NONE
		case .Inbox:
			dequeue_result := _dequeue(shard, type_id, slot_index)
			turn_frame.message_pool_index = dequeue_result.pool_index
			if turn_frame.message_pool_index != POOL_NONE_INDEX {
				message = dequeue_result.message
				message.correlation = dequeue_result.correlation
				correlation = dequeue_result.correlation
				envelope_flags = dequeue_result.flags
				message_pointer = &message
			}
		case .Runnable:
		}

		turn_flags: Isolate_Turn_Flags
		if .Is_Call in envelope_flags do turn_flags += {.Is_Call}

		turn_frame.isolate_handle = make_handle(
			shard.id,
			type_id,
			slot_index,
			generations[slot_index],
		)
		turn_frame.message_source_handle =
			message_pointer != nil && !is_io_completion && message.tag != TAG_SHUTDOWN ? message.user.source : ISOLATE_HANDLE_NONE
		turn_frame.message_correlation_id = correlation
		turn_frame.turn_flags = turn_flags
		turn_frame.isolate_slot_index = slot_index
		turn_frame.staged_effect.call = {}
		turn_frame.staged_effect.io.operation = {}
		turn_frame.staged_effect.kind = .None
		turn_frame.reply_sent = false
		turn_frame.transfer_read_handle = TRANSFER_HANDLE_NONE
		turn_frame.staging_slot_index = IO_SLOT_INDEX_NONE
		turn_frame.phase = .User_Code
		turn_frame.staged_effect.io.data_source = .None
		turn_frame.staged_effect.io.payload_offset = 0
		turn_frame.staged_effect.io.payload_size = 0

		mem.arena_init(&turn_frame.scratch_arena, shard.scratch_memory)

		working_stride := type_descriptor.working_memory_size
		if working_stride > 0 {
			start_index := int(slot_index) * working_stride
			working_slice := shard.working_memory[type_id][start_index:start_index +
			working_stride]
			turn_frame.working_arena = mem.Arena {
				data   = working_slice,
				offset = int(working_arena_offsets[slot_index]),
			}
		} else {
			turn_frame.working_arena = {}
		}

		isolate_pointer := _get_isolate_ptr(shard, type_id, slot_index)

		when TINA_SIMULATION_MODE {
			if ratio_chance(
				shard.sim_state.fault_config.isolate_crash_rate,
				shard.sim_state.crash_prng,
			) {
				_turn_cleanup_resources(shard, &turn_frame)
				_teardown_isolate(shard, type_id, slot_index, .Crashed)
				cursor = shard.dispatch_cursors[type_id]
				continue slot_loop
			}
		}

		previous_allocator := context.allocator
		previous_temp_allocator := context.temp_allocator
		turn_frame.previous_allocator = previous_allocator
		turn_frame.previous_temp_allocator = previous_temp_allocator
		shard.current_isolate_turn_frame = &turn_frame
		shard.current_trap_environment = &shard.trap_environment_inner
		context.allocator = _working_arena_allocator(&turn_frame.working_arena)
		context.temp_allocator = mem.arena_allocator(&turn_frame.scratch_arena)

		transition := type_descriptor.handler_fn(isolate_pointer, message_pointer)

		turn_frame.phase = .Scheduler_Commit
		context.allocator = turn_frame.previous_allocator
		context.temp_allocator = turn_frame.previous_temp_allocator
		shard.current_trap_environment = nil

		if working_stride > 0 {
			working_arena_offsets[slot_index] = u32(turn_frame.working_arena.offset)
		}

		if is_io_completion {
			io_operation_kinds[slot_index] = .None
			flags[slot_index] -= {.IO_Completion_Ready}
			io_peer_addresses[slot_index] = {}
			if buffer_to_free != IO_SLOT_INDEX_NONE {
				_io_slot_return_to_pool(
					&shard.reactor,
					io_operation_pool_affinity(dispatch_io_operation_kind),
					buffer_to_free,
				)
				io_slot_indices[slot_index] = IO_SLOT_INDEX_NONE
			}
		}

		_interpret_transition(shard, type_id, slot_index, transition, &turn_frame)
		_turn_cleanup_resources(shard, &turn_frame)
		shard.current_isolate_turn_frame = turn_frame.previous_isolate_turn_frame
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
		_dispatchable_type_refresh(shard, Isolate_Type_Id(type_index))
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
			if shard.counters.io_awaiting_count > 0 {
				reactor_service_nonblocking(&shard.reactor, shard)
			}
			dispatch_since_io_service_count = 0
		}

		type_index, found := _dispatch_ready_find_next_type(
			shard,
			shard.dispatch_type_cursor,
			type_count,
		)
		if !found {
			break
		}
		shard.dispatch_type_cursor = type_index + 1
		if shard.dispatch_type_cursor >= type_count do shard.dispatch_type_cursor = 0
		scanned_type_count += 1

		credit_count := u32(shard.dispatch_credit_counts[type_index])
		if credit_count == 0 {
			_dispatchable_type_refresh(shard, Isolate_Type_Id(type_index))
			continue
		}

		type_work_budget_count := _scheduler_dispatch_batch_count_limit(
			credit_count,
			turn_work_budget_count,
			dispatch_since_io_service_count,
		)

		dispatched_count := u32(
			_dispatch_type_batch(
				shard,
				shard.type_descriptors[type_index],
				Scheduler_Work_Count(type_work_budget_count),
			),
		)

		if dispatched_count == 0 {
			_dispatchable_type_refresh(shard, Isolate_Type_Id(type_index))
			continue
		}

		scanned_type_count = 0
		shard.dispatch_credit_counts[type_index] = Scheduler_Credit_Count(
			credit_count - dispatched_count,
		)
		_dispatchable_type_refresh(shard, Isolate_Type_Id(type_index))
		turn_work_budget_count -= dispatched_count
		dispatch_since_io_service_count += dispatched_count

		if dispatch_since_io_service_count >= io_service_interval_count {
			if shard.counters.io_awaiting_count > 0 {
				reactor_service_nonblocking(&shard.reactor, shard)
			}
			dispatch_since_io_service_count = 0
		}
	}
}

scheduler_tick :: proc(shard: ^Shard) {
	when TINA_SIMULATION_MODE {
		g_current_shard_pointer = shard
	}
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
	transport_drain_control_inbound(shard)
	transport_retry_liveness_broadcast(shard)

	// ========================================================================
	// Step 1: Drain inbound cross-shard rings → deliver to local mailboxes
	// ========================================================================
	transport_drain_inbound(shard, now)

	// ========================================================================
	// Step 2: Initial nonblocking I/O service point
	// ========================================================================
	if shard.counters.io_awaiting_count > 0 {
		reactor_service_nonblocking(&shard.reactor, shard)
	}

	// ========================================================================
	// Step 3: Replenish credits and run weighted dispatch
	// ========================================================================
	_scheduler_replenish_dispatch_credits(shard)
	_scheduler_run_dispatch_turn(shard)

	// ========================================================================
	// Step 4: Final I/O service point and handoff scans
	// ========================================================================
	reactor_flush_submissions(&shard.reactor, shard)
	if reactor_has_io_work(&shard.reactor) {
		reactor_service_nonblocking(&shard.reactor, shard)
	}
	_fd_handoff_retry_scan(shard)
	_fd_handoff_timeout_scan(shard, now)

	// ========================================================================
	// Step 5: Flush outbound cross-shard rings
	// ========================================================================
	transport_flush_control_outbound(shard)
	transport_flush_outbound(shard)

	// ========================================================================
	// Step 6 & 7: Advance timers and Flush logs
	// ========================================================================
	_advance_timers(shard)
	log_flush(shard)
}

// --- Isolate State Transition Interpreter ---

@(rodata, private = "package")
ISOLATE_FAULT_REASONS_INTERPRETED := [Isolate_Fault_Reason]string {
	.None                     = "Voluntary isolate fault reason: None",
	.Spawn_Failed             = "Voluntary isolate fault reason: Spawn_Failed",
	.Unimplemented_Transition = "Voluntary isolate fault reason: Unimplemented_Transition",
	.Init_Failed              = "Voluntary isolate fault reason: Init_Failed",
	.Contract_Violation       = "Voluntary isolate fault reason: Contract_Violation",
}

@(private = "package")
_shard_message_pool_alloc_user :: #force_inline proc "contextless" (
	shard: ^Shard,
) -> (
	u32,
	Pool_Error,
) {
	when TINA_ASAN_POISONING {
		return pool_alloc_user_tina_owned(&shard.message_pool)
	} else {
		return pool_alloc_user(&shard.message_pool)
	}
}

@(private = "package")
_shard_message_pool_alloc_system :: #force_inline proc "contextless" (
	shard: ^Shard,
) -> (
	u32,
	Pool_Error,
) {
	when TINA_ASAN_POISONING {
		return pool_alloc_system_tina_owned(&shard.message_pool)
	} else {
		return pool_alloc_system(&shard.message_pool)
	}
}

@(private = "package")
_shard_message_pool_free_unchecked :: #force_inline proc "contextless" (
	shard: ^Shard,
	index: u32,
) {
	when TINA_ASAN_POISONING {
		pool_free_unchecked_tina_owned(&shard.message_pool, index)
	} else {
		pool_free_unchecked(&shard.message_pool, index)
	}
}

@(private = "package")
_reactor_receive_pool_free :: #force_inline proc(reactor: ^Reactor, index: IO_Slot_Index) {
	when TINA_ASAN_POISONING {
		io_slot_pool_free_tina_owned(&reactor.receive_pool, index)
	} else {
		io_slot_pool_free(&reactor.receive_pool, index)
	}
}

@(private = "package")
_reactor_staging_pool_free :: #force_inline proc(reactor: ^Reactor, index: IO_Slot_Index) {
	when TINA_ASAN_POISONING {
		io_slot_pool_free_tina_owned(&reactor.staging_pool, index)
	} else {
		io_slot_pool_free(&reactor.staging_pool, index)
	}
}

@(private = "package")
_turn_cleanup_resources :: proc(shard: ^Shard, frame: ^Isolate_Turn_Frame) {
	if frame == nil do return

	if frame.message_pool_index != POOL_NONE_INDEX {
		_shard_message_pool_free_unchecked(shard, frame.message_pool_index)
		frame.message_pool_index = POOL_NONE_INDEX
	}

	if frame.transfer_read_handle != TRANSFER_HANDLE_NONE {
		_transfer_pool_free(shard, transfer_handle_index(frame.transfer_read_handle))
		frame.transfer_read_handle = TRANSFER_HANDLE_NONE
	}

	if frame.staging_slot_index != IO_SLOT_INDEX_NONE {
		_reactor_staging_pool_free(&shard.reactor, frame.staging_slot_index)
		frame.staging_slot_index = IO_SLOT_INDEX_NONE
	}
}

@(private = "file")
_transition_contract_violation :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot: Isolate_Slot_Index,
	turn_frame: ^Isolate_Turn_Frame,
	message: string,
) {
	_shard_log(
		shard,
		turn_frame.isolate_handle,
		.ERROR,
		LOG_TAG_ISOLATE_CRASHED,
		transmute([]u8)message,
	)
	_teardown_isolate(shard, type_id, slot, .Crashed)
}

@(private = "file")
_commit_staged_call :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot: Isolate_Slot_Index,
	turn_frame: ^Isolate_Turn_Frame,
) {
	staged_call := turn_frame.staged_effect.call
	correlation_id := staged_call.envelope.correlation
	turn_frame.staged_effect.kind = .None

	_slot_set_waiting_for_reply(shard, type_id, slot, correlation_id)
	_register_system_timer(
		shard,
		turn_frame.isolate_handle,
		_duration_ns_to_ticks(staged_call.timeout_ns, shard.timer_resolution_ns),
		TAG_CALL_TIMEOUT,
		correlation_id,
	)

	envelope := staged_call.envelope
	envelope.source = turn_frame.isolate_handle
	envelope.flags += {.Is_Call}
	route_result := _route_envelope_user(shard, envelope.destination, &envelope)
	if route_result != .ok {
		timeout_env: Message_Envelope
		timeout_env.source = ISOLATE_HANDLE_NONE
		timeout_env.destination = turn_frame.isolate_handle
		timeout_env.tag = TAG_CALL_TIMEOUT
		timeout_env.correlation = correlation_id
		if _enqueue_system_msg(shard, turn_frame.isolate_handle, &timeout_env) != .ok {
			shard.metadata[type_id][u32(slot)].pending_correlation = 0
			_slot_set_state(shard, type_id, slot, .Runnable)
		}
	}
}

@(private = "file")
_commit_staged_io :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot: Isolate_Slot_Index,
	turn_frame: ^Isolate_Turn_Frame,
) {
	operation := turn_frame.staged_effect.io.operation
	turn_frame.staged_effect.kind = .None

	error := reactor_submit_io(
		&shard.reactor,
		shard,
		turn_frame.isolate_handle,
		operation,
		turn_frame.staged_effect.io.data_source,
		turn_frame.staged_effect.io.payload_offset,
		turn_frame.staged_effect.io.payload_size,
		turn_frame.staging_slot_index,
	)
	if error != IO_ERR_NONE {
		_slot_set_io_submit_failure(
			shard,
			type_id,
			slot,
			_io_op_to_operation_kind(operation),
			i32(error),
		)
		// If staging slot was claimed but IO failed, free it
		staging_slot := turn_frame.staging_slot_index
		if staging_slot != IO_SLOT_INDEX_NONE {
			_reactor_staging_pool_free(&shard.reactor, staging_slot)
			turn_frame.staging_slot_index = IO_SLOT_INDEX_NONE
		}
	} else {
		// Staging claim is now owned by the in-flight I/O (kernel reads from it).
		// metadata.io_slot_index carries it until the completion reclaims via
		// _io_slot_return_to_pool. Clear the turn claim so the
		// post-commit auto-free does not return the slot while the kernel holds it.
		turn_frame.staging_slot_index = IO_SLOT_INDEX_NONE
		_slot_set_state(shard, type_id, slot, .Wait_Io)
	}
}

_interpret_transition :: proc(
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot: Isolate_Slot_Index,
	transition: Isolate_Transition,
	turn_frame: ^Isolate_Turn_Frame,
) {
	switch transition.kind {
	case .Done:
		if turn_frame.staged_effect.kind != .None {
			_transition_contract_violation(
				shard,
				type_id,
				slot,
				turn_frame,
				"Handler returned .Done with staged control-plane work",
			)
			return
		}
		_teardown_isolate(shard, type_id, slot, .Normal)
	case .Yield:
		if turn_frame.staged_effect.kind != .None {
			_transition_contract_violation(
				shard,
				type_id,
				slot,
				turn_frame,
				"Handler returned .Yield with staged control-plane work",
			)
			return
		}
		_slot_set_state(shard, type_id, slot, .Runnable)
	case .Wait_Message:
		if turn_frame.staged_effect.kind != .None {
			_transition_contract_violation(
				shard,
				type_id,
				slot,
				turn_frame,
				"Handler returned .Wait_Message with staged control-plane work",
			)
			return
		}
		_slot_set_state(shard, type_id, slot, .Wait_Message)
	case .Crash:
		if turn_frame.staged_effect.kind != .None {
			_transition_contract_violation(
				shard,
				type_id,
				slot,
				turn_frame,
				"Handler returned .Crash with staged control-plane work",
			)
			return
		}
		reason_str := ISOLATE_FAULT_REASONS_INTERPRETED[transition.fault_reason]
		_shard_log(
			shard,
			turn_frame.isolate_handle,
			.ERROR,
			LOG_TAG_ISOLATE_CRASHED,
			transmute([]u8)reason_str,
		)
		_teardown_isolate(shard, type_id, slot, .Crashed)
	case .Wait_Reply:
		if turn_frame.staged_effect.kind != .Call {
			_transition_contract_violation(
				shard,
				type_id,
				slot,
				turn_frame,
				"Handler returned .Wait_Reply without exactly one staged call",
			)
			return
		}
		_commit_staged_call(shard, type_id, slot, turn_frame)
	case .Wait_Io:
		if turn_frame.staged_effect.kind != .IO {
			_transition_contract_violation(
				shard,
				type_id,
				slot,
				turn_frame,
				"Handler returned .Wait_Io without exactly one staged io submission",
			)
			return
		}
		_commit_staged_io(shard, type_id, slot, turn_frame)
	}
}

// --- Message Routing ---

@(private = "file")
Message_Allocation_Policy :: enum u8 {
	User,
	System,
}

@(private = "file")
Mailbox_Capacity_Policy :: enum u8 {
	Respect,
	Bypass,
}

@(private = "package")
_route_envelope_user :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, .User, .Respect)
}

@(private = "package")
_route_envelope_system :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, .System, .Bypass)
}

@(private = "package")
_route_envelope_reply :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _route_envelope_internal(shard, to, envelope, .System, .Bypass)
}

@(private = "file")
_route_envelope_internal :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
	allocation_policy: Message_Allocation_Policy,
	capacity_policy: Mailbox_Capacity_Policy,
) -> Send_Result {
	destination := extract_shard_id(to)

	if destination == shard.id {
		return _enqueue_internal(shard, to, envelope, allocation_policy, capacity_policy)
	} else {
		return transport_route_envelope(shard, destination, envelope)
	}
}

@(private = "package")
_enqueue_user_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, .User, .Respect)
}

@(private = "package")
_enqueue_system_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, .System, .Bypass)
}

@(private = "package")
_enqueue_reply_msg :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
) -> Send_Result {
	return _enqueue_internal(shard, to, envelope, .System, .Bypass)
}

// Hot path: must remain contextless (no assert/fmt/make/default-allocator calls).
// Index validity is structurally guaranteed by pool alloc/free lifecycle.
@(private = "file")
_enqueue_internal :: #force_inline proc "contextless" (
	shard: ^Shard,
	to: Isolate_Handle,
	envelope: ^Message_Envelope,
	allocation_policy: Message_Allocation_Policy,
	capacity_policy: Mailbox_Capacity_Policy,
) -> Send_Result {
	type_id := extract_type_id(to)
	slot := extract_slot(to)
	is_reply := .Is_Reply in envelope.flags
	is_timeout := envelope.tag == TAG_CALL_TIMEOUT
	if is_timeout {
		return _wake_call_timeout(shard, to, envelope.correlation) ? .ok : .stale_handle
	}
	soa_meta := shard.metadata[type_id]

	if soa_meta[slot].generation != extract_generation(to) {
		shard.counters.stale_delivery_drops += 1
		return .stale_handle
	}

	// Validation Only (No Mutation Yet)
	if is_reply {
		if soa_meta[slot]._state != .Wait_Reply ||
		   soa_meta[slot].pending_correlation != envelope.correlation {
			shard.counters.stale_delivery_drops += 1
			return .stale_handle
		}
	} else if capacity_policy == .Respect {
		// Capacity Check ONLY for normal user messages
		// Replies and timeouts bypass mailbox limits to prevent deadlocks
		if soa_meta[slot].inbox_count >= shard.type_descriptors[type_id].mailbox_capacity {
			shard.counters.mailbox_full_drops += 1
			return .mailbox_full
		}
	}

	// Pool Allocation
	pool_index: u32
	error: Pool_Error
	// Because `allocation_policy` is passed as a constant from the wrapper,
	// I expect the compiler will dead-code-eliminate this IF statement.
	if allocation_policy == .User {
		pool_index, error = _shard_message_pool_alloc_user(shard)
	} else {
		pool_index, error = _shard_message_pool_alloc_system(shard)
	}

	if error != .None {
		shard.counters.pool_exhaustion_drops += 1
		return .pool_exhausted
	}

	// Safe State Mutation (We are guaranteed to enqueue now)
	if is_reply {
		soa_meta[slot].pending_correlation = 0
		_slot_set_state(shard, type_id, slot, .Runnable)
	}

	// Link into Mailbox
	envelope_destination := pool_get_ptr_unchecked(&shard.message_pool, pool_index)
	envelope_destination^ = envelope^
	envelope_destination.next_in_mailbox = POOL_NONE_INDEX

	if soa_meta[slot].inbox_head == POOL_NONE_INDEX {
		soa_meta[slot].inbox_head = pool_index
	} else {
		tail_envelope := pool_get_ptr_unchecked(&shard.message_pool, soa_meta[slot].inbox_tail)
		tail_envelope.next_in_mailbox = pool_index
	}

	soa_meta[slot].inbox_tail = pool_index
	_slot_increment_inbox_count(shard, type_id, slot)

	if soa_meta[slot]._state == .Wait_Message {
		_slot_set_state(shard, type_id, slot, .Runnable)
	}
	return .ok
}

@(private = "package")
Dequeue_Result :: struct {
	pool_index:  u32,
	correlation: Correlation_Id,
	message:     Message,
	flags:       Envelope_Flags,
}

@(private = "package")
_dequeue :: proc "contextless" (
	shard: ^Shard,
	type_id: Isolate_Type_Id,
	slot: Isolate_Slot_Index,
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
	entry_index, lookup_error := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
	if lookup_error != .None {
		return false
	}
	entry := &shard.handoff_table.entries[entry_index]

	cleanup_fd := entry.cleanup_fd
	free_error := fd_handoff_table_free(&shard.handoff_table, ref)
	if free_error != .None {
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
	retry_pool_index, pool_error := _shard_message_pool_alloc_system(shard)
	if pool_error != .None {
		return false
	}

	retry_envelope := pool_get_ptr_unchecked(&shard.message_pool, retry_pool_index)
	retry_envelope^ = envelope^
	retry_envelope.next_in_mailbox = POOL_NONE_INDEX

	if shard.handoff_retry_head == POOL_NONE_INDEX {
		shard.handoff_retry_head = retry_pool_index
	} else {
		tail_envelope := pool_get_ptr_unchecked(&shard.message_pool, shard.handoff_retry_tail)
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
		retry_envelope := pool_get_ptr_unchecked(&shard.message_pool, retry_pool_index)
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

			_shard_message_pool_free_unchecked(shard, retry_pool_index)
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
	destination: Isolate_Handle,
	ref: FD_Handoff_Ref,
	os_fd: OS_FD,
) -> FD_Handoff_Control_Send {
	env: Message_Envelope
	env.source = ISOLATE_HANDLE_NONE
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
	type_id:    Isolate_Type_Id,
	slot_index: Isolate_Slot_Index,
}

@(private = "file")
_resolve_target_slot :: #force_inline proc "contextless" (
	shard: ^Shard,
	target: Isolate_Handle,
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

	return Target_Slot{type_id = type_id, slot_index = slot_index}, true
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
	destination: Isolate_Handle,
	source: Isolate_Handle,
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
	destination: Isolate_Handle,
	source: Isolate_Handle,
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
	target: Isolate_Handle,
	fd: FD_Handle,
	peer_address: Peer_Address,
) -> FD_Handoff_Reject_Reason {
	target_slot, ok := _resolve_target_slot(shard, target)
	if !ok {
		return .Invalid_Target
	}

	soa_meta := shard.metadata[target_slot.type_id]
	if soa_meta[target_slot.slot_index]._state == .Unallocated ||
	   soa_meta[target_slot.slot_index]._state == .Crashed {
		return .Invalid_Target
	}
	if soa_meta[target_slot.slot_index]._state == .Wait_Io ||
	   soa_meta[target_slot.slot_index].io_operation_kind != .None {
		return .Target_Busy
	}

	_slot_set_io_operation_kind(
		shard,
		target_slot.type_id,
		target_slot.slot_index,
		.Accept_Complete,
	)
	soa_meta[target_slot.slot_index].io_result = 0
	soa_meta[target_slot.slot_index].io_fd = fd
	soa_meta[target_slot.slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	soa_meta[target_slot.slot_index].io_peer_address = peer_address
	soa_meta[target_slot.slot_index].flags += {.IO_Completion_Ready}
	_dispatchable_refresh_slot(shard, target_slot.type_id, target_slot.slot_index)
	return .None
}

@(private = "file")
_clear_fd_handoff_accept :: proc "contextless" (
	shard: ^Shard,
	target: Isolate_Handle,
	fd: FD_Handle,
) {
	target_slot, ok := _resolve_target_slot(shard, target)
	if !ok {
		return
	}

	soa_meta := shard.metadata[target_slot.type_id]
	if soa_meta[target_slot.slot_index].io_operation_kind != .Accept_Complete {
		return
	}
	if soa_meta[target_slot.slot_index].io_fd != fd {
		return
	}

	_slot_set_io_operation_kind(shard, target_slot.type_id, target_slot.slot_index, .None)
	soa_meta[target_slot.slot_index].io_result = 0
	soa_meta[target_slot.slot_index].io_fd = FD_HANDLE_NONE
	soa_meta[target_slot.slot_index].io_slot_index = IO_SLOT_INDEX_NONE
	soa_meta[target_slot.slot_index].io_peer_address = Peer_Address{}
	soa_meta[target_slot.slot_index].flags -= {.IO_Completion_Ready}
	_dispatchable_refresh_slot(shard, target_slot.type_id, target_slot.slot_index)
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
		if soa_meta[target_slot.slot_index].io_operation_kind == .Accept_Complete {
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
	when TINA_ASAN_POISONING {
		pool_reset_tina_owned(&shard.message_pool)
	} else {
		pool_reset(&shard.message_pool)
	}
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0

	when TINA_ASAN_POISONING {
		io_slot_pool_reset_tina_owned(&shard.transfer_pool)
	} else {
		io_slot_pool_reset(&shard.transfer_pool)
	}
	for i in 0 ..< shard.transfer_pool.slot_count {
		shard.transfer_generations[i] += 1
		if shard.transfer_generations[i] == 0 do shard.transfer_generations[i] = 1
	}

	// Sweep unsubmitted I/O buffers from the reactor's pending queue.
	// If a Level 2 fault interrupted the thread during Step 3 (Dispatch),
	// these buffers were allocated but never reached the OS kernel.
	for i in 0 ..< shard.reactor.pending_count {
		sub := &shard.reactor.pending_submissions[i]
		type_index := submission_token_type_index(sub.token)
		slot_index := submission_token_slot_index(sub.token)
		buffer_index := submission_token_buffer_index(sub.token)
		if buffer_index != IO_SLOT_INDEX_NONE {
			_io_slot_return_to_pool(
				&shard.reactor,
				io_operation_pool_affinity(submission_token_operation_kind(sub.token)),
				buffer_index,
			)
		}
		if int(type_index) < len(shard.metadata) &&
		   int(slot_index) < len(shard.metadata[type_index]) {
			shard.metadata[type_index][slot_index].io_slot_index = IO_SLOT_INDEX_NONE
		}
	}
	shard.reactor.pending_count = 0
	shard.reactor.io_in_flight_count = 0

	for i in 0 ..< shard.reactor.fd_table.slot_count {
		entry := &shard.reactor.fd_table.entries[i]

		if entry.reader_isolate != ISOLATE_HANDLE_NONE ||
		   entry.writer_isolate != ISOLATE_HANDLE_NONE {
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
		type_id := type_desc.id
		soa_meta := shard.metadata[type_id]

		// Reset the free head for this type
		shard.isolate_free_heads[type_id] = POOL_NONE_INDEX
		shard.dispatch_cursors[type_id] = 0

		for slot := int(type_desc.slot_count) - 1; slot >= 0; slot -= 1 {
			// SWEEP: Reclaim completed but undispatched I/O buffers before wiping
			// metadata. The IO_Completion_Ready flag is the authoritative discriminator
			// — io_operation_kind is now set at submission time too
			// (ADR §5.3), so checking the tag alone would free in-flight slots whose
			// pool memory the kernel is still using.
			if .IO_Completion_Ready in soa_meta[slot].flags &&
			   soa_meta[slot].io_slot_index != IO_SLOT_INDEX_NONE {
				_io_slot_return_to_pool(
					&shard.reactor,
					io_operation_pool_affinity(soa_meta[slot].io_operation_kind),
					soa_meta[slot].io_slot_index,
				)
			}

			new_generation := (soa_meta[slot].generation + 1) & 0x0FFFFFFF
			if new_generation == 0 do new_generation = 1

			soa_meta[slot].generation = new_generation
			_slot_set_state_bare(
				shard,
				type_id,
				Isolate_Slot_Index(slot),
				.Unallocated,
				"mass_teardown: bulk io_awaiting+dispatchable reset after loop; poison called separately",
			)
			soa_meta[slot].inbox_count = 0
			soa_meta[slot].inbox_tail = POOL_NONE_INDEX
			soa_meta[slot].pending_correlation = 0
			soa_meta[slot].io_operation_kind = .None
			soa_meta[slot].working_arena_offset = 0
			soa_meta[slot].flags = {}

			// Re-link the intrusive free list!
			soa_meta[slot].inbox_head = shard.isolate_free_heads[type_id]
			shard.isolate_free_heads[type_id] = u32(slot)
			_sanitizer_address_poison_isolate_slot(shard, type_id, Isolate_Slot_Index(slot))
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
	shard.counters.io_awaiting_count = 0
	shard.dispatch_type_cursor = 0
	shard.current_isolate_turn_frame = nil
	shard.current_trap_environment = nil

	timer_wheel_reset(&shard.timer_wheel)

	shard.next_correlation_id = 0
	// Control Signal reset
	store_shard_control_signal(shard, .None)

	// Step 6: Notify peers through the control-plane liveness channel.
	shard_broadcast_liveness_state(shard, .Running)
	transport_flush_control_outbound(shard)
}

// Checks if any Isolates are still alive across all types on this Shard.
@(private)
shard_has_live_isolates :: proc(shard: ^Shard) -> bool {
	for type_desc in shard.type_descriptors {
		states := shard.metadata[type_desc.id]._state[:]
		for i in 0 ..< type_desc.slot_count {
			if states[i] != .Unallocated {
				return true
			}
		}
	}
	return false
}

@(private = "package")
shard_broadcast_liveness_state :: proc(shard: ^Shard, state: Shard_State) {
	when TINA_RUNTIME_ASSERTIONS {
		assert(shard != nil, "Shard liveness broadcast requires a shard")
		if shard.shard_count > 0 {
			assert(
				int(shard.id) < int(shard.shard_count),
				"Shard id must be within shard count before liveness broadcast",
			)
		}
	}
	shard.liveness_epoch += 1
	if shard.liveness_epoch == 0 do shard.liveness_epoch = 1

	shard.liveness_broadcast_epoch = shard.liveness_epoch
	shard.liveness_broadcast_state = state
	shard.liveness_broadcast_pending_mask = {}

	for target_index in 0 ..< int(shard.shard_count) {
		target_shard := Shard_Id(target_index)
		if target_shard != shard.id {
			shard_mask_include(&shard.liveness_broadcast_pending_mask, target_shard)
		}
	}

	transport_retry_liveness_broadcast(shard)
}

@(private = "package")
_process_inbound_control_event :: proc "contextless" (
	shard: ^Shard,
	source_shard: Shard_Id,
	event: ^Shard_Control_Event,
) {
	if event.kind != .Liveness do return
	if source_shard >= Shard_Id(shard.shard_count) do return
	if event.source != source_shard do return
	source_index := int(source_shard)
	if event.epoch == 0 || event.epoch <= shard.liveness_epoch_seen[source_index] do return

	shard.liveness_epoch_seen[source_index] = event.epoch

	switch event.state {
	case .Running:
		// A new peer epoch invalidates in-flight handoffs from the old incarnation.
		_fd_handoff_close_entries_for_target_shard(shard, source_shard, false)
		shard_mask_include(&shard.peer_alive_mask, source_shard)
	case .Quarantined:
		shard_mask_exclude(&shard.peer_alive_mask, source_shard)
		_fd_handoff_close_entries_for_target_shard(shard, source_shard, false)
	case .Init, .Shutting_Down, .Terminated:
		shard_mask_exclude(&shard.peer_alive_mask, source_shard)
	}
}

@(private = "package")
_process_inbound_envelope :: #force_inline proc "contextless" (
	shard: ^Shard,
	source_shard: Shard_Id,
	envelope: ^Message_Envelope,
) {
	// System Broadcast Intercept
	if envelope.destination == ISOLATE_HANDLE_NONE {
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
		if .Is_Reply in envelope.flags {
			_ = _enqueue_reply_msg(shard, envelope.destination, envelope)
		} else {
			_ = _enqueue_user_msg(shard, envelope.destination, envelope)
		}
	}
}

@(private = "file")
_alloc_handoff_test_entry :: proc(
	t: ^testing.T,
	shard: ^Shard,
	target_handle: Isolate_Handle,
	deadline_tick: u64,
) -> FD_Handoff_Ref {
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
		deadline_tick,
		shard.id,
	)
	testing.expect_value(t, alloc_error, FD_Handoff_Table_Error.None)
	return ref
}

@(private = "file")
_make_handoff_test_fixture :: proc(
	t: ^testing.T,
	handoff_entry_count: int = 4,
) -> ^Test_Shard_Fixture {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {0},
			subsystems = {.Metadata, .Reactor, .Handoff_Table},
			reactor_buffer_count = 4,
			reactor_buffer_bytes = 1024,
			staging_slot_count = 2,
			staging_slot_size = 1024,
			fd_table_slot_count = 8,
			handoff_entry_count = handoff_entry_count,
		},
	)

	fixture.shard.peer_alive_mask = {~u64(0), ~u64(0), ~u64(0), ~u64(0)}
	fixture.shard.handoff_retry_head = POOL_NONE_INDEX
	fixture.shard.handoff_retry_tail = POOL_NONE_INDEX
	fixture.shard.handoff_retry_count = 0

	when TINA_SIMULATION_MODE {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend_deinit(&fixture.shard.reactor.backend)
		config := Backend_Config {
			queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
			sim_config = Simulation_IO_Config{world = cast(rawptr)world},
		}
		error := backend_init(&fixture.shard.reactor.backend, config)
		testing.expect_value(t, error, Backend_Error.None)
	}

	return fixture
}

@(private = "package")
_make_teardown_test_shard :: proc(t: ^testing.T) -> ^Test_Shard_Fixture {
	return _make_teardown_test_shard_with_slots(t, 1)
}

@(private = "package")
_make_teardown_test_shard_with_slots :: proc(
	t: ^testing.T,
	isolate_slot_count: int,
) -> ^Test_Shard_Fixture {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {isolate_slot_count},
			subsystems = {.Metadata, .Message_Pool, .Reactor, .Transfer_Pool, .Handoff_Table},
			message_pool_slots = 16,
			reactor_buffer_count = 4,
			reactor_buffer_bytes = 1024,
			transfer_slot_count = 4,
			transfer_slot_size = 1024,
			staging_slot_count = 2,
			staging_slot_size = 1024,
			fd_table_slot_count = 8,
			handoff_entry_count = 8,
		},
	)
	return fixture
}

@(test)
test_io_awaiting_count_tracks_slot_state_transitions :: proc(t: ^testing.T) {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec{type_count = 1, slot_counts = {1}, subsystems = {.Metadata}},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard
	test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)

	_slot_set_state(shard, 0, 0, .Runnable)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))

	_slot_set_state(shard, 0, 0, .Wait_Io)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))

	_slot_set_state(shard, 0, 0, .Wait_Io)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))

	_slot_set_io_completion_ready(shard, 0, 0, .Recv_Complete, 8, IO_SLOT_INDEX_NONE)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))
	testing.expect_value(t, shard.metadata[0][0]._state, Isolate_State.Runnable)

	_slot_set_state(shard, 0, 0, .Wait_Io)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))

	_slot_set_io_submit_failure(shard, 0, 0, .Recv_Complete, i32(IO_ERR_RESOURCE_EXHAUSTED))
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))
	testing.expect_value(t, shard.metadata[0][0]._state, Isolate_State.Runnable)

	_slot_set_state(shard, 0, 0, .Wait_Io)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))

	_slot_set_waiting_for_reply(shard, 0, 0, 7)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))
	testing.expect_value(t, shard.metadata[0][0]._state, Isolate_State.Wait_Reply)

	// Pending_IO_Reuse: transitioning from Wait_Io to Pending_IO_Reuse
	// should NOT decrement the counter — the slot is still I/O-blocked.
	_slot_set_state(shard, 0, 0, .Wait_Io)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))

	_slot_set_state(shard, 0, 0, .Pending_IO_Reuse)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(1))

	// Resolving Pending_IO_Reuse → Unallocated MUST decrement.
	_slot_set_state(shard, 0, 0, .Unallocated)
	testing.expect_value(t, shard.counters.io_awaiting_count, u64(0))
}

@(test)
test_dispatchable_refresh_slot_updates_type_summary :: proc(t: ^testing.T) {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {2},
			subsystems = {.Metadata, .Dispatchable},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.dispatch_credit_counts[0] = 1
	_slot_set_state_no_dispatch(shard, 0, 1, .Runnable)
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

	_slot_set_state_no_dispatch(shard, 0, 1, .Wait_Io)
	_dispatchable_refresh_slot(shard, 0, 1)

	testing.expect_value(t, shard.dispatchable_slot_counts[0], u32(0))
	testing.expect_value(t, shard.dispatchable_slot_words[0][0], u64(0))
	testing.expect_value(t, shard.dispatchable_type_words[0], u64(0))
	testing.expect_value(t, shard.dispatch_ready_type_words[0], u64(0))
}

@(test)
test_dispatchable_find_next_slot_wraps_within_single_word :: proc(t: ^testing.T) {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {64},
			subsystems = {.Metadata, .Dispatchable},
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.dispatchable_slot_words[0][0] = (u64(1) << 5) | (u64(1) << 63)

	slot_index, found := _dispatchable_find_next_slot(shard, 0, Isolate_Slot_Index(6), 64)
	testing.expect(t, found, "expected to find wrapped dispatchable slot")
	testing.expect_value(t, slot_index, Isolate_Slot_Index(63))

	slot_index, found = _dispatchable_find_next_slot(shard, 0, Isolate_Slot_Index(6), 63)
	testing.expect(t, found, "expected wrapped search to reach lower bits in same word")
	testing.expect_value(t, slot_index, Isolate_Slot_Index(5))
}

@(test)
test_message_policy_separates_transfer_from_reply_allocation :: proc(t: ^testing.T) {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {1},
			subsystems = {.Metadata, .Message_Pool},
			message_pool_slots = 128,
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.id = 0
	shard.type_descriptors[0].mailbox_capacity = 128

	target := make_handle(0, 0, 0, 1)
	test_shard_slot_activate(fixture, target, .Wait_Message)

	testing.expect_value(t, shard.message_pool.reserved_count, u32(1))

	for shard.message_pool.free_count > shard.message_pool.reserved_count {
		_, pool_error := _shard_message_pool_alloc_user(shard)
		testing.expect_value(t, pool_error, Pool_Error.None)
	}
	testing.expect_value(t, shard.message_pool.free_count, shard.message_pool.reserved_count)

	transfer_envelope := Message_Envelope {
		source       = target,
		destination  = target,
		tag          = TAG_TRANSFER,
		payload_size = u16(size_of(Transfer_Handle)),
	}
	transfer_result := _route_envelope_user(shard, target, &transfer_envelope)
	testing.expect_value(t, transfer_result, Send_Result.pool_exhausted)
	testing.expect_value(t, shard.message_pool.free_count, shard.message_pool.reserved_count)
	testing.expect_value(t, shard.metadata[0][0].inbox_count, u16(0))

	correlation_id := Correlation_Id(7)
	_slot_set_state_no_dispatch(shard, 0, 0, .Wait_Reply)
	shard.metadata[0][0].pending_correlation = correlation_id
	reply_envelope := Message_Envelope {
		source      = target,
		destination = target,
		correlation = correlation_id,
		tag         = USER_MESSAGE_TAG_BASE,
		flags       = {.Is_Reply},
	}
	reply_result := _route_envelope_reply(shard, target, &reply_envelope)
	testing.expect_value(t, reply_result, Send_Result.ok)
	testing.expect_value(t, shard.message_pool.free_count, u32(0))
	testing.expect_value(t, shard.metadata[0][0]._state, Isolate_State.Runnable)
	testing.expect_value(t, shard.metadata[0][0].pending_correlation, Correlation_Id(0))
	testing.expect_value(t, shard.metadata[0][0].inbox_count, u16(1))
}

@(test)
test_fd_handoff_send_ack_defers_and_retries_when_ring_is_full :: proc(t: ^testing.T) {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {0},
			subsystems = {.Metadata, .Message_Pool},
			message_pool_slots = 4,
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.id = 1
	shard.shard_count = 2
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0
	shard_mask_include(&shard.peer_alive_mask, 0)

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
		network_error := sim_network_init(
			&network,
			2,
			ring_sizes,
			&drop_prng,
			context.temp_allocator,
		)
		testing.expect_value(t, network_error, mem.Allocator_Error.None)

		fault_config := FaultConfig{}
		shard.sim_state.network = &network
		shard.sim_state.fault_config = &fault_config

		prefill_envelope := Message_Envelope {
			source      = make_handle(1, 1, 0, 1),
			destination = ISOLATE_HANDLE_NONE,
		}
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

		prefill_envelope := Message_Envelope {
			source      = make_handle(1, 1, 0, 1),
			destination = make_handle(0, 1, 0, 1),
		}
		testing.expect_value(
			t,
			spsc_ring_enqueue(&ring, &prefill_envelope),
			Enqueue_Result.Success,
		)

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
		target_fixture := test_shard_fixture_init(
			Test_Shard_Spec{type_count = 1, slot_counts = {0}, subsystems = {.Metadata}},
		)
		defer test_shard_fixture_deinit(target_fixture)
		target_shard := &target_fixture.shard
		target_shard.id = 0
		target_shard.sim_state.network = shard.sim_state.network
		target_shard.sim_state.fault_config = shard.sim_state.fault_config
		sim_network_drain(shard.sim_state.network, target_shard, shard.id, 0)
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
	fixture := _make_teardown_test_shard(t)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.dispatch_credit_counts[0] = 7
	shard.dispatch_type_cursor = 1
	shard.current_isolate_turn_frame = cast(^Isolate_Turn_Frame)uintptr(1)
	shard.current_trap_environment = &shard.trap_environment_inner

	shard_mass_teardown(shard)

	testing.expect_value(t, shard.dispatch_credit_counts[0], Scheduler_Credit_Count(0))
	testing.expect_value(t, shard.dispatch_type_cursor, u32(0))
	testing.expect_value(t, shard.current_isolate_turn_frame, nil)
	testing.expect_value(t, shard.current_trap_environment, nil)
}

@(test)
test_fd_handoff_retry_scan_drops_unroutable_control_messages :: proc(t: ^testing.T) {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec {
			type_count = 1,
			slot_counts = {0},
			subsystems = {.Metadata, .Message_Pool},
			message_pool_slots = 2,
		},
	)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.id = 0
	shard.handoff_retry_head = POOL_NONE_INDEX
	shard.handoff_retry_tail = POOL_NONE_INDEX
	shard.handoff_retry_count = 0

	retry_envelope := Message_Envelope {
		source       = make_handle(0, 1, 0, 1),
		destination  = make_handle(1, 1, 0, 1),
		tag          = TAG_FD_HANDOFF_REJECT,
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
	fixture := _make_handoff_test_fixture(t, 4)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	ref_target_1_a := _alloc_handoff_test_entry(t, shard, make_handle(1, 1, 0, 1), 100)
	ref_target_1_b := _alloc_handoff_test_entry(t, shard, make_handle(1, 1, 1, 1), 100)
	ref_target_2 := _alloc_handoff_test_entry(t, shard, make_handle(2, 1, 0, 1), 100)

	quarantine_envelope := Message_Envelope {
		source      = ISOLATE_HANDLE_NONE,
		destination = ISOLATE_HANDLE_NONE,
		tag         = TAG_SHARD_QUARANTINED,
	}
	_process_inbound_envelope(shard, 1, &quarantine_envelope)

	_, lookup_err_target_1_a := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_1_a)
	_, lookup_err_target_1_b := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_1_b)
	_, lookup_err_target_2 := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_2)

	testing.expect(
		t,
		lookup_err_target_1_a != .None,
		"quarantined target shard entries should be reclaimed",
	)
	testing.expect(
		t,
		lookup_err_target_1_b != .None,
		"all quarantined target shard entries should be reclaimed",
	)
	testing.expect_value(t, lookup_err_target_2, FD_Handoff_Table_Error.None)
}

@(test)
test_liveness_control_channel_delivers_without_data_plane_capacity :: proc(t: ^testing.T) {
	source_fixture := test_shard_fixture_init(
		Test_Shard_Spec{type_count = 1, slot_counts = {0}, subsystems = {.Metadata}},
	)
	defer test_shard_fixture_deinit(source_fixture)
	source := &source_fixture.shard

	target_fixture := _make_handoff_test_fixture(t, 2)
	defer test_shard_fixture_deinit(target_fixture)
	target := &target_fixture.shard

	source.id = 0
	source.shard_count = 2
	target.id = 1
	target.shard_count = 2

	channel_cells: [2]Shard_Control_Channel_Cell
	channel: Shard_Control_Channel
	shard_control_channel_init(&channel, 2, channel_cells[:])
	outbound_control_channels: [1]^Shard_Control_Channel
	outbound_control_channels[0] = &channel
	source.outbound_control_channels = outbound_control_channels[:]
	target.inbound_control_channel = &channel

	ref_target_0 := _alloc_handoff_test_entry(t, target, make_handle(0, 1, 0, 1), 100)

	shard_broadcast_liveness_state(source, .Quarantined)
	testing.expect(
		t,
		!shard_mask_contains(&source.liveness_broadcast_pending_mask, 1),
		"dedicated source cell should publish liveness without data-plane backpressure",
	)
	testing.expect_value(t, source.counters.liveness_control_publish_count, u64(1))

	transport_drain_control_inbound(target)
	_, lookup_error := fd_handoff_table_lookup_index(&target.handoff_table, ref_target_0)
	testing.expect(
		t,
		lookup_error != .None,
		"delivered quarantine should reclaim target-shard handoffs",
	)
	testing.expect(
		t,
		!shard_mask_contains(&target.peer_alive_mask, 0),
		"delivered quarantine should clear peer liveness",
	)
}

@(test)
test_liveness_restart_epoch_closes_stale_peer_handoffs :: proc(t: ^testing.T) {
	fixture := _make_handoff_test_fixture(t, 2)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	shard.id = 1
	shard.shard_count = 2
	shard_mask_exclude(&shard.peer_alive_mask, 0)
	ref_target_0 := _alloc_handoff_test_entry(t, shard, make_handle(0, 1, 0, 1), 100)

	event := Shard_Control_Event {
		epoch  = 7,
		source = Shard_Id(0),
		state  = .Running,
		kind   = .Liveness,
	}
	_process_inbound_control_event(shard, 0, &event)

	_, lookup_error := fd_handoff_table_lookup_index(&shard.handoff_table, ref_target_0)
	testing.expect(
		t,
		lookup_error != .None,
		"restart epoch should reclaim stale target-shard handoffs",
	)
	testing.expect(
		t,
		shard_mask_contains(&shard.peer_alive_mask, 0),
		"restart epoch should restore peer liveness",
	)
}

@(test)
test_fd_handoff_close_all_entries_reclaims_all_in_flight_entries :: proc(t: ^testing.T) {
	fixture := _make_handoff_test_fixture(t, 4)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

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
	fixture := _make_handoff_test_fixture(t, 2)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	target_handle := make_handle(1, 1, 0, 1)
	ref := _alloc_handoff_test_entry(t, shard, target_handle, 5)

	_fd_handoff_timeout_scan(shard, 6)

	entry_index, lookup_error := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
	testing.expect_value(t, lookup_error, FD_Handoff_Table_Error.None)
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
	fixture := _make_handoff_test_fixture(t, 2)
	defer test_shard_fixture_deinit(fixture)
	shard := &fixture.shard

	target_handle := make_handle(1, 1, 0, 1)
	ref := _alloc_handoff_test_entry(t, shard, target_handle, 100)

	shard_mass_teardown(shard)

	_, lookup_error := fd_handoff_table_lookup_index(&shard.handoff_table, ref)
	testing.expect(
		t,
		lookup_error != .None,
		"mass teardown should reclaim in-flight handoff entries",
	)
	testing.expect_value(t, shard.handoff_table.free_count, shard.handoff_table.entry_count)
	testing.expect_value(t, shard.counters.handoff_timeouts, u64(0))
}
