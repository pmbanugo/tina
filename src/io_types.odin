package tina

import "core:testing"

// ============================================================================
// I/O Subsystem Core Types (§6.6.1, §6.6.2, §6.6.3)
// ============================================================================

// --- OS File Descriptor (platform-specific) ---

when ODIN_OS == .Windows {
	OS_FD :: distinct uintptr
	OS_FD_INVALID :: OS_FD(~uintptr(0))
} else {
	OS_FD :: distinct i32
	OS_FD_INVALID :: OS_FD(-1)
}

// --- FD_Handle — Generational Index into Shard's FD Table (§6.6.1 §3) ---
// Layout: lower 16 bits = slot index, upper 16 bits = generation
// Total: 4 bytes. Same generational index pattern as Isolate Handles.
FD_Handle :: distinct u32

FD_HANDLE_NONE :: FD_Handle(0)

fd_handle_make :: #force_inline proc "contextless" (index: u16, generation: u16) -> FD_Handle {
	return FD_Handle(u32(index) | (u32(generation) << 16))
}

fd_handle_index :: #force_inline proc "contextless" (h: FD_Handle) -> u16 {
	return u16(u32(h) & 0xFFFF)
}

fd_handle_generation :: #force_inline proc "contextless" (h: FD_Handle) -> u16 {
	return u16(u32(h) >> 16)
}

// --- IO Operation Kind (formerly IO_Completion_Tag) ---
//
// This is the single source of truth for I/O operation identity.
// The u8 backing type matches the 8-bit op_kind field in Submission_Token.
// Exhaustive switch on this enum forces every consumption site to handle
// all variants — a compile-time guarantee that no new operation can be
// added without deciding its pool affinity, FD close policy, and
// completion behavior.

IO_Operation_Kind :: enum u8 {
	None              = 0x00,
	Read_Complete     = 0x10,
	Write_Complete    = 0x11,
	Accept_Complete   = 0x12,
	Connect_Complete  = 0x13,
	Send_Complete     = 0x14,
	Recv_Complete     = 0x15,
	Sendto_Complete   = 0x16,
	Recvfrom_Complete = 0x17,
	Close_Complete    = 0x18,
	Sendfile_Complete = 0x19,
}

IO_Slot_Pool_Affinity :: enum u8 {
	None,     // No pool slot involved (accept, connect, close, sendfile)
	Receive,  // receive_pool: kernel writes here (read, recv, recvfrom)
	Staging,  // staging_pool: user writes here (write, send, sendto)
}

io_operation_pool_affinity :: #force_inline proc "contextless" (
	kind: IO_Operation_Kind,
) -> IO_Slot_Pool_Affinity {
	switch kind {
	case .Read_Complete, .Recv_Complete, .Recvfrom_Complete:
		return .Receive
	case .Write_Complete, .Send_Complete, .Sendto_Complete:
		return .Staging
	case .None, .Accept_Complete, .Connect_Complete,
	     .Close_Complete, .Sendfile_Complete:
		return .None
	}
	return .None
}

IO_TAG_NONE              :: Message_Tag(IO_Operation_Kind.None)
IO_TAG_READ_COMPLETE     :: Message_Tag(IO_Operation_Kind.Read_Complete)
IO_TAG_WRITE_COMPLETE    :: Message_Tag(IO_Operation_Kind.Write_Complete)
IO_TAG_ACCEPT_COMPLETE   :: Message_Tag(IO_Operation_Kind.Accept_Complete)
IO_TAG_CONNECT_COMPLETE  :: Message_Tag(IO_Operation_Kind.Connect_Complete)
IO_TAG_SEND_COMPLETE     :: Message_Tag(IO_Operation_Kind.Send_Complete)
IO_TAG_RECV_COMPLETE     :: Message_Tag(IO_Operation_Kind.Recv_Complete)
IO_TAG_SENDTO_COMPLETE   :: Message_Tag(IO_Operation_Kind.Sendto_Complete)
IO_TAG_RECVFROM_COMPLETE :: Message_Tag(IO_Operation_Kind.Recvfrom_Complete)
IO_TAG_CLOSE_COMPLETE    :: Message_Tag(IO_Operation_Kind.Close_Complete)
IO_TAG_SENDFILE_COMPLETE :: Message_Tag(IO_Operation_Kind.Sendfile_Complete)

