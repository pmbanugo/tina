#+build linux, darwin, freebsd, openbsd, netbsd
package tina

import "core:fmt"
import "core:os"
import "core:sys/posix"

// Configures process-wide signal dispositions before any threads are spawned.
os_signals_init_process :: #force_inline proc() {
	// Ignore SIGPIPE process-wide.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	// Install SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP, SIGABRT handlers with SA_ONSTACK
	sa_fatal: posix.sigaction_t
	sa_fatal.sa_sigaction = _fatal_signal_handler
	sa_fatal.sa_flags = {.SIGINFO, .ONSTACK}
	posix.sigemptyset(&sa_fatal.sa_mask)

	posix.sigaction(.SIGSEGV, &sa_fatal, nil)
	posix.sigaction(.SIGBUS, &sa_fatal, nil)
	posix.sigaction(.SIGFPE, &sa_fatal, nil)
	posix.sigaction(.SIGILL, &sa_fatal, nil)
	posix.sigaction(.SIGTRAP, &sa_fatal, nil)
	posix.sigaction(.SIGABRT, &sa_fatal, nil)

	// Install SIGUSR1 handler with SA_ONSTACK
	sa_usr1: posix.sigaction_t
	sa_usr1.sa_sigaction = _sigusr1_handler
	sa_usr1.sa_flags = {.SIGINFO, .ONSTACK}
	posix.sigemptyset(&sa_usr1.sa_mask)

	posix.sigaction(.SIGUSR1, &sa_usr1, nil)

	// Block signals that will be handled synchronously via sigtimedwait by the watchdog.
	blocked: posix.sigset_t
	posix.sigemptyset(&blocked)
	posix.sigaddset(&blocked, .SIGTERM)
	posix.sigaddset(&blocked, .SIGINT)
	posix.sigaddset(&blocked, .SIGUSR1)
	posix.sigaddset(&blocked, .SIGUSR2)
	posix.sigaddset(&blocked, .SIGHUP)

	sig_err := posix.pthread_sigmask(.BLOCK, &blocked, nil)
	if sig_err != .NONE {
		fmt.eprintfln("[FATAL] Failed to set pthread_sigmask: %v", posix.strerror(sig_err))
		os.exit(1)
	}
}

// Called by the Shard thread to unblock signals meant specifically for it
os_signals_init_thread :: #force_inline proc() {
	unblock_sig: posix.sigset_t
	posix.sigemptyset(&unblock_sig)
	posix.sigaddset(&unblock_sig, .SIGUSR1)
	posix.pthread_sigmask(.UNBLOCK, &unblock_sig, nil)
}

// Called after a siglongjmp to manually restore the hardware trap signals
os_signals_restore_thread_mask :: #force_inline proc() {
	unblock_sig: posix.sigset_t
	posix.sigemptyset(&unblock_sig)
	posix.sigaddset(&unblock_sig, .SIGSEGV)
	posix.sigaddset(&unblock_sig, .SIGBUS)
	posix.sigaddset(&unblock_sig, .SIGFPE)
	posix.sigaddset(&unblock_sig, .SIGILL)
	posix.sigaddset(&unblock_sig, .SIGTRAP)
	posix.sigaddset(&unblock_sig, .SIGABRT)
	posix.sigaddset(&unblock_sig, .SIGUSR1)
	posix.pthread_sigmask(.UNBLOCK, &unblock_sig, nil)
}

os_abort :: #force_inline proc "contextless" () -> ! {
	posix.abort()
}

// The Tier 3 Fault Trap
@(private = "file")
_fatal_signal_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ucontext: rawptr) {
	shard := g_current_shard_pointer
	if shard == nil {
		buf: [64]u8
		n := _sig_append_str(buf[:], 0, "[FATAL] non-shard sig=")
		n = _sig_append_u64(buf[:], n, u64(sig))
		n = _sig_append_str(buf[:], n, "\n")
		_write_stderr(buf[:n])
		posix.signal(sig, auto_cast posix.SIG_DFL)
		posix.raise(sig)
		return
	}

	buf: [96]u8
	n := _sig_append_str(buf[:], 0, "[FATAL] Shard ")
	n = _sig_append_u64(buf[:], n, u64(shard.id))
	n = _sig_append_str(buf[:], n, " caught sig=")
	n = _sig_append_u64(buf[:], n, u64(sig))
	n = _sig_append_str(buf[:], n, ". Level 2 Recovery.\n")
	_write_stderr(buf[:n])

	emergency_log_flush_signal(shard)
	os_trap_restore(&shard.trap_environment_outer, RECOVERY_TIER_3)
}

// The Watchdog Cooperative Kill Trap
@(private = "file")
_sigusr1_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ucontext: rawptr) {
	shard := g_current_shard_pointer
	if shard == nil do return

	buf: [96]u8
	n := _sig_append_str(buf[:], 0, "[WATCHDOG] Shard ")
	n = _sig_append_u64(buf[:], n, u64(shard.id))
	n = _sig_append_str(buf[:], n, " SIGUSR1 force-kill. Level 2 Recovery.\n")
	_write_stderr(buf[:n])

	os_trap_restore(&shard.trap_environment_outer, RECOVERY_WATCHDOG)
}
