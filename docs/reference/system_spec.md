# System Specification Reference

All configuration structs for booting a Tina system. Everything is immutable after `tina_start`.

Source file: `config.odin`.

---

## `SystemSpec`

The root boot specification for the entire Tina process.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `app_version` | `u32` | `0` | Application version tag. Informational. |
| `memory_init_mode` | `Memory_Init_Mode` | `.Production` | Memory initialization strategy. `.Development` lazy mode. No pinning, no NUMA policy, no pre-faulting. |
| `quarantine_policy` | `Quarantine_Policy` | `.Quarantine` | What happens when a Shard exceeds its restart budget. `.Quarantine` isolates it; `.Abort` terminates the process. |
| `init_timeout_ms` | `u32` | `0` | Timeout for Shard initialization phase (milliseconds). |
| `shutdown_timeout_ms` | `u32` | `0` | Timeout for graceful shutdown (milliseconds). |
| `safety_margin` | `f32` | `0` | Memory safety margin multiplier. |
| `watchdog` | `Watchdog_Config` | — | Watchdog thread configuration. |
| `dio` | `^Dio_Config` | `nil` | Direct I/O configuration. `nil` means DIO disabled. Currently reserved. |
| `types` | `[]TypeDescriptor` | — | **Required.** Registered Isolate types. 1–254 entries. |
| `shard_specs` | `[]ShardSpec` | — | **Required.** Per-Shard configurations. Length must equal `shard_count`. |
| `shard_count` | `u8` | — | **Required.** Number of Shards (OS threads). 1–255. |
| `timer_resolution_ns` | `u64` | — | **Required.** Timer wheel resolution in nanoseconds. Must be > 0. |
| `pool_slot_count` | `int` | — | **Required.** Message pool capacity. Must be a power of 2. |
| `reactor_buffer_slot_count` | `int` | `0` | Reactor I/O buffer pool slot count. Max 4094 (12-bit token field). |
| `reactor_buffer_slot_size` | `int` | `0` | Bytes per reactor buffer slot. |
| `transfer_slot_count` | `int` | `0` | Transfer buffer pool slot count. |
| `transfer_slot_size` | `int` | `0` | Bytes per transfer buffer slot. |
| `timer_spoke_count` | `int` | — | **Required.** Timer wheel spoke count. Must be a power of 2. |
| `timer_entry_count` | `int` | — | **Required.** Timer entry pool size. |
| `fd_table_slot_count` | `int` | `0` | FD table capacity per Shard. |
| `fd_entry_size` | `int` | `0` | Size of each FD entry. Use `size_of(tina.FD_Entry)`. |
| `log_ring_size` | `int` | — | **Required.** Log ring buffer capacity. Must be a power of 2. |
| `supervision_groups_max` | `int` | `0` | Max supervision groups per Shard. |
| `scratch_arena_size` | `int` | `0` | Scratch arena size in bytes. Must be >= the largest `TypeDescriptor.scratch_requirement_max`. |
| `default_ring_size` | `u32` | — | **Required.** Default cross-shard messaging channel capacity. Must be a power of 2, >= 16. |
| `ring_overrides` | `[]Ring_Override` | `nil` | Per-pair or per-shard ring size overrides. |
| `simulation` | `^SimulationConfig` | `nil` | Simulation mode config. Only present when compiled with `TINA_SIM=true`. |

---

## `ShardSpec`

Per-Shard (OS thread) configuration.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `shard_id` | `u8` | — | Unique Shard identifier. |
| `target_core` | `i32` | `-1` | CPU core to pin this Shard to. `-1` means no affinity (fallback to `shard_id`). |
| `root_group` | `Group_Spec` | — | Root of the supervision tree for this Shard. |

---

## `TypeDescriptor`

Defines the behavior, memory footprint, and lifecycle functions for a specific Isolate type.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | `u8` | — | Unique type ID. 0–254. ID 255 is reserved for supervision subgroups. |
| `slot_count` | `int` | — | Maximum concurrent instances of this type per Shard. Max: 1,048,575 (20-bit). |
| `stride` | `int` | — | Byte size of the Isolate struct. Use `size_of(MyIsolate)`. |
| `soa_metadata_size` | `int` | — | Size of per-slot Isolate metadata. Use `size_of(tina.Isolate_Metadata)`. |
| `working_memory_size` | `int` | `0` | Private working arena size per Isolate instance (bytes). |
| `scratch_requirement_max` | `int` | `0` | Maximum scratch arena bytes this type needs. `SystemSpec.scratch_arena_size` must be >= this. |
| `mailbox_capacity` | `u16` | `0` | Per-Isolate mailbox depth. |
| `budget_weight` | `u16` | `0` | Scheduling weight. Higher = more messages processed per tick. Default: 1. |
| `init_fn` | `Init_Fn` | — | `proc(self: rawptr, args: []u8, ctx: ^TinaContext) -> Effect`. Called once on spawn. |
| `handler_fn` | `Handler_Fn` | — | `proc(self: rawptr, message: ^Message, ctx: ^TinaContext) -> Effect`. Called on every message. |

