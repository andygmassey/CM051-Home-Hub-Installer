#!/bin/bash
# scripts/tests/test_an_unreachable_box_is_not_a_defect.sh
#
# THE ACCEPTANCE GATE REPORTED A HARNESS ERROR AS A DEFECT IN THE ARTEFACT, AND
# REPORTED AN UNREAD LOG AS A CLEAN ONE.
#
# acceptance_gate_v1013 is registered in cut-manifests/permanent.yaml, so it
# runs on EVERY cut, and check_box_walk_probe consumes its exit code:
#
#     78          -> CANNOT-RUN
#     any other   -> FAIL
#     0           -> PASS
#
# run_box_walk.sh:44 declares EX_CANNOT_RUN=78 and the 25 probes under probes/
# all refuse through lib/probe.sh's probe_cannot_run(). This gate sits one
# directory up, sources nothing, and exited 2 for "cannot ssh to the box" -- so
# an unreachable box became a FAIL against the artefact, which is the false
# accusation check_box_walk_probe's own comment describes as sending "whoever
# reads the report hunting a bug that was never detected."
#
# AND THE OTHER DIRECTION, WHICH IS WORSE. Three situations produced an
# identical count of 0: a genuinely clean log, a box with NO log directories,
# and an ssh call that returned nothing. A5 and A6 read that 0 and reported
#
#     PASS  A6  Wiki compiler clean (fresh image)  sparql-400=0 crashes=0 ...
#
# on a box where not one log line was ever read. A8 had the same shape with an
# empty string: "all ostler agents exit 0 / benign" when nothing came back at
# all. A fresh box is exactly the box an acceptance gate runs against.
#
# HOW THIS IS TESTED WITHOUT A BOX. The existing self-test says "we can't stand
# up a real Ostler box in a shell fixture", which is true and was taken to mean
# the counting semantics were untestable. They are not: you do not need a box,
# you need a fake `box()`. Every arm below runs the REAL script with its one
# ssh-touching function replaced, and an arm asserts that replacement landed --
# without it, a stub that failed to apply would make the script attempt a real
# connection, fail, exit 78, and the first arm would pass for entirely the
# wrong reason.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GATE="${REPO}/scripts/box_walk_probes/acceptance_gate_v1013.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "${GATE}" ] || cant "cannot read ${GATE}"
[ -s "${GATE}" ] || cant "${GATE} is empty; every arm below would report on nothing"

WORK="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# Build a runnable copy whose only ssh-touching function is replaced by a stub
# driven from a file. NOTHING below opens a network connection.
# ---------------------------------------------------------------------------
STUB_MODE="${WORK}/mode"
build() {
    local out="$1"
    awk -v stub="${WORK}/stub.sh" '
        /^box\(\)\{ ssh / { print "box(){ . " stub "; _fake_box \"$1\"; }"; next }
        { print }
    ' "${GATE}" > "${out}"
    chmod +x "${out}"
}

cat > "${WORK}/stub.sh" <<'STUB'
_fake_box() {
    local cmd="$1"
    local mode; mode="$(cat "${STUB_MODE}")"
    case "${mode}" in
        dead)     return 0 ;;                        # ssh produces nothing at all
        nologs)   case "${cmd}" in
                      *found=0*)     echo NOLOGS ;;  # the dirs are not there
                      *"echo ok"*)   echo ok ;;
                      *http_code*)   echo 200 ;;
                      *frontpage*)   echo '{"id":"welcome-1"}' ;;
                      *launchctl*)   echo __A8_OK__ ;;
                      *api/tags*)    echo '"name":"qwen"' ;;
                      *)             echo "" ;;
                  esac ;;
        clean)    case "${cmd}" in
                      *found=0*)     echo 0 ;;
                      *"echo ok"*)   echo ok ;;
                      *http_code*)   echo 200 ;;
                      *frontpage*)   echo '{"id":"welcome-1"}' ;;
                      *launchctl*)   echo __A8_OK__ ;;
                      *api/tags*)    echo '"name":"qwen"' ;;
                      *)             echo "" ;;
                  esac ;;
        dirty)    case "${cmd}" in
                      *found=0*)     echo 7 ;;       # real errors in the logs
                      *"echo ok"*)   echo ok ;;
                      *http_code*)   echo 200 ;;
                      *frontpage*)   echo '{"id":"welcome-1"}' ;;
                      *launchctl*)   echo __A8_OK__ ;;
                      *api/tags*)    echo '"name":"qwen"' ;;
                      *)             echo "" ;;
                  esac ;;
        a8trunc)  case "${cmd}" in
                      *"echo ok"*)   echo ok ;;
                      *found=0*)     echo 0 ;;
                      *launchctl*)   echo "" ;;      # reply lost, no terminator
                      *http_code*)   echo 200 ;;
                      *frontpage*)   echo '{"id":"welcome-1"}' ;;
                      *api/tags*)    echo '"name":"qwen"' ;;
                      *)             echo "" ;;
                  esac ;;
    esac
}
STUB

