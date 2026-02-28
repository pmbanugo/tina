* odin test src -strict-style 

---
- src/config.odin: Defines the `SystemSpec`, `ShardSpec`, and `TypeDescriptor` along with memory projection utilities.
- src/handle.odin: Implements the 64-bit packed handle referencing Isolates and cross-shard resources.
- src/arena.odin: Implements the fixed `mmap` backing that all shard resources will be carved from sequentially.
- src/pool.odin: A Gingerbill Part 4 strictly fixed intrusive free-list allocator implementation, designed for zero-fragmentation constant time pool acquisitions.
- src/prng.odin: Permuted Congruential Generator logic for fully deterministic, tree-derived shard entropy mapping.
- src/test_phase0.odin: Wires together all functionality required for verification. Exits gracefully. — strictly added to verify phase 1 implementation
