package tina

when TINA_SIMULATION_MODE {
	// Fault injection for simulation lives separately from transport delivery.
	// This keeps the transport file focused on channel semantics, while the
	// harness can evolve the fault engine independently.

	FaultEngine :: struct {
		partition_prng: ^Prng,
		fault_config:   ^FaultConfig,
		network:        ^SimulatedNetwork,
		shard_count:    u8,
	}

	fault_engine_tick :: proc(engine: ^FaultEngine, round: u64) {
		// 1. Heal existing partitions probabilistically
		heal_rate := engine.fault_config.network_partition_heal_rate
		if heal_rate.numerator > 0 {
			for source in 0 ..< engine.shard_count {
				for id in 0 ..< engine.shard_count {
					if shard_mask_contains(&engine.network.partition_matrix[source], id) {
						if ratio_chance(heal_rate, engine.partition_prng) {
							shard_mask_exclude(&engine.network.partition_matrix[source], id)
						}
					}
				}
			}
		}

		// 2. Create new partitions probabilistically
		part_rate := engine.fault_config.network_partition_rate
		if part_rate.numerator > 0 {
			if ratio_chance(part_rate, engine.partition_prng) {
				victim := u8(prng_uint_less_than(engine.partition_prng, u32(engine.shard_count)))
				for other in 0 ..< engine.shard_count {
					if other != victim {
						shard_mask_include(&engine.network.partition_matrix[victim], other)
						shard_mask_include(&engine.network.partition_matrix[other], victim)
					}
				}
			}
		}

		// 3. Update per-channel delays (jitter)
		range := engine.fault_config.network_delay_range_ticks
		if range[1] > 0 {
			diff := range[1] - range[0]
			for source in 0 ..< engine.shard_count {
				source_channels := engine.network.channels[source]
				for target in 0 ..< engine.shard_count {
					if source != target {
						source_channels[target].delay_ticks =
							range[0] + prng_uint_less_than(engine.partition_prng, diff + 1)
					}
				}
			}
		} else {
			// Fast path for 0-delay simulation
			for source in 0 ..< engine.shard_count {
				source_channels := engine.network.channels[source]
				for target in 0 ..< engine.shard_count {
					if source != target {
						source_channels[target].delay_ticks = 0
					}
				}
			}
		}
	}
}
