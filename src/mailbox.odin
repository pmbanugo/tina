package tina

MESSAGE_ENVELOPE_SIZE :: 128 // Fixed size message envelope for Isolates mailbox
MAX_PAYLOAD_SIZE :: 96

// Tag definitions
Message_Tag :: distinct u16
TAG_CALL_TIMEOUT: Message_Tag : 0x0001
TAG_TIMER: Message_Tag : 0x0002
TAG_SHUTDOWN: Message_Tag : 0x0003
TAG_TRANSFER: Message_Tag : 0x0004
TAG_SHARD_RESTARTED: Message_Tag : 0x0005
TAG_SHARD_QUARANTINED: Message_Tag : 0x0006
// Application message tags can start from here (0x0040 - 0xFFFF)
USER_MESSAGE_TAG_BASE: Message_Tag : 0x0040

Envelope_Flag :: enum {
	Is_Call, // bit 0
	Is_Reply, // bit 1
}

Envelope_Flags :: bit_set[Envelope_Flag;u16]

// Structured to cleanly separate User payloads from I/O completions
Message :: struct {
	using body: struct #raw_union {
		user: struct {
			source:       Handle,
			payload_size: u16,
			payload:      [MAX_PAYLOAD_SIZE]u8,
		},
		io:   struct {
			peer_address: Peer_Address, // 28 bytes — peer address from accept/recvfrom
			fd:           FD_Handle, // 4 bytes — which FD completed (or new client FD for accept)
			result:       i32, // 4 bytes — bytes transferred or negative error
			buffer_index: u16, // 2 bytes — reactor buffer pool index
		},
	},
	tag:        Message_Tag,
}

// 128 bytes exactly. Fields ordered largest-to-smallest to eliminate implicit padding.
Message_Envelope :: struct #align (128) {
	using _lifecycle: struct #raw_union {
		source:         Handle, // ALIVE STATE: Sender's Handle
		next_free_slot: u32, // DEAD STATE: Intrusive pool free-list linkage
	},
	destination:      Handle,
	correlation:      u32,
	next_in_mailbox:  u32, // (The queue linkage, overwrites index)
	tag:              Message_Tag,
	flags:            Envelope_Flags,
	payload_size:     u16,
	_padding:         u16,
	payload:          [MAX_PAYLOAD_SIZE]u8, // 96 bytes
}
