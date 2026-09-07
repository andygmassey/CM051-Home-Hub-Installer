#!/bin/bash
# =============================================================================
# SELF-TEST for scripts/verify_prompt_loops_are_bounded.sh
#
# The gate's job is to tell three things apart, and every arm here exists to
# stop one specific way of failing to:
#
#   1. a loop that asks a human and cannot give up          -> COUNT IT
#   2. a loop that waits on a machine, correctly bounded    -> DO NOT COUNT IT
#   3. a tree it could not read at all                      -> CANNOT-RUN, exit 2
#
# 🗿 WHY ARM 3 EXISTS, AND IT IS THE ONE THAT MAKES THE REST MEAN ANYTHING.
#
# The real must-miss control in install.sh -- the two Tailscale wait loops --
# is excluded for THREE independent reasons at once: it does not ask for input,
# it carries a numeric bound, AND it contains a break. So it would keep passing
# even if the "asks for input" half of the predicate were deleted, which makes
# it useless as evidence for that half specifically. A control that can be
# satisfied by a sibling guard is not a control for the guard you are testing.
#
# Arm 3 plants the isolating case that install.sh does not happen to contain:
# a loop that is unbounded AND unguarded AND does not ask for input. Only a
# working `asks` predicate keeps it out of the count.
# =============================================================================
set -uo pipefail

GATE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/verify_prompt_loops_are_bounded.sh"
pass=0; fail=0; cannot=0

# Every fixture starts from the real shape, so the arms test the gate and not a
# toy grammar invented to agree with it.
#
# shellcheck disable=SC2016
# The single quotes are LOAD-BEARING, not an oversight. These are install.sh
# source text to be written to a file and scanned, so "$VALUE" and $(gui_read
# ...) must survive as literal characters. Expanding them here would write
# fixtures containing this test's own empty variables, and every arm would then
# measure a file with no loops in it -- which arm 9 would catch, but as a
# confusing CANNOT-RUN rather than as the mistake it is.
ASKING_UNBOUNDED='
VALUE=""
while [[ -z "$VALUE" ]]; do
    warn "$MSG_SOMETHING"
    VALUE="$(gui_read "$MSG_TITLE" text "" "" "" "field")"
done
'
ASKING_BOUNDED='
VALUE=""
TRIES=0
while [[ -z "$VALUE" && $TRIES -lt 5 ]]; do
    VALUE="$(gui_read "$MSG_TITLE" text "" "" "" "field")"
    TRIES=$((TRIES + 1))
done
'
# Unbounded, unguarded, and asks NOTHING. This is the isolating must-miss.
SILENT_UNBOUNDED='
SETTLED=""
while [[ -z "$SETTLED" ]]; do
    SETTLED="$(cat /some/file 2>/dev/null || true)"
    sleep 1
done
'

mkfix() {   # $1 dir  $2 extra-body  -> writes install.sh + ceiling
    local d="$1"
    mkdir -p "$d/scripts" "$d/tests"
    {
        printf '#!/bin/bash\n'
        # the three real unbounded askers
        printf '%s\n' "$ASKING_UNBOUNDED"
        printf '%s\n' "$ASKING_UNBOUNDED"
        printf '%s\n' "$ASKING_UNBOUNDED"
        # the two real bounded waiters
        printf '%s\n' "$ASKING_BOUNDED"
        printf '%s\n' "$ASKING_BOUNDED"
        [[ -n "${2:-}" ]] && printf '%s\n' "$2"
    } > "$d/install.sh"
    printf '3\n' > "$d/tests/PROMPT_LOOP_UNBOUNDED_CEILING"
}

run() {   # $1 label  $2 wanted-rc  $3 dir  [$4 ceiling-override]
    local label="$1" want="$2" d="$3" out rc
    [[ -n "${4:-}" ]] && printf '%s\n' "$4" > "$d/tests/PROMPT_LOOP_UNBOUNDED_CEILING"
    out="$(REPO_ROOT="$d" bash "$GATE" 2>&1)"; rc=$?
    if [[ "$rc" -eq "$want" ]]; then
        printf '  [PASS] %-52s rc=%s\n' "$label" "$rc"; pass=$((pass+1))
    else
        printf '  [FAIL] %-52s rc=%s wanted %s\n' "$label" "$rc" "$want"; fail=$((fail+1))
        printf '%s\n' "$out" | sed 's/^/         /' | tail -6
    fi
}

echo "== verify_prompt_loops_are_bounded: self-test =="

T="$(mktemp -d "${TMPDIR:-/tmp}/plg.XXXXXX")"

# ARM 1 -- SUBJECT. Three unbounded askers, two bounded waiters, ceiling 3.
mkfix "$T/a1" ""
run "1 baseline: 3 unbounded at ceiling 3" 0 "$T/a1"

# ARM 2 -- MUST-CATCH. A fourth asking loop with no way out.
mkfix "$T/a2" "$ASKING_UNBOUNDED"
run "2 must-catch: a 4th unbounded asker fails" 1 "$T/a2"

# ARM 3 -- THE ISOLATING MUST-MISS (see header). Unbounded, unguarded, silent.
mkfix "$T/a3" "$SILENT_UNBOUNDED"
run "3 must-miss: unbounded but asks nothing is NOT counted" 0 "$T/a3"

# ARM 4 -- a bounded asker is a fix, not a finding.
mkfix "$T/a4" "$ASKING_BOUNDED"
run "4 must-miss: a bounded asker is not counted" 0 "$T/a4"

# ARM 5 -- the ratchet's other direction. 3 actual against a ceiling of 4 is a
# FAILURE, because unclaimed headroom is headroom a regression can use.
mkfix "$T/a5" ""
run "5 ratchet: backlog below the ceiling fails" 1 "$T/a5" "4"

# ARM 6 -- CANNOT-RUN, not a pass: no ceiling file.
mkfix "$T/a6" ""; rm -f "$T/a6/tests/PROMPT_LOOP_UNBOUNDED_CEILING"
run "6 cannot-run: ceiling file absent -> exit 2" 2 "$T/a6"

# ARM 7 -- CANNOT-RUN, not a pass: no subject.
mkfix "$T/a7" ""; rm -f "$T/a7/install.sh"
run "7 cannot-run: subject absent -> exit 2" 2 "$T/a7"

# ARM 8 -- CANNOT-RUN, not a pass: a ceiling that is not a number.
mkfix "$T/a8" ""; printf 'three\n' > "$T/a8/tests/PROMPT_LOOP_UNBOUNDED_CEILING"
run "8 cannot-run: non-integer ceiling -> exit 2" 2 "$T/a8"

# ARM 9 -- VACUITY CONTROL. A subject with none of the shape must report
# CANNOT-RUN. "Found nothing" and "could not look" print identically, and this
# is the arm that keeps a silently-broken regex from reading as a clean sheet.
mkdir -p "$T/a9/tests"; printf '#!/bin/bash\necho hello\n' > "$T/a9/install.sh"
printf '3\n' > "$T/a9/tests/PROMPT_LOOP_UNBOUNDED_CEILING"
run "9 vacuity: zero matches is CANNOT-RUN, not PASS" 2 "$T/a9"

rm -rf -- "$T"
echo
printf 'pass=%d fail=%d cannot-run=%d\n' "$pass" "$fail" "$cannot"
[[ "$fail" -eq 0 ]] || exit 1
