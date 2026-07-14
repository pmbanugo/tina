package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Exit_Code :: enum int {
	Success     = 0,
	Violation   = 1,
	Operational = 2,
}

Violation_Kind :: enum u8 {
	Direct_Isolate_Pointer,
	Direct_State_Assignment,
	Ad_Hoc_Shard_Allocation,
	Raw_Shard_Size_Carrier,
	Raw_Shard_Pointer_Cast,
	Manual_Free_List_Mutation,
	Plain_Ownership_API,
	Mutable_Package_Diagnostic,
	Forbidden_Documentation,
	Direct_Generation_Assignment,
}

VIOLATION_MESSAGES := [Violation_Kind]string {
	.Direct_Isolate_Pointer       = "simulation test contains direct _get_isolate_ptr call",
	.Direct_State_Assignment      = "direct ._state = assignment outside approved setter",
	.Ad_Hoc_Shard_Allocation      = "ad-hoc new(Shard...) in test without allowlist",
	.Raw_Shard_Size_Carrier       = "raw size_of(Shard) allocation carrier without allowlist",
	.Raw_Shard_Pointer_Cast       = "cast to ^Shard from raw memory without allowlist",
	.Manual_Free_List_Mutation    = "manual isolate_free_heads mutation in test without allowlist",
	.Plain_Ownership_API          = "plain ownership API used in ASan-active test path (use _tina_owned wrappers)",
	.Mutable_Package_Diagnostic   = "package-level mutable diagnostic variable",
	.Forbidden_Documentation      = "documentation still teaches post-run isolate/payload inspection",
	.Direct_Generation_Assignment = "direct isolate metadata generation assignment outside approved owner",
}

Odin_File_Attribute :: enum u8 {
	Simulation_Test,
	Tina_Owned_Test_Path,
	Shard_Fixture_File_Allowlist,
}

Odin_File_Attributes :: bit_set[Odin_File_Attribute; u8]

Allowlist_Marker :: enum u8 {
	Hand_Rolled_Shard_Fixture,
	Hydrate_Shard_Fixture,
	State_Setter,
	Free_List_Mutation,
}

Allowlist_Markers :: bit_set[Allowlist_Marker; u8]

Scan_Status :: enum u8 {Success, Read_Failure, Parse_Failure, Allocation_Failure, Input_Too_Large, Capacity_Exhausted}
Collect_Status :: enum u8 {Success, Traversal_Failure, Relative_Path_Failure, Allocation_Failure, Capacity_Exhausted}
Root_Status :: enum u8 {Success, Resolution_Failure}
Self_Test_Preparation_Status :: enum u8 {Success, Directory_Failure, Write_Failure, Allocation_Failure}
Record_Status :: enum u8 {Success, Allocation_Failure, Capacity_Exhausted}

Violation :: struct {
	path_relative: string,
	line_number:   u32,
	kind:          Violation_Kind,
}

File_Path :: struct {
	path_absolute: string,
	path_relative: string,
	file_name:     string,
}

Scan :: struct {
	file:             ^ast.File,
	file_path:        ^File_Path,
	violations:       ^[dynamic]Violation,
	allowlist_lines:  []Allowlist_Markers,
	attributes:       Odin_File_Attributes,
	status:           Scan_Status,
}

INPUT_FILE_SIZE_MAX :: 4 * 1024 * 1024
COLLECTED_FILE_COUNT_MAX :: 4096
DIRECTORY_ENTRY_COUNT_MAX :: 65536
VIOLATION_COUNT_MAX :: 65536

APPROVED_GENERATION_OWNER_FILE_NAMES :: [?]string {
	"test_shard_builder.odin", "allocator_arena.odin", "isolate_lifecycle.odin", "shard.odin",
}

OWNERSHIP_SENSITIVE_PROCEDURE_NAMES :: [?]string {
	"pool_init",
	"pool_alloc_user",
	"pool_alloc_system",
	"pool_free",
	"pool_free_unchecked",
	"pool_reset",
	"io_slot_pool_init",
	"io_slot_pool_alloc",
	"io_slot_pool_alloc_unzeroed",
	"io_slot_pool_free",
	"io_slot_pool_reset",
	"reactor_init",
	"spsc_ring_init",
	"spsc_ring_enqueue",
	"spsc_ring_commit_read",
	"log_init",
}

ALLOWLIST_MARKER_TEXTS := [Allowlist_Marker]string {
	.Hand_Rolled_Shard_Fixture = "ALLOWLIST(hand_rolled_shard_fixture)",
	.Hydrate_Shard_Fixture     = "ALLOWLIST(hydrate_shard_fixture)",
	.State_Setter              = "ALLOWLIST_STATE_SETTER",
	.Free_List_Mutation        = "ALLOWLIST(free_list_mutation)",
}

#assert(len(VIOLATION_MESSAGES) == len(Violation_Kind))
#assert(len(ALLOWLIST_MARKER_TEXTS) == len(Allowlist_Marker))

input_file_size_is_allowed :: proc(file_size: i64) -> bool {
	return file_size <= INPUT_FILE_SIZE_MAX
}

collected_file_count_is_allowed :: proc(file_count: int) -> bool {
	return file_count <= COLLECTED_FILE_COUNT_MAX
}

directory_entry_count_is_allowed :: proc(directory_entry_count: int) -> bool {
	return directory_entry_count <= DIRECTORY_ENTRY_COUNT_MAX
}

violation_count_is_allowed :: proc(violation_count: int) -> bool {
	return violation_count <= VIOLATION_COUNT_MAX
}

