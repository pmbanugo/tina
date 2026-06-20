package tina

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"

_ :: fmt
_ :: intrinsics
_ :: os
_ :: strings

when TINA_ASAN_DEATH_TESTS {

Death_Case :: struct {
	name: string,
	fn:   proc(),
}

@(private = "file")
_death_cases := [?]Death_Case{
	{"message_pool_use_after_free", _death_message_pool_use_after_free},
	{"io_slot_use_after_free", _death_io_slot_use_after_free},
	{"isolate_payload_use_after_release", _death_isolate_payload_use_after_release},
	{"working_arena_use_after_reset", _death_working_arena_use_after_reset},
	{"inflight_io_slot_use_after_submit_poison", _death_inflight_io_slot_use_after_submit_poison},
	{"spsc_slot_use_after_commit", _death_spsc_slot_use_after_commit},
	{"log_record_use_after_flush", _death_log_record_use_after_flush},
}

main :: proc() {
	if !TINA_ASAN_POISONING {
		fmt.eprintln("[DEATH] runner requires an AddressSanitizer build")
		os.exit(1)
	}

	arguments := os.args
	if len(arguments) == 1 {
		run_parent()
		return
	}
	if len(arguments) == 2 {
		run_child(arguments[1])
		return
	}

	fmt.eprintln("[DEATH] unexpected arguments; usage: runner [case-name]")
	os.exit(1)
}

@(private = "file")
run_parent :: proc() {
	executable := os.args[0]
	all_passed := true

	for case_entry in _death_cases {
		desc := os.Process_Desc {
			command = {executable, case_entry.name},
		}

		state, stdout, stderr, err := os.process_exec(desc, context.allocator)
		defer {
			delete(stdout)
			delete(stderr)
		}

		if err != nil {
			fmt.eprintf(
				"[DEATH] case '%s': failed to spawn child: %v\n",
				case_entry.name,
				err,
			)
			all_passed = false
			continue
		}

		stderr_str := string(stderr)
		asan_detected :=
			strings.contains(stderr_str, "AddressSanitizer") ||
			strings.contains(stderr_str, "use-after-poison") ||
			strings.contains(stderr_str, "unknown-crash")

		if state.success || !asan_detected {
			fmt.eprintf(
				"[DEATH] case '%s': FAIL (success=%v, asan_detected=%v)\n",
				case_entry.name,
				state.success,
				asan_detected,
			)
			if len(stderr_str) > 0 {
				fmt.eprintf("[DEATH] stderr:\n%s\n", stderr_str)
			}
			all_passed = false
		} else {
			fmt.printfln("[DEATH] case '%s': PASS", case_entry.name)
		}
	}

	if !all_passed {
		os.exit(1)
	}
}

@(private = "file")
run_child :: proc(case_name: string) {
	for case_entry in _death_cases {
		if case_entry.name == case_name {
			case_entry.fn()
			fmt.eprintf(
				"[DEATH] case '%s' returned without crashing; ASan did not intercept the access\n",
				case_name,
			)
			os.exit(0)
		}
	}

	fmt.eprintf("[DEATH] unknown case: %s\n", case_name)
	os.exit(2)
}

// ============================================================================
// Death cases
// ============================================================================

@(private = "file")
_death_message_pool_use_after_free :: proc() {
	backing: [MESSAGE_ENVELOPE_SIZE * 2]u8
	pool: Message_Pool
	pool_init_tina_owned(&pool, backing[:], MESSAGE_ENVELOPE_SIZE)

	index, _ := pool_alloc_system_tina_owned(&pool)
	message := pool_get_ptr_unchecked(&pool, index)
	pool_free_unchecked_tina_owned(&pool, index)

	// ASan must intercept this write to freed poisoned memory.
	intrinsics.volatile_store(&message.tag, Message_Tag(0x1234))
}

@(private = "file")
_death_io_slot_use_after_free :: proc() {
	backing: [64]u8
	pool: IO_Slot_Pool
	io_slot_pool_init_tina_owned(&pool, backing[:], 64, 1)

	index, _ := io_slot_pool_alloc_tina_owned(&pool)
	slot := _io_slot_pool_pointer(&pool, index)
	io_slot_pool_free_tina_owned(&pool, index)

	// ASan must intercept this write to freed poisoned memory (past the
	// intrusive free-list word that remains addressable).
	intrinsics.volatile_store(&slot[size_of(IO_Slot_Index)], 0xAB)
}

@(private = "file")
_death_isolate_payload_use_after_release :: proc() {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {1},
			strides     = {64},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)

	test_shard_slot_activate(fixture, make_handle(0, 0, 0, 1), .Runnable)
	payload := rawptr(&fixture.shard.isolate_memory[0][0])
	test_shard_slot_release(fixture, 0, 0)

	// ASan must intercept this write to the released isolate payload.
	intrinsics.volatile_store(cast(^u64)payload, 0xDEAD_BEEF)
}

