package http_server

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "package")
Route_Index :: distinct u8

@(private = "package")
ROUTE_INDEX_NONE :: Route_Index(0xFF)

// Offset into `Compiled_Router.literal_buffer`.
@(private = "package")
Literal_Offset :: distinct u32

@(private = "package")
Route_Kind :: enum u8 {
	Static,
	Parametric,
	Wildcard,
}

@(private = "package")
Route_Part_Kind :: enum u8 {
	Literal,
	Param,
	Wildcard,
}

@(private = "package")
Route_Part :: struct {
	literal_offset: Literal_Offset, // byte offset for Literal kind; 0 otherwise
	name_offset:    Literal_Offset, // byte offset for Param kind; 0 otherwise
	literal_size:   u16, // size for Literal kind; 0 otherwise
	name_size:      u16, // size for Param kind; 0 otherwise
	kind:           Route_Part_Kind,
}

@(private = "package")
Route_Entry :: struct {
	methods_mask:          Method_Mask,
	route_index_by_method: [len(Method)]Route_Index,
	pattern_offset:        Literal_Offset,
	pattern_size:          u16,
	first_part_index:      u16,
	part_count:            u8,
	segment_count:         u8,
	kind:                  Route_Kind,
}

@(private = "package")
Compiled_Router :: struct {
	entries:                      #soa[]Route_Entry,
	literal_buffer:               []u8,
	route_parts:                  []Route_Part,
	descriptors:                  []Route_Descriptor,

	// Match-time path-segment ceiling baked at compile time from
	// `Route_Budget.path_segment_count_max`. The match data plane never
	// re-reads `Limits`, it reads this field instead.
	match_budget:                 Match_Budget,

	// Bucket counts segregating entries[] by kind. Sum equals len(entries).
	static_count:                 u16,
	parametric_count:             u16,
	wildcard_count:               u16,
	global_methods_mask:          Method_Mask,
	options_asterisk_route_index: Route_Index,
	options_asterisk_allow:       []u8,
}

@(private = "package")
Match_Outcome :: enum u8 {
	Found,
	Method_Not_Allowed,
	Not_Found,
}

@(private = "package")
Match_Result :: struct {
	route_index:  Route_Index,
	methods_mask: Method_Mask, // populated only for .Method_Not_Allowed
	outcome:      Match_Outcome,
}

@(private = "package")
Compile_Error :: enum u8 {
	None,
	Too_Many_Routes,
	Empty_Pattern,
	Pattern_Not_Rooted, // pattern does not start with `/`
	Pattern_Bad_Encoding, // canonicalization rejected the pattern
	Wildcard_Not_Terminal, // `*` segment appears before the end
	Empty_Param_Name, // `:` followed by `/` or end-of-pattern
	Param_Count_Exceeds_Limit, // pattern declares more `:param` segments than the operator-configured Route_Budget allows
	Segment_Count_Exceeds_Limit, // pattern declares more path segments than the operator-configured Route_Budget allows
	Duplicate_Route, // same canonical pattern + same method registered twice
	Param_Name_Conflict, // same path + kind aggregated, but different param names
	Asterisk_Wrong_Method, // `*` registered for a method other than OPTIONS
	Empty_Methods_Mask, // route registered with no methods
}

// Sidecar parts use canonical-pattern-relative offsets during the compile pass;
// they are rebased onto `literal_buffer` at emit time.
@(private = "file")
Route_Part_IR :: struct {
	pattern_offset: u16, // relative to canonical_pattern
	size:           u16,
	kind:           Route_Part_Kind,
}