// --- Socket Types (§6.6.3 §4, §9, §10) ---

Socket_Domain :: enum u8 {
	AF_INET  = 0,
	AF_INET6 = 1,
	AF_UNIX  = 2,
}

Socket_Type :: enum u8 {
	STREAM = 0,
	DGRAM  = 1,
}

Socket_Protocol :: enum u8 {
	DEFAULT = 0,
	TCP     = 1,
	UDP     = 2,
}

Shutdown_How :: enum u8 {
	SHUT_READER = 0,
	SHUT_WRITER = 1,
	SHUT_BOTH   = 2,
}

Socket_Level :: enum u8 {
	SOL_SOCKET   = 0,
	IPPROTO_TCP  = 1,
	IPPROTO_UDP  = 2,
	IPPROTO_IPV6 = 3,
}

Socket_Option :: enum u16 {
	// SOL_SOCKET
	SO_REUSEADDR      = 0x0001,
	SO_REUSEPORT      = 0x0002,
	SO_KEEPALIVE      = 0x0003,
	SO_RCVBUF         = 0x0004,
	SO_SNDBUF         = 0x0005,
	SO_LINGER         = 0x0006,
	SO_BINDTODEVICE   = 0x0007,
	SO_EXCLUSIVEADDRUSE = 0x0008,
	// IPPROTO_TCP
	TCP_NODELAY       = 0x0101,
	TCP_CORK          = 0x0102,
	TCP_NOPUSH        = 0x0103,
	TCP_KEEPIDLE      = 0x0104,
	TCP_KEEPINTVL     = 0x0105,
	TCP_KEEPCNT       = 0x0106,

	TCP_DEFER_ACCEPT  = 0x0107,
	TCP_NOTSENT_LOWAT = 0x0108,

	// IPPROTO_IPV6
	IPV6_V6ONLY       = 0x0201,
}

Socket_Linger :: struct {
	onoff:  i32,
	linger: i32,
}

Socket_Option_Value :: union {
	bool,
	i32,
	Socket_Linger,
}

// --- Socket Address (§6.6.3 §9) ---
// Tagged union for full addresses used in IoOp and backend types.

Socket_Address_Inet4 :: struct {
	address: [4]u8,
	port:    u16,
}

Socket_Address_Inet6 :: struct {
	address: [16]u8,
	port:    u16,
	flow:    u32,
	scope:   u32,
}

Socket_Address_Unix :: struct {
	path: [108]u8,
}

Socket_Address :: union {
	Socket_Address_Inet4,
	Socket_Address_Inet6,
	Socket_Address_Unix,
}

// Compact 28-byte peer address for Isolate metadata (§6.6.3 §5.3).
// Covers inet4 and inet6. Unix peer addresses are not supported in SOA
// (unix domain accept does not produce meaningful peer addresses).
Peer_Address :: struct {
	flow_info:    u32, // IPv6 flow info (0 for IPv4)
	scope_id:     u32, // IPv6 scope ID (0 for IPv4)
	port:         u16, // network port
	family:       Socket_Domain, // discriminant
	_padding:     [1]u8,
	address_data: [16]u8, // IPv4 uses first 4 bytes, IPv6 uses all 16
}
#assert(size_of(Peer_Address) == 28)

// --- IoOp Sub-Union (§6.6.1 §2, §6.6.3 §7) ---

IoOp_Read :: struct {
	fd:              FD_Handle,
	buffer_size_max: u32,
	offset:          u64,
}

IoOp_Write :: struct {
	fd:     FD_Handle,
	offset: u64,
}

IoOp_Accept :: struct {
	listen_fd: FD_Handle,
}

IoOp_Connect :: struct {
	fd:      FD_Handle,
	address: Socket_Address,
}

IoOp_Send :: struct {
	fd: FD_Handle,
}

IoOp_Recv :: struct {
	fd:              FD_Handle,
	buffer_size_max: u32,
}

IoOp_Sendto :: struct {
	fd:      FD_Handle,
	address: Socket_Address,
}

IoOp_Recvfrom :: struct {
	fd:              FD_Handle,
	buffer_size_max: u32,
}

