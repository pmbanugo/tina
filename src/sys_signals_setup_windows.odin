#+build windows
package tina

import "core:testing"
import win "core:sys/windows"

os_signals_init_process :: proc() {
	// Install a Vectored Exception Handler as the Windows equivalent of
	// POSIX signal handlers (SIGSEGV, SIGBUS, SIGFPE, etc.).
	//
	// FirstHandler = 1 means Tina's handler runs first, before any
	// debugger or other VEH handlers. It only intervenes for shard
	// threads; all other exceptions continue to the next handler.
	win.AddVectoredExceptionHandler(1, _vectored_exception_handler)
}

// No per-thread signal setup needed on Windows.
os_signals_init_thread :: #force_inline proc "contextless" () {}

// No signal mask to restore on Windows.
os_signals_restore_thread_mask :: #force_inline proc "contextless" () {}

os_abort :: #force_inline proc "contextless" () -> ! {
	win.ExitProcess(1)
}

// NOTE: ARM64 Windows would require a separate handler path or
// conditional logic because the CONTEXT struct uses a different
// register layout (x0–x28, sp, lr, pc).

@(private = "file")
_vectored_exception_handler :: proc "system" (exception_info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	shard := g_current_shard_pointer
	if shard == nil do return win.EXCEPTION_CONTINUE_SEARCH

	// Best-effort diagnostic flush before redirecting.
	emergency_log_flush_signal(shard)

	// Redirect execution to the outer trap recovery point.
	// The OS restores the modified context via RtlRestoreContext.
	env := &shard.trap_environment_outer
	ctx := exception_info.ContextRecord

	ctx.Rbx = env.rbx
	ctx.Rbp = env.rbp
	ctx.Rdi = env.rdi
	ctx.Rsi = env.rsi
	ctx.R12 = env.r12
	ctx.R13 = env.r13
	ctx.R14 = env.r14
	ctx.R15 = env.r15
	ctx.Rsp = env.stack_pointer
	ctx.Rip = env.return_address
	ctx.Rax = RECOVERY_TIER_3

	return win.EXCEPTION_CONTINUE_EXECUTION
}

// ============================================================================
// Tests
// ============================================================================

@(test)
test_windows_veh_exception_recovery :: proc(t: ^testing.T) {
	os_signals_init_process()

	shard := new(Shard)
	shard_old := g_current_shard_pointer
	defer g_current_shard_pointer = shard_old
	defer free(shard)
	g_current_shard_pointer = shard

	result := os_trap_save(&shard.trap_environment_outer)
	if result == 0 {
		win.RaiseException(
			win.EXCEPTION_ACCESS_VIOLATION,
			0, // dwExceptionFlags — no continuation
			0, // nNumberOfArguments
			nil,
		)
	}
	testing.expect_value(t, result, RECOVERY_TIER_3)
}
