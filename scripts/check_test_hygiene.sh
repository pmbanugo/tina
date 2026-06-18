#!/usr/bin/env bash
set -euo pipefail

# Test Architecture Hygiene Gate
#
# Permanent, fast structural invariant checks for the test subsystem. This is
# intentionally shell/grep based so it can run in CI before any Odin toolchain
# setup and locally on macOS and Linux without extra dependencies.
#
# Rules:
#   1. Simulation tests do not read isolate payload memory after a run.
#   2. State transitions route through approved setters.
#   3. Test Shard fixtures use the builder or an allowlisted hydrate-shard path.
#   4. No package-level mutable diagnostic variables survive.
#   5. No manual isolate free-list mutation in tests except narrow allowlists.
#   6. ASan-active test code uses _tina_owned ownership wrappers on pools.
#   7. Documentation must not teach post-run isolate payload inspection.
#
# Exit code 1 if any violation is found, 0 otherwise.

ROOT="${HYGIENE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${ROOT}/src"
TESTS="${ROOT}/tests"
DOCS="${ROOT}/docs"
README_DST="${SRC}/README_DST.md"

VIOLATIONS_FILE=""

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

init_violations() {
    VIOLATIONS_FILE=$(mktemp)
}

record() {
    # $1 = file, $2 = line, $3 = message
    printf '%s:%s:%s\n' "$1" "$2" "$3" >> "${VIOLATIONS_FILE}"
}

print_violations() {
    sort -t':' -k1,1 -k2,2n "${VIOLATIONS_FILE}"
}

cleanup() {
    if [[ -n "${VIOLATIONS_FILE}" && -f "${VIOLATIONS_FILE}" ]]; then
        rm -f "${VIOLATIONS_FILE}"
    fi
}
trap cleanup EXIT

# Strip a trailing Odin // comment from a line. This is intentionally simple:
# it may mangle a // inside a string literal, but such lines are rare and the
# false negatives are acceptable for a fast hygiene gate.
strip_comment() {
    printf '%s' "$1" | sed 's|//.*||'
}

# Collect Odin source files once, sorted, for deterministic output.
odin_files() {
    find "${SRC}" "${TESTS}" -type f -name '*.odin' -print 2>/dev/null | sort
}

# Collect simulation test files (current location and any future nested ones).
sim_test_files() {
    find "${SRC}" "${TESTS}" -type f \( -name 'simulated_test*.odin' -o -name '*simulated_test*.odin' \) -print 2>/dev/null | sort
}

# Check whether a file carries a file-level allowlist marker.
has_file_allowlist() {
    local file="$1"
    local tag="$2"
    grep -qE "ALLOWLIST_FILE\(${tag}\)" "${file}" 2>/dev/null
}

# Check whether an inline allowlist marker appears on this line or the previous
# line. This lets authors put the comment above or beside the exceptional code.
has_inline_allowlist() {
    local file="$1"
    local lineno="$2"
    local marker="$3"
    local context
    context=$(sed -n "$((lineno - 1)),${lineno}p" "${file}" 2>/dev/null || true)
    printf '%s\n' "${context}" | grep -qF "${marker}"
}

