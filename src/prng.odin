package tina

import "core:testing"
import "core:mem"

Prng :: struct {
    state: u64,
    inc: u64,
}

prng_init :: proc(p: ^Prng, seed: u64) {
    p.state = 0
    p.inc = (seed << 1) | 1
    prng_step(p)
    p.state += seed
    prng_step(p)
}

prng_step :: proc(p: ^Prng) -> u32 {
    old_state := p.state
    p.state = old_state * 6364136223846793005 + p.inc
    xorshifted := u32(((old_state >> 18) ~ old_state) >> 27)
    rot := u32(old_state >> 59)
    return (xorshifted >> rot) | (xorshifted << ((32 - rot) & 31))
}

derive_shard_seed :: proc(master_seed: u64, shard_id: u16) -> u64 {
    z := master_seed ~ (u64(shard_id) * 0x9E3779B97F4A7C15)
    z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ~ (z >> 27)) * 0x94D049BB133111EB
    return z ~ (z >> 31)
}

// --- Deterministic Fault Math ---

// Evaluates a fractional probability using pure integer math
ratio_chance :: proc(r: Ratio, p: ^Prng) -> bool {
    if r.denominator == 0 || r.numerator == 0 do return false
    if r.numerator >= r.denominator do return true

    // Uses the fast range instead of modulo
    val := prng_uint_less_than(p, r.denominator)
    return val < r.numerator
}

// --- The PRNG Tree ---

Prng_Tree :: struct {
    master:       Prng,

    // System-wide domains
    scheduling:   Prng,
    network_drop: Prng,
    partition:    Prng,

    // Per-Shard domains
    shard_io:     []Prng,
    shard_crash:[]Prng,
}

// Initializes the entire tree from a single master seed.
// Note: Derivation order is STRICT and APPEND-ONLY to maintain determinism guarantees.
prng_tree_init :: proc(tree: ^Prng_Tree, seed: u64, shard_count: int, allocator: mem.Allocator) {
    prng_init(&tree.master, seed)

    // Helper to extract 64-bits from the 32-bit output of our Prng
    next_u64 :: proc(p: ^Prng) -> u64 {
        low := u64(prng_step(p))
        high := u64(prng_step(p))
        return (high << 32) | low
    }

    // Fixed Derivation Order
    prng_init(&tree.scheduling, next_u64(&tree.master))
    prng_init(&tree.network_drop, next_u64(&tree.master))
    prng_init(&tree.partition, next_u64(&tree.master))

    tree.shard_io = make([]Prng, shard_count, allocator)
    tree.shard_crash = make([]Prng, shard_count, allocator)

    // Derive per-shard PRNGs sequentially
    for i in 0..<shard_count {
        prng_init(&tree.shard_io[i], next_u64(&tree.master))
        prng_init(&tree.shard_crash[i], next_u64(&tree.master))
    }
}

// Returns a random u32 in the range[0, bound)
prng_uint_less_than :: proc(p: ^Prng, bound: u32) -> u32 {
    if bound == 0 do return 0
    // Daniel Lemire's fast range algorithm (avoids modulo)
    random32 := prng_step(p)
    return u32((u64(random32) * u64(bound)) >> 32)
}

// === TEST ===
@(test)
test_prng_determinism :: proc(t: ^testing.T) {
    master_seed: u64 = 0x123456789ABCDEF0
    seed1 := derive_shard_seed(master_seed, 1)
    seed2 := derive_shard_seed(master_seed, 2)

    // Ensure different shards get different seeds from the same master seed
    testing.expect(t, seed1 != seed2, "Different shards must derive different seeds")

    prng1 := Prng{}
    prng2 := Prng{}
    prng_init(&prng1, seed1)
    prng_init(&prng2, seed1) // Init with the exact same seed

    for _ in 0..<100 {
        v1 := prng_step(&prng1)
        v2 := prng_step(&prng2)
        testing.expect_value(t, v1, v2)
    }
}
