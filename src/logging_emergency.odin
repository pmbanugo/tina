package tina

import "core:mem"

// ============================================================================
// Emergency Log Flush — Cross-Platform Walk
// ============================================================================
// Async-signal-safe ring drain. Only the final byte sink (_write_stderr) is
// platform-specific; everything else lives here so POSIX and Windows cannot
// drift apart and so the on-ring layout is read through Log_Record_Header
// (the single source of truth) instead of hand-coded byte offsets.
//
// Constraints (must hold for every code path reachable from a signal handler):
//   - No fmt, no allocator, no runtime context, no panicking helpers.
//   - Header is staged on the stack and copied byte-by-byte from the ring via
//     _ring_copy_raw — never aliased directly because the ring may wrap and
//     the byte address may be unaligned.
//   - The write_cursor snapshot is captured once per flush so a moving writer
//     cannot extend the walk mid-iteration.

@(private = "package")
_ring_copy_raw :: proc "contextless" (ring: ^Log_Ring_Buffer, offset: u64, target: []u8) {
	for i in 0 ..< len(target) {
		index := (offset + u64(i)) & ring.capacity_mask
		target[i] = ring.buffer[index]
	}
}

// Walks the ring from `cursor` up to `limit`, emitting one [EMERGENCY] line per
// record via _write_stderr, and returns the cursor position after the last
// fully-emitted record. Caller decides whether to commit it back to
// ring.read_cursor (signal path) or discard it (snapshot path).
@(private = "package")
_emergency_log_flush_walk :: proc "contextless" (
	ring: ^Log_Ring_Buffer,
	cursor_start: u64,
	limit: u64,
) -> u64 {
	cursor := cursor_start
	capacity := ring.capacity_mask + 1

	for limit - cursor >= Log_Record_Header_Size {
		header: Log_Record_Header
		_ring_copy_raw(
			ring,
			cursor,
			mem.byte_slice(cast(^u8)&header, Log_Record_Header_Size),
		)

		if header.payload_size > u16(MAX_PAYLOAD_SIZE) do break

		record_size := log_record_size_from_payload_size(header.payload_size)
		if record_size > capacity do break
		if limit - cursor < record_size do break

		line_buffer: [4096]u8
		position := 0
		position = _sig_append_str(line_buffer[:], position, "[EMERGENCY] Handle: ")
		position = _sig_append_u64(line_buffer[:], position, u64(header.isolate_handle))
		position = _sig_append_str(line_buffer[:], position, " Tag: ")
		position = _sig_append_u64(line_buffer[:], position, u64(header.tag))
		position = _sig_append_str(line_buffer[:], position, " - ")

		payload_count := int(header.payload_size)
		if payload_count > 0 {
			payload_buffer: [MAX_PAYLOAD_SIZE]u8
			_ring_copy_raw(
				ring,
				cursor + Log_Record_Header_Size,
				payload_buffer[:payload_count],
			)
			// Reserve one byte for the trailing newline.
			if position + payload_count + 1 > len(line_buffer) {
				payload_count = len(line_buffer) - position - 1
			}
			for i in 0 ..< payload_count {
				line_buffer[position + i] = payload_buffer[i]
			}
			position += payload_count
		}
		line_buffer[position] = '\n'
		position += 1

		_write_stderr(line_buffer[:position])

		cursor += record_size
	}

	return cursor
}

// Signal-safe emergency flush: drains the shard's own log ring.
// Called from fatal_signal_handler on the shard's own thread.
// Destructively advances read_cursor to the last fully-emitted record.
@(private = "package")
emergency_log_flush_signal :: proc "contextless" (shard: ^Shard) {
	ring := &shard.log_ring
	ring.read_cursor = _emergency_log_flush_walk(ring, ring.read_cursor, ring.write_cursor)
}

// Phase 3 snapshot flush: reads another shard's log ring WITHOUT mutating
// read_cursor. Called from the watchdog thread during force-kill.
// Accepts data races per ADR §5.3.
emergency_log_flush_snapshot :: proc "contextless" (shard: ^Shard) {
	ring := &shard.log_ring
	_ = _emergency_log_flush_walk(ring, ring.read_cursor, ring.write_cursor)
}
