# shellcheck shell=bash
# lib/companion_unpair.sh -- the walk leaves no synthetic companion paired.
#
# Walk #27: after a walk, Doctor read "Paired" because the pairing probes
# (pairing_recovers_without_a_repair_storm, conversation_capture_seed, the
# 106c acceptance gate) pair a SOFTWARE passkey through the real
# /auth/pair/register flow and nothing ever unpaired it. The gateway's
# companion_paired is true while devices.db has a row OR
# workspace/security/passkey.json exists (zeroclaw-gateway api.rs), so both
# have to go.
#
# companion_walk_baseline  (before any probe pairs) records the walk start and
#                          whether a passkey file already existed.
# companion_walk_unpair    (after every measurement) revokes, through the
#                          Hub's own DELETE /api/devices/{id}, every device
#                          paired at or after the walk start, removes the
#                          passkey file only if the walk found none, and
#                          prints the end state read from /health.
_CU_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -F companion_unpair_box_snippet >/dev/null || . "${_CU_HERE}/companion_pair.sh"

_cu_box() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes "$OSTLER_BOX_HOST" "$1"
    else
        bash -lc "$1"
    fi
}

OSTLER_COMPANION_PASSKEY_REL=".ostler/assistant-config/workspace/security/passkey.json"

companion_walk_baseline() {
    local out
    if [ -n "${OSTLER_COMPANION_WALK_START:-}" ]; then
        # A caller that pairs earlier (an early pass) set it first; keep theirs.
        printf -- '--- COMPANION BASELINE: walk start %s (set by the caller), passkey %s ---\n\n' \
            "$OSTLER_COMPANION_WALK_START" "${OSTLER_COMPANION_PASSKEY_BEFORE:-<unread>}"
        return 0
    fi
    out="$(_cu_box "date +%s; [ -f \"\$HOME/${OSTLER_COMPANION_PASSKEY_REL}\" ] && echo passkey=present || echo passkey=absent" 2>/dev/null)"
    OSTLER_COMPANION_WALK_START="$(printf '%s\n' "$out" | sed -n '1p' | tr -cd '0-9')"
    OSTLER_COMPANION_PASSKEY_BEFORE="$(printf '%s\n' "$out" | sed -n 's/^passkey=//p')"
    export OSTLER_COMPANION_WALK_START OSTLER_COMPANION_PASSKEY_BEFORE
    printf -- '--- COMPANION BASELINE: walk start %s, passkey %s before the walk ---\n\n' \
        "${OSTLER_COMPANION_WALK_START:-<unread>}" "${OSTLER_COMPANION_PASSKEY_BEFORE:-<unread>}"
}

companion_walk_unpair() {
    printf -- '--- COMPANION: unpairing the walk'"'"'s synthetic companion ---\n'
    if [ -z "${OSTLER_COMPANION_WALK_START:-}" ]; then
        printf '    CANNOT-RUN: no walk start was recorded, so the walk'"'"'s devices cannot be told from the owner'"'"'s. Nothing revoked.\n\n'
        return 0
    fi
    local rmpk=0 out
    [ "${OSTLER_COMPANION_PASSKEY_BEFORE:-}" = "absent" ] && rmpk=1
    out="$(_cu_box "$(companion_unpair_box_snippet "$OSTLER_COMPANION_WALK_START" "$rmpk")
printf '%s\n' \"\$CU_JSON\"" 2>&1)"
    OSTLER_COMPANION_UNPAIR_JSON="$(printf '%s\n' "$out" | tail -1)"
    export OSTLER_COMPANION_UNPAIR_JSON
    printf '%s' "$OSTLER_COMPANION_UNPAIR_JSON" | /usr/bin/python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    print("    CANNOT-RUN: the unpair helper printed no result"); sys.exit(0)
print("    revoked %s walk device(s), %s left; passkey removed: %s" % (r.get("revoked"), r.get("left_since"), r.get("passkey_removed")))
print("    END STATE (/health): companion_paired=%s paired=%s" % (r.get("companion_paired"), r.get("paired")))
if r.get("companion_paired") is False:
    print("    ok   Doctor will not read Paired from the walk")
elif r.get("companion_paired") is True:
    print("    FAIL the box still reads paired after the walk cleanup (%s)" % r.get("detail"))
else:
    print("    CANNOT-RUN: /health not read (%s)" % r.get("detail"))
'
    printf '\n'
}
