package tina

// u64-backed bitmaps use explicit shift/mask helpers so the word math stays
// structural and does not depend on compiler strength reduction.
BITMAP_WORD_SHIFT_COUNT :: 6
BITMAP_WORD_BIT_COUNT   :: 1 << BITMAP_WORD_SHIFT_COUNT
BITMAP_WORD_BIT_MASK    :: BITMAP_WORD_BIT_COUNT - 1

#assert(BITMAP_WORD_BIT_COUNT == size_of(u64) * 8)

// Calculates the number of 64-bit words required to back a bitmap of a given capacity.
// Useful when allocating slices (e.g., `make([]u64, bitmap_word_count_from_bit_count(N))`).
bitmap_word_count_from_bit_count :: #force_inline proc "contextless" (bit_count: int) -> int {
	if bit_count <= 0 {
		return 0
	}
	return (bit_count + BITMAP_WORD_BIT_MASK) >> BITMAP_WORD_SHIFT_COUNT
}

// Maps a global bit position to its corresponding `u64` word in the backing array.
// Used as the array index when reading or modifying the bitset.
bitmap_word_index_from_bit_index :: #force_inline proc "contextless" (bit_index: u32) -> int {
	return int(bit_index >> BITMAP_WORD_SHIFT_COUNT)
}

// Extracts the local bit position (0-63) within its containing word.
// Isolates the remainder to prepare for bit shifting operations.
bitmap_word_bit_index_from_bit_index :: #force_inline proc "contextless" (bit_index: u32) -> u32 {
	return bit_index & BITMAP_WORD_BIT_MASK
}

// Generates a 64-bit mask for a specific local bit index.
// Used in conjunction with bitwise OR/AND to set, clear, or test the bit in the word.
bitmap_mask_from_word_bit_index :: #force_inline proc "contextless" (word_bit_index: u32) -> u64 {
	return u64(1) << word_bit_index
}

// A direct convenience helper that combines local index extraction and mask generation.
// This is the primary utility for checking or mutating a global bit position.
bitmap_mask_from_bit_index :: #force_inline proc "contextless" (bit_index: u32) -> u64 {
	return bitmap_mask_from_word_bit_index(bitmap_word_bit_index_from_bit_index(bit_index))
}

// Translates a local bit position back into a global bit index.
// Essential when iterating over set bits (e.g., using `bits.trailing_zeros` on a word).
bitmap_bit_index_from_word_index_and_word_bit_index :: #force_inline proc "contextless" (
	word_index: int,
	word_bit_index: u32,
) -> u32 {
	return (u32(word_index) << BITMAP_WORD_SHIFT_COUNT) + word_bit_index
}
