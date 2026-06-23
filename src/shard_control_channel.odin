package tina

import "core:sync"
import "core:testing"

SHARD_CONTROL_READY_WORD_COUNT :: 4

#assert(SHARD_CONTROL_READY_WORD_COUNT * BITMAP_WORD_BIT_COUNT >= MAX_SHARDS)

Shard_Control_Event_Kind :: enum u8 {
	Liveness,
}

Shard_Control_Event :: struct {
	epoch:    u32,
	source:   Shard_Id,
	state:    Shard_State,
	kind:     Shard_Control_Event_Kind,
	_padding: u8,
}

Shard_Control_Channel_Cell :: struct {
	event_word: u64,
}

Shard_Control_Channel :: struct #align(CACHE_LINE_SIZE) {
	// Producers set ready bits; the single consumer clears them before reading cells.
	ready_words: [SHARD_CONTROL_READY_WORD_COUNT]u64,
	_padding1:   [CACHE_LINE_SIZE - SHARD_CONTROL_READY_WORD_COUNT * size_of(u64)]u8,

	// Read-only after boot.
	source_count: int,
	cells:        [^]Shard_Control_Channel_Cell,
}

// The ready_words (written by every producer) must not share a cache
// line with the source_count/cells fields read only by the consumer.
#assert(offset_of(Shard_Control_Channel, source_count) == CACHE_LINE_SIZE, "Shard_Control_Channel cold section must start on the second cache line")
#assert(size_of(Shard_Control_Channel) == 2 * CACHE_LINE_SIZE, "Shard_Control_Channel must occupy exactly two cache lines")

#assert(size_of(Shard_Control_Event) == size_of(u64))
#assert(size_of(Shard_Control_Channel_Cell) == size_of(u64))

@(private = "file")
shard_control_event_pack :: #force_inline proc "contextless" (
	source_shard: Shard_Id,
	event: ^Shard_Control_Event,
) -> u64 {
	return u64(event.epoch) |
	       (u64(source_shard) << 32) |
	       (u64(event.state) << 40) |
	       (u64(event.kind) << 48)
}

@(private = "file")
shard_control_event_unpack :: #force_inline proc "contextless" (event_word: u64) -> Shard_Control_Event {
	return Shard_Control_Event {
		epoch  = u32(event_word),
		source = Shard_Id(event_word >> 32),
		state  = Shard_State(event_word >> 40),
		kind   = Shard_Control_Event_Kind(event_word >> 48),
	}
}

shard_control_channel_init :: proc(
	channel: ^Shard_Control_Channel,
	source_count: int,
	cells: []Shard_Control_Channel_Cell,
) {
	assert(source_count > 0, "Shard control channel source count must be positive")
	assert(source_count <= MAX_SHARDS, "Shard control channel source count exceeds ready mask")
	assert(len(cells) >= source_count, "Shard control channel cell count is too small")

	for word_index in 0 ..< SHARD_CONTROL_READY_WORD_COUNT {
		channel.ready_words[word_index] = 0
	}
	for source_index in 0 ..< source_count {
		cells[source_index].event_word = 0
	}

	channel.source_count = source_count
	channel.cells = raw_data(cells)
}

shard_control_channel_publish :: #force_inline proc(
	channel: ^Shard_Control_Channel,
	source_shard: Shard_Id,
	event: ^Shard_Control_Event,
) {
	source_index := int(source_shard)
	when TINA_RUNTIME_ASSERTIONS {
		assert(channel != nil, "Shard control channel publish requires a channel")
		assert(event != nil, "Shard control channel publish requires an event")
		assert(source_index < channel.source_count, "Shard control source is outside channel source count")
		assert(event.source == source_shard, "Shard control event source must match publisher cell")
	}

	event_word := shard_control_event_pack(source_shard, event)
	sync.atomic_store_explicit(&channel.cells[source_index].event_word, event_word, .Release)

	bit_index := u32(source_shard)
	word_index := bitmap_word_index_from_bit_index(bit_index)
	bit_mask := bitmap_mask_from_bit_index(bit_index)
	sync.atomic_or_explicit(&channel.ready_words[word_index], bit_mask, .Release)
}

