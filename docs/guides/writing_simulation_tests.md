# Writing Simulation Tests

## Overview

Deterministic simulation testing lets you reproduce concurrency bugs by controlling all sources of non-determinism. Same seed + same config = same execution. This guide shows how to write a simulation test from scratch.

The key steps:
1. Define a **TestDriver** Isolate type that generates traffic.
2. (Optional) Define **user checkers** that verify application-level invariants.
3. Build a **simulation-specific SystemSpec** with `SimulationConfig`.
4. Compile with `-define:TINA_SIM=true` and run.

## Step 1: The TestDriver Isolate

A TestDriver is an ordinary Isolate. It generates traffic by sending messages, spawning children, and issuing `.call` requests. It's subject to the same scheduling, backpressure, and fault injection as everything else — no god mode.

```odin
package main

import tina "../src"
import "core:fmt"

// The TestDriver generates work by sending messages to Workers periodically.
TEST_DRIVER_TYPE: u8 : 100   // high ID to avoid collision with real types
TAG_DRIVER_TICK:  tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 100

TestDriver :: struct {
    round: u32,
}

driver_init :: proc(self_raw: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    // Register a timer to fire on the next tick — this drives the workload.
    tina.ctx_register_timer(ctx, 1_000_000, TAG_DRIVER_TICK)  // 1ms
    return tina.Effect_Receive{}
}

driver_handler :: proc(
    self_raw: rawptr,
    message: ^tina.Message,
    ctx: ^tina.TinaContext,
) -> tina.Effect {
    self := tina.self_as(TestDriver, self_raw, ctx)

    switch message.tag {
    case TAG_DRIVER_TICK:
        self.round += 1

        // Generate some work — send a message to a Worker, spawn something, etc.
        // This is application-specific. The point is: the TestDriver IS an Isolate.
        // It can crash, it can be backpressured, it can be restarted.

        // Re-arm the timer.
        tina.ctx_register_timer(ctx, 1_000_000, TAG_DRIVER_TICK)
        return tina.Effect_Receive{}

    case tina.TAG_SHUTDOWN:
        return tina.Effect_Done{}

    case:
        return tina.Effect_Receive{}
    }
}
```

**Key principle:** The TestDriver lives inside the simulation, not above it. If you overwhelm the system with messages, the TestDriver experiences the same backpressure real clients would. This tests realistic behavior, not idealized throughput.

## Step 2: User-Defined Checkers (Optional)

Checkers verify invariants across all Shards at regular intervals. They receive read-only access to Shard state.

```odin
// Example: verify that a conservation invariant holds.
// "The total number of active jobs across all Workers must not exceed MAX_CONCURRENT."
my_checker :: proc(shards: []tina.Shard, tick: u64) -> tina.Check_Result {
    // Walk all Shards and Isolates, count active jobs...
    // If the invariant is violated:
    // return tina.Check_Violation{message = "Too many concurrent jobs!"}

    return tina.Check_Ok{}
}
```

Checkers run every `checker_interval_ticks` rounds AND unconditionally at simulation termination. A violation halts the simulation and logs the seed for reproduction.

## Step 3: The Simulation SystemSpec

Build a boot spec that includes both your real Isolate types AND the TestDriver. Enable simulation via `SimulationConfig`.

