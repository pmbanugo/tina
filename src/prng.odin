package tina

import "core:testing"

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

    for i in 0..<100 {
        v1 := prng_step(&prng1)
        v2 := prng_step(&prng2)
        testing.expect_value(t, v1, v2)
    }
}
