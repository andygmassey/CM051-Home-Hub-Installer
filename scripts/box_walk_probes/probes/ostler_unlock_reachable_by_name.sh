#!/usr/bin/env bash
# probes/ostler_unlock_reachable_by_name.sh
# ============================================================================
# QUESTION: if a customer opens Terminal and types `ostler-unlock`, does
#           anything run -- or does the shell say "command not found"?
#
# THE DEFECT THIS EXISTS FOR. `ostler-unlock` is the v1.0 recovery-key
# redeemer: it works (proven -- `--help` runs, and a wrong key is correctly
# rejected), but pyproject.toml only installs its console_script into the
# owning venv's OWN bin/:
#
#     $HOME/.ostler/.venv/bin/ostler-unlock
#     $HOME/.ostler/services/cm048/.venv/bin/ostler-unlock
#
# neither of which is ever on a customer's PATH. Every prior check asked "is
# the file present" and answered yes, because it is -- at a path nobody types.
# This probe asks the only question that matters: can the bare command name
# resolve, THE WAY A CUSTOMER ACTUALLY TYPES IT.
#
# WHY `zsh -ilc`, NOT box_run's DEFAULT. box_run's local branch runs
# `bash -lc`, and a plain `ssh box "cmd"` is neither login nor interactive.
# install.sh writes the customer's PATH addition to `~/.zshrc`, and zsh only
# sources `.zshrc` for an INTERACTIVE shell -- login alone does not do it,
# MEASURED here (see PR description): `zsh -lc 'echo $FOO'` with FOO set only
# in .zshrc prints nothing; `zsh -ilc` prints it. Terminal.app opens a
# login+interactive shell by default, so `-ilc` is the invocation that
# actually matches what a customer's Terminal window runs. Testing with plain
# `box_run` here would test the wrong shell and could PASS on a box where a
# real customer's Terminal still says command not found.
#
# THE REJECTION, NOT THE UNLOCK. A deliberately WRONG recovery key of the
# right shape is offered on stdin. A working redeemer that is actually reached
# answers "Incorrect recovery key" and exits 1 -- it can only say that after
# loading THIS box's keychain and checking against it, so the rejection is
# positive proof the command ran, not an absence. No real key is used, read,
# logged or compared, and success (an actual unlock) is never required or
# attempted.
#
# THREE OUTCOMES:
#   PASS         zsh ran ostler-unlock and it rejected the wrong key by name.
#   FAIL         zsh said command not found -- the exact customer-facing defect.
#   CANNOT-RUN   no security config on this box at all (no keychain.json), or
#                the run produced neither signal (inconclusive).
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="ostler_unlock_reachable_by_name"
PROBE_QUESTION="does \`ostler-unlock\` resolve by bare name in the shell a customer's Terminal actually opens?"

KEYCHAIN="${OSTLER_KEYCHAIN_PATH:-\$HOME/.ostler/security/keychain.json}"

# _classify <rc> <notfound-count> <incorrect-count> -> verdict word.
# THE ONE DECISION FUNCTION, used by run_probe AND self_test, so a mutation to
# the adjudication breaks both in the same commit.
_classify() {
    _rc="$1"; _nf="${2:-0}"; _ik="${3:-0}"
    if [ "$_nf" -gt 0 ]; then
        printf 'FAIL-NOT-ON-PATH'; return
    fi
    if [ "$_rc" -eq 1 ] && [ "$_ik" -gt 0 ]; then
        printf 'PASS-REJECTED'; return
    fi
    printf 'CANNOT-RUN-INCONCLUSIVE'
}

