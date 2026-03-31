package tina

import "core:mem"
import "core:os"

Log_Level :: enum u8 {
	ERROR = 0,
	WARN  = 1,
	INFO  = 2,
	DEBUG = 3,
}

Log_Tag :: distinct u8

LOG_TAG_ISOLATE_CRASHED: Log_Tag : 0x01
LOG_TAG_ISOLATE_TRAPPED: Log_Tag : 0x02
LOG_TAG_SUPERVISION: Log_Tag : 0x03
LOG_TAG_SHARD_RESTARTED: Log_Tag : 0x06
LOG_TAG_IO_EXHAUSTION: Log_Tag : 0x08
// Application log tags can start from here (0x40 - 0xFF)
USER_LOG_TAG_BASE: Log_Tag : 0x40

POSIX_PIPE_BUF_SIZE :: 4096 // Guaranteed atomic write size on POSIX
MAX_FORMATTED_LOG_LINE :: 512 // Max size for the formatted log line output

Log_Record_Header :: struct {
	timestamp:      u64,
	isolate_handle: Handle,
	payload_size:   u16,
	_reserved_0:    u16,
	level:          Log_Level,
	tag:            Log_Tag,
	_reserved_1:    u16,
}

Log_Record_Header_Size :: u64(size_of(Log_Record_Header))

Log_Ring_Buffer :: struct {
	buffer:        []u8,
	capacity_mask: u64, // Mask instead of capacity for fast bitwise wrapping
	read_cursor:   u64,
	write_cursor:  u64,
}

log_init :: proc(ring: ^Log_Ring_Buffer, backing: []u8) {
	capacity := u64(len(backing))
	assert(
		capacity > 0 && (capacity & (capacity - 1)) == 0,
		"Log ring buffer capacity must be a power of 2",
	)

	ring.buffer = backing
	ring.capacity_mask = capacity - 1
	ring.read_cursor = 0
	ring.write_cursor = 0
}

// Writes a diagnostic log to the Shard's environment.
// The message is raw-byte
ctx_log_raw :: #force_inline proc "contextless" (
	ctx: ^TinaContext,
	level: Log_Level,
	$tag: Log_Tag,
	payload: []u8,
) {
	#assert(
		tag >= USER_LOG_TAG_BASE,
		"[Tina] User code cannot log with system tags. Tag must be >= 0x40.",
	)
	_shard_log(_ctx_extract_shard(ctx), ctx.self_handle, level, tag, payload)
}

// Writes a diagnostic log to the Shard's environment.
// The message is typed
ctx_log_typed :: #force_inline proc "contextless" (
	ctx: ^TinaContext,
	level: Log_Level,
	$tag: Log_Tag,
	message: ^$T,
) where size_of(T) <=
	MAX_PAYLOAD_SIZE {
	#assert(
		tag >= USER_LOG_TAG_BASE,
		"[Tina] User code cannot log with system tags. Tag must be >= 0x40.",
	)
	_shard_log(
		_ctx_extract_shard(ctx),
		ctx.self_handle,
		level,
		tag,
		mem.byte_slice(message, size_of(T)),
	)
}

ctx_log :: proc {
	ctx_log_raw,
	ctx_log_typed,
}

// The internal logging primitive
@(private = "package")
_shard_log :: #force_inline proc "contextless" (
	shard: ^Shard,
	source: Handle,
	level: Log_Level,
	tag: Log_Tag,
	payload: []u8,
) {
	timestamp := shard.current_tick
	clamped_size := min(len(payload), MAX_PAYLOAD_SIZE)
	record_size := Log_Record_Header_Size + u64(((clamped_size + 7) & ~int(7)))

	capacity := shard.log_ring.capacity_mask + 1
	if shard.log_ring.write_cursor + record_size - shard.log_ring.read_cursor > capacity {
		return
	}

	header := Log_Record_Header {
		timestamp      = timestamp,
		isolate_handle = source,
		payload_size   = u16(clamped_size),
		level          = level,
		tag            = tag,
	}

	_write_ring_data(
		&shard.log_ring,
		shard.log_ring.write_cursor,
		mem.byte_slice(cast(^u8)&header, 24),
	)
	if len(payload) > 0 {
		_write_ring_data(&shard.log_ring, shard.log_ring.write_cursor + 24, payload[:clamped_size])
	}
	shard.log_ring.write_cursor += record_size
}

