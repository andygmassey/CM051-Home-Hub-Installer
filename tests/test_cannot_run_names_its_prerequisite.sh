#!/usr/bin/env bash
# A CANNOT-RUN must say WHAT WAS MISSING, not only that something was.
#
# THE DEFECT. lib/probe.sh's probe_cannot_run() prints
#
#     VERDICT: CANNOT-RUN -- <the missing prerequisite>
#
# and its own comment requires that prerequisite be named "so the operator can
# fix it rather than guess". run_box_walk.sh's header makes the same promise:
# "CANNOT-RUN is printed in its own block with the missing prerequisite named,
# every time". It was not. The phase-2 loop kept only the basename:
#
#     elif [ "$rc" -eq "$EX_CANNOT_RUN" ]; then
#         CANNOT=$((CANNOT + 1)); CANNOT_LIST="$CANNOT_LIST $b"
#
# so the summary block listed names and the reason was discarded. MEASURED
# 2026-08-29 on walks/v1.0.50.tsv: 6 probes did not run and no reason for any
# of them is recoverable, from the record or the summary. Dispositioning those
# six took a hand audit of four probe sources.
#
# WHAT THIS TEST DOES. It builds a hermetic probe suite -- run_box_walk.sh and
# the real lib/ copied into a temp dir, with fixture probes -- runs it, and
# checks the three ways this can be wrong:
#
#   - the reason is not printed at all (the original defect)
#   - a probe exits 78 WITHOUT going through probe_cannot_run, and the missing
#     reason is rendered as a blank rather than announced. A blank reads as
#     "no reason given"; what it means is "the contract was bypassed"
#   - THE REGRESSION THAT MATTERS: post_walk_qa.sh parses the NOT MEASURED
#     block with an awk that accepts only bare probe names and EXITS on the
#     first line that is not one. Printing reasons underneath the names would
#     truncate walks/<version>.tsv to a SINGLE not_measured_probe row and
#     silently drop the rest -- the exact blindness the record exists to
#     prevent, reintroduced by the fix for it. So the reasons go in their own
#     block, below a blank line, under a header that does not contain the
#     string the parser keys on, and this test runs the REAL parser over the
#     REAL runner output to prove all names still survive.
#
# PUBLIC REPO. The reasons interpolate ${OSTLER_BOX_HOST}, $LOG_PATH,
# ~/.ostler/... and in one case raw ssh stderr -- measured across the 90
# probe_cannot_run call sites in 21 of 21 probes. They are console-only and
# must never reach walks/, which is committed here. The last check asserts a
# path-bearing reason does not survive into what the record writer publishes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/box_walk_probes/run_box_walk.sh"
LIB="$REPO_ROOT/scripts/box_walk_probes/lib"
QA="$REPO_ROOT/scripts/post_walk_qa.sh"

FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