input_file_size_status :: proc(file_size: i64) -> Scan_Status {
	if input_file_size_is_allowed(file_size) { return .Success }
	return .Input_Too_Large
}

collected_file_count_status :: proc(file_count: int) -> Collect_Status {
	if collected_file_count_is_allowed(file_count) { return .Success }
	return .Capacity_Exhausted
}

directory_entry_count_status :: proc(directory_entry_count: int) -> Collect_Status {
	if directory_entry_count_is_allowed(directory_entry_count) { return .Success }
	return .Capacity_Exhausted
}

violation_count_status :: proc(violation_count: int) -> Record_Status {
	if violation_count_is_allowed(violation_count) { return .Success }
	return .Capacity_Exhausted
}

main :: proc() {
	arguments := os.args
	if len(arguments) > 2 {
		usage()
		os.exit(int(Exit_Code.Operational))
	}
	if len(arguments) == 2 {
		if arguments[1] != "--self-test" {
			usage()
			os.exit(int(Exit_Code.Operational))
		}
		os.exit(int(run_self_test()))
	}
	root_path, root_status := repository_root()
	if root_status != .Success {
		fmt.eprintln("[HYGIENE ERROR] cannot resolve repository root")
		os.exit(int(Exit_Code.Operational))
	}
	violations, make_error := make([dynamic]Violation, context.allocator)
	if make_error != nil {
		delete(root_path)
		os.exit(int(report_allocation_error()))
	}
	if gate_result := run_gate(root_path, &violations); gate_result != .Success {
		delete_violations(&violations)
		delete(root_path)
		os.exit(int(gate_result))
	}
	result := print_result(&violations)
	delete_violations(&violations)
	delete(root_path)
	os.exit(int(result))
}

usage :: proc() {
	fmt.eprintln("usage: odin run scripts/check_test_hygiene.odin -file -strict-style -- [--self-test]")
}

parser_error_handler :: proc(position: tokenizer.Pos, message: string, arguments: ..any) {
	fmt.eprintf("[HYGIENE ERROR] %s:%d:%d: ", position.file, position.line, position.column)
	fmt.eprintf(message, ..arguments)
	fmt.eprintln()
}

normalize_relative_path :: proc(path_relative: string) {
	for &character in transmute([]byte)path_relative {
		if character == '\\' {
			character = '/'
		}
	}
}

append_file_path :: proc(root_path, path_absolute: string, paths: ^[dynamic]File_Path) -> Collect_Status {
	if capacity_status := collected_file_count_status(len(paths) + 1); capacity_status != .Success {
		return capacity_status
	}
	absolute_copy, absolute_allocation_error := strings.clone(path_absolute, paths.allocator)
	if absolute_allocation_error != nil {
		return .Allocation_Failure
	}
	path_relative, relative_error := filepath.rel(root_path, absolute_copy, paths.allocator)
	if relative_error != nil {
		delete(absolute_copy, paths.allocator)
		return .Relative_Path_Failure
	}
	normalize_relative_path(path_relative)
	_, file_name := os.split_path(absolute_copy)
	file_path := File_Path{absolute_copy, path_relative, file_name}
	if _, append_allocation_error := append(paths, file_path); append_allocation_error != nil {
		delete(path_relative, paths.allocator)
		delete(absolute_copy, paths.allocator)
		return .Allocation_Failure
	}
	return .Success
}

collect_files :: proc(
	root_path, directory_path, suffix: string,
	files: ^[dynamic]File_Path,
) -> (status: Collect_Status, error_path: string, traversal_error: os.Error) {
	walker := os.walker_create(directory_path)
	defer os.walker_destroy(&walker)

	directory_entry_count := 0
	for information in os.walker_walk(&walker) {
		directory_entry_count += 1
		if capacity_status := directory_entry_count_status(directory_entry_count); capacity_status != .Success {
			return capacity_status, "", nil
		}
		if information.type != .Regular {
			continue
		}
		if !strings.has_suffix(information.name, suffix) {
			continue
		}

		append_status := append_file_path(root_path, information.fullpath, files)
		if append_status == .Relative_Path_Failure {
			path_copy, copy_allocation_error := strings.clone(information.fullpath, files.allocator)
			if copy_allocation_error != nil {
				return .Allocation_Failure, "", nil
			}
			return .Relative_Path_Failure, path_copy, .Invalid_Argument
		}
		if append_status != .Success {
			return append_status, "", nil
		}
	}

	if path, walk_error := os.walker_error(&walker); walk_error != nil {
		// The deferred walker destruction runs before the caller can report its borrowed error path.
		path_copy, path_allocation_error := strings.clone(path, files.allocator)
		if path_allocation_error != nil {
			return .Allocation_Failure, "", nil
		}
		return .Traversal_Failure, path_copy, walk_error
	}
	return .Success, "", nil
}

sort_file_paths :: proc(files: []File_Path) {
	slice.sort_by(files, proc(left, right: File_Path) -> bool {
		return left.path_relative < right.path_relative
	})
}

source_line_count :: proc(source: string) -> int {
	line_count := 1
	for character in source {
		if character == '\n' {
			line_count += 1
		}
	}
	return line_count
}

mark_comment_allowlists :: proc(lines: []Allowlist_Markers, text: string, line_number_start: int) {
	for marker in Allowlist_Marker {
		search_offset := 0
		for search_offset < len(text) {
			marker_offset := strings.index(text[search_offset:], ALLOWLIST_MARKER_TEXTS[marker])
			if marker_offset < 0 {
				break
			}
			marker_offset += search_offset
			line_number := line_number_start
			for character in text[:marker_offset] {
				if character == '\n' {
					line_number += 1
				}
			}
			assert(line_number < len(lines))
			lines[line_number] += {marker}
			search_offset = marker_offset + len(ALLOWLIST_MARKER_TEXTS[marker])
		}
	}
}

