package tina

import "core:testing"

when TINA_SIMULATION_MODE {
	// Clock-adjacent helpers live here so later work can grow this into a real
	// SimulatedClock subsystem without reopening the main harness loop.

		simulator_is_globally_idle :: proc(sim: ^Simulator) -> bool {
		for i in 0 ..< sim.spec.shard_count {
			shard := &sim.shards[i]

			// Check if any Isolate has pending work in its mailbox or is waiting for I/O
			for type_desc in shard.type_descriptors {
				type_id := u16(type_desc.id)
				slot_count := type_desc.slot_count

				for slot in 0 ..< slot_count {
					if shard.metadata[type_id].inbox_count[slot] > 0 do return false
					if shard.metadata[type_id].io_completion_tag[slot] != IO_TAG_NONE do return false
					if shard.metadata[type_id].state[slot] == .Runnable do return false
					if shard.metadata[type_id].state[slot] == .Waiting_For_Io do return false
				}
			}

			// Check if the SimulatedIO backend has pending completions
			if shard.reactor.backend.pending_count > 0 do return false

			// Check if any timers are registered
			if shard.timer_wheel.resident_count > 0 do return false
			if shard.timer_wheel.renewable_armed_count > 0 do return false
		}

		// Check if any SimulatedNetwork channel has delayed messages in flight
		net := &sim.network
		for source in 0 ..< net.shard_count {
			for target in 0 ..< net.shard_count {
				if source != target {
					if net.channels[source][target].delay_queue.count > 0 do return false
				}
			}
		}

		return true
	}

	@(test)
	test_simulator_is_globally_idle_counts_active_renewable_deadlines :: proc(t: ^testing.T) {
		spec := SystemSpec {shard_count = 1}
		shards := make([]Shard, 1)
		defer delete(shards)

		sim := Simulator {
			spec   = &spec,
			shards = shards,
		}
		shard := &sim.shards[0]
		deadline_handle := TIMER_HANDLE_NONE

		spokes := make([]u32, 8)
		defer delete(spokes)
		entries := make([]Timer_Entry, 8)
		defer delete(entries)
		timer_wheel_init(&shard.timer_wheel, spokes, entries, 0)
		renewable_deliver_at := make([]u64, 8)
		defer delete(renewable_deliver_at)
		renewable_target := make([]Handle, 8)
		defer delete(renewable_target)
		renewable_tag := make([]Message_Tag, 8)
		defer delete(renewable_tag)
		renewable_correlation := make([]Correlation_Id, 8)
		defer delete(renewable_correlation)
		renewable_armed_words := make([]u64, 1)
		defer delete(renewable_armed_words)
		timer_wheel_init_renewable(
			&shard.timer_wheel,
			renewable_deliver_at,
			renewable_target,
			renewable_tag,
			renewable_correlation,
			renewable_armed_words,
		)
		deadline_handle = timer_acquire_renewable(&shard.timer_wheel, make_handle(0, 1, 0, 1))
		timer_rearm_renewable(
			&shard.timer_wheel,
			deadline_handle,
			5,
			Message_Tag(USER_MESSAGE_TAG_BASE),
			CORRELATION_ID_NONE,
		)

		testing.expect(
			t,
			!simulator_is_globally_idle(&sim),
			"active renewable deadline should keep simulator non-idle",
		)

		timer_release_renewable(&shard.timer_wheel, deadline_handle)
		testing.expect(
			t,
			simulator_is_globally_idle(&sim),
			"cancelled renewable deadline should not block quiescence",
		)
	}
}
