package tina

import "core:testing"

// ============================================================================
// FD Table — Shard-Owned File Descriptor Registry (§6.6.1 §3, §6.6.3 §6)
// ============================================================================
//
// Fixed-size table mapping FD_Handle (generational index) to OS file descriptors.
// Direction-partitioned ownership: each entry tracks reader_isolate and writer_isolate
// separately, enabling full-duplex split affinity (§6.6.3 §17).
//
// Managed via an intrusive LIFO free list with u16 indices.
// Ginger Bill pool pattern — same as message pool and reactor buffer pool.

FD_TABLE_NONE_INDEX :: u16(0xFFFF)
FD_TABLE_SLOT_COUNT_MAX :: int(FD_TABLE_NONE_INDEX)

#assert(FD_TABLE_SLOT_COUNT_MAX == int(FD_TABLE_NONE_INDEX))

FD_Table :: struct {
	entries:    []FD_Entry,
	free_head:  u16,
	free_count: u16,
	slot_count: u16,
}

FD_Table_Error :: enum u8 {
	None,
	Table_Full,
	Invalid_Index,
	Stale_Generation,
	Affinity_Violation,
}

// Initialize the FD table with a backing slice of FD_Entry.
// All slots start on the free list. Entries must be pre-allocated.
fd_table_init :: proc(table: ^FD_Table, backing: []FD_Entry) {
	assert(
		len(backing) <= FD_TABLE_SLOT_COUNT_MAX,
		"FD table slot count exceeds FD_Handle index capacity",
	)
	table.entries = backing
	table.slot_count = u16(len(backing))
	table.free_count = table.slot_count
	table.free_head = FD_TABLE_NONE_INDEX

	// Build LIFO free list: slot 0 at head for initial cache locality.
	// Repurpose os_fd field as next-free index (intrusive).
	for i := len(backing) - 1; i >= 0; i -= 1 {
		entry := &table.entries[i]
		when TINA_ASAN_POISONING {
			_sanitizer_address_unpoison_raw(rawptr(&entry.payload), size_of(entry.payload))
		}
		entry^ = FD_Entry{}
		entry.os_fd = _fd_table_encode_next(table.free_head)
		entry.generation = 1
		entry.reader_isolate = ISOLATE_HANDLE_NONE
		entry.writer_isolate = ISOLATE_HANDLE_NONE
		entry.peer_address = {}
		entry.state = .Free
		entry.attributes = {}
		when TINA_ASAN_POISONING {
			_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))
		}
		table.free_head = u16(i)
	}
}

// Allocate an FD table slot for a new OS file descriptor.
// Returns the FD_Handle with generation for stale-reference detection.
fd_table_alloc :: proc "contextless" (
	table: ^FD_Table,
	os_fd: OS_FD,
	owner: Isolate_Handle,
) -> (
	FD_Handle,
	FD_Table_Error,
) {
	if table.free_head == FD_TABLE_NONE_INDEX {
		return FD_HANDLE_NONE, .Table_Full
	}

	index := table.free_head
	entry := &table.entries[index]
	// Advance free list
	table.free_head = _fd_table_decode_next(entry.os_fd)
	table.free_count -= 1

	// Initialize the entry
	_sanitizer_address_unpoison_raw(rawptr(&entry.payload), size_of(entry.payload))
	entry.os_fd = os_fd
	entry.reader_isolate = owner
	entry.writer_isolate = owner
	entry.peer_address = {}
	entry.state = .Open
	entry.attributes = {}
	// generation already set from previous free or init

	return fd_handle_make(index, entry.generation), .None
}

// Look up an FD entry index by handle with generation check.
fd_table_lookup_index :: proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> (
	u16,
	FD_Table_Error,
) {
	if handle == FD_HANDLE_NONE {
		return FD_TABLE_NONE_INDEX, .Invalid_Index
	}

	index := fd_handle_index(handle)
	if index >= table.slot_count {
		return FD_TABLE_NONE_INDEX, .Invalid_Index
	}

	if table.entries[index].generation != fd_handle_generation(handle) {
		return FD_TABLE_NONE_INDEX, .Stale_Generation
	}
	if table.entries[index].state == .Free {
		return FD_TABLE_NONE_INDEX, .Invalid_Index
	}

	return index, .None
}

