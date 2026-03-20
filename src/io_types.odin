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

fd_handle_make :: #force_inline proc(index: u16, generation: u16) -> FD_Handle {
	return FD_Handle(u32(index) | (u32(generation) << 16))
}

fd_handle_index :: #force_inline proc(h: FD_Handle) -> u16 {
	return u16(u32(h) & 0xFFFF)
}

fd_handle_generation :: #force_inline proc(h: FD_Handle) -> u16 {
	return u16(u32(h) >> 16)
}

// --- IO Completion Tags (§6.6.1 §5, §6.6.3 §7, PUBLIC_API_SURFACE §7.2) ---

IO_Completion_Tag :: distinct u16

IO_TAG_NONE: IO_Completion_Tag : 0x0000
IO_TAG_READ_COMPLETE: IO_Completion_Tag : 0x0010
IO_TAG_WRITE_COMPLETE: IO_Completion_Tag : 0x0011
IO_TAG_ACCEPT_COMPLETE: IO_Completion_Tag : 0x0012
IO_TAG_CONNECT_COMPLETE: IO_Completion_Tag : 0x0013
IO_TAG_SEND_COMPLETE: IO_Completion_Tag : 0x0014
IO_TAG_RECV_COMPLETE: IO_Completion_Tag : 0x0015
IO_TAG_SENDTO_COMPLETE: IO_Completion_Tag : 0x0016
IO_TAG_RECVFROM_COMPLETE: IO_Completion_Tag : 0x0017
IO_TAG_CLOSE_COMPLETE: IO_Completion_Tag : 0x0018

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
	SO_REUSEADDR    = 0x0001,
	SO_REUSEPORT    = 0x0002,
	SO_KEEPALIVE    = 0x0003,
	SO_RCVBUF       = 0x0004,
	SO_SNDBUF       = 0x0005,
	SO_LINGER       = 0x0006,
	SO_BINDTODEVICE = 0x0007,
	// IPPROTO_TCP
	TCP_NODELAY     = 0x0101,
	TCP_CORK        = 0x0102,
	TCP_NOPUSH      = 0x0103,
	TCP_KEEPIDLE    = 0x0104,
	TCP_KEEPINTVL   = 0x0105,
	TCP_KEEPCNT     = 0x0106,
	// IPPROTO_IPV6
	IPV6_V6ONLY     = 0x0201,
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

// Compact 28-byte peer address for SOA metadata (§6.6.3 §5.3).
// Covers inet4 and inet6. Unix peer addresses are not supported in SOA
// (unix domain accept does not produce meaningful peer addresses).
Peer_Address :: struct {
	address_data: [16]u8, // IPv4 uses first 4 bytes, IPv6 uses all 16
	flow_info:    u32, // IPv6 flow info (0 for IPv4)
	scope_id:     u32, // IPv6 scope ID (0 for IPv4)
	port:         u16, // network port
	family:       Socket_Domain, // discriminant
	_padding:     [1]u8,
}
#assert(size_of(Peer_Address) == 28)

// --- IoOp Sub-Union (§6.6.1 §2, §6.6.3 §7) ---

IoOp_Read :: struct {
	fd:              FD_Handle,
	buffer_size_max: u32,
	offset:          u64,
}

IoOp_Write :: struct {
	fd:             FD_Handle,
	payload_offset: u16,
	payload_size:   u32,
	offset:         u64,
}

IoOp_Accept :: struct {
	listen_fd: FD_Handle,
}

IoOp_Connect :: struct {
	fd:      FD_Handle,
	address: Socket_Address,
}

IoOp_Send :: struct {
	fd:             FD_Handle,
	payload_offset: u16,
	payload_size:   u32,
}

IoOp_Recv :: struct {
	fd:              FD_Handle,
	buffer_size_max: u32,
}

IoOp_Sendto :: struct {
	fd:             FD_Handle,
	address:        Socket_Address,
	payload_offset: u16,
	payload_size:   u32,
}

IoOp_Recvfrom :: struct {
	fd:              FD_Handle,
	buffer_size_max: u32,
}

IoOp_Close :: struct {
	fd: FD_Handle,
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
}

// --- FD Table Entry (§6.6.3 §6) ---
// Direction-partitioned ownership: read_owner and write_owner tracked separately.
// For single-owner FDs (common case), both point to the same Isolate.

