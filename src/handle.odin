package tina

import "core:testing"

Handle :: distinct u64

HANDLE_NONE :: Handle(0)

make_handle :: #force_inline proc(shard_id: u16, type_id: u16, slot: u32, generation: u32) -> Handle {
    // shard_id: 8 bits (63-56)
    // type_id: 8 bits (55-48)
    // slot_idx: 20 bits (47-28)
    // generation: 28 bits (27-0)
    return Handle(
        (u64(shard_id & 0xFF) << 56) |
        (u64(type_id & 0xFF) << 48) |
        (u64(slot & 0xFFFFF) << 28) |
        (u64(generation & 0x0FFFFFFF)))
}

extract_shard_id :: #force_inline proc(h: Handle) -> u16 {
    return u16((u64(h) >> 56) & 0xFF)
}

extract_type_id :: #force_inline proc(h: Handle) -> u16 {
    return u16((u64(h) >> 48) & 0xFF)
}

extract_slot :: #force_inline proc(h: Handle) -> u32 {
    return u32((u64(h) >> 28) & 0xFFFFF)
}

extract_generation :: #force_inline proc(h: Handle) -> u32 {
    return u32(u64(h) & 0x0FFFFFFF)
}

@(test)
test_handle_packing :: proc(t: ^testing.T) {
    h0 := make_handle(0, 0, 0, 0)
    testing.expect_value(t, extract_shard_id(h0), 0)
    testing.expect_value(t, extract_type_id(h0), 0)
    testing.expect_value(t, extract_slot(h0), 0)
    testing.expect_value(t, extract_generation(h0), 0)

    // Test max values for bit budgets
    h_max := make_handle(0xFF, 0xFF, 0xFFFFF, 0x0FFFFFFF)
    testing.expect_value(t, extract_shard_id(h_max), 0xFF)
    testing.expect_value(t, extract_type_id(h_max), 0xFF)
    testing.expect_value(t, extract_slot(h_max), 0xFFFFF)
    testing.expect_value(t, extract_generation(h_max), 0x0FFFFFFF)

    h_mixed := make_handle(0x12, 0x56, 0x9ABC, 0xDEF0123)
    testing.expect_value(t, extract_shard_id(h_mixed), 0x12)
    testing.expect_value(t, extract_type_id(h_mixed), 0x56)
    testing.expect_value(t, extract_slot(h_mixed), 0x9ABC)
    testing.expect_value(t, extract_generation(h_mixed), 0xDEF0123)
}