IoOp_Close :: struct {
	fd: FD_Handle,
}

IoOp_Sendfile :: struct {
	fd_file:       FD_Handle,
	fd_socket:     FD_Handle,
	source_offset: u64,
	size:          u32,
}

IoOp :: union {
	IoOp_Read,
	IoOp_Write,
	IoOp_Accept,
	IoOp_Connect,
	IoOp_Send,
	IoOp_Recv,
	IoOp_Sendto,
	IoOp_Recvfrom,
	IoOp_Close,
	IoOp_Sendfile,
}

// --- FD Table Entry (§6.6.3 §6) ---
// Direction-partitioned ownership: reader_isolate and writer_isolate tracked separately.
// For single-owner FDs (common case), both point to the same Isolate.

FD_Entry_State :: enum u8 {
	Free,
	Open,
	Close_After_Current_IO,
	Close_Queued,
	Close_In_Flight,
}

FD_Entry_Attribute :: enum u8 {
	Fresh_Accept, // newly accepted socket, eligible for v1 cross-shard handoff
}

FD_Entry_Attributes :: bit_set[FD_Entry_Attribute;u8]

// A named region gives ASan one contiguous logical lifetime; `using` below
// preserves flat field access without adding storage or indirection.
FD_Entry_Payload :: struct {
	reader_isolate: Isolate_Handle,
	writer_isolate: Isolate_Handle,
	peer_address:   Peer_Address,
}

FD_Entry :: struct {
	using payload: FD_Entry_Payload,
	os_fd:           OS_FD,
	generation:      u16,
	state:           FD_Entry_State,
	attributes:      FD_Entry_Attributes,
	_padding:        [4]u8,
}

#assert(offset_of(FD_Entry, payload) == 0)
#assert(size_of(FD_Entry_Payload) % ASAN_POISON_GRANULE_SIZE == 0)
#assert(offset_of(FD_Entry, os_fd) >= size_of(FD_Entry_Payload))

FD_Handoff_Result :: enum u8 {
	ok,
	not_remote_target,
	not_owner,
	invalid_fd_state,
	unsupported,
	handoff_table_full,
	transport_full,
	transport_unavailable,
}

FD_Handoff_Reject_Reason :: enum u8 {
	None,
	Invalid_Target,
	Target_Busy,
	Adopt_Failed,
	Unsupported,
}

@(private = "package")
FD_Handoff_State :: enum u8 {
	Free,
	In_Flight,
}

FD_HANDOFF_NONE_INDEX :: u16(0xFFFF)
FD_HANDOFF_ENTRY_COUNT_MAX :: int(FD_HANDOFF_NONE_INDEX)

#assert(FD_HANDOFF_ENTRY_COUNT_MAX == int(FD_HANDOFF_NONE_INDEX))

@(private = "package")
FD_Handoff_Ref :: struct {
	handoff_index: u16,
	generation:    u16,
	source_shard:  Shard_Id,
	_padding:      [3]u8,
}

@(private = "package")
FD_HANDOFF_REF_NONE :: FD_Handoff_Ref {
	handoff_index = FD_HANDOFF_NONE_INDEX,
}

@(private = "package")
FD_Handoff_Offer :: struct {
	handoff:      FD_Handoff_Ref,
	os_fd:        OS_FD,
	peer_address: Peer_Address,
}

@(private = "package")
FD_Handoff_Ack :: struct {
	handoff: FD_Handoff_Ref,
}

@(private = "package")
FD_Handoff_Reject :: struct {
	handoff:  FD_Handoff_Ref,
	reason:   FD_Handoff_Reject_Reason,
	_padding: [7]u8,
}

@(private = "package")
FD_Handoff_Abort :: struct {
	handoff: FD_Handoff_Ref,
	os_fd:   OS_FD,
}

@(private = "package")
FD_Handoff_Entry :: struct {
	target_handle:   Isolate_Handle,
	peer_address:    Peer_Address,
	deadline_tick:   u64,
	cleanup_fd:      OS_FD,
	generation:      u16,
	next_free_index: u16,
	state:           FD_Handoff_State,
	_padding:        [3]u8,
}