build_allowlist_lines :: proc(file: ^ast.File, source: string, allocator: runtime.Allocator) -> (
	lines: []Allowlist_Markers,
	shard_file_allowlist: bool,
	allocation_error: runtime.Allocator_Error,
) {
	lines = make([]Allowlist_Markers, source_line_count(source) + 1, allocator) or_return
	for group in file.comments {
		for token in group.list {
			mark_comment_allowlists(lines, token.text, token.pos.line)
			if strings.contains(token.text, "ALLOWLIST_FILE(hand_rolled_shard_fixture)") {
				shard_file_allowlist = true
			}
			if strings.contains(token.text, "ALLOWLIST_FILE(hydrate_shard_fixture)") {
				shard_file_allowlist = true
			}
		}
	}
	return lines, shard_file_allowlist, nil
}

scan_allowlist_is_adjacent :: proc(scan: ^Scan, line_number: u32, marker: Allowlist_Marker) -> bool {
	assert(line_number > 0)
	assert(int(line_number) < len(scan.allowlist_lines))
	if marker in scan.allowlist_lines[line_number] {
		return true
	}
	return marker in scan.allowlist_lines[line_number - 1]
}

append_violation :: proc(violations: ^[dynamic]Violation, path_relative: string, line_number: u32, kind: Violation_Kind) -> Record_Status {
	if capacity_status := violation_count_status(len(violations) + 1); capacity_status != .Success {
		return capacity_status
	}
	// Findings outlive the file-path collections used to discover them.
	path_copy, copy_error := strings.clone(path_relative, violations.allocator)
	if copy_error != nil {
		return .Allocation_Failure
	}
	if _, allocation_error := append(violations, Violation{path_copy, line_number, kind}); allocation_error != nil {
		delete(path_copy, violations.allocator)
		return .Allocation_Failure
	}
	return .Success
}

record_violation :: proc(scan: ^Scan, line_number: int, kind: Violation_Kind) {
	if scan.status != .Success {
		return
	}
	assert(line_number > 0)
	record_status := append_violation(scan.violations, scan.file_path.path_relative, u32(line_number), kind)
	switch record_status {
	case .Success:
	case .Allocation_Failure:
		scan.status = .Allocation_Failure
	case .Capacity_Exhausted:
		scan.status = .Capacity_Exhausted
	}
}

expression_identifier :: proc(expression: ^ast.Expr) -> string {
	if expression == nil {
		return ""
	}
	#partial switch value in expression.derived {
	case ^ast.Ident:
		return value.name
	case ^ast.Selector_Expr:
		return value.field.name
	case:
		return ""
	}
}

expression_is_pointer_to_shard :: proc(expression: ^ast.Expr) -> bool {
	if expression == nil {
		return false
	}
	#partial switch pointer in expression.derived {
	case ^ast.Pointer_Type:
		return expression_identifier(pointer.elem) == "Shard"
	case:
		return false
	}
}

expression_is_indexed_name :: proc(expression: ^ast.Expr, name: string) -> bool {
	if expression == nil {
		return false
	}
	#partial switch index_expression in expression.derived {
	case ^ast.Index_Expr:
		return expression_identifier(index_expression.expr) == name
	case:
		return false
	}
}

expression_is_metadata_generation_target :: proc(expression: ^ast.Expr) -> bool {
	current := expression
	for current != nil {
		#partial switch value in current.derived {
		case ^ast.Index_Expr:
			current = value.expr
		case ^ast.Selector_Expr:
			if value.field.name != "generation" {
				return false
			}
			current = value.expr
			for current != nil {
				#partial switch receiver in current.derived {
				case ^ast.Index_Expr:
					current = receiver.expr
				case ^ast.Selector_Expr:
					if receiver.field.name == "metadata" {
						return true
					}
					current = receiver.expr
				case:
					return false
				}
			}
		case:
			return false
		}
	}
	return false
}

generation_owner_file_name_is_approved :: proc(file_name: string) -> bool {
	for approved_file_name in APPROVED_GENERATION_OWNER_FILE_NAMES {
		if file_name == approved_file_name {
			return true
		}
	}
	return false
}

check_generation_assignment :: proc(scan: ^Scan, line_number: int) {
	if generation_owner_file_name_is_approved(scan.file_path.file_name) {
		return
	}
	record_violation(scan, line_number, .Direct_Generation_Assignment)
}

check_call :: proc(scan: ^Scan, call: ^ast.Call_Expr) {
	name := expression_identifier(call.expr)
	if .Simulation_Test in scan.attributes {
		if name == "_get_isolate_ptr" {
			record_violation(scan, call.pos.line, .Direct_Isolate_Pointer)
		}
	}
	if name == "new" {
		if len(call.args) > 0 {
			if expression_identifier(call.args[0]) == "Shard" {
				check_shard_call(scan, call, .Ad_Hoc_Shard_Allocation)
			}
		}
	}
	if name == "size_of" {
		if len(call.args) == 1 {
			if expression_identifier(call.args[0]) == "Shard" {
				check_shard_call(scan, call, .Raw_Shard_Size_Carrier)
			}
		}
	}
	if .Tina_Owned_Test_Path in scan.attributes {
		if ownership_sensitive_procedure_name(name) {
			record_violation(scan, call.pos.line, .Plain_Ownership_API)
		}
	}
}

