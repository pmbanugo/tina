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

	MAX_SIMULATED_PENDING :: 1024
	MAX_SIMULATED_DESCRIPTORS :: 4096
	MAX_SIMULATED_OBJECTS :: 4096
	SIM_DESCRIPTOR_NONE_INDEX :: u16(0xFFFF)
	SIM_OBJECT_NONE_INDEX :: u16(0xFFFF)
	SIM_ERR_BADF :: i32(-9)
	SIM_ERR_NFILE :: i32(-24)

	Sim_FD_Object :: struct {
		ref_count:       u16,
		inflight_count:  u16,
		next_free_index: u16,
		alive:           bool,
		_padding:        [3]u8,
	}

	Sim_FD_Descriptor :: struct {
		fd_number:       OS_FD,
		object_index:    u16,
		next_free_index: u16,
		active:          bool,
		cloexec:         bool,
		_padding:        [6]u8,
	}

	Simulated_Operation :: struct {
		token:          Submission_Token,
		operation:      Submission_Operation,
		submitted_tick: u64,
		delay_ticks:    u64,
		descriptor_index: u16,
		object_index:   u16,
		object_index_second: u16,
		has_second_pin:      bool,
		_padding:       [1]u8,
	}

	Sim_FD_State :: struct {
		descriptors:          [MAX_SIMULATED_DESCRIPTORS]Sim_FD_Descriptor,
		objects:              [MAX_SIMULATED_OBJECTS]Sim_FD_Object,
		descriptor_free_head: u16,
		descriptor_free_count: u16,
		object_free_head:     u16,
		object_free_count:    u16,
		active_backend_count: u16,
		_padding:             u16,
		next_sim_fd:          i32,
	}

	@(private = "package")
	@(thread_local)
	g_sim_fd_state: Sim_FD_State

	_Platform_State :: struct {
		pending:       [MAX_SIMULATED_PENDING]Simulated_Operation,
		pending_count: u16,
		prng:          Prng, // used only for reordering (order-dependent is OK)
		seed:          u64, // original seed for per-op deterministic derivation
		tick_count:    u64,
		config:        Simulation_IO_Config,
	}

	@(private = "package")
	_backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
		backend.pending_count = 0
		backend.tick_count = 0
		backend.config = config.sim_config
		if g_sim_fd_state.active_backend_count == 0 {
			_sim_fd_state_reset()
		}
		g_sim_fd_state.active_backend_count += 1

		// Seed from config — populated from Prng_Tree at shard hydration,
		// or from t.seed in tests.
		backend.seed = config.sim_config.seed
		prng_init(&backend.prng, backend.seed)
		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		backend.pending_count = 0
		if g_sim_fd_state.active_backend_count > 0 {
			g_sim_fd_state.active_backend_count -= 1
		}
		if g_sim_fd_state.active_backend_count == 0 {
			_sim_fd_state_reset()
		}
	}

	@(private = "package")
	_backend_submit :: proc(
		backend: ^Platform_Backend,
		submissions: []Submission,
	) -> Backend_Error {
		for &sub in submissions {
			if backend.pending_count >= MAX_SIMULATED_PENDING {
				return .Queue_Full
			}

			descriptor_index, object_index, valid := _sim_pin_submission_targets(backend, &sub.operation)
			if !valid {
				return .System_Error
			}

			// Sendfile needs a second pin for the fd_file
			object_index_second: u16 = SIM_OBJECT_NONE_INDEX
			has_second_pin := false
			if sf, ok := sub.operation.(Submission_Op_Sendfile); ok {
				file_desc_index, file_ok := _sim_lookup_descriptor_index(backend, sf.fd_file)
				if !file_ok {
					_sim_unpin_object(backend, object_index)
					return .System_Error
				}
				file_object_index := g_sim_fd_state.descriptors[file_desc_index].object_index
				if !_sim_pin_object(backend, file_object_index) {
					_sim_unpin_object(backend, object_index)
					return .System_Error
				}
				object_index_second = file_object_index
				has_second_pin = true
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
				submitted_tick       = backend.tick_count,
				delay_ticks          = delay,
				descriptor_index     = descriptor_index,
				object_index         = object_index,
				object_index_second  = object_index_second,
				has_second_pin       = has_second_pin,
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
	) -> (
		u32,
		Backend_Error,
	) {
		backend.tick_count += 1
		completed_count: u32 = 0

		// Scan pending for operations whose delay has elapsed
		i: u16 = 0
		for i < backend.pending_count {
			op := &backend.pending[i]

			if backend.tick_count >= op.submitted_tick + op.delay_ticks {
				if completed_count >= u32(len(completions)) {
					break // output buffer full
				}

				completion := &completions[completed_count]
				completion.token = op.token
				completion.extra = nil

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
						completion.result = _sim_sample_error(backend, op.token)
					} else {
						_sim_generate_success(backend, op, completion)
					}
				} else {
					_sim_generate_success(backend, op, completion)
				}

				if completion.result >= 0 {
					if _, ok := op.operation.(Submission_Op_Close); ok {
						if !_sim_close_descriptor_index(backend, op.descriptor_index) {
							completion.result = SIM_ERR_BADF
						}
					}
				}

				_sim_unpin_object(backend, op.object_index)
				if op.has_second_pin {
					_sim_unpin_object(backend, op.object_index_second)
				}

				completed_count += 1

				// Remove by swapping with last (order doesn't matter in pending array)
				backend.pending_count -= 1
				if i < backend.pending_count {
					backend.pending[i] = backend.pending[backend.pending_count]
				}
				// Don't increment i — we need to check the swapped-in element
			} else {
				i += 1
			}
		}

		// Optional reordering of completions
		if backend.config.reorder && completed_count > 1 {
			for j: u32 = 0; j < completed_count - 1; j += 1 {
				remaining := completed_count - j
				swap_index := j + u32(prng_uint_less_than(&backend.prng, remaining))
				completions[j], completions[swap_index] = completions[swap_index], completions[j]
			}
		}

		return completed_count, .None
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
		object_index, ok := _sim_alloc_object(backend)
		if !ok {
			return OS_FD_INVALID, .System_Error
		}
		fd, descriptor_ok := _sim_alloc_descriptor(backend, object_index, true)
		if !descriptor_ok {
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
		if _, ok := _sim_lookup_descriptor(backend, fd); !ok do return .System_Error
		return .None
	}

	@(private = "package")
	_backend_control_listen :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		backlog: u32,
	) -> Backend_Error {
		if _, ok := _sim_lookup_descriptor(backend, fd); !ok do return .System_Error
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
		if _, ok := _sim_lookup_descriptor(backend, fd); !ok do return .System_Error
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
		if _, ok := _sim_lookup_descriptor(backend, fd); !ok do return nil, .System_Error
		// Simulation returns a default value
		return i32(0), .None
	}

	@(private = "package")
	_backend_control_shutdown :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		how: Shutdown_How,
	) -> Backend_Error {
		if _, ok := _sim_lookup_descriptor(backend, fd); !ok do return .System_Error
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
		descriptor_index, ok := _sim_lookup_descriptor_index(backend, fd)
		if !ok do return .System_Error
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
		desc, ok := _sim_lookup_descriptor(backend, fd)
		if !ok {
			return OS_FD_INVALID, .System_Error
		}
		object := &g_sim_fd_state.objects[desc.object_index]
		object.ref_count += 1
		dup_fd, alloc_ok := _sim_alloc_descriptor(backend, desc.object_index, true)
		if !alloc_ok {
			object.ref_count -= 1
			return OS_FD_INVALID, .System_Error
		}
		return dup_fd, .None
	}

	@(private = "package")
	_backend_register_fixed_fd :: proc "contextless" (backend: ^Platform_Backend, slot_index: u16, fd: OS_FD) {
		// No-op: SimulatedIO has no kernel fixed-file table.
	}

	@(private = "package")
	_backend_unregister_fixed_fd :: proc "contextless" (backend: ^Platform_Backend, slot_index: u16) {
		// No-op: SimulatedIO has no kernel fixed-file table.
	}

	// --- Internal Helpers ---

	@(private = "package")
	_sim_fd_state_reset :: proc "contextless" () {
		g_sim_fd_state.descriptor_free_head = SIM_DESCRIPTOR_NONE_INDEX
		g_sim_fd_state.descriptor_free_count = MAX_SIMULATED_DESCRIPTORS
		for i := MAX_SIMULATED_DESCRIPTORS - 1; i >= 0; i -= 1 {
			g_sim_fd_state.descriptors[i] = Sim_FD_Descriptor {
				fd_number = OS_FD_INVALID,
				object_index = SIM_OBJECT_NONE_INDEX,
				next_free_index = g_sim_fd_state.descriptor_free_head,
			}
			g_sim_fd_state.descriptor_free_head = u16(i)
		}

		g_sim_fd_state.object_free_head = SIM_OBJECT_NONE_INDEX
		g_sim_fd_state.object_free_count = MAX_SIMULATED_OBJECTS
		for i := MAX_SIMULATED_OBJECTS - 1; i >= 0; i -= 1 {
			g_sim_fd_state.objects[i] = Sim_FD_Object {
				next_free_index = g_sim_fd_state.object_free_head,
			}
			g_sim_fd_state.object_free_head = u16(i)
		}
		g_sim_fd_state.next_sim_fd = 100
	}

	@(private = "file")
	_sim_alloc_object :: proc "contextless" (backend: ^Platform_Backend) -> (u16, bool) {
		if g_sim_fd_state.object_free_head == SIM_OBJECT_NONE_INDEX {
			return SIM_OBJECT_NONE_INDEX, false
		}
		index := g_sim_fd_state.object_free_head
		object := &g_sim_fd_state.objects[index]
		g_sim_fd_state.object_free_head = object.next_free_index
		g_sim_fd_state.object_free_count -= 1
		object^ = Sim_FD_Object {
			ref_count = 1,
			inflight_count = 0,
			next_free_index = SIM_OBJECT_NONE_INDEX,
			alive = true,
		}
		return index, true
	}

	@(private = "file")
	_sim_alloc_descriptor :: proc "contextless" (
		backend: ^Platform_Backend,
		object_index: u16,
		cloexec: bool,
	) -> (
		OS_FD,
		bool,
	) {
		if g_sim_fd_state.descriptor_free_head == SIM_DESCRIPTOR_NONE_INDEX {
			return OS_FD_INVALID, false
		}
		index := g_sim_fd_state.descriptor_free_head
		desc := &g_sim_fd_state.descriptors[index]
		g_sim_fd_state.descriptor_free_head = desc.next_free_index
		g_sim_fd_state.descriptor_free_count -= 1

		fd_number := OS_FD(g_sim_fd_state.next_sim_fd)
		g_sim_fd_state.next_sim_fd += 1
		desc^ = Sim_FD_Descriptor {
			fd_number = fd_number,
			object_index = object_index,
			next_free_index = SIM_DESCRIPTOR_NONE_INDEX,
			active = true,
			cloexec = cloexec,
		}
		return fd_number, true
	}

	@(private = "package")
	_sim_lookup_descriptor_index :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> (u16, bool) {
		for i in 0 ..< MAX_SIMULATED_DESCRIPTORS {
			desc := &g_sim_fd_state.descriptors[i]
			if desc.active && desc.fd_number == fd {
				return u16(i), true
			}
		}
		return SIM_DESCRIPTOR_NONE_INDEX, false
	}

	@(private = "package")
	_sim_lookup_descriptor :: proc "contextless" (backend: ^Platform_Backend, fd: OS_FD) -> (^Sim_FD_Descriptor, bool) {
		index, ok := _sim_lookup_descriptor_index(backend, fd)
		if !ok {
			return nil, false
		}
		return &g_sim_fd_state.descriptors[index], true
	}

	@(private = "file")
	_sim_maybe_free_object :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) {
		if object_index == SIM_OBJECT_NONE_INDEX do return
		object := &g_sim_fd_state.objects[object_index]
		if !object.alive || object.ref_count != 0 || object.inflight_count != 0 do return
		object.alive = false
		object.next_free_index = g_sim_fd_state.object_free_head
		g_sim_fd_state.object_free_head = object_index
		g_sim_fd_state.object_free_count += 1
	}

	@(private = "file")
	_sim_object_release_ref :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) {
		if object_index == SIM_OBJECT_NONE_INDEX do return
		object := &g_sim_fd_state.objects[object_index]
		if object.ref_count > 0 {
			object.ref_count -= 1
		}
		_sim_maybe_free_object(backend, object_index)
	}

	@(private = "file")
	_sim_pin_object :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) -> bool {
		if object_index == SIM_OBJECT_NONE_INDEX do return false
		object := &g_sim_fd_state.objects[object_index]
		if !object.alive do return false
		object.inflight_count += 1
		return true
	}

	@(private = "file")
	_sim_unpin_object :: proc "contextless" (backend: ^Platform_Backend, object_index: u16) {
		if object_index == SIM_OBJECT_NONE_INDEX do return
		object := &g_sim_fd_state.objects[object_index]
		if object.inflight_count > 0 {
			object.inflight_count -= 1
		}
		_sim_maybe_free_object(backend, object_index)
	}

	@(private = "file")
	_sim_close_descriptor_index :: proc "contextless" (backend: ^Platform_Backend, descriptor_index: u16) -> bool {
		if descriptor_index == SIM_DESCRIPTOR_NONE_INDEX || descriptor_index >= MAX_SIMULATED_DESCRIPTORS {
			return false
		}
		desc := &g_sim_fd_state.descriptors[descriptor_index]
		if !desc.active {
			return false
		}
		object_index := desc.object_index
		desc^ = Sim_FD_Descriptor {
			fd_number = OS_FD_INVALID,
			object_index = SIM_OBJECT_NONE_INDEX,
			next_free_index = g_sim_fd_state.descriptor_free_head,
		}
		g_sim_fd_state.descriptor_free_head = descriptor_index
		g_sim_fd_state.descriptor_free_count += 1
		_sim_object_release_ref(backend, object_index)
		return true
	}

	@(private = "file")
	_sim_pin_submission_targets :: proc "contextless" (
		backend: ^Platform_Backend,
		op: ^Submission_Operation,
	) -> (
		u16,
		u16,
		bool,
	) {
		fd := _sim_submission_fd(op)
		descriptor_index, ok := _sim_lookup_descriptor_index(backend, fd)
		if !ok {
			return SIM_DESCRIPTOR_NONE_INDEX, SIM_OBJECT_NONE_INDEX, false
		}
		object_index := g_sim_fd_state.descriptors[descriptor_index].object_index
		if !_sim_pin_object(backend, object_index) {
			return SIM_DESCRIPTOR_NONE_INDEX, SIM_OBJECT_NONE_INDEX, false
		}
		return descriptor_index, object_index, true
	}

	@(private = "file")
	_sim_submission_fd :: proc "contextless" (op: ^Submission_Operation) -> OS_FD {
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
			completion.result = i32(min(op.operation.(Submission_Op_Read).size, 128))
		case Submission_Op_Write:
			completion.result = i32(op.operation.(Submission_Op_Write).size)
		case Submission_Op_Accept:
			object_index, object_ok := _sim_alloc_object(backend)
			if !object_ok {
				completion.result = SIM_ERR_NFILE
				break
			}
			client_fd, descriptor_ok := _sim_alloc_descriptor(backend, object_index, true)
			if !descriptor_ok {
				if object_ok {
					_sim_object_release_ref(backend, object_index)
				}
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
			completion.result = i32(op.operation.(Submission_Op_Send).size)
		case Submission_Op_Recv:
			completion.result = i32(min(op.operation.(Submission_Op_Recv).size, 128))
		case Submission_Op_Sendto:
			completion.result = i32(op.operation.(Submission_Op_Sendto).size)
		case Submission_Op_Recvfrom:
			completion.result = i32(min(op.operation.(Submission_Op_Recvfrom).size, 128))
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
		backend: Platform_Backend
		config := Backend_Config {
			queue_size = DEFAULT_BACKEND_QUEUE_SIZE,
			sim_config = Simulation_IO_Config{delay_range_ticks = {1, 3}, seed = t.seed},
		}

		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 0)
		testing.expect(t, g_sim_fd_state.next_sim_fd >= 100, "sim FD should start at 100+")

		backend_deinit(&backend)
	}

	@(test)
	test_simulated_backend_submit_collect :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {0, 1}, // complete within 1 tick
				seed              = t.seed,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, 3)
		submissions := [1]Submission {
			{
				token = token,
				operation = Submission_Op_Connect {
					fd_socket = fd,
					address = Socket_Address_Inet4{address = {127, 0, 0, 1}, port = 8080},
				},
			},
		}
		sub_err := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_err, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 1)

		completions: [8]Raw_Completion
		count, collect_err := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_err, Backend_Error.None)
		testing.expect(t, count >= 1, "should have at least 1 completion")
		testing.expect_value(t, completions[0].token, token)
		testing.expect_value(t, completions[0].result, 0)

	}

	@(test)
	test_simulated_backend_cancel :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {100, 200}, // won't complete soon
				seed              = t.seed,
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		token := submission_token_pack(1, 5, 0, 0, BUFFER_INDEX_NONE, 1)
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Recv{fd_socket = fd, size = 4096}},
		}
		backend_submit(&backend, submissions[:])
		testing.expect_value(t, backend.pending_count, 1)

		cancel_err := backend_cancel(&backend, token)
		testing.expect_value(t, cancel_err, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 0)

		// Cancel again should return Not_Found
		cancel_err2 := backend_cancel(&backend, token)
		testing.expect_value(t, cancel_err2, Backend_Error.Not_Found)

	}

	@(test)
	test_simulated_backend_control_socket :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config{seed = t.seed},
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
			backend: Platform_Backend
			config := Backend_Config {
				sim_config = Simulation_IO_Config{delay_range_ticks = {1, 5}, seed = seed},
			}
			backend_init(&backend, config)
			defer backend_deinit(&backend)

			fds: [4]OS_FD
			for i in 0 ..< 4 {
				fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
				if sock_err != .None {
					return [4]Raw_Completion{}
				}
				fds[i] = fd
			}

			// Submit 4 operations
			submissions: [4]Submission
			for i in 0 ..< 4 {
				submissions[i] = Submission {
					token = submission_token_pack(0, u32(i), 0, 0, BUFFER_INDEX_NONE, 7),
					operation = Submission_Op_Recv{fd_socket = fds[i], size = 1024},
				}
			}
			backend_submit(&backend, submissions[:])

			// Collect over several ticks
			result: [4]Raw_Completion
			collected: u32 = 0
			for tick in 0 ..< 20 {
				if collected >= 4 do break
				buf: [4]Raw_Completion
				count, _ := backend_collect(&backend, buf[:], 0)
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
	test_simulated_backend_error_distribution :: proc(t: ^testing.T) {
		// Define a distribution: 50% ECONNRESET (-104), 50% EPIPE (-32)
		dist := [2]Error_Weight {
			{error_code = -104, weight = 1},
			{error_code = -32, weight = 1},
		}

		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks  = {0, 1},
				fault_rate         = Ratio{numerator = 1, denominator = 1}, // 100% fault rate
				seed               = t.seed,
				error_distribution = dist[:],
			},
		}
		backend_init(&backend, config)
		defer backend_deinit(&backend)

		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_RECV_COMPLETE))
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Recv{fd_socket = fd, size = 1024}},
		}
		backend_submit(&backend, submissions[:])

		completions: [4]Raw_Completion
		count, _ := backend_collect(&backend, completions[:], 0)
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
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {seed = t.seed},
		}
		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		dup_fd, dup_err := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_err, Backend_Error.None)
		testing.expect(t, dup_fd != fd, "simulated dup must return a distinct descriptor")

		desc, ok := _sim_lookup_descriptor(&backend, dup_fd)
		testing.expect(t, ok, "dup fd should resolve in simulated descriptor table")
		testing.expect(t, desc.cloexec, "simulated dup must set close-on-exec")
	}

	@(test)
	test_simulated_backend_close_invalidates_only_closed_descriptor :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {seed = t.seed},
		}
		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)
		dup_fd, dup_err := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_err, Backend_Error.None)

		close_err := backend_control_close(&backend, fd)
		testing.expect_value(t, close_err, Backend_Error.None)

		_, original_ok := _sim_lookup_descriptor(&backend, fd)
		testing.expect(t, !original_ok, "closed descriptor should be invalidated")
		_, dup_ok := _sim_lookup_descriptor(&backend, dup_fd)
		testing.expect(t, dup_ok, "duplicate descriptor should remain active")

		shutdown_err := backend_control_shutdown(&backend, dup_fd, .SHUT_BOTH)
		testing.expect_value(t, shutdown_err, Backend_Error.None)
	}

	@(test)
	test_simulated_backend_pending_op_survives_close_of_duplicate_descriptor :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {2, 2},
				seed = t.seed,
			},
		}
		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		defer backend_deinit(&backend)

		fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)
		dup_fd, dup_err := backend_control_dup(&backend, fd)
		testing.expect_value(t, dup_err, Backend_Error.None)

		token := submission_token_pack(2, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_RECV_COMPLETE))
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Recv{fd_socket = fd, size = 256}},
		}
		sub_err := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_err, Backend_Error.None)

		close_err := backend_control_close(&backend, dup_fd)
		testing.expect_value(t, close_err, Backend_Error.None)

		completions: [2]Raw_Completion
		count, collect_err := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_err, Backend_Error.None)
		testing.expect_value(t, count, u32(0))

		count, collect_err = backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_err, Backend_Error.None)
		testing.expect_value(t, count, u32(1))
		testing.expect_value(t, completions[0].token, token)
		testing.expect(t, completions[0].result >= 0, "pending op should still complete after duplicate close")
	}

	@(test)
	test_simulated_accept_completion_returns_tracked_descriptor :: proc(t: ^testing.T) {
		backend: Platform_Backend
		config := Backend_Config {
			sim_config = Simulation_IO_Config {
				delay_range_ticks = {0, 0},
				seed = t.seed,
			},
		}
		err := backend_init(&backend, config)
		testing.expect_value(t, err, Backend_Error.None)
		defer backend_deinit(&backend)

		listen_fd, sock_err := backend_control_socket(&backend, .AF_INET, .STREAM, .TCP)
		testing.expect_value(t, sock_err, Backend_Error.None)

		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, u8(IO_TAG_ACCEPT_COMPLETE))
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Accept{listen_fd = listen_fd}},
		}
		sub_err := backend_submit(&backend, submissions[:])
		testing.expect_value(t, sub_err, Backend_Error.None)

		completions: [2]Raw_Completion
		count, collect_err := backend_collect(&backend, completions[:], 0)
		testing.expect_value(t, collect_err, Backend_Error.None)
		testing.expect_value(t, count, u32(1))

		accept_extra, ok := completions[0].extra.(Completion_Extra_Accept)
		testing.expect(t, ok, "accept completion should carry accept extra")
		_, descriptor_ok := _sim_lookup_descriptor(&backend, accept_extra.client_fd)
		testing.expect(t, descriptor_ok, "accepted client fd should be tracked by simulated backend")
	}

} // when TINA_SIM
