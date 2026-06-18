# Deterministic Simulation Testing (DST)

Tina's simulation mode replaces the OS clock, cross-shard transport, and I/O backend with deterministic substitutes. Same seed + same `SystemSpec` = same execution = same outcome.

## Build and Run

Simulation mode is a compile-time flag. It strips all OS threading, signal handling, and platform I/O.

```sh
# Run all simulation tests
odin test . -define:TINA_SIM=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# With debug assertions (structural invariant checks in non-simulation code paths)
odin test . -define:TINA_SIM=true -define:TINA_ASSERTS=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# From the repository root, run the same simulation coverage under AddressSanitizer
odin test tests/ -all-packages -define:TINA_SIM=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -sanitize:address

# Run a specific test
odin test . -define:TINA_SIM=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_NAMES=tina.test_ping_pong_simulation

# Type-check only (no link)
odin check . -define:TINA_SIM=true
```

The flag `TINA_SIM=true` sets `TINA_SIMULATION_MODE` to `true`, which gates all simulation-only code via `when TINA_SIMULATION_MODE`.

## Sanitizer Testing Strategy

Sanitizers are a diagnostic lane, not a replacement for deterministic simulation. DST explores schedules, failures, backpressure, and recovery with replayable seeds. Sanitizers instrument concrete execution to catch memory and threading bugs that a checker may not encode. Tina uses both because they stress different invariants.

CI keeps the normal platform and simulation suites as the portability baseline, then adds a Linux sanitizer matrix:

| Lane | Required? | Why it exists |
|------|-----------|---------------|
| Platform + `-sanitize:address` | Yes | Catches stack/global/heap memory faults in the non-DST backend and application-facing APIs. |
| Simulation + `-sanitize:address` | Yes | Runs deterministic workloads with ASan so a failing seed can be replayed while preserving the same simulated clock, network, and I/O order. |
| Platform + `-sanitize:thread` | Yes | Catches data races in any test that exercises real OS threads, atomics, or cross-shard runtime paths. |
| Platform + `-sanitize:memory` | Experimental | Linux/FreeBSD-only lane for uninitialized reads around raw OS/FFI boundaries and explicit non-zeroed allocation paths. Odin's zero-is-initialized rule makes this lower signal than ASan. |
| Simulation + `-sanitize:memory` | Experimental | Checks the single-threaded DST backend for uninitialized reads in pure framework/application state. |

ThreadSanitizer is intentionally not part of the simulation lane today. Simulation mode is single-threaded by design, so TSan adds little signal there, and tests that deliberately corrupt checker state are not a good race-detection workload. Use TSan on non-DST tests that actually start Tina shards or exercise cross-shard communication.

Sanitizer runs set `ODIN_TEST_THREADS=1`. This keeps the Odin test runner from becoming the concurrency workload under inspection; tests that intentionally create Tina runtime threads still do so explicitly.

Local commands from the repository root:

```sh
# Platform backend with ASan
odin test tests/ -all-packages -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -sanitize:address

# Simulation backend with ASan
odin test tests/ -all-packages -define:TINA_SIM=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -sanitize:address

# Platform backend with TSan
odin test tests/ -all-packages -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -sanitize:thread

# Linux/FreeBSD only: MSan
odin test tests/ -all-packages -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -sanitize:memory
```

AddressSanitizer needs one extra Tina-specific design step to reach full value. The normal ASan runtime sees the Grand Arena as one large valid allocation; it cannot know that an isolate slot, message envelope, receive buffer, staging slot, or transfer slot is logically freed while still inside that allocation. Odin's `base:sanitizer` package exposes `address_poison*` and `address_unpoison*` procedures for this exact problem.

Future allocator instrumentation should follow these rules:

