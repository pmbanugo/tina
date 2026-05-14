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
				type_id := type_desc.id
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

			// Active maintenance tasks are scheduler-visible work even when no Isolate
			// mailbox traffic is pending. HTTP deadlines depend on this path.
			for task_index in 0 ..< int(shard.maintenance_task_count) {
				task := shard.maintenance_tasks[task_index]
				if task.handler != nil && task.next_tick != max(u64) do return false
			}
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

	@(private = "file")
	_simulator_idle_test_maintenance_handler :: proc(
		state: rawptr,
		ctx: Shard_Maintenance_Context,
		work_budget_count: Scheduler_Work_Count,
	) -> Shard_Maintenance_Result {
		return Shard_Maintenance_Result{}
	}

	@(test)
	test_simulator_is_globally_idle_counts_active_maintenance_tasks :: proc(t: ^testing.T) {
		spec := SystemSpec {shard_count = 1}
		shards := make([]Shard, 1)
		defer delete(shards)

		sim := Simulator {
			spec   = &spec,
			shards = shards,
		}
		shard := &sim.shards[0]

		shard.maintenance_tasks = make([]Shard_Maintenance_Task, 1)
		defer delete(shard.maintenance_tasks)
		shard.maintenance_task_count = 1
		shard.maintenance_tasks[0] = Shard_Maintenance_Task {
			handler               = _simulator_idle_test_maintenance_handler,
			next_tick             = 5,
			cadence_tick_count    = 1,
			budget_weight         = Scheduler_Weight_Count(1),
			work_budget_count_max = Scheduler_Work_Count(1),
		}

		testing.expect(
			t,
			!simulator_is_globally_idle(&sim),
			"active maintenance task should keep simulator non-idle",
		)

		shard.maintenance_tasks[0].next_tick = max(u64)
		testing.expect(
			t,
			simulator_is_globally_idle(&sim),
			"disabled maintenance task should not block quiescence",
		)
	}
}