// Compiles a slice of user-registered routes into a `Compiled_Router`. The
// router (and its backing buffers) are allocated from the supplied allocator
// and remain valid until that allocator is destroyed. On error, no allocations
// outlive the call.
//
// `route_budget` is a *required* parameter (not defaulted): the route-table
// compile pass enforces operator-configured ceilings (param count, segment
// count) against this budget. Requiring it makes a future change to compile
// without a budget a compile-time error rather than a silent regression.
// The same operator value is folded into the compiled router's
// `Match_Budget` so the match data plane never re-reads `Limits`.
@(private = "package")
compile_router :: proc(
	routes: []Route,
	route_budget: Route_Budget,
	allocator := context.allocator,
) -> (
	router: Compiled_Router,
	error: Compile_Error,
	error_index: int,
) {
	output_allocator := allocator

	if len(routes) > 255 {
		return {}, .Too_Many_Routes, len(routes) - 1
	}

	// Phase 1: validate input shapes, find the asterisk route.
	asterisk_input_index: int = -1
	for route, route_input_index in routes {
		if route.methods_mask == {} {
			return {}, .Empty_Methods_Mask, route_input_index
		}
		if len(route.pattern) == 0 {
			return {}, .Empty_Pattern, route_input_index
		}

		is_asterisk_pattern := len(route.pattern) == 1 && route.pattern[0] == '*'
		if is_asterisk_pattern {
			if route.methods_mask != {.OPTIONS} {
				return {}, .Asterisk_Wrong_Method, route_input_index
			}
			if asterisk_input_index >= 0 {
				return {}, .Duplicate_Route, route_input_index
			}
			asterisk_input_index = route_input_index
			continue
		}

		if route.pattern[0] != '/' {
			return {}, .Pattern_Not_Rooted, route_input_index
		}
	}

	descriptors_dynamic := make([dynamic]Route_Descriptor, 0, len(routes), context.temp_allocator)

	options_asterisk_route_index := ROUTE_INDEX_NONE
	global_methods_mask: Method_Mask

	if asterisk_input_index >= 0 {
		route := routes[asterisk_input_index]
		descriptor_index := Route_Index(len(descriptors_dynamic))
		append(
			&descriptors_dynamic,
			Route_Descriptor {
				handler = route.handler,
				handler_kind = route.handler_kind,
				body_size_max = route.body_size_max,
				body_mode = route.body_mode,
				state_size = route.state_size,
			},
		)
		options_asterisk_route_index = descriptor_index
		global_methods_mask += {.OPTIONS}
	}

	// Phase 2: aggregate routes by (kind, canonical pattern).
	Aggregate :: struct {
		kind:          Route_Kind,
		pattern_bytes: []u8,
		parts:         []Route_Part_IR,
		segment_count: u8,
		methods_mask:  Method_Mask,
		slots:         [len(Method)]Route_Index,
	}

	aggregates := make([dynamic]Aggregate, 0, len(routes), context.temp_allocator)

	for route, route_input_index in routes {
		if route_input_index == asterisk_input_index do continue

		canonical := make([]u8, len(route.pattern), context.temp_allocator)
		copy(canonical, transmute([]u8)route.pattern)
		pattern_size_canonical, pattern_error, _ := path_canonicalize_selective_in_place(canonical)
		if pattern_error != .None {
			return {}, .Pattern_Bad_Encoding, route_input_index
		}
		canonical = canonical[:pattern_size_canonical]

		kind, parts, classify_error := classify_pattern(
			canonical,
			route_budget,
			context.temp_allocator,
		)
		if classify_error != .None {
			return {}, classify_error, route_input_index
		}

		descriptor_index := Route_Index(len(descriptors_dynamic))
		append(
			&descriptors_dynamic,
			Route_Descriptor {
				handler = route.handler,
				handler_kind = route.handler_kind,
				body_size_max = route.body_size_max,
				body_mode = route.body_mode,
				state_size = route.state_size,
			},
		)

		// Find an aggregate whose runtime match shape is identical — same
		// kind, same per-segment kinds, same literal segment bytes. Param
		// names are checked separately after a shape match is found.
		aggregate_index := -1
		for &candidate, candidate_index in aggregates {
			if route_match_shapes_equal(
				candidate.kind,
				candidate.parts,
				candidate.pattern_bytes,
				kind,
				parts,
				canonical,
			) {
				aggregate_index = candidate_index
				break
			}
		}

		if aggregate_index < 0 {
			pattern_copy := make([]u8, len(canonical), context.temp_allocator)
			copy(pattern_copy, canonical)

			parts_copy: []Route_Part_IR
			if kind != .Static {
				parts_copy = make([]Route_Part_IR, len(parts), context.temp_allocator)
				copy(parts_copy, parts)
			}

			slots: [len(Method)]Route_Index
			for &slot in slots do slot = ROUTE_INDEX_NONE

			for method in Method {
				if method not_in route.methods_mask do continue
				slots[method] = descriptor_index
				global_methods_mask += {method}
			}

			append(
				&aggregates,
				Aggregate {
					kind = kind,
					pattern_bytes = pattern_copy,
					parts = parts_copy,
					segment_count = part_count_to_segment_count(kind, parts_copy),
					methods_mask = route.methods_mask,
					slots = slots,
				},
			)
			continue
		}

		aggregate := &aggregates[aggregate_index]

		// Preserve the original error precedence: a duplicate method on the
		// same shape is diagnosed before a param-name disagreement.
		for method in Method {
			if method not_in route.methods_mask do continue
			if aggregate.slots[method] != ROUTE_INDEX_NONE {
				return {}, .Duplicate_Route, route_input_index
			}
		}

		// Match shape collapses these into one entry — the shared
		// Route_Part sidecar can only record one set of param names.
		if !route_parts_param_names_equal(
			aggregate.parts,
			parts,
			aggregate.pattern_bytes,
			canonical,
		) {
			return {}, .Param_Name_Conflict, route_input_index
		}

		for method in Method {
			if method not_in route.methods_mask do continue
			aggregate.slots[method] = descriptor_index
			aggregate.methods_mask += {method}
			global_methods_mask += {method}
		}
	}

	// Phase 3: HEAD → GET fallback. Explicit HEAD wins.
	for &aggregate in aggregates {
		if .HEAD in aggregate.methods_mask do continue
		if .GET not_in aggregate.methods_mask do continue
		aggregate.slots[Method.HEAD] = aggregate.slots[Method.GET]
		aggregate.methods_mask += {.HEAD}
	}
	if .GET in global_methods_mask do global_methods_mask += {.HEAD}

	// Pre-calculate emitted sizes.
	static_count: u16 = 0
	parametric_count: u16 = 0
	wildcard_count: u16 = 0
	literal_buffer_size: u32 = 0
	route_parts_total: u16 = 0

	for &aggregate in aggregates {
		switch aggregate.kind {
		case .Static:
			static_count += 1
		case .Parametric:
			parametric_count += 1
		case .Wildcard:
			wildcard_count += 1
		}
		literal_buffer_size += u32(len(aggregate.pattern_bytes))
		route_parts_total += u16(len(aggregate.parts))
	}

	// Allocate final storage on the supplied allocator.
	descriptors_final := make([]Route_Descriptor, len(descriptors_dynamic), output_allocator)
	copy(descriptors_final, descriptors_dynamic[:])

	literal_buffer := make([]u8, literal_buffer_size, output_allocator)
	route_parts_final := make([]Route_Part, route_parts_total, output_allocator)
	entries_final := make_soa(#soa[]Route_Entry, len(aggregates), output_allocator)

	// Emit aggregates in bucketed order so the static path is a tight
	// prefix scan with no kind branch.
	emit_indices := [3]u16{0, static_count, static_count + parametric_count}
	literal_cursor: u32 = 0
	parts_cursor: u16 = 0

	for &aggregate in aggregates {
		bucket_index := int(aggregate.kind)
		entry_index := emit_indices[bucket_index]
		emit_indices[bucket_index] += 1

		pattern_offset := Literal_Offset(literal_cursor)
		copy(literal_buffer[literal_cursor:], aggregate.pattern_bytes)

		first_part_index := parts_cursor
		for ir_part in aggregate.parts {
			route_part: Route_Part
			route_part.kind = ir_part.kind
			switch ir_part.kind {
			case .Literal:
				route_part.literal_offset = Literal_Offset(
					literal_cursor + u32(ir_part.pattern_offset),
				)
				route_part.literal_size = ir_part.size
			case .Param:
				route_part.name_offset = Literal_Offset(
					literal_cursor + u32(ir_part.pattern_offset),
				)
				route_part.name_size = ir_part.size
			case .Wildcard:
			// terminal segment. no offsets recorded — match consumes the
			// remaining suffix unconditionally
			}
			route_parts_final[parts_cursor] = route_part
			parts_cursor += 1
		}

		entries_final[entry_index] = Route_Entry {
			methods_mask          = aggregate.methods_mask,
			route_index_by_method = aggregate.slots,
			pattern_offset        = pattern_offset,
			pattern_size          = u16(len(aggregate.pattern_bytes)),
			first_part_index      = first_part_index,
			part_count            = u8(len(aggregate.parts)),
			segment_count         = aggregate.segment_count,
			kind                  = aggregate.kind,
		}

		literal_cursor += u32(len(aggregate.pattern_bytes))
	}

	// Build OPTIONS * Allow value if no explicit handler was registered.
	options_allow: []u8
	if options_asterisk_route_index == ROUTE_INDEX_NONE {
		options_allow = build_options_asterisk_allow(global_methods_mask, output_allocator)
	}

	router = Compiled_Router {
		entries = entries_final,
		literal_buffer = literal_buffer,
		route_parts = route_parts_final,
		descriptors = descriptors_final,
		match_budget = Match_Budget{path_segment_count_max = route_budget.path_segment_count_max},
		static_count = static_count,
		parametric_count = parametric_count,
		wildcard_count = wildcard_count,
		global_methods_mask = global_methods_mask,
		options_asterisk_route_index = options_asterisk_route_index,
		options_asterisk_allow = options_allow,
	}
	return router, .None, -1
}


// Frees all storage owned by `Compiled_Router`. Call only when shutting down.
@(private = "package")
compiled_router_destroy :: proc(router: ^Compiled_Router, allocator := context.allocator) {
	context.allocator = allocator
	delete_soa(router.entries)
	mem.delete(router.literal_buffer)
	mem.delete(router.route_parts)
	mem.delete(router.descriptors)
	if len(router.options_asterisk_allow) > 0 {
		mem.delete(router.options_asterisk_allow)
	}
	router^ = {}
}


// ─── Pattern Classification ─────────────────────────────────────────────────

// Splits `pattern` (which begins with `/`) into segments and classifies each.
// Allocates `parts` from `allocator` (typically `context.temp_allocator`).
@(private = "file")
classify_pattern :: proc(
	pattern: []u8,
	route_budget: Route_Budget,
	allocator := context.temp_allocator,
) -> (
	kind: Route_Kind,
	parts: []Route_Part_IR,
	error: Compile_Error,
) {
	context.allocator = allocator

	// `pattern` is guaranteed to start with `/`. Iterate segments by `/`
	// boundaries and classify each.
	parts_dynamic := make([dynamic]Route_Part_IR, 0, 8)

	any_param := false
	any_wildcard := false
	param_count := 0
	wildcard_seen_at: int = -1

	read_index := 1 // skip leading `/`
	pattern_size := len(pattern)
	for read_index < pattern_size || (pattern_size == 1) {
		// Find next `/`
		segment_begin := read_index
		segment_end := segment_begin
		for segment_end < pattern_size && pattern[segment_end] != '/' {
			segment_end += 1
		}
		segment_size := segment_end - segment_begin

		// Empty segment (e.g. trailing `/` or `//`) is rejected as malformed.
		// Pattern `/` is the legal exception: pattern_size == 1, no segments.
		if pattern_size == 1 do break
		if segment_size == 0 {
			return .Static, nil, .Empty_Pattern
		}

		first_byte := pattern[segment_begin]
		switch first_byte {
		case '*':
			if segment_size != 1 {
				// `*foo` is not a valid wildcard token — wildcard must be a
				// single `*` segment.
				return .Static, nil, .Wildcard_Not_Terminal
			}
			if wildcard_seen_at >= 0 {
				return .Static, nil, .Wildcard_Not_Terminal
			}
			wildcard_seen_at = segment_begin
			any_wildcard = true
			append(
				&parts_dynamic,
				Route_Part_IR{kind = .Wildcard, pattern_offset = u16(segment_begin), size = 1},
			)
		case ':':
			if segment_size < 2 {
				return .Static, nil, .Empty_Param_Name
			}
			any_param = true
			param_count += 1
			append(
				&parts_dynamic,
				Route_Part_IR {
					kind           = .Param,
					pattern_offset = u16(segment_begin + 1), // skip the `:`
					size           = u16(segment_size - 1),
				},
			)
		case:
			append(
				&parts_dynamic,
				Route_Part_IR {
					kind = .Literal,
					pattern_offset = u16(segment_begin),
					size = u16(segment_size),
				},
			)
		}

		read_index = segment_end + 1 // step over the `/` separator
	}

	if wildcard_seen_at >= 0 &&
	   wildcard_seen_at != int(parts_dynamic[len(parts_dynamic) - 1].pattern_offset) {
		return .Static, nil, .Wildcard_Not_Terminal
	}

	// Configurable ceilings fire first — these encode the operator's stated
	// budget and produce the precise, named diagnosis. The constructor
	// `route_budget_from` already guarantees path_segment_count_max < 0xFF and
	// param_count_max <= path_segment_count_max, so a check against a sub-255
	// ceiling is the *only* reachable width contract.
	if param_count > int(route_budget.param_count_max) {
		return .Static, nil, .Param_Count_Exceeds_Limit
	}
	if len(parts_dynamic) > int(route_budget.path_segment_count_max) {
		return .Static, nil, .Segment_Count_Exceeds_Limit
	}

	parts = parts_dynamic[:]
	switch {
	case any_wildcard:
		kind = .Wildcard
	case any_param:
		kind = .Parametric
	case:
		// Static routes do not need part metadata for matching — the runtime
		// path is a direct memcmp on the packed pattern.
		kind = .Static
		parts = nil
	}
	return kind, parts, .None
}

@(private = "file")
part_count_to_segment_count :: proc(kind: Route_Kind, parts: []Route_Part_IR) -> u8 {
	if kind == .Static do return 0
	count := len(parts)
	if count > 255 do count = 255
	return u8(count)
}

// Two routes share an aggregate if their runtime match shape is identical:
// same kind, same number of parts, same per-part kinds, and Literal parts
// have byte-equal segment bytes. Static routes have no parts; in that case
// the canonical pattern bytes themselves stand in.
@(private = "file")
route_match_shapes_equal :: proc(
	kind_a: Route_Kind,
	parts_a: []Route_Part_IR,
	pattern_a: []u8,
	kind_b: Route_Kind,
	parts_b: []Route_Part_IR,
	pattern_b: []u8,
) -> bool {
	if kind_a != kind_b do return false
	if kind_a == .Static {
		return slice.equal(pattern_a, pattern_b)
	}
	if len(parts_a) != len(parts_b) do return false
	for index in 0 ..< len(parts_a) {
		if parts_a[index].kind != parts_b[index].kind do return false
		if parts_a[index].kind != .Literal do continue
		literal_a := pattern_a[parts_a[index].pattern_offset:][:parts_a[index].size]
		literal_b := pattern_b[parts_b[index].pattern_offset:][:parts_b[index].size]
		if !slice.equal(literal_a, literal_b) do return false
	}
	return true
}

@(private = "file")
route_parts_param_names_equal :: proc(
	parts_a: []Route_Part_IR,
	parts_b: []Route_Part_IR,
	pattern_a: []u8,
	pattern_b: []u8,
) -> bool {
	if len(parts_a) != len(parts_b) do return false
	for index in 0 ..< len(parts_a) {
		if parts_a[index].kind != parts_b[index].kind do return false
		if parts_a[index].kind != .Param do continue
		name_a := pattern_a[parts_a[index].pattern_offset:][:parts_a[index].size]
		name_b := pattern_b[parts_b[index].pattern_offset:][:parts_b[index].size]
		if !slice.equal(name_a, name_b) do return false
	}
	return true
}


// ═══════════════════════════════════════════════════════════════════════════
// Match Engine
// ═══════════════════════════════════════════════════════════════════════════

// Matches the canonical request `path_bytes` against the compiled router.
// `request_method` is the parsed method. `request` is mutated so that any
// computed `path_segment_count` is cached for the rest of the request.
@(private = "package")
match_route :: proc(
	router: ^Compiled_Router,
	request: ^Request_State,
	path_bytes: []u8,
) -> Match_Result {
	method := request.method
	method_known := .Unknown_Method not_in request.status_flags
	path_size := u16(len(path_bytes))

	for size, entry_index in router.entries.pattern_size[:int(router.static_count)] {
		if size != path_size do continue

		pattern_offset := router.entries[entry_index].pattern_offset
		pattern_bytes := router.literal_buffer[int(pattern_offset):][:int(path_size)]
		if !slice.equal(path_bytes, pattern_bytes) do continue

		if !method_known {
			return Match_Result {
				outcome = .Method_Not_Allowed,
				methods_mask = router.entries[entry_index].methods_mask,
			}
		}

		route_index := router.entries[entry_index].route_index_by_method[method]
		if route_index != ROUTE_INDEX_NONE {
			return Match_Result{outcome = .Found, route_index = route_index}
		}
		return Match_Result {
			outcome = .Method_Not_Allowed,
			methods_mask = router.entries[entry_index].methods_mask,
		}
	}

	return match_route_parametric_or_wildcard(router, request, path_bytes, method, method_known)
}

@(private = "file")
match_route_parametric_or_wildcard :: proc(
	router: ^Compiled_Router,
	request: ^Request_State,
	path_bytes: []u8,
	method: Method,
	method_known: bool,
) -> Match_Result {
	if router.parametric_count == 0 && router.wildcard_count == 0 {
		return Match_Result{outcome = .Not_Found}
	}

	segment_count := ensure_path_segment_count(
		request,
		path_bytes,
		router.match_budget.path_segment_count_max,
	)

	// Operator-configured ceiling: oversized request paths are rejected
	// outright, including wildcard fallthrough.
	if segment_count == PATH_SEGMENT_COUNT_OVER_LIMIT {
		return Match_Result{outcome = .Not_Found}
	}

	// Parametric bucket — exact segment count match required.
	parametric_begin := int(router.static_count)
	parametric_end := parametric_begin + int(router.parametric_count)
	for entry_index in parametric_begin ..< parametric_end {
		if router.entries[entry_index].segment_count != segment_count do continue
		if !match_route_parts(
			router,
			router.entries[entry_index].first_part_index,
			router.entries[entry_index].part_count,
			path_bytes,
			false,
		) {continue}

		if !method_known {
			return Match_Result {
				outcome = .Method_Not_Allowed,
				methods_mask = router.entries[entry_index].methods_mask,
			}
		}

		route_index := router.entries[entry_index].route_index_by_method[method]
		if route_index != ROUTE_INDEX_NONE {
			return Match_Result{outcome = .Found, route_index = route_index}
		}
		return Match_Result {
			outcome = .Method_Not_Allowed,
			methods_mask = router.entries[entry_index].methods_mask,
		}
	}

	// Wildcard bucket — entry.segment_count is the minimum, suffix consumed
	// by the terminal `*`.
	wildcard_begin := parametric_end
	wildcard_end := wildcard_begin + int(router.wildcard_count)
	for entry_index in wildcard_begin ..< wildcard_end {
		if segment_count < router.entries[entry_index].segment_count do continue
		if !match_route_parts(
			router,
			router.entries[entry_index].first_part_index,
			router.entries[entry_index].part_count,
			path_bytes,
			true,
		) {continue}

		if !method_known {
			return Match_Result {
				outcome = .Method_Not_Allowed,
				methods_mask = router.entries[entry_index].methods_mask,
			}
		}

		route_index := router.entries[entry_index].route_index_by_method[method]
		if route_index != ROUTE_INDEX_NONE {
			return Match_Result{outcome = .Found, route_index = route_index}
		}
		return Match_Result {
			outcome = .Method_Not_Allowed,
			methods_mask = router.entries[entry_index].methods_mask,
		}
	}

	return Match_Result{outcome = .Not_Found}
}

// Walks the entry's `Route_Part` array against `path_bytes` segment-by-segment.
// `is_wildcard_entry` toggles the terminal-suffix consumption rule.
@(private = "file")
match_route_parts :: proc(
	router: ^Compiled_Router,
	first_part_index: u16,
	part_count: u8,
	path_bytes: []u8,
	is_wildcard_entry: bool,
) -> bool {
	read_index := 1 // skip leading `/`
	path_size := len(path_bytes)
	parts_begin := int(first_part_index)

	// Push the wildcard decision up — adjust loop bound at the call site
	actual_part_count := int(part_count)
	if is_wildcard_entry {
		actual_part_count -= 1 // exclude terminal wildcard part
	}
	parts_end := parts_begin + actual_part_count

	for part_index in parts_begin ..< parts_end {
		part := router.route_parts[part_index]

		// Locate this segment.
		if read_index > path_size do return false
		segment_begin := read_index
		segment_end := segment_begin
		for segment_end < path_size && path_bytes[segment_end] != '/' {
			segment_end += 1
		}
		segment_size := segment_end - segment_begin
		if segment_size == 0 do return false

		if part.kind == .Literal {
			if int(part.literal_size) != segment_size do return false
			literal_bytes := router.literal_buffer[int(part.literal_offset):][:int(
				part.literal_size,
			)]
			if !slice.equal(path_bytes[segment_begin:segment_end], literal_bytes) do return false
		}
		// .Param: accept unconditionally (no work — fall through)

		read_index = segment_end + 1
	}

	// Wildcard entries accept remaining suffix unconditionally
	if is_wildcard_entry do return true

	// Parametric (non-wildcard) entry: every byte must be consumed exactly.
	// `read_index` is positioned one past the consumed `/`; for the path
	// to be fully consumed, `read_index - 1 == path_size`.
	if read_index - 1 != path_size do return false
	return true
}

// Computes (or returns the cached) number of path segments. A segment is a
// non-empty run between `/` separators. Root path `/` has 0 segments.
//
// `path_segment_count_max` is the operator-configured Match_Budget ceiling.
// Request paths that exceed it return (and cache) `PATH_SEGMENT_COUNT_OVER_LIMIT`
// so the per-request over-limit decision is made exactly once. The match path
// short-circuits on this sentinel and reports `.Not_Found`, refusing wildcard
// fallthrough — the documented contract of "Max path segments for parametric
// matching".
//
// Because `match_budget_from` asserts `path_segment_count_max < 0xFF` at
// install time, a legitimate count can never collide with either sentinel
// (NONE=0xFF, OVER_LIMIT=0xFE).
@(private = "package")
ensure_path_segment_count :: proc(
	request: ^Request_State,
	path_bytes: []u8,
	path_segment_count_max: u8,
) -> u8 {
	if request.path_segment_count != PATH_SEGMENT_COUNT_NONE {
		return request.path_segment_count
	}

	count := 0
	read_index := 1 // skip leading `/`
	path_size := len(path_bytes)
	for read_index < path_size {
		// Skip consecutive `/` (treat as if same as one). Empty-segment
		// patterns are rejected at compile time; here we just guard against
		// canonical forms that include redundant slashes.
		if path_bytes[read_index] == '/' {
			read_index += 1
			continue
		}
		count += 1
		// Short-circuit the moment we cross the operator ceiling — no point
		// counting segments we will refuse to match anyway.
		if count > int(path_segment_count_max) {
			request.path_segment_count = PATH_SEGMENT_COUNT_OVER_LIMIT
			return request.path_segment_count
		}
		for read_index < path_size && path_bytes[read_index] != '/' {
			read_index += 1
		}
	}

	if count > 254 do count = 254
	request.path_segment_count = u8(count)
	return request.path_segment_count
}


// ═══════════════════════════════════════════════════════════════════════════
// 405 Allow Header Generation
// ═══════════════════════════════════════════════════════════════════════════

// Canonical Allow-listing order: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS,
// TRACE. Stable, predictable, and matches the order most servers emit.
@(private = "file")
ALLOW_METHOD_ORDER :: [?]Method{.GET, .HEAD, .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .TRACE}

@(private = "file", rodata)
METHOD_TOKEN_STRINGS := [Method]string {
	.GET     = "GET",
	.POST    = "POST",
	.PUT     = "PUT",
	.DELETE  = "DELETE",
	.PATCH   = "PATCH",
	.HEAD    = "HEAD",
	.OPTIONS = "OPTIONS",
	.TRACE   = "TRACE",
}

@(private = "file")
method_token_bytes :: proc(method: Method) -> string {
	return METHOD_TOKEN_STRINGS[method]
}

// Writes the comma-separated method list (e.g. `"GET, HEAD, POST"`) into
// `output_buffer` and returns the bytes written. The header NAME (`Allow: `)
// is the response writer's responsibility, not this helper's.
@(private = "package")
allow_value_write :: proc(output_buffer: []u8, methods_mask: Method_Mask) -> u8 {
	write_index := 0
	first := true
	for method in ALLOW_METHOD_ORDER {
		if method not_in methods_mask do continue

		token := method_token_bytes(method)
		if !first {
			if write_index + 2 > len(output_buffer) do return u8(write_index)
			output_buffer[write_index + 0] = ','
			output_buffer[write_index + 1] = ' '
			write_index += 2
		}
		token_bytes := transmute([]u8)token
		if write_index + len(token_bytes) > len(output_buffer) do return u8(write_index)
		copy(output_buffer[write_index:], token_bytes)
		write_index += len(token_bytes)
		first = false
	}
	return u8(write_index)
}


// ═══════════════════════════════════════════════════════════════════════════
// OPTIONS * Canned Response
// ═══════════════════════════════════════════════════════════════════════════

// Serializes the canned `OPTIONS *` response once at install time. Format:
//
//   HTTP/1.1 204 No Content\r\n
// Builds the immutable Allow value for the implicit `OPTIONS *` response.
// The actual response is produced through the normal response writer so
// Date, Connection, and framing policy stay correct.
@(private = "file")
build_options_asterisk_allow :: proc(
	methods_mask: Method_Mask,
	allocator := context.allocator,
) -> []u8 {
	allow_buffer: [128]u8
	allow_size := allow_value_write(allow_buffer[:], methods_mask)
	if allow_size == 0 {
		return nil
	}
	output := make([]u8, int(allow_size), allocator)
	copy(output, allow_buffer[:allow_size])
	return output
}


// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

@(test)
test_route_index_sentinel :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(ROUTE_INDEX_NONE), 0xFF)
}

