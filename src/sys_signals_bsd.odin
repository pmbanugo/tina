#+build darwin, freebsd, openbsd, netbsd

package tina

import "core:sys/posix"
import "core:sys/kqueue"
import "core:c"

// BSD/Darwin: sigtimedwait is not available in Odin's posix bindings.
// Use kqueue EVFILT_SIGNAL for timed signal waiting instead.
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
    kq, err := kqueue.kqueue()
    if err != nil do return nil, false
    defer posix.close(posix.FD(kq))

    // Watch for blocked signals
    evs := [4]kqueue.KEvent{
        { ident = uintptr(posix.Signal.SIGTERM), filter = .Signal, flags = {.Add, .Enable} },
        { ident = uintptr(posix.Signal.SIGINT),  filter = .Signal, flags = {.Add, .Enable} },
        { ident = uintptr(posix.Signal.SIGUSR2), filter = .Signal, flags = {.Add, .Enable} },
        { ident = uintptr(posix.Signal.SIGHUP),  filter = .Signal, flags = {.Add, .Enable} },
    }

    ts := posix.timespec {
        tv_sec = posix.time_t(timeout_ms / 1000),
        tv_nsec = c.long((timeout_ms % 1000) * 1_000_000),
    }

    out_evs: [1]kqueue.KEvent
    n, _ := kqueue.kevent(kqueue.KQ(kq), evs[:], out_evs[:], &ts)

    if n > 0 {
        return posix.Signal(out_evs[0].ident), true
    }
    return nil, false
}