check_shard_call :: proc(scan: ^Scan, call: ^ast.Call_Expr, kind: Violation_Kind) {
	if scan.file_path.file_name == "bootstrap_shard.odin" {
		return
	}
	if .Shard_Fixture_File_Allowlist in scan.attributes {
		return
	}
	if scan_allowlist_is_adjacent(scan, u32(call.pos.line), .Hand_Rolled_Shard_Fixture) {
		return
	}
	if scan_allowlist_is_adjacent(scan, u32(call.pos.line), .Hydrate_Shard_Fixture) {
		return
	}
	record_violation(scan, call.pos.line, kind)
}

ownership_sensitive_procedure_name :: proc(name: string) -> bool {
	for procedure_name in OWNERSHIP_SENSITIVE_PROCEDURE_NAMES {
		if name == procedure_name {
			return true
		}
	}
	return false
}

check_assignment :: proc(scan: ^Scan, assignment: ^ast.Assign_Stmt) {
	for expression in assignment.lhs {
		#partial switch selector in expression.derived {
		case ^ast.Selector_Expr:
			if selector.field.name == "_state" {
				if assignment.op.kind == .Eq {
					if !scan_allowlist_is_adjacent(scan, u32(expression.pos.line), .State_Setter) {
						record_violation(scan, expression.pos.line, .Direct_State_Assignment)
					}
				}
			}
		case:
			_ = selector
		}
		if expression_is_indexed_name(expression, "isolate_free_heads") {
			if assignment.op.kind == .Eq {
				check_free_list_assignment(scan, expression.pos.line)
			}
		}
		if expression_is_metadata_generation_target(expression) {
			check_generation_assignment(scan, expression.pos.line)
		}
	}
}

check_free_list_assignment :: proc(scan: ^Scan, line_number: int) {
	switch scan.file_path.file_name {
	case "test_shard_builder.odin", "bootstrap_shard.odin", "allocator_arena.odin",
	     "isolate_lifecycle.odin", "shard.odin", "io_reactor.odin":
		return
	}
	if scan_allowlist_is_adjacent(scan, u32(line_number), .Free_List_Mutation) {
		return
	}
	record_violation(scan, line_number, .Manual_Free_List_Mutation)
}

check_type_cast :: proc(scan: ^Scan, type_cast: ^ast.Type_Cast) {
	if !expression_is_pointer_to_shard(type_cast.type) {
		return
	}
	if scan.file_path.file_name == "bootstrap_shard.odin" {
		return
	}
	if .Shard_Fixture_File_Allowlist in scan.attributes {
		return
	}
	if scan_allowlist_is_adjacent(scan, u32(type_cast.pos.line), .Hand_Rolled_Shard_Fixture) {
		return
	}
	if scan_allowlist_is_adjacent(scan, u32(type_cast.pos.line), .Hydrate_Shard_Fixture) {
		return
	}
	record_violation(scan, type_cast.pos.line, .Raw_Shard_Pointer_Cast)
}

scan_odin_file_visit_node :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return visitor
	}
	scan := cast(^Scan)visitor.data
	if scan.status != .Success {
		return nil
	}
	#partial switch value in node.derived {
	case ^ast.Call_Expr:
		check_call(scan, value)
	case ^ast.Assign_Stmt:
		check_assignment(scan, value)
	case ^ast.Type_Cast:
		check_type_cast(scan, value)
	case:
		_ = value
	}
	return visitor
}

check_package_diagnostics_visit_node :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return visitor
	}
	scan := cast(^Scan)visitor.data
	if scan.status != .Success {
		return nil
	}
	#partial switch value in node.derived {
	case ^ast.When_Stmt, ^ast.Block_Stmt, ^ast.Foreign_Block_Decl:
		return visitor
	case ^ast.Value_Decl:
		if value.is_mutable {
			for name_expression in value.names {
				name := expression_identifier(name_expression)
				if strings.contains(name, "diagnostic") {
					record_violation(scan, name_expression.pos.line, .Mutable_Package_Diagnostic)
				}
			}
		}
	case:
		_ = value
	}
	return nil
}

check_package_diagnostics :: proc(scan: ^Scan) {
	visitor := ast.Visitor{visit = check_package_diagnostics_visit_node, data = scan}
	for declaration in scan.file.decls {
		ast.walk(&visitor, declaration)
		if scan.status != .Success {
			return
		}
	}
}

scan_odin_file :: proc(
	file_path: ^File_Path,
	violations: ^[dynamic]Violation,
	file_allocator: runtime.Allocator,
) -> Scan_Status {
	file_information, stat_error := os.stat(file_path.path_absolute, file_allocator)
	if stat_error != nil {
		fmt.eprintfln("[HYGIENE ERROR] cannot inspect %s: %v", file_path.path_relative, stat_error)
		return .Read_Failure
	}
	defer os.file_info_delete(file_information, file_allocator)
	assert(file_information.size >= 0)
	if input_file_size_status(file_information.size) != .Success {
		fmt.eprintfln("[HYGIENE ERROR] input file exceeds 4 MiB limit: %s", file_path.path_relative)
		return .Input_Too_Large
	}
	source, read_error := os.read_entire_file(file_path.path_absolute, file_allocator)
	if read_error != nil {
		fmt.eprintfln("[HYGIENE ERROR] cannot read %s: %v", file_path.path_relative, read_error)
		return .Read_Failure
	}

	context.allocator = file_allocator
	file := ast.new_from_positions(ast.File, {}, {})
	file.fullpath = file_path.path_absolute
	file.src = string(source)
	parser_state := parser.Parser{flags = {.Optional_Semicolons}, err = parser_error_handler}
	parsed := parser.parse_file(&parser_state, file)
	if !parsed {
		fmt.eprintfln("[HYGIENE ERROR] cannot parse %s (%d syntax error(s))", file_path.path_relative, file.syntax_error_count)
		return .Parse_Failure
	}
	if file.syntax_error_count != 0 {
		fmt.eprintfln("[HYGIENE ERROR] cannot parse %s (%d syntax error(s))", file_path.path_relative, file.syntax_error_count)
		return .Parse_Failure
	}

	allowlist_lines, shard_file_allowlist, allowlist_error := build_allowlist_lines(file, file.src, file_allocator)
	if allowlist_error != nil {
		return .Allocation_Failure
	}
	scan := initialize_scan(file, file_path, violations, allowlist_lines, shard_file_allowlist)
	check_package_diagnostics(&scan)
	visitor := ast.Visitor{visit = scan_odin_file_visit_node, data = &scan}
	ast.walk(&visitor, file)
	return scan.status
}