@(private = "package")
FD_Handoff_Table :: struct {
	entries:     []FD_Handoff_Entry,
	free_head:   u16,
	free_count:  u16,
	entry_count: u16,
	_padding:    u16,
}

#assert(size_of(FD_Handoff_Offer) <= MAX_PAYLOAD_SIZE)
#assert(size_of(FD_Handoff_Ack) <= MAX_PAYLOAD_SIZE)
#assert(size_of(FD_Handoff_Reject) <= MAX_PAYLOAD_SIZE)
#assert(size_of(FD_Handoff_Abort) <= MAX_PAYLOAD_SIZE)

@(private = "package")
fd_handoff_ref_make :: #force_inline proc "contextless" (
	handoff_index: u16,
	generation: u16,
	source_shard: Shard_Id,
) -> FD_Handoff_Ref {
	return FD_Handoff_Ref {
		handoff_index = handoff_index,
		generation = generation,
		source_shard = source_shard,
	}
}

// --- Handoff Mode (§6.6.3 §5.4) ---

Handoff_Mode :: enum u8 {
	Full       = 0, // transfer both directions — parent loses all FD access
	Read_Only  = 1, // child gets read direction, parent retains write direction
	Write_Only = 2, // child gets write direction, parent retains read direction
}

// --- Submission Token (§6.6.2 §4 / Repacked for 20-bit slots) ---
// 64-bit packed correlation identifier.
// Bit layout (LSB to MSB):
//   [0..7]   isolate_type_index  u8    (8 bits)
//   [8..27]  isolate_slot_index  u32   (20 bits)
//   [28..35] isolate_generation  u8    (8 bits)
//   [36..43] io_sequence         u8    (8 bits)
//   [44..55] buffer_index        u16   (12 bits)
//   [56..63] operation_kind      u8    (8 bits)

Submission_Token :: distinct u64

// Distinct type for slot indices into IO_Slot_Pool slabs. Prevents the bare
// u16 0x0FFF sentinel from being silently mixed with other u16 fields
// (counts, offsets, sizes). The compiler enforces explicit conversion at
// I/O boundaries (e.g. submission_token_pack, pool alloc return).
IO_Slot_Index :: distinct u16
IO_SLOT_INDEX_BITS :: 12
IO_SLOT_INDEX_NONE :: IO_Slot_Index(0x0FFF) // 12-bit max value (4095)
IO_SLOT_COUNT_MAX :: int(u16(IO_SLOT_INDEX_NONE))
IO_SLOT_INDEX_MASK :: u64(0x0FFF)
FIXED_FILE_INDEX_NONE :: u16(0xFFFF)

#assert(u16(IO_SLOT_INDEX_NONE) == (1 << IO_SLOT_INDEX_BITS) - 1)
#assert(IO_SLOT_COUNT_MAX == int(u16(IO_SLOT_INDEX_NONE)))
#assert(IO_SLOT_COUNT_MAX <= int(max(u16)))

submission_token_pack :: #force_inline proc(
	type_index: u8,
	slot_index: u32,
	generation: u8,
	sequence: u8,
	buffer_index: IO_Slot_Index,
	operation_kind: IO_Operation_Kind,
) -> Submission_Token {
	when TINA_RUNTIME_ASSERTIONS {
		assert(slot_index <= 0xFFFFF, "isolate slot index exceeds Submission_Token capacity")
		assert(u16(buffer_index) <= u16(IO_SLOT_INDEX_NONE), "I/O slot index exceeds Submission_Token capacity")
		assert(u8(operation_kind) < 0x80, "user completion operation kind overlaps Linux internal user-data tags")
	}
	return Submission_Token(
		u64(type_index & 0xFF) |
		(u64(slot_index & 0xFFFFF) << 8) |
		(u64(generation & 0xFF) << 28) |
		(u64(sequence & 0xFF) << 36) |
		((u64(buffer_index) & IO_SLOT_INDEX_MASK) << 44) |
		(u64(operation_kind) << 56),
	)
}

submission_token_type_index :: #force_inline proc "contextless" (token: Submission_Token) -> u8 {
	return u8(u64(token) & 0xFF)
}

submission_token_slot_index :: #force_inline proc "contextless" (token: Submission_Token) -> u32 {
	return u32((u64(token) >> 8) & 0xFFFFF)
}