@(test)
test_compile_empty :: proc(t: ^testing.T) {
	router, error, _ := compile_router({}, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, len(router.entries), 0)
	testing.expect_value(t, router.options_asterisk_route_index, ROUTE_INDEX_NONE)
	defer compiled_router_destroy(&router)
}

@(test)
test_compile_static_routes_packed :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/", methods_mask = {.GET}},
		{pattern = "/users", methods_mask = {.GET, .POST}},
		{pattern = "/users/me", methods_mask = {.GET}},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, len(router.entries), 3)
	testing.expect_value(t, router.static_count, 3)
	testing.expect_value(t, router.parametric_count, 0)
	testing.expect_value(t, router.wildcard_count, 0)
	// HEAD auto-fallback to GET expands global mask.
	testing.expect(t, .HEAD in router.global_methods_mask, "global mask should include HEAD")
}

@(test)
test_compile_aggregates_methods_into_one_entry :: proc(t: ^testing.T) {
	// Two separate registrations on the same path collapse into one entry.
	routes := []Route {
		{pattern = "/users", methods_mask = {.GET}},
		{pattern = "/users", methods_mask = {.POST}},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, len(router.entries), 1)

	entry := router.entries[0]
	testing.expect(t, .GET in entry.methods_mask, "GET should be set")
	testing.expect(t, .POST in entry.methods_mask, "POST should be set")
	testing.expect(t, .HEAD in entry.methods_mask, "HEAD should be auto-fallback")
	testing.expect(t, entry.route_index_by_method[Method.GET] != ROUTE_INDEX_NONE, "GET slot")
	testing.expect(t, entry.route_index_by_method[Method.POST] != ROUTE_INDEX_NONE, "POST slot")
	testing.expect_value(
		t,
		entry.route_index_by_method[Method.HEAD],
		entry.route_index_by_method[Method.GET],
	)
}

