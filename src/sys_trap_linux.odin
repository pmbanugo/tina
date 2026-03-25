#+build linux
package tina

import "core:c"

OS_Trap_Environment :: distinct [64]c.long // 512 bytes on x64

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	@(link_name = "__sigsetjmp")
	_sigsetjmp :: proc(env: ^OS_Trap_Environment, savesigs: c.int) -> c.int ---
	siglongjmp :: proc(env: ^OS_Trap_Environment, val: c.int) -> ! ---
}

@(private = "package")
_os_trap_save :: #force_inline proc "contextless" (env: ^OS_Trap_Environment) -> i32 {
	return _sigsetjmp(env, 0) // savesigs = 0
}

@(private = "package")
_os_trap_restore :: #force_inline proc "contextless" (env: ^OS_Trap_Environment, val: i32) -> ! {
	siglongjmp(env, val)
}
