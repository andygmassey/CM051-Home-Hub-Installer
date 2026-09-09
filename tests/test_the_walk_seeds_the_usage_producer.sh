#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_usage_producer.sh
# ============================================================================
# grounding_seed.sh puts a PERSON in front of the grounded probe.
# preference_seed.sh puts a PREFERENCE PAIR in front of the interest profile.
# Nothing put WORK in front of usage_journal_producers, so on v1.0.81
# cm051_ostler_fda_ingest was absent from a journal holding 557 parsed rows and
# there was no way to tell "the writer is broken" from "the writer was never
# asked to write". The roster itself says so in its cm051 row: ABSENT means
# "no measured call happened", NOT "the writer is missing".
#
# scripts/box_walk_probes/lib/usage_seed.sh closes that by running the
# installer's own people sweep (install.sh:29420-29424) once, by hand, and
# counting the producer's rows either side of it. This test pins the five
# things that make it worth having:
#
#   1. IT IS WIRED. The runner sources the lib and calls usage_seed_apply
#      ABOVE the phase-2 measurement loop, with the forget step below it. A lib
#      nothing invokes is the "unwired" case the directive names.
#   2. THE ASSUMPTION IS STILL MEASURED FIRST, THOUGH IT HAS NOW BEEN SEEN
#      ONCE. Measured on the walk box as archie, 2026-09-09T17:42:35Z, Ollama
#      0.33.3: prompt_eval_count 5 (int) for the install healthcheck body and
#      15 for a three-item batch. One box on one day is not a property of every
#      box, so the seed re-measures it on every walk instead of citing that. If
#      a runtime does not report a USABLE count, no seed can make any
#      embed-based producer write, and that is a CANNOT-RUN about the runtime
#      rather than a pass or a product FAIL. Present-but-zero is pinned
#      separately, because usage_journal.py:257-264 rejects it and a presence
#      test alone would not.
#   3. THE DELTA IS THE VERDICT, NOT THE EXIT CODE. A positive delta is SEEDED
#      even when the sweep exits non-zero; a zero delta on a status-ok sweep is
#      a named FINDING, which is the one outcome here that is a real finding.
#   4. WHAT WE COULD NOT LOOK AT IS NOT A FAIL. An absent venv, a dead embedder
#      and an explicit skip each print a named CANNOT-RUN, never a bare red.
#   5. THE VECTOR NEVER LEAVES THE BOX. The embed measurement prints the
#      response KEY LIST and nothing else.
#
# THE STUB BOX. OSTLER_BOX_HOST is empty, so the lib's own _us_box_exec runs
# each remote program through /bin/sh on this machine -- the REAL remote
# command text, not a mock of it -- against a fake ~/.ostler, a fake curl on
# PATH and a fake email-ingest interpreter. So the suite runs on a CI runner
# with no box, while still executing the shell the box would execute. What it
# cannot cover is ssh itself, which no test in this estate covers.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/usage_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
PROBE="$REPO/scripts/box_walk_probes/probes/usage_journal_producers.sh"

PASS=0
FAIL=0
arm() { # $1 = label, $2 = condition already evaluated (0/1), $3 = detail on failure
    if [ "$2" -eq 0 ]; then
        printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$1"; printf '%s\n' "$3" | sed 's/^/         /'; FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$LIB" ] || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -f "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }
[ -f "$PROBE" ] || { printf 'CANNOT-RUN: no probe at %s\n' "$PROBE"; exit 78; }
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] || { printf 'CANNOT-RUN: no python3 on PATH\n'; exit 78; }

# A response body carrying a usable count, and one that does not. The float is
# distinctive on purpose: arm 9 asserts it never reaches the operator's screen.
VECTOR_CANARY="0.1234567"
BODY_MEASURED="{\"model\": \"nomic-embed-text\", \"embeddings\": [[${VECTOR_CANARY}]], \"prompt_eval_count\": 3, \"total_duration\": 12345}"
BODY_NO_COUNT="{\"model\": \"nomic-embed-text\", \"embeddings\": [[${VECTOR_CANARY}]], \"total_duration\": 12345}"
BODY_ZERO_COUNT="{\"model\": \"nomic-embed-text\", \"embeddings\": [[${VECTOR_CANARY}]], \"prompt_eval_count\": 0}"