---

## `Group_Spec`

Supervision group configuration. Defines restart strategy and children.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `strategy` | `Supervision_Strategy` | — | Restart strategy: `.One_For_One`, `.One_For_All`, `.Rest_For_One`. |
| `restart_count_max` | `u16` | — | Maximum restarts allowed within the window before escalation. Must be >= 1. |
| `window_duration_ticks` | `u32` | — | Restart window duration in ticks. Must be > 0. |
| `children` | `[]Child_Spec` | — | Static children. Each is either a `Static_Child_Spec` or a nested `Group_Spec`. |
| `child_count_dynamic_max` | `u16` | `0` | Maximum number of dynamically spawned children. > 0 implies dynamic group. Only valid with `.One_For_One` strategy. |

**`Child_Spec`** is a union:
```odin
Child_Spec :: union {
    Static_Child_Spec,
    Group_Spec,         // Nested supervision subtree.
}
```

---

## `Static_Child_Spec`

A statically declared child in the supervision tree. Spawned at boot and on restart.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type_id` | `u8` | — | Registered `TypeDescriptor.id`. Must reference a valid type. |
| `restart_type` | `Restart_Type` | — | `.permanent`, `.transient`, or `.temporary`. |
| `args_size` | `u8` | `0` | Byte count of serialized args within `args_payload`. |
| `args_payload` | `[MAX_INIT_ARGS_SIZE]u8` | `{}` | Serialized init args (max 64 bytes). Use `init_args_of` to populate. |

---

## `Spawn_Spec`

Runtime spawn configuration passed to `ctx_spawn`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `args_payload` | `[MAX_INIT_ARGS_SIZE]u8` | `{}` | Serialized init args. |
| `group_id` | `Supervision_Group_Id` | — | Target supervision group. Use `ctx_supervision_group_id(ctx)` or `SUPERVISION_GROUP_ID_NONE`. |
| `type_id` | `u8` | — | Registered `TypeDescriptor.id`. |
| `restart_type` | `Restart_Type` | — | `.permanent`, `.transient`, or `.temporary`. |
| `args_size` | `u8` | `0` | Byte count within `args_payload`. |
| `handoff_mode` | `Handoff_Mode` | `.Full` | FD ownership transfer mode (`.Full`, `.Read_Only`, `.Write_Only`). |
| `handoff_fd` | `FD_Handle` | `FD_HANDLE_NONE` | FD to hand off to the new Isolate. |

---

## `Watchdog_Config`

Configuration for the watchdog thread that monitors Shard health.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `check_interval_ms` | `u32` | `0` | How often the watchdog checks Shard liveness (milliseconds). |
| `shard_restart_window_ms` | `u32` | `0` | Time window for counting Shard restarts. |
| `shard_restart_max` | `u16` | `0` | Maximum Shard restarts within the window before quarantine. |
| `phase_2_threshold` | `u8` | `0` | Number of quarantined Shards before escalating to process-level action. |

---

## `Dio_Config`

Direct I/O configuration. Currently reserved — pass `nil` in `SystemSpec.dio`.

| Field | Type | Description |
|-------|------|-------------|
| `target_core` | `i32` | CPU core for the DIO thread. |
| `submission_ring_size` | `u32` | Submission ring capacity. |
| `completion_ring_size` | `u32` | Completion ring capacity. |

---

## `SimulationConfig`

Available only when compiled with `-define:TINA_SIM=true`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `seed` | `u64` | — | Deterministic PRNG seed. |
| `ticks_max` | `u64` | — | Maximum simulation ticks before termination. Must be > 0. |
| `single_threaded` | `bool` | `false` | Run all Shards on a single thread (deterministic interleaving). |
| `shuffle_shard_order` | `bool` | `false` | Randomize Shard execution order each tick. |
| `terminate_on_quiescent` | `bool` | `false` | Stop simulation when no Isolate has pending work. |
| `faults` | `FaultConfig` | `{}` | Fault injection configuration. |
| `builtin_checkers` | `Checker_Flags` | `{}` | Built-in invariant checkers to enable. |
| `user_checkers` | `[]Checker_Fn` | `nil` | User-defined checker functions. |
| `checker_interval_ticks` | `u32` | `0` | How often checkers run (in ticks). |

---

## `FaultConfig`

Fault injection rates and delays. Only meaningful when `TINA_SIM=true`. All `Ratio` fields with `numerator = 0` are disabled.

| Field | Type | Description |
|-------|------|-------------|
| `io_error_rate` | `Ratio` | Probability of I/O operation failure. |
| `io_delay_range_ticks` | `[2]u32` | `[min, max]` simulated I/O delay in ticks. |
| `network_drop_rate` | `Ratio` | Probability of inter-Shard message drop. |
| `network_delay_range_ticks` | `[2]u32` | `[min, max]` simulated network delay in ticks. |
| `network_partition_rate` | `Ratio` | Probability of network partition onset. |
| `network_partition_heal_rate` | `Ratio` | Probability of healing a partition. |
| `isolate_crash_rate` | `Ratio` | Probability of random Isolate crash. |
| `init_failure_rate` | `Ratio` | Probability of `init_fn` failure. |

**Validation rules:**
- `numerator > 0` requires `denominator > 0`.
- `numerator <= denominator`.
- For delay ranges: `min <= max`.

---

## Supporting Types

### `Ratio`

```odin
Ratio :: struct {
    numerator:   u32,
    denominator: u32,
}
```

`numerator = 0` means disabled. `numerator/denominator` is the probability.

### `Supervision_Strategy`

```odin
Supervision_Strategy :: enum u8 {
    One_For_One,   // Only the crashed child is restarted.
    One_For_All,   // All children are terminated and restarted.
    Rest_For_One,  // Crashed child and all children after it are restarted.
}
```

### `Restart_Type`

```odin
Restart_Type :: enum u8 {
    permanent,  // Always restarted.
    transient,  // Restarted only on crash (not normal exit).
    temporary,  // Never restarted.
}
```

### `Memory_Init_Mode`

```odin
Memory_Init_Mode :: enum u8 {
    Production,   // No extra initialization.
    Development,  // Zero-fill for debugging.
}
```

### `Quarantine_Policy`

```odin
Quarantine_Policy :: enum u8 {
    Quarantine,  // Isolate the failed Shard. Other Shards continue.
    Abort,       // Terminate the process.
}
```

### `Ring_Override`

Customize cross-shard messaging channel sizes for specific Shard pairs or directions.

```odin
Ring_Override :: struct {
    type:        Ring_Override_Type,  // .Pair, .All_Inbound_To, .All_Outbound_From
    source:      u8,                 // Source Shard ID (for .Pair and .All_Outbound_From).
    destination: u8,                 // Destination Shard ID (for .Pair and .All_Inbound_To).
    size:        u32,                // Ring capacity. Must be a power of 2, >= 16.
}
```

Last override wins (painter's algorithm).

### `Checker_Flags`

```odin
Checker_Flags :: bit_set[Checker_Flag; u16]

