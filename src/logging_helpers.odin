package tina

// --- Async-Signal-Safe Helpers (write(2) only, no fmt/allocator/runtime) ---
// Used by signal handlers and the assertion failure proc for safe string formatting.

@(private = "package")
_sig_append_str :: #force_inline proc "contextless" (target: []u8, position: int, source: string) -> int {
	copy_count := min(len(target) - position, len(source))
	for i in 0 ..< copy_count do target[position + i] = source[i]
	return position + copy_count
}

@(private = "package")
_sig_append_u64 :: #force_inline proc "contextless" (target: []u8, position: int, value: u64) -> int {
	if position >= len(target) do return position
	if value == 0 {
		target[position] = '0'
		return position + 1
	}
	digits: [20]u8
	digit_count := 0
	v := value
	for v > 0 {
		digits[digit_count] = u8('0') + u8(v % 10)
		v /= 10
		digit_count += 1
	}
	write_count := min(digit_count, len(target) - position)
	for i in 0 ..< write_count {
		target[position + i] = digits[digit_count - 1 - i]
	}
	return position + write_count
}

@(private = "package")
_sig_append_hex :: #force_inline proc "contextless" (target: []u8, position: int, value: u64) -> int {
	if position >= len(target) do return position
	if value == 0 {
		target[position] = '0'
		return position + 1
	}
	@(static, rodata)
	hex_digits := [16]u8 {
		'0', '1', '2', '3', '4', '5', '6', '7',
		'8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
	}
	digits: [16]u8
	digit_count := 0
	v := value
	for v > 0 {
		digits[digit_count] = hex_digits[v & 0xF]
		v >>= 4
		digit_count += 1
	}
	write_count := min(digit_count, len(target) - position)
	for i in 0 ..< write_count {
		target[position + i] = digits[digit_count - 1 - i]
	}
	return position + write_count
}
