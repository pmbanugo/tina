# Deterministic Simulation Testing (DST)

Tina's simulation mode replaces the OS clock, cross-shard transport, and I/O backend with deterministic substitutes. Everything runs single-threaded. Same seed + same `SystemSpec` = same execution = same outcome.

## Build and Run

Simulation mode is a compile-time flag. It strips all OS threading, signal handling, and platform I/O.

```sh
# Run all simulation tests
odin test . -define:TINA_SIM=true

# With debug assertions (structural invariant checks in non-simulation code paths)
odin test . -define:TINA_SIM=true -define:TINA_ASSERTS=true

# Run a specific test
odin test . -define:TINA_SIM=true -define:ODIN_TEST_NAMES=tina.test_ping_pong_simulation

# Type-check only (no link)
odin check . -define:TINA_SIM=true
```

The flag `TINA_SIM=true` sets `TINA_SIMULATION_MODE` to `true`, which gates all simulation-only code via `when TINA_SIMULATION_MODE`.

## Writing a Simulation Test

A simulation test is an `odin test` procedure that constructs a `SystemSpec` with a `SimulationConfig`, initializes a `Simulator`, runs it, and asserts on post-run state.

```odin
@(test)
test_my_scenario :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // 1. Define isolate types with init/handler functions
    types := [1]TypeDescriptor{
        {
            id = 0, slot_count = 10,
            stride = size_of(MyIsolate),
            soa_metadata_size = size_of(Isolate_Metadata),
            init_fn = my_init, handler_fn = my_handler,
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
        transfer_slot_size = 4096, timer_spoke_count = 1024,
        timer_entry_count = 1024, timer_resolution_ns = 1_000_000,
        fd_table_slot_count = 16, fd_entry_size = size_of(FD_Entry),
        fd_handoff_entry_count = 0,
        log_ring_size = 4096, supervision_groups_max = 16,
        scratch_arena_size = 65536,
    }

    // 5. Init and run
    sim: Simulator
    err := simulator_init(&sim, &spec, context.temp_allocator)
    testing.expect_value(t, err, mem.Allocator_Error.None)
    simulator_run(&sim)

    // 6. Assert on post-run state
    testing.expect_value(t, sim.termination_reason, Termination_Reason.Quiescent)
    shard := &sim.shards[0]
    // ... inspect shard.metadata, shard.counters, isolate memory, etc.
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
| `Generation_Monotonic`| No isolate generation is zero (reserved for `HANDLE_NONE`). |
| `FD_Table_Integrity`  | Active FD entries have non-zero generation and valid OS FD. |
| `FD_Handoff_Integrity`| Handoff table accounting: `free_count + in_flight == entry_count`. In-flight entries have valid fields. |
| `Sim_FD_Integrity`    | Simulated descriptor↔object ref counts match actual descriptors and pending ops (simulation only). |

Enable all with `CHECKER_FLAGS_ALL`. Disable all with `CHECKER_FLAGS_NONE`.

Checkers run:
1. Every `checker_interval_ticks` rounds during simulation.
2. Unconditionally at simulation termination (regardless of termination reason).

A checker violation stops the simulation immediately. The `Simulator.termination_reason` will be `.Checker_Violation`.

## User Checkers

Register application-level invariant checkers to verify domain logic during simulation.

```odin
balance_checker :: proc(shards: []Shard, tick: u64) -> Check_Result {
    total: i64 = 0
    for &shard in shards {
        for slot in 0 ..< shard.type_descriptors[ACCOUNT_TYPE_ID].slot_count {
            account := cast(^Account)_get_isolate_ptr(&shard, u16(ACCOUNT_TYPE_ID), u32(slot))
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

## Post-Run Inspection

After `simulator_run` returns, inspect:

```odin
sim.termination_reason  // .Ticks_Max, .Quiescent, or .Checker_Violation
sim.final_round         // last round executed

shard := &sim.shards[0]
shard.metadata[type_id].state[slot]       // isolate state
shard.metadata[type_id].generation[slot]  // handle generation
shard.counters                            // backpressure and I/O counters
```

The simulation prints a summary to stdout:

```
[SIM] Simulation complete: seed=0x..., rounds=847, termination=quiescent (no pending work or timers)
[SIM] Backpressure: mailbox_full=0, pool_exhaustion=0, ring_full=0, stale_delivery=0, quarantine=0
[SIM] I/O: stale_completions=1, buffer_exhaustions=0, transfer_exhaustions=0, transfer_stale=0
```

When a test fails, the seed in the summary is the reproduction key. Re-run with that seed to replay the exact same execution.

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
odin test . -define:TINA_SIM=true -define:ODIN_TEST_RANDOM_SEED=12345 \
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