1. Poison only in sanitizer builds; production and normal tests must pay zero cost.
2. Preserve intrusive free-list metadata. For message and I/O slot pools, keep the free-list word addressable while poisoning the rest of the free slot payload, then unpoison the whole slot immediately before allocation and zeroing.
3. Poison typed isolate memory when the metadata state becomes `.Unallocated`; unpoison it before `init_handler` receives `self`. The free-list state lives in SOA metadata, so the isolate payload can be fully poisoned while free.
4. Poison working-memory slices together with their owning isolate slot. Scratch memory is turn-scoped and should be considered separately because nested init/spawn turns share the same scratch arena with offset restoration.
5. Keep sanitizer hooks out of the hot path unless `ODIN_SANITIZER_FLAGS` contains the relevant sanitizer. The hook shape should be small and direct enough that the optimizer erases it in non-sanitized builds.
6. If a sanitizer report occurs in a DST run, treat the printed seed as the reproduction key and rerun the same sanitizer command with `ODIN_TEST_RANDOM_SEED` or a pinned `SimulationConfig.seed`.

## Writing a Simulation Test

A simulation test is an `odin test` procedure that constructs a `SystemSpec` with a `SimulationConfig`, initializes a `Simulator`, runs it, and asserts on post-run state.

```odin
@(test)
test_my_scenario :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // 1. Define isolate types with init/handler functions
    types := [1]IsolateTypeDescriptor{
        {
            id = 0, slot_count = 10,
            stride = size_of(MyIsolate),
            soa_metadata_size = size_of(Isolate_Metadata),
            init_handler = my_init, handler_fn = my_handler,
        },
    }

    // 2. Define supervision tree
    children := [1]Child_Spec{
        Static_Child_Spec{type_id = 0, restart_type = .permanent},
    }
    root_group := Group_Spec{
        strategy = .One_For_One,
        restart_count_max = 3, window_duration_ticks = 1000,
        children = children[:],
        child_count_dynamic_max = 10,
    }
    shard_specs := [1]ShardSpec{{shard_id = 0, root_group = root_group}}

    // 3. Configure simulation
    sim_config := SimulationConfig{
        seed                   = t.seed,  // or a fixed seed for reproducibility
        ticks_max              = 10_000,
        terminate_on_quiescent = true,
        builtin_checkers       = CHECKER_FLAGS_ALL,
        checker_interval_ticks = 100,
    }

    // 4. Build SystemSpec
    spec := SystemSpec{
        shard_count = 1, types = types[:],
        shard_specs = shard_specs[:], simulation = &sim_config,
        pool_slot_count = 1024, reactor_buffer_slot_count = 8,
        reactor_buffer_slot_size = 4096, transfer_slot_count = 4,
        transfer_slot_size = 4096,
        timer_entry_count = 1024, timer_resolution_ns = 1_000_000,
        fd_table_slot_count = 16, fd_entry_size = size_of(FD_Entry),
        fd_handoff_entry_count = 0,
        log_ring_size = 4096, supervision_groups_max = 16,
        scratch_arena_size = 65536,
    }

    // 5. Init and run
    sim: Simulator
    error := simulator_init(&sim, &spec, context.temp_allocator)
    testing.expect_value(t, error, mem.Allocator_Error.None)
    simulator_run(&sim)

    // 6. Assert on post-run state
    testing.expect_value(t, sim.termination_reason, Termination_Reason.Quiescent)
    shard := &sim.shards[0]
    // ... inspect shard.metadata, shard.counters, and diagnostics only.
    // Do not read isolate payload memory after simulator_run returns.
}
```

Your isolate types generate traffic and exercise the system under test. There is no privileged injection API — workload isolates are subject to the same scheduling, backpressure, and fault injection as everything else.

## SimulationConfig Reference

| Field                    | Type           | Zero value / default | Purpose |
|--------------------------|----------------|----------------------|---------|
| `seed`                   | `u64`          | required             | Master PRNG seed. All non-determinism derives from this. |
| `ticks_max`              | `u64`          | required (> 0)       | Maximum rounds before termination. |
| `terminate_on_quiescent` | `bool`         | `false`              | Stop when no shard has pending work, timers, or in-flight network messages. |
| `shuffle_shard_order`    | `bool`         | `false`              | PRNG-shuffle shard execution order per round. |
| `single_threaded`        | `bool`         | `false`              | Reserved. Simulation is always single-threaded today. |
| `faults`                 | `FaultConfig`  | all disabled         | Fault injection rates. See below. |
| `builtin_checkers`       | `Checker_Flags`| empty (none enabled) | Which framework checkers run. Use `CHECKER_FLAGS_ALL` to enable all. |
| `user_checkers`          | `[]Checker_Fn` | empty                | Application-level invariant checkers. |
| `checker_interval_ticks` | `u32`          | `0` (disabled)       | Run checkers every N rounds. All checkers also run unconditionally at termination. |