// 2-part ring buffer block copy (SIMD-friendly)
@(private = "package")
_write_ring_data :: #force_inline proc "contextless" (
	ring: ^Log_Ring_Buffer,
	offset: u64,
	data: []u8,
) {
	size := u64(len(data))
	if size == 0 do return

	start := offset & ring.capacity_mask
	capacity := ring.capacity_mask + 1

	if start + size <= capacity {
		// Fits perfectly without wrapping
		mem.copy(&ring.buffer[start], raw_data(data), int(size))
	} else {
		// Wraps the buffer edge: perform two distinct copies
		first_chunk := capacity - start
		mem.copy(&ring.buffer[start], raw_data(data), int(first_chunk))

		src_offset := rawptr(uintptr(raw_data(data)) + uintptr(first_chunk))
		mem.copy(&ring.buffer[0], src_offset, int(size - first_chunk))
	}
}

// 2-part ring buffer block read (SIMD-friendly)
@(private = "package")
_read_ring_data :: #force_inline proc "contextless" (
	ring: ^Log_Ring_Buffer,
	offset: u64,
	data: []u8,
) {
	size := u64(len(data))
	if size == 0 do return

	start := offset & ring.capacity_mask
	capacity := ring.capacity_mask + 1

	if start + size <= capacity {
		// Fits perfectly without wrapping
		mem.copy(raw_data(data), &ring.buffer[start], int(size))
	} else {
		// Wraps the buffer edge: perform two distinct copies
		first_chunk := capacity - start
		mem.copy(raw_data(data), &ring.buffer[start], int(first_chunk))

		dst_offset := rawptr(uintptr(raw_data(data)) + uintptr(first_chunk))
		mem.copy(dst_offset, &ring.buffer[0], int(size - first_chunk))
	}
}

@(private = "package")
log_level_label :: #force_inline proc "contextless" (level: Log_Level) -> string {
	@(static, rodata)
	labels := [4]string{"ERROR", "WARN", "INFO", "DEBUG"}
	if u8(level) < 4 do return labels[u8(level)]
	return "UNKNOWN"
}

// Step 7: Flush logs to OS stream via PIPE_BUF chunks
log_flush :: proc(shard: ^Shard) {
	temp_buffer: [POSIX_PIPE_BUF_SIZE]u8
	temp_size := 0
	ring := &shard.log_ring
	commit_cursor := ring.read_cursor

	for commit_cursor < ring.write_cursor {
		if ring.write_cursor - commit_cursor < Log_Record_Header_Size {break}

		header: Log_Record_Header
		_read_ring_data(
			ring,
			commit_cursor,
			mem.byte_slice(cast(^u8)&header, Log_Record_Header_Size),
		)
		record_size := Log_Record_Header_Size + u64((header.payload_size + 7) & ~u16(7))

		if ring.write_cursor - commit_cursor < record_size {break}

		payload_buf: [MAX_PAYLOAD_SIZE]u8
		_read_ring_data(
			ring,
			commit_cursor + Log_Record_Header_Size,
			payload_buf[:header.payload_size],
		)

		line_buffer: [MAX_FORMATTED_LOG_LINE]u8
		position := 0
		position = _sig_append_str(line_buffer[:], position, "[")
		position = _sig_append_u64(line_buffer[:], position, header.timestamp)
		position = _sig_append_str(line_buffer[:], position, "] ")
		position = _sig_append_str(line_buffer[:], position, log_level_label(header.level))
		position = _sig_append_str(line_buffer[:], position, "[Tag:")
		position = _sig_append_hex(line_buffer[:], position, u64(header.tag))
		position = _sig_append_str(line_buffer[:], position, "] Handle:")
		position = _sig_append_hex(line_buffer[:], position, u64(header.isolate_handle))
		position = _sig_append_str(line_buffer[:], position, " - ")
		payload_size := min(int(header.payload_size), len(line_buffer) - position - 1)
		for i in 0 ..< payload_size {
			line_buffer[position + i] = payload_buf[i]
		}
		position += payload_size
		line_buffer[position] = '\n'
		position += 1
		line_bytes := line_buffer[:position]

		if temp_size + len(line_bytes) > POSIX_PIPE_BUF_SIZE {
			written_size, write_error := os.write(os.stderr, temp_buffer[:temp_size])
			if write_error != nil || written_size < temp_size {
				break // Retain data for next tick (Capacitor behavior)
			}
			ring.read_cursor = commit_cursor
			temp_size = 0
		}
		copy(temp_buffer[temp_size:], line_bytes)
		temp_size += len(line_bytes)

		commit_cursor += record_size
	}

	if temp_size > 0 {
		written_size, write_error := os.write(os.stderr, temp_buffer[:temp_size])
		if write_error == nil && written_size == temp_size {
			ring.read_cursor = commit_cursor
		}
	}
}