# The fake curl. Writes whatever STUB_EMBED_BODY holds to the -o file and
# prints STUB_EMBED_CODE for -w '%{http_code}', which is the only contract the
# lib has with it.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'SH'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "$out" ]; then
    printf '%s' "${STUB_EMBED_BODY:-}" > "$out"
fi
printf '%s' "${STUB_EMBED_CODE:-200}"
exit "${STUB_CURL_RC:-0}"
SH
chmod +x "$STUB_BIN/curl"

# A fake ~/.ostler whose email-ingest interpreter stands in for the venv
# python install.sh:29372 resolves. It appends STUB_SWEEP_ROWS producer rows to
# the journal and prints STUB_SWEEP_DICT, which is the counts-only dict the
# real sweep prints. It also drops a sentinel, so an arm can assert the sweep
# did NOT run.
make_box() { # $1 = OSTLER_DIR to build
    local root="$1"
    mkdir -p "$root/services/email-ingest/.venv/bin"
    cat > "$root/services/email-ingest/.venv/bin/python" <<'SH'
#!/bin/sh
printf 'ran\n' >> "${STUB_RAN}"
n="${STUB_SWEEP_ROWS:-0}"
i=0
while [ "$i" -lt "$n" ]; do
    printf '{"id": "stub-%s", "session_id": "ostler-fda-ingest-abcdef012345", "usage": {"model": "nomic-embed-text", "input_tokens": 3}}\n' \
        "$i" >> "${STUB_JOURNAL}"
    i=$((i + 1))
done
printf '%s\n' "${STUB_SWEEP_DICT:-}"
exit "${STUB_SWEEP_RC:-0}"
SH
    chmod +x "$root/services/email-ingest/.venv/bin/python"
}

# Source the lib in a child shell, call the step, report what it decided.
# `set -uo pipefail` in the child on purpose: that is what run_box_walk.sh runs
# under, so an unset variable in the lib fails HERE rather than on a box.
run_apply() { # $1 = lib, $2 = box dir, $3 = journal, rest = env assignments
    local lib="$1" box="$2" journal="$3"; shift 3
    env -u OSTLER_USAGE_SEED_SKIP \
        OSTLER_BOX_HOST= \
        PATH="$STUB_BIN:$PATH" \
        OSTLER_DIR="$box" \
        OSTLER_USAGE_JOURNAL="$journal" \
        STUB_JOURNAL="$journal" \
        "$@" \
        bash -c '
            set -uo pipefail
            . "$1"
            usage_seed_apply
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${USAGE_SEED_STATE}"
        ' _ "$lib" 2>&1
}

printf 'THE WALK SEEDS THE USAGE PRODUCER\n\n'

# ---------------------------------------------------------------------------
printf -- '-- 1. it is wired into the runner, in the right order --\n'
# ---------------------------------------------------------------------------
src_line="$(grep -n 'lib/usage_seed.sh' "$RUNNER" | head -1 | cut -d: -f1)"
apply_line="$(grep -n '^usage_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
forget_line="$(grep -n '^usage_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)"
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$apply_line" ]
arm "the runner sources the lib and calls usage_seed_apply" $? \
    "source line='$src_line' apply line='$apply_line'"

[ -n "$loop_line" ] && [ -n "$apply_line" ] && [ "$apply_line" -lt "$loop_line" ]
arm "the sweep runs BEFORE the phase-2 probe loop (a sweep after it seeds nothing)" $? \
    "apply at $apply_line, probe loop at $loop_line"

[ -n "$forget_line" ] && [ -n "$loop_line" ] && [ "$forget_line" -gt "$loop_line" ]
arm "the forget step runs AFTER the loop, so it cannot change a verdict" $? \
    "forget at $forget_line, probe loop at $loop_line"