@(test)
test_compile_explicit_head_overrides_get_fallback :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/x", methods_mask = {.GET}, handler = rawptr(uintptr(0xAAAA))},
		{pattern = "/x", methods_mask = {.HEAD}, handler = rawptr(uintptr(0xBBBB))},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	entry := router.entries[0]
	get_index := entry.route_index_by_method[Method.GET]
	head_index := entry.route_index_by_method[Method.HEAD]
	testing.expect(t, head_index != get_index, "explicit HEAD must NOT alias GET")
	testing.expect_value(t, router.descriptors[get_index].handler, rawptr(uintptr(0xAAAA)))
	testing.expect_value(t, router.descriptors[head_index].handler, rawptr(uintptr(0xBBBB)))
}

@(test)
test_compile_duplicate_route_rejected :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/dup", methods_mask = {.GET}},
		{pattern = "/dup", methods_mask = {.GET}},
	}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Duplicate_Route)
}

@(test)
test_compile_canonicalization_collision :: proc(t: ^testing.T) {
	// `/admin` and `/%61dmin` canonicalize identically.
	routes := []Route {
		{pattern = "/admin", methods_mask = {.GET}},
		{pattern = "/%61dmin", methods_mask = {.GET}},
	}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Duplicate_Route)
}

@(test)
test_compile_parametric_classified :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/users/:id", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, router.parametric_count, 1)
	testing.expect_value(t, router.entries[0].kind, Route_Kind.Parametric)
	testing.expect_value(t, router.entries[0].segment_count, 2)
}