run_probe() {
    box_reachable || probe_cannot_run "box ${OSTLER_BOX_HOST:-<local>} is not reachable over ssh. Nothing was inspected, and that is not a pass."

    _has_kc="$(box_run "test -f ${KEYCHAIN} && echo YES || echo NO")"
    case "$_has_kc" in
        YES) : ;;
        NO)  probe_examined 0 "security configs (no keychain on this box)"
             probe_cannot_run "no ${KEYCHAIN} on ${OSTLER_BOX_HOST:-this machine}. With no security config at all there is nothing a recovery-key redeemer could be reached FOR. That is coverage absent, not a clean bill." ;;
        *)   probe_cannot_run "could not determine whether ${KEYCHAIN} exists -- the reader returned '${_has_kc}'. An answer that is neither YES nor NO has established nothing." ;;
    esac

    # ⛔ NO SECRET IS READ, TYPED, LOGGED OR COMPARED. This literal is an
    # obviously-fake key of the right shape; it exists only to be rejected.
    _out="$(box_run "zsh -ilc '
        _e=\$(mktemp -t ostler-probe-unlock-name) || exit 90
        { printf \"AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GG\\n\" | ostler-unlock --recovery-key --secret-file - >/dev/null; } 2>\"\$_e\"
        _rc=\$?
        _nf=\$(grep -ac \"command not found\" \"\$_e\" 2>/dev/null || echo 0)
        _ik=\$(grep -ac \"Incorrect recovery key\" \"\$_e\" 2>/dev/null || echo 0)
        rm -f \"\$_e\"
        printf \"rc=%s nf=%s ik=%s\\n\" \"\$_rc\" \"\$_nf\" \"\$_ik\"
    '")"

    _rc="$(printf '%s' "$_out" | sed -n 's/.*rc=\([0-9-]*\).*/\1/p' | tail -1)"
    _nf="$(printf '%s' "$_out" | sed -n 's/.*nf=\([0-9]*\).*/\1/p' | tail -1)"
    _ik="$(printf '%s' "$_out" | sed -n 's/.*ik=\([0-9]*\).*/\1/p' | tail -1)"
    case "$_rc" in ''|*[!0-9-]*) _rc=-1 ;; esac
    case "$_nf" in ''|*[!0-9]*) _nf=0 ;; esac
    case "$_ik" in ''|*[!0-9]*) _ik=0 ;; esac

    probe_examined 1 "invocation of \`ostler-unlock\` by bare name, in an interactive login zsh (the shell a customer's Terminal actually opens)"
    probe_note "raw: ${_out:-<no output>}"

    _verdict="$(_classify "$_rc" "$_nf" "$_ik")"
    case "$_verdict" in
        PASS-REJECTED)
            probe_pass "ostler-unlock resolved BY BARE NAME in an interactive login zsh and rejected a deliberately wrong recovery key (rc=1, 'Incorrect recovery key'), which it can only say after loading this box's own keychain. No real key was used." ;;
        FAIL-NOT-ON-PATH)
            probe_fail "🔴 \`ostler-unlock\` IS NOT ON THIS CUSTOMER'S PATH. An interactive login zsh -- the shell Terminal.app actually opens -- said 'command not found' for the exact command a customer is told to run with their recovery key. The redeemer may work perfectly from inside a venv; nobody can reach it by typing its name." ;;
        *)
            probe_cannot_run "the invocation produced neither a clean rejection nor a command-not-found (rc=${_rc}, notfound-markers=${_nf}, incorrect-key-markers=${_ik}). Neither 'reachable and working' nor 'not on PATH' was established." ;;
    esac
}

self_test() {
    # Drives the DECISION, not a real box. Three arms over the three states.
    fails=0
    _t() { got="$(_classify "$1" "$2" "$3")"; if [ "$got" = "$4" ]; then printf 'arm OK: rc=%s nf=%s ik=%s -> %s\n' "$1" "$2" "$3" "$got"; else printf 'arm BROKEN: rc=%s nf=%s ik=%s -> %s, wanted %s\n' "$1" "$2" "$3" "$got" "$4"; fails=$((fails+1)); fi; }

    _t 127 1 0 FAIL-NOT-ON-PATH
    _t   1 0 1 PASS-REJECTED
    _t   2 0 0 CANNOT-RUN-INCONCLUSIVE
    # THE OUTRANK ARM: a run that somehow produced BOTH a not-found marker and
    # a rejection marker must still FAIL. A shell that could not resolve the
    # name did not run the real redeemer, whatever else appears in its output.
    _t 127 1 1 FAIL-NOT-ON-PATH

    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed. This probe cannot demonstrate a FAIL, so its real result must not be trusted."
    fi
    probe_examined 4 "self-test arms (not-on-path / rejected-by-name / inconclusive / not-found outranks a stray rejection marker)"
    probe_fail "negative control behaved correctly on all 4 arms: a command-not-found rc=127 FAILs, a clean rc=1 rejection PASSes, an inconclusive rc/marker pair is CANNOT-RUN, and a not-found marker outranks a rejection marker rather than being masked by it"
}

probe_main "$@"