# The three line citations at the top of the runner must survive this wiring.
[ "$(sed -n '42p' "$RUNNER")" = 'PROBE_DIR="$HERE/probes"' ] \
    && [ "$(sed -n '44p' "$RUNNER")" = 'EX_CANNOT_RUN=78' ] \
    && [ "$(sed -n '83p' "$RUNNER")" = 'for f in "$PROBE_DIR"/*.sh; do' ]
arm "the runner's three cited lines (:42 :44 :83) still say what is cited" $? \
    "42=[$(sed -n '42p' "$RUNNER")] 44=[$(sed -n '44p' "$RUNNER")] 83=[$(sed -n '83p' "$RUNNER")]"

# ONE RESOLVER, NOT TWO. The lib must ask the probe where the journal is, or a
# seed could count rows in a file the probe never reads and report SEEDED while
# the probe still saw nothing.
grep -q -- '--print-journal-path' "$LIB" && grep -q -- '--print-journal-path' "$PROBE"
arm "the journal path is resolved by the PROBE's own resolver, not a copy of it" $? \
    "the lib must invoke the probe with --print-journal-path"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. a positive delta is SEEDED, and says the sweep was run by hand --\n'
# ---------------------------------------------------------------------------
BOX2="$WORK/box2"; make_box "$BOX2"
J2="$WORK/journal2.jsonl"; : > "$J2"
R2="$WORK/ran2"
out2="$(run_apply "$LIB" "$BOX2" "$J2" STUB_RAN="$R2" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=2 STUB_SWEEP_DICT='{"status": "ok", "sent": 5, "points_created": 5, "total": 5}')"
grep -q 'RC=0' <<< "$out2" && grep -q 'STATE=seeded' <<< "$out2"
arm "two new producer rows is SEEDED AND MEASURED" $? "$out2"

grep -q 'delta  : 2 row' <<< "$out2"
arm "and the delta is printed as a number, with the before and after either side" $? "$out2"

grep -q 'before : 0 row' <<< "$out2" && grep -q 'after  : 2 row' <<< "$out2"
arm "the before and after counts are both printed" $? "$out2"

grep -q 'RE-RUNS THE PRODUCT OWN PEOPLE SWEEP BY HAND' <<< "$out2"
arm "a pass says IN WORDS that this is the golden case the roster warns of" $? "$out2"

[ -f "$R2" ]
arm "the sweep actually ran" $? "no sentinel at $R2"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. the exit code is not the verdict; the delta is --\n'
# ---------------------------------------------------------------------------
BOX3="$WORK/box3"; make_box "$BOX3"
J3="$WORK/journal3.jsonl"; : > "$J3"
R3="$WORK/ran3"
out3="$(run_apply "$LIB" "$BOX3" "$J3" STUB_RAN="$R3" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=1 STUB_SWEEP_RC=1 \
    STUB_SWEEP_DICT='{"status": "ok", "sent": 1, "points_created": 1, "total": 1}')"
grep -q 'STATE=seeded' <<< "$out3"
arm "a sweep that exited 1 but WROTE a row is still SEEDED (install.sh guards that rc)" $? "$out3"

grep -q 'sweep  : exit 1' <<< "$out3"
arm "and the exit code is reported anyway, so it can be argued with" $? "$out3"

# ---------------------------------------------------------------------------
printf -- '\n-- 4. delta 0 on a status-ok sweep is a named FINDING --\n'
# ---------------------------------------------------------------------------
BOX4="$WORK/box4"; make_box "$BOX4"
J4="$WORK/journal4.jsonl"; : > "$J4"
R4="$WORK/ran4"
out4="$(run_apply "$LIB" "$BOX4" "$J4" STUB_RAN="$R4" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=0 STUB_SWEEP_DICT='{"status": "ok", "sent": 7, "points_created": 7, "total": 7}')"
grep -q 'STATE=finding' <<< "$out4" && grep -q 'FINDING: THE SWEEP RAN AND THE PRODUCER DID NOT WRITE' <<< "$out4"
arm "the sweep ran, wrote nothing, and that is a FINDING in those words" $? "$out4"

grep -q 'RC=1' <<< "$out4"
arm "and it returns 1, so the walk never scores it a pass" $? "$out4"

