#+build windows
package tina

// NOTE: ARM64 Windows support (arm64ec or native) would need a different
// register set (x0–x28, v0–v31, sp, lr, pc) and a separate .asm file
// targeting aarch64. The current implementation targets x64 (AMD64 / Intel 64)
// only.
//
// KNOWN GAP — XMM6–XMM15 not saved/restored:
//
// Windows x64 defines XMM6–XMM15 as callee-saved (must be preserved across
// function calls). This struct and the accompanying NASM assembly do not
// save/restore them. After os_trap_restore or VEH recovery, any code that
// was using XMM6–XMM15 at the save point will see their post-clobber values
// instead of the saved values.
//
// In production, the compiler rarely uses XMM6–XMM15 in the code between
// os_trap_save and os_trap_restore because the critical sections are
// short and integer-heavy. The biggest risk is the VEH handler's
// RtlRestoreContext path: the CONTEXT passed by the OS contains the
// XMM6–XMM15 values at exception time, and the handler does not overwrite
// them with save-point values. If this ever causes a real bug, add
// xmm6–xmm15 fields to this struct and update both the NASM file and
// _vectored_exception_handler in sys_signals_setup_windows.odin.

OS_Trap_Environment :: struct #align (16) {
	return_address: u64,
	stack_pointer:  u64,
	rbx:            u64,
	rbp:            u64,
	rdi:            u64,
	rsi:            u64,
	r12:            u64,
	r13:            u64,
	r14:            u64,
	r15:            u64,
}

#assert(size_of(OS_Trap_Environment) == 80, "OS_Trap_Environment size must match x64 register save layout (10 × u64)")
#assert(align_of(OS_Trap_Environment) == 16, "OS_Trap_Environment must be 16-byte aligned for SSE movdqa compatibility")

// Import the NASM-compiled trap save/restore routines.
// Odin compiles .asm files with NASM and links the resulting .obj automatically.
foreign import tina_trap_impl "tina_trap_windows_x64.asm"

@(default_calling_convention = "c")
foreign tina_trap_impl {
	@(private = "package")
	_os_trap_save :: proc(env: ^OS_Trap_Environment) -> i32 ---

	@(private = "package")
	_os_trap_restore :: proc(env: ^OS_Trap_Environment, val: i32) -> ! ---
}