shard_control_channel_take_ready_word :: #force_inline proc(
	channel: ^Shard_Control_Channel,
	word_index: int,
) -> u64 {
	when TINA_RUNTIME_ASSERTIONS {
		assert(channel != nil, "Shard control channel ready-word exchange requires a channel")
		assert(word_index >= 0 && word_index < SHARD_CONTROL_READY_WORD_COUNT, "Shard control ready word index is out of range")
	}
	return sync.atomic_exchange_explicit(&channel.ready_words[word_index], u64(0), .Acquire)
}

shard_control_channel_load_event :: #force_inline proc(
	channel: ^Shard_Control_Channel,
	source_shard: Shard_Id,
) -> Shard_Control_Event {
	source_index := int(source_shard)
	when TINA_RUNTIME_ASSERTIONS {
		assert(channel != nil, "Shard control channel event load requires a channel")
		assert(source_index < channel.source_count, "Shard control source is outside channel source count")
	}
	event_word := sync.atomic_load_explicit(&channel.cells[source_index].event_word, .Acquire)
	return shard_control_event_unpack(event_word)
}

@(test)
test_shard_control_channel_coalesces_by_source :: proc(t: ^testing.T) {
	cells: [3]Shard_Control_Channel_Cell
	channel: Shard_Control_Channel
	shard_control_channel_init(&channel, 3, cells[:])

	first := Shard_Control_Event{epoch = 1, source = Shard_Id(0), state = .Quarantined, kind = .Liveness}
	second := Shard_Control_Event{epoch = 2, source = Shard_Id(0), state = .Running, kind = .Liveness}
	third := Shard_Control_Event{epoch = 3, source = Shard_Id(2), state = .Quarantined, kind = .Liveness}

	shard_control_channel_publish(&channel, Shard_Id(0), &first)
	shard_control_channel_publish(&channel, Shard_Id(0), &second)
	shard_control_channel_publish(&channel, Shard_Id(2), &third)

	ready_word := shard_control_channel_take_ready_word(&channel, 0)
	testing.expect(t, (ready_word & bitmap_mask_from_bit_index(0)) != 0, "source 0 should be ready")
	testing.expect(t, (ready_word & bitmap_mask_from_bit_index(1)) == 0, "source 1 should be empty")
	testing.expect(t, (ready_word & bitmap_mask_from_bit_index(2)) != 0, "source 2 should be ready")

	event_0 := shard_control_channel_load_event(&channel, Shard_Id(0))
	event_2 := shard_control_channel_load_event(&channel, Shard_Id(2))
	testing.expect_value(t, event_0.epoch, u32(2))
	testing.expect_value(t, event_0.source, Shard_Id(0))
	testing.expect_value(t, event_0.state, Shard_State.Running)
	testing.expect_value(t, event_2.epoch, u32(3))
	testing.expect_value(t, event_2.source, Shard_Id(2))
	testing.expect_value(t, event_2.state, Shard_State.Quarantined)
	testing.expect_value(t, shard_control_channel_take_ready_word(&channel, 0), u64(0))
}

@(test)
test_shard_control_event_pack_round_trips :: proc(t: ^testing.T) {
	event := Shard_Control_Event{epoch = 0xAABBCCDD, source = Shard_Id(7), state = .Quarantined, kind = .Liveness}
	event_word := shard_control_event_pack(event.source, &event)
	decoded := shard_control_event_unpack(event_word)

	testing.expect_value(t, decoded.epoch, event.epoch)
	testing.expect_value(t, decoded.source, event.source)
	testing.expect_value(t, decoded.state, event.state)
	testing.expect_value(t, decoded.kind, event.kind)
}
