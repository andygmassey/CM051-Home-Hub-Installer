#!/usr/bin/env bash
# probes/running_config_matches_disk.sh
# ============================================================================
# QUESTION: is the daemon actually RUNNING the configuration that is on disk?
#
# WHY IT MATTERS. Writing a config file is not applying it. A long-lived daemon
# reads its config once and keeps serving what it read, so an edit -- or an
# installer upgrade -- can sit on disk indefinitely with nothing enforcing it
# and nothing reporting the gap.
#
# THIS IS NOT HYPOTHETICAL. Three instances on one box in a single day
# (2026-08-26):
#
#   ical-server   held a PRE-ROTATION service token while the plist and the
#                 secrets file both held the new one. Every non-public
#                 /api/v1 route 401'd for every correctly configured client,
#                 presenting as a client-side auth fault. Two box-walk probes
#                 were red because of it.
#
#   launchd       served a job definition loaded at FIRST INSTALL while
#                 install.sh had rewritten the plist. `launchctl bootstrap`
#                 no-ops on an already-loaded label, so the rewrite never took
#                 effect, and `kickstart -k` did not help either -- it restarts
#                 from the LOADED definition. (CM051 #1110)
#
#   daemon        reported require_pairing=FALSE while BOTH config.toml files
#                 on the box said `require_pairing = true`. A SECURITY CONTROL
#                 configured on and running off, because the daemon started
#                 2 hours before the file was last written.
#
# The third is why this probe exists. The first two were found by hand, one at a
# time, after they had already cost a walk. Nothing was watching for the class.
#
# WHAT IT COMPARES. Disk value vs LIVE value, per setting. Not "is the file
# right" and not "is the daemon up" -- those both pass while the two disagree.
#
# A LIE IN THE SAFE-LOOKING DIRECTION IS THE DANGEROUS ONE. A config that says a
# control is ON reads as reassurance. The running process is what enforces it.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/probe.sh"

PROBE_NAME="running_config_matches_disk"
PROBE_QUESTION="does the daemon enforce the configuration that is on disk, or one it read long ago?"

HEALTH_URL="${OSTLER_DAEMON_HEALTH_URL:-http://127.0.0.1:8000/health}"
CONFIG_PATH="${OSTLER_ASSISTANT_CONFIG:-\$HOME/.ostler/assistant-config/config.toml}"

# --- adjudicator -----------------------------------------------------------
# judge_drift <setting> <disk_value> <live_value> -> AGREE|DRIFT|UNREADABLE
#
# Separated from the readers so self_test can drive it with crafted values and
# demonstrate a FAIL without needing a box in a particular state. The probes
# that could never show a red are the ones nobody trusts.
judge_drift() {
    _setting="$1"; _disk="$2"; _live="$3"
    if [ -z "$_disk" ] || [ "$_disk" = "UNAVAILABLE" ] \
       || [ -z "$_live" ] || [ "$_live" = "UNAVAILABLE" ]; then
        printf 'UNREADABLE'
        return
    fi
    if [ "$_disk" = "$_live" ]; then printf 'AGREE'; else printf 'DRIFT'; fi
}

# Normalise TOML/JSON booleans so `true` and `True` are not reported as drift.
# A false positive here costs exactly as much trust as a false negative.
norm_bool() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        true)  printf 'true' ;;
        false) printf 'false' ;;
        *)     printf '%s' "$1" ;;
    esac
}

read_disk_require_pairing() {
    _v="$(box_run "grep -m1 -E '^[[:space:]]*require_pairing[[:space:]]*=' ${CONFIG_PATH} 2>/dev/null | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//'")"
    if [ -z "$_v" ]; then printf 'UNAVAILABLE'; else norm_bool "$_v"; fi
}

read_live_require_pairing() {
    _b="$(box_run "curl -sS -m 8 '${HEALTH_URL}' 2>/dev/null")"
    if [ -z "$_b" ]; then printf 'UNAVAILABLE'; return; fi
    _v="$(printf '%s' "$_b" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("UNAVAILABLE"); raise SystemExit
v = d.get("require_pairing")
print("UNAVAILABLE" if v is None else str(v))' 2>/dev/null)"
    if [ -z "$_v" ]; then printf 'UNAVAILABLE'; else norm_bool "$_v"; fi
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach ${OSTLER_BOX_HOST:-this machine} over ssh; nothing was compared"
    fi

    _disk="$(read_disk_require_pairing)"
    _live="$(read_live_require_pairing)"
    probe_note "require_pairing on disk : ${_disk}"
    probe_note "require_pairing live    : ${_live}"

    _verdict="$(judge_drift require_pairing "$_disk" "$_live")"
    probe_examined "1 setting compared (require_pairing), 2 of 2 sides needed" "disk config vs the daemon's live /health"

    case "$_verdict" in
        UNREADABLE)
            probe_cannot_run "one side of the comparison was unreadable (disk='${_disk}' live='${_live}'). A comparison needs BOTH; one side alone cannot disagree with itself."
            ;;
        DRIFT)
            probe_fail "the daemon is NOT running the config on disk: require_pairing is '${_disk}' in ${CONFIG_PATH} and '${_live}' in the live daemon. The file is not what is being enforced. A restart that re-reads config is the remedy; note that launchctl kickstart restarts from the LOADED definition and will not pick up a rewritten plist."
            ;;
        AGREE)
            probe_pass "the daemon enforces the config on disk (require_pairing=${_live} both sides)"
            ;;
        *)
            probe_fail "adjudicator returned an unknown verdict '${_verdict}' -- treating as failure rather than guessing"
            ;;
    esac
}

self_test() {
    probe_examined "4 crafted comparisons" "synthetic disk/live pairs adjudicated by the live judge (no box touched)"

    # 1. THE DEFECT. Config says the control is ON, the daemon runs it OFF.
    if [ "$(judge_drift require_pairing true false)" != "DRIFT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: true-on-disk vs false-live was not reported as DRIFT, so this probe could not have caught the 2026-08-26 require_pairing defect."
    fi

    # 2. Agreement must still be agreement, or the probe cries wolf forever.
    if [ "$(judge_drift require_pairing true true)" != "AGREE" ]; then
        probe_pass "POSITIVE CONTROL DID NOT FIRE: matching values were not reported as AGREE."
    fi

    # 3. Case difference is NOT drift. TOML writes `true`, JSON prints `True`.
    if [ "$(judge_drift require_pairing "$(norm_bool True)" "$(norm_bool true)")" != "AGREE" ]; then
        probe_pass "FALSE POSITIVE: 'True' and 'true' were reported as drift. A probe that cries wolf on formatting is a probe nobody reads."
    fi

    # 4. One side missing is UNREADABLE, never AGREE. This is the whole
    #    CANNOT-RUN-is-not-PASS rule, applied to itself.
    if [ "$(judge_drift require_pairing UNAVAILABLE false)" != "UNREADABLE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unreadable side adjudicated as a comparison. 'Could not look' would have been reported as a result."
    fi

    probe_fail "negative controls fired on all 4 crafted comparisons (drift caught, agreement kept, case-difference forgiven, missing side refused)"
}

probe_main "$@"
