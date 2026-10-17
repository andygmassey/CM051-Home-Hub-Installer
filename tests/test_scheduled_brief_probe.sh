#!/usr/bin/env bash
# scheduled_brief_reaches_messages: the probe can say PASS, FAIL and CANNOT-RUN,
# each for its own reason, and it is read-only.
#
# Hermetic: synthetic jobs.db, chat.db and daemon log built by the lib's own
# --self-test. No real messages, recipients or handles.
#
# Arms:
#   1. the judge's self-test lands every case on its own verdict
#   2. the probe's --self-test exits 1 with "negative control behaved"
#   3. a mutant judge (a dropped delivery turned into a pass) makes the probe's
#      self-test stop claiming a behaved control
#   4. it declares WALK_READ_ONLY and opens sqlite read-only only
#
# EXIT 0 pass, 1 fail, 2 cannot-run. BASH 3.2.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="${ROOT}/scripts/box_walk_probes/probes/scheduled_brief_reaches_messages.sh"
LIB="${ROOT}/scripts/box_walk_probes/lib/brief_delivery_probe.py"
[ -f "$PROBE" ] && [ -f "$LIB" ] || { echo "CANNOT-RUN: probe or lib missing" >&2; exit 2; }
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

echo "--- 1. judge self-test ---"
python3 "$LIB" --self-test >"$W/lib.out" 2>&1; rc=$?
n="$(grep -c '^  ok' "$W/lib.out")"
if [ "$rc" -eq 0 ] && [ "$n" -ge 8 ]; then ok "judge self-test: ${n} cases on their own verdicts"
else cat "$W/lib.out"; bad "judge self-test rc=$rc cases=$n"; fi

echo "--- 2. probe self-test goes red ---"
out="$(bash "$PROBE" --self-test 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'negative control behaved' <<< "$out"; then
    ok "probe --self-test exits 1 with 'negative control behaved'"
else printf '%s\n' "$out"; bad "probe --self-test rc=$rc"; fi

echo "--- 3. a mutant judge breaks the self-test ---"
M="$W/mut"; mkdir -p "$M/probes" "$M/lib"
cp "$PROBE" "$M/probes/"; cp "${ROOT}/scripts/box_walk_probes/lib/probe.sh" "$M/lib/"
python3 -c "import sys; s=sys.stdin.read(); a='    if dropped:\n        return lines, EX_FAIL'; assert a in s; sys.stdout.write(s.replace(a, '    if dropped:\n        return lines, EX_PASS'))" < "$LIB" > "$M/lib/brief_delivery_probe.py"
if cmp -s "$LIB" "$M/lib/brief_delivery_probe.py"; then bad "mutant did not apply"; else
    out="$(bash "$M/probes/scheduled_brief_reaches_messages.sh" --self-test 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'negative control behaved' <<< "$out"; then
        ok "with a dropped delivery turned into PASS, the self-test no longer claims a behaved control (rc=$rc)"
    else bad "the self-test still reports a behaved control against a mutant judge"; fi
fi

echo "--- 4. read-only ---"
grep -q '^# WALK_READ_ONLY:' "$PROBE" && ok "declares WALK_READ_ONLY" || bad "no WALK_READ_ONLY declaration"
if grep -nE 'sqlite3\.connect\(' "$LIB" | grep -v 'mode=ro' | grep -vE 'connect\((jobs|chat)\)' >/dev/null; then
    bad "an sqlite open that is not mode=ro outside the self-test fixtures"
else ok "every box-side sqlite open is mode=ro"; fi

echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
