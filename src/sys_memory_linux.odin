#+build linux
package tina

import "core:mem"
import "core:sys/linux"

os_page_size :: #force_inline proc "contextless" () -> uint {
	return 4096
}

// Reserves VA space and appends an inaccessible guard page at the tail.
// Returns the usable slice of memory (excluding the guard page).
os_reserve_arena_with_guard :: proc "contextless" (size: uint) -> (data:[]u8, err: mem.Allocator_Error) {
	page_sz := os_page_size()
	aligned_size := align_forward_page(size, page_sz)
	total_size := aligned_size + page_sz

	addr, errno := linux.mmap(
		0,
		total_size,
		{.READ, .WRITE},
		{.PRIVATE, .ANONYMOUS},
	)
	if errno != .NONE do return nil, .Out_Of_Memory

	// Guard page at the tail - PROT_NONE (empty protection set)
	guard_addr := rawptr(uintptr(addr) + uintptr(aligned_size))
	linux.mprotect(guard_addr, page_sz, {})

	return (cast([^]u8)addr)[:aligned_size], nil
}

// Releases the memory including the guard page
os_release_arena_with_guard :: proc "contextless" (data:[]u8) {
	if len(data) == 0 do return
	page_sz := os_page_size()
	aligned_size := align_forward_page(uint(len(data)), page_sz)
	total_size := aligned_size + page_sz
	linux.munmap(raw_data(data), total_size)
}
