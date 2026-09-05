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

# --- setting 2: the service token, compared by HASH, never by value ---------
#
# This is the instance that did the most damage on 2026-08-26 and the one the
# require_pairing comparison alone does NOT catch: ical-server held a
# pre-rotation token while the plist and the secrets file both held the new one.
# Every non-public /api/v1 route 401'd for every correctly configured client.
#
# NEVER PRINT THE VALUE. A walk log lands in support bundles. Only the first 12
# hex of a sha256 is emitted -- enough to say "same" or "different", useless to
# anyone who obtains the log.
#
# NORMALISE THE BYTES BEFORE HASHING, and this is not fussiness. Rehearsing this
# comparison I hashed the live side through `sed | shasum`, which appends sed's
# trailing newline, and the disk side through `tr -d`, which does not. The SAME
# token hashed to 0fa1a5d2 and caa3d247, and for a moment it read as a fresh
# security drift on a box I had already fixed. A probe that reports a false
# drift on a security setting burns its credibility the first time it fires.
# Hash the exact bytes, both sides, with printf '%s'.
token_sha_live() {
    # `-u "$(id -u)"`: bare `pgrep -f` matches every account's processes. This
    # line then reads a process ENVIRONMENT, so an unscoped match points
    # `ps -Eww` at a pid we do not own -- which the kernel refuses, yielding an
    # empty token and a CANNOT-RUN blamed on the wrong thing. Scope to this
    # account so the probe reads OUR service, or honestly finds none.
    _t="$(box_run "P=\$(pgrep -u \"\$(id -u)\" -f ical-server.py | head -1); ps -Eww -p \$P 2>/dev/null | tr ' ' '\\n' | grep -m1 '^PWG_SERVICE_TOKEN=' | sed 's/^PWG_SERVICE_TOKEN=//'")"
    if [ -z "$_t" ]; then printf 'UNAVAILABLE'; return; fi
    printf '%s' "$_t" | shasum -a 256 | cut -c1-12
}

token_sha_disk() {
    _t="$(box_run "cat \$HOME/.ostler/secrets/service_token 2>/dev/null | tr -d '\\r\\n'")"
    if [ -z "$_t" ]; then printf 'UNAVAILABLE'; return; fi
    printf '%s' "$_t" | shasum -a 256 | cut -c1-12
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach ${OSTLER_BOX_HOST:-this machine} over ssh; nothing was compared"
    fi

    _disk="$(read_disk_require_pairing)"
    _live="$(read_live_require_pairing)"
    probe_note "require_pairing on disk : ${_disk}"
    probe_note "require_pairing live    : ${_live}"
    _v1="$(judge_drift require_pairing "$_disk" "$_live")"

    _tdisk="$(token_sha_disk)"
    _tlive="$(token_sha_live)"
    probe_note "service token on disk   : ${_tdisk}  (sha256/12, value never printed)"
    probe_note "service token live      : ${_tlive}"
    _v2="$(judge_drift service_token "$_tdisk" "$_tlive")"

    probe_examined "2 settings compared (require_pairing, service_token), 2 of 2 sides needed each" "disk config vs the live processes enforcing it"

    # A DRIFT anywhere outranks an UNREADABLE anywhere. A proven disagreement is
    # a finding; an unreadable second setting only costs coverage. Report the
    # worst thing actually ESTABLISHED, never the average of the two.
    _verdict=AGREE
    case "${_v1}|${_v2}" in
        *DRIFT*)      _verdict=DRIFT ;;
        *UNREADABLE*) _verdict=UNREADABLE ;;
    esac

    case "$_verdict" in
        UNREADABLE)
            probe_cannot_run "one side of a comparison was unreadable (require_pairing disk='${_disk}' live='${_live}' [${_v1}]; service_token disk='${_tdisk}' live='${_tlive}' [${_v2}]). A comparison needs BOTH; one side alone cannot disagree with itself."
            ;;
        DRIFT)
            probe_fail "a running process is NOT using the config on disk. require_pairing disk='${_disk}' live='${_live}' [${_v1}]; service_token disk='${_tdisk}' live='${_tlive}' [${_v2}]. The file is not what is being enforced. A restart that re-reads config is the remedy; note that launchctl kickstart restarts from the LOADED definition and will not pick up a rewritten plist."
            ;;
        AGREE)
            probe_pass "both settings match the config on disk (require_pairing=${_live}, service_token sha ${_tlive})"
            ;;
        *)
            probe_fail "adjudicator returned an unknown verdict '${_verdict}' -- treating as failure rather than guessing"
            ;;
    esac
}

self_test() {
    probe_examined "6 crafted comparisons" "synthetic disk/live pairs adjudicated by the live judge (no box touched)"

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

    # 5+6. THE FALSE POSITIVE THAT NEARLY GOT REPORTED AS A SECURITY DRIFT.
    #      Two hashes of the SAME token differ if one side carries a trailing
    #      newline. The readers normalise with printf '%s'; these arms prove the
    #      normalisation is load-bearing, so deleting it turns this probe into a
    #      false-alarm generator on a security setting.
    _n1="$(printf '%s' "abc" | shasum -a 256 | cut -c1-12)"
    _n2="$(printf '%s' "abc" | shasum -a 256 | cut -c1-12)"
    if [ "$(judge_drift service_token "$_n1" "$_n2")" != "AGREE" ]; then
        probe_pass "FALSE POSITIVE: identically-normalised hashes of one value were reported as drift."
    fi
    _n3="$(printf '%s\n' "abc" | shasum -a 256 | cut -c1-12)"
    if [ "$_n1" = "$_n3" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a trailing newline made no difference to the hash, so the normalisation arm proves nothing."
    fi

    probe_fail "negative controls fired on all 6 crafted comparisons (drift caught, agreement kept, case-difference forgiven, missing side refused, trailing-newline false positive excluded)"
}

probe_main "$@"
