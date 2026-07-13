package tina

import "core:testing"

// ============================================================================
// SimulatedIO Backend (§6.6.2 §5.4) — Deterministic Testing
// ============================================================================
//
// No kernel interaction. Deterministic delay/error derivation, fault injection,
// and optional completion reordering.
// Same seed + same submit/collect sequence = same completions.
//
// Active when TINA_SIM=true (overrides OS selection).

when TINA_SIMULATION_MODE {

	BACKEND_POOL_BUFFER_OWNED_AFTER_SUBMIT :: true
	MAX_SIMULATED_PENDING :: 1024
	MAX_SIMULATED_DESCRIPTORS :: 4096
	MAX_SIMULATED_OBJECTS :: 4096
	// Every accepted operation is either pending or represented by one unread
	// completion. Acceptance is bounded by this completion capacity so
	// cancellation is a state transition, not a second capacity dependency.
	MAX_SIMULATED_COMPLETED :: REACTOR_COMPLETION_BATCH_COUNT * 2
	#assert(REACTOR_SUBMISSION_BATCH_COUNT <= MAX_SIMULATED_PENDING)
	#assert(REACTOR_COMPLETION_BATCH_COUNT <= MAX_SIMULATED_COMPLETED, "completed ring must hold at least one drain batch")
	SIM_DESCRIPTOR_NONE_INDEX :: u16(0xFFFF)
	SIM_OBJECT_NONE_INDEX :: u16(0xFFFF)
	SIM_ERR_BADF :: i32(-9)
	SIM_ERR_NFILE :: i32(-24)
	SIM_ERR_CANCELED :: i32(-125)

	@(private = "package")
	_backend_boot_scratch_size :: #force_inline proc "contextless" (
		receive_slot_count: int,
		fd_slot_count: int,
	) -> int {
		return 0
	}

	Sim_FD_Object_State :: enum u8 {
		Free,
		Open,
		Bound,
		Listening,
	}

	Sim_FD_Object_Attribute :: enum u8 {
		Reuse_Port,
		Exclusive_Address_Use,
	}

	Sim_FD_Object_Attributes :: bit_set[Sim_FD_Object_Attribute; u8]

	Sim_FD_Object :: struct {
		ref_count:       u16,
		inflight_count:  u16,
		next_free_index: u16,
		state:           Sim_FD_Object_State,
		attributes:      Sim_FD_Object_Attributes,
		bind_address:    Socket_Address,
	}

	Sim_FD_Descriptor_State :: enum u8 {
		Free,
		Open_Close_On_Exec,
	}

	Sim_FD_Descriptor :: struct {
		fd_number:       OS_FD,
		object_index:    u16,
		next_free_index: u16,
		state:           Sim_FD_Descriptor_State,
		_padding:        [3]u8,
	}
	#assert(size_of(Sim_FD_Object_State) == 1)
	#assert(size_of(Sim_FD_Object_Attributes) == 1)
	#assert(offset_of(Sim_FD_Object, bind_address) == 8)
	#assert(size_of(Sim_FD_Object) == 8 + size_of(Socket_Address))
	#assert(size_of(Sim_FD_Descriptor_State) == 1)
	#assert(size_of(Sim_FD_Descriptor) == size_of(OS_FD) + 8)

	Simulated_Operation :: struct {
		token:          Submission_Token,
		operation:      Submission_Operation,
		data_size:      u32,
		submitted_tick: u64,
		delay_ticks:    u64,
		descriptor_index: u16,
		object_index:   u16,
		object_index_second: u16,
		has_second_pin:      bool,
		_padding:       [1]u8,
	}

	Simulated_Submission_Targets :: struct {
		descriptor_index:    u16,
		object_index:        u16,
		object_index_second: u16,
		has_second_pin:      bool,
		_padding:            [1]u8,
	}

	Sim_IO_World :: struct {
		descriptors:          [MAX_SIMULATED_DESCRIPTORS]Sim_FD_Descriptor,
		objects:              [MAX_SIMULATED_OBJECTS]Sim_FD_Object,
		descriptor_free_head: u16,
		descriptor_free_count: u16,
		object_free_head:     u16,
		object_free_count:    u16,
		active_backend_count: u16, // INVARIANT ONLY — not used for lifecycle decisions
		_padding:             u16,
		next_sim_fd:          i32,
	}

	_Platform_State :: struct {
		pending:           [MAX_SIMULATED_PENDING]Simulated_Operation,
		pending_count:     u16,
		completed:         [MAX_SIMULATED_COMPLETED]Raw_Completion,
		completed_count:   u16,
		completed_head:    u16,
		completed_tail:    u16,
		prng:              Prng, // used only for reordering (order-dependent is OK)
		seed:              u64, // original seed for per-op deterministic derivation
		tick_count:        u64,
		time_controlled:   bool,
		collect_fault_pending: bool,
		_padding:          [6]u8,
		config:            Simulation_IO_Config,
		sim_world:         ^Sim_IO_World, // shared context — set before backend_init
	}

	@(private = "package")
	_backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
		backend.pending_count = 0
		backend.completed_count = 0
		backend.completed_head = 0
		backend.completed_tail = 0
		backend.tick_count = 0
		backend.time_controlled = false
		backend.collect_fault_pending = false
		backend.config = config.sim_config
		world := cast(^Sim_IO_World)config.sim_config.world
		backend.sim_world = world
		if world != nil {
			world.active_backend_count += 1
		}

		// Seed from config — populated from Prng_Tree at shard hydration,
		// or from t.seed in tests.
		backend.seed = config.sim_config.seed
		prng_init(&backend.prng, backend.seed)
		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		for pending_index in 0 ..< backend.pending_count {
			pending := &backend.pending[pending_index]
			_sim_unpin_object(backend, pending.object_index)
			if pending.has_second_pin {
				_sim_unpin_object(backend, pending.object_index_second)
			}
		}
		backend.pending_count = 0
		_sim_dispose_unread_accepts(backend)
		backend.completed_count = 0
		backend.completed_head = 0
		backend.completed_tail = 0
		world := backend.sim_world
		if world != nil {
			if world.active_backend_count > 0 {
				world.active_backend_count -= 1
			}
		}
		backend.sim_world = nil
	}

	@(private = "file")
	_sim_dispose_unread_accepts :: proc "contextless" (backend: ^Platform_Backend) {
		completion_index := backend.completed_head
		for _ in 0 ..< backend.completed_count {
			completion := &backend.completed[completion_index]
			if accept_extra, ok := completion.extra.(Completion_Extra_Accept); ok {
				descriptor_index := _sim_lookup_descriptor_index(
					backend,
					accept_extra.client_fd,
				)
				if descriptor_index != SIM_DESCRIPTOR_NONE_INDEX {
					_ = _sim_close_descriptor_index(backend, descriptor_index)
				}
			}
			completion_index = (completion_index + 1) % MAX_SIMULATED_COMPLETED
		}
	}

	@(private = "package")
	_backend_quiesce_after_collect_fault :: proc(
		backend: ^Platform_Backend,
	) -> Backend_Quiesce_Result {
		_backend_deinit(backend)
		return .Quiesced
	}

	@(private = "package")
	_backend_submit :: proc(
		backend: ^Platform_Backend,
		submissions: []Submission,
	) -> Backend_Error {
		obligation_count := int(backend.pending_count) + int(backend.completed_count)
		if obligation_count + len(submissions) > MAX_SIMULATED_COMPLETED {
			return .Queue_Full
		}

		prepared: [REACTOR_SUBMISSION_BATCH_COUNT]Simulated_Submission_Targets
		when TINA_RUNTIME_ASSERTIONS {
			assert(len(submissions) <= len(prepared), "sim backend submit batch exceeds reactor submission batch")
		}
		if len(submissions) > len(prepared) {
			return .Queue_Full
		}

		for submission, submission_index in submissions {
			submission_operation := submission.operation
			targets, valid := _sim_validate_submission_targets(backend, &submission_operation)
			if !valid {
				return .System_Error
			}
			prepared[submission_index] = targets
		}

		for submission_index in 0 ..< len(submissions) {
			sub := &submissions[submission_index]
			targets := prepared[submission_index]

			assert(
				_sim_pin_object(backend, targets.object_index),
				"validated simulated object must remain pinnable during commit",
			)
			if targets.has_second_pin {
				assert(
					_sim_pin_object(backend, targets.object_index_second),
					"validated second simulated object must remain pinnable during commit",
				)
			}

			// Compute delay from hash seeded by (seed, tick_count, token) for determinism
			// invariant to batch size and iteration order
			delay: u64
			min_delay := u64(backend.config.delay_range_ticks[0])
			max_delay := u64(backend.config.delay_range_ticks[1])
			if max_delay > min_delay {
				range := max_delay - min_delay
				h := _sim_op_hash(backend.seed, backend.tick_count, sub.token)
				delay = min_delay + (h % range)
			} else {
				delay = min_delay
			}

			backend.pending[backend.pending_count] = Simulated_Operation {
				token               = sub.token,
				operation            = sub.operation,
				data_size            = sub.data_size,
				submitted_tick       = backend.tick_count,
				delay_ticks          = delay,
				descriptor_index     = targets.descriptor_index,
				object_index         = targets.object_index,
				object_index_second  = targets.object_index_second,
				has_second_pin       = targets.has_second_pin,
			}
			backend.pending_count += 1
		}

		return .None
	}

	@(private = "package")
	_backend_collect :: proc(
		backend: ^Platform_Backend,
		completions: []Raw_Completion,
		timeout_ns: i64,
	) -> Backend_Collect_Result {
		// PHASE 1: Advance time, move ready ops from pending -> completed ring
		if !backend.time_controlled {
			backend.tick_count += 1
		}

		i: u16 = 0
		for i < backend.pending_count {
			op := &backend.pending[i]

			if backend.tick_count >= op.submitted_tick + op.delay_ticks {
				// Back-pressure: if the completed ring is full, stop processing
				// matured ops. They stay in pending and will be retried next tick.
				// Without this guard the op would be removed from pending with no
				// completion generated — a silent drop that permanently inflates
				// io_in_flight_count and strands the Isolate in Wait_Io.
				if backend.completed_count >= MAX_SIMULATED_COMPLETED {
					break
				}

				completion_ptr := &backend.completed[backend.completed_tail]
				completion_ptr.token = op.token
				completion_ptr.extra = nil

				// Fault injection — hash-based derivation with a different phase
				// to avoid correlation with delay (§6.6.2 §5.4)
				if backend.config.fault_rate.denominator > 0 &&
				   backend.config.fault_rate.numerator > 0 {
					fault_hash := _sim_op_hash(backend.seed ~ 0x1, backend.tick_count, op.token)
					fault_val := u32(fault_hash >> 32)
					threshold := u32(
						(u64(backend.config.fault_rate.numerator) * u64(max(u32))) /
						u64(backend.config.fault_rate.denominator),
					)
					if fault_val < threshold {
						completion_ptr.result = _sim_sample_error(backend, op.token)
					} else {
						_sim_generate_success(backend, op, completion_ptr)
					}
				} else {
					_sim_generate_success(backend, op, completion_ptr)
				}

				if _, is_close := op.operation.(Submission_Op_Close); is_close {
					close_ok := _sim_close_descriptor_index(backend, op.descriptor_index)
					if !close_ok && completion_ptr.result >= 0 {
						completion_ptr.result = SIM_ERR_BADF
					}
				}

				_sim_unpin_object(backend, op.object_index)
				if op.has_second_pin {
					_sim_unpin_object(backend, op.object_index_second)
				}

				backend.completed_tail = (backend.completed_tail + 1) % MAX_SIMULATED_COMPLETED
				backend.completed_count += 1

				// Remove from pending (swap-with-last)
				backend.pending_count -= 1
				if i < backend.pending_count {
					backend.pending[i] = backend.pending[backend.pending_count]
				}
				// Don't increment i — we need to check the swapped-in element
			} else {
				i += 1
			}
		}

		// PHASE 2: Drain completed ring into caller's buffer
		completed_count: u32 = 0
		for completed_count < u32(len(completions)) && backend.completed_count > 0 {
			completions[completed_count] = backend.completed[backend.completed_head]
			backend.completed_head = (backend.completed_head + 1) % MAX_SIMULATED_COMPLETED
			backend.completed_count -= 1
			completed_count += 1
		}

		// Optional reordering of completions (on caller's buffer)
		if backend.config.reorder && completed_count > 1 {
			for j: u32 = 0; j < completed_count - 1; j += 1 {
				remaining := completed_count - j
				swap_index := j + u32(prng_uint_less_than(&backend.prng, remaining))
				completions[j], completions[swap_index] = completions[swap_index], completions[j]
			}
		}

		fault: Backend_Collect_Fault
		if backend.collect_fault_pending {
			backend.collect_fault_pending = false
			fault = .System_Error
		}
		return Backend_Collect_Result {
			completion_count = completed_count,
			fault = fault,
		}
	}

	@(private = "package")
	_sim_fail_next_collect :: proc "contextless" (backend: ^Platform_Backend) {
		backend.collect_fault_pending = true
	}

	@(private = "package")
	_backend_set_current_tick :: #force_inline proc "contextless" (backend: ^Platform_Backend, tick_count: u64) {
		backend.tick_count = tick_count
		backend.time_controlled = true
	}

	@(private = "package")
	_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
		// Simulate OS async cancel latency/failure.
		// Hash phase 0x3 keeps this PRNG draw independent of I/O errors/delays.
		if backend.config.fault_rate.denominator > 0 {
			h := _sim_op_hash(backend.seed ~ 0x3, backend.tick_count, token)
			threshold := u32(
				(u64(backend.config.fault_rate.numerator) * u64(max(u32))) /
				u64(backend.config.fault_rate.denominator),
			)

			if u32(h >> 32) < threshold {
				return .Too_Late // The kernel was too slow; the completion will still fire later!
			}
		}

		// Normal successful cancel
		for i: u16 = 0; i < backend.pending_count; i += 1 {
			if backend.pending[i].token == token {
				completion := Raw_Completion {
					token  = token,
					result = SIM_ERR_CANCELED,
					extra  = nil,
					flags  = {.Synthesized},
				}
				store_result := _sim_store_completion(backend, completion)
				assert(store_result == .Stored, "accepted simulated obligation must retain completion capacity")
				_sim_unpin_object(backend, backend.pending[i].object_index)
				if backend.pending[i].has_second_pin {
					_sim_unpin_object(backend, backend.pending[i].object_index_second)
				}
				backend.pending_count -= 1
				if i < backend.pending_count {
					backend.pending[i] = backend.pending[backend.pending_count]
				}
				return .None
			}
		}
		return .Not_Found
	}

	@(private = "package")
	_backend_wake :: proc(backend: ^Platform_Backend) {
		// No-op: single-threaded simulation
	}

	// --- Synchronous Control Operations (simulated) ---

	@(private = "package")
	_backend_control_socket :: proc(
		backend: ^Platform_Backend,
		domain: Socket_Domain,
		socket_type: Socket_Type,
		protocol: Socket_Protocol,
	) -> (
		OS_FD,
		Backend_Error,
	) {
		assert(
			backend.sim_world != nil,
			"simulated socket creation requires an initialized I/O world",
		)
		object_index := _sim_alloc_object(backend)
		if object_index == SIM_OBJECT_NONE_INDEX {
			return OS_FD_INVALID, .System_Error
		}
		fd := _sim_alloc_descriptor(backend, object_index)
		if fd == OS_FD_INVALID {
			_sim_object_release_ref(backend, object_index)
			return OS_FD_INVALID, .System_Error
		}
		return fd, .None
	}

	@(private = "package")
	_backend_control_bind :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		address: Socket_Address,
	) -> Backend_Error {
		descriptor := _sim_lookup_descriptor(backend, fd)
		if descriptor == nil do return .System_Error

		world := backend.sim_world
		object := &world.objects[descriptor.object_index]
		if object.state != .Open {
			return .Invalid_Argument
		}

		for object_index in 0 ..< MAX_SIMULATED_OBJECTS {
			other := &world.objects[object_index]
			if other.state == .Free do continue
			if other.state == .Open do continue
			if u16(object_index) == descriptor.object_index do continue
			if !_sim_bind_addresses_overlap(address, other.bind_address) {
				continue
			}
			if _sim_bind_allows_shared_port(object, other) {
				continue
			}
			return .Address_In_Use
		}

		object.state = .Bound
		object.bind_address = address
		return .None
	}

	@(private = "package")
	_backend_control_listen :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		backlog: u32,
	) -> Backend_Error {
		descriptor := _sim_lookup_descriptor(backend, fd)
		if descriptor == nil do return .System_Error
		world := backend.sim_world
		object := &world.objects[descriptor.object_index]
		if object.state == .Free do return .Invalid_Argument
		if object.state == .Open do return .Invalid_Argument
		object.state = .Listening
		return .None
	}

	@(private = "package")
	_backend_control_setsockopt :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		level: Socket_Level,
		option: Socket_Option,
		value: Socket_Option_Value,
	) -> Backend_Error {
		descriptor := _sim_lookup_descriptor(backend, fd)
		if descriptor == nil do return .System_Error
		world := backend.sim_world
		object := &world.objects[descriptor.object_index]

		if level == .SOL_SOCKET {
			#partial switch option {
			case .SO_REUSEPORT:
				if enabled, enabled_ok := value.(bool); enabled_ok {
					if enabled {
						object.attributes += {.Reuse_Port}
					} else {
						object.attributes -= {.Reuse_Port}
					}
				}
			case .SO_EXCLUSIVEADDRUSE:
				if enabled, enabled_ok := value.(bool); enabled_ok {
					if enabled {
						object.attributes += {.Exclusive_Address_Use}
					} else {
						object.attributes -= {.Exclusive_Address_Use}
					}
				}
			case:
			}
		}

		return .None
	}

	@(private = "package")
	_backend_control_getsockopt :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		level: Socket_Level,
		option: Socket_Option,
	) -> (
		Socket_Option_Value,
		Backend_Error,
	) {
		if _sim_lookup_descriptor(backend, fd) == nil do return nil, .System_Error
		// Simulation returns a default value
		return i32(0), .None
	}

	@(private = "package")
	_backend_control_shutdown :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		how: Shutdown_How,
	) -> Backend_Error {
		if _sim_lookup_descriptor(backend, fd) == nil do return .System_Error
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
		descriptor_index := _sim_lookup_descriptor_index(backend, fd)
		if descriptor_index == SIM_DESCRIPTOR_NONE_INDEX do return .System_Error
		if !_sim_close_descriptor_index(backend, descriptor_index) {
			return .System_Error
		}
		return .None
	}

	@(private = "package")
	_backend_control_dup :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> (
		OS_FD,
		Backend_Error,
	) {
		descriptor := _sim_lookup_descriptor(backend, fd)
		if descriptor == nil {
			return OS_FD_INVALID, .System_Error
		}
		world := backend.sim_world
		object := &world.objects[descriptor.object_index]
		object.ref_count += 1
		duplicate_fd := _sim_alloc_descriptor(backend, descriptor.object_index)
		if duplicate_fd == OS_FD_INVALID {
			object.ref_count -= 1
			return OS_FD_INVALID, .System_Error
		}
		return duplicate_fd, .None
	}

	@(private = "package")
	_backend_register_fixed_fd :: #force_inline proc "contextless" (backend: ^Platform_Backend, slot_index: u16, fd: OS_FD) -> Backend_Fixed_File_Update_Result {
		// No-op: SimulatedIO has no kernel fixed-file table.
		return .Updated
	}

	@(private = "package")
	_backend_unregister_fixed_fd :: #force_inline proc "contextless" (backend: ^Platform_Backend, slot_index: u16) -> Backend_Fixed_File_Update_Result {
		// No-op: SimulatedIO has no kernel fixed-file table.
		return .Updated
	}

	// --- Internal Helpers ---

	@(private = "package")
	_sim_world_init :: proc "contextless" (world: ^Sim_IO_World) {
		world.descriptor_free_head = SIM_DESCRIPTOR_NONE_INDEX
		world.descriptor_free_count = MAX_SIMULATED_DESCRIPTORS
		for i := MAX_SIMULATED_DESCRIPTORS - 1; i >= 0; i -= 1 {
			world.descriptors[i] = Sim_FD_Descriptor {
				fd_number = OS_FD_INVALID,
				object_index = SIM_OBJECT_NONE_INDEX,
				next_free_index = world.descriptor_free_head,
			}
			world.descriptor_free_head = u16(i)
		}

		world.object_free_head = SIM_OBJECT_NONE_INDEX
		world.object_free_count = MAX_SIMULATED_OBJECTS
		for i := MAX_SIMULATED_OBJECTS - 1; i >= 0; i -= 1 {
			world.objects[i] = Sim_FD_Object {
				next_free_index = world.object_free_head,
			}
			world.object_free_head = u16(i)
		}
		world.next_sim_fd = 100
		world.active_backend_count = 0
	}

	@(private = "file")
	_sim_alloc_object :: proc "contextless" (backend: ^Platform_Backend) -> u16 {
		world := backend.sim_world
		if world.object_free_head == SIM_OBJECT_NONE_INDEX {
			return SIM_OBJECT_NONE_INDEX
		}
		index := world.object_free_head
		object := &world.objects[index]
		world.object_free_head = object.next_free_index
		world.object_free_count -= 1
		object^ = Sim_FD_Object {
			ref_count       = 1,
			inflight_count  = 0,
			next_free_index = SIM_OBJECT_NONE_INDEX,
			state           = .Open,
		}
		return index
	}

	@(private = "file")
	_sim_alloc_descriptor :: proc "contextless" (
		backend: ^Platform_Backend,
		object_index: u16,
	) -> OS_FD {
		world := backend.sim_world
		if world.descriptor_free_head == SIM_DESCRIPTOR_NONE_INDEX {
			return OS_FD_INVALID
		}
		index := world.descriptor_free_head
		descriptor := &world.descriptors[index]
		world.descriptor_free_head = descriptor.next_free_index
		world.descriptor_free_count -= 1

		fd_number := OS_FD(world.next_sim_fd)
		world.next_sim_fd += 1
		descriptor^ = Sim_FD_Descriptor {
			fd_number = fd_number,
			object_index = object_index,
			next_free_index = SIM_DESCRIPTOR_NONE_INDEX,
			state = .Open_Close_On_Exec,
		}
		return fd_number
	}

	@(private = "package")
	_sim_lookup_descriptor_index :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> u16 {
		world := backend.sim_world
		for i in 0 ..< MAX_SIMULATED_DESCRIPTORS {
			descriptor := &world.descriptors[i]
			if descriptor.state == .Open_Close_On_Exec && descriptor.fd_number == fd {
				return u16(i)
			}
		}
		return SIM_DESCRIPTOR_NONE_INDEX
	}

	@(private = "package")
	_sim_lookup_descriptor :: #force_inline proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> ^Sim_FD_Descriptor {
		world := backend.sim_world
		index := _sim_lookup_descriptor_index(backend, fd)
		if index == SIM_DESCRIPTOR_NONE_INDEX {
			return nil
		}
		return &world.descriptors[index]
	}

	@(private = "file")
	_sim_maybe_free_object :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) {
		world := backend.sim_world
		if object_index == SIM_OBJECT_NONE_INDEX do return
		object := &world.objects[object_index]
		if object.state == .Free do return
		if object.ref_count != 0 do return
		if object.inflight_count != 0 do return
		object.state = .Free
		object.next_free_index = world.object_free_head
		world.object_free_head = object_index
		world.object_free_count += 1
	}

	@(private = "file")
	_sim_object_release_ref :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) {
		world := backend.sim_world
		if object_index == SIM_OBJECT_NONE_INDEX do return
		object := &world.objects[object_index]
		if object.ref_count > 0 {
			object.ref_count -= 1
		}
		_sim_maybe_free_object(backend, object_index)
	}

	@(private = "file")
	_sim_pin_object :: #force_inline proc "contextless" (backend: ^Platform_Backend, object_index: u16) -> bool {
		world := backend.sim_world
		if object_index == SIM_OBJECT_NONE_INDEX do return false
		object := &world.objects[object_index]
		if object.state == .Free do return false
		object.inflight_count += 1
		return true
	}

	@(private = "file")
	_sim_unpin_object :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) {
		world := backend.sim_world
		if object_index == SIM_OBJECT_NONE_INDEX do return
		object := &world.objects[object_index]
		if object.inflight_count > 0 {
			object.inflight_count -= 1
		}
		_sim_maybe_free_object(backend, object_index)
	}

	@(private = "file")
	_sim_close_descriptor_index :: proc "contextless" (backend: ^Platform_Backend, descriptor_index: u16) -> bool {
		world := backend.sim_world
		if descriptor_index == SIM_DESCRIPTOR_NONE_INDEX do return false
		if descriptor_index >= MAX_SIMULATED_DESCRIPTORS do return false
		descriptor := &world.descriptors[descriptor_index]
		if descriptor.state == .Free {
			return false
		}
		object_index := descriptor.object_index
		descriptor^ = Sim_FD_Descriptor {
			fd_number = OS_FD_INVALID,
			object_index = SIM_OBJECT_NONE_INDEX,
			next_free_index = world.descriptor_free_head,
		}
		world.descriptor_free_head = descriptor_index
		world.descriptor_free_count += 1
		_sim_object_release_ref(backend, object_index)
		return true
	}

	@(private = "file")
	_sim_validate_submission_targets :: proc "contextless" (
		backend: ^Platform_Backend,
		op: ^Submission_Operation,
	) -> (
		Simulated_Submission_Targets,
		bool,
	) {
		world := backend.sim_world
		fd := _sim_submission_fd(op)
		descriptor_index := _sim_lookup_descriptor_index(backend, fd)
		if descriptor_index == SIM_DESCRIPTOR_NONE_INDEX {
			return {}, false
		}
		object_index := world.descriptors[descriptor_index].object_index
		if object_index == SIM_OBJECT_NONE_INDEX do return {}, false
		if world.objects[object_index].state == .Free do return {}, false

		targets := Simulated_Submission_Targets {
			descriptor_index    = descriptor_index,
			object_index        = object_index,
			object_index_second = SIM_OBJECT_NONE_INDEX,
		}

		if sf, is_sendfile := op.(Submission_Op_Sendfile); is_sendfile {
			file_descriptor_index := _sim_lookup_descriptor_index(backend, sf.fd_file)
			if file_descriptor_index == SIM_DESCRIPTOR_NONE_INDEX {
				return {}, false
			}
			file_object_index := world.descriptors[file_descriptor_index].object_index
			if file_object_index == SIM_OBJECT_NONE_INDEX do return {}, false
			if world.objects[file_object_index].state == .Free do return {}, false
			targets.object_index_second = file_object_index
			targets.has_second_pin = true
		}
		return targets, true
	}

	@(private = "file")
	_sim_store_completion :: proc "contextless" (
		backend: ^Platform_Backend,
		completion: Raw_Completion,
	) -> Backend_Completion_Store_Result {
		if backend.completed_count >= MAX_SIMULATED_COMPLETED {
			return .Capacity_Exhausted
		}
		backend.completed[backend.completed_tail] = completion
		backend.completed_tail = (backend.completed_tail + 1) % MAX_SIMULATED_COMPLETED
		backend.completed_count += 1
		return .Stored
	}

	@(private = "file")
	_sim_submission_fd :: #force_inline proc "contextless" (op: ^Submission_Operation) -> OS_FD {
		switch o in op^ {
		case Submission_Op_Read:     return o.fd
		case Submission_Op_Write:    return o.fd
		case Submission_Op_Accept:   return o.listen_fd
		case Submission_Op_Connect:  return o.fd_socket
		case Submission_Op_Close:    return o.fd
		case Submission_Op_Send:     return o.fd_socket
		case Submission_Op_Recv:     return o.fd_socket
		case Submission_Op_Sendto:   return o.fd_socket
		case Submission_Op_Recvfrom: return o.fd_socket
		case Submission_Op_Sendfile: return o.fd_socket
		}
		return OS_FD_INVALID
	}

	@(private = "file")
	_sim_bind_allows_shared_port :: #force_inline proc "contextless" (
		candidate: ^Sim_FD_Object,
		existing: ^Sim_FD_Object,
	) -> bool {
		if candidate == nil do return false
		if existing == nil do return false
		if .Exclusive_Address_Use in candidate.attributes do return false
		if .Exclusive_Address_Use in existing.attributes do return false
		if .Reuse_Port not_in candidate.attributes do return false
		return .Reuse_Port in existing.attributes
	}

	@(private = "file")
	_sim_bind_addresses_overlap :: proc "contextless" (
		left: Socket_Address,
		right: Socket_Address,
	) -> bool {
		#partial switch left_address in left {
		case Socket_Address_Inet4:
			right_address, ok := right.(Socket_Address_Inet4)
			if !ok {
				return false
			}
			if left_address.port != right_address.port {
				return false
			}
			left_is_wildcard := _sim_is_ipv4_wildcard(left_address.address)
			right_is_wildcard := _sim_is_ipv4_wildcard(right_address.address)
			return left_is_wildcard || right_is_wildcard || left_address.address == right_address.address
		case Socket_Address_Inet6:
			right_address, ok := right.(Socket_Address_Inet6)
			if !ok {
				return false
			}
			if left_address.port != right_address.port {
				return false
			}
			left_is_unspecified := _sim_is_ipv6_unspecified(left_address.address)
			right_is_unspecified := _sim_is_ipv6_unspecified(right_address.address)
			return left_is_unspecified || right_is_unspecified || (
				left_address.address == right_address.address &&
				left_address.flow == right_address.flow &&
				left_address.scope == right_address.scope
			)
		case Socket_Address_Unix:
			right_address, ok := right.(Socket_Address_Unix)
			if !ok {
				return false
			}
			return left_address.path == right_address.path
		}
		return false
	}

	@(private = "file")
	_sim_is_ipv4_wildcard :: #force_inline proc "contextless" (address: [4]u8) -> bool {
		return address == [4]u8{}
	}

	@(private = "file")
	_sim_is_ipv6_unspecified :: #force_inline proc "contextless" (address: [16]u8) -> bool {
		return address == [16]u8{}
	}

	// Derive a deterministic per-operation value from (seed, tick, token).
	// This is an accepted implementation of the ADR's per-domain determinism goal:
	// the seed still roots the backend in the shard's simulation domain, while the
	// hash-style derivation avoids accidental dependence on local iteration order
	// or batch packing details inside backend_submit/backend_collect.
	@(private = "file")
	_sim_op_hash :: #force_inline proc "contextless" (
		seed: u64,
		tick: u64,
		token: Submission_Token,
	) -> u64 {
		mixed := seed ~ (tick * ~u64(0x9E3779B97F4A7C15)) ~ (u64(token) * ~u64(0x517CC1B727220A95))
		p: Prng
		prng_init(&p, mixed)
		return prng_step(&p)
	}

	@(private = "file")
	_sim_generate_success :: proc(
		backend: ^Platform_Backend,
		op: ^Simulated_Operation,
		completion: ^Raw_Completion,
	) {
		switch _ in op.operation {
		case Submission_Op_Read:
			completion.result = i32(min(op.data_size, 128))
		case Submission_Op_Write:
			completion.result = i32(op.data_size)
		case Submission_Op_Accept:
			object_index := _sim_alloc_object(backend)
			if object_index == SIM_OBJECT_NONE_INDEX {
				completion.result = SIM_ERR_NFILE
				break
			}
			client_fd := _sim_alloc_descriptor(backend, object_index)
			if client_fd == OS_FD_INVALID {
				_sim_object_release_ref(backend, object_index)
				completion.result = SIM_ERR_NFILE
				break
			}
			completion.result = 0
			completion.extra = Completion_Extra_Accept {
				client_fd = client_fd,
				client_address = Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 9999},
			}
		case Submission_Op_Connect:
			completion.result = 0
		case Submission_Op_Close:
			completion.result = 0
		case Submission_Op_Send:
			completion.result = i32(op.data_size)
		case Submission_Op_Recv:
			completion.result = i32(min(op.data_size, 128))
		case Submission_Op_Sendto:
			completion.result = i32(op.data_size)
		case Submission_Op_Recvfrom:
			completion.result = i32(min(op.data_size, 128))
			completion.extra = Completion_Extra_Recvfrom {
				peer_address = Socket_Address_Inet4{address = {10, 0, 0, 1}, port = 5000},
			}
		case Submission_Op_Sendfile:
			sf := op.operation.(Submission_Op_Sendfile)
			completion.result = i32(min(sf.size, 65536))
		case:
			completion.result = 0
		}
	}

	@(private = "file")
	_sim_sample_error :: proc(backend: ^Platform_Backend, token: Submission_Token) -> i32 {
		dist := backend.config.error_distribution
		if len(dist) == 0 {
			return i32(IO_ERR_RESOURCE_EXHAUSTED) // fallback
		}

		// Compute total weight
		total_weight: u64 = 0
		for entry in dist {
			total_weight += u64(entry.weight)
		}
		if total_weight == 0 {
			return i32(IO_ERR_RESOURCE_EXHAUSTED) // fallback
		}

		// Deterministic sample using a different hash phase (0x2) to avoid
		// correlation with fault occurrence decision (which uses 0x1)
		h := _sim_op_hash(backend.seed ~ 0x2, backend.tick_count, token)
		sample := h % total_weight

		// Cumulative weight selection
		cumulative: u64 = 0
		for entry in dist {
			cumulative += u64(entry.weight)
			if sample < cumulative {
				return entry.error_code
			}
		}

		// Should be unreachable, but return last entry as safety
		return dist[len(dist) - 1].error_code
	}

	// ============================================================================
	// Tests
	// ============================================================================

	@(test)
	test_simulated_backend_init :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
			sim_config = Simulation_IO_Config{delay_range_ticks = {1, 3}, seed = t.seed, world = cast(rawptr)world},
		}

		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 0)
		testing.expect(t, world.next_sim_fd >= 100, "sim FD should start at 100+")

		backend_deinit(&backend)
	}

	@(test)
	test_simulated_backend_submit_collect :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {0, 1}, // complete within 1 tick
				seed              = t.seed,
				world             = world,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, IO_Operation_Kind(3))
		submissions := [1]Submission {
			{
				token = token,
				operation = Submission_Op_Connect {
					fd_socket = fd,
					address = Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 8080},
				},
			},
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 1)

		completions: [8]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count := collect_result.completion_count
		testing.expect(t, count >= 1, "should have at least 1 completion")
		testing.expect_value(t, completions[0].token, token)
		testing.expect_value(t, completions[0].result, 0)

	}

	@(test)
	test_simulated_backend_cancel :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {100, 200}, // won't complete soon
				seed              = t.seed,
				world             = world,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		token := submission_token_pack(1, 5, 0, 0, IO_SLOT_INDEX_NONE, IO_Operation_Kind(1))
		submissions := [1]Submission {
			{token = token, data_size = 4096, operation = Submission_Op_Recv{fd_socket = fd}},
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 1)

		cancel_error := backend_cancel(&backend, token)
		testing.expect_value(t, cancel_error, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 0)

		// Cancel again should return Not_Found
		cancel_err2 := backend_cancel(&backend, token)
		testing.expect_value(t, cancel_err2, Backend_Error.Not_Found)

	}

	@(test)
	test_simulated_backend_control_socket :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config{seed = t.seed, world = cast(rawptr)world},
		}
		backend_init(&backend, config)

		fd1, err1 := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, err1, Backend_Error.None)

		fd2, err2 := backend_control_socket(&backend, .AF_INET, .DGRAM, .UDP)
		testing.expect_value(t, err2, Backend_Error.None)

		// Each call should return a unique FD
		testing.expect(t, fd1 != fd2, "simulated FDs should be unique")

		backend_deinit(&backend)
	}

	@(test)
	test_simulated_backend_determinism :: proc(t: ^testing.T) {
		seed := t.seed

		run_sim :: proc(seed: u64) -> [4]Raw_Completion {
			world := new(Sim_IO_World, context.temp_allocator)
			_sim_world_init(world)
			backend: Platform_Backend
			config := Backend_Config {
				sim_config = Simulation_IO_Config{delay_range_ticks = {1, 5}, seed = seed, world = cast(rawptr)world},
			}
			backend_init(&backend, config)
			defer backend_deinit(&backend)

			fds: [4]OS_FD
			for i in 0 ..< 4 {
				fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
				if sock_error != .None {
					return [4]Raw_Completion{}
				}
				fds[i] = fd
			}

			// Submit 4 operations
			submissions: [4]Submission
			for i in 0 ..< 4 {
				submissions[i] = Submission {
					token = submission_token_pack(0, u32(i), 0, 0, IO_SLOT_INDEX_NONE, IO_Operation_Kind(7)),
					data_size = 1024,
					operation = Submission_Op_Recv{fd_socket = fds[i]},
				}
			}
			submit_result := backend_submit(&backend, submissions[:])
			if submit_result != .None {
				return [4]Raw_Completion{}
			}

			// Collect over several ticks
			result: [4]Raw_Completion
			collected: u32 = 0
			for tick in 0 ..< 20 {
				if collected >= 4 do break
				buf: [4]Raw_Completion
				collect_result := backend_collect(&backend, buf[:], 0)
				if collect_result.fault != .None {
					return [4]Raw_Completion{}
				}
				count := collect_result.completion_count
				for j: u32 = 0; j < count && collected < 4; j += 1 {
					result[collected] = buf[j]
					collected += 1
				}
			}
			return result
		}

		result1 := run_sim(seed)
		result2 := run_sim(seed)

		// Same seed → same sequence of completions
		for i in 0 ..< 4 {
			testing.expect_value(t, result1[i].token, result2[i].token)
			testing.expect_value(t, result1[i].result, result2[i].result)
		}
	}

	@(test)
	test_simulated_backend_collect_uses_shard_controlled_time :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {1, 1},
				seed              = t.seed,
				world             = world,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		backend_set_current_tick(&backend, 7)

		token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, IO_Operation_Kind(5))
		submissions := [1]Submission {
			{
				token = token,
				data_size = 256,
				operation = Submission_Op_Recv {
					fd_socket = fd,
				},
			},
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)

		completions: [1]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count_first := collect_result.completion_count
		testing.expect_value(t, count_first, u32(0))

		collect_result = backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count_second := collect_result.completion_count
		testing.expect_value(t, count_second, u32(0))
		testing.expect_value(t, backend.tick_count, u64(7))

		backend_set_current_tick(&backend, 8)
		collect_result = backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count_third := collect_result.completion_count
		testing.expect_value(t, count_third, u32(1))
		testing.expect_value(t, completions[0].token, token)
	}

	@(test)
	test_simulated_backend_error_distribution :: proc(t: ^testing.T) {
		// Define a distribution: 50% ECONNRESET (-104), 50% EPIPE (-32)
		dist := [2]Error_Weight {
			{error_code = -104, weight = 1},
			{error_code = -32, weight = 1},
		}

		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks  = {0, 1},
				fault_rate         = Ratio{numerator = 1, denominator = 1}, // 100% fault rate
				seed               = t.seed,
				error_distribution = dist[:],
				world              = world,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Recv_Complete)
		submissions := [1]Submission {
			{token = token, data_size = 1024, operation = Submission_Op_Recv{fd_socket = fd}},
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)

		completions: [4]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count := collect_result.completion_count
		testing.expect(t, count >= 1, "should have at least 1 completion")

		// With 100% fault rate, the result should be one of our distribution errors
		result := completions[0].result
		testing.expect(
			t,
			result == -104 || result == -32,
			"fault result should be from the error distribution",
		)

	}

	@(test)
	test_simulated_backend_control_dup_returns_distinct_fd :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {seed = t.seed, world = cast(rawptr)world},
		}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		dup_fd, dup_error := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_error, Backend_Error.None)
		testing.expect(t, dup_fd != fd, "simulated dup must return a distinct descriptor")

		descriptor := _sim_lookup_descriptor(&backend, dup_fd)
		testing.expect(t, descriptor != nil, "dup fd should resolve in simulated descriptor table")
		if descriptor != nil {
			testing.expect_value(t, descriptor.state, Sim_FD_Descriptor_State.Open_Close_On_Exec)
		}
	}

	@(test)
	test_simulated_backend_close_invalidates_only_closed_descriptor :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {seed = t.seed, world = cast(rawptr)world},
		}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)
		descriptor_index := _sim_lookup_descriptor_index(&backend, fd)
		testing.expect(t, descriptor_index != SIM_DESCRIPTOR_NONE_INDEX, "open descriptor must have a table index")
		dup_fd, dup_error := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_error, Backend_Error.None)

		close_error := backend_control_close(&backend, fd)
		testing.expect_value(t, close_error, Backend_Error.None)

		original_descriptor := _sim_lookup_descriptor(&backend, fd)
		testing.expect(t, original_descriptor == nil, "closed descriptor should be invalidated")
		if descriptor_index != SIM_DESCRIPTOR_NONE_INDEX {
			freed_descriptor := &world.descriptors[descriptor_index]
			testing.expect_value(t, freed_descriptor.state, Sim_FD_Descriptor_State.Free)
			testing.expect_value(t, freed_descriptor.fd_number, OS_FD_INVALID)
			testing.expect_value(t, freed_descriptor.object_index, SIM_OBJECT_NONE_INDEX)
		}
		duplicate_descriptor := _sim_lookup_descriptor(&backend, dup_fd)
		testing.expect(t, duplicate_descriptor != nil, "duplicate descriptor should remain active")

		shutdown_error := backend_control_shutdown(&backend, dup_fd, .SHUT_BOTH)
		testing.expect_value(t, shutdown_error, Backend_Error.None)
	}

	@(test)
	test_simulated_backend_pending_op_survives_close_of_duplicate_descriptor :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {2, 2},
				seed = t.seed,
				world = cast(rawptr)world,
			},
		}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)
		dup_fd, dup_error := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_error, Backend_Error.None)

		token := submission_token_pack(2, 0, 0, 0, IO_SLOT_INDEX_NONE, .Recv_Complete)
		submissions := [1]Submission {
			{token = token, data_size = 256, operation = Submission_Op_Recv{fd_socket = fd}},
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)

		close_error := backend_control_close(&backend, dup_fd)
		testing.expect_value(t, close_error, Backend_Error.None)

		completions: [2]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count := collect_result.completion_count
		testing.expect_value(t, count, u32(0))

		collect_result = backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count = collect_result.completion_count
		testing.expect_value(t, count, u32(1))
		testing.expect_value(t, completions[0].token, token)
		testing.expect(t, completions[0].result >= 0, "pending op should still complete after duplicate close")
	}

	@(test)
	test_simulated_accept_completion_returns_tracked_descriptor :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {0, 0},
				seed = t.seed,
				world = cast(rawptr)world,
			},
		}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		listen_fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, .Accept_Complete)
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Accept{listen_fd = listen_fd}},
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)

		completions: [2]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		count := collect_result.completion_count
		testing.expect_value(t, count, u32(1))

		accept_extra, ok := completions[0].extra.(Completion_Extra_Accept)
		testing.expect(t, ok, "accept completion should carry accept extra")
		descriptor := _sim_lookup_descriptor(&backend, accept_extra.client_fd)
		testing.expect(t, descriptor != nil, "accepted client fd should be tracked by simulated backend")
	}

	@(test)
	test_simulated_backend_deinit_closes_only_unread_accepts :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {0, 0},
				seed = t.seed,
				world = cast(rawptr)world,
			},
		}
		testing.expect_value(t, backend_init(&backend, config), Backend_Error.None)

		listen_fd, socket_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, socket_error, Backend_Error.None)
		descriptor_free_count_before := world.descriptor_free_count
		object_free_count_before := world.object_free_count

		submissions: [2]Submission
		for submission_index in 0 ..< len(submissions) {
			submissions[submission_index] = Submission {
				token = submission_token_pack(
					0,
					u32(submission_index),
					0,
					0,
					IO_SLOT_INDEX_NONE,
					.Accept_Complete,
				),
				operation = Submission_Op_Accept{listen_fd = listen_fd},
			}
		}
		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)

		completions: [1]Raw_Completion
		collect_result := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
		testing.expect_value(t, collect_result.completion_count, u32(1))
		testing.expect_value(t, backend.completed_count, u16(1))
		testing.expect_value(t, world.descriptor_free_count, descriptor_free_count_before - 2)
		testing.expect_value(t, world.object_free_count, object_free_count_before - 2)

		backend_deinit(&backend)

		// The delivered accept belongs to the reactor; only the unread accept was
		// still backend-owned when teardown discarded the completion ring.
		testing.expect_value(t, world.descriptor_free_count, descriptor_free_count_before - 1)
		testing.expect_value(t, world.object_free_count, object_free_count_before - 1)
	}

	@(test)
	test_simulated_backend_bind_rejects_duplicate_exclusive_address :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {seed = t.seed, world = cast(rawptr)world},
		}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		address := Socket_Address_Inet4 {address = {127, 0, 0, 1}, port = 8080}

		first_fd, first_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, first_error, Backend_Error.None)
		first_bind_error := backend_control_bind(&backend, first_fd, address)
		testing.expect_value(t, first_bind_error, Backend_Error.None)

		second_fd, second_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, second_error, Backend_Error.None)
		second_bind_error := backend_control_bind(&backend, second_fd, address)
		testing.expect_value(t, second_bind_error, Backend_Error.Address_In_Use)
	}

	@(test)
	test_simulated_backend_bind_accepts_duplicate_reuse_port_address :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {seed = t.seed, world = cast(rawptr)world},
		}
		error := backend_init(&backend, config)
		testing.expect_value(t, error, Backend_Error.None)
		defer backend_deinit(&backend)

		address := Socket_Address_Inet4 {address = {127, 0, 0, 1}, port = 8080}

		first_fd, first_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, first_error, Backend_Error.None)
		testing.expect_value(
			t,
			backend_control_setsockopt(&backend, first_fd, .SOL_SOCKET, .SO_REUSEPORT, bool(true)),
			Backend_Error.None,
		)
		testing.expect_value(t, backend_control_bind(&backend, first_fd, address), Backend_Error.None)

		second_fd, second_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, second_error, Backend_Error.None)
		testing.expect_value(
			t,
			backend_control_setsockopt(&backend, second_fd, .SOL_SOCKET, .SO_REUSEPORT, bool(true)),
			Backend_Error.None,
		)
		testing.expect_value(t, backend_control_bind(&backend, second_fd, address), Backend_Error.None)
	}

	// Contract: every accepted submission must yield exactly one completion.
	// This is the LSP contract for all backends — SimulatedIO is the oracle.
	@(test)
	test_simulated_backend_accepted_submission_yields_exactly_one_completion :: proc(t: ^testing.T) {
		world := new(Sim_IO_World, context.temp_allocator)
		_sim_world_init(world)
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {0, 3},
				seed              = t.seed,
				world             = cast(rawptr)world,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_error := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_error, Backend_Error.None)

		submission_count := 8
		submissions: [8]Submission
		tokens: [8]Submission_Token
		for i in 0 ..< submission_count {
			tokens[i] = submission_token_pack(
				0, u32(i), 1, u8(i), IO_SLOT_INDEX_NONE, .Recv_Complete,
			)
			submissions[i] = Submission {
				token      = tokens[i],
				data_size  = 256,
				operation  = Submission_Op_Recv{fd_socket = fd},
			}
		}

		submit_result := backend_submit(&backend, submissions[:])
		testing.expect_value(t, submit_result, Backend_Error.None)

		collected: u32 = 0
		seen: [8]bool
		for tick in 0 ..< 20 {
			if collected >= u32(submission_count) do break
			buf: [8]Raw_Completion
			collect_result := backend_collect(&backend, buf[:], 0)
			testing.expect_value(t, collect_result.fault, Backend_Collect_Fault.None)
			count := collect_result.completion_count
			for j in 0 ..< count {
				idx := submission_token_slot_index(buf[j].token)
				testing.expect(t, int(idx) < submission_count, "completion token slot out of range")
				testing.expect(t, !seen[idx], "duplicate completion for same token")
				seen[idx] = true
				collected += 1
			}
		}

		testing.expect_value(t, collected, u32(submission_count))
		testing.expect_value(t, backend.pending_count, u16(0))
		testing.expect_value(t, backend.completed_count, u16(0))
	}

} // when TINA_SIM
