#!/usr/bin/env bash
# Prove verify_hint_coverage.sh FIRES.
#
# The trap this gate must not fall into is the zero-denominator one: if the
# `progress "..." "<id>"` pattern ever stops matching, a naive gate finds no
# emitted steps, compares an empty list against the copy, and reports full
# coverage. Control 4 pins that: no emitted steps is rc=2, never rc=0.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify_hint_coverage.sh"
PASS=0; FAIL=0; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
rc(){ bash "$GATE" "$1" >"$TMP/o" 2>&1; echo $?; }

mkroot(){
    local d="$1" sh="$2" hint="$3"
    rm -rf "$d"; mkdir -p "$d/gui/OstlerInstaller/Resources"
    printf '%s\n' "$sh"   > "$d/install.sh"
    printf '%s\n' "$hint" > "$d/gui/OstlerInstaller/Resources/HintCopy.json"
}

# ── 1: matched lists are green.
mkroot "$TMP/a" \
'    progress "Doing a thing" "step_one"
    progress "Doing another" "step_two"' \
'{"step_one":{"id":"step_one"},"step_two":{"id":"step_two"}}'
[[ "$(rc "$TMP/a")" == 0 ]] && ok "every emitted step covered -> rc=0" || no "matched tree wrongly failed"

# ── 2: an uncovered step fails AND is named. This is the live defect.
mkroot "$TMP/b" \
'    progress "Doing a thing" "step_one"
    progress "Hydrating your graph from iCloud" "hydrate_graph"' \
'{"step_one":{"id":"step_one"}}'
if [[ "$(rc "$TMP/b")" == 1 ]]; then
    ok "a step with no copy -> rc=1"
    grep -q 'hydrate_graph' "$TMP/o" && ok "  and it NAMES the uncovered step" || no "  did not name the step"
    grep -q '1 of 2' "$TMP/o" && ok "  and it prints the denominator" || no "  no denominator printed"
else
    no "uncovered step NOT caught"
fi

# ── 3: an orphan entry fails, unless it is on the declared allow list.
mkroot "$TMP/c" \
'    progress "Doing a thing" "step_one"' \
'{"step_one":{"id":"step_one"},"step_that_left":{"id":"step_that_left"}}'
[[ "$(rc "$TMP/c")" == 1 ]] && ok "orphan entry -> rc=1" || no "orphan entry NOT caught"

mkroot "$TMP/c2" \
'    progress "Doing a thing" "step_one"' \
'{"step_one":{"id":"step_one"},"health_check":{"id":"health_check"}}'
[[ "$(rc "$TMP/c2")" == 0 ]] && ok "a declared-allowed orphan does not fail" || no "allow list not honoured"

# ── 4: THE ZERO-DENOMINATOR TRAP. No emitted steps must be rc=2, never rc=0.
mkroot "$TMP/d" \
'echo "this install.sh has no progress calls at all"' \
'{"step_one":{"id":"step_one"}}'
if [[ "$(rc "$TMP/d")" == 2 ]]; then
    ok "no emitted steps -> rc=2, NOT a clean pass"
    grep -q 'Refusing to report coverage' "$TMP/o" \
        && ok "  and it says why it refuses" || no "  refusal not explained"
else
    no "empty emitter read as FULL COVERAGE (the zero-denominator trap)"
fi

# ── 5: unparseable copy is rc=2. A blank hint panel on every step is not a pass.
mkroot "$TMP/e" \
'    progress "Doing a thing" "step_one"' \
'{ this is not json'
[[ "$(rc "$TMP/e")" == 2 ]] && ok "unparseable HintCopy.json -> rc=2" || no "bad JSON not caught as cannot-run"

# ── 6: a missing file is rc=2, distinct from both pass and fail.
mkroot "$TMP/f" \
'    progress "Doing a thing" "step_one"' \
'{"step_one":{"id":"step_one"}}'
rm -f "$TMP/f/gui/OstlerInstaller/Resources/HintCopy.json"
[[ "$(rc "$TMP/f")" == 2 ]] && ok "absent HintCopy.json -> rc=2" || no "absent file not rc=2"

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "ALL HINT-COVERAGE CONTROLS PASSED"
