package tina

// OS-agnostic aliases for the Trap Boundary environment
os_trap_save :: #force_inline proc "contextless" (env: ^OS_Trap_Environment) -> i32 {
	return _os_trap_save(env)
}

os_trap_restore :: #force_inline proc "contextless" (env: ^OS_Trap_Environment, val: i32) -> ! {
	_os_trap_restore(env, val)
}
