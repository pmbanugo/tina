package http_server

import "core:time"
import "core:testing"

// ─── Date Cache ───────────────────────────────────────────────────────────
//
// Maintains the shard-local Date cache required by RFC 7231. 
// Uses monotonic time for fast checking and unix time for actual formatting.

Date_Cache :: struct {
	next_second_threshold_ns: u64,    // monotonic_ns at which the cache must reformat (DR-16)
	size:                     u8,
	bytes:                    [29]u8, // RFC 7231 Date, e.g. "Sun, 06 Nov 1994 08:49:37 GMT"
}

NANOSECONDS_PER_SECOND :: 1_000_000_000

@(rodata, private = "file")
WEEKDAYS := [7][3]u8 {
	{'S', 'u', 'n'}, {'M', 'o', 'n'}, {'T', 'u', 'e'},
	{'W', 'e', 'd'}, {'T', 'h', 'u'}, {'F', 'r', 'i'},
	{'S', 'a', 't'},
}

@(rodata, private = "file")
MONTHS := [12][3]u8 {
	{'J', 'a', 'n'}, {'F', 'e', 'b'}, {'M', 'a', 'r'},
	{'A', 'p', 'r'}, {'M', 'a', 'y'}, {'J', 'u', 'n'},
	{'J', 'u', 'l'}, {'A', 'u', 'g'}, {'S', 'e', 'p'},
	{'O', 'c', 't'}, {'N', 'o', 'v'}, {'D', 'e', 'c'},
}

@(private = "file")
write_two_digits :: #force_inline proc "contextless" (target: []u8, offset: int, value: int) {
	tens := u8(value / 10)
	ones := u8(value % 10)
	target[offset] = '0' + tens
	target[offset + 1] = '0' + ones
}

@(private = "file")
write_four_digits :: #force_inline proc "contextless" (target: []u8, offset: int, value: int) {
	thousands := u8(value / 1000)
	hundreds := u8((value % 1000) / 100)
	tens := u8((value % 100) / 10)
	ones := u8(value % 10)
	target[offset] = '0' + thousands
	target[offset + 1] = '0' + hundreds
	target[offset + 2] = '0' + tens
	target[offset + 3] = '0' + ones
}

// Refreshes the cache if the given deterministic monotonic nanosecond timestamp
// crosses the next_second_threshold_ns threshold.
update_date_cache :: #force_inline proc "contextless" (
	cache: ^Date_Cache,
	monotonic_ns: u64,
	unix_epoch_ns: u64,
) {
	// Fast path check.
	if monotonic_ns < cache.next_second_threshold_ns {
		return
	}
	
	// Refresh the string.
	local_time := time.unix(0, i64(unix_epoch_ns))
	year, month, day := time.date(local_time)
	hour, minute, second := time.clock(local_time)
	weekday := time.weekday(local_time)
	
	// Layout: "Sun, 06 Nov 1994 08:49:37 GMT"
	target := cache.bytes[:]
	
	// time.weekday(t) returns 0 for Sunday
	weekday_letters := WEEKDAYS[int(weekday)]
	target[0] = weekday_letters[0]; target[1] = weekday_letters[1]; target[2] = weekday_letters[2]
	target[3] = ','
	target[4] = ' '
	
	write_two_digits(target, 5, day)
	target[7] = ' '
	
	// time.date(t) returns month 1..12
	month_letters := MONTHS[int(month) - 1]
	target[8] = month_letters[0]; target[9] = month_letters[1]; target[10] = month_letters[2]
	target[11] = ' '
	
	write_four_digits(target, 12, year)
	target[16] = ' '
	
	write_two_digits(target, 17, hour)
	target[19] = ':'
	write_two_digits(target, 20, minute)
	target[22] = ':'
	write_two_digits(target, 23, second)
	
	target[25] = ' '
	target[26] = 'G'
	target[27] = 'M'
	target[28] = 'T'
	
	cache.size = 29
	
	// Calculate the next threshold.
	// Since we format based on the wall clock second, we must update exactly when
	// the monotonic clock advances enough to represent the next wall clock second.
	// The simplest way without drifting is just to add the remaining nanoseconds 
	// in the current wall clock second to the current monotonic time.
	fraction_ns := unix_epoch_ns % NANOSECONDS_PER_SECOND
	cache.next_second_threshold_ns = monotonic_ns + (NANOSECONDS_PER_SECOND - fraction_ns)
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_date_cache_formatting :: proc(t: ^testing.T) {
	cache := Date_Cache{}
	
	// Sun, 06 Nov 1994 08:49:37 GMT is unix 784111777000000000 (roughly)
	// Let's use a precise calculation to verify.
	// time.datetime_to_unix(1994, 11, 6, 8, 49, 37) -> unix_seconds
	// We'll just construct a known time using Odin's core:time.
	known_time, _ := time.components_to_time(1994, 11, 6, 8, 49, 37)
	unix_ns := u64(time.to_unix_nanoseconds(known_time))
	
	monotonic_ns := u64(10_000_000_000)
	update_date_cache(&cache, monotonic_ns, unix_ns)
	
	testing.expect_value(t, cache.size, 29)
	testing.expect_value(t, string(cache.bytes[:]), "Sun, 06 Nov 1994 08:49:37 GMT")
	
	// Threshold should be monotonic + remaining ns
	fraction_ns := unix_ns % NANOSECONDS_PER_SECOND
	expected_threshold := monotonic_ns + (NANOSECONDS_PER_SECOND - fraction_ns)
	testing.expect_value(t, cache.next_second_threshold_ns, expected_threshold)
}

@(test)
test_date_cache_skips_when_under_threshold :: proc(t: ^testing.T) {
	cache := Date_Cache{}
	cache.next_second_threshold_ns = 5000
	
	// Should do nothing because 4000 < 5000
	update_date_cache(&cache, 4000, 0)
	testing.expect_value(t, cache.size, 0)
	
	// Should update because 5000 >= 5000
	known_time, _ := time.components_to_time(2026, 1, 1, 0, 0, 0)
	unix_ns := u64(time.to_unix_nanoseconds(known_time))
	update_date_cache(&cache, 5000, unix_ns)
	testing.expect_value(t, cache.size, 29)
}
