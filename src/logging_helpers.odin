package tina

// --- Async-Signal-Safe Helpers (write(2) only, no fmt/allocator/runtime) ---
// Used by signal handlers and the assertion failure proc for safe string formatting.

@(private = "package")
_sig_append_str :: proc "contextless" (target: []u8, position: int, source: string) -> int {
	n := min(len(target) - position, len(source))
	for i in 0 ..< n do target[position + i] = source[i]
	return position + n
}

@(private = "package")
_sig_append_u64 :: proc "contextless" (target: []u8, position: int, value: u64) -> int {
	if position >= len(target) do return position
	if value == 0 {
		target[position] = '0'
		return position + 1
	}
	tmp: [20]u8
	n := 0
	v := value
	for v > 0 {
		tmp[n] = u8('0') + u8(v % 10)
		v /= 10
		n += 1
	}
	written := min(n, len(target) - position)
	for i in 0 ..< written {
		target[position + i] = tmp[n - 1 - i]
	}
	return position + written
}