FD_Flag :: enum {
	Close_On_Completion, // bit 0
}

FD_Flags :: bit_set[FD_Flag;u8]

FD_Entry :: struct {
	os_fd:       OS_FD,
	read_owner:  Handle,
	write_owner: Handle,
	generation:  u16,
	flags:       FD_Flags,
	_padding:    [5]u8,
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
//   [56..63] operation_tag       u8    (8 bits)

Submission_Token :: distinct u64

BUFFER_INDEX_NONE :: u16(0x0FFF) // 12-bit max value (4095)
FIXED_FILE_INDEX_NONE :: u16(0xFFFF)

submission_token_pack :: #force_inline proc(
	type_index: u8,
	slot_index: u32,
	generation: u8,
	sequence: u8,
	buf_index: u16,
	op_tag: u8,
) -> Submission_Token {
	return Submission_Token(
		u64(type_index & 0xFF) |
		(u64(slot_index & 0xFFFFF) << 8) |
		(u64(generation & 0xFF) << 28) |
		(u64(sequence & 0xFF) << 36) |
		(u64(buf_index & 0x0FFF) << 44) |
		(u64(op_tag & 0xFF) << 56),
	)
}

submission_token_type_index :: #force_inline proc(t: Submission_Token) -> u8 {
	return u8(u64(t) & 0xFF)
}

submission_token_slot_index :: #force_inline proc(t: Submission_Token) -> u32 {
	return u32((u64(t) >> 8) & 0xFFFFF)
}

submission_token_generation :: #force_inline proc(t: Submission_Token) -> u8 {
	return u8((u64(t) >> 28) & 0xFF)
}

submission_token_io_sequence :: #force_inline proc(t: Submission_Token) -> u8 {
	return u8((u64(t) >> 36) & 0xFF)
}

submission_token_buffer_index :: #force_inline proc(t: Submission_Token) -> u16 {
	return u16((u64(t) >> 44) & 0x0FFF)
}

submission_token_operation_tag :: #force_inline proc(t: Submission_Token) -> u8 {
	return u8((u64(t) >> 56) & 0xFF)
}

// --- Submission (§6.6.2 §4) ---
// Reactor → Backend. Contains the correlation token and platform-level operation data.

Submission_Op_Read :: struct {
	fd:     OS_FD,
	buffer: [^]u8,
	size:   u32,
	offset: u64,
}

Submission_Op_Write :: struct {
	fd:     OS_FD,
	buffer: [^]u8,
	size:   u32,
	offset: u64,
}

Submission_Op_Accept :: struct {
	listen_fd: OS_FD,
}

Submission_Op_Connect :: struct {
	socket_fd: OS_FD,
	address:   Socket_Address,
}

Submission_Op_Close :: struct {
	fd: OS_FD,
}

Submission_Op_Send :: struct {
	socket_fd: OS_FD,
	buffer:    [^]u8,
	size:      u32,
}

Submission_Op_Recv :: struct {
	socket_fd: OS_FD,
	buffer:    [^]u8,
	size:      u32,
}

Submission_Op_Sendto :: struct {
	socket_fd: OS_FD,
	address:   Socket_Address,
	buffer:    [^]u8,
	size:      u32,
}

Submission_Op_Recvfrom :: struct {
	socket_fd: OS_FD,
	buffer:    [^]u8,
	size:      u32,
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
}

Submission :: struct {
	token:            Submission_Token,
	fixed_file_index: u16, // Index into io_uring fixed-file table (Linux only). FIXED_FILE_INDEX_NONE if unused.
	operation:        Submission_Operation,
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

Raw_Completion :: struct {
	token:  Submission_Token,
	result: i32,
	extra:  Completion_Extra,
}

// --- I/O Error Codes (§6.6.1 §8) ---

IO_Error :: distinct i32

IO_ERR_NONE: IO_Error : 0
IO_ERR_RESOURCE_EXHAUSTED: IO_Error : -1
IO_ERR_STALE_FD: IO_Error : -2
IO_ERR_AFFINITY_VIOLATION: IO_Error : -3
IO_ERR_BOUNDS_VIOLATION: IO_Error : -4
IO_ERR_SUBMISSION_FULL: IO_Error : -5

// --- Transfer Buffer Handle (§6.9 §8.2) ---
// Layout: lower 16 bits = pool index, upper 16 bits = generation
Transfer_Handle :: distinct u32

TRANSFER_HANDLE_NONE :: Transfer_Handle(0)

transfer_handle_make :: #force_inline proc(index: u16, generation: u16) -> Transfer_Handle {
	return Transfer_Handle(u32(index) | (u32(generation) << 16))
}