# A zero delta with NOTHING TO EMBED is a different answer entirely. If these
# two collapsed, an empty graph would be reported as a broken producer.
BOX4b="$WORK/box4b"; make_box "$BOX4b"
J4b="$WORK/journal4b.jsonl"; : > "$J4b"
R4b="$WORK/ran4b"
out4b="$(run_apply "$LIB" "$BOX4b" "$J4b" STUB_RAN="$R4b" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=0 STUB_SWEEP_DICT='{"status": "no_data", "sent": 0, "points_created": 0, "total": 0}')"
grep -q 'STATE=cannot-run' <<< "$out4b" && grep -q 'CANNOT-RUN' <<< "$out4b"
arm "the same zero delta with no people to embed is CANNOT-RUN, not a FINDING" $? "$out4b"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. the unmeasured assumption is measured FIRST --\n'
# ---------------------------------------------------------------------------
BOX5="$WORK/box5"; make_box "$BOX5"
J5="$WORK/journal5.jsonl"; : > "$J5"
R5="$WORK/ran5"
out5="$(run_apply "$LIB" "$BOX5" "$J5" STUB_RAN="$R5" \
    STUB_EMBED_BODY="$BODY_NO_COUNT" \
    STUB_SWEEP_ROWS=3 STUB_SWEEP_DICT='{"status": "ok", "sent": 3, "points_created": 3, "total": 3}')"
grep -q 'STATE=no-counts' <<< "$out5" && grep -q 'CANNOT-RUN' <<< "$out5"
arm "no prompt_eval_count is a named CANNOT-RUN, never a pass" $? "$out5"

grep -q 'RC=1' <<< "$out5"
arm "and it returns 1" $? "$out5"

[ ! -f "$R5" ]
arm "nothing is swept on a runtime that cannot report a count" $? "the sweep ran anyway"

grep -q 'KEYS ' <<< "$out5"
arm "the response KEY LIST is printed, so the claim can be checked" $? "$out5"

# PRESENT IS NOT USABLE. usage_journal.py:257-264 rejects a non-positive count,
# so a presence-only test would wave this through and report SEEDED on a box
# where no row can ever be written.
BOX5b="$WORK/box5b"; make_box "$BOX5b"
J5b="$WORK/journal5b.jsonl"; : > "$J5b"
R5b="$WORK/ran5b"
out5b="$(run_apply "$LIB" "$BOX5b" "$J5b" STUB_RAN="$R5b" \
    STUB_EMBED_BODY="$BODY_ZERO_COUNT" \
    STUB_SWEEP_ROWS=3 STUB_SWEEP_DICT='{"status": "ok", "sent": 3, "points_created": 3, "total": 3}')"
grep -q 'STATE=no-counts' <<< "$out5b"
arm "prompt_eval_count present but ZERO is also CANNOT-RUN (present is not usable)" $? "$out5b"
[ ! -f "$R5b" ]
arm "and nothing is swept on that box either" $? "the sweep ran anyway"

# A dead embedder and a runtime that answers without counts are different
# facts. Reading them as one would report "this runtime cannot measure" about
# a box nobody asked.
BOX5c="$WORK/box5c"; make_box "$BOX5c"
J5c="$WORK/journal5c.jsonl"; : > "$J5c"
R5c="$WORK/ran5c"
out5c="$(run_apply "$LIB" "$BOX5c" "$J5c" STUB_RAN="$R5c" \
    STUB_EMBED_BODY="" STUB_CURL_RC=7 \
    STUB_SWEEP_ROWS=3 STUB_SWEEP_DICT='{"status": "ok", "sent": 3, "points_created": 3, "total": 3}')"
grep -q 'STATE=cannot-run' <<< "$out5c" && grep -q 'curl exit' <<< "$out5c"
arm "a request that never completed is CANNOT-RUN naming the curl exit, not no-counts" $? "$out5c"

BOX5d="$WORK/box5d"; make_box "$BOX5d"
J5d="$WORK/journal5d.jsonl"; : > "$J5d"
R5d="$WORK/ran5d"
out5d="$(run_apply "$LIB" "$BOX5d" "$J5d" STUB_RAN="$R5d" \
    STUB_EMBED_BODY='{"error": "model not found"}' STUB_EMBED_CODE=500 \
    STUB_SWEEP_ROWS=3 STUB_SWEEP_DICT='{"status": "ok", "sent": 3, "points_created": 3, "total": 3}')"