@(test)
test_compile_wildcard_classified :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/static/*", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, router.wildcard_count, 1)
	testing.expect_value(t, router.entries[0].kind, Route_Kind.Wildcard)
}

@(test)
test_compile_wildcard_must_be_terminal :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/*/foo", methods_mask = {.GET}}}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Wildcard_Not_Terminal)
}

@(test)
test_compile_empty_param_name_rejected :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/users/:", methods_mask = {.GET}}}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Empty_Param_Name)
}

@(test)
test_compile_options_asterisk_split_out :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "*", methods_mask = {.OPTIONS}, handler = rawptr(uintptr(0xCAFE))},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, len(router.entries), 0)
	testing.expect(t, router.options_asterisk_route_index != ROUTE_INDEX_NONE, "should be set")
	testing.expect_value(
		t,
		router.descriptors[router.options_asterisk_route_index].handler,
		rawptr(uintptr(0xCAFE)),
	)
}

@(test)
test_compile_options_asterisk_allow_built :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/health", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, router.options_asterisk_route_index, ROUTE_INDEX_NONE)
	testing.expect(t, len(router.options_asterisk_allow) > 0, "Allow value should be built")
	testing.expect_value(t, string(router.options_asterisk_allow), "GET, HEAD")
}

@(test)
test_compile_asterisk_for_non_options_rejected :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "*", methods_mask = {.GET}}}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Asterisk_Wrong_Method)
}