initialize_scan :: proc(
	file: ^ast.File,
	file_path: ^File_Path,
	violations: ^[dynamic]Violation,
	allowlist_lines: []Allowlist_Markers,
	shard_file_allowlist: bool,
) -> Scan {
	attributes: Odin_File_Attributes
	file_name := file_path.file_name
	if strings.has_prefix(file_name, "simulated_test") {
		if strings.has_suffix(file_name, ".odin") {
			attributes += {.Simulation_Test, .Tina_Owned_Test_Path}
		}
	}
	for tina_owned_file_name in ([]string{"test_shard_builder.odin", "test_shard_fixture_lifecycle.odin", "test_shard_fixture_asan_probes.odin", "test_asan_death_runner.odin"}) {
		if file_name == tina_owned_file_name {
			attributes += {.Tina_Owned_Test_Path}
		}
	}
	if shard_file_allowlist {
		attributes += {.Shard_Fixture_File_Allowlist}
	}
	return Scan{file, file_path, violations, allowlist_lines, attributes, .Success}
}

documentation_line_is_forbidden :: proc(line_text: string) -> bool {
	if strings.contains(line_text, "inspect isolate memory") {
		return true
	}
	if strings.contains(line_text, "inspect payload memory") {
		return true
	}
	if line_offset := strings.index(line_text, "post-run"); line_offset >= 0 {
		remainder := line_text[line_offset + len("post-run"):]
		if inspect_offset := strings.index(remainder, "inspect"); inspect_offset >= 0 {
			after_inspect := remainder[inspect_offset + len("inspect"):]
			if strings.contains(after_inspect, "isolate") {
				return true
			}
			if strings.contains(after_inspect, "payload") {
				return true
			}
		}
	}
	if line_offset := strings.index(line_text, "after simulator_run"); line_offset >= 0 {
		return strings.contains(line_text[line_offset + len("after simulator_run"):], "inspect")
	}
	return false
}

scan_documentation_file :: proc(
	file_path: ^File_Path,
	violations: ^[dynamic]Violation,
	allocator: runtime.Allocator,
) -> Scan_Status {
	file_information, stat_error := os.stat(file_path.path_absolute, allocator)
	if stat_error != nil {
		fmt.eprintfln("[HYGIENE ERROR] cannot inspect %s: %v", file_path.path_relative, stat_error)
		return .Read_Failure
	}
	defer os.file_info_delete(file_information, allocator)
	assert(file_information.size >= 0)
	if input_file_size_status(file_information.size) != .Success {
		fmt.eprintfln("[HYGIENE ERROR] input file exceeds 4 MiB limit: %s", file_path.path_relative)
		return .Input_Too_Large
	}
	data, read_error := os.read_entire_file(file_path.path_absolute, allocator)
	if read_error != nil {
		fmt.eprintfln("[HYGIENE ERROR] cannot read %s: %v", file_path.path_relative, read_error)
		return .Read_Failure
	}
	text := string(data)
	line_number := 1
	line_offset_start := 0
	for line_offset := 0; line_offset <= len(text); line_offset += 1 {
		if line_offset < len(text) {
			if text[line_offset] != '\n' {
				continue
			}
		}
		if documentation_line_is_forbidden(text[line_offset_start:line_offset]) {
			record_status := append_violation(violations, file_path.path_relative, u32(line_number), .Forbidden_Documentation)
			if record_status == .Allocation_Failure {
				return .Allocation_Failure
			}
			if record_status == .Capacity_Exhausted {
				return .Capacity_Exhausted
			}
		}
		line_offset_start = line_offset + 1
		line_number += 1
	}
	return .Success
}

sort_violations :: proc(violations: []Violation) {
	slice.sort_by(violations, proc(left, right: Violation) -> bool {
		if left.path_relative != right.path_relative {
			return left.path_relative < right.path_relative
		}
		if left.line_number != right.line_number {
			return left.line_number < right.line_number
		}
		return VIOLATION_MESSAGES[left.kind] < VIOLATION_MESSAGES[right.kind]
	})
}

run_gate :: proc(root_path: string, violations: ^[dynamic]Violation) -> Exit_Code {
	odin_files, make_error := make([dynamic]File_Path, context.allocator)
	if make_error != nil {
		return report_allocation_error()
	}
	defer delete_file_paths(&odin_files)
	for directory_name in ([]string{"src", "tests"}) {
		directory_path, join_error := filepath.join({root_path, directory_name}, context.temp_allocator)
		if join_error != nil {
			return report_allocation_error()
		}
		collect_status, error_path, walk_error := collect_files(root_path, directory_path, ".odin", &odin_files)
		if collect_status == .Allocation_Failure {
			return report_allocation_error()
		}
		if collect_status == .Capacity_Exhausted {
			return report_capacity_error("file collection or directory traversal")
		}
		if collect_status != .Success {
			fmt.eprintfln("[HYGIENE ERROR] cannot traverse %s: %v", error_path, walk_error)
			delete(error_path, odin_files.allocator)
			return .Operational
		}
		assert(error_path == "")
	}
	sort_file_paths(odin_files[:])
	if scan_odin_files(odin_files[:], violations) != .Success {
		return .Operational
	}
	return scan_documentation(root_path, violations)
}

