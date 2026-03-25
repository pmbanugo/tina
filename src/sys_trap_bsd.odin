#+build darwin, freebsd, openbsd, netbsd
package tina

import "core:c"

OS_Trap_Environment :: distinct [256]c.long // 2048 bytes on 64-bit (covers all BSDs)

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	sigsetjmp :: proc(env: ^OS_Trap_Environment, savesigs: c.int) -> c.int ---
	siglongjmp :: proc(env: ^OS_Trap_Environment, val: c.int) -> ! ---
}

@(private = "package")
_os_trap_save :: #force_inline proc "contextless" (env: ^OS_Trap_Environment) -> i32 {
	return sigsetjmp(env, 0) // savesigs = 0
}

@(private = "package")
_os_trap_restore :: #force_inline proc "contextless" (env: ^OS_Trap_Environment, val: i32) -> ! {
	siglongjmp(env, val)
}