COPY="${WORK}/gate.sh"
build "${COPY}"

echo "== MUST-MISS: the stub really replaced ssh =="
# Without this, a failed substitution would let the script attempt a REAL
# connection. Every arm below would then be measuring the network.
if grep -q '^box(){ ssh ' "${COPY}"; then
    bad "the real ssh box() survived in the copy -- every arm below would open a network connection and prove nothing"
elif grep -q '_fake_box' "${COPY}"; then
    ok "the copy calls _fake_box and contains no ssh box(), so the arms below are hermetic"
else
    cant "the copy has neither the real box() nor the stub; the awk substitution produced something unexpected"
fi

run_gate() {
    printf '%s' "$1" > "${STUB_MODE}"
    STUB_MODE="${STUB_MODE}" OSTLER_BOX_HOST="fake.invalid" \
        bash "${COPY}" > "${WORK}/out.txt" 2>&1
    printf '%s' "$?"
}

echo "== an unreachable box exits 78 (CANNOT-RUN), not 2 and not 1 =="
rc="$(run_gate dead)"
if [ "${rc}" = "78" ]; then
    ok "ssh producing nothing exits 78, which check_box_walk_probe records as CANNOT-RUN"
elif [ "${rc}" = "2" ]; then
    bad "ssh failure still exits 2 -- check_box_walk_probe maps every non-zero that is not 78 to FAIL, so an unreachable box is recorded as a defect in the artefact"
else
    bad "ssh failure exits ${rc}, expected 78"
fi
if grep -q 'VERDICT: CANNOT-RUN --' "${WORK}/out.txt"; then
    ok "it names the prerequisite on a VERDICT line, so run_box_walk does not record it as UNRECORDED"
else
    bad "no 'VERDICT: CANNOT-RUN --' line, so run_box_walk records the reason as UNRECORDED"
fi

echo "== a box with NO logs refuses instead of reporting the compiler clean =="
rc="$(run_gate nologs)"
if [ "${rc}" = "78" ]; then
    ok "absent log directories exit 78 rather than passing"
elif [ "${rc}" = "0" ]; then
    bad "absent log directories still exit 0 -- the gate reports 'Wiki compiler clean' on a box where not one log line was read"
else
    bad "absent log directories exit ${rc}, expected 78"
fi
if grep -q 'CANT  A6' "${WORK}/out.txt" && grep -q 'CANT  A5' "${WORK}/out.txt"; then
    ok "A5 and A6 are both rendered as could-not-run rather than pass"
else
    bad "A5/A6 did not render as could-not-run: $(grep -E 'A5|A6' "${WORK}/out.txt" | tr '\n' ' ')"
fi

echo "== CONTROL: a readable, genuinely clean box still exits 0 =="
# Without this the fix could be "always refuse", which blocks every cut.
rc="$(run_gate clean)"
if [ "${rc}" = "0" ]; then
    ok "CONTROL: readable logs with zero matches still exit 0, so the refusals above are measurements and not a blanket"
else
    bad "CONTROL: a clean box exits ${rc}, expected 0. Rows: $(grep -E '  (PASS|FAIL|CANT|EYES)  A' "${WORK}/out.txt" | tr -s ' ' | tr '\n' ' ')"
fi
if grep -qE '  CANT  A' "${WORK}/out.txt"; then
    bad "CONTROL: a clean box still produced a could-not-run row, so the refusal is firing on readable input"
else
    ok "CONTROL: a clean box produces NO could-not-run row"
fi

echo "== CONTROL: a real defect still FAILS, and outranks could-not-run =="
rc="$(run_gate dirty)"
if [ "${rc}" = "1" ]; then
    ok "CONTROL: logs carrying real errors still exit 1, so CANNOT-RUN has not swallowed a measured defect"
else
    bad "CONTROL: a dirty box exits ${rc}, expected 1"
fi

echo "== A8: a lost launchctl reply is not 'all agents exit clean' =="
rc="$(run_gate a8trunc)"
if grep -q 'CANT  A8' "${WORK}/out.txt"; then
    ok "a reply with no terminator renders A8 as could-not-run (exit ${rc})"
else
    bad "A8 reported '$(grep -E 'A8' "${WORK}/out.txt" | head -1 | tr -s ' ')' for a reply that never arrived"
fi

echo
echo "== ${pass} pass / ${fail} fail / $((pass+fail)) total =="
[ "${fail}" -eq 0 ] || exit 1
exit 0