```odin
main :: proc() {
    // ---- Real types + TestDriver ----
    types := [3]tina.TypeDescriptor{
        // Real application types (same as production)
        {
            id         = 0,
            slot_count = 10,
            stride     = size_of(WorkerIsolate),
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn    = worker_init,
            handler_fn = worker_handler,
            mailbox_capacity = 64,
        },
        {
            id         = 1,
            slot_count = 1,
            stride     = size_of(DispatcherIsolate),
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn    = dispatcher_init,
            handler_fn = dispatcher_handler,
            mailbox_capacity = 64,
        },
        // Simulation-only: TestDriver
        {
            id         = TEST_DRIVER_TYPE,
            slot_count = 1,
            stride     = size_of(TestDriver),
            soa_metadata_size = size_of(tina.Isolate_Metadata),
            init_fn    = driver_init,
            handler_fn = driver_handler,
            mailbox_capacity = 16,
        },
    }

    // Include the TestDriver in the supervision tree
    children := [2]tina.Child_Spec{
        tina.Static_Child_Spec{type_id = 1, restart_type = .permanent},  // Dispatcher
        tina.Static_Child_Spec{type_id = TEST_DRIVER_TYPE, restart_type = .permanent},
    }

    root_group := tina.Group_Spec{
        strategy              = .One_For_One,
        restart_count_max     = 20,
        window_duration_ticks = 50_000,
        children              = children[:],
        child_count_dynamic_max = 10,
    }

    shard_specs := [2]tina.ShardSpec{
        {shard_id = 0, root_group = root_group, target_core = -1},
        {shard_id = 1, root_group = root_group, target_core = -1},
    }

    // ---- Simulation configuration ----
    user_checkers := [1]tina.Checker_Fn{my_checker}

    sim_config := tina.SimulationConfig{
        seed                   = 0xDEADBEEF,       // the reproducibility key
        ticks_max              = 500_000,           // stop after 500K ticks
        single_threaded        = true,              // always true for DST
        shuffle_shard_order    = true,              // explore interleaving space
        terminate_on_quiescent = true,              // stop if nothing is happening
        faults = tina.FaultConfig{
            io_error_rate             = tina.Ratio{1, 200},      // 0.5% I/O errors
            network_drop_rate         = tina.Ratio{1, 100},      // 1% message drops
            network_partition_rate    = tina.Ratio{1, 10_000},   // rare partitions
            network_partition_heal_rate = tina.Ratio{1, 100},    // heal quickly
            isolate_crash_rate        = tina.Ratio{1, 500},      // 0.2% handler crashes
            init_failure_rate         = tina.Ratio{1, 1000},     // 0.1% init failures
        },
        builtin_checkers       = tina.CHECKER_FLAGS_ALL,
        user_checkers          = user_checkers[:],
        checker_interval_ticks = 100,
    }

    spec := tina.SystemSpec{
        shard_count           = 2,
        types                 = types[:],
        shard_specs           = shard_specs[:],
        timer_resolution_ns   = 1_000_000,
        pool_slot_count       = 1024,         // intentionally small — stress backpressure
        timer_spoke_count     = 256,
        timer_entry_count     = 256,
         log_ring_size         = 4096, // Logging Subsystem buffer size (power of 2)
        default_ring_size     = 16,
        scratch_arena_size    = 4096,
        fd_table_slot_count   = 16,
        fd_entry_size         = size_of(tina.FD_Entry),
        supervision_groups_max = 4,
        reactor_buffer_slot_count = 16,
        reactor_buffer_slot_size  = 4096,
        transfer_slot_count   = 8,
        transfer_slot_size    = 4096,
        shutdown_timeout_ms   = 3_000,
        simulation            = &sim_config,
    }

    tina.tina_start(&spec)
}
```

## Step 4: Build and Run

```sh
# Build with simulation mode enabled
odin build my_sim_test.odin -file -out:sim_test -define:TINA_SIM=true

# Run — output shows seed, fault counts, checker results
./sim_test
```

**To reproduce a failure:** Copy the seed from the output and paste it into `sim_config.seed`. Run again. You will get the exact same execution.

## Tips

**Starve the simulation.** Configure your `SystemSpec` with tiny message pools and mailbox capacities (e.g., `pool_slot_count = 1024`, `mailbox_capacity = 16`). This forces the system into constant backpressure, exercising the `.pool_exhausted` and `.mailbox_full` drop paths that rarely trigger in production — exposing hidden state-machine bugs in your retry and shed-load logic.

**Start with low fault rates.** Begin with `Ratio{1, 1000}` and increase gradually. High crash rates can overwhelm the supervision system before your application logic even runs.

**Use multiple seeds.** A single seed explores one execution path. Run your simulation in a loop with incrementing seeds to explore the state space:

```sh
for i in $(seq 1 1000); do
    ./sim_test -define:SEED=$i || echo "FAILURE at seed $i" && break
done
```

**Checkers are your oracle.** Without checkers, the simulation can only find crashes and deadlocks. With checkers, it finds *semantic* bugs — invariant violations that leave the system running but in a wrong state.

**Keep your TestDriver simple.** The TestDriver's job is to generate realistic traffic patterns, not to test every edge case. Let the fault injection do the edge-case exploration — that's what it's for.
