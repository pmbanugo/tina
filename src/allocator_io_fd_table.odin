package tina

import "core:testing"

// ============================================================================
// FD Table — Shard-Owned File Descriptor Registry (§6.6.1 §3, §6.6.3 §6)
// ============================================================================
//
// Fixed-size table mapping FD_Handle (generational index) to OS file descriptors.
// Direction-partitioned ownership: each entry tracks read_owner and write_owner
// separately, enabling full-duplex split affinity (§6.6.3 §17).
//
// Managed via an intrusive LIFO free list with u16 indices.
// Ginger Bill pool pattern — same as message pool and reactor buffer pool.

FD_TABLE_NONE_INDEX :: u16(0xFFFF)

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
	table.entries = backing
	table.slot_count = u16(len(backing))
	table.free_count = table.slot_count
	table.free_head = FD_TABLE_NONE_INDEX

	// Build LIFO free list: slot 0 at head for initial cache locality.
	// Repurpose os_fd field as next-free index (intrusive).
	for i := len(backing) - 1; i >= 0; i -= 1 {
		entry := &table.entries[i]
		entry^ = FD_Entry{}
		entry.os_fd = _fd_table_encode_next(table.free_head)
		entry.generation = 0
		entry.read_owner = HANDLE_NONE
		entry.write_owner = HANDLE_NONE
		entry.flags = {}
		table.free_head = u16(i)
	}
}

// Allocate an FD table slot for a new OS file descriptor.
// Returns the FD_Handle with generation for stale-reference detection.
fd_table_alloc :: proc(table: ^FD_Table, os_fd: OS_FD, owner: Handle) -> (FD_Handle, FD_Table_Error) {
	if table.free_head == FD_TABLE_NONE_INDEX {
		return FD_HANDLE_NONE, .Table_Full
	}

	index := table.free_head
	entry := &table.entries[index]

	// Advance free list
	table.free_head = _fd_table_decode_next(entry.os_fd)
	table.free_count -= 1

	// Initialize the entry
	entry.os_fd = os_fd
	entry.read_owner = owner
	entry.write_owner = owner
	entry.flags = {}
	// generation already set from previous free or init

	return fd_handle_make(index, entry.generation), .None
}

// Look up an FD entry by handle with generation check.
// Returns nil and error if the handle is stale or invalid.
fd_table_lookup :: proc(table: ^FD_Table, handle: FD_Handle) -> (^FD_Entry, FD_Table_Error) {
	if handle == FD_HANDLE_NONE {
		return nil, .Invalid_Index
	}

	index := fd_handle_index(handle)
	if index >= table.slot_count {
		return nil, .Invalid_Index
	}

	entry := &table.entries[index]
	if entry.generation != fd_handle_generation(handle) {
		return nil, .Stale_Generation
	}

	return entry, .None
}

// Resolve an FD_Handle to the underlying OS_FD with generation check.
fd_table_resolve :: #force_inline proc(table: ^FD_Table, handle: FD_Handle) -> (OS_FD, FD_Table_Error) {
	entry, err := fd_table_lookup(table, handle)
	if err != .None {
		return OS_FD_INVALID, err
	}
	return entry.os_fd, .None
}

// Validate that `owner` has the correct direction affinity for the given operation.
// recv/recvfrom/read/accept check read_owner; send/sendto/write/connect/close check write_owner.
fd_table_validate_read_affinity :: #force_inline proc(entry: ^FD_Entry, owner: Handle) -> FD_Table_Error {
	if entry.read_owner != owner {
		return .Affinity_Violation
	}
	return .None
}

fd_table_validate_write_affinity :: #force_inline proc(entry: ^FD_Entry, owner: Handle) -> FD_Table_Error {
	if entry.write_owner != owner {
		return .Affinity_Violation
	}
	return .None
}

// Transfer FD ownership according to handoff mode (§6.6.3 §5.4).
fd_table_handoff :: proc(table: ^FD_Table, handle: FD_Handle, new_owner: Handle, mode: Handoff_Mode) -> FD_Table_Error {
	entry, err := fd_table_lookup(table, handle)
	if err != .None {
		return err
	}

	switch mode {
	case .Full:
		entry.read_owner = new_owner
		entry.write_owner = new_owner
	case .Read_Only:
		entry.read_owner = new_owner
	case .Write_Only:
		entry.write_owner = new_owner
	}

	return .None
}

// Free an FD table slot. Bumps generation for stale-reference detection.
// Does NOT close the OS FD — caller must handle that.
fd_table_free :: proc(table: ^FD_Table, handle: FD_Handle) -> FD_Table_Error {
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

	// Bump generation to invalidate all outstanding FD_Handles
	entry.generation += 1
	entry.os_fd = _fd_table_encode_next(table.free_head)
	entry.read_owner = HANDLE_NONE
	entry.write_owner = HANDLE_NONE
	entry.flags = {}

	table.free_head = index
	table.free_count += 1

	return .None
}

