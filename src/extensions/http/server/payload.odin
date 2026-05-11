package http_server

import tina "../../.."
import "core:mem"
import "core:testing"

payload_view_as :: proc($T: typeid, payload: []u8) -> ^T {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(size_of(T) > 0, "payload_view_as: zero-sized types are not supported")
		assert(len(payload) >= size_of(T), "payload_view_as: payload smaller than requested type")
		assert(uintptr(raw_data(payload)) % align_of(T) == 0, "payload_view_as: payload alignment mismatch")
	}
	if size_of(T) == 0 || len(payload) < size_of(T) {
		return nil
	}
	return cast(^T)raw_data(payload)
}

payload_copy_as :: proc($T: typeid, payload: []u8) -> T {
	when tina.TINA_RUNTIME_ASSERTIONS {
		assert(size_of(T) > 0, "payload_copy_as: zero-sized types are not supported")
		assert(len(payload) >= size_of(T), "payload_copy_as: payload smaller than requested type")
	}

	result: T
	if size_of(T) == 0 || len(payload) < size_of(T) {
		return result
	}
	mem.copy(raw_data(tina.bytes_of(&result)), raw_data(payload), size_of(T))
	return result
}

retain_payload :: proc(request: ^Request, transient_payload: []u8) -> []u8 {
	if len(transient_payload) == 0 {
		return nil
	}
	retained_payload := make([]u8, len(transient_payload), request_arena(request))
	copy(retained_payload, transient_payload)
	return retained_payload
}

@(private = "file")
Payload_Test_Struct :: struct {
	value_a: u32,
	value_b: u16,
}

@(test)
test_payload_view_and_copy_as_round_trip :: proc(t: ^testing.T) {
	payload_value := Payload_Test_Struct {
		value_a = 0x11223344,
		value_b = 0x5566,
	}
	payload_bytes := tina.bytes_of(&payload_value)

	view := payload_view_as(Payload_Test_Struct, payload_bytes)
	testing.expect(t, view != nil, "payload_view_as should return non-nil for valid payload")
	testing.expect_value(t, view.value_a, u32(0x11223344))
	testing.expect_value(t, view.value_b, u16(0x5566))

	copy_value := payload_copy_as(Payload_Test_Struct, payload_bytes)
	testing.expect_value(t, copy_value.value_a, u32(0x11223344))
	testing.expect_value(t, copy_value.value_b, u16(0x5566))
}