Checker_Flag :: enum u8 {
    Pool_Integrity,        // Verify message pool free-list consistency.
    Generation_Monotonic,  // Verify handle generations only increase.
}

CHECKER_FLAGS_ALL  :: Checker_Flags{.Pool_Integrity, .Generation_Monotonic}
CHECKER_FLAGS_NONE :: Checker_Flags{}
```

### `Check_Result`

```odin
Check_Result :: union {
    Check_Ok,         // struct {} — invariant holds.
    Check_Violation,  // struct { message: string } — invariant violated.
}
```

### `Checker_Fn`

```odin
Checker_Fn :: #type proc(shards: []Shard, tick: u64) -> Check_Result
```

---

## Enum Quick Reference

Scannable lookup for all configuration enums.

| Enum | Value | Meaning |
|------|-------|---------|
| **`Supervision_Strategy`** | | |
| | `.One_For_One` | Only the crashed child is restarted. |
| | `.One_For_All` | All children are torn down and restarted. |
| | `.Rest_For_One` | Crashed child and all children started after it are restarted. |
| **`Restart_Type`** | | |
| | `.permanent` | Always restarted, regardless of exit reason. |
| | `.transient` | Restarted only on crash. Clean exit is not restarted. |
| | `.temporary` | Never restarted. |
| **`Memory_Init_Mode`** | | |
| | `.Production` | No extra initialization. |
| | `.Development` | Zero-fill all memory for debugging. |
| **`Quarantine_Policy`** | | |
| | `.Quarantine` | Isolate the failed Shard. Other Shards continue. |
| | `.Abort` | Terminate the entire process. |
| **`Handoff_Mode`** | | |
| | `.Full` | Transfer both directions — parent loses all FD access. |
| | `.Read_Only` | Child gets read, parent retains write. |
| | `.Write_Only` | Child gets write, parent retains read. |
| **`Ring_Override_Type`** | | |
| | `.Pair` | Override a specific source → destination pair. |
| | `.All_Inbound_To` | Override all channels inbound to a destination Shard. |
| | `.All_Outbound_From` | Override all channels outbound from a source Shard. |

---

## Constraints & Validation

`SystemSpec` is validated at boot by `validate_system_spec`. A constraint violation halts the process before any Shard thread is spawned.

### Power-of-2 Requirements

These fields must be powers of 2 (1, 2, 4, 8, 16, 32, ...):

| Field | Minimum |
|-------|---------|
| `pool_slot_count` | — |
| `log_ring_size` | — |
| `timer_spoke_count` | — |
| `default_ring_size` | 16 |
| `Ring_Override.size` | 16 |

### Capacity Limits

| Field | Min | Max | Notes |
|-------|-----|-----|-------|
| `shard_count` | 1 | 255 | `len(shard_specs)` must equal `shard_count`. |
| `types` (length) | 1 | 254 | Type IDs must be unique and <= 254. ID 255 is reserved. |
| `TypeDescriptor.slot_count` | — | 1,048,575 | 20-bit slot index. |
| `reactor_buffer_slot_count` | — | 4,094 | 12-bit token field. |
| `timer_resolution_ns` | 1 | — | Must be > 0. |

### Supervision Constraints

- `restart_count_max` >= 1.
- `window_duration_ticks` > 0.
- Dynamic children (`child_count_dynamic_max > 0`) only valid with `.One_For_One` strategy.

### Arena Constraints

- `scratch_arena_size` >= the largest `TypeDescriptor.scratch_requirement_max` across all types.

### Simulation Constraints (when `TINA_SIM=true`)

- `ticks_max` > 0.
- Fault `Ratio`: `numerator > 0` requires `denominator > 0`. `numerator <= denominator`.
- Delay ranges: `min <= max`.

### `SystemSpecError`

```odin
SystemSpecError :: enum u8 {
    None,
    ValueOutOfBounds,              // Size/count too small or too large.
    ValueNotPowerOfTwo,            // Alignment/ring/pool constraint violated.
    DuplicateTypeId,               // Two TypeDescriptors share an ID.
    InvalidTypeId,                 // Child_Spec references unregistered type.
    InvalidSupervisionStrategy,    // Invalid strategy/dynamic combination.
    InvalidSupervisionIntensity,   // restart_count_max < 1 or window_duration_ticks == 0.
}
```

---

## Minimal Example

The simplest `SystemSpec` that passes validation and boots a single Isolate:

```odin
package main

