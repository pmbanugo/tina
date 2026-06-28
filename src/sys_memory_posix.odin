#+build darwin, freebsd, openbsd, netbsd
package tina

import "core:mem"
import "core:sys/posix"

os_page_size :: #force_inline proc "contextless" () -> uint {
	return uint(posix.sysconf(._PAGESIZE))
}

os_reserve_arena_with_guard :: proc "contextless" (size: uint) -> (data:[]u8, error: mem.Allocator_Error) {
	page_sz := os_page_size()
	aligned_size := align_forward_page(size, page_sz)
	total_size := aligned_size + page_sz

	addr := posix.mmap(
		nil,
		total_size,
		{.READ, .WRITE},
		{.ANONYMOUS, .PRIVATE},
		-1,
		0,
	)
	if addr == posix.MAP_FAILED || addr == nil do return {}, .Out_Of_Memory

	assert_contextless(cast(uintptr)addr & (CACHE_LINE_SIZE - 1) == 0,
		"os_reserve_arena_with_guard: mmap returned non-CACHE_LINE_SIZE aligned memory")

	usable_size := int(aligned_size)
	memory := mem.byte_slice(addr, int(total_size))

	guard_addr := raw_data(memory[usable_size:])
	posix.mprotect(guard_addr, page_sz, {})

	return mem.byte_slice(addr, usable_size), .None
}

// Releases the memory including the guard page
os_release_arena_with_guard :: proc "contextless" (data:[]u8) {
	if len(data) == 0 do return
	page_sz := os_page_size()
	aligned_size := align_forward_page(uint(len(data)), page_sz)
	total_size := aligned_size + page_sz
	posix.munmap(raw_data(data), total_size)
}
