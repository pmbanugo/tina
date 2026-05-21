package tina

import "core:testing"

// OS-agnostic aliases for the Trap Boundary environment
os_trap_save :: #force_inline proc "contextless" (env: ^OS_Trap_Environment) -> i32 {
	return _os_trap_save(env)
}

os_trap_restore :: #force_inline proc "contextless" (env: ^OS_Trap_Environment, val: i32) -> ! {
	_os_trap_restore(env, val)
}

// ============================================================================
// Tests
// ============================================================================

@(test)
test_trap_save_restore_round_trip :: proc(t: ^testing.T) {
	env: OS_Trap_Environment
	result := os_trap_save(&env)
	if result == 0 {
		os_trap_restore(&env, 42)
	}
	testing.expect_value(t, result, 42)
}

@(test)
test_trap_restore_different_values :: proc(t: ^testing.T) {
	// Verify the return-value path (mov eax, edx) doesn't truncate or
	// corrupt values at interesting bit boundaries.
	Test_Case :: struct {
		input:    i32,
		expected: i32,
	}

	cases := [?]Test_Case {
		{1, 1},       // minimum positive
		{255, 255},   // byte boundary
		{-1, -1},     // all bits set (0xFFFFFFFF)
	}

	for tc in cases {
		env: OS_Trap_Environment
		result := os_trap_save(&env)
		if result == 0 {
			os_trap_restore(&env, tc.input)
		}
		testing.expect_value(t, result, tc.expected)
	}
}

@(test)
test_trap_nested_save_restore :: proc(t: ^testing.T) {
	// Mirrors the real inner/outer trap boundary pattern in shard/bootstrap.
	env_outer: OS_Trap_Environment
	env_inner: OS_Trap_Environment

	outer_result := os_trap_save(&env_outer)
	if outer_result == 0 {
		inner_result := os_trap_save(&env_inner)
		if inner_result == 0 {
			os_trap_restore(&env_inner, 1)
		}
		testing.expect_value(t, inner_result, 1)
		os_trap_restore(&env_outer, 2)
	}
	testing.expect_value(t, outer_result, 2)
}

// Helper for test_trap_cross_frame_restore — restores from a deeper call frame.
@(private = "file")
_restore_cross_frame :: proc "contextless" (env: ^OS_Trap_Environment, val: i32) -> ! {
	os_trap_restore(env, val)
}

@(test)
test_trap_cross_frame_restore :: proc(t: ^testing.T) {
	// os_trap_restore is always called from a deeper frame than os_trap_save
	// in production (e.g., signal handler → shard frame). This validates
	// that RSP unwinding works across multiple stack frames.
	env: OS_Trap_Environment
	result := os_trap_save(&env)
	if result == 0 {
		_restore_cross_frame(&env, 99)
	}
	testing.expect_value(t, result, 99)
}