grep -q 'STATE=cannot-run' <<< "$out5d" && grep -q 'HTTP 500' <<< "$out5d"
arm "HTTP 500 from the embedder is CANNOT-RUN naming the code" $? "$out5d"
[ ! -f "$R5d" ]
arm "and no sweep is run against a dead embedder" $? "the sweep ran anyway"

# ---------------------------------------------------------------------------
printf -- '\n-- 6. the sweep could not run at all --\n'
# ---------------------------------------------------------------------------
BOX6="$WORK/box6"; make_box "$BOX6"
rm -f "$BOX6/services/email-ingest/.venv/bin/python"
J6="$WORK/journal6.jsonl"; : > "$J6"
R6="$WORK/ran6"
out6="$(run_apply "$LIB" "$BOX6" "$J6" STUB_RAN="$R6" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=2 STUB_SWEEP_DICT='{"status": "ok", "sent": 2, "points_created": 2, "total": 2}')"
grep -q 'STATE=cannot-run' <<< "$out6" && grep -q 'USEED-NO-VENV' <<< "$out6"
arm "an absent email-ingest interpreter is CANNOT-RUN, not a product FAIL" $? "$out6"

grep -q 'install.sh:29376' <<< "$out6"
arm "and it names the install's own test for the same condition" $? "$out6"

# The module missing inside a venv that DOES exist: the interpreter runs and
# prints no dict. That is not a delta of zero, it is no measurement at all.
BOX6b="$WORK/box6b"; make_box "$BOX6b"
J6b="$WORK/journal6b.jsonl"; : > "$J6b"
R6b="$WORK/ran6b"
out6b="$(run_apply "$LIB" "$BOX6b" "$J6b" STUB_RAN="$R6b" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=0 STUB_SWEEP_RC=1 STUB_SWEEP_DICT='ModuleNotFoundError: ostler_fda')"
grep -q 'STATE=cannot-run' <<< "$out6b" && grep -q 'no counts-only dict' <<< "$out6b"
arm "a sweep that printed no dict is CANNOT-RUN, not a zero delta" $? "$out6b"

# A CHECKOUT PROBLEM MUST NOT READ AS A BOX PROBLEM. With the probe absent
# there is no resolver to ask, and that is a different sentence from "the
# resolver answered with nothing".
NOPROBE="$WORK/noprobe"
cp -R "$REPO/scripts/box_walk_probes" "$NOPROBE"
rm -rf "$NOPROBE/probes"
BOX6c="$WORK/box6c"; make_box "$BOX6c"
J6c="$WORK/journal6c.jsonl"; : > "$J6c"
R6c="$WORK/ran6c"
out6c="$(run_apply "$NOPROBE/lib/usage_seed.sh" "$BOX6c" "$J6c" STUB_RAN="$R6c" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=2 STUB_SWEEP_DICT='{"status": "ok", "sent": 2, "points_created": 2, "total": 2}')"
grep -q 'STATE=cannot-run' <<< "$out6c" && grep -q 'checkout problem' <<< "$out6c"
arm "an absent probe is CANNOT-RUN naming the CHECKOUT, not the box" $? "$out6c"
[ ! -f "$R6c" ]
arm "and nothing is swept when the journal cannot even be named" $? "the sweep ran anyway"

# ---------------------------------------------------------------------------
printf -- '\n-- 7. skipping, and forgetting --\n'
# ---------------------------------------------------------------------------
BOX7="$WORK/box7"; make_box "$BOX7"
J7="$WORK/journal7.jsonl"; : > "$J7"
R7="$WORK/ran7"
out7="$(run_apply "$LIB" "$BOX7" "$J7" STUB_RAN="$R7" \
    STUB_EMBED_BODY="$BODY_MEASURED" OSTLER_USAGE_SEED_SKIP=1 \
    STUB_SWEEP_ROWS=2 STUB_SWEEP_DICT='{"status": "ok", "sent": 2, "points_created": 2, "total": 2}')"