submission_token_generation :: #force_inline proc "contextless" (token: Submission_Token) -> u8 {
	return u8((u64(token) >> 28) & 0xFF)
}

submission_token_io_sequence :: #force_inline proc "contextless" (token: Submission_Token) -> u8 {
	return u8((u64(token) >> 36) & 0xFF)
}

submission_token_buffer_index :: #force_inline proc "contextless" (token: Submission_Token) -> IO_Slot_Index {
	return IO_Slot_Index((u64(token) >> 44) & IO_SLOT_INDEX_MASK)
}

submission_token_operation_kind :: #force_inline proc "contextless" (token: Submission_Token) -> IO_Operation_Kind {
	return IO_Operation_Kind((u64(token) >> 56) & 0xFF)
}

// --- Submission (§6.6.2 §4) ---
// Reactor → Backend. Contains the correlation token and platform-level operation data.

Submission_Op_Read :: struct {
	fd:     OS_FD,
	offset: u64,
}

Submission_Op_Write :: struct {
	fd:     OS_FD,
	offset: u64,
}

Submission_Op_Accept :: struct {
	listen_fd: OS_FD,
}

Submission_Op_Connect :: struct {
	fd_socket: OS_FD,
	address:   Socket_Address,
}

Submission_Op_Close :: struct {
	fd: OS_FD,
}

Submission_Op_Send :: struct {
	fd_socket: OS_FD,
}

Submission_Op_Recv :: struct {
	fd_socket: OS_FD,
}

Submission_Op_Sendto :: struct {
	fd_socket: OS_FD,
	address:   Socket_Address,
}

Submission_Op_Recvfrom :: struct {
	fd_socket: OS_FD,
}

Submission_Op_Sendfile :: struct {
	fd_file:       OS_FD,
	fd_socket:     OS_FD,
	source_offset: u64,
	size:          u32,
}

Submission_Operation :: union {
	Submission_Op_Read,
	Submission_Op_Write,
	Submission_Op_Accept,
	Submission_Op_Connect,
	Submission_Op_Close,
	Submission_Op_Send,
	Submission_Op_Recv,
	Submission_Op_Sendto,
	Submission_Op_Recvfrom,
	Submission_Op_Sendfile,
}


_Submission_Common :: struct {
	token:            Submission_Token,
	fixed_file_index: u16, // Index into io_uring fixed-file table (Linux only). FIXED_FILE_INDEX_NONE if unused.
	// Resolved pointer: Isolate struct (writes) or pool slot (reads).
	// nil for operations without data (accept, connect, close).
	data_pointer:     [^]u8,
	data_size:        u32, // Byte count for the data region. 0 when data_pointer is nil.
	operation:        Submission_Operation,
}

when TINA_ASAN_POISONING {
	Submission :: struct {
		using _: _Submission_Common,
		// Logical pool slot size for sanitizer poisoning. Zero means data_pointer
		// is not a Tina-owned pool slot, or the backend chooses the buffer later
		// (io_uring provided receive buffers).
		sanitizer_slot_size: u32,
	}
} else {
	Submission :: struct {
		using _: _Submission_Common,
	}
}

// --- Raw Completion (§6.6.2 §4) ---
// Backend → Reactor. Carries the correlation token and result.

Completion_Extra_Accept :: struct {
	client_fd:      OS_FD,
	client_address: Socket_Address,
}

Completion_Extra_Recvfrom :: struct {
	peer_address: Socket_Address,
}

Completion_Extra :: union {
	Completion_Extra_Accept,
	Completion_Extra_Recvfrom,
}

// Per-completion flag bits. Set by the backend to signal provenance to the
// reactor's collection path. .Synthesized indicates the completion was
// generated by the backend (e.g. on kqueue, to cancel a pending op whose
// kernel-side counterpart was dropped) rather than delivered by the kernel.
Completion_Flag :: enum u8 {
	Synthesized = 0, // Diagnostic: backend-generated (kqueue cancel, SimulatedIO cancel), not kernel-delivered.
}
Completion_Flags :: distinct bit_set[Completion_Flag; u8]

Raw_Completion :: struct {
	token:  Submission_Token,
	result: i32,
	extra:  Completion_Extra,
	flags:  Completion_Flags,
}

