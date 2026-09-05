#!/usr/bin/env bash
# A converge that was KILLED must still get its catch-up agent.
#
# WHY THIS EXISTS. MEASURED on the v1.0.71 walk box, 2026-09-05. Both markers
# were present at once:
#
#     ~/.ostler/state/dedupe-converge.done     PRESENT
#     ~/.ostler/state/dedupe-converge.killed   PRESENT
#         killed_at_utc=2026-09-05T15:17:16Z waited_s=300 budget_s=300
#
# They are not mutually exclusive: the converge can finish inside the 30s poll
# window while the budget check fires in the same iteration, so the subshell
# touches .done AND the kill path writes .killed.
#
# The guard tested ONLY .done, so it concluded the pass had completed and
# skipped the catch-up agent. On that box the post-walk QA suite then failed
# THREE probes on this one cause: people_count_agreement (oxigraph 1821 vs
# doctor 1905, off by 84), people_stores_reconcile (84 orphan vectors), and
# converge_kill_is_recorded. Those 84 people were split across two stores
# permanently, because the agent that exists to finish an interrupted converge
# was never installed.
#
# THE FOUR STATES ARE THE TEST. Three of them must install the agent and one
# must not, and the interesting one -- done AND killed -- is the state that
# actually occurred.
#
# THREE STATES OF VERDICT. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Pull the decision block out of a tree: the `if` that chooses whether to
# install the catch-up agent, through its closing `fi`.
_extract_guard() {
    awk '
        /if \[\[ ! -f "\$_DEDUPE_DONE_MARKER"/ { f = 1 }
        f { print }
        f && /^    fi$/ { exit }
    ' "$1"
}

# Drive the guard with a given pair of markers. Echoes "installed" or "skipped".
# The agent installer and `info` are stubbed, so nothing is created anywhere.
_drive() {
    local guard="$1" done_marker="$2" killed_marker="$3"
    local S="${WORK}/state"; rm -rf "$S"; mkdir -p "$S"
    [ "$done_marker"   = "yes" ] && : > "${S}/dedupe-converge.done"
    [ "$killed_marker" = "yes" ] && : > "${S}/dedupe-converge.killed"
    {
        printf '%s\n' '_DEDUPE_DONE_MARKER="'"${S}"'/dedupe-converge.done"'
        printf '%s\n' '_DEDUPE_KILLED_MARKER="'"${S}"'/dedupe-converge.killed"'
        printf '%s\n' 'MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="complete"'
        printf '%s\n' '_install_dedupe_catchup_agent() { echo installed; }'
        printf '%s\n' 'info() { echo skipped; }'
        printf '%s\n' "$guard"
    } > "${WORK}/g.sh"
    bash "${WORK}/g.sh" 2>/dev/null | tail -1
}

_GUARD="$(_extract_guard "$SUBJECT")"
[ -n "$_GUARD" ] || { echo "CANNOT-RUN: the catch-up guard was not found in ${SUBJECT}" >&2; exit 2; }

echo "== subject: this tree =="
#          .done  .killed  expected
for row in "no:no:installed:neither marker -- the pass plainly did not finish" \
           "yes:no:skipped:a clean completion needs no catch-up" \
           "yes:yes:installed:DONE **and** KILLED -- the state measured on the box" \
           "no:yes:installed:killed with no done marker"; do
    IFS=: read -r d k want why <<< "$row"
    got="$(_drive "$_GUARD" "$d" "$k")"
    if [ "$got" = "$want" ]; then
        ok "done=${d} killed=${k} -> ${got}   (${why})"
    else
        bad "done=${d} killed=${k} -> ${got}, expected ${want}   (${why})"
    fi
done

# -- NEGATIVE CONTROL, pinned to the tree that shipped the defect ------------
# 2fb58d1e is origin/main when this fix was written: the tree whose guard read
# only .done. Pinned to a sha, never a branch, or the control inverts on merge.
_CONTROL_SHA="2fb58d1e"
echo "== negative control: ${_CONTROL_SHA} (the tree that skipped the agent) =="
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi
_CGUARD="$(_extract_guard "$_ctl")"
[ -n "$_CGUARD" ] || { echo "CANNOT-RUN: no guard found in the control blob." >&2; exit 2; }

got="$(_drive "$_CGUARD" yes yes)"
case "$got" in
    skipped)   ok "control ${_CONTROL_SHA}: done+killed SKIPS the agent -- the measured defect reproduces" ;;
    installed) bad "control ${_CONTROL_SHA}: done+killed already installed the agent there, so this harness is not measuring the defect" ;;
    *)         bad "control ${_CONTROL_SHA}: unexpected result '${got}'" ;;
esac

# And the control must behave correctly on the state it DID handle, or its
# failure above could be any old breakage rather than this one.
got="$(_drive "$_CGUARD" no no)"
case "$got" in
    installed) ok "CONTROL ON THE CONTROL: the pre-fix tree DOES install when .done is absent, so the killed marker is the discriminator" ;;
    *)         bad "the pre-fix tree gives '${got}' even with no .done; the discriminator is not what this test claims" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