scan_odin_files :: proc(files: []File_Path, violations: ^[dynamic]Violation) -> Exit_Code {
	file_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&file_arena)
	defer mem.dynamic_arena_destroy(&file_arena)
	file_allocator := mem.dynamic_arena_allocator(&file_arena)
	for file_index in 0..<len(files) {
		scan_status := scan_odin_file(&files[file_index], violations, file_allocator)
		mem.dynamic_arena_reset(&file_arena)
		if scan_status == .Allocation_Failure {
			return report_allocation_error()
		}
		if scan_status == .Capacity_Exhausted {
			return report_capacity_error("violation collection")
		}
		if scan_status != .Success {
			return .Operational
		}
	}
	return .Success
}

scan_documentation :: proc(root_path: string, violations: ^[dynamic]Violation) -> Exit_Code {
	documentation, make_error := make([dynamic]File_Path, context.allocator)
	if make_error != nil {
		return report_allocation_error()
	}
	defer delete_file_paths(&documentation)
	readme, join_error := filepath.join({root_path, "src", "README_DST.md"}, context.temp_allocator)
	if join_error != nil { return report_allocation_error() }
	_, readme_stat_error := os.stat(readme, context.temp_allocator)
	if readme_stat_error == nil {
		append_status := append_file_path(root_path, readme, &documentation)
		assert(append_status != .Relative_Path_Failure)
		if append_status == .Allocation_Failure {
			return report_allocation_error()
		}
		if append_status == .Capacity_Exhausted { return report_capacity_error("file collection") }
	} else if readme_stat_error != .Not_Exist {
		fmt.eprintfln("[HYGIENE ERROR] cannot inspect src/README_DST.md: %v", readme_stat_error)
		return .Operational
	}
	docs, docs_join_error := filepath.join({root_path, "docs"}, context.temp_allocator)
	if docs_join_error != nil { return report_allocation_error() }
	_, docs_stat_error := os.stat(docs, context.temp_allocator)
	if docs_stat_error == nil {
		collect_status, error_path, walk_error := collect_files(root_path, docs, ".md", &documentation)
		if collect_status == .Allocation_Failure { return report_allocation_error() }
		if collect_status == .Capacity_Exhausted { return report_capacity_error("file collection or directory traversal") }
		if collect_status != .Success {
			fmt.eprintfln("[HYGIENE ERROR] cannot traverse %s: %v", error_path, walk_error)
			delete(error_path, documentation.allocator)
			return .Operational
		}
		assert(error_path == "")
	} else if docs_stat_error != .Not_Exist {
		fmt.eprintfln("[HYGIENE ERROR] cannot inspect docs: %v", docs_stat_error)
		return .Operational
	}
	sort_file_paths(documentation[:])
	file_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&file_arena)
	defer mem.dynamic_arena_destroy(&file_arena)
	file_allocator := mem.dynamic_arena_allocator(&file_arena)
	for file_index in 0..<len(documentation) {
		scan_status := scan_documentation_file(&documentation[file_index], violations, file_allocator)
		mem.dynamic_arena_reset(&file_arena)
		if scan_status == .Allocation_Failure { return report_allocation_error() }
		if scan_status == .Capacity_Exhausted { return report_capacity_error("violation collection") }
		if scan_status != .Success { return .Operational }
	}
	return .Success
}

delete_file_paths :: proc(paths: ^[dynamic]File_Path) {
	for path in paths {
		delete(path.path_absolute, paths.allocator)
		delete(path.path_relative, paths.allocator)
	}
	delete(paths^)
}

delete_violations :: proc(violations: ^[dynamic]Violation) {
	for violation in violations {
		delete(violation.path_relative, violations.allocator)
	}
	delete(violations^)
}

report_allocation_error :: proc() -> Exit_Code {
	fmt.eprintln("[HYGIENE ERROR] memory allocation failed")
	return .Operational
}

report_capacity_error :: proc(resource: string) -> Exit_Code {
	fmt.eprintfln("[HYGIENE ERROR] %s capacity exhausted", resource)
	return .Operational
}

print_result :: proc(violations: ^[dynamic]Violation) -> Exit_Code {
	if len(violations) == 0 {
		fmt.println("[HYGIENE OK] Test architecture invariants satisfied.")
		return .Success
	}
	sort_violations(violations[:])
	for violation in violations {
		fmt.printfln("[HYGIENE FAIL] %s:%d:%s", violation.path_relative, violation.line_number, VIOLATION_MESSAGES[violation.kind])
	}
	fmt.printfln("\n%d test-architecture hygiene violation(s) found.", len(violations))
	return .Violation
}

write_self_test_file :: proc(root_path, path_relative, contents: string) -> Self_Test_Preparation_Status {
	path_absolute, join_error := filepath.join({root_path, path_relative}, context.temp_allocator)
	if join_error != nil {
		fmt.eprintfln("[HYGIENE SELF-TEST FAILED] cannot allocate path for %s", path_relative)
		return .Allocation_Failure
	}
	if write_error := os.write_entire_file(path_absolute, contents); write_error != nil {
		fmt.eprintfln("[HYGIENE SELF-TEST FAILED] cannot write %s: %v", path_relative, write_error)
		return .Write_Failure
	}
	return .Success
}

