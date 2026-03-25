#+build linux

package tina

import "core:sys/linux"
import "core:sys/posix"

// Linux: use rt_sigtimedwait for timed signal waiting.
// BSD/Darwin use kqueue EVFILT_SIGNAL (see sys_signals_bsd.odin).
os_poll_watchdog_events :: proc(timeout_ms: u32) -> Watchdog_Event {
	sig, ok := os_wait_for_signal(timeout_ms)
	if !ok do return .None

	#partial switch sig {
	case .SIGTERM, .SIGINT: return .Shutdown
	case .SIGUSR2:          return .Recover_Quarantine
	case .SIGHUP:           return .Reload_Config
	case:                   return .None
	}
}

os_wait_for_signal :: proc(timeout_ms: u32) -> (sig: posix.Signal, ok: bool) {
    set: linux.Sig_Set
    // Zero-init, then set the bits for the signals we care about.
    for &word in set {
        word = 0
    }
    // Signal bit = 1 << (signo - 1) within the appropriate word.
    _sigaddset(&set, linux.Signal.SIGTERM)
    _sigaddset(&set, linux.Signal.SIGINT)
    _sigaddset(&set, linux.Signal.SIGUSR2)
    _sigaddset(&set, linux.Signal.SIGHUP)

    time_spec := linux.Time_Spec {
        time_sec  = uint(timeout_ms / 1000),
        time_nsec = uint((timeout_ms % 1000) * 1_000_000),
    }

    info: linux.Sig_Info
    received_signal, errno := linux.rt_sigtimedwait(&set, &info, &time_spec)

    if errno == .NONE && i32(received_signal) > 0 {
        return posix.Signal(received_signal), true
    }
    return nil, false
}

// Add a signal to a sigset. Mirrors sigaddset(3).
@(private = "file")
_sigaddset :: proc(set: ^linux.Sig_Set, signal: linux.Signal) {
    signo := u32(signal)
    word_index := (signo - 1) / (8 * size_of(uint))
    bit_index := (signo - 1) % (8 * size_of(uint))
    set[word_index] |= uint(1) << bit_index
}
