package tina

import "core:testing"

FD_Handoff_Table_Error :: enum u8 {
	None,
	Table_Full,
	Invalid_Index,
	Stale_Generation,
	Invalid_State,
}

fd_handoff_table_init :: proc(table: ^FD_Handoff_Table, backing: []FD_Handoff_Entry) {
	assert(
		len(backing) <= FD_HANDOFF_ENTRY_COUNT_MAX,
		"FD handoff entry count exceeds index capacity",
	)
	table.entries = backing
	table.entry_count = u16(len(backing))
	table.free_count = table.entry_count
	table.free_head = FD_HANDOFF_NONE_INDEX

	for i := len(backing) - 1; i >= 0; i -= 1 {
		entry := &table.entries[i]
		entry^ = FD_Handoff_Entry{}
		entry.generation = 1
		entry.state = .Free
		entry.next_free_index = table.free_head
		table.free_head = u16(i)
	}
}

@(private = "package")
fd_handoff_table_alloc :: proc "contextless" (
	table: ^FD_Handoff_Table,
	target_handle: Isolate_Handle,
	cleanup_fd: OS_FD,
	peer_address: Peer_Address,
	deadline_tick: u64,
	source_shard: Shard_Id,
) -> (
	FD_Handoff_Ref,
	FD_Handoff_Table_Error,
) {
	if table.free_head == FD_HANDOFF_NONE_INDEX {
		return FD_HANDOFF_REF_NONE, .Table_Full
	}

	index := table.free_head
	entry := &table.entries[index]
	table.free_head = entry.next_free_index
	table.free_count -= 1

	entry.target_handle = target_handle
	entry.peer_address = peer_address
	entry.deadline_tick = deadline_tick
	entry.cleanup_fd = cleanup_fd
	entry.state = .In_Flight
	entry.next_free_index = FD_HANDOFF_NONE_INDEX

	return fd_handoff_ref_make(index, entry.generation, source_shard), .None
}

@(private = "package")
fd_handoff_table_lookup_index :: proc "contextless" (
	table: ^FD_Handoff_Table,
	ref: FD_Handoff_Ref,
) -> (
	u16,
	FD_Handoff_Table_Error,
) {
	if ref.handoff_index == FD_HANDOFF_NONE_INDEX || ref.handoff_index >= table.entry_count {
		return FD_HANDOFF_NONE_INDEX, .Invalid_Index
	}

	entry := &table.entries[ref.handoff_index]
	if entry.generation != ref.generation {
		return FD_HANDOFF_NONE_INDEX, .Stale_Generation
	}
	if entry.state != .In_Flight {
		return FD_HANDOFF_NONE_INDEX, .Invalid_State
	}

	return ref.handoff_index, .None
}

@(private = "package")
fd_handoff_table_free :: proc "contextless" (
	table: ^FD_Handoff_Table,
	ref: FD_Handoff_Ref,
) -> FD_Handoff_Table_Error {
	if ref.handoff_index == FD_HANDOFF_NONE_INDEX || ref.handoff_index >= table.entry_count {
		return .Invalid_Index
	}

	entry := &table.entries[ref.handoff_index]
	if entry.generation != ref.generation {
		return .Stale_Generation
	}
	if entry.state != .In_Flight {
		return .Invalid_State
	}

	entry.generation += 1
	if entry.generation == 0 do entry.generation = 1
	entry^ = FD_Handoff_Entry {
		generation = entry.generation,
		state = .Free,
		next_free_index = table.free_head,
	}

	table.free_head = ref.handoff_index
	table.free_count += 1
	return .None
}

@(test)
test_fd_handoff_table_alloc_free :: proc(t: ^testing.T) {
	backing: [2]FD_Handoff_Entry
	table: FD_Handoff_Table
	fd_handoff_table_init(&table, backing[:])

	ref, alloc_error := fd_handoff_table_alloc(
		&table,
		make_handle(1, 2, 3, 4),
		OS_FD(10),
		Peer_Address{},
		42,
		0,
	)
	testing.expect_value(t, alloc_error, FD_Handoff_Table_Error.None)
	testing.expect_value(t, table.free_count, u16(1))

	entry_index, lookup_error := fd_handoff_table_lookup_index(&table, ref)
	testing.expect_value(t, lookup_error, FD_Handoff_Table_Error.None)
	entry := &table.entries[entry_index]
	testing.expect_value(t, entry.cleanup_fd, OS_FD(10))

	free_error := fd_handoff_table_free(&table, ref)
	testing.expect_value(t, free_error, FD_Handoff_Table_Error.None)
	testing.expect_value(t, table.free_count, u16(2))

	_, lookup_error = fd_handoff_table_lookup_index(&table, ref)
	testing.expect_value(t, lookup_error, FD_Handoff_Table_Error.Stale_Generation)
}