SELF_TEST_SIMULATED :: `package hygiene_self_test

bad_payload :: proc(shard: ^Shard) {
	_ = _get_isolate_ptr(
		shard,
		0,
		0,
	)
	shard.metadata[0][0]._state = .Runnable
	_ = new(Shard, context.temp_allocator); _ = size_of(Shard)
	_ = cast(^Shard) (
		raw_memory
	)
	_ = transmute(^Shard)raw_memory
	shard.isolate_free_heads[0] = 1
	shard.metadata[0][0].generation = 2
	pool_init()
	pool_alloc_user()
	pool_alloc_system()
	pool_free()
	pool_free_unchecked()
	pool_reset()
	io_slot_pool_init()
	io_slot_pool_alloc()
	io_slot_pool_alloc_unzeroed()
	io_slot_pool_free()
	io_slot_pool_reset()
	reactor_init()
	spsc_ring_init()
	spsc_ring_enqueue()
	spsc_ring_commit_read()
	log_init()
}

allowed :: proc() {
	_ = new(Shard) // ALLOWLIST(hydrate_shard_fixture)
	// ALLOWLIST_STATE_SETTER
	shard._state = .Runnable
	// ALLOWLIST(free_list_mutation)
	shard.isolate_free_heads[0] = 1
	_ = make([]Shard, 4)
	other.generation = 2
	pool_init_tina_owned()
}

non_matches :: proc() {
	// _get_isolate_ptr(shard, 0, 0)
	_ = "new(Shard) pool_init( isolate_free_heads[0] = 1 metadata.generation = 2"
}
`

SELF_TEST_DIAGNOSTIC :: `package hygiene_self_test

bad_diagnostic_counter: u64
diagnostic_type :: struct {}
when true {
	conditional_diagnostic_counter: u64
}
local_only :: proc() {
	local_diagnostic: u64
	_ = local_diagnostic
	when true {
		local_when_diagnostic: u64
		_ = local_when_diagnostic
	}
}
`

SELF_TEST_FILE_ALLOWLIST :: `package hygiene_self_test

// ALLOWLIST_FILE(hand_rolled_shard_fixture)
allowed :: proc(memory: rawptr) {
	_ = new(Shard)
	_ = size_of(Shard)
	_ = cast(^Shard)memory
}
`

SELF_TEST_NESTED :: `package hygiene_self_test

bad_cast :: proc(memory: rawptr) {
	_ = transmute(^Shard)memory
}
`

SELF_TEST_ASAN_PROBE :: `package hygiene_self_test
bad :: proc() { reactor_init() }
`

SELF_TEST_ASAN_RUNNER :: `package hygiene_self_test
bad :: proc() { log_init() }
`

SELF_TEST_GENERATION_OWNER :: `package hygiene_self_test
allowed :: proc(shard: ^Shard) { shard.metadata[0][0].generation = 1 }
`

prepare_self_test_directories :: proc(root_path: string) -> Self_Test_Preparation_Status {
	for directory in ([]string{"src", "src/nested", "tests", "docs", "docs/nested"}) {
		path_absolute, join_error := filepath.join({root_path, directory}, context.temp_allocator)
		if join_error != nil {
			fmt.eprintln("[HYGIENE SELF-TEST FAILED] cannot allocate directory path")
			return .Allocation_Failure
		}
		if make_error := os.make_directory_all(path_absolute); make_error != nil {
			fmt.eprintfln("[HYGIENE SELF-TEST FAILED] cannot create %s: %v", directory, make_error)
			return .Directory_Failure
		}
	}
	return .Success
}

prepare_self_test_tree :: proc(root_path: string) -> Self_Test_Preparation_Status {
	if status := prepare_self_test_directories(root_path); status != .Success {
		return status
	}
	files := []struct {path_relative, contents: string} {
		{"src/simulated_test_self.odin", SELF_TEST_SIMULATED},
		{"src/diagnostic_self.odin", SELF_TEST_DIAGNOSTIC},
		{"tests/file_allowlist.odin", SELF_TEST_FILE_ALLOWLIST},
		{"src/nested/carrier.odin", SELF_TEST_NESTED},
		{"src/test_shard_fixture_asan_probes.odin", SELF_TEST_ASAN_PROBE},
		{"src/test_asan_death_runner.odin", SELF_TEST_ASAN_RUNNER},
		{"src/allocator_arena.odin", SELF_TEST_GENERATION_OWNER},
		{"docs/nested/bad.md", "Tests may inspect isolate memory.\nTests may inspect payload memory.\nA post-run check can inspect the isolate.\nafter simulator_run returns, inspect the result.\n"},
		{"src/README_DST.md", "No forbidden advice here.\n"},
	}
	for file in files {
		if status := write_self_test_file(root_path, file.path_relative, file.contents); status != .Success {
			return status
		}
	}
	return .Success
}

 self_test_has_path_count :: proc(violations: []Violation, path_relative: string, violation_count_expected: int) -> bool {
	actual_count := 0
	for violation in violations {
		if violation.path_relative == path_relative {
			actual_count += 1
		}
	}
	return actual_count == violation_count_expected
}

self_test_classes_are_complete :: proc(violations: []Violation) -> bool {
	for kind in Violation_Kind {
		kind_found := false
		for violation in violations {
			if violation.kind == kind {
				kind_found = true
				break
			}
		}
		if !kind_found {
			return false
		}
	}
	return true
}

