* odin test src -strict-style 

---
- config.odin: Defines the `SystemSpec`, `ShardSpec`, and `TypeDescriptor` along with memory projection utilities.
- handle.odin: Implements the 64-bit packed handle referencing Isolates and cross-shard resources.
- arena.odin: Implements the fixed `mmap` backing that all shard resources will be carved from sequentially.
- pool.odin: A Gingerbill Part 4 strictly fixed intrusive free-list allocator implementation, designed for zero-fragmentation constant time pool acquisitions.
- prng.odin: Permuted Congruential Generator logic for fully deterministic, tree-derived shard entropy mapping.
- api.odin: contains the top-level API surface: Context, Effects, and public Enums.
- mailbox.odin: Defines the Message structures and the 128-byte Message_Envelope.
- logging.odin: Tina's logger.
- timer.odin: Fixed increment clock and array-backed wheel.
- shard.odin: The core scheduler loop, SOA implementation (via #soa), and the Active Context API (ctx_send, ctx_spawn).
- tina_phase1_test.odin:  A ping-pong test verifying the implementation details for milestone in phase 1 (based on roadmap).
