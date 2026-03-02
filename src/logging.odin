package tina

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"

Log_Level :: enum u8 { ERROR = 0, WARN = 1, INFO = 2, DEBUG = 3 }

Log_Tag     :: distinct u8

LOG_TAG_ISOLATE_CRASHED : Log_Tag : 0x01
LOG_TAG_ISOLATE_TRAPPED : Log_Tag : 0x02
LOG_TAG_SUPERVISION     : Log_Tag : 0x03
LOG_TAG_SHARD_RESTARTED : Log_Tag : 0x06
LOG_TAG_IO_EXHAUSTION   : Log_Tag : 0x08
// Application log tags can start from here (0x40 - 0xFF)
USER_LOG_TAG_BASE : Log_Tag : 0x40

POSIX_PIPE_BUF_SIZE     :: 4096  // Guaranteed atomic write size on POSIX
MAX_FORMATTED_LOG_LINE  :: 256   // Max size for the string builder output

// 24 bytes exactly. Ordered largest to smallest.
Log_Record_Header :: struct {
    timestamp: u64,         // 8 bytes
    isolate_handle: Handle, // 8 bytes
    payload_size: u16,      // 2 bytes
    _reserved_0: u16,       // 2 bytes
    level: Log_Level,       // 1 byte
    tag: Log_Tag,           // 1 byte
    _reserved_1: u16,       // 2 bytes
}

Log_Record_Header_Size :: u64(size_of(Log_Record_Header))

Log_Ring_Buffer :: struct {
    buffer:[]u8,
    capacity: u64,
    read_cursor: u64,
    write_cursor: u64,
}

log_init :: proc(ring: ^Log_Ring_Buffer, backing:[]u8) {
    ring.buffer = backing
    ring.capacity = u64(len(backing))
    ring.read_cursor = 0
    ring.write_cursor = 0
}

ctx_log :: proc(ctx: ^TinaContext, level: Log_Level, tag: Log_Tag, payload:[]u8) {
    timestamp := ctx.shard.clock.current_tick
    record_size := Log_Record_Header_Size + u64( ((len(payload) + 7) & ~int(7))) // 8-byte aligned chunks

    // Front-door drop if full
    if ctx.shard.log_ring.write_cursor + record_size - ctx.shard.log_ring.read_cursor > ctx.shard.log_ring.capacity {
        return
    }

    header := Log_Record_Header{
        timestamp = timestamp,
        isolate_handle = ctx.self_handle,
        payload_size = u16(len(payload)),
        level = level,
        tag = tag,
    }

    _write_ring_data(&ctx.shard.log_ring, ctx.shard.log_ring.write_cursor, mem.byte_slice(cast(^u8)&header, 24))
    if len(payload) > 0 {
        _write_ring_data(&ctx.shard.log_ring, ctx.shard.log_ring.write_cursor + 24, payload)
    }
    ctx.shard.log_ring.write_cursor += record_size
}

@(private="package")
_write_ring_data :: proc(ring: ^Log_Ring_Buffer, offset: u64, data:[]u8) {
    for i in 0..<len(data) {
        ring.buffer[(offset + u64(i)) % ring.capacity] = data[i]
    }
}

@(private="package")
_read_ring_data :: proc(ring: ^Log_Ring_Buffer, offset: u64, data: []u8) {
    for i in 0..<len(data) {
        data[i] = ring.buffer[(offset + u64(i)) % ring.capacity]
    }
}

// Step 7: Flush logs to OS stream via PIPE_BUF chunks
log_flush :: proc(shard: ^Shard) {
    temp_buf: [POSIX_PIPE_BUF_SIZE]u8
    temp_len := 0
    ring := &shard.log_ring

    for ring.read_cursor < ring.write_cursor {
        if ring.write_cursor - ring.read_cursor < Log_Record_Header_Size { break }

        header: Log_Record_Header
        _read_ring_data(ring, ring.read_cursor, mem.byte_slice(cast(^u8)&header, Log_Record_Header_Size))
        record_len := Log_Record_Header_Size + u64((header.payload_size + 7) & ~u16(7))

        if ring.write_cursor - ring.read_cursor < record_len { break }

        payload_buf: [MAX_PAYLOAD_SIZE]u8
        _read_ring_data(ring, ring.read_cursor + Log_Record_Header_Size, payload_buf[:header.payload_size])

        line_buffer: [MAX_FORMATTED_LOG_LINE]u8
        b := strings.builder_from_bytes(line_buffer[:])
        fmt.sbprintf(&b, "[%v] %v[Tag:%X] Handle:%X - %s\n",
            header.timestamp, header.level, header.tag, u64(header.isolate_handle),
            string(payload_buf[:header.payload_size]))

        // Chunk to 4096 to prevent cross-thread interleaving (PIPE_BUF atomicity)
        if temp_len + len(b.buf) > POSIX_PIPE_BUF_SIZE {
            os.write(os.stderr, temp_buf[:temp_len])
            temp_len = 0
        }
        copy(temp_buf[temp_len:], b.buf[:])
        temp_len += len(b.buf)

        ring.read_cursor += record_len
    }

    // EAGAIN handling (capacitor behavior). We write what we have.
    if temp_len > 0 {
    	// TODO: check the os.write result for errors/EAGAIN? or do something different and assert earlier?
        os.write(os.stderr, temp_buf[:temp_len])
    }
}
