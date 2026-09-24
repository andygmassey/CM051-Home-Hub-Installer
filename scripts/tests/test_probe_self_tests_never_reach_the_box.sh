#!/usr/bin/env bash
# A probe's self-test runs with the box variables cleared (#2362).
#
# On the v1.0.102 walk four probes came back BROKEN in phase 1 because their
# self-tests reached the live box through lib/probe.sh box_run() while the box
# was busy; the same self-tests pass on a quiet host. This proves, two ways:
#   A. EXECUTED: the runner's own run_probe_self_test, lifted from
#      run_box_walk.sh, hands a stub probe NO OSTLER_BOX_HOST even when the
#      caller exports one.
#   B. REAL PROBES: every probe's self-test returns the same code with
#      OSTLER_BOX_HOST pointed at an unreachable host as without it, when run
#      the way the runner runs it. On main five differ.
#
# EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="${1:-${REPO}/scripts/box_walk_probes/run_box_walk.sh}"
PROBES_DIR="${REPO}/scripts/box_walk_probes/probes"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
[ -f "$RUNNER" ] || { echo "CANNOT-RUN: no runner at $RUNNER" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

awk '/^run_probe_self_test\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$RUNNER" > "$WORK/fn.sh"
if [ ! -s "$WORK/fn.sh" ]; then
    bad "run_box_walk.sh defines run_probe_self_test"
    echo; echo "== ${PASS} pass / ${FAIL} fail =="; exit 1
fi
ok "run_box_walk.sh defines run_probe_self_test"
grep -q 'run_probe_self_test "$p"' "$RUNNER" \
    && ok "phase 1 invokes every self-test through it" \
    || bad "phase 1 invokes every self-test through it"

echo "A. a stub probe sees no box host"
printf '#!/usr/bin/env bash\necho "host=[${OSTLER_BOX_HOST:-}] dir=[${OSTLER_BOX_WALK_EVIDENCE_DIR:-}]"\n' > "$WORK/stub.sh"
out="$(OSTLER_BOX_HOST=nobody@selftest.invalid OSTLER_BOX_WALK_EVIDENCE_DIR=/nowhere \
       bash -c ". '$WORK/fn.sh'; run_probe_self_test '$WORK/stub.sh'")"
[ "$out" = "host=[] dir=[]" ] && ok "the host and the evidence dir are cleared" \
    || bad "the stub still saw: $out"
out="$(OSTLER_BOX_HOST=nobody@selftest.invalid bash "$WORK/stub.sh")"
[ "$out" != "host=[] dir=[]" ] && ok "control: the same stub DOES see the host when run bare" \
    || bad "control: the stub never sees the host, so arm A proves nothing"

echo "B. every real probe's self-test is independent of the box host"
n=0; differ=""
for p in "$PROBES_DIR"/*.sh; do
    n=$((n + 1))
    r1="$(bash -c ". '$WORK/fn.sh'; run_probe_self_test '$p'" >/dev/null 2>&1; echo $?)"
    r2="$(OSTLER_BOX_HOST=nobody@selftest.invalid OSTLER_SSH_TIMEOUT=2 bash -c ". '$WORK/fn.sh'; run_probe_self_test '$p'" >/dev/null 2>&1; echo $?)"
    [ "$r1" = "$r2" ] || differ="${differ} $(basename "$p" .sh)(${r1}/${r2})"
done
[ "$n" -ge 20 ] || { echo "CANNOT-RUN: only $n probes found" >&2; exit 2; }
[ -z "$differ" ] && ok "all $n self-tests return the same code with and without a box host" \
    || bad "self-test depends on the box host:${differ}"

echo; echo "== ${PASS} pass / ${FAIL} fail =="
[ "$FAIL" -eq 0 ]
