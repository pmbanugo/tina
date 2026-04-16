package tina

import "core:testing"

fd_handoff_table_init :: proc(table: ^FD_Handoff_Table, backing: []FD_Handoff_Entry) {
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
	target_handle: Handle,
	cleanup_fd: OS_FD,
	peer_address: Peer_Address,
	deadline_tick: u64,
	source_shard: u8,
) -> (
	FD_Handoff_Ref,
	bool,
) {
	if table.free_head == FD_HANDOFF_NONE_INDEX {
		return FD_HANDOFF_REF_NONE, false
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

	return fd_handoff_ref_make(index, entry.generation, source_shard), true
}

@(private = "package")
fd_handoff_table_lookup :: proc "contextless" (
	table: ^FD_Handoff_Table,
	ref: FD_Handoff_Ref,
) -> (
	^FD_Handoff_Entry,
	bool,
) {
	if ref.handoff_index == FD_HANDOFF_NONE_INDEX || ref.handoff_index >= table.entry_count {
		return nil, false
	}

	entry := &table.entries[ref.handoff_index]
	if entry.generation != ref.generation || entry.state != .In_Flight {
		return nil, false
	}

	return entry, true
}

@(private = "package")
fd_handoff_table_free :: proc "contextless" (table: ^FD_Handoff_Table, ref: FD_Handoff_Ref) -> bool {
	if ref.handoff_index == FD_HANDOFF_NONE_INDEX || ref.handoff_index >= table.entry_count {
		return false
	}

	entry := &table.entries[ref.handoff_index]
	if entry.generation != ref.generation || entry.state != .In_Flight {
		return false
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
	return true
}

@(test)
test_fd_handoff_table_alloc_free :: proc(t: ^testing.T) {
	backing: [2]FD_Handoff_Entry
	table: FD_Handoff_Table
	fd_handoff_table_init(&table, backing[:])

	ref, ok := fd_handoff_table_alloc(
		&table,
		make_handle(1, 2, 3, 4),
		OS_FD(10),
		Peer_Address{},
		42,
		0,
	)
	testing.expect(t, ok, "first handoff alloc should succeed")
	testing.expect_value(t, table.free_count, u16(1))

	entry, found := fd_handoff_table_lookup(&table, ref)
	testing.expect(t, found, "handoff entry should be found")
	testing.expect_value(t, entry.cleanup_fd, OS_FD(10))

	freed := fd_handoff_table_free(&table, ref)
	testing.expect(t, freed, "handoff entry should free successfully")
	testing.expect_value(t, table.free_count, u16(2))

	_, found = fd_handoff_table_lookup(&table, ref)
	testing.expect(t, !found, "stale handoff ref should not resolve after free")
}