transfer_handle_index :: #force_inline proc(h: Transfer_Handle) -> u16 {
	return u16(u32(h) & 0xFFFF)
}

transfer_handle_generation :: #force_inline proc(h: Transfer_Handle) -> u16 {
	return u16(u32(h) >> 16)
}

// --- Helpers for SOA Address Storage ---

socket_address_to_peer_address :: #force_inline proc(sa: Socket_Address) -> Peer_Address {
	pa: Peer_Address
	switch a in sa {
	case Socket_Address_Inet4:
		pa.family = .AF_INET
		pa.port = a.port
		// Explicit 4-byte assignment
		pa.address_data[0] = a.address[0]
		pa.address_data[1] = a.address[1]
		pa.address_data[2] = a.address[2]
		pa.address_data[3] = a.address[3]
	case Socket_Address_Inet6:
		pa.family = .AF_INET6
		pa.port = a.port
		pa.flow_info = a.flow
		pa.scope_id = a.scope
		// Both are [16]u8, direct array assignment works
		pa.address_data = a.address
	case Socket_Address_Unix:
		pa.family = .AF_UNIX
	}
	return pa
}

peer_address_to_socket_address :: #force_inline proc(pa: Peer_Address) -> Socket_Address {
	switch pa.family {
	case .AF_INET:
		a := Socket_Address_Inet4 {
			port = pa.port,
		}
		// Explicit 4-byte assignment from the unaddressable parameter
		a.address[0] = pa.address_data[0]
		a.address[1] = pa.address_data[1]
		a.address[2] = pa.address_data[2]
		a.address[3] = pa.address_data[3]
		return a
	case .AF_INET6:
		a := Socket_Address_Inet6 {
			port  = pa.port,
			flow  = pa.flow_info,
			scope = pa.scope_id,
		}
		a.address = pa.address_data
		return a
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
		buf_index = 0x0CDE, // Fits in 12 bits!
		op_tag = 0xF0,
	)

	testing.expect_value(t, submission_token_type_index(token), 0x12)
	testing.expect_value(t, submission_token_slot_index(token), 0x93456)
	testing.expect_value(t, submission_token_generation(token), 0x78)
	testing.expect_value(t, submission_token_io_sequence(token), 0x9A)
	testing.expect_value(t, submission_token_buffer_index(token), 0x0CDE)
	testing.expect_value(t, submission_token_operation_tag(token), 0xF0)
}

@(test)
test_submission_token_zero :: proc(t: ^testing.T) {
	token := submission_token_pack(0, 0, 0, 0, 0, 0)
	testing.expect_value(t, u64(token), u64(0))
}

@(test)
test_submission_token_buffer_none_sentinel :: proc(t: ^testing.T) {
	token := submission_token_pack(0, 0, 0, 0, BUFFER_INDEX_NONE, 0)
	testing.expect_value(t, submission_token_buffer_index(token), BUFFER_INDEX_NONE)
}

@(test)
test_peer_address_size :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Peer_Address), 28)
}

@(test)
test_io_completion_tag_distinct :: proc(t: ^testing.T) {
	// Ensure all tags are unique values
	tags := [?]IO_Completion_Tag {
		IO_TAG_NONE,
		IO_TAG_READ_COMPLETE,
		IO_TAG_WRITE_COMPLETE,
		IO_TAG_ACCEPT_COMPLETE,
		IO_TAG_CONNECT_COMPLETE,
		IO_TAG_CLOSE_COMPLETE,
		IO_TAG_SEND_COMPLETE,
		IO_TAG_RECV_COMPLETE,
		IO_TAG_SENDTO_COMPLETE,
		IO_TAG_RECVFROM_COMPLETE,
	}
	for i in 0 ..< len(tags) {
		for j in (i + 1) ..< len(tags) {
			testing.expect(t, tags[i] != tags[j], "duplicate IO_Completion_Tag values")
		}
	}
}
