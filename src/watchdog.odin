package tina

import "core:fmt"
import "core:sync"
import "core:sys/posix"

watchdog_loop :: proc(configs: []Shard_Config, states:[]u8, spec: ^SystemSpec) {
    interval_ms := spec.watchdog.check_interval_ms
    if interval_ms == 0 do interval_ms = 500

    fmt.printfln("[SYSTEM] Process running. Watchdog active (interval: %v ms).", interval_ms)

    for {
        sig, sig_ok := os_wait_for_signal(interval_ms)

        if sig_ok {
            #partial switch sig {
            case .SIGTERM, .SIGINT:
                fmt.printfln("\n[WATCHDOG] Received signal %v. Initiating Graceful Shutdown...", sig)
                set_process_phase(.Shutting_Down)

                for i in 0..<spec.shard_count {
                    sync.atomic_store_explicit(&states[i], u8(Shard_State.Shutting_Down), .Release)
                }

                // TODO: Graceful shutdown drain loop logic will go here
                return

            case .SIGUSR2:
                fmt.printfln("[WATCHDOG] Received SIGUSR2. Recovering quarantined Shards.")
                // TODO: §6.5.5.2 Quarantine Recovery

            case .SIGHUP:
                fmt.printfln("[WATCHDOG] Received SIGHUP. (Reserved for future use).")
            }
        } else {
            // Timeout (EAGAIN) — No signal received. Do periodic heartbeat work!
            for i in 0..<spec.shard_count {
                state := cast(Shard_State)sync.atomic_load_explicit(&states[i], .Relaxed)
                if state == .Running {
                    // TODO: Heartbeat tick comparison and stall-count escalation (§6.5.1.4)
                }
            }
        }
    }
}