## Fault Injection

All fault rates use `Ratio{numerator, denominator}` with pure integer arithmetic. `Ratio{0, 0}` means disabled. `Ratio{1, 100}` means 1% probability per event.

```odin
sim_config.faults = FaultConfig{
    isolate_crash_rate          = Ratio{1, 100},   // 1% crash per handler invocation
    init_failure_rate           = Ratio{1, 200},   // 0.5% init failure
    io_error_rate               = Ratio{1, 50},    // 2% I/O error per completion
    io_delay_range_ticks        = {5, 20},         // completions delayed 5–20 ticks
    network_drop_rate           = Ratio{1, 1000},  // 0.1% message drop
    network_delay_range_ticks   = {0, 5},          // per-channel delivery delay
    network_partition_rate      = Ratio{1, 500},   // partition creation per round
    network_partition_heal_rate = Ratio{1, 10},    // partition heal per round
}
```

Validation rules:
- Numerator > 0 requires denominator > 0.
- Numerator must not exceed denominator.
- Delay range min must be ≤ max (when max > 0).

## Structural Checkers

Built-in checkers verify framework invariants at configurable intervals.

| Flag                  | What it checks |
|-----------------------|----------------|
| `Pool_Integrity`      | `free_count` does not exceed `slot_count` for message pool, reactor buffer pool, and transfer pool. |
| `Generation_Monotonic`| No isolate generation is zero (reserved for `ISOLATE_HANDLE_NONE`). |
| `FD_Table_Integrity`  | Active FD entries have non-zero generation and valid OS FD. |
| `FD_Handoff_Integrity`| Handoff table accounting: `free_count + in_flight == entry_count`. In-flight entries have valid fields. |
| `Sim_FD_Integrity`    | Simulated descriptor↔object ref counts match actual descriptors and pending ops (simulation only). |
| `State_Transition_Integrity` | `io_awaiting_count`, dispatchable bitmaps, per-type dispatchable counts, and type summary words are consistent with metadata state and flags. |

Enable all with `CHECKER_FLAGS_ALL`. Disable all with `CHECKER_FLAGS_NONE`.

Checkers run:
1. Every `checker_interval_ticks` rounds during simulation.
2. Unconditionally at simulation termination (regardless of termination reason).

A checker violation stops the simulation immediately. The `Simulator.termination_reason` will be `.Checker_Violation`.

## User Checkers

Register application-level invariant checkers to verify domain logic during simulation.

User checkers run while the simulation is active, so they may inspect live isolate payload memory through the sanctioned helper. They must not read payload memory after `simulator_run` returns; that memory is logically freed and may be ASan-poisoned.

```odin
balance_checker :: proc(shards: []Shard, tick: u64) -> Check_Result {
    total: i64 = 0
    for &shard in shards {
        for slot in 0 ..< shard.type_descriptors[ACCOUNT_TYPE_ID].slot_count {
            account := cast(^Account)sim_checker_get_live_isolate_ptr(
                &shard,
                ACCOUNT_TYPE_ID,
                Isolate_Slot_Index(slot),
            )
            if account == nil {
                continue // slot is not live at this tick
            }
            total += account.balance
        }
    }
    if total != INITIAL_TOTAL {
        return Check_Violation{message = "Balance conservation violated"}
    }
    return nil
}

user_checkers := [1]Checker_Fn{balance_checker}
sim_config.user_checkers = user_checkers[:]
```

User checkers receive read-only access to shard state. Return `nil` for OK, `Check_Violation{message = "..."}` for failure.

## Determinism

Same seed + same `SystemSpec` = identical execution. This is enforced by:

- Single-threaded round-based execution (no OS threads, no atomics).
- Per-domain PRNG tree derived from the master seed.
- Integer-ratio fault probabilities (no floating point).
- Deterministic shard execution order (fixed ascending, or PRNG-shuffled).
- Per-channel FIFO in the simulated network (no message overtaking).