@(private = "file")
_death_working_arena_use_after_reset :: proc() {
	state: rawptr

	callback :: proc(user_data: rawptr) {
		_ = user_data
		working_allocator := ctx_working_arena()
		value := new(u64, working_allocator)
		value^ = 0xCAFE_BABE

		ctx_working_arena_reset()

		// ASan must intercept this write to the logically-freed allocation.
		intrinsics.volatile_store(value, 0xDEAD_BEEF)
	}

	test_with_turn_frame(
		Test_Turn_Frame_Config{
			self_handle         = make_handle(0, 0, 0, 1),
			working_memory_size = 256,
		},
		state,
		callback,
	)
}

@(private = "file")
_death_inflight_io_slot_use_after_submit_poison :: proc() {
	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count           = 1,
			slot_counts          = {1},
			strides              = {8},
			subsystems           = {.Metadata, .Reactor},
			reactor_buffer_count = 2,
			reactor_buffer_bytes = 64,
		},
	)
	defer test_shard_fixture_deinit(fixture)

	index, _ := io_slot_pool_alloc_tina_owned(&fixture.shard.reactor.receive_pool)
	_sanitizer_address_poison_inflight_io_slot(&fixture.shard.reactor, .Receive, index)

	slot := _io_slot_pool_pointer(&fixture.shard.reactor.receive_pool, index)
	// ASan must intercept this write to an in-flight kernel-owned buffer.
	intrinsics.volatile_store(&slot[0], 0xCD)
}

@(private = "file")
_death_spsc_slot_use_after_commit :: proc() {
	buffer: [2]Message_Envelope
	ring: SPSC_Ring
	spsc_ring_init_tina_owned(&ring, 2, buffer[:])

	envelope := Message_Envelope{tag = TAG_TIMER}
	spsc_ring_enqueue_tina_owned(&ring, &envelope)
	spsc_ring_flush_producer(&ring)

	read_pointer := spsc_ring_get_read_ptr(&ring, 0)
	spsc_ring_commit_read_tina_owned(&ring, 1)

	// ASan must intercept this write to the committed (now free) slot.
	intrinsics.volatile_store(&read_pointer.tag, TAG_TIMER)
}

@(private = "file")
_death_log_record_use_after_flush :: proc() {
	// Use heap-backed storage so ASan instruments the access. Stack variables
	// inside the same frame are not always checked by the compiler-generated
	// instrumentation even when their shadow state is poisoned.
	backing := make([]u8, 64)
	ring: Log_Ring_Buffer
	log_init_tina_owned(&ring, backing)

	fixture := test_shard_fixture_init(
		Test_Shard_Spec{
			type_count  = 1,
			slot_counts = {0},
			strides     = {0},
			subsystems  = {.Metadata},
		},
	)
	defer test_shard_fixture_deinit(fixture)

	shard := &fixture.shard
	shard.log_ring = ring
	shard.current_tick = 1

	payload := []u8{'x'}
	_shard_log(
		shard,
		ISOLATE_HANDLE_NONE,
		Log_Level.INFO,
		USER_LOG_TAG_BASE,
		payload,
	)
	log_flush(shard)

	// ASan must intercept this write to flushed (re-poisoned) log bytes.
	intrinsics.volatile_store(&backing[0], 0xEF)
}

}
