#+build windows
package tina

import "core:mem"
import win "core:sys/windows"

os_page_size :: #force_inline proc "contextless" () -> uint {
	info: win.SYSTEM_INFO
	win.GetSystemInfo(&info)
	return uint(info.dwPageSize)
}

os_reserve_arena_with_guard :: proc "contextless" (size: uint) -> (data:[]u8, err: mem.Allocator_Error) {
	page_sz := os_page_size()
	aligned_size := align_forward_page(size, page_sz)
	total_size := aligned_size + page_sz // Add exactly one guard page

	// Reserve the whole chunk including guard page
	addr := win.VirtualAlloc(nil, total_size, win.MEM_RESERVE, win.PAGE_NOACCESS)
	if addr == nil do return nil, .Out_Of_Memory

	// Commit the usable portion
	commit_addr := win.VirtualAlloc(addr, aligned_size, win.MEM_COMMIT, win.PAGE_READWRITE)
	if commit_addr == nil {
		win.VirtualFree(addr, 0, win.MEM_RELEASE)
		return nil, .Out_Of_Memory
	}

	// The tail page remains MEM_RESERVE (uncommitted/no-access), serving as the guard page
	return (cast([^]u8)addr)[:aligned_size], nil
}

// Releases the memory including the guard page
os_release_arena_with_guard :: proc "contextless" (data:[]u8) {
	if len(data) == 0 do return
	page_sz := os_page_size()
	aligned_size := align_forward_page(uint(len(data)), page_sz)
	total_size := aligned_size + page_sz
	// MEM_RELEASE requires the size parameter to be 0
	win.VirtualFree(raw_data(data), 0, win.MEM_RELEASE)
}
