#!/usr/bin/env bash
# scripts/bounded_step.sh turns a hung CI step into a readable RED. Proven four ways:
#   A planted hang in the REAL watchdog test (LWD_SELFTEST_HANG=1, hangs before case 1, so it is
#     reached in under 1 s on any host): the wrapper dumps ps +
#     sample + the progress file, kills the group, exits 1, all within the bound
#   B a clean command: its rc passes through (0 and 3), nothing is dumped
#   C mutant: the wrapper's kill_group neutered -> the wrapper outlives the bound (caught)
# Usage: [REPO_ROOT]. rc 0 all pass, 1 a case failed, 2 CANNOT-RUN.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WRAP="${ROOT}/scripts/bounded_step.sh"
[ "$(uname -s)" = Darwin ] || { echo "CANNOT-RUN: the watchdog test under it needs macOS" >&2; exit 2; }
[ -x "$WRAP" ] || { echo "CANNOT-RUN: ${WRAP} not executable" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-bstep.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "CANNOT-RUN: mktemp gave no directory" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
cleanup() {
    local f p
    for f in "$WORK"/*.pgid; do # a survivor of the mutant run: our own, by recorded pgid
        [ -e "$f" ] || continue
        p="$(cat "$f")"; kill -KILL -- "-$p" 2>/dev/null
    done
    [ -z "${MUT_WRAPPER:-}" ] || kill -KILL "$MUT_WRAPPER" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' INT TERM HUP

BOUND=20
echo "== A: planted hang in the real watchdog test, bound ${BOUND}s"
T0="$(date +%s)"
LWD_SELFTEST_HANG=1 LWD_NO_MUTANTS=1 /bin/bash "$WRAP" "$BOUND" "$WORK/a.progress" -- /bin/bash "$ROOT/tests/test_listener_watchdog_install_marker.sh" "$ROOT" > "$WORK/a.out" 2>&1
RC=$?; ELAPSED=$(( $(date +%s) - T0 ))
sed 's/^/    | /' "$WORK/a.out"
[ "$RC" = 1 ] && ok "A1 wrapper exit 1 (RED) on a hang (rc=${RC})" || bad "A1 wanted rc 1, got ${RC}"
[ "$ELAPSED" -le $((BOUND + 30)) ] && ok "A2 returned in ${ELAPSED}s, bound ${BOUND}s + 30s slack" || bad "A2 took ${ELAPSED}s, past bound ${BOUND}s + 30s"
grep -q 'BOUNDED-STEP EXPIRED' "$WORK/a.out" && ok "A3 expiry line printed" || bad "A3 no expiry line"
grep -q 'sleep 86400' "$WORK/a.out" && grep -q ' PGID ' "$WORK/a.out" && ok "A4 ps dump names the stuck 'sleep 86400' child" || bad "A4 ps dump lacks the stuck child"
grep -q '^--- sample ' "$WORK/a.out" && ok "A5 sample of the deepest child attempted" || bad "A5 no sample section"
grep -q '^@[0-9:]* start hang-planted' "$WORK/a.out" && [ "$(grep -c '^@[0-9:]* start hang-planted' "$WORK/a.out")" -ge 2 ] && ok "A6 progress file catted: last case 'hang-planted' shown" || bad "A6 progress file not in the dump"
[ -s "$WORK/a.progress.dump" ] && grep -q 'BOUNDED-STEP DIAGNOSTIC' "$WORK/a.progress.dump" && ok "A8 dump also written to the .dump file (the artifact CI uploads)" || bad "A8 no .dump file"
PG="$(cat "$WORK/a.progress.pgid" 2>/dev/null)"
if [ -n "$PG" ] && ! kill -0 -- "-$PG" 2>/dev/null && [ -z "$(pgrep -P "$PG")" ]; then ok "A7 group ${PG} gone after the kill"; else bad "A7 group ${PG:-?} still alive"; fi

echo "== B: clean commands pass their rc through"
/bin/bash "$WRAP" 20 "$WORK/b0.progress" -- /bin/bash -c 'echo hello' > "$WORK/b0.out" 2>&1; R0=$?
/bin/bash "$WRAP" 20 "$WORK/b3.progress" -- /bin/bash -c 'exit 3' > "$WORK/b3.out" 2>&1; R3=$?
[ "$R0" = 0 ] && [ "$R3" = 3 ] && ! grep -q BOUNDED "$WORK/b0.out" "$WORK/b3.out" \
    && ok "B rc 0 -> 0, rc 3 -> 3, no diagnostic" || bad "B rc ${R0}/${R3}, wanted 0/3"

echo "== C: mutant, kill_group neutered, must outlive the bound"
MBOUND=4
python3 -I - "$WRAP" "$WORK/mutant.sh" <<'PYEND' || { bad "C mutant did not apply (anchor moved)"; echo "$PASS passed, $FAIL failed"; exit 1; }
import sys
s = open(sys.argv[1]).read()
i = s.index("kill_group() {")
j = s.index("\n}\n", i)
open(sys.argv[2], "w").write(s[:i] + "kill_group() { :" + s[j:])
PYEND
/bin/bash "$WORK/mutant.sh" "$MBOUND" "$WORK/c.progress" -- /bin/bash -c 'sleep 86400; :' > "$WORK/c.out" 2>&1 &
MUT_WRAPPER=$!
sleep $((MBOUND + 8))
if kill -0 "$MUT_WRAPPER" 2>/dev/null; then ok "C mutant: wrapper still alive ${MBOUND}+8s in (outlives the bound, as the mutation predicts)"
else bad "C mutant survived: wrapper ended anyway, so kill_group is not what bounds the step"; fi
grep -q 'BOUNDED-STEP EXPIRED' "$WORK/c.out" && ok "C mutant still dumped (the dump is not the kill)" || bad "C mutant: no dump"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
