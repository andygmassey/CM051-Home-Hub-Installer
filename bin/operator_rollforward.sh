#!/usr/bin/env bash
# THE OPERATOR'S PRE-TAG ROLLFORWARD RUN. It had no runbook, so it never ran.
#
# WHY THIS EXISTS. `.github/workflows/cut.yml` splits the rollforward gate by
# what each environment can honestly prove:
#
#     here, every tag push   --verify-claims   registry parses, no row claims
#                                              a fix with no gate
#     operator, pre-tag      --cut             THE GATE BODIES RUN
#     box-walk, on the Mini  --cut + GATE_BOX  the box gates run
#
# The middle row is a named responsibility with nothing behind it. Nothing in
# the repository set up what `--cut` needs, so the honest state was that the
# only run of the full gate anyone had ever seen was the one on the v1.0.19 tag
# where 15 gates printed UNRUNNABLE and 8 more went red on missing sibling
# checkouts. Two passed. That is the run the workflow comment is describing.
#
# MEASURED 2026-09-06, doing this by hand for the first time:
#
#     nothing set                 0 measured failures, 28 CANNOT-RUN,  0 passed
#     this script's environment   2 measured failures,  5 CANNOT-RUN, 21 passed
#
# Same gate, same cut, same box. The difference is entirely the harness, and
# a gate that cannot run is not a gate that found nothing.
#
# ── WHY IT BUILDS WORKTREES INSTEAD OF USING THE CHECKOUTS ─────────────────
# The [repo] gates refuse to measure against a stale checkout and say so by
# name (v1018-D028). Mine were 31, 7, 18 and 90 commits behind origin/main.
# The obvious move is to pull them. DO NOT: those are working checkouts and
# two of them held uncommitted work belonging to someone else. This creates
# throwaway detached worktrees at origin/main instead, which cannot disturb a
# branch, an index or a stash.
#
# ── THREE STATES ───────────────────────────────────────────────────────────
# 0 the gate ran and passed. 1 the gate ran and found something. 2 CANNOT-RUN:
# the environment could not be built, so NOTHING was measured. A cut does not
# proceed on 2, and 2 must never be reported as 0.
set -uo pipefail

CUT="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# UNDER $HOME, NOT $TMPDIR, AND THE GATE ITSELF TOLD ME WHY.
# v1018-D001 bind-mounts a file from $CM051_DIR into a container. The container
# runtime does not share /tmp or /var/folders, so a worktree there makes that
# gate RED with "cannot bind-mount a file from $CM051_DIR". MEASURED: the same
# gate was GREEN when the trees sat under $HOME and RED under $TMPDIR, with
# nothing else changed. The gate's own message says "A /tmp worktree does
# exactly this. Re-point CM051_DIR under $HOME and re-run", which is the second
# time tonight this runner has diagnosed my harness for me.
WORKROOT="${OSTLER_ROLLFORWARD_WORKROOT:-${HOME}/.ostler-rollforward-trees}"
KEEP="${OSTLER_ROLLFORWARD_KEEP:-0}"

say()  { printf '%s\n' "$*"; }
cant() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

[ -n "$CUT" ] || cant "usage: bin/operator_rollforward.sh <cut-version>   e.g. v1.0.72"
[ -x "${REPO_ROOT}/bin/rollforward_gate.sh" ] || cant "bin/rollforward_gate.sh is missing or not executable at ${REPO_ROOT}."

# Sibling checkouts, by the names the gate reads. Each is only a SOURCE for a
# worktree; none is modified.
#   var|default sibling directory name
SIBLINGS="CM051_DIR|CM051-Home-Hub-Installer
OA_DIR|ostler-assistant
CM044_DIR|CM044-PWG-Personal-Wiki
OS003_DIR|OS003-canonical"

DEVROOT="${OSTLER_DEV_ROOT:-$(cd "${REPO_ROOT}/.." && pwd)}"
say "dev root: ${DEVROOT}"
say "worktrees: ${WORKROOT}"

rm -rf "$WORKROOT" 2>/dev/null
mkdir -p "$WORKROOT" || cant "could not create ${WORKROOT}"