@(test)
test_compile_param_name_conflict_rejected :: proc(t: ^testing.T) {
	// Same pattern shape (`/users/:X`), conflicting param names — the shared
	// part schema cannot represent both names.
	routes := []Route {
		{pattern = "/users/:id", methods_mask = {.GET}},
		{pattern = "/users/:name", methods_mask = {.POST}},
	}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Param_Name_Conflict)
}

@(test)
test_compile_duplicate_route_error_index_is_input_index :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/first", methods_mask = {.GET}},
		{pattern = "/second", methods_mask = {.GET}},
		{pattern = "/second", methods_mask = {.GET}},
	}
	_, error, error_index := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Duplicate_Route)
	testing.expect_value(t, error_index, 2)
}

@(test)
test_compile_param_name_conflict_error_index_is_input_index :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/first", methods_mask = {.GET}},
		{pattern = "/second", methods_mask = {.GET}},
		{pattern = "/users/:id", methods_mask = {.GET}},
		{pattern = "/users/:name", methods_mask = {.POST}},
	}
	_, error, error_index := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Param_Name_Conflict)
	testing.expect_value(t, error_index, 3)
}

@(test)
test_match_static_hit :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/", methods_mask = {.GET}},
		{pattern = "/users", methods_mask = {.GET}},
		{pattern = "/users/me", methods_mask = {.GET}},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/users/me"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
	testing.expect(t, result.route_index != ROUTE_INDEX_NONE, "should resolve")

	// Static fast path must NOT compute segment_count.
	testing.expect_value(t, request.path_segment_count, PATH_SEGMENT_COUNT_NONE)
}

@(test)
test_match_static_miss_falls_through_to_not_found :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/users", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/nope"))
	testing.expect_value(t, result.outcome, Match_Outcome.Not_Found)
}

@(test)
test_match_method_not_allowed_emits_correct_mask :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET, .POST}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .DELETE

	result := match_route(&router, &request, transmute([]u8)string("/x"))
	testing.expect_value(t, result.outcome, Match_Outcome.Method_Not_Allowed)
	testing.expect(t, .GET in result.methods_mask, "GET present")
	testing.expect(t, .POST in result.methods_mask, "POST present")
	testing.expect(t, .HEAD in result.methods_mask, "HEAD auto-fallback present")
	testing.expect(t, .DELETE not_in result.methods_mask, "DELETE absent")
}

@(test)
test_match_unknown_method_known_path_still_reports_method_not_allowed :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET, .POST}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET
	request.status_flags += {.Unknown_Method}

	result := match_route(&router, &request, transmute([]u8)string("/x"))
	testing.expect_value(t, result.outcome, Match_Outcome.Method_Not_Allowed)
	testing.expect(t, .GET in result.methods_mask, "GET present")
	testing.expect(t, .POST in result.methods_mask, "POST present")
	testing.expect(t, .HEAD in result.methods_mask, "HEAD auto-fallback present")
}

@(test)
test_match_unknown_method_missing_path_stays_not_found :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET, .POST}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET
	request.status_flags += {.Unknown_Method}

	result := match_route(&router, &request, transmute([]u8)string("/missing"))
	testing.expect_value(t, result.outcome, Match_Outcome.Not_Found)
}

@(test)
test_match_head_resolves_to_get_handler :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/x", methods_mask = {.GET}, handler = rawptr(uintptr(0x1111))}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .HEAD

	result := match_route(&router, &request, transmute([]u8)string("/x"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
	testing.expect_value(
		t,
		router.descriptors[result.route_index].handler,
		rawptr(uintptr(0x1111)),
	)
}

@(test)
test_match_static_beats_parametric :: proc(t: ^testing.T) {
	// `/users/me` static must win over `/users/:id` parametric.
	routes := []Route {
		{pattern = "/users/:id", methods_mask = {.GET}, handler = rawptr(uintptr(0xAA))},
		{pattern = "/users/me", methods_mask = {.GET}, handler = rawptr(uintptr(0xBB))},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/users/me"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
	testing.expect_value(t, router.descriptors[result.route_index].handler, rawptr(uintptr(0xBB)))
}

@(test)
test_match_parametric_route :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/users/:id", methods_mask = {.GET}, handler = rawptr(uintptr(0xAA))},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/users/123"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
	testing.expect_value(t, router.descriptors[result.route_index].handler, rawptr(uintptr(0xAA)))
}

@(test)
test_match_parametric_segment_count_mismatch :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/users/:id", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/users/123/posts"))
	testing.expect_value(t, result.outcome, Match_Outcome.Not_Found)
}