// Resolve an FD_Handle to the underlying OS_FD with generation check.
fd_table_resolve :: #force_inline proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> (
	OS_FD,
	FD_Table_Error,
) {
	index, error := fd_table_lookup_index(table, handle)
	if error != .None {
		return OS_FD_INVALID, error
	}
	return table.entries[index].os_fd, .None
}

// Validate that `owner` has the correct direction affinity for the given operation.
// recv/recvfrom/read/accept check reader_isolate; send/sendto/write/connect/close check writer_isolate.
fd_table_validate_read_affinity :: #force_inline proc "contextless" (
	entry: ^FD_Entry,
	owner: Isolate_Handle,
) -> FD_Table_Error {
	if entry.reader_isolate != owner {
		return .Affinity_Violation
	}
	return .None
}

fd_table_validate_write_affinity :: #force_inline proc "contextless" (
	entry: ^FD_Entry,
	owner: Isolate_Handle,
) -> FD_Table_Error {
	if entry.writer_isolate != owner {
		return .Affinity_Violation
	}
	return .None
}

// Transfer FD ownership according to handoff mode (§6.6.3 §5.4).
fd_table_handoff :: proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
	new_owner: Isolate_Handle,
	mode: Handoff_Mode,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Open {
		return .Invalid_Index
	}

	switch mode {
	case .Full:
		entry.reader_isolate = new_owner
		entry.writer_isolate = new_owner
	case .Read_Only:
		entry.reader_isolate = new_owner
	case .Write_Only:
		entry.writer_isolate = new_owner
	}

	return .None
}

// Free an FD table slot. Bumps generation for stale-reference detection.
// Does NOT close the OS FD — caller must handle that.
fd_table_free :: proc "contextless" (table: ^FD_Table, handle: FD_Handle) -> FD_Table_Error {
	if handle == FD_HANDLE_NONE {
		return .Invalid_Index
	}

	index := fd_handle_index(handle)
	if index >= table.slot_count {
		return .Invalid_Index
	}

	entry := &table.entries[index]
	if entry.generation != fd_handle_generation(handle) {
		return .Stale_Generation
	}
	if entry.state == .Free {
		return .Invalid_Index
	}

	// Bump generation to invalidate all outstanding FD_Handles.
	// Skip 0 on wrap: fd_handle_make(0, 0) == 0 == FD_HANDLE_NONE, so a
	// generation of 0 on slot 0 would mint a live handle indistinguishable
	// from the none sentinel.
	entry.generation += 1
	if entry.generation == 0 do entry.generation = 1
	entry.os_fd = _fd_table_encode_next(table.free_head)
	entry.reader_isolate = ISOLATE_HANDLE_NONE
	entry.writer_isolate = ISOLATE_HANDLE_NONE
	entry.peer_address = {}
	entry.state = .Free
	entry.attributes = {}
	_sanitizer_address_poison_raw(rawptr(&entry.payload), size_of(entry.payload))

	table.free_head = index
	table.free_count += 1

	return .None
}

fd_table_mark_close_after_current_io :: proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Open {
		return .Invalid_Index
	}
	entry.state = .Close_After_Current_IO
	return .None
}

fd_table_is_close_after_current_io :: #force_inline proc "contextless" (entry: ^FD_Entry) -> bool {
	return entry.state == .Close_After_Current_IO
}

fd_table_mark_close_queued :: proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Open {
		return .Invalid_Index
	}
	entry.state = .Close_Queued
	return .None
}

fd_table_restore_open_from_close_queued :: proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Close_Queued {
		return .Invalid_Index
	}
	entry.state = .Open
	return .None
}

