package tina

import "core:testing"

Handle :: distinct u64

make_handle :: proc(shard_id, type_id, slot, generation: u16) -> Handle {
    return Handle(u64(shard_id) | (u64(type_id) << 16) | (u64(slot) << 32) | (u64(generation) << 48))
}

extract_shard_id :: proc(h: Handle) -> u16 {
    return u16(u64(h) & 0xFFFF)
}

extract_type_id :: proc(h: Handle) -> u16 {
    return u16((u64(h) >> 16) & 0xFFFF)
}

extract_slot :: proc(h: Handle) -> u16 {
    return u16((u64(h) >> 32) & 0xFFFF)
}

extract_generation :: proc(h: Handle) -> u16 {
    return u16((u64(h) >> 48) & 0xFFFF)
}

@(test)
test_handle_packing :: proc(t: ^testing.T) {
    h0 := make_handle(0, 0, 0, 0)
    testing.expect_value(t, extract_shard_id(h0), 0)
    testing.expect_value(t, extract_type_id(h0), 0)
    testing.expect_value(t, extract_slot(h0), 0)
    testing.expect_value(t, extract_generation(h0), 0)

    h_max := make_handle(0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF)
    testing.expect_value(t, extract_shard_id(h_max), 0xFFFF)
    testing.expect_value(t, extract_type_id(h_max), 0xFFFF)
    testing.expect_value(t, extract_slot(h_max), 0xFFFF)
    testing.expect_value(t, extract_generation(h_max), 0xFFFF)

    h_mixed := make_handle(0x1234, 0x5678, 0x9ABC, 0xDEF0)
    testing.expect_value(t, extract_shard_id(h_mixed), 0x1234)
    testing.expect_value(t, extract_type_id(h_mixed), 0x5678)
    testing.expect_value(t, extract_slot(h_mixed), 0x9ABC)
    testing.expect_value(t, extract_generation(h_mixed), 0xDEF0)
}