@(test)
test_match_wildcard_consumes_suffix :: proc(t: ^testing.T) {
	routes := []Route{{pattern = "/static/*", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/static/css/app.css"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
}

@(test)
test_match_parametric_beats_wildcard :: proc(t: ^testing.T) {
	routes := []Route {
		{pattern = "/files/*", methods_mask = {.GET}, handler = rawptr(uintptr(0xAAA1))},
		{pattern = "/files/:name", methods_mask = {.GET}, handler = rawptr(uintptr(0xBBB2))},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	// `/files/foo` is one segment after `/files`, so parametric matches
	// before wildcard (parametric bucket precedes wildcard bucket).
	result := match_route(&router, &request, transmute([]u8)string("/files/foo"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
	testing.expect_value(
		t,
		router.descriptors[result.route_index].handler,
		rawptr(uintptr(0xBBB2)),
	)
}

@(test)
test_match_2F_does_not_split_segments_at_runtime :: proc(t: ^testing.T) {
	// Path `/a%2Fb` must match parametric `/:p` (one segment), not `/:a/:b`.
	routes := []Route{{pattern = "/:p", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	request: Request_State
	request_state_reset(&request)
	request.method = .GET

	result := match_route(&router, &request, transmute([]u8)string("/a%2Fb"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
}

@(test)
test_ensure_path_segment_count_caches :: proc(t: ^testing.T) {
	request: Request_State
	request_state_reset(&request)
	count_first := ensure_path_segment_count(
		&request,
		transmute([]u8)string("/a/b/c"),
		DEFAULT_MATCH_BUDGET.path_segment_count_max,
	)
	testing.expect_value(t, count_first, 3)

	// Re-call should be cache-hit; mutating the path bytes underneath should
	// not change the cached count.
	count_second := ensure_path_segment_count(
		&request,
		transmute([]u8)string("/x/y"),
		DEFAULT_MATCH_BUDGET.path_segment_count_max,
	)
	testing.expect_value(t, count_second, 3)
}

@(test)
test_ensure_path_segment_count_root :: proc(t: ^testing.T) {
	request: Request_State
	request_state_reset(&request)
	count := ensure_path_segment_count(
		&request,
		transmute([]u8)string("/"),
		DEFAULT_MATCH_BUDGET.path_segment_count_max,
	)
	testing.expect_value(t, count, 0)
}

@(test)
test_allow_value_write_canonical_order :: proc(t: ^testing.T) {
	buffer: [64]u8
	mask := Method_Mask{.POST, .GET, .DELETE}
	size := allow_value_write(buffer[:], mask)
	testing.expect_value(t, string(buffer[:size]), "GET, POST, DELETE")
}

@(test)
test_allow_value_write_single_method :: proc(t: ^testing.T) {
	buffer: [64]u8
	size := allow_value_write(buffer[:], Method_Mask{.PATCH})
	testing.expect_value(t, string(buffer[:size]), "PATCH")
}

@(test)
test_allow_value_write_empty_mask :: proc(t: ^testing.T) {
	buffer: [64]u8
	size := allow_value_write(buffer[:], Method_Mask{})
	testing.expect_value(t, size, 0)
}

@(test)
test_dozens_of_paths_resolve_correctly :: proc(t: ^testing.T) {
	// Stress the matcher with a mixed table of static, parametric, wildcard,
	// and aggregated multi-method routes.
	routes := []Route {
		{pattern = "/", methods_mask = {.GET}, handler = rawptr(uintptr(1))},
		{pattern = "/health", methods_mask = {.GET}, handler = rawptr(uintptr(2))},
		{pattern = "/users", methods_mask = {.GET, .POST}, handler = rawptr(uintptr(3))},
		{pattern = "/users/me", methods_mask = {.GET}, handler = rawptr(uintptr(4))},
		{pattern = "/users/:id", methods_mask = {.GET}, handler = rawptr(uintptr(5))},
		{pattern = "/users/:id/posts", methods_mask = {.GET}, handler = rawptr(uintptr(6))},
		{
			pattern = "/users/:id/posts/:post_id",
			methods_mask = {.GET},
			handler = rawptr(uintptr(7)),
		},
		{pattern = "/static/*", methods_mask = {.GET}, handler = rawptr(uintptr(8))},
		{
			pattern = "/api/v1/orders",
			methods_mask = {.GET, .POST, .DELETE},
			handler = rawptr(uintptr(9)),
		},
	}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)

	Case :: struct {
		method:           Method,
		path:             string,
		expected_outcome: Match_Outcome,
		expected_handler: uintptr, // 0 if not Found
	}
	cases := [?]Case {
		{.GET, "/", .Found, 1},
		{.GET, "/health", .Found, 2},
		{.GET, "/users", .Found, 3},
		{.POST, "/users", .Found, 3},
		{.GET, "/users/me", .Found, 4},
		{.GET, "/users/42", .Found, 5},
		{.GET, "/users/42/posts", .Found, 6},
		{.GET, "/users/42/posts/99", .Found, 7},
		{.GET, "/static/css/app.css", .Found, 8},
		{.GET, "/static/img/logo.png", .Found, 8},
		{.DELETE, "/api/v1/orders", .Found, 9},
		{.PUT, "/users", .Method_Not_Allowed, 0},
		{.GET, "/missing", .Not_Found, 0},
	}

	for c in cases {
		request: Request_State
		request_state_reset(&request)
		request.method = c.method

		result := match_route(&router, &request, transmute([]u8)c.path)
		if result.outcome != c.expected_outcome {
			testing.fail_now(
				t,
				fmt.tprintf(
					"path %q method %v: expected %v got %v",
					c.path,
					c.method,
					c.expected_outcome,
					result.outcome,
				),
			)
		}
		if c.expected_outcome == .Found {
			actual_handler := uintptr(router.descriptors[result.route_index].handler)
			if actual_handler != c.expected_handler {
				testing.fail_now(
					t,
					fmt.tprintf(
						"path %q method %v: expected handler %d got %d",
						c.path,
						c.method,
						c.expected_handler,
						actual_handler,
					),
				)
			}
		}
	}
}


// ─── Compile-time Route_Budget enforcement ─────────────────────────────────

// Test helper: build a canonical `/a/b/c/...` pattern string with exactly
// `seg_count` single-letter literal segments. No trailing slash — every
// segment is non-empty, so the canonicalizer and `classify_pattern` see
// exactly `seg_count` segments. The result is allocated from
// `context.temp_allocator`; callers reset the temp allocator at end of test
// via `defer free_all(context.temp_allocator)`, so the pattern lifetime ends
// exactly when the test ends.
@(private = "file")
build_pattern_segments :: proc(seg_count: int) -> string {
	pattern := make([]u8, 1 + seg_count * 2 - 1, context.temp_allocator)
	pattern[0] = '/'
	pattern[1] = 'a'
	for i in 1 ..< seg_count {
		pattern[2 * i] = '/'
		pattern[2 * i + 1] = u8('a' + (i % 26))
	}
	return string(pattern)
}

@(test)
test_compile_param_count_exceeds_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	// 9 params against a budget of 8 — the configurable ceiling fires before
	// the u8-width backstop (which would only trip at >255 parts).
	tight := DEFAULT_ROUTE_BUDGET
	routes := []Route{{pattern = "/:a/:b/:c/:d/:e/:f/:g/:h/:i", methods_mask = {.GET}}}
	_, error, error_index := compile_router(routes, tight)
	testing.expect_value(t, error, Compile_Error.Param_Count_Exceeds_Limit)
	testing.expect_value(t, error_index, 0)
}

@(test)
test_compile_param_count_at_boundary_succeeds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	// Exactly param_count_max (8) param segments is the legal edge.
	routes := []Route{{pattern = "/:a/:b/:c/:d/:e/:f/:g/:h", methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
}

@(test)
test_compile_segment_count_exceeds_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	// 17 literal segments against a budget of 16 — the configurable ceiling
	// fires. Build the pattern with literals only so the param check does not
	// mask it.
	pattern := build_pattern_segments(seg_count = 17)
	routes := []Route{{pattern = pattern, methods_mask = {.GET}}}
	_, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	testing.expect_value(t, error, Compile_Error.Segment_Count_Exceeds_Limit)
}

@(test)
test_compile_segment_count_at_boundary_succeeds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	// Exactly path_segment_count_max (16) literal segments is the legal edge.
	pattern := build_pattern_segments(seg_count = 16)
	routes := []Route{{pattern = pattern, methods_mask = {.GET}}}
	router, error, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)
	testing.expect_value(t, error, Compile_Error.None)
}

// ─── Match-time Match_Budget enforcement ───────────────────────────────────

@(test)
test_ensure_path_segment_count_over_limit_caches_sentinel :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	request: Request_State
	request_state_reset(&request)
	count := ensure_path_segment_count(
		&request,
		transmute([]u8)string("/a/b/c/d"),
		path_segment_count_max = 3,
	)
	testing.expect_value(t, count, PATH_SEGMENT_COUNT_OVER_LIMIT)
	testing.expect_value(t, request.path_segment_count, PATH_SEGMENT_COUNT_OVER_LIMIT)

	// Subsequent call must return the cached sentinel — the "never recomputed"
	// invariant for the cached field holds even on the over-limit path.
	count_again := ensure_path_segment_count(
		&request,
		transmute([]u8)string("/short"),
		path_segment_count_max = 3,
	)
	testing.expect_value(t, count_again, PATH_SEGMENT_COUNT_OVER_LIMIT)
}

@(test)
test_match_route_parametric_rejects_over_limit_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	// A 9-segment request path against a router compiled with
	// path_segment_count_max = 16 must NOT match a parametric `/:p`
	// route. Use a long (>16) request path so the over-limit branch fires
	// and short-circuits to Not_Found (no wildcard fallthrough).
	routes := []Route{{pattern = "/:p", methods_mask = {.GET}}}
	router, _, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)

	// 17 segments — exceeds the default path_segment_count_max (16).
	path_bytes := transmute([]u8)build_pattern_segments(seg_count = 17)
	request: Request_State
	request_state_reset(&request)
	result := match_route(&router, &request, path_bytes)
	testing.expect_value(t, result.outcome, Match_Outcome.Not_Found)
	testing.expect_value(t, request.path_segment_count, PATH_SEGMENT_COUNT_OVER_LIMIT)
}

@(test)
test_match_route_parametric_unders_limit_still_routes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	// Sanity: a 1-segment path against `/:p` (under every ceiling) still
	// matches. Guards against the over-limit branch incorrectly rejecting legal input.
	routes := []Route{{pattern = "/:p", methods_mask = {.GET}}}
	router, _, _ := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)

	request: Request_State
	request_state_reset(&request)
	result := match_route(&router, &request, transmute([]u8)string("/hello"))
	testing.expect_value(t, result.outcome, Match_Outcome.Found)
	testing.expect(
		t,
		request.path_segment_count != PATH_SEGMENT_COUNT_OVER_LIMIT,
		"legal path must not carry the over-limit sentinel",
	)
	testing.expect(
		t,
		request.path_segment_count != PATH_SEGMENT_COUNT_NONE,
		"matched path must have its segment count computed",
	)
}

