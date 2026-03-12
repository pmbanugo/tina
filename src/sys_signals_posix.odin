#+build linux, freebsd, openbsd, netbsd

package tina

import "core:sys/posix"
import "core:c"

os_wait_for_signal :: proc(timeout_ms: u32) -> (sig: posix.Signal, ok: bool) {
    set: posix.sigset_t
    posix.sigemptyset(&set)
    posix.sigaddset(&set, .SIGTERM)
    posix.sigaddset(&set, .SIGINT)
    posix.sigaddset(&set, .SIGUSR2)
    posix.sigaddset(&set, .SIGHUP)

    ts := posix.timespec {
        tv_sec = posix.time_t(timeout_ms / 1000),
        tv_nsec = c.long((timeout_ms % 1000) * 1_000_000),
    }

    info: posix.siginfo_t
    res := posix.sigtimedwait(&set, &info, &ts)

    if res > 0 {
        return posix.Signal(res), true
    }
    return nil, false
}