To verify determinism, run the same simulation twice and compare all observable state:

```odin
result1 := run_simulation(seed)
result2 := run_simulation(seed)
assert(result1 == result2)
```

## How Tests Observe Simulation Results

After `simulator_run` returns, tests must not read isolate payload memory. Free slots are ASan-poisoned and live slots may have been reclaimed. Instead, tests observe results through:

1. **Metadata SOA** — state, generation, flags, inbox counts, pending correlation, I/O fields.
2. **Counters** — backpressure, I/O, transfer, and handoff counters on `Shard_Counters`.
3. **Simulation diagnostic table** — scalar facts written by handlers while payload memory is live.
4. **Checker results** — built-in and user checker violations.

### Simulation Diagnostics

Handlers write scalar diagnostic records using the simulation-only API:

```odin
DIAG_PING_COUNT: Diagnostic_Field_Id : 0

ping_handler :: proc(self: rawptr, message: ^Message) -> Isolate_Transition {
    ping := cast(^PingIsolate)self
    ping.count += 1
    ctx_test_diagnostic_write_u64(DIAG_PING_COUNT, u64(ping.count))
    // ...
}
```

Tests read the records after `simulator_run`:

```odin
shard_test_diagnostic_expect_u64(
    t,
    shard,
    PING_TYPE_ID,
    0,
    DIAG_PING_COUNT,
    100,
)
```

The diagnostic table is dense, append-only, and keyed by `(isolate_type_id, slot_index, field_id)`. It stores only `u64` scalars — no pointers, slices, strings, or payload snapshots. Capacity defaults to 64 records per shard; large tests can override it:

```odin
sim_config.diagnostic_record_count_per_shard = 400
```

This is used by tests such as the fairness test, where 300 workers each write a run-count diagnostic.

### During-Run Payload Inspection

User checkers run during the simulation while payload memory is still live. If a checker must inspect full isolate payload state, use the sanctioned helper:

```odin
account := cast(^Account)sim_checker_get_live_isolate_ptr(
    &shard,
    ACCOUNT_TYPE_ID,
    Isolate_Slot_Index(slot),
)
```

This helper returns `nil` if the slot is `.Unallocated` so the checker does not read poisoned memory. It is only valid inside a checker or other during-run context.

## Post-Run Inspection

After `simulator_run` returns, inspect:

```odin
sim.termination_reason  // .Ticks_Max, .Quiescent, or .Checker_Violation
sim.final_round         // last round executed

shard := &sim.shards[0]
shard.metadata[type_id]._state[slot]       // isolate state
shard.metadata[type_id].generation[slot]   // handle generation
shard.counters                             // backpressure and I/O counters
```

The simulation prints a summary to stdout:

```
[SIM] Simulation complete: seed=0x..., rounds=847, termination=quiescent (no pending work or timers)
[SIM] Backpressure: mailbox_full=0, pool_exhaustion=0, ring_full=0, stale_delivery=0, quarantine=0
[SIM] I/O: stale_completions=1, buffer_exhaustions=0, transfer_exhaustions=0, transfer_stale=0
```

When a test fails, the seed in the summary is the reproduction key. Re-run with that seed to replay the exact same execution.

## Test Fixtures for Non-Simulation Unit Tests

Unit tests that need a `Shard` must use the `Test_Shard_Fixture` builder instead of allocating a `Shard` directly. The fixture owns the Grand Arena and records which subsystems were actually initialized, so teardown is precise and production lifetime rules are preserved.

```odin
fixture := test_shard_fixture_init(
    Test_Shard_Spec{
        type_count  = 1,
        slot_counts = {4},
        subsystems  = {.Metadata, .Dispatchable, .Message_Pool},
    },
)
defer test_shard_fixture_deinit(fixture)

shard := &fixture.shard
```

Declare only the subsystems the test needs:

