#!/usr/bin/env bash
# A BOM row whose `ref` is the cut pin records a check that cannot fail.
#
# The BOM's purpose is to prove each fix is IN the cut. The check is
# `git merge-base --is-ancestor <ref> <pin>`. Put the pin in the ref column and
# that becomes "is the pin an ancestor of the pin", which is true for every cut
# that ever will be, so the row proves nothing about the fix it names.
#
# FOUND ON v1.0.67, 2026-09-05. Its eight rows all carried `c0518825`, the cut
# pin, and every one graded "landed". @ARCHIE had done the real check -- eight
# distinct per-PR SHAs, verified independently by TNM -- but the FILE did not
# preserve it, so the evidence lived only in a relay-board post.
#
# NOT A v1.0.67 NOVELTY. Measured across all 26 cuts carrying both a BOM and a
# cut.env: FOUR are tautological (v1.0.61, v1.0.62, v1.0.65, v1.0.67) and 22
# are not. Nothing noticed the previous three. That is what this gate is for.
#
# WHAT THIS DELIBERATELY DOES NOT TEST. A cut may legitimately carry fewer
# distinct refs than rows: if every fix landed in one merge commit, one ref for
# N rows is correct and v1.0.63 is exactly that shape (5 rows, 1 ref, and that
# ref is NOT the pin). Flagging "distinct < rows" would call that a defect and
# bury the real one in noise. The narrow predicate is ref EQUALS pin.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="${REPO}/tests/bom_tautological_ref_baseline.txt"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# A DENOMINATOR FLOOR. If the cut walk stops matching -- a layout change, a
# rename -- it examines zero cuts, none are tautological, and this gate goes
# green over a question it never asked. 26 carried both files on 2026-09-05.
MIN_CUTS=20

[ -f "$BASELINE" ] || cant "no baseline at ${BASELINE}; 'no new instances' would be unfounded"
cd "$REPO" || cant "cannot enter ${REPO}"

# Is this cut's ref column the pin? Echoes "TAUT" or "ok", or "SKIP:<why>".
_classify() {
    local d="$1" bom="cuts/$1/MUST_CONTAIN.tsv" env="cuts/$1/cut.env"
    [ -f "$bom" ] || { printf 'SKIP:no-bom'; return; }
    [ -f "$env" ] || { printf 'SKIP:no-cut.env'; return; }
    local refs dist first pin
    refs="$(grep -vE '^[[:space:]]*(#|$)' "$bom" | tail -n +2 | /usr/bin/awk -F'\t' '{print $3}' | sort -u)"
    dist="$(printf '%s\n' "$refs" | grep -c . || true)"
    [ "${dist:-0}" -ge 1 ] || { printf 'SKIP:no-rows'; return; }
    first="$(printf '%s\n' "$refs" | head -1)"
    pin="$(grep '^CM051=' "$env" | cut -d= -f2 | tr -d ' ')"
    [ -n "$pin" ] || { printf 'SKIP:no-pin'; return; }
    if [ "${dist}" = "1" ]; then
        # abbreviated SHAs are common in both files, so compare by prefix
        case "$pin"   in "$first"*) printf 'TAUT'; return ;; esac
        case "$first" in "$pin"*)   printf 'TAUT'; return ;; esac
    fi
    printf 'ok'
}

echo "── controls: the classifier must SEE a tautology and must ABSTAIN ──"
# Both controls are REAL CUTS in this repo, not synthetic fixtures: the two
# shapes the predicate must tell apart already exist in history.
C_TAUT="$(_classify v1.0.65)"
C_OK="$(_classify v1.0.66)"
C_ONEREF="$(_classify v1.0.63)"

# ANCHOR THE CONTROL TO A SHIPPED CUT, NOT A LIVE ONE. This was v1.0.67 until
# CM051 #1488 repinned that cut to 03b50c6b, which broke its tautology and with
# it this control -- the gate went red because its FIXTURE moved, not because
# the property did. v1.0.65 shipped long ago and cannot change under the test.
[ "$C_TAUT" = "TAUT" ] \
    && ok "MUST-FLAG: v1.0.65 (ref == pin) classifies TAUT" \
    || bad "MUST-FLAG: v1.0.65 classified '${C_TAUT}'. The predicate cannot see the defect it exists for, so every 'ok' below is meaningless."
[ "$C_OK" = "ok" ] \
    && ok "MUST-MISS: v1.0.66 (5 rows, 5 distinct refs) classifies ok" \
    || bad "MUST-MISS: v1.0.66 classified '${C_OK}'. The predicate flags a correct BOM."
[ "$C_ONEREF" = "ok" ] \
    && ok "MUST-MISS: v1.0.63 (5 rows, ONE ref, but not the pin) classifies ok -- one merge commit is legitimate" \
    || bad "MUST-MISS: v1.0.63 classified '${C_ONEREF}'. The predicate is testing 'distinct < rows' rather than 'ref == pin', which would bury the real defect in noise."

echo "── subject: every cut in this repo ──"
NEW=""; N=0; T=0
for dir in cuts/v1.*/; do
    d="$(basename "$dir")"
    r="$(_classify "$d")"
    case "$r" in SKIP:*) continue ;; esac
    N=$((N+1))
    [ "$r" = "TAUT" ] || continue
    T=$((T+1))
    grep -qxF "$d" "$BASELINE" || NEW="${NEW} ${d}"
done

[ "$N" -ge "$MIN_CUTS" ] || cant "examined ${N} cut(s), below the floor of ${MIN_CUTS}. \
The walk has gone blind; zero tautologies found by looking at nothing is not a pass."

printf '  examined %s cut(s); %s tautological, %s baselined\n' \
    "$N" "$T" "$(grep -cvE '^[[:space:]]*(#|$)' "$BASELINE")"

if [ -z "$NEW" ]; then
    ok "no NEW cut puts the pin in its ref column"
else
    bad "NEW tautological BOM(s):${NEW}
        Every row grades 'landed' by asking whether the pin is an ancestor of
        the pin. Put the per-fix merge commits in the ref column, as v1.0.66
        does, so the check can fail."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