@(test)
test_compile_many_all_method_routes_no_descriptor_overflow :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	ROUTE_COUNT :: 33
	ALL_METHODS :: Method_Mask {
		Method.GET,
		Method.POST,
		Method.PUT,
		Method.DELETE,
		Method.PATCH,
		Method.HEAD,
		Method.OPTIONS,
		Method.TRACE,
	}

	pattern_buf: [8]u8
	routes := make([]Route, ROUTE_COUNT, context.temp_allocator)
	for i in 0 ..< ROUTE_COUNT {
		pattern := fmt.bprintf(pattern_buf[:], "/r%d", i)
		routes[i] = Route {
			handler      = rawptr(uintptr(0x1000 + uintptr(i))),
			handler_kind = .Request,
			pattern      = strings.clone(pattern, context.temp_allocator),
			methods_mask = ALL_METHODS,
		}
	}

	router, error, error_index := compile_router(routes, DEFAULT_ROUTE_BUDGET)
	defer compiled_router_destroy(&router)

	testing.expect_value(t, error, Compile_Error.None)
	testing.expect_value(t, error_index, -1)
	testing.expect_value(t, len(router.descriptors), ROUTE_COUNT)

	for i in 0 ..< ROUTE_COUNT {
		request: Request_State
		request_state_reset(&request)
		request.method = .GET
		path_bytes := transmute([]u8)routes[i].pattern
		result := match_route(&router, &request, path_bytes)
		testing.expect_value(t, result.outcome, Match_Outcome.Found)
		testing.expect_value(
			t,
			router.descriptors[result.route_index].handler,
			rawptr(uintptr(0x1000 + uintptr(i))),
		)
	}
}
