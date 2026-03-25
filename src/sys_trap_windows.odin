#+build windows
package tina

import "core:c"

OS_Trap_Environment :: distinct [64]c.long

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	@(link_name = "_setjmp")
	_tina_setjmp :: proc(env: ^OS_Trap_Environment, hack: rawptr = nil) -> c.int ---
	@(link_name = "longjmp")
	_tina_longjmp :: proc(env: ^OS_Trap_Environment, val: c.int) -> ! ---
}

@(private = "package")
_os_trap_save :: #force_inline proc "contextless" (env: ^OS_Trap_Environment) -> i32 {
	return _tina_setjmp(env)
}

@(private = "package")
_os_trap_restore :: #force_inline proc "contextless" (env: ^OS_Trap_Environment, val: i32) -> ! {
	_tina_longjmp(env, val)
}
