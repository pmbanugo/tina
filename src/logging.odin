package tina

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

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
MAX_FORMATTED_LOG_LINE :: 256 // Max size for the string builder output

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

ctx_log :: proc(ctx: ^TinaContext, level: Log_Level, tag: Log_Tag, payload: []u8) {
	timestamp := ctx.shard.current_tick
	record_size := Log_Record_Header_Size + u64(((len(payload) + 7) & ~int(7)))

	capacity := ctx.shard.log_ring.capacity_mask + 1
	if ctx.shard.log_ring.write_cursor + record_size - ctx.shard.log_ring.read_cursor > capacity {
		return
	}

	header := Log_Record_Header {
		timestamp      = timestamp,
		isolate_handle = ctx.self_handle,
		payload_size   = u16(len(payload)),
		level          = level,
		tag            = tag,
	}

	_write_ring_data(
		&ctx.shard.log_ring,
		ctx.shard.log_ring.write_cursor,
		mem.byte_slice(cast(^u8)&header, 24),
	)
	if len(payload) > 0 {
		_write_ring_data(&ctx.shard.log_ring, ctx.shard.log_ring.write_cursor + 24, payload)
	}
	ctx.shard.log_ring.write_cursor += record_size
}

// SIMD-friendly 2-part ring buffer block copy
@(private = "package")
_write_ring_data :: #force_inline proc(ring: ^Log_Ring_Buffer, offset: u64, data: []u8) {
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

// SIMD-friendly 2-part ring buffer block read
@(private = "package")
_read_ring_data :: #force_inline proc(ring: ^Log_Ring_Buffer, offset: u64, data: []u8) {
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

// Step 7: Flush logs to OS stream via PIPE_BUF chunks
log_flush :: proc(shard: ^Shard) {
	temp_buf: [POSIX_PIPE_BUF_SIZE]u8
	temp_size := 0
	ring := &shard.log_ring

	for ring.read_cursor < ring.write_cursor {
		if ring.write_cursor - ring.read_cursor < Log_Record_Header_Size {break}

		header: Log_Record_Header
		_read_ring_data(
			ring,
			ring.read_cursor,
			mem.byte_slice(cast(^u8)&header, Log_Record_Header_Size),
		)
		record_size := Log_Record_Header_Size + u64((header.payload_size + 7) & ~u16(7))

		if ring.write_cursor - ring.read_cursor < record_size {break}

		payload_buf: [MAX_PAYLOAD_SIZE]u8
		_read_ring_data(
			ring,
			ring.read_cursor + Log_Record_Header_Size,
			payload_buf[:header.payload_size],
		)

		line_buffer: [MAX_FORMATTED_LOG_LINE]u8
		b := strings.builder_from_bytes(line_buffer[:])
		fmt.sbprintf(
			&b,
			"[%v] %v[Tag:%X] Handle:%X - %s\n",
			header.timestamp,
			header.level,
			header.tag,
			u64(header.isolate_handle),
			string(payload_buf[:header.payload_size]),
		)

		if temp_size + len(b.buf) > POSIX_PIPE_BUF_SIZE {
			os.write(os.stderr, temp_buf[:temp_size])
			temp_size = 0
		}
		copy(temp_buf[temp_size:], b.buf[:])
		temp_size += len(b.buf)

		ring.read_cursor += record_size
	}

	if temp_size > 0 {
		// TODO: check the os.write result for errors/EAGAIN? or do something different and assert earlier?
		os.write(os.stderr, temp_buf[:temp_size])
	}
}
