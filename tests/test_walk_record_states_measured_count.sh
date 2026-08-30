#!/usr/bin/env bash
# The walk record must state HOW MANY PROBES MEASURED, not only how they were bucketed.
#
# THE DEFECT. run_box_walk.sh:201-204 skips a probe that failed phase 1:
#
#     case " $BROKEN_LIST " in
#         *" $b "*)
#             printf '\n[%s]\n  SKIPPED -- probe failed its own negative control in phase 1.\n' "$b"
#             continue
#
# `continue` lands before every counter, so a broken probe is counted in
# `broken` and in nothing else. That is exactly why the four counts partition
# the suite -- and exactly why their SUM cannot tell you whether anything was
# measured. pass+fail+cannot_run+broken reaches the probe count either way.
#
# MEASURED on walks/v1.0.50.tsv: 7+7+6+1 = 21 = the probe count, as cleanly as
# if all 21 had run. Twenty had. `no_store_port_is_tcp_reachable` was BROKEN,
# phase 2 stepped over it, and that walk took NO store-port measurement at all
# -- the probe guarding the store exposure closed as #551. A closed security
# finding whose guard never executed.
#
# So the reconciliation is a good COMPLETENESS check and a bad COVERAGE check.
# The number that carries coverage is pass+fail+cannot_run, and the record now
# states it instead of leaving a reader to derive it. Credit: TNM 2026-08-30,
# sharpening my own use of the same sum.
#
# WHAT THIS TEST DOES. It lifts the REAL denominator parser out of
# post_walk_qa.sh -- never a reimplementation, or it would be testing a copy --
# and checks the three ways this rots:
#
#   - the parser is fooled by a per-probe line and returns a name as a count
#     (the exact defect that made count_of report BROKEN as 0 for months)
#   - the parser silently returns a number when the total is absent
#   - the record stops stating coverage at all

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="$REPO_ROOT/scripts/post_walk_qa.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

[ -f "$QA" ] || { echo "FAIL [missing]: $QA not found -- nothing checked. NOT a pass." >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- lift the REAL n_probes parser out of the script under test -----------
LINE="$(grep -n 'n_probes="\$(awk' "$QA" | head -1 | cut -d: -f1)"
if [ -z "$LINE" ]; then
    fail "no-parser" "post_walk_qa.sh has no n_probes awk parser; the record cannot state a denominator"
    exit 1
fi
{ echo 'PROBE_LOG="$1"'; sed -n "${LINE}p" "$QA"; echo 'printf "%s" "$n_probes"'; } > "$WORK/np.sh"
/bin/bash -n "$WORK/np.sh" || { fail "extract-syntax" "lifted parser does not parse"; exit 2; }
pass "lifted the real n_probes parser out of post_walk_qa.sh and it parses"

np() { /bin/bash "$WORK/np.sh" "$1"; }

# ---- a real-shaped summary, in run_box_walk.sh's exact output form --------
cat > "$WORK/good.log" <<'EOF'
--- PHASE 1: negative controls (each probe must be able to FAIL) ---
  BROKEN   no_store_port_is_tcp_reachable  (self-test returned 0, expected 1)
  ok       daemon_is_listening  (goes red on known-bad input)

============================================================
RESULT
  PASS        7
  FAIL        7
  CANNOT-RUN  6
  BROKEN      1
  ----------------
  of          21 probes
============================================================
EOF

got="$(np "$WORK/good.log")"
if [ "$got" = "21" ]; then
    pass "the probe total is recovered from the summary (21)"
else
    fail "denominator" "expected 21, got '${got:-<empty>}'"
fi

# ---- THE COVERAGE ARITHMETIC, on the real v1.0.50 shape ------------------
# 7+7+6 = 20 measured, of 21. The sum 7+7+6+1 = 21 is NOT the coverage number.
m=$(( 7 + 7 + 6 ))
if [ "$m" -eq 20 ] && [ "$got" = "21" ] && [ "$m" -lt "$got" ]; then
    pass "v1.0.50 shape yields measured 20 of 21 -- strictly less than the perfect sum of 21"
else
    fail "coverage-arithmetic" "expected measured=20 < total=21, got measured=$m total=$got"
fi

# ---- the parser must NOT be fooled by a per-probe line --------------------
# This is the defect that made count_of return a probe NAME as the BROKEN count.
cat > "$WORK/trap.log" <<'EOF'
  BROKEN   of_course_this_is_a_probe_name  (self-test returned 0, expected 1)
  of          99 probes and some trailing prose
RESULT
  of          21 probes
EOF
got="$(np "$WORK/trap.log")"
if [ "$got" = "21" ]; then
    pass "a per-probe line and a malformed 'of' line are both rejected; the real total wins"
elif [ "$got" = "99" ]; then
    fail "trap-fooled" "the parser accepted a line with trailing prose (NF>3) and returned 99"
else
    fail "trap-other" "expected 21, got '${got:-<empty>}'"
fi

# ---- an absent total must yield EMPTY, never a fabricated number ----------
cat > "$WORK/nototal.log" <<'EOF'
RESULT
  PASS        7
  FAIL        7
  CANNOT-RUN  6
  BROKEN      1
EOF
got="$(np "$WORK/nototal.log")"
if [ -z "$got" ]; then
    pass "an absent probe total yields empty, so the record can say UNKNOWN rather than invent a ratio"
else
    fail "fabricated" "expected empty when the total is absent, got '$got'"
fi

# ---- the record must actually emit the coverage row ----------------------
if grep -q "printf 'measured\\\\t" "$QA"; then
    pass "the record emits a measured row"
else
    fail "row-missing" "post_walk_qa.sh never writes 'measured'; coverage is left to be derived from a sum that cannot carry it"
fi

# ---- and it must name the skip IN THE EMITTED ROW, not in a comment ------
# SCOPED TO THE printf ON PURPOSE. The first version of this check grepped the
# whole file, and the mutation that deleted the phrase from the emitted string
# SURVIVED -- because the same words appear in the code comment above it. A
# comment standing in for behaviour is the defect this estate keeps finding;
# the assertion has to read the line that executes.
_emit="$(grep -n "printf 'measured" "$QA")"
if [ -z "$_emit" ]; then
    fail "no-emit" "no printf of a measured row to inspect"
elif [ "$(printf '%s' "$_emit" | grep -c 'SKIPPED in phase 2')" -gt 0 ]; then
    pass "the EMITTED row says why broken probes are excluded (not merely a comment nearby)"
else
    fail "unexplained" "the measured row is emitted but does not itself say a broken probe is skipped and measures nothing; only the surrounding comment does"
fi

# ---- the reconciliation must be stated in the file, not assumed ----------
if grep -q 'DOES NOT RECONCILE' "$QA"; then
    pass "a non-partitioning bucket set is announced in the record rather than silently summed"
else
    fail "silent-recon" "post_walk_qa.sh never emits a DOES NOT RECONCILE state; a broken partition would print as normal"
fi

[ "$FAILED" -ne 0 ] && exit 1
echo
echo "ALL WALK RECORD COVERAGE TESTS PASSED"