# -------------------------------------------------------------------------
# Rule 1: No direct _get_isolate_ptr in simulation test files.
# -------------------------------------------------------------------------
check_no_direct_get_isolate_ptr() {
    while IFS= read -r match; do
        file=${match%%:*}
        rest=${match#*:}
        lineno=${rest%%:*}
        text=${rest#*:}
        code=$(strip_comment "${text}")
        if ! printf '%s' "${code}" | grep -qE "_get_isolate_ptr"; then
            continue
        fi
        record "${file}" "${lineno}" "simulation test contains direct _get_isolate_ptr call"
    done < <(sim_test_files | xargs grep -Hn "_get_isolate_ptr" 2>/dev/null || true)
}

# -------------------------------------------------------------------------
# Rule 2: Direct `._state =` only inside approved setters.
# -------------------------------------------------------------------------
check_no_direct_state_assignment() {
    while IFS= read -r match; do
        file=${match%%:*}
        rest=${match#*:}
        lineno=${rest%%:*}
        text=${rest#*:}
        code=$(strip_comment "${text}")
        if ! printf '%s' "${code}" | grep -qE "\._state\s*=[^=]"; then
            continue
        fi
        if has_inline_allowlist "${file}" "${lineno}" "ALLOWLIST_STATE_SETTER"; then
            continue
        fi
        record "${file}" "${lineno}" "direct ._state = assignment outside approved setter"
    done < <(odin_files | xargs grep -Hn "\._state\s*=[^=]" 2>/dev/null || true)
}

# -------------------------------------------------------------------------
# Rule 3: Ad-hoc shard lifetime carriers in tests.
#   - new(Shard...) with allocator/whitespace variants
#   - raw allocation of size_of(Shard)
#   - cast from raw memory to ^Shard used as fixture construction
# -------------------------------------------------------------------------
check_no_ad_hoc_shard_carriers() {
    while IFS= read -r match; do
        file=${match%%:*}
        rest=${match#*:}
        lineno=${rest%%:*}
        text=${rest#*:}
        code=$(strip_comment "${text}")

        basename=$(basename "${file}")

        # Production shard thread entry is allowed.
        if [[ "${basename}" == "bootstrap_shard.odin" ]]; then
            continue
        fi

        # Whole-file allowlists for sanctioned production-construction tests.
        if has_file_allowlist "${file}" "hand_rolled_shard_fixture" || \
           has_file_allowlist "${file}" "hydrate_shard_fixture"; then
            continue
        fi

        # Inline allowlists adjacent to the exceptional line.
        if has_inline_allowlist "${file}" "${lineno}" "ALLOWLIST(hand_rolled_shard_fixture)" || \
           has_inline_allowlist "${file}" "${lineno}" "ALLOWLIST(hydrate_shard_fixture)"; then
            continue
        fi

        if printf '%s' "${code}" | grep -qE "new\s*\(\s*Shard(\s*,[^)]*)?\s*\)"; then
            record "${file}" "${lineno}" "ad-hoc new(Shard...) in test without allowlist"
            continue
        fi
        if printf '%s' "${code}" | grep -qE "size_of\s*\(\s*Shard\s*\)"; then
            record "${file}" "${lineno}" "raw size_of(Shard) allocation carrier without allowlist"
            continue
        fi
        if printf '%s' "${code}" | grep -qE "cast\s*\(\s*\^Shard\s*\)"; then
            record "${file}" "${lineno}" "cast to ^Shard from raw memory without allowlist"
            continue
        fi
    done < <(odin_files | xargs grep -HnE "new\s*\(\s*Shard|size_of\s*\(\s*Shard\s*\)|cast\s*\(\s*\^Shard\s*\)" 2>/dev/null || true)
}

# -------------------------------------------------------------------------
# Rule 4: No package-level mutable *_diagnostic_* variables.
# -------------------------------------------------------------------------
check_no_package_level_mutable_diagnostics() {
    while IFS= read -r match; do
        file=${match%%:*}
        rest=${match#*:}
        lineno=${rest%%:*}
        text=${rest#*:}
        code=$(strip_comment "${text}")

        # Filter out type aliases, procedures, constants, and comments.
        if printf '%s' "${code}" | grep -qE "::[[:space:]]*(#[a-z_]+[[:space:]]+)?(proc|struct|enum|union)"; then
            continue
        fi
        record "${file}" "${lineno}" "package-level mutable diagnostic variable"
    done < <(odin_files | xargs grep -HnE "^[[:space:]]*(@\([^)]+\)[[:space:]]+)?[a-z_][a-z_0-9]*diagnostic[a-z_0-9]*[[:space:]]*:" 2>/dev/null || true)
}

# -------------------------------------------------------------------------
# Rule 5: No manual isolate free-list mutation in tests.
# -------------------------------------------------------------------------
check_no_manual_free_list_mutation() {
    while IFS= read -r match; do
        file=${match%%:*}
        rest=${match#*:}
        lineno=${rest%%:*}
        text=${rest#*:}
        code=$(strip_comment "${text}")
        if ! printf '%s' "${code}" | grep -qE "isolate_free_heads\[[^]]+\][[:space:]]*="; then
            continue
        fi

        basename=$(basename "${file}")

        # Fixture builder is the sanctioned owner of free-list manipulation.
        if [[ "${basename}" == "test_shard_builder.odin" ]]; then
            continue
        fi

        # Production files are not tests.
        if [[ "${basename}" == "bootstrap_shard.odin" || \
              "${basename}" == "allocator_arena.odin" || \
              "${basename}" == "isolate_lifecycle.odin" || \
              "${basename}" == "shard.odin" || \
              "${basename}" == "io_reactor.odin" ]]; then
            continue
        fi

        if has_inline_allowlist "${file}" "${lineno}" "ALLOWLIST(free_list_mutation)"; then
            continue
        fi

        record "${file}" "${lineno}" "manual isolate_free_heads mutation in test without allowlist"
    done < <(odin_files | xargs grep -HnE "isolate_free_heads\[[^]]+\][[:space:]]*=" 2>/dev/null || true)
}

# -------------------------------------------------------------------------
# Rule 6: ASan-active paths on framework-owned pools must use _tina_owned wrappers.
# -------------------------------------------------------------------------
check_no_plain_pool_on_owned_paths() {
    local pool_files
    pool_files=$(
        find "${SRC}" "${TESTS}" -type f \( \
            -name 'simulated_test*.odin' -o \
            -name 'test_shard_builder.odin' -o \
            -name 'test_shard_fixture_lifecycle.odin' \
        \) -print 2>/dev/null | sort
    )
    if [[ -z "${pool_files}" ]]; then
        return
    fi

    while IFS= read -r match; do
        file=${match%%:*}
        rest=${match#*:}
        lineno=${rest%%:*}
        text=${rest#*:}
        code=$(strip_comment "${text}")

        # Tina-owned wrappers are the only allowed entry points on these paths.
        if printf '%s' "${code}" | grep -qE "_tina_owned"; then
            continue
        fi
        # Shard-level wrappers are also owned paths.
        if printf '%s' "${code}" | grep -qE "_shard_message_pool_"; then
            continue
        fi

        record "${file}" "${lineno}" "plain pool API used in ASan-active test path (use _tina_owned wrappers)"
    done < <(
        printf '%s\n' "${pool_files}" \
            | xargs grep -HnE "(pool_init|pool_alloc_user|pool_alloc_system|pool_free_unchecked|pool_reset|io_slot_pool_init|io_slot_pool_alloc|io_slot_pool_alloc_unzeroed|io_slot_pool_free)([[:space:]]*\()" 2>/dev/null \
            || true
    )
}

# -------------------------------------------------------------------------
# Rule 7: Documentation must not teach post-run isolate/payload inspection.
# -------------------------------------------------------------------------
check_no_post_run_payload_docs() {
    local doc_targets=("${README_DST}")
    if [[ -d "${DOCS}" ]]; then
        while IFS= read -r doc; do
            doc_targets+=("${doc}")
        done < <(find "${DOCS}" -type f -name "*.md" 2>/dev/null | sort || true)
    fi

    for doc in "${doc_targets[@]}"; do
        if [[ ! -f "${doc}" ]]; then
            continue
        fi
        while IFS= read -r match; do
            file=${match%%:*}
            rest=${match#*:}
            lineno=${rest%%:*}
            record "${file}" "${lineno}" "documentation still teaches post-run isolate/payload inspection"
        done < <(grep -HnE "inspect isolate memory|inspect payload memory|post-run.*inspect.*(isolate|payload)|after simulator_run.*inspect" "${doc}" 2>/dev/null || true)
    done
}

# -------------------------------------------------------------------------
# Self-test mode
# -------------------------------------------------------------------------
run_self_test() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/src" "${tmpdir}/tests" "${tmpdir}/docs"

    cat > "${tmpdir}/src/simulated_test_self.odin" <<'EOF'
package tina

import "core:testing"

// VIOLATION: direct payload read in a simulation test
bad_payload_read :: proc(shard: ^Shard) {
    ptr := _get_isolate_ptr(shard, 0, 0)
    _ = ptr
}

// VIOLATION: direct state assignment outside a setter
bad_state_assign :: proc(shard: ^Shard) {
    shard.metadata[0][0]._state = .Runnable
}

// VIOLATION: ad-hoc Shard allocation variants
bad_new_1 :: proc() { _ = new(Shard) }
bad_new_2 :: proc() { _ = new ( Shard ) }
bad_new_3 :: proc() { _ = new(Shard, context.temp_allocator) }

// ALLOWLIST(hydrate_shard_fixture): sanctioned production construction test
ok_hydrate :: proc() {
    // ALLOWLIST(hydrate_shard_fixture)
    shard := new(Shard)
    _ = shard
}

// VIOLATION: raw size_of(Shard) allocation carrier
bad_size :: proc() {
    mem, _ := mem.alloc(size_of(Shard), align_of(Shard), context.temp_allocator)
    _ = mem
}

// VIOLATION: cast from raw memory to ^Shard
bad_cast :: proc(mem: rawptr) {
    shard := cast(^Shard)mem
    _ = shard
}

// VIOLATION: manual free-list mutation
bad_free_list :: proc(shard: ^Shard) {
    shard.isolate_free_heads[0] = 1
}

// VIOLATION: plain pool API on an owned path
bad_pool :: proc(shard: ^Shard) {
    pool_init(&shard.message_pool, nil, 0)
}
EOF

    cat > "${tmpdir}/src/test_fixture_self.odin" <<'EOF'
package tina

// Package-level mutable diagnostic variable.
bad_diagnostic_counter: u64

foo :: proc() { bad_diagnostic_counter += 1 }
EOF

    cat > "${tmpdir}/docs/bad_guide.md" <<'EOF'
# Bad Guide

After simulator_run returns, the test can inspect isolate memory to verify state.
EOF

    local violations_output
    if ! violations_output=$(HYGIENE_ROOT="${tmpdir}" "${BASH_SOURCE[0]}"); then
        :
    fi

    # One line per violation; the sample file contains 11 distinct offending lines.
    local expected=11
    local actual
    actual=$(printf '%s\n' "${violations_output}" | grep -c '\[HYGIENE FAIL\]' || true)

    # Ensure every expected violation class appears.
    local ok=1
    printf '%s' "${violations_output}" | grep -q "direct _get_isolate_ptr call" || ok=0
    printf '%s' "${violations_output}" | grep -q "direct ._state = assignment" || ok=0
    printf '%s' "${violations_output}" | grep -q "ad-hoc new(Shard...)" || ok=0
    printf '%s' "${violations_output}" | grep -q "raw size_of(Shard)" || ok=0
    printf '%s' "${violations_output}" | grep -q "cast to \\^Shard" || ok=0
    printf '%s' "${violations_output}" | grep -q "manual isolate_free_heads mutation" || ok=0
    printf '%s' "${violations_output}" | grep -q "plain pool API" || ok=0
    printf '%s' "${violations_output}" | grep -q "package-level mutable diagnostic variable" || ok=0
    printf '%s' "${violations_output}" | grep -q "documentation still teaches" || ok=0

    # The allowlisted hydrate-shard line must not be reported.
    local false_positive=0
    if printf '%s' "${violations_output}" | grep -q "simulated_test_self.odin:.*ok_hydrate"; then
        false_positive=1
    fi

    rm -rf "${tmpdir}"

    if [[ "${actual}" -ne "${expected}" || "${ok}" -ne 1 || "${false_positive}" -ne 0 ]]; then
        echo "[HYGIENE SELF-TEST FAILED]"
        echo "Expected ${expected} violations, found ${actual}."
        printf '%s\n' "${violations_output}"
        exit 1
    fi

    echo "[HYGIENE SELF-TEST OK]"
    exit 0
}

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
    run_self_test
fi

init_violations

check_no_direct_get_isolate_ptr
check_no_direct_state_assignment
check_no_ad_hoc_shard_carriers
check_no_package_level_mutable_diagnostics
check_no_manual_free_list_mutation
check_no_plain_pool_on_owned_paths
check_no_post_run_payload_docs

if [[ -s "${VIOLATIONS_FILE}" ]]; then
    print_violations | sed 's/^/[HYGIENE FAIL] /'
    echo ""
    echo "$(wc -l < "${VIOLATIONS_FILE}" | tr -d ' ') test-architecture hygiene violation(s) found."
    exit 1
fi

echo "[HYGIENE OK] Test architecture invariants satisfied."