// --- I/O Error Codes (§6.6.1 §8) ---

IO_Error :: distinct i32

IO_ERR_NONE: IO_Error : 0
IO_ERR_RESOURCE_EXHAUSTED: IO_Error : -1
IO_ERR_STALE_FD: IO_Error : -2
IO_ERR_AFFINITY_VIOLATION: IO_Error : -3
IO_ERR_BOUNDS_VIOLATION: IO_Error : -4
IO_ERR_SUBMISSION_FULL: IO_Error : -5
IO_ERR_BACKEND_FAILURE: IO_Error : -6
IO_ERR_INVALID_DATA_SOURCE: IO_Error : -7 // Send/write/sendto requires IO_Data_Source.Isolate_Struct or .Staging_Slot, not .None.

// Where the write bytes come from.
// Only relevant for send/write/sendto. Ignored for recv/read/accept/connect/close.
IO_Data_Source :: enum u8 {
	None,            // No data (recv, accept, connect, close, sendfile, read)
	Isolate_Struct,  // Direct reference: reactor computes pointer from Isolate struct
	Staging_Slot,    // Staging pool slot: reactor uses staging pool pointer
}

// --- Transfer Buffer Handle (§6.9 §8.2) ---
// Layout: lower 16 bits = pool index, upper 16 bits = generation
Transfer_Handle :: distinct u32

TRANSFER_HANDLE_NONE :: Transfer_Handle(0)

transfer_handle_make :: #force_inline proc "contextless" (index: IO_Slot_Index, generation: u16) -> Transfer_Handle {
	return Transfer_Handle(u32(index) | (u32(generation) << 16))
}

transfer_handle_index :: #force_inline proc "contextless" (handle: Transfer_Handle) -> IO_Slot_Index {
	return IO_Slot_Index(u32(handle) & 0xFFFF)
}

transfer_handle_generation :: #force_inline proc "contextless" (handle: Transfer_Handle) -> u16 {
	return u16(u32(handle) >> 16)
}

// --- Helpers for SOA Address Storage ---

socket_address_to_peer_address :: #force_inline proc "contextless" (address: Socket_Address) -> Peer_Address {
	peer_address: Peer_Address
	switch socket_address in address {
	case Socket_Address_Inet4:
		peer_address.family = .AF_INET
		peer_address.port = socket_address.port
		// Explicit 4-byte assignment
		peer_address.address_data[0] = socket_address.address[0]
		peer_address.address_data[1] = socket_address.address[1]
		peer_address.address_data[2] = socket_address.address[2]
		peer_address.address_data[3] = socket_address.address[3]
	case Socket_Address_Inet6:
		peer_address.family = .AF_INET6
		peer_address.port = socket_address.port
		peer_address.flow_info = socket_address.flow
		peer_address.scope_id = socket_address.scope
		// Both are [16]u8, direct array assignment works
		peer_address.address_data = socket_address.address
	case Socket_Address_Unix:
		peer_address.family = .AF_UNIX
	}
	return peer_address
}

peer_address_to_socket_address :: #force_inline proc "contextless" (peer_address: Peer_Address) -> Socket_Address {
	switch peer_address.family {
	case .AF_INET:
		address := Socket_Address_Inet4 {
			port = peer_address.port,
		}
		// Explicit 4-byte assignment from the unaddressable parameter
		address.address[0] = peer_address.address_data[0]
		address.address[1] = peer_address.address_data[1]
		address.address[2] = peer_address.address_data[2]
		address.address[3] = peer_address.address_data[3]
		return address
	case .AF_INET6:
		address := Socket_Address_Inet6 {
			port  = peer_address.port,
			flow  = peer_address.flow_info,
			scope = peer_address.scope_id,
		}
		address.address = peer_address.address_data
		return address
	case .AF_UNIX:
		return Socket_Address_Unix{}
	case:
		return nil
	}
}

// ============================================================================
// Tests
// ============================================================================

