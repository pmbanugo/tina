package tina

// Aligns size up to the nearest page boundary
align_forward_page :: #force_inline proc "contextless" (size: uint, page_size: uint) -> uint {
	return (size + page_size - 1) & ~(page_size - 1)
}
