#!/usr/bin/env bash
#
# tests/test_expired_deferral_ratchet.sh
#
# The expiry ratchet's comparison, exercised directly.
#
# WHY IT IS A SEPARATE TEST. scripts/verify_no_orphaned_fixes.sh makes a network
# call per ref and takes about four minutes on a full six-repo run. A ratchet
# that can only be exercised by the thing it lives inside is a ratchet nobody
# exercises, so the comparison is a function and this drives it in a second.
#
# WHAT THE RATCHET IS FOR. Deferral expiry is REPORTED and not enforced, and
# that is correct: 426 refs have expired as of v1.0.43, so switching enforcement
# on would fail the cut outright. What was wrong is that "not blocking" also
# meant "unbounded" -- the number could grow every cut and nothing said so.
#
# THE BASELINE IS A LIST, NOT A COUNT, and that is the whole design. A count
# cannot see a swap: work one ref off and let another expire, and the total is
# unchanged while a deferral has quietly gone past its deadline.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_no_orphaned_fixes.sh"

[[ -f "$GATE" ]] || { echo "CANNOT-RUN: gate not found at $GATE (exit 2)" >&2; exit 2; }

# Pull the function out of the gate without running the gate. sed range, not
# `source`: the script has top-level side effects (mktemp, traps, arg parsing)
# and sourcing it would run all of them.
FN="$(sed -n '/^expiry_ratchet_sets() {$/,/^}$/p' "$GATE")"
if [[ -z "$FN" ]]; then
    echo "CANNOT-RUN: expiry_ratchet_sets() not found in ${GATE}." >&2
    echo "  The function was renamed or inlined; this test is measuring nothing." >&2
    exit 2
fi
eval "$FN"
if ! declare -F expiry_ratchet_sets >/dev/null; then
    echo "CANNOT-RUN: the extracted text did not define expiry_ratchet_sets (exit 2)" >&2
    exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ratchet-XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  [pass] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

# check <label> <current-lines> <baseline-lines> <want-new> <want-gone>
check() {
    local label="$1" cur="$2" base="$3" want_new="$4" want_gone="$5"
    printf '%s' "$cur" > "$TMP/cur"
    printf '%s' "$base" > "$TMP/base"
    expiry_ratchet_sets "$TMP/cur" "$TMP/base" "$TMP/new" "$TMP/gone"
    local got_new got_gone
    got_new="$(tr '\n' ' ' < "$TMP/new" | sed 's/ *$//')"
    got_gone="$(tr '\n' ' ' < "$TMP/gone" | sed 's/ *$//')"
    if [[ "$got_new" == "$want_new" && "$got_gone" == "$want_gone" ]]; then
        ok "$label"
    else
        bad "$label -- new=[$got_new] want [$want_new]; gone=[$got_gone] want [$want_gone]"
    fi
}

echo "== the ratchet must FIRE =="

check "(1) a ref that expired and is not baselined is NEW" \
      'CM051:#1
CM051:#2
' 'CM051:#1
' 'CM051:#2' ''

# THE CASE A COUNT CANNOT SEE. One off, one on: totals identical, and a
# deferral has silently gone past its deadline.
check "(2) a SWAP is caught -- same count, different set" \
      'CM051:#1
CM051:#3
' 'CM051:#1
CM051:#2
' 'CM051:#3' 'CM051:#2'

echo "== the ratchet must stay QUIET =="

check "(3) an unchanged set is neither new nor gone" \
      'CM051:#1
CM051:#2
' 'CM051:#1
CM051:#2
' '' ''

check "(4) progress: a baselined ref that no longer expires is GONE, not NEW" \
      'CM051:#1
' 'CM051:#1
CM051:#2
' '' 'CM051:#2'

check "(5) input order does not matter -- both sides are re-sorted" \
      'CM051:#2
CM051:#1
' 'CM051:#1
CM051:#2
' '' ''

check "(6) duplicates on either side do not manufacture a diff" \
      'CM051:#1
CM051:#1
CM051:#2
' 'CM051:#2
CM051:#1
' '' ''

check "(7) comments and blank lines in the baseline are not refs" \
      'CM051:#1
' '# Deferrals whose until_cut has already passed.
   # indented comment

CM051:#1
' '' ''

echo "== boundaries =="

check "(8) an empty current set against a populated baseline is all GONE" \
      '' 'CM051:#1
CM051:#2
' '' 'CM051:#1 CM051:#2'