// Mark an FD for close-on-completion (§6.6.1 §3).
// Used during teardown_isolate when I/O is in-flight on the FD.
fd_table_mark_close_on_completion :: proc(table: ^FD_Table, handle: FD_Handle) -> FD_Table_Error {
	entry, err := fd_table_lookup(table, handle)
	if err != .None {
		return err
	}
	entry.flags += {.Close_On_Completion}
	return .None
}

// Check if an FD is marked for close-on-completion.
fd_table_is_close_on_completion :: #force_inline proc(entry: ^FD_Entry) -> bool {
	return .Close_On_Completion in entry.flags
}

// Find all FDs owned by a given Isolate (for teardown).
// Calls visitor for each matching FD. Visitor returns true to continue, false to stop.
fd_table_for_each_owned :: proc(table: ^FD_Table, owner: Handle, visitor: proc(handle: FD_Handle, entry: ^FD_Entry) -> bool) {
	for i in 0..<table.slot_count {
		entry := &table.entries[i]
		if entry.read_owner == owner || entry.write_owner == owner {
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
_fd_table_encode_next :: #force_inline proc(next: u16) -> OS_FD {
	return OS_FD(next)
}

@(private = "file")
_fd_table_decode_next :: #force_inline proc(encoded: OS_FD) -> u16 {
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

	handle, err := fd_table_alloc(&table, OS_FD(42), make_handle(0, 1, 0, 0))
	testing.expect_value(t, err, FD_Table_Error.None)
	testing.expect(t, handle != FD_HANDLE_NONE, "should get a valid handle")
	testing.expect_value(t, table.free_count, 3)

	entry, lookup_err := fd_table_lookup(&table, handle)
	testing.expect_value(t, lookup_err, FD_Table_Error.None)
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
	free_err := fd_table_free(&table, handle)
	testing.expect_value(t, free_err, FD_Table_Error.None)

	// Old handle is now stale
	_, stale_err := fd_table_lookup(&table, handle)
	testing.expect_value(t, stale_err, FD_Table_Error.Stale_Generation)
}

@(test)
test_fd_table_full :: proc(t: ^testing.T) {
	backing: [2]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)
	fd_table_alloc(&table, OS_FD(1), owner)
	fd_table_alloc(&table, OS_FD(2), owner)

	_, err := fd_table_alloc(&table, OS_FD(3), owner)
	testing.expect_value(t, err, FD_Table_Error.Table_Full)
}

@(test)
test_fd_table_direction_affinity :: proc(t: ^testing.T) {
	backing: [4]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	reader := make_handle(0, 1, 0, 0)
	writer := make_handle(0, 1, 1, 0)
	other  := make_handle(0, 1, 2, 0)

	// Allocate with full ownership to reader, then split
	handle, _ := fd_table_alloc(&table, OS_FD(99), reader)
	entry, _ := fd_table_lookup(&table, handle)

	// Transfer write direction to writer
	fd_table_handoff(&table, handle, writer, .Write_Only)

	// Reader owns read direction
	testing.expect_value(t, fd_table_validate_read_affinity(entry, reader), FD_Table_Error.None)
	testing.expect_value(t, fd_table_validate_read_affinity(entry, other), FD_Table_Error.Affinity_Violation)

	// Writer owns write direction
	testing.expect_value(t, fd_table_validate_write_affinity(entry, writer), FD_Table_Error.None)
	testing.expect_value(t, fd_table_validate_write_affinity(entry, other), FD_Table_Error.Affinity_Violation)
}

@(test)
test_fd_table_close_on_completion :: proc(t: ^testing.T) {
	backing: [4]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)
	handle, _ := fd_table_alloc(&table, OS_FD(5), owner)

	entry, _ := fd_table_lookup(&table, handle)
	testing.expect(t, !fd_table_is_close_on_completion(entry), "should not be marked initially")

	fd_table_mark_close_on_completion(&table, handle)
	testing.expect(t, fd_table_is_close_on_completion(entry), "should be marked after set")
}

@(test)
test_fd_table_reuse_after_free :: proc(t: ^testing.T) {
	backing: [2]FD_Entry
	table: FD_Table
	fd_table_init(&table, backing[:])

	owner := make_handle(0, 1, 0, 0)

	// Allocate both slots
	h1, _ := fd_table_alloc(&table, OS_FD(10), owner)
	h2, _ := fd_table_alloc(&table, OS_FD(20), owner)
	testing.expect_value(t, table.free_count, 0)

	// Free h1
	fd_table_free(&table, h1)
	testing.expect_value(t, table.free_count, 1)

	// Re-allocate — should reuse h1's slot (LIFO) with bumped generation
	h3, err := fd_table_alloc(&table, OS_FD(30), owner)
	testing.expect_value(t, err, FD_Table_Error.None)
	testing.expect_value(t, fd_handle_index(h3), fd_handle_index(h1))
	testing.expect(t, fd_handle_generation(h3) > fd_handle_generation(h1), "generation should have bumped")
}
