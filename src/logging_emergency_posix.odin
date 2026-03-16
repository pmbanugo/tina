#+build linux, darwin, freebsd, openbsd, netbsd

package tina

import "core:sys/posix"

// ============================================================================
// Emergency Log Flush — Async-Signal-Safe (§6.4, PROCESS_LIFECYCLE_SIGNALS.md)
// ============================================================================
// These functions use ONLY posix.write (async-signal-safe) and manual byte
// manipulation. No fmt, no allocator, no runtime context.

STDERR_FD :: posix.FD(2)

@(private = "package")
_write_stderr :: proc "contextless" (data: []u8) {
	if len(data) == 0 do return
	posix.write(STDERR_FD, raw_data(data), uint(len(data)))
}

@(private = "package")
_ring_copy_raw :: proc "contextless" (ring: ^Log_Ring_Buffer, offset: u64, target: []u8) {
	for i in 0 ..< len(target) {
		index := (offset + u64(i)) & ring.capacity_mask
		target[i] = ring.buffer[index]
	}
}

// Reconstructs a u16 from two raw bytes in little-endian order (e.g. from a ring buffer header).
@(private = "package")
_u16_from_le_bytes :: proc "contextless" (b0, b1: u8) -> u16 {
	return u16(b0) | (u16(b1) << 8)
}

// Signal-safe emergency flush: drains the shard's own log ring using only write(2).
// Called from fatal_signal_handler on the shard's own thread. Destructively advances read_cursor.
@(private = "package")
emergency_log_flush_signal :: proc "contextless" (shard: ^Shard) {
	ring := &shard.log_ring
	cursor := ring.read_cursor
	limit := ring.write_cursor
	header_size := u64(Log_Record_Header_Size)

	for limit - cursor >= header_size {
		header_bytes: [24]u8
		_ring_copy_raw(ring, cursor, header_bytes[:])

		// payload_size is at offset 16 in Log_Record_Header (after timestamp u64 + handle u64)
		payload_size := _u16_from_le_bytes(header_bytes[16], header_bytes[17])
		if payload_size > u16(MAX_PAYLOAD_SIZE) do break

		record_size := header_size + u64((payload_size + 7) & ~u16(7))
		if record_size > (ring.capacity_mask + 1) do break
		if limit - cursor < record_size do break

		// Write payload bytes to stderr in chunks
		payload_remaining := int(payload_size)
		payload_offset := cursor + header_size
		for payload_remaining > 0 {
			chunk: [256]u8
			n := min(payload_remaining, len(chunk))
			_ring_copy_raw(ring, payload_offset, chunk[:n])
			_write_stderr(chunk[:n])
			payload_offset += u64(n)
			payload_remaining -= n
		}
		_write_stderr({'\n'})

		cursor += record_size
	}

	ring.read_cursor = cursor
}

// Phase 3 snapshot flush: reads another shard's log ring WITHOUT mutating read_cursor.
// Called from the watchdog thread during force-kill. Accepts data races per ADR §5.3.
emergency_log_flush_snapshot :: proc "contextless" (shard: ^Shard) {
	ring := &shard.log_ring
	cursor := ring.read_cursor
	limit := ring.write_cursor
	header_size := u64(Log_Record_Header_Size)

	for limit - cursor >= header_size {
		header_bytes: [24]u8
		_ring_copy_raw(ring, cursor, header_bytes[:])

		payload_size := _u16_from_le_bytes(header_bytes[16], header_bytes[17])
		if payload_size > MAX_PAYLOAD_SIZE do break

		record_size := header_size + u64((payload_size + 7) & ~u16(7))
		if record_size > (ring.capacity_mask + 1) do break
		if limit - cursor < record_size do break

		payload_remaining := int(payload_size)
		payload_offset := cursor + header_size
		for payload_remaining > 0 {
			chunk: [256]u8
			n := min(payload_remaining, len(chunk))
			_ring_copy_raw(ring, payload_offset, chunk[:n])
			_write_stderr(chunk[:n])
			payload_offset += u64(n)
			payload_remaining -= n
		}
		_write_stderr({'\n'})

		cursor += record_size
	}
	// NOTE: Does NOT update ring.read_cursor — non-destructive snapshot.
}