import tina "../src"

MyIsolate :: struct {}

my_init :: proc(self: rawptr, args: []u8, ctx: ^tina.TinaContext) -> tina.Effect {
    return tina.Effect_Receive{}
}

my_handler :: proc(self: rawptr, msg: ^tina.Message, ctx: ^tina.TinaContext) -> tina.Effect {
    return tina.Effect_Receive{}
}

main :: proc() {
    types := [1]tina.TypeDescriptor{{
        id             = 0,
        slot_count     = 1,
        stride         = size_of(MyIsolate),
        soa_metadata_size = size_of(tina.Isolate_Metadata),
        init_fn        = my_init,
        handler_fn     = my_handler,
        mailbox_capacity = 16,
    }}

    children := [1]tina.Child_Spec{
        tina.Static_Child_Spec{type_id = 0, restart_type = .permanent},
    }

    root_group := tina.Group_Spec{
        strategy              = .One_For_One,
        restart_count_max     = 3,
        window_duration_ticks = 1000,
        children              = children[:],
    }

    shard_specs := [1]tina.ShardSpec{{shard_id = 0, root_group = root_group}}

    spec := tina.SystemSpec{
        shard_count             = 1,
        types                   = types[:],
        shard_specs             = shard_specs[:],
        timer_resolution_ns     = 1_000_000,
        pool_slot_count         = 1024,
        log_ring_size           = 4096,
        timer_spoke_count       = 1024,
        timer_entry_count       = 64,
        default_ring_size       = 16,
        scratch_arena_size      = 4096,
        fd_table_slot_count     = 16,
        fd_entry_size           = size_of(tina.FD_Entry),
        supervision_groups_max  = 4,
        reactor_buffer_slot_count = 16,
        reactor_buffer_slot_size  = 4096,
        transfer_slot_count     = 16,
        transfer_slot_size      = 4096,
        shutdown_timeout_ms     = 3000,
    }

    tina.tina_start(&spec)
}
```
