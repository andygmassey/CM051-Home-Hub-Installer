#!/usr/bin/env bash
#
# tests/test_hydrate_sentinel_change_fields.sh
#
# G1a + G1b: the hydrate sentinel record now carries a typed `item_count` and a
# `last_update_at` that is DISTINCT from `recorded_at`.
#
#   recorded_at    -- when this record was WRITTEN (every install / re-run / tick)
#   last_update_at -- when the source's DATA last CHANGED (carried forward when
#                     item_count is unchanged, advanced when it moves)
#
# One timestamp cannot answer both "landed at install?" and "keeps updating?".
# This drives the real recorder functions extracted from install.sh (no full
# install), so the semantics are proven, not asserted.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found (exit 2)" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sentinel-XXXXXX")" || { echo "CANNOT-RUN: mktemp (exit 2)" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# Extract only the functions under test (and their one dependency) rather than
# sourcing install.sh, which has top-level side effects.
extract() {
    local body
    body="$(sed -n "/^$1() {/,/^}/p" "$INSTALL")"
    [[ -n "$body" ]] || { echo "CANNOT-RUN: $1() not found in install.sh -- renamed? (exit 2)" >&2; exit 2; }
    printf '%s\n' "$body"
}

{
    printf '_HYDRATE_SENTINEL_DIR=%q\n' "$TMP/hydrate"
    printf 'mkdir -p "$_HYDRATE_SENTINEL_DIR"\n'
    printf 'gui_step_record_rc() { :; }\n'   # stubbed: the emitter is not driving here
    extract _hydrate_payload_count
    extract _hydrate_compute_change
    extract _hydrate_payload_is_all_zero
    extract _hydrate_sentinel_record
    extract _hydrate_sentinel_record_error
    extract _hydrate_sentinel_record_no_data
    extract _hydrate_sentinel_record_cannot_run
} > "$TMP/funcs.sh"

# shellcheck source=/dev/null
source "$TMP/funcs.sh"
S="$_HYDRATE_SENTINEL_DIR"

pass=0; fail=0
ok()  { printf '  [pass] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
field() { grep -m1 "^$2=" "$S/$1.done" 2>/dev/null | cut -d= -f2-; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: want [$3] got [$2]"; fi; }
neq() { if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1: both [$2]"; fi; }

# 1. first record with data -> typed item_count, status ok, last_update_at set
_hydrate_sentinel_record people "people=5"
eq  "G1b: item_count typed from payload"       "$(field people item_count)" "5"
eq  "status ok"                                "$(field people status)"     "ok"
lua1="$(field people last_update_at)"
if [[ -n "$lua1" ]]; then ok "G1a: last_update_at set on first record"; else bad "last_update_at empty"; fi

# 2. re-record UNCHANGED count a second later -> last_update_at CARRIED,
#    recorded_at NEW: the two timestamps must diverge (that is the whole point).
sleep 1
_hydrate_sentinel_record people "people=5"
eq  "G1a: unchanged count -> last_update_at carried" "$(field people last_update_at)" "$lua1"
neq "G1a: recorded_at advanced while last_update_at did not" "$(field people recorded_at)" "$(field people last_update_at)"

# 3. re-record CHANGED count -> item_count updates AND last_update_at advances
sleep 1
_hydrate_sentinel_record people "people=8"
eq  "changed count -> item_count updates"       "$(field people item_count)" "8"
neq "G1a: changed count -> last_update_at advances" "$(field people last_update_at)" "$lua1"

# 4. no_data -> item_count 0
_hydrate_sentinel_record_no_data browsing "no_export_found"
eq  "no_data -> item_count 0"                   "$(field browsing item_count)" "0"
eq  "no_data status"                            "$(field browsing status)"     "no_data"

# 5. cannot_run -> item_count 0
_hydrate_sentinel_record_cannot_run contacts "pipeline_venv_missing"
eq  "cannot_run -> item_count 0"                "$(field contacts item_count)" "0"

# 6. error carrying a partial count -> item_count reflects it
_hydrate_sentinel_record_error imessage 1 "sent=3"
eq  "error -> item_count from payload"          "$(field imessage item_count)" "3"

# 7. all-zero payload takes the no_data branch with item_count 0 (not a false ok)
_hydrate_sentinel_record whatsapp "sent=0"
eq  "all-zero payload -> no_data"               "$(field whatsapp status)"     "no_data"
eq  "all-zero payload -> item_count 0"          "$(field whatsapp item_count)" "0"

echo
echo "hydrate sentinel change-fields test: ${pass} passed, ${fail} failed."
[[ "$fail" -eq 0 ]] || exit 1
exit 0
