package tina

import "core:testing"

// ============================================================================
// SimulatedIO Backend (§6.6.2 §5.4) — Deterministic Testing
// ============================================================================
//
// No kernel interaction. PRNG-driven delays, fault injection, reordering.
// Same seed + same submit/collect sequence = same completions.
//
// Active when TINA_SIM=true (overrides OS selection).

when TINA_SIMULATION_MODE {

	MAX_SIMULATED_PENDING :: 1024

	Simulated_Operation :: struct {
		token:          Submission_Token,
		operation:      Submission_Operation,
		submitted_tick: u64,
		delay_ticks:    u64,
	}

	_Platform_State :: struct {
		pending:       [MAX_SIMULATED_PENDING]Simulated_Operation,
		pending_count: u16,
		prng:          Prng, // used only for reordering (order-dependent is OK)
		seed:          u64, // original seed for per-op deterministic derivation
		tick_count:    u64,
		config:        Simulation_IO_Config,
		next_sim_fd:   i32, // incrementing simulated FD counter
	}

	@(private = "package")
	_backend_init :: proc(backend: ^Platform_Backend, config: Backend_Config) -> Backend_Error {
		backend.pending_count = 0
		backend.tick_count = 0
		backend.next_sim_fd = 100 // start above stdin/stdout/stderr range
		backend.config = config.sim_config

		// Seed from config — populated from Prng_Tree at shard hydration,
		// or from t.seed in tests.
		backend.seed = config.sim_config.seed
		prng_init(&backend.prng, backend.seed)
		return .None
	}

	@(private = "package")
	_backend_deinit :: proc(backend: ^Platform_Backend) {
		backend.pending_count = 0
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
				token          = sub.token,
				operation      = sub.operation,
				submitted_tick = backend.tick_count,
				delay_ticks    = delay,
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
						completion.result = i32(IO_ERR_RESOURCE_EXHAUSTED)
					} else {
						_sim_generate_success(op, completion)
					}
				} else {
					_sim_generate_success(op, completion)
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
				swap_idx := j + u32(prng_uint_less_than(&backend.prng, remaining))
				completions[j], completions[swap_idx] = completions[swap_idx], completions[j]
			}
		}

		return completed_count, .None
	}

	@(private = "package")
	_backend_cancel :: proc(backend: ^Platform_Backend, token: Submission_Token) -> Backend_Error {
		for i: u16 = 0; i < backend.pending_count; i += 1 {
			if backend.pending[i].token == token {
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
		fd := OS_FD(backend.next_sim_fd)
		backend.next_sim_fd += 1
		return fd, .None
	}

	@(private = "package")
	_backend_control_bind :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		address: Socket_Address,
	) -> Backend_Error {
		return .None
	}

	@(private = "package")
	_backend_control_listen :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		backlog: u32,
	) -> Backend_Error {
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
		return .None
	}

	@(private = "package")
	_backend_control_shutdown :: proc(
		backend: ^Platform_Backend,
		fd: OS_FD,
		how: Shutdown_How,
	) -> Backend_Error {
		return .None
	}

	@(private = "package")
	_backend_control_close :: proc(backend: ^Platform_Backend, fd: OS_FD) -> Backend_Error {
		return .None
	}

	// --- Internal Helpers ---

	// Derive a deterministic per-operation value from (seed, tick, token).
	// Uses the existing PRNG engine: mixes inputs into a seed, inits a
	// throwaway Prng, and draws one step. Invariant to batch size/order (§6.6.2 §5.4).
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
	_sim_generate_success :: proc(op: ^Simulated_Operation, completion: ^Raw_Completion) {
		switch _ in op.operation {
		case Submission_Op_Read:
			completion.result = i32(min(op.operation.(Submission_Op_Read).size, 128))
		case Submission_Op_Write:
			completion.result = i32(op.operation.(Submission_Op_Write).size)
		case Submission_Op_Accept:
			// Simulate new client FD
			completion.result = 0
			completion.extra = Completion_Extra_Accept {
				client_fd = OS_FD(200),
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
		case:
			completion.result = 0
		}
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
		testing.expect(t, backend.next_sim_fd >= 100, "sim FD should start at 100+")

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

		token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, 3)
		submissions := [1]Submission {
			{
				token = token,
				operation = Submission_Op_Connect {
					socket_fd = OS_FD(10),
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

		backend_deinit(&backend)
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

		token := submission_token_pack(1, 5, 0, 0, BUFFER_INDEX_NONE, 1)
		submissions := [1]Submission {
			{token = token, operation = Submission_Op_Recv{socket_fd = OS_FD(10), size = 4096}},
		}
		backend_submit(&backend, submissions[:])
		testing.expect_value(t, backend.pending_count, 1)

		cancel_err := backend_cancel(&backend, token)
		testing.expect_value(t, cancel_err, Backend_Error.None)
		testing.expect_value(t, backend.pending_count, 0)

		// Cancel again should return Not_Found
		cancel_err2 := backend_cancel(&backend, token)
		testing.expect_value(t, cancel_err2, Backend_Error.Not_Found)

		backend_deinit(&backend)
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

			// Submit 4 operations
			submissions: [4]Submission
			for i in 0 ..< 4 {
				submissions[i] = Submission {
					token = submission_token_pack(0, u32(i), 0, 0, BUFFER_INDEX_NONE, 7),
					operation = Submission_Op_Recv{socket_fd = OS_FD(i32(i) + 10), size = 1024},
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
			backend_deinit(&backend)
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

} // when TINA_SIM