@(test)
test_fd_handle_packing :: proc(t: ^testing.T) {
	h := fd_handle_make(0x1234, 0xABCD)
	testing.expect_value(t, fd_handle_index(h), 0x1234)
	testing.expect_value(t, fd_handle_generation(h), 0xABCD)

	h_zero := fd_handle_make(0, 0)
	testing.expect_value(t, fd_handle_index(h_zero), 0)
	testing.expect_value(t, fd_handle_generation(h_zero), 0)
	// NEW: 0 index + 0 gen is now exactly FD_HANDLE_NONE
	testing.expect(
		t,
		h_zero == FD_HANDLE_NONE,
		"index 0 + generation 0 should equal FD_HANDLE_NONE",
	)
}

@(test)
test_submission_token_round_trip :: proc(t: ^testing.T) {
	token := submission_token_pack(
		type_index = 0x12,
		slot_index = 0x93456, // Testing a 20-bit value!
		generation = 0x78,
		sequence = 0x9A,
		buffer_index = 0x0CDE, // Fits in 12 bits!
		operation_kind = IO_Operation_Kind(0x70),
	)

	testing.expect_value(t, submission_token_type_index(token), 0x12)
	testing.expect_value(t, submission_token_slot_index(token), 0x93456)
	testing.expect_value(t, submission_token_generation(token), 0x78)
	testing.expect_value(t, submission_token_io_sequence(token), 0x9A)
	testing.expect_value(t, u16(submission_token_buffer_index(token)), 0x0CDE)
	testing.expect_value(t, submission_token_operation_kind(token), IO_Operation_Kind(0x70))
}

@(test)
test_submission_token_zero :: proc(t: ^testing.T) {
	token := submission_token_pack(0, 0, 0, 0, 0, .None)
	testing.expect_value(t, u64(token), u64(0))
}

@(test)
test_submission_token_buffer_none_sentinel :: proc(t: ^testing.T) {
	token := submission_token_pack(0, 0, 0, 0, IO_SLOT_INDEX_NONE, .None)
	testing.expect_value(t, submission_token_buffer_index(token), IO_SLOT_INDEX_NONE)
}

@(test)
test_peer_address_size :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Peer_Address), 28)
}

@(test)
test_io_operation_kind_distinct :: proc(t: ^testing.T) {
	// Ensure all IO_Operation_Kind raw values are unique
	kinds := [?]IO_Operation_Kind {
		.None,
		.Read_Complete,
		.Write_Complete,
		.Accept_Complete,
		.Connect_Complete,
		.Close_Complete,
		.Send_Complete,
		.Recv_Complete,
		.Sendto_Complete,
		.Recvfrom_Complete,
		.Sendfile_Complete,
	}
	for i in 0 ..< len(kinds) {
		for j in (i + 1) ..< len(kinds) {
			testing.expect(t, kinds[i] != kinds[j], "duplicate IO_Operation_Kind values")
		}
	}
}

@(test)
test_io_operation_pool_affinity_exhaustive :: proc(t: ^testing.T) {
	// Verify pool affinity classification is correct for every variant
	testing.expect_value(t, io_operation_pool_affinity(.None), IO_Slot_Pool_Affinity.None)
	testing.expect_value(t, io_operation_pool_affinity(.Read_Complete), IO_Slot_Pool_Affinity.Receive)
	testing.expect_value(t, io_operation_pool_affinity(.Write_Complete), IO_Slot_Pool_Affinity.Staging)
	testing.expect_value(t, io_operation_pool_affinity(.Accept_Complete), IO_Slot_Pool_Affinity.None)
	testing.expect_value(t, io_operation_pool_affinity(.Connect_Complete), IO_Slot_Pool_Affinity.None)
	testing.expect_value(t, io_operation_pool_affinity(.Send_Complete), IO_Slot_Pool_Affinity.Staging)
	testing.expect_value(t, io_operation_pool_affinity(.Recv_Complete), IO_Slot_Pool_Affinity.Receive)
	testing.expect_value(t, io_operation_pool_affinity(.Sendto_Complete), IO_Slot_Pool_Affinity.Staging)
	testing.expect_value(t, io_operation_pool_affinity(.Recvfrom_Complete), IO_Slot_Pool_Affinity.Receive)
	testing.expect_value(t, io_operation_pool_affinity(.Close_Complete), IO_Slot_Pool_Affinity.None)
	testing.expect_value(t, io_operation_pool_affinity(.Sendfile_Complete), IO_Slot_Pool_Affinity.None)
}
