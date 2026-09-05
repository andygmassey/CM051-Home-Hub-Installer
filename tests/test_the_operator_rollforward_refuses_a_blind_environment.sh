#!/usr/bin/env bash
# THE OPERATOR'S ROLLFORWARD RUNNER MUST REFUSE A BLIND ENVIRONMENT.
#
# WHY THIS EXISTS. `bin/operator_rollforward.sh` prepares the environment the
# rollforward gate needs and then runs it. Its whole value is that a partly
# prepared environment produces UNRUNNABLE gates, and a run with UNRUNNABLE
# gates looks, in the summary line, almost exactly like a run that found
# nothing.
#
# MEASURED 2026-09-06, the same gate, the same cut, the same box:
#
#     nothing prepared    0 measured failures, 28 CANNOT-RUN,  0 passed
#     prepared            2 measured failures,  5 CANNOT-RUN, 21 passed
#
# So the runner must never proceed on a half-built environment. Every arm below
# is a way the environment can be blind, and every one must exit 2.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/bin/operator_rollforward.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -x "$SUBJECT" ] || { echo "CANNOT-RUN: no executable runner at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

_rc() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

echo "== a blind environment must refuse, and must not exit 0 =="

rc="$(_rc bash "$SUBJECT")"
[ "$rc" = "2" ] && ok "no cut version exits 2" \
                || bad "no cut version exits ${rc}"

rc="$(_rc env OSTLER_DEV_ROOT="${WORK}/nowhere" bash "$SUBJECT" v1.0.72)"
[ "$rc" = "2" ] && ok "a sibling checkout that does not exist exits 2 rather than running a partly blind gate" \
                || bad "a missing sibling exits ${rc}; the gate would have run with UNRUNNABLE rows"

# It must NAME the variable it could not satisfy. "Something was missing" costs
# the next operator the same diagnosis.
env OSTLER_DEV_ROOT="${WORK}/nowhere" bash "$SUBJECT" v1.0.72 >/dev/null 2>"${WORK}/err"
if grep -q 'CM051_DIR' "${WORK}/err" 2>/dev/null; then
    ok "the refusal NAMES the variable it could not satisfy"
else
    bad "the refusal does not name the missing variable; a refusal that cannot say why is diagnosed twice"
fi

# An unreachable GATE_BOX must be caught ONCE, up front, not discovered by
# fifteen box gates in turn. 10.255.255.1 is TEST-NET-1 style unroutable.
rc="$(_rc env GATE_BOX=archie@10.255.255.1 bash "$SUBJECT" v1.0.72)"
[ "$rc" = "2" ] && ok "a GATE_BOX that is set but unreachable exits 2 up front" \
                || bad "an unreachable GATE_BOX exits ${rc}; 15 box gates would each report UNRUNNABLE instead"

echo "== the worktree root must be shareable with the container runtime =="

# v1018-D001 bind-mounts a file from \$CM051_DIR into a container, and the
# runtime does not share /tmp or /var/folders. MEASURED: that gate was GREEN
# with the trees under \$HOME and RED under \$TMPDIR, nothing else changed.
# This is a source-shape assertion because the alternative is running the whole
# gate twice, which takes minutes and needs a live box.
if grep -qE 'WORKROOT="\$\{OSTLER_ROLLFORWARD_WORKROOT:-\$\{HOME\}' "$SUBJECT"; then
    ok "the default worktree root is under \$HOME, where the container runtime can bind-mount"
else
    bad "the default worktree root is not under \$HOME; v1018-D001 will go RED on a path the container runtime cannot share"
fi

# CONTROL on that arm: the assertion must be capable of failing. Point it at a
# tree where the default IS a temp path and confirm the predicate says so.
cp "$SUBJECT" "${WORK}/mutant.sh"
/usr/bin/sed -i '' 's|WORKROOT="${OSTLER_ROLLFORWARD_WORKROOT:-${HOME}/.ostler-rollforward-trees}"|WORKROOT="${OSTLER_ROLLFORWARD_WORKROOT:-${TMPDIR:-/tmp}/trees}"|' "${WORK}/mutant.sh" 2>/dev/null
if grep -qE 'WORKROOT="\$\{OSTLER_ROLLFORWARD_WORKROOT:-\$\{HOME\}' "${WORK}/mutant.sh"; then
    bad "CONTROL: the mutant still matches the \$HOME predicate, so the arm above proves nothing"
else
    ok "CONTROL: a \$TMPDIR default fails the same predicate, so the arm above is a measurement"
fi

echo "== git's own error must survive a refusal =="

# MEASURED: the first version swallowed git stderr and reported "could not
# create a worktree", which named the symptom and hid every cause. The real
# one was "is a missing but already registered worktree" -- stale registration
# from this script's own cleanup.
if grep -q 'git-err' "$SUBJECT" && grep -q 'git said' "$SUBJECT"; then
    ok "git's stderr is captured and printed on a worktree failure"
else
    bad "git's stderr is discarded on a worktree failure; the cause cannot be recovered from the message"
fi

if grep -q 'worktree prune' "$SUBJECT"; then
    ok "stale worktree registrations are pruned, so a second run is not refused by the first run's cleanup"
else
    bad "no worktree prune: deleting the directory does not deregister it, and the next run will refuse"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
