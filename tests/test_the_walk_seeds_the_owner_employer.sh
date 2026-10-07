#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_owner_employer.sh
# ============================================================================
# owner_digest_knows_the_owner (v1.0.107 #10) asks the chat "Where have I
# worked?" and needs a known answer. lib/owner_employer_seed.sh supplies one
# through the customer's own import path: a synthetic LinkedIn Positions.csv
# handed to ~/.ostler/bin/ostler-import. This test pins:
#
#   1. IT IS WIRED. The runner sources the lib, calls the apply FLUSH LEFT
#      inside the READ_ONLY gate above phase 2, and calls the forget below it.
#   2. THE FIXTURE IS ONE THE SHIPPED PARSER READS AS A POSITION AT THE SEED
#      ORGANISATION. Parsed by the vendored linkedin_career.parse_positions_csv,
#      not by a regex of ours.
#   3. SEEDED IS EARNED. A stub box whose importer succeeds and whose
#      context-refresh rewrites CONTEXT.md reports seeded. MUST-FAIL arms: an
#      importer that exits non-zero, and a refresh that never rewrites the
#      digest, each report failed.
#
# macOS only: the seed runs on the Hub, and uses BSD stat. Exit 2 elsewhere,
# because a check that could not run has not passed.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/owner_employer_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
VENDOR="$REPO/vendor/cm041/contact_syncer/linkedin_career.py"

[ "$(uname -s)" = "Darwin" ] || { echo "CANNOT-RUN: needs macOS (BSD stat, as on the Hub)"; exit 2; }
[ -f "$LIB" ] && [ -f "$RUNNER" ] && [ -f "$VENDOR" ] || { echo "CANNOT-RUN: a subject file is missing"; exit 2; }

PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); else printf '  [FAIL] %s %s\n' "$1" "${3:-}"; FAIL=$((FAIL+1)); fi; }
b() { "$@" && echo 0 || echo 1; }

echo "1. wiring"
arm "the runner sources the lib" "$(b grep -q '^\. "\$HERE/lib/owner_employer_seed.sh"' "$RUNNER")"
apply_line=$(grep -n '^owner_employer_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)
forget_line=$(grep -n '^owner_employer_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)
phase2_line=$(grep -n "^printf -- '--- PHASE 2" "$RUNNER" | head -1 | cut -d: -f1)
arm "the apply is called flush left, above phase 2" "$(b [ -n "$apply_line" ] && [ -n "$phase2_line" ] && [ "$apply_line" -lt "$phase2_line" ])" "apply=$apply_line phase2=$phase2_line"
arm "the forget is called below phase 2" "$(b [ -n "$forget_line" ] && [ "$forget_line" -gt "$phase2_line" ])" "forget=$forget_line"
gate=$(awk -v n="$apply_line" 'NR<n && /READ_ONLY/ {l=$0} END{print l}' "$RUNNER")
case "$gate" in *'if [ "$READ_ONLY" -eq 0 ]'*) g=0 ;; *) g=1 ;; esac
arm "the apply sits inside the READ_ONLY gate" "$g" "nearest gate: $gate"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkbox() { # $1 = importer rc, $2 = 1 if refresh rewrites the digest
    local h="$T/box-$1-$2"; mkdir -p "$h/.ostler/bin" "$h/.ostler/assistant-config/workspace" "$h/stub"
    printf '#!/bin/sh\necho import "$@" >> "%s/import.calls"\nexit %s\n' "$h" "$1" > "$h/.ostler/bin/ostler-import"
    chmod +x "$h/.ostler/bin/ostler-import"
    echo "## old" > "$h/.ostler/assistant-config/workspace/CONTEXT.md"
    touch -t 202001010000 "$h/.ostler/assistant-config/workspace/CONTEXT.md"
    if [ "$2" -eq 1 ]; then
        printf '#!/bin/sh\ntouch "%s/.ostler/assistant-config/workspace/CONTEXT.md"\n' "$h" > "$h/stub/launchctl"
    else
        printf '#!/bin/sh\nexit 0\n' > "$h/stub/launchctl"
    fi
    printf '#!/bin/sh\n:\n' > "$h/stub/sleep"
    chmod +x "$h/stub/launchctl" "$h/stub/sleep"
    echo "$h"
}
run_seed() { # $1 = box home; prints the state
    ( export HOME="$1" PATH="$1/stub:$PATH"; unset OSTLER_BOX_HOST
      _oes_box() { bash -c "$1"; }
      . "$LIB"; _oes_box() { bash -c "$1"; }
      owner_employer_seed_apply >/dev/null 2>&1; echo "$OSTLER_OWNER_SEED_STATE" )
}

echo "2. the fixture, read by the shipped parser"
H=$(mkbox 0 1); st=$(run_seed "$H")
CSV="$H/.ostler/walk-seed/owner-linkedin/Basic_LinkedInDataExport/Positions.csv"
arm "the seed wrote Positions.csv" "$(b [ -f "$CSV" ])"
parsed=$(python3 - "$VENDOR" "$CSV" <<'PY'
import ast, csv, sys
src = open(sys.argv[1]).read()
fn = [n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "parse_positions_csv"][0]
ns = {"csv": csv, "List": list, "Dict": dict}
exec(compile(ast.Module(body=[fn], type_ignores=[]), "p", "exec"), ns)
rows = ns["parse_positions_csv"](sys.argv[2])
print("|".join(r.get("Company Name", "") for r in rows))
PY
)
arm "the vendored parser reads exactly one position, at ExampleCo" "$(b [ "$parsed" = "ExampleCo" ])" "got '$parsed'"
arm "the importer was handed the export's parent directory" "$(b grep -q "walk-seed/owner-linkedin\$" "$H/import.calls")"

echo "3. seeded is earned"
arm "importer ok + digest rewritten reads seeded" "$(b [ "$st" = "seeded" ])" "got $st"
st=$(run_seed "$(mkbox 1 1)")
arm "MUST-FAIL: an importer that exits 1 reads failed" "$(b [ "$st" = "failed" ])" "got $st"
st=$(run_seed "$(mkbox 0 0)")
arm "MUST-FAIL: a digest that is never rewritten reads failed" "$(b [ "$st" = "failed" ])" "got $st"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
