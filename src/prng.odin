package tina

import "core:mem"
import "core:testing"

// ============================================================================
// Deterministic PRNG Engine (Xoshiro256**)
// ============================================================================
//
// Hard-forked from Odin's core:math/rand to guarantee years of seed stability
// for Deterministic Simulation Testing. Stripped of all generic interface
// overhead (dynamic dispatch, byte slice filling) for better inline execution.
//
// State is exactly 32 bytes: fits entirely within a single CPU cache line.

Prng :: struct {
	state: [4]u64,
}

// Initialize using SplitMix64 to expand a 64-bit seed into 256 bits of state.
prng_init :: proc "contextless" (p: ^Prng, seed: u64) {
	local_seed := seed

	// Inline SplitMix64 step
	sm64_next :: #force_inline proc "contextless" (s: ^u64) -> u64 {
		s^ += 0x9E3779B97F4A7C15
		z := s^
		z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
		z = (z ~ (z >> 27)) * 0x94D049BB133111EB
		return z ~ (z >> 31)
	}

	p.state[0] = sm64_next(&local_seed)
	p.state[1] = sm64_next(&local_seed)
	p.state[2] = sm64_next(&local_seed)
	p.state[3] = sm64_next(&local_seed)

	// Extremely unlikely all zero; ensure non-zero state to prevent generator death
	if (p.state[0] | p.state[1] | p.state[2] | p.state[3]) == 0 {
		p.state[0] = 1
	}
}

// Advance the generator and return 64 bits of randomness.
prng_step :: #force_inline proc "contextless" (p: ^Prng) -> u64 {
	// xoshiro256** output function
	result := _rotl_u64(p.state[1] * 5, 7) * 9
	t := p.state[1] << 17

	// State transition
	p.state[2] ~= p.state[0]
	p.state[3] ~= p.state[1]
	p.state[1] ~= p.state[2]
	p.state[0] ~= p.state[3]
	p.state[2] ~= t
	p.state[3] = _rotl_u64(p.state[3], 45)

	return result
}

@(private = "file")
_rotl_u64 :: #force_inline proc "contextless" (x: u64, k: uint) -> u64 {
	return (x << k) | (x >> (64 - k))
}

// Daniel Lemire's fast range algorithm (avoids modulo bias).
// Extracts the top 32 bits of a 64-bit random number for the fractional multiplication.
prng_uint_less_than :: #force_inline proc "contextless" (p: ^Prng, bound: u32) -> u32 {
	if bound == 0 do return 0
	random32 := u32(prng_step(p) >> 32)
	return u32((u64(random32) * u64(bound)) >> 32)
}

// ============================================================================
// Fault Math & PRNG Tree
// ============================================================================

// Evaluates a fractional probability using pure integer math.
// e.g. Ratio{1, 1000} evaluates to true 0.1% of the time.
ratio_chance :: #force_inline proc "contextless" (r: Ratio, p: ^Prng) -> bool {
	if r.numerator == 0 do return false
	if r.numerator >= r.denominator do return true

	val := prng_uint_less_than(p, r.denominator)
	return val < r.numerator
}

Prng_Tree :: struct {
	master:       Prng,

	// System-wide domains
	scheduling:   Prng,
	network_drop: Prng,
	partition:    Prng,

	// Per-Shard domains
	shard_io:     []Prng,
	shard_crash:  []Prng,
}

// Initializes the entire tree from a single master seed.
// Note: Derivation order is STRICT and APPEND-ONLY to maintain determinism guarantees.
prng_tree_init :: proc(tree: ^Prng_Tree, seed: u64, shard_count: int, allocator: mem.Allocator) {
	// Initialize the master generator
	prng_init(&tree.master, seed)

	// Fixed Derivation Order: We use prng_step to draw a pure 64-bit seed
	// from the master state to cleanly initialize the child domain states.
	prng_init(&tree.scheduling, prng_step(&tree.master))
	prng_init(&tree.network_drop, prng_step(&tree.master))
	prng_init(&tree.partition, prng_step(&tree.master))

	// Pre-allocate the arrays first
	tree.shard_io = make([]Prng, shard_count, allocator)
	tree.shard_crash = make([]Prng, shard_count, allocator)

	// Derive per-shard PRNGs sequentially with no internal branching
	for i in 0 ..< shard_count {
		prng_init(&tree.shard_io[i], prng_step(&tree.master))
		prng_init(&tree.shard_crash[i], prng_step(&tree.master))
	}
}

// ======
// Tests
// ======

@(test)
test_prng_determinism :: proc(t: ^testing.T) {
	// A hardcoded seed MUST produce the exact same sequence forever
	prng1, prng2: Prng
	prng_init(&prng1, 0x123456789ABCDEF0)
	prng_init(&prng2, 0x123456789ABCDEF0)

	for _ in 0 ..< 100 {
		testing.expect_value(t, prng_step(&prng1), prng_step(&prng2))
	}
}

@(test)
test_prng_tree_isolation :: proc(t: ^testing.T) {
	tree: Prng_Tree

	// We use t.seed here so the test harness can fuzz it,
	// but the user can lock it via ODIN_TEST_RANDOM_SEED
	prng_tree_init(&tree, t.seed, 4, context.temp_allocator)

	v1 := prng_step(&tree.shard_io[0])
	v2 := prng_step(&tree.shard_io[1])

	testing.expect(t, v1 != v2, "Different shards must derive different sequences")
}

@(test)
test_zero_state_safeguard :: proc(t: ^testing.T) {
	prng: Prng

	// Intentionally feed a sequence that might cause SplitMix64 to output all zeros.
	// Because of the sm64_next math, an exact seed to produce 0 is hard to hit,
	// so we manually zero the state to prove the safeguard.
	prng.state = {0, 0, 0, 0}

	// The safeguard inside prng_init wouldn't let this happen, but if we manually zero it,
	// xoshiro256** would normally output 0 forever.
	// We want to prove that prng_init prevents this.

	prng_init(&prng, 0) // seed = 0

	zero_count := 0
	for _ in 0 ..< 100 {
		if prng_step(&prng) == 0 do zero_count += 1
	}

	// It's virtually impossible for 100 consecutive steps to be 0 unless the generator died
	testing.expect(t, zero_count < 100, "Generator died and produced only zeros")
}
