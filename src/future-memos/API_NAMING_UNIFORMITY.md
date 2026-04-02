# Future Memo: Config and Watchdog Naming Uniformity

## Status

Deferred design cleanup. No behavior change is proposed in this memo.

## Context

The recent supervision and shard-restart repair work changed several names:

- `child_count_static`
- `child_count_dynamic`
- `child_count_dynamic_max`
- `shard_restart_count`
- `shard_restart_window_ns`

That pass fixed the most awkward and highest-value naming problems on the repaired path. The remaining naming surface is now serviceable, but still not fully uniform across config, runtime state, watchdog policy, and recovery helpers.

This memo records what is still uneven, why it may matter later, and what a future cleanup could do.

## Why Consider a Future Sweep

The current code is correct, but the terminology is drawn from a few different layers:

- ADR terminology
- runtime implementation terminology
- watchdog policy terminology
- older field naming conventions

This leaves a few inconsistencies:

- some names are domain-first, such as `shard_restart_count`
- some names are metric-first, such as `restart_count_max`
- configured time windows and active runtime windows use different naming shapes
- helper names sometimes describe policy, and sometimes describe state transitions

None of that is a correctness problem on its own. The cost is cognitive:

- harder scanning when related concepts do not align visually
- higher chance of subtle misuse when config fields and runtime fields look more different than they really are
- more friction when adding new supervision or watchdog policy without a clear naming template

This matters most in Tina because the design relies on precise temporal semantics:

- restart budget
- recovery boundary
- quarantine state
- watchdog escalation

Those concepts should remain distinct in names as well as in behavior.

## Current Naming Friction

### 1. Mixed noun ordering

Examples:

- `shard_restart_count`
- `restart_count_max`

Both are readable, but they encode the subject in different positions.

### 2. Configured duration vs runtime window anchor

Examples:

- `window_duration_ticks`
- `shard_restart_window_ms`
- `window_start_tick`
- `shard_restart_window_ns`

These are all legitimate, but the shape differs depending on which subsystem owns the field.

### 3. Distinct lifecycle terms are not always visibly separated

The design has three separate concepts:

- `restart`: bounded budget and retry accounting
- `recovery`: trap-boundary return and Level 2 handling
- `quarantine`: dormant policy state after repeated failure

Future helper names and config additions should preserve that separation.

### 4. Watchdog policy surface could be more obviously grouped

`Watchdog_Config` currently mixes:

- polling cadence
- escalation thresholds
- shard restart budget
- quarantine terminal policy

The fields are fine, but the naming and grouping could become more systematic if that config grows.

## Principles for a Future Cleanup

If this is revisited, the cleanup should stay conservative:

- no semantic changes
- no hidden policy changes
- no renaming just for novelty
- preserve ADR vocabulary where it is already clear
- prefer names that make temporal state obvious

The cleanup should also keep the recent style direction:

- use `*_count` for cardinality
- use `*_index` for positions
- use `*_capacity_count` where capacity and live count differ
- use `*_window_*` consistently for budget windows

## Possible Future Actions

### Option A: Leave it as-is

Do nothing unless future work adds enough policy surface that inconsistency starts causing real confusion.

Use this option if:

- watchdog policy remains small
- the current naming feels stable in practice
- there is no immediate feature pressure in restart/quarantine policy

### Option B: Small terminology sweep

Apply a naming-only pass over supervision-adjacent config and helper names.

Candidate goals:

- choose one preferred noun order for restart-budget fields
- make configured durations read more consistently next to runtime window anchors
- align watchdog helper names with supervision helper naming patterns

Example areas:

- `config.odin`
- `bootstrap.odin`
- `bootstrap_shard.odin`
- `watchdog.odin`

This is the safest future cleanup if readability becomes a nuisance.

### Option C: Structured watchdog policy naming pass

Keep field names mostly intact, but reorganize `Watchdog_Config` and related helpers by concern:

- cadence and polling
- escalation thresholds
- shard restart budget
- quarantine policy

This improves readability without forcing a broad rename set.

### Option D: Full restart-policy vocabulary standardization

Do a broader pass only if Tina is about to add more policy features, for example:

- alternate quarantine strategies
- more explicit shard recovery controls
- operator-triggered shard restart commands
- more watchdog phases or diagnostics

In that case, define a naming template first, then apply it consistently.

## Recommended Trigger for Reopening This

Revisit this memo only when one of these happens:

- a new watchdog policy field is being added
- shard restart policy grows beyond the current max/window model
- a second operator recovery path is introduced
- config review shows repeated confusion between restart, recovery, and quarantine semantics

Without one of those triggers, the current naming is good enough.

## Suggested Decision Order for a Future Pass

1. Decide whether the cleanup is config-only or config-plus-runtime.
2. Decide whether noun order should be domain-first or metric-first for restart-budget names.
3. Decide whether configured duration fields should all use an explicit `*_window_duration_*` shape.
4. Rename helper functions only after the field vocabulary is fixed.
5. Run the full test matrix after the rename, with no behavior edits in the same patch.

## Recommendation

Do not spend more time on this now.

The important awkward name has already been fixed. A future naming pass is justified only if the policy surface grows or if repeated maintenance work shows the remaining inconsistency is slowing people down.
