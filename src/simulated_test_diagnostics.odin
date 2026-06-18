package tina

import "core:testing"

// Focused tests for the simulation diagnostic table. The diagnostic table is a
// control-plane observation surface: handlers write scalar facts while payload
// memory is live, and post-run assertions read those scalars instead of
// inspecting isolate memory.
when TINA_SIMULATION_MODE {

	DIAG_TEST_FIELD_A: Diagnostic_Field_Id : 0
	DIAG_TEST_FIELD_B: Diagnostic_Field_Id : 1

	@(private = "file")
	_make_diagnostic_table :: proc(records: []Diagnostic_Record) -> Diagnostic_Table {
		return Diagnostic_Table{
			records      = records,
			record_count = 0,
		}
	}

	@(test)
	test_diagnostic_table_type_zero_slot_zero_field_zero :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		records: [4]Diagnostic_Record
		table := _make_diagnostic_table(records[:])

		diagnostic_table_write(&table, 0, 0, 0, 42)
		value, found := diagnostic_table_read(&table, 0, 0, 0)
		testing.expect(t, found, "expected diagnostic record for type/slot/field zero")
		testing.expect_value(t, value, u64(42))
	}

	@(test)
	test_diagnostic_table_rewrite_updates_value_and_write_count :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		records: [4]Diagnostic_Record
		table := _make_diagnostic_table(records[:])

		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 10)
		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 20)
		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 30)

		value, found := diagnostic_table_read(&table, 0, 0, DIAG_TEST_FIELD_A)
		testing.expect(t, found, "expected rewritten record to exist")
		testing.expect_value(t, value, u64(30))
		testing.expect_value(t, table.record_count, u32(1))
		for rec in table.records[:table.record_count] {
			testing.expect_value(t, rec.write_count, u32(3))
		}
	}

	@(test)
	test_diagnostic_table_fields_do_not_collide :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		records: [4]Diagnostic_Record
		table := _make_diagnostic_table(records[:])

		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 100)
		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_B, 200)

		value_a, found_a := diagnostic_table_read(&table, 0, 0, DIAG_TEST_FIELD_A)
		value_b, found_b := diagnostic_table_read(&table, 0, 0, DIAG_TEST_FIELD_B)
		testing.expect(t, found_a && found_b, "expected both field records to exist")
		testing.expect_value(t, value_a, u64(100))
		testing.expect_value(t, value_b, u64(200))
		testing.expect_value(t, table.record_count, u32(2))
	}

	@(test)
	test_diagnostic_table_slots_do_not_collide :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		records: [4]Diagnostic_Record
		table := _make_diagnostic_table(records[:])

		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 111)
		diagnostic_table_write(&table, 0, 1, DIAG_TEST_FIELD_A, 222)

		value_0, found_0 := diagnostic_table_read(&table, 0, 0, DIAG_TEST_FIELD_A)
		value_1, found_1 := diagnostic_table_read(&table, 0, 1, DIAG_TEST_FIELD_A)
		testing.expect(t, found_0 && found_1, "expected both slot records to exist")
		testing.expect_value(t, value_0, u64(111))
		testing.expect_value(t, value_1, u64(222))
		testing.expect_value(t, table.record_count, u32(2))
	}

	@(test)
	test_diagnostic_table_capacity_exhaustion_fails_deterministically :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		records: [2]Diagnostic_Record
		table := _make_diagnostic_table(records[:])

		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 1)
		diagnostic_table_write(&table, 0, 1, DIAG_TEST_FIELD_A, 2)

		// Capacity exhaustion must be deterministic: the third distinct record
		// overflows the table and panics with a provisioning message.
		// NOTE: Panics are routed through the test runner's assertion handler, so
		// `expect_assert_message` matches the panic message exactly.
		testing.expect_assert_message(
			t,
			"diagnostic record capacity exhausted; increase diagnostic_record_count_per_shard",
		)
		diagnostic_table_write(&table, 0, 2, DIAG_TEST_FIELD_A, 3)
	}

	@(test)
	test_diagnostic_table_capacity_stops_at_limit :: proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)

		records: [2]Diagnostic_Record
		table := _make_diagnostic_table(records[:])

		diagnostic_table_write(&table, 0, 0, DIAG_TEST_FIELD_A, 1)
		diagnostic_table_write(&table, 0, 1, DIAG_TEST_FIELD_A, 2)

		testing.expect_value(t, table.record_count, u32(2))
	}
}