self_test_violation_paths_are_preserved :: proc(violations: []Violation) -> bool {
	if !self_test_has_path_count(violations, "docs/nested/bad.md", 4) {
		return false
	}
	if !self_test_has_path_count(violations, "src/diagnostic_self.odin", 2) {
		return false
	}
	if !self_test_has_path_count(violations, "src/nested/carrier.odin", 1) {
		return false
	}
	if !self_test_has_path_count(violations, "src/simulated_test_self.odin", 24) {
		return false
	}
	if !self_test_has_path_count(violations, "src/test_shard_fixture_asan_probes.odin", 1) {
		return false
	}
	return self_test_has_path_count(violations, "src/test_asan_death_runner.odin", 1)
}

self_test_ordering_is_stable :: proc(violations: []Violation) -> bool {
	for index in 1..<len(violations) {
		left, right := violations[index - 1], violations[index]
		if right.path_relative < left.path_relative {
			return false
		}
		if right.path_relative == left.path_relative {
			if right.line_number < left.line_number {
				return false
			}
			if right.line_number == left.line_number {
				if VIOLATION_MESSAGES[right.kind] < VIOLATION_MESSAGES[left.kind] { return false }
			}
		}
	}
	return true
}

self_test_walker_error_path_is_preserved :: proc(root_path: string) -> bool {
	missing_directory, join_error := filepath.join({root_path, "missing"}, context.temp_allocator)
	if join_error != nil {
		return false
	}
	paths, make_error := make([dynamic]File_Path, context.allocator)
	if make_error != nil {
		return false
	}
	defer delete_file_paths(&paths)
	status, error_path, walk_error := collect_files(root_path, missing_directory, ".odin", &paths)
	if status != .Traversal_Failure {
		assert(error_path == "")
		return false
	}
	assert(walk_error != nil)
	path_is_preserved := error_path == missing_directory
	delete(error_path, paths.allocator)
	return path_is_preserved
}

self_test_bounds_are_correct :: proc() -> bool {
	if input_file_size_status(INPUT_FILE_SIZE_MAX) != .Success { return false }
	if input_file_size_status(INPUT_FILE_SIZE_MAX + 1) != .Input_Too_Large { return false }
	if collected_file_count_status(COLLECTED_FILE_COUNT_MAX) != .Success { return false }
	if collected_file_count_status(COLLECTED_FILE_COUNT_MAX + 1) != .Capacity_Exhausted { return false }
	if directory_entry_count_status(DIRECTORY_ENTRY_COUNT_MAX) != .Success { return false }
	if directory_entry_count_status(DIRECTORY_ENTRY_COUNT_MAX + 1) != .Capacity_Exhausted { return false }
	if violation_count_status(VIOLATION_COUNT_MAX) != .Success { return false }
	return violation_count_status(VIOLATION_COUNT_MAX + 1) == .Capacity_Exhausted
}

run_self_test :: proc() -> Exit_Code {
	temporary_root, temporary_error := os.make_directory_temp("", "tina-hygiene-*", context.allocator)
	if temporary_error != nil {
		fmt.eprintfln("[HYGIENE SELF-TEST FAILED] cannot create temporary tree: %v", temporary_error)
		return .Operational
	}
	defer delete(temporary_root)
	defer os.remove_all(temporary_root)
	canonical_root, canonical_error := os.get_absolute_path(temporary_root, context.allocator)
	if canonical_error != nil {
		fmt.eprintfln("[HYGIENE SELF-TEST FAILED] cannot resolve temporary tree: %v", canonical_error)
		return .Operational
	}
	defer delete(canonical_root)
	if prepare_self_test_tree(canonical_root) != .Success {
		return .Operational
	}
	if !self_test_bounds_are_correct() { return .Violation }
	if !self_test_walker_error_path_is_preserved(canonical_root) {
		fmt.eprintln("[HYGIENE SELF-TEST FAILED] walker error path is not preserved")
		return .Violation
	}
	violations, make_error := make([dynamic]Violation, context.allocator)
	if make_error != nil {
		return report_allocation_error()
	}
	defer delete_violations(&violations)
	if run_gate(canonical_root, &violations) != .Success {
		return .Operational
	}
	sort_violations(violations[:])
	violation_count_expected := 33
	violations_valid := len(violations) == violation_count_expected
	if !self_test_classes_are_complete(violations[:]) {
		violations_valid = false
	}
	if !self_test_violation_paths_are_preserved(violations[:]) {
		violations_valid = false
	}
	if !self_test_ordering_is_stable(violations[:]) {
		violations_valid = false
	}
	if !violations_valid {
		fmt.eprintfln("[HYGIENE SELF-TEST FAILED] expected %d violations, found %d", violation_count_expected, len(violations))
		for violation in violations {
			fmt.eprintfln("%s:%d:%s", violation.path_relative, violation.line_number, VIOLATION_MESSAGES[violation.kind])
		}
		return .Violation
	}
	fmt.println("[HYGIENE SELF-TEST OK]")
	return .Success
}

repository_root :: proc() -> (root_path: string, status: Root_Status) {
	environment_buffer: [4096]byte
	if configured_root, environment_error := os.lookup_env(environment_buffer[:], "HYGIENE_ROOT"); environment_error == nil {
		absolute_error: os.Error
		root_path, absolute_error = os.get_absolute_path(configured_root, context.allocator)
		if absolute_error != nil { return "", .Resolution_Failure }
		return root_path, .Success
	}
	working_directory_error: os.Error
	root_path, working_directory_error = os.get_working_directory(context.allocator)
	if working_directory_error != nil { return "", .Resolution_Failure }
	return root_path, .Success
}