fd_table_mark_close_in_flight :: proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Close_Queued {
		return .Invalid_Index
	}
	entry.state = .Close_In_Flight
	return .None
}

fd_table_mark_fresh_accept :: #force_inline proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
	peer_address: Peer_Address,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Open {
		return .Invalid_Index
	}
	entry.peer_address = peer_address
	entry.attributes += {.Fresh_Accept}
	return .None
}

fd_table_clear_fresh_accept :: #force_inline proc "contextless" (
	table: ^FD_Table,
	handle: FD_Handle,
) -> FD_Table_Error {
	index := fd_table_lookup_index(table, handle) or_return
	entry := &table.entries[index]
	if entry.state != .Open {
		return .Invalid_Index
	}
	entry.attributes -= {.Fresh_Accept}
	entry.peer_address = {}
	return .None
}

fd_table_is_fresh_accept :: #force_inline proc "contextless" (entry: ^FD_Entry) -> bool {
	return .Fresh_Accept in entry.attributes
}

// Find all FDs owned by a given Isolate (for teardown).
// Calls visitor for each matching FD. Visitor returns true to continue, false to stop.
fd_table_for_each_owned :: proc(
	table: ^FD_Table,
	owner: Isolate_Handle,
	visitor: proc(handle: FD_Handle, entry: ^FD_Entry) -> bool,
) {
	for i in 0 ..< table.slot_count {
		entry := &table.entries[i]
		if entry.state == .Free {
			continue
		}
		if entry.reader_isolate == owner || entry.writer_isolate == owner {
			h := fd_handle_make(i, entry.generation)
			if !visitor(h, entry) {
				return
			}
		}
	}
}

// --- Internal: intrusive free list encoding ---
// Repurpose the OS_FD field (i32 or uintptr) to store next-free u16 index.

@(private = "file")
_fd_table_encode_next :: #force_inline proc "contextless" (next: u16) -> OS_FD {
	return OS_FD(next)
}

@(private = "file")
_fd_table_decode_next :: #force_inline proc "contextless" (encoded: OS_FD) -> u16 {
	return u16(encoded)
}

// ============================================================================
// Tests
// ============================================================================

@(test)
test_fd_table_init :: proc(t: ^testing.T) {
	backing: [8]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	testing.expect_value(t, table.slot_count, 8)
	testing.expect_value(t, table.free_count, 8)
	testing.expect(t, table.free_head != FD_TABLE_NONE_INDEX, "free list should not be empty")
}

@(test)
test_fd_table_alloc_and_lookup :: proc(t: ^testing.T) {
	backing: [4]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	handle, error := fd_table_alloc(&table, OS_FD(42), make_handle(0, 1, 0, 0))
	testing.expect_value(t, error, FD_Table_Error.None)
	testing.expect(t, handle != FD_HANDLE_NONE, "should get a valid handle")
	testing.expect_value(t, table.free_count, 3)

	entry_index, lookup_error := fd_table_lookup_index(&table, handle)
	testing.expect_value(t, lookup_error, FD_Table_Error.None)
	entry := &table.entries[entry_index]
	testing.expect_value(t, entry.os_fd, OS_FD(42))
}

@(test)
test_fd_table_generation_check :: proc(t: ^testing.T) {
	backing: [4]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)
	handle, _ := fd_table_alloc(&table, OS_FD(10), owner)

	// Free the slot — generation bumps
	free_error := fd_table_free(&table, handle)
	testing.expect_value(t, free_error, FD_Table_Error.None)

	// Old handle is now stale
	_, stale_error := fd_table_lookup_index(&table, handle)
	testing.expect_value(t, stale_error, FD_Table_Error.Stale_Generation)
}

@(test)
test_fd_table_full :: proc(t: ^testing.T) {
	backing: [2]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)
	fd_table_alloc(&table, OS_FD(1), owner)
	fd_table_alloc(&table, OS_FD(2), owner)

	_, error := fd_table_alloc(&table, OS_FD(3), owner)
	testing.expect_value(t, error, FD_Table_Error.Table_Full)
}