ENVARGS=""
built=0
while IFS='|' read -r var dirname; do
    [ -n "${var:-}" ] || continue
    # An explicit override wins, and is used AS GIVEN: the operator may already
    # have a fresh tree and we should not second-guess it.
    existing="$(eval "printf '%s' \"\${${var}:-}\"")"
    if [ -n "$existing" ]; then
        say "  ${var} <- ${existing} (from the environment, used as given)"
        ENVARGS="${ENVARGS} ${var}=${existing}"
        built=$((built+1))
        continue
    fi
    src="${DEVROOT}/${dirname}"
    if [ ! -d "${src}/.git" ] && [ ! -f "${src}/.git" ]; then
        cant "${var}: no git checkout at ${src}. Set ${var} explicitly, or clone it there. Guessing a path is how a gate ends up measuring the wrong tree."
    fi
    git -C "$src" fetch -q origin main 2>/dev/null \
        || cant "${var}: could not fetch origin/main in ${src}. A stale source makes every [repo] gate UNRUNNABLE."
    # PRUNE FIRST. Deleting the worktree DIRECTORY does not deregister it, so a
    # second run of this script hits "is a missing but already registered
    # worktree" and refuses. MEASURED: that is exactly what happened on the
    # first re-run, and it took git's own stderr to say so, which is why the
    # error is no longer swallowed below.
    git -C "$src" worktree prune 2>/dev/null || true
    dest="${WORKROOT}/${dirname}"
    # Do NOT swallow git's stderr here. MEASURED: the first version discarded
    # it and reported "could not create a worktree", which named the symptom
    # and hid every possible cause -- a locked worktree, a path collision, a
    # missing parent. A refusal that cannot say why costs the next person the
    # same diagnosis twice.
    if ! git -C "$src" worktree add -q --detach "$dest" origin/main 2>"${WORKROOT}/.git-err"; then
        say "  --- git said ---"
        sed 's/^/      /' "${WORKROOT}/.git-err" 2>/dev/null | head -6
        cant "${var}: could not create a worktree at ${dest}. git's own message is above."
    fi
    sha="$(git -C "$dest" rev-parse --short HEAD 2>/dev/null)"
    say "  ${var} <- ${dest} @ ${sha} (fresh worktree at origin/main)"
    ENVARGS="${ENVARGS} ${var}=${dest}"
    built=$((built+1))
done <<EOF
${SIBLINGS}
EOF

# CONTROL: four names go in, four must come out. A silently-skipped sibling
# turns its gates into UNRUNNABLE, which is the failure this script exists to
# stop, so it must not be possible to get here with three.
[ "$built" -eq 4 ] || cant "only ${built} of 4 sibling trees were prepared; refusing to run a gate that would be partly blind."

if [ -n "${GATE_BOX:-}" ]; then
    say "  GATE_BOX <- ${GATE_BOX}"
    ENVARGS="${ENVARGS} GATE_BOX=${GATE_BOX}"
    # Reachability is checked here rather than 15 gates later.
    ssh -o ConnectTimeout=8 -o BatchMode=yes "${GATE_BOX}" true 2>/dev/null \
        || cant "GATE_BOX ${GATE_BOX} is set but not reachable over ssh. A box gate cannot measure a box it cannot open, and 15 gates would print UNRUNNABLE one at a time."
else
    say "  GATE_BOX unset: the box gates will print UNRUNNABLE."
    say "  That is a REDUCTION IN COVERAGE, not a pass. Set GATE_BOX=user@host to run them."
fi

say ""
say "== rollforward gate, cut ${CUT} =="
# shellcheck disable=SC2086
env ${ENVARGS} bash "${REPO_ROOT}/bin/rollforward_gate.sh" --cut "$CUT"
rc=$?

if [ "$KEEP" = "1" ]; then
    say ""
    say "worktrees kept at ${WORKROOT} (OSTLER_ROLLFORWARD_KEEP=1)"
else
    while IFS='|' read -r _v dirname; do
        [ -n "${dirname:-}" ] || continue
        src="${DEVROOT}/${dirname}"
        git -C "$src" worktree remove --force "${WORKROOT}/${dirname}" 2>/dev/null || true
    done <<EOF
${SIBLINGS}
EOF
    rm -rf "$WORKROOT" 2>/dev/null
fi

exit "$rc"
