# Odin Compilation & Runtime Assertions

**Tina mandates that bounds-checking remains enabled for all Isolate handler code. This is not a suggestion; it is the structural mechanism that prevents a single buggy Isolate from destroying an entire CPU core.**

## The Fault Taxonomy: Why We Need Bounds-Checking

In a shared-nothing, thread-per-core architecture, an Isolate shares its virtual memory space (the Grand Arena) with thousands of other Isolates on the same Shard. Tina relies on Odin’s runtime safety to enforce the isolation boundary between them.

Tina classifies memory faults into two tiers:

*   **Tier 2 (Contained):** The developer makes a mistake (e.g., array out-of-bounds). Odin’s bounds-checker catches it and triggers a runtime panic. Tina’s Trap Boundary intercepts the panic, tears down the offending Isolate, and the supervisor restarts it. The rest of the Shard never notices. **This requires bounds-checking to be enabled.**
*   **Tier 3 (Catastrophic):** If bounds-checking is disabled, that same mistake becomes a silent wild pointer write. It corrupts the adjacent Isolate's memory. Eventually, this triggers a hardware `SIGSEGV`, forcing a Level 2 Shard Recovery: all 10,000 Isolates on that core are wiped, and the entire Shard reboots.

## The Performance Reality

Odin’s bounds-checking adds ~0.1–5% overhead to hot loops. **Tina accepts this cost unconditionally.** 

The alternative — transforming a trivial, Isolate-contained logic bug (Tier 2) into a core-fatal memory corruption event (Tier 3) — is architecturally unacceptable.

### The Escape Hatch: Explicit Hot-Loop Bypass

If, and only if, profiling proves that bounds-checking is the primary bottleneck in a specific hot path, you may bypass it using Odin's `#no_bounds_check` directive for that specific block.

When you do this, you are explicitly accepting that any bug in that block elevates from a Tier 2 recoverable panic to a Tier 3 Shard-fatal crash. This must be justified and heavily commented in the code.

## Runtime Assertions (`-define:TINA_ASSERTS=true`)

Tina includes internal, framework-level assertions to validate structural invariants (e.g., ensuring `ctx_spawn` doesn't silently truncate initialization arguments). 

*   **Development/Testing:** Compile with `-define:TINA_ASSERTS=true`. This enables rigorous sanity checks that fail fast during local development.
*   **Production:** Compile without this flag. The framework assumes the developer has validated the structural logic via Deterministic Simulation Testing (DST) prior to deployment. 

> Note: `TINA_ASSERTS` controls framework-internal sanity checks. It does **not** disable Odin's standard bounds-checking, which must remain active in production.

## Tradeoffs Accepted

*   **We sacrifice 0.1–5% raw throughput to guarantee fault containment.** Bounds-checking is the firewall between Isolates on the same Shard.
*   **We require explicit developer discipline.** If a developer disables bounds-checking globally to win a micro-benchmark, they break Tina's fundamental isolation guarantee.
*   **We favor deterministic failure over silent corruption.** A caught panic is observable, countable, and recoverable. A wild memory write is none of these.