@(test)
test_fd_table_direction_affinity :: proc(t: ^testing.T) {
	backing: [4]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	reader := make_handle(0, 1, 0, 0)
	writer := make_handle(0, 1, 1, 0)
	other := make_handle(0, 1, 2, 0)

	// Allocate with full ownership to reader, then split
	handle, _ := fd_table_alloc(&table, OS_FD(99), reader)
	entry_index, _ := fd_table_lookup_index(&table, handle)

	// Transfer write direction to writer
	fd_table_handoff(&table, handle, writer, .Write_Only)
	entry := &table.entries[entry_index]

	// Reader owns read direction
	testing.expect_value(t, fd_table_validate_read_affinity(entry, reader), FD_Table_Error.None)
	testing.expect_value(
		t,
		fd_table_validate_read_affinity(entry, other),
		FD_Table_Error.Affinity_Violation,
	)

	// Writer owns write direction
	testing.expect_value(t, fd_table_validate_write_affinity(entry, writer), FD_Table_Error.None)
	testing.expect_value(
		t,
		fd_table_validate_write_affinity(entry, other),
		FD_Table_Error.Affinity_Violation,
	)
}

@(test)
test_fd_table_close_after_current_io :: proc(t: ^testing.T) {
	backing: [4]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)
	handle, _ := fd_table_alloc(&table, OS_FD(5), owner)

	entry_index, _ := fd_table_lookup_index(&table, handle)
	entry := &table.entries[entry_index]
	testing.expect(t, !fd_table_is_close_after_current_io(entry), "should not be marked initially")

	mark_error := fd_table_mark_close_after_current_io(&table, handle)
	testing.expect_value(t, mark_error, FD_Table_Error.None)
	testing.expect(t, fd_table_is_close_after_current_io(entry), "should be marked after set")
}

@(test)
test_fd_table_close_submission_state_machine :: proc(t: ^testing.T) {
	backing: [1]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)
	handle, allocate_error := fd_table_alloc(&table, OS_FD(5), owner)
	testing.expect_value(t, allocate_error, FD_Table_Error.None)
	entry := &backing[0]

	queue_error := fd_table_mark_close_queued(&table, handle)
	testing.expect_value(t, queue_error, FD_Table_Error.None)
	testing.expect_value(t, entry.state, FD_Entry_State.Close_Queued)

	restore_error := fd_table_restore_open_from_close_queued(&table, handle)
	testing.expect_value(t, restore_error, FD_Table_Error.None)
	testing.expect_value(t, entry.state, FD_Entry_State.Open)

	queue_error = fd_table_mark_close_queued(&table, handle)
	testing.expect_value(t, queue_error, FD_Table_Error.None)
	in_flight_error := fd_table_mark_close_in_flight(&table, handle)
	testing.expect_value(t, in_flight_error, FD_Table_Error.None)
	testing.expect_value(t, entry.state, FD_Entry_State.Close_In_Flight)
}

@(test)
test_fd_table_reuse_after_free :: proc(t: ^testing.T) {
	backing: [2]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)

	// Allocate both slots
	h1, _ := fd_table_alloc(&table, OS_FD(10), owner)
	_, _ = fd_table_alloc(&table, OS_FD(20), owner)
	testing.expect_value(t, table.free_count, 0)

	// Free h1
	fd_table_free(&table, h1)
	testing.expect_value(t, table.free_count, 1)

	// Re-allocate — should reuse h1's slot (LIFO) with bumped generation
	h3, error := fd_table_alloc(&table, OS_FD(30), owner)
	testing.expect_value(t, error, FD_Table_Error.None)
	testing.expect_value(t, fd_handle_index(h3), fd_handle_index(h1))
	testing.expect(
		t,
		fd_handle_generation(h3) > fd_handle_generation(h1),
		"generation should have bumped",
	)
}
