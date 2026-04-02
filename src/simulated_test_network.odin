package tina

import "core:mem"
import "core:testing"

when TINA_SIMULATION_MODE {

	// ============================================================================
	// SimulatedNetwork contract tests (§C in Plan 05)
	// ============================================================================

	// Helper: create a minimal 2-shard network for unit testing
	@(private = "file")
	_make_test_network :: proc(
		capacity: u32,
		allocator: mem.Allocator,
	) -> (SimulatedNetwork, Prng) {
		ring_sizes := make([][]u32, 2, allocator)
		ring_sizes[0] = make([]u32, 2, allocator)
		ring_sizes[1] = make([]u32, 2, allocator)
		ring_sizes[0][1] = capacity
		ring_sizes[1][0] = capacity

		drop_prng := Prng{}
		prng_init(&drop_prng, 0xDEAD)

		net: SimulatedNetwork
		sim_network_init(&net, 2, ring_sizes, &drop_prng, allocator)

		for row in ring_sizes do delete(row, allocator)
		delete(ring_sizes, allocator)

		return net, drop_prng
	}

	@(private = "file")
	_make_test_envelope :: proc(seq: u32) -> Message_Envelope {
		env: Message_Envelope
		payload_ptr := cast(^u32)&env.payload[0]
		payload_ptr^ = seq
		return env
	}

	@(private = "file")
	_extract_seq :: proc(env: ^Message_Envelope) -> u32 {
		return (cast(^u32)&env.payload[0])^
	}

	@(test)
	test_network_fifo_preserved_under_delay :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		net, drop_prng := _make_test_network(16, context.temp_allocator)
		net.drop_prng = &drop_prng

		// Set a 3-tick delay on channel 0->1
		net.channels[0][1].delay_ticks = 3

		// Create a minimal shard stub for source (shard 0)
		source_shard: Shard
		source_shard.id = 0
		source_shard.sim_state.network = &net
		source_shard.sim_state.fault_config = &FaultConfig{} // all disabled
		shard_mask_include(&source_shard.peer_alive_mask, 1)

		// Enqueue 5 messages at tick 0
		for i in u32(0) ..< 5 {
			env := _make_test_envelope(i)
			res := sim_network_enqueue(
				&net,
				&source_shard,
				1,
				env,
				0,
				source_shard.sim_state.fault_config,
			)
			testing.expect_value(t, res, Send_Result.ok)
		}

		// At tick 2, nothing should be deliverable yet (deliver_at = 3)
		channel := &net.channels[0][1]
		peeked, ok := delay_queue_peek(&channel.delay_queue)
		testing.expect(t, ok, "Queue should have items")
		testing.expect(t, peeked.deliver_at > 2, "Should not be deliverable at tick 2")

		// At tick 3, drain and verify FIFO order
		received: [5]u32
		received_count: u32 = 0
		for {
			item, pop_ok := delay_queue_peek(&channel.delay_queue)
			if !pop_ok do break
			if item.deliver_at > 3 do break

			popped, _ := delay_queue_pop(&channel.delay_queue)
			if received_count < 5 {
				received[received_count] = _extract_seq(&popped.envelope)
				received_count += 1
			}
		}

		testing.expect_value(t, received_count, u32(5))
		for i in u32(0) ..< 5 {
			testing.expect_value(t, received[i], i)
		}
	}

	@(test)
	test_network_partition_blocks_delivery :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		net, drop_prng := _make_test_network(16, context.temp_allocator)
		net.drop_prng = &drop_prng

		source_shard: Shard
		source_shard.id = 0
		source_shard.sim_state.network = &net
		source_shard.sim_state.fault_config = &FaultConfig{}
		shard_mask_include(&source_shard.peer_alive_mask, 1)

		// Partition shard 0 from shard 1
		shard_mask_include(&net.partition_matrix[0], 1)

		env := _make_test_envelope(42)
		res := sim_network_enqueue(&net, &source_shard, 1, env, 0, source_shard.sim_state.fault_config)

		// Should be dropped due to partition
		testing.expect_value(t, res, Send_Result.stale_handle)
		testing.expect_value(t, source_shard.counters.quarantine_drops, u64(1))

		// Queue should be empty
		testing.expect_value(t, net.channels[0][1].delay_queue.count, u32(0))
	}

	@(test)
	test_network_heal_restores_delivery :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		net, drop_prng := _make_test_network(16, context.temp_allocator)
		net.drop_prng = &drop_prng

		source_shard: Shard
		source_shard.id = 0
		source_shard.sim_state.network = &net
		source_shard.sim_state.fault_config = &FaultConfig{}
		shard_mask_include(&source_shard.peer_alive_mask, 1)

		// Partition then heal
		shard_mask_include(&net.partition_matrix[0], 1)
		shard_mask_exclude(&net.partition_matrix[0], 1)

		// After heal, delivery should work
		env := _make_test_envelope(99)
		res := sim_network_enqueue(&net, &source_shard, 1, env, 0, source_shard.sim_state.fault_config)
		testing.expect_value(t, res, Send_Result.ok)
		testing.expect_value(t, net.channels[0][1].delay_queue.count, u32(1))
	}

	@(test)
	test_network_delayed_messages_not_overtaken :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		net, drop_prng := _make_test_network(16, context.temp_allocator)
		net.drop_prng = &drop_prng

		source_shard: Shard
		source_shard.id = 0
		source_shard.sim_state.network = &net
		source_shard.sim_state.fault_config = &FaultConfig{}
		shard_mask_include(&source_shard.peer_alive_mask, 1)

		// Enqueue msg A at tick 0 with 5-tick delay
		net.channels[0][1].delay_ticks = 5
		env_a := _make_test_envelope(1)
		sim_network_enqueue(&net, &source_shard, 1, env_a, 0, source_shard.sim_state.fault_config)

		// Change delay to 2 ticks and enqueue msg B at tick 1
		net.channels[0][1].delay_ticks = 2
		env_b := _make_test_envelope(2)
		sim_network_enqueue(&net, &source_shard, 1, env_b, 1, source_shard.sim_state.fault_config)

		// msg A deliver_at = 5, msg B deliver_at = 3
		// But FIFO means B cannot be delivered before A
		channel := &net.channels[0][1]

		// At tick 3, peek should show A first (FIFO head), deliver_at=5 > 3, so nothing deliverable
		head, ok := delay_queue_peek(&channel.delay_queue)
		testing.expect(t, ok, "Queue should have items")
		testing.expect_value(t, _extract_seq(&head.envelope), u32(1))
		testing.expect(t, head.deliver_at > 3, "A (head) should not be deliverable at tick 3")

		// At tick 5, drain both — order must be A then B
		received: [2]u32
		for i in 0 ..< 2 {
			item, pop_ok := delay_queue_pop(&channel.delay_queue)
			testing.expect(t, pop_ok, "Should have items to pop")
			received[i] = _extract_seq(&item.envelope)
		}
		testing.expect_value(t, received[0], u32(1)) // A first
		testing.expect_value(t, received[1], u32(2)) // B second
	}
}