| Subsystem | Provides |
|-----------|----------|
| `Metadata` | Mandatory base: type descriptors, isolate memory, SOA metadata, free lists. |
| `Dispatchable` | Per-slot and per-type dispatchable bitmaps. |
| `Message_Pool` | Framework-owned message envelope pool. |
| `Timer_Wheel` | Timer entries and armed bitmap. |
| `Reactor` | FD table, receive/staging pools, and backend. |
| `Transfer_Pool` | Large-payload transfer buffer pool. |
| `Handoff_Table` | FD handoff entries for cross-isolate socket transfer. |
| `Supervision` | Supervision group table. |
| `Scratch` | Scratch arena backing memory. |

Activate and release isolate slots through the ownership helpers:

```odin
test_shard_slot_activate(fixture, make_handle(0, 0, 2, 1), .Runnable)
// ... exercise the slot ...
test_shard_slot_release(fixture, 0, 2)
```

Rules:

- Do not edit `isolate_free_heads`, `generation`, or `._state` directly in tests.
- Do not allocate `new(Shard)` except in sanctioned hydrate-shard tests marked with `ALLOWLIST_FILE(hydrate_shard_fixture)`.
- Manual free-list mutation is not a fixture API; use `test_shard_slot_activate` and `test_shard_slot_release`.
- Tests that need special I/O metadata may set those fields after activation, but activation itself must go through `test_shard_slot_activate`.
- Initially free fixture slots are ASan-poisoned in sanitizer builds; activation unpoisons payload and working memory, and release re-poisons them.

## Sequential Verification Gate

Before resuming ASan feature work, collect verification evidence from these commands run **sequentially** in the same workspace. Do not run multiple `odin test` invocations concurrently when collecting gate evidence; the runner may share build/test artifacts.

```sh
# 1. Structural hygiene (no Odin toolchain required)
scripts/check_test_hygiene.sh

# 2. Normal test suite
odin test tests/ -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_FANCY=false

# 3. Simulation test suite
odin test tests/ -all-packages -define:TINA_SIM=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_FANCY=false

# 4. Single-thread simulation suite (sanitizer-runner configuration)
odin test tests/ -all-packages -define:TINA_SIM=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_FANCY=false
```

## Reproducing Failures

```odin
// Pin the seed from a failing run
sim_config.seed = 0xDEADBEEF  // from the [SIM] summary output
```

Odin's test runner also prints its random seed:

```
The random seed sent to every test is: 12345. Set with -define:ODIN_TEST_RANDOM_SEED=n.
```

To reproduce a test that uses `t.seed`:

```sh
odin test . -define:TINA_SIM=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
    -define:ODIN_TEST_RANDOM_SEED=12345 \
    -define:ODIN_TEST_NAMES=tina.test_my_failing_test
```

## File Layout

| File | Responsibility |
|------|---------------|
| `simulator.odin` | `Simulator` struct, `simulator_init`, `simulator_run`, summary reporting |
| `simulation_clock.odin` | `simulator_is_globally_idle` (quiescence + fast-forward) |
| `simulation_faults.odin` | `FaultEngine`, per-round partition/heal/jitter |
| `simulation_checkers.odin` | Built-in and user checker execution |
| `sim_network.odin` | `SimulatedNetwork`, per-channel delay queues, FIFO transport |
| `io_backend_simulated.odin` | Simulated I/O backend (deterministic completions) |
| `config.odin` | `SimulationConfig`, `FaultConfig`, `Ratio`, `Checker_Flags`, validation |

Test files:

| File | Coverage |
|------|----------|
| `simulated_test.odin` | Shared fixtures (ping-pong types) and basic ping-pong test |
| `simulated_test_determinism.odin` | Replay determinism, seed divergence under faults |
| `simulated_test_fairness.odin` | Intra-type dispatch fairness (starvation prevention) |
| `simulated_test_scheduling.odin` | Multi-shard tick uniformity |
| `simulated_test_network.odin` | FIFO ordering, partition, heal, delay semantics |
| `simulated_test_io.odin` | Stale completion reclamation, buffer teardown, shutdown priority |
| `simulated_test_supervision.odin` | Temporary child exit, mixed subgroups, restart intensity |
| `simulated_test_harness.odin` | Termination reasons, checker execution, disabled checkers |