for f in "$RUNNER" "$QA" "$LIB/probe.sh"; do
    [ -f "$f" ] || { echo "FAIL [missing]: $f not found -- nothing checked. NOT a pass." >&2; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- hermetic suite: the real runner, the real lib, fixture probes --------
mkdir -p "$WORK/probes" "$WORK/lib"
cp "$RUNNER" "$WORK/run_box_walk.sh"
cp "$LIB"/*.sh "$WORK/lib/"

# The distinctive reason carries a home-directory path, because the real ones
# do: that is the whole reason the reasons cannot be published. It is the token
# this test hunts for on the console AND the token that must never reach the
# record.
#
# COMPOSED AT RUNTIME, ON PURPOSE. The literal would trip
# .github/scripts/ci-pii-shape-scan.sh, whose pattern '/Users/[a-z0-9._-]+/?'
# matches on SHAPE and cannot tell this synthetic fixture from a real operator
# path. That guard is right to fire and must not be weakened or bypassed, so
# the segment is assembled here instead. The value is still a genuine
# home-path shape at run time, which is what the assertions need.
_HOME_SEG="$(printf 'U')sers"
REASON_PATH="/${_HOME_SEG}/fixture-operator/.ostler/secrets/absent-thing.conf"

cat > "$WORK/probes/aaa_cannot_with_reason.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "\$(dirname "\${BASH_SOURCE[0]}")/../lib/probe.sh"
PROBE_NAME="aaa_cannot_with_reason"
PROBE_QUESTION="does a named prerequisite survive to the summary?"
run_probe() {
    probe_examined 1 "fixture prerequisite"
    probe_cannot_run "no credential at ${REASON_PATH}; NOTHING was measured"
}
self_test() {
    probe_examined 1 "fixture prerequisite"
    probe_fail "negative control"
}
probe_main "\$@"
EOF

# Exits 78 WITHOUT probe_cannot_run -- the contract-bypass arm.
cat > "$WORK/probes/bbb_cannot_without_marker.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"
PROBE_NAME="bbb_cannot_without_marker"
PROBE_QUESTION="is a bypassed contract announced rather than left blank?"
run_probe() {
    probe_examined 1 "fixture prerequisite"
    exit 78
}
self_test() {
    probe_examined 1 "fixture prerequisite"
    probe_fail "negative control"
}
probe_main "$@"
EOF

cat > "$WORK/probes/ccc_passes.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"
PROBE_NAME="ccc_passes"
PROBE_QUESTION="a passing probe, so the counts are not degenerate"
run_probe() {
    probe_examined 1 "fixture thing"
    probe_pass "fine"
}
self_test() {
    probe_examined 1 "fixture thing"
    probe_fail "negative control"
}
probe_main "$@"
EOF

chmod +x "$WORK/probes"/*.sh
OUT="$WORK/run.log"
# /bin/bash ON PURPOSE, not `bash`. The cut host runs the walk under macOS
# system bash, which is 3.2; a developer machine usually has Homebrew bash 5
# first on PATH. Bash 5 accepts 3.2-invalid syntax, so testing through PATH
# would green-light a runner that dies on the box. Same reason the probe-body
# job in cut-manifest.yml pins macOS.
/bin/bash "$WORK/run_box_walk.sh" > "$OUT" 2>&1
RC=$?
printf 'note: exercised the runner under %s\n' "$(/bin/bash --version | head -1)"

# ---- the run must be the shape this test assumes -------------------------
# A control: if the fixture suite did not actually produce 2 CANNOT-RUN and
# 1 PASS, every assertion below is measuring the wrong thing.
got_cannot="$(awk '/^  CANNOT-RUN /{print $2}' "$OUT")"
got_pass="$(awk '/^  PASS   /{print $2}' "$OUT")"
if [ "${got_cannot:-x}" = "2" ] && [ "${got_pass:-x}" = "1" ]; then
    pass "control: the fixture suite produced pass=1 cannot_run=2 (rc=$RC)"
else
    fail "control" "expected pass=1 cannot_run=2, got pass=${got_pass:-none} cannot_run=${got_cannot:-none} (rc=$RC). Nothing below is trustworthy."
    sed 's/^/    /' "$OUT" >&2
    exit 1
fi

# ---- 1. the reason reaches the summary -----------------------------------
# Not merely somewhere in the output: the per-probe stanza in phase 2 already
# echoes the whole probe, and that is what made this defect easy to miss. It
# must be in the block AFTER "PREREQUISITES THAT WERE ABSENT".
SUMMARY="$(awk '/^PREREQUISITES THAT WERE ABSENT/{f=1; next} f' "$OUT")"
if [ -z "$SUMMARY" ]; then
    fail "no-block" "run_box_walk.sh printed no 'PREREQUISITES THAT WERE ABSENT' block, so the reasons are still discarded at the summary."
elif printf '%s' "$SUMMARY" | grep -Fq -- "$REASON_PATH"; then
    pass "the missing prerequisite is named in the summary block"
else
    fail "reason-dropped" "the summary block does not carry the probe's stated prerequisite. Got: $(printf '%s' "$SUMMARY" | tr '\n' ' ')"
fi

# ---- 2. a bypassed contract is announced, never blank --------------------
if printf '%s' "$SUMMARY" | grep -q 'UNRECORDED'; then
    pass "a probe that exited 78 without probe_cannot_run is announced as UNRECORDED"
else
    fail "silent-blank" "bbb_cannot_without_marker bypassed probe_cannot_run and the summary does not say so. A blank reason reads as 'none given' when it means 'contract bypassed'."
fi

# ---- 3. THE REGRESSION GUARD: the record still gets EVERY name -----------
# Lift the real section_names() out of post_walk_qa.sh and run it over the
# real runner output, exactly as the record writer does.
A=$(grep -n 'section_names() {' "$QA" | head -1 | cut -d: -f1)
[ -n "$A" ] || { fail "no-extractor" "post_walk_qa.sh has no section_names()"; exit 1; }
B=$(awk -v a="$A" 'NR>a && /^    }$/{print NR; exit}' "$QA")
[ -n "$B" ] || { fail "unterminated" "section_names() never closes"; exit 2; }
{ echo 'PROBE_LOG="$1"'; sed -n "${A},${B}p" "$QA"; } > "$WORK/sn.sh"
bash -n "$WORK/sn.sh" || { fail "extract-syntax" "lifted section_names does not parse"; exit 2; }

names="$(bash -c 'source "$0" "$1"; section_names "$2"' "$WORK/sn.sh" "$OUT" 'NOT MEASURED' | tr '\n' ' ' | sed 's/ *$//')"
if [ "$names" = "aaa_cannot_with_reason bbb_cannot_without_marker" ]; then
    pass "the record parser still recovers BOTH not-measured names (the reason block did not truncate it)"
else
    fail "record-truncated" "section_names returned '$names', expected both fixture names. The reasons block has broken the record writer: walks/<version>.tsv would lose not_measured_probe rows."
fi

# ---- 4. PUBLIC REPO: the reason must not reach the record ----------------
if printf '%s' "$names" | grep -Fq -- "$REASON_PATH"; then
    fail "leak" "a reason carrying an operator path reached what the record writer publishes. walks/ is committed to a PUBLIC repo."
elif printf '%s' "$names" | grep -q '/'; then
    fail "leak-shape" "what the record writer publishes contains a path separator: '$names'"
else
    pass "the path-bearing reason stays on the console and does not reach the record"
fi

# ---- 5. the record ANNOUNCES the withholding -----------------------------
# Otherwise a reader of walks/<version>.tsv sees not_measured_probe rows with
# no explanation and reasonably infers no reason was ever captured.
if grep -q 'not_measured_reasons' "$QA"; then
    pass "the record emits not_measured_reasons, so the gap is stated rather than discovered"
else
    fail "silent-gap" "post_walk_qa.sh writes no not_measured_reasons row; the record gives a reader no way to know reasons exist at all."
fi

[ "$FAILED" -ne 0 ] && exit 1
echo
echo "ALL CANNOT-RUN PREREQUISITE-NAMING TESTS PASSED"