grep -q 'STATE=skipped' <<< "$out7" && grep -q 'not a pass' <<< "$out7"
arm "OSTLER_USAGE_SEED_SKIP=1 sweeps nothing and says it is not a pass" $? "$out7"
[ ! -f "$R7" ]
arm "and it really does not sweep" $? "the sweep ran anyway"

# EVERY return-1 path names which of the two it was. A bare red leaves the
# reader to infer it, and that inference is what the three-outcome discipline
# exists to remove.
missing=""
for o in "$out4" "$out4b" "$out5" "$out5b" "$out5c" "$out5d" "$out6" "$out6b" "$out6c" "$out7"; do
    if ! grep -qE '^  (CANNOT-RUN|FINDING)' <<< "$o"; then
        missing="${missing}
$(printf '%s' "$o" | head -3)"
    fi
done
[ -z "$missing" ]
arm "every return-1 path prints a line beginning CANNOT-RUN or FINDING" $? "$missing"

# The forget step removes nothing, and says so rather than staying silent.
outf="$(env OSTLER_BOX_HOST= bash -c '
    set -uo pipefail
    . "$1"
    USAGE_SEED_STATE=seeded
    usage_seed_forget
    printf "FRC=%s\n" "$?"
' _ "$LIB" 2>&1)"
grep -q 'FRC=0' <<< "$outf" && grep -q 'nothing to remove' <<< "$outf"
arm "forget removes nothing, returns 0, and prints why" $? "$outf"

# ---------------------------------------------------------------------------
printf -- '\n-- 8. the vector never leaves the box --\n'
# ---------------------------------------------------------------------------
! grep -q "$VECTOR_CANARY" <<< "$out2$out5$out5b"
arm "no embedding value is printed on any embed path, only the key list" $? \
    "the canary $VECTOR_CANARY reached the operator's screen"

# ---------------------------------------------------------------------------
printf -- '\n-- 9. MUTATION: with the delta check disabled, arm 4 must fail --\n'
# ---------------------------------------------------------------------------
# The delta check is the whole assertion. A future edit that reads the sweep's
# status or its exit code instead would turn this step into a decoration that
# reports SEEDED on every box where the sweep merely ran.
#
# THE MUTANT LIVES IN A MIRROR OF THE REAL TREE, not in a bare temp file. The
# lib finds the probe whose resolver it uses at ../probes/, relative to its own
# BASH_SOURCE, so a mutant sitting loose in $WORK would fail at the journal
# lookup and never reach the delta check at all. A mutation arm that dies
# before the mutated line looks exactly like a mutation the suite caught.
MIRROR="$WORK/mirror"
cp -R "$REPO/scripts/box_walk_probes" "$MIRROR"
MUT="$MIRROR/lib/usage_seed.sh"
sed 's/^    if \[ "${USAGE_SEED_DELTA}" -gt 0 \]; then$/    if true; then/' "$LIB" > "$MUT"
mut_left="$(grep -c -F 'USAGE_SEED_DELTA}" -gt 0' "$MUT" || true)"
[ "$mut_left" = "0" ]
arm "the mutant really has the delta check disabled (the injection landed)" $? \
    "still present: $mut_left line(s)"

BOXM="$WORK/boxm"; make_box "$BOXM"
JM="$WORK/journalm.jsonl"; : > "$JM"
RM="$WORK/ranm"
outm="$(run_apply "$MUT" "$BOXM" "$JM" STUB_RAN="$RM" \
    STUB_EMBED_BODY="$BODY_MEASURED" \
    STUB_SWEEP_ROWS=0 STUB_SWEEP_DICT='{"status": "ok", "sent": 7, "points_created": 7, "total": 7}')"
grep -q 'STATE=seeded' <<< "$outm"
if [ $? -eq 0 ]; then mut_rc=0; else mut_rc=1; fi
arm "MUST-FAIL: the mutant reports SEEDED on a zero delta, so arm 4 is a real assertion" "$mut_rc" \
    "the mutant did not pass a zero delta: $outm"

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