check "(9) a populated current set against an EMPTY baseline is all NEW" \
      'CM051:#1
CM051:#2
' '' 'CM051:#1 CM051:#2' ''

# A baseline file that does not exist must behave as empty, i.e. everything is
# new. It must NOT behave as "matches", which is how a deleted baseline would
# silently retire the ratchet.
printf '%s' 'CM051:#1
' > "$TMP/cur"
expiry_ratchet_sets "$TMP/cur" "$TMP/does-not-exist" "$TMP/new" "$TMP/gone"
if [[ "$(cat "$TMP/new")" == "CM051:#1" ]]; then
    ok "(10) a MISSING baseline makes everything new, it does not read as clean"
else
    bad "(10) a missing baseline did not flag the current set: [$(cat "$TMP/new")]"
fi

echo "== the committed baseline =="

BASE="${REPO_ROOT}/tests/expired_deferrals_baseline.txt"
if [[ ! -f "$BASE" ]]; then
    bad "(11) tests/expired_deferrals_baseline.txt is missing -- the ratchet has nothing to ratchet against"
else
    n="$(grep -cv '^[[:space:]]*\(#\|$\)' "$BASE")"
    if (( n > 0 )); then
        ok "(11) the committed baseline holds ${n} ref(s)"
    else
        bad "(11) the committed baseline holds no refs, so it can never flag anything"
    fi
    # Every row must look like a ref this gate can generate. A prose line in
    # here would never match and would sit in the file looking handled.
    strays="$(grep -v '^[[:space:]]*\(#\|$\)' "$BASE" | grep -vc '^[A-Za-z0-9_.-]*:[^ ]*$')"
    if [[ "$strays" == "0" ]]; then
        ok "(12) every baselined row has the <repo>:<ref> shape the gate emits"
    else
        bad "(12) ${strays} baselined row(s) are not in <repo>:<ref> shape and can never match"
    fi
fi

echo "== the wiring from comparison to exit code =="

# STRUCTURAL, and labelled so, because the boundary matters.
#
# THE DETECTION HAS BEEN PROVED BEHAVIOURALLY. A full run at v1.0.43 against a
# baseline with two rows deleted reported, on a real six-repo run:
#
#     expiry ratchet: 426 expired now, 424 baselined, 6 repo(s) checked
#     ERROR: a deferral went past its until_cut and is not in the baseline.
#         CM031:#121
#         CM051:feat/land-freshness-gate
#
# Exactly the two removed, and only those.
#
# WHAT IS NOT PROVED BEHAVIOURALLY is the step from that message to exit 1,
# because on this estate the gate exits 1 for genuine orphaned work before the
# expiry exit path is reached, so no run can isolate it. The three checks below
# grep the source instead -- the same technique as the flush/reset ordering in
# the output-buffer test. That is a WEAKER claim than the ten above, and saying
# so is the point: a structural check that reads as behavioural proof is how a
# suite gets believed further than it has earned.

if grep -q 'expiry_ratchet_failed=1' "$GATE"; then
    ok "(13) a new expiry sets expiry_ratchet_failed"
else
    bad "(13) nothing sets expiry_ratchet_failed, so a new expiry changes no exit code"
fi

# It must NOT reuse `red`. `red` means "work exists that is not in what you are
# about to ship" and the exit block prints exactly that sentence; an expired
# deferral is a different fact and printing the orphan paragraph for it sends
# the reader looking for commits that are not missing.
# Read the BRANCH, not a comment. Extract the lines between the new-expiry
# error message and the end of that arm, and assert red is not touched there.
if awk '
    /ERROR: a deferral went past its until_cut/ { inbranch = 1 }
    inbranch && /red=\$\(\(red \+ 1\)\)/       { bumped = 1 }
    inbranch && /^    elif /                   { inbranch = 0 }
    END { exit bumped }
' "$GATE"; then
    ok "(14) the new-expiry arm does NOT increment red, so it cannot print the orphaned-work paragraph"
else
    bad "(14) the new-expiry arm increments red -- an expired deferral would be reported as work missing from the ship"
fi

if awk '
    /expiry_ratchet_failed=1/            { set = NR }
    /expiry_ratchet_failed" -ne 0/       { read = NR }
    END { exit !(set && read && set < read) }
' "$GATE"; then
    ok "(15) the flag is SET before it is READ, so the exit path can see it"
else
    bad "(15) expiry_ratchet_failed is read before it is set, or never read at all"
fi

echo
printf 'expiry ratchet: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
exit 0
