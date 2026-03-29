package tina

import "core:testing"

// 256-bit mask for Shard tracking.
Shard_Mask :: distinct [4]u64

shard_mask_contains :: #force_inline proc "contextless" (m: ^Shard_Mask, id: u8) -> bool {
	return (m[id >> 6] & (u64(1) << (id & 63))) != 0
}

shard_mask_include :: #force_inline proc "contextless" (m: ^Shard_Mask, id: u8) {
	m[id >> 6] |= (u64(1) << (id & 63))
}

shard_mask_exclude :: #force_inline proc "contextless" (m: ^Shard_Mask, id: u8) {
	m[id >> 6] &= ~(u64(1) << (id & 63))
}

@(test)
test_shard_mask_empty_state :: proc(t: ^testing.T) {
	mask: Shard_Mask // Odin zero-initializes this to {0, 0, 0, 0}

	// Prove nothing is contained initially
	for i in u8(0) ..= 255 {
		testing.expectf(t, !shard_mask_contains(&mask, i), "Bit %d should be empty initially", i)
	}
}

@(test)
test_shard_mask_isolation :: proc(t: ^testing.T) {
	mask: Shard_Mask

	// Set bit 42
	shard_mask_include(&mask, 42)

	// Prove exactly bit 42 is set
	testing.expect(t, shard_mask_contains(&mask, 42), "Bit 42 should be set")

	// Prove adjacent bits did not flip (isolation)
	testing.expect(t, !shard_mask_contains(&mask, 41), "Bit 41 should not bleed")
	testing.expect(t, !shard_mask_contains(&mask, 43), "Bit 43 should not bleed")

	// Clear bit 42
	shard_mask_exclude(&mask, 42)
	testing.expect(t, !shard_mask_contains(&mask, 42), "Bit 42 should be cleared")
}

@(test)
test_shard_mask_bucket_boundaries :: proc(t: ^testing.T) {
	mask: Shard_Mask

	// These specific numbers test the transition between the four 64-bit buckets
	// Bucket 0: 0-63, Bucket 1: 64-127, Bucket 2: 128-191, Bucket 3: 192-255
	boundaries := []u8{0, 63, 64, 127, 128, 191, 192, 255}

	for b in boundaries {
		shard_mask_include(&mask, b)
		testing.expectf(t, shard_mask_contains(&mask, b), "Boundary bit %d should be set", b)

		// Verify it didn't bleed across the 64-bit bucket boundaries
		if b > 0 {
			testing.expectf(
				t,
				!shard_mask_contains(&mask, b - 1),
				"Bit %d should not bleed down",
				b,
			)
		}
		if b < 255 {
			testing.expectf(t, !shard_mask_contains(&mask, b + 1), "Bit %d should not bleed up", b)
		}

		shard_mask_exclude(&mask, b)
		testing.expectf(t, !shard_mask_contains(&mask, b), "Boundary bit %d should be cleared", b)
	}
}

@(test)
test_shard_mask_all_alive_default :: proc(t: ^testing.T) {
	// This simulates exactly how hydrate_shard initializes the mask for the network
	mask := Shard_Mask{~u64(0), ~u64(0), ~u64(0), ~u64(0)}

	// Prove all 256 bits are alive
	for i in u8(0) ..= 255 {
		testing.expectf(
			t,
			shard_mask_contains(&mask, i),
			"Bit %d should be alive in default state",
			i,
		)
	}

	// Simulate Quarantining a Shard deep in bucket 2
	shard_mask_exclude(&mask, 150)

	// Prove exactly 150 is quarantined
	testing.expect(t, !shard_mask_contains(&mask, 150), "Shard 150 should be quarantined")
	testing.expect(t, shard_mask_contains(&mask, 149), "Shard 149 should still be alive")
	testing.expect(t, shard_mask_contains(&mask, 151), "Shard 151 should still be alive")

	// Simulate Restarting / Recovering that Shard
	shard_mask_include(&mask, 150)
	testing.expect(t, shard_mask_contains(&mask, 150), "Shard 150 should be recovered")
}

@(test)
test_shard_mask_max_capacity :: proc(t: ^testing.T) {
	mask: Shard_Mask

	// Populate the entire bitmask
	for i in u8(0) ..= 255 {
		shard_mask_include(&mask, i)
	}

	// Verify all internal integers are completely saturated (all 1s)
	testing.expect_value(t, mask[0], ~u64(0))
	testing.expect_value(t, mask[1], ~u64(0))
	testing.expect_value(t, mask[2], ~u64(0))
	testing.expect_value(t, mask[3], ~u64(0))
}
