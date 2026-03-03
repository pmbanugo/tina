* odin test src -strict-style 
* Anywhere we need to branch between simulation and production (like the Shard struct holding a pointer to the network), we will use when #config(TINA_SIM, false). You can pass -define:TINA_SIM=true when running odin test or odin run.

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
- sim_network.odin: contains the delay queue, the network structure, and the fault engine that injects chaos deterministically.
- tina_phase1_test.odin:  A ping-pong test verifying the implementation details for milestone in phase 1 (based on roadmap).
