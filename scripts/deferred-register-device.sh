#!/usr/bin/env bash
# deferred-register-device.sh
#
# Hub-side scheduler for the device registration retried by the
# installer when the install-time POST to /register-device failed
# with a network error. Invoked by launchd on a 1-hour cadence
# (com.ostler.deferred-register-device.plist) and idempotent.
#
# Reads:    ~/.ostler/state/pending_registration.json
# Writes:   ~/.ostler/state/fingerprint.txt          (on 200)
#           ~/.ostler/state/registration_warning.txt (on 409 cap)
# Deletes:  ~/.ostler/state/pending_registration.json (on 200 or 409)
#
# Behaviour:
#   - Pending queue absent or empty: exit 0, no-op.
#   - 200 OK: cache the fingerprint, clear the queue, log success.
#   - 409 Conflict (cap reached): write a warning file for the
#     Doctor surface to read, clear the queue. The customer already
#     installed (fail-open) but their slot was never opened; the
#     Doctor banner explains that this Mac will not register without
#     a manual reset.
#   - 410 Gone (revoked/refunded): clear the queue (no point
#     retrying), log error.
#   - Network / 5xx / unparseable: leave the queue in place and
#     return 0 so launchd does not throttle us. The next scheduled
#     fire will try again.
#
# The Worker contract is documented at
#   CM050/appcast-server/docs/REGISTER_DEVICE.md.

set -euo pipefail

OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"
STATE_DIR="${OSTLER_DIR}/state"
PENDING="${STATE_DIR}/pending_registration.json"
FP_CACHE="${STATE_DIR}/fingerprint.txt"
WARNING="${STATE_DIR}/registration_warning.txt"
LOG_DIR="${OSTLER_DIR}/logs"
LOG_FILE="${LOG_DIR}/deferred-register-device.log"
ENDPOINT="${OSTLER_REGISTER_ENDPOINT:-https://appcast.ostler.ai/register-device}"

mkdir -p "${LOG_DIR}"

log() {
    printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "${LOG_FILE}"
}

# Pending queue absent → no-op.
if [ ! -f "${PENDING}" ]; then
    exit 0
fi

# Parse pending. We use python3 because it ships with macOS and
# avoids depending on jq, which is not present by default.
PARSE_OUT=$(/usr/bin/env python3 - "${PENDING}" <<'PYEOF' || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    license_id = data.get("license_id", "")
    fingerprint = data.get("fingerprint", "")
    if not license_id or not fingerprint:
        sys.exit(2)
    # tab-separated so a shell read can pick them up cleanly.
    print(f"{license_id}\t{fingerprint}")
except Exception as exc:
    print(f"ERR\t{exc}", file=sys.stderr)
    sys.exit(2)
PYEOF
)

if [ -z "${PARSE_OUT}" ]; then
    log "pending registration queue malformed; removing"
    rm -f "${PENDING}"
    exit 0
fi

LICENSE_ID="$(printf '%s' "${PARSE_OUT}" | awk -F'\t' '{print $1}')"
FINGERPRINT="$(printf '%s' "${PARSE_OUT}" | awk -F'\t' '{print $2}')"

# Build the JSON request body via python3 to avoid quoting hazards.
REQ_BODY=$(/usr/bin/env python3 - <<PYEOF
import json
print(json.dumps({"license_id": "${LICENSE_ID}", "fingerprint": "${FINGERPRINT}"}))
PYEOF
)

# curl: capture body + http status code on a single line, fail-silent
# so we can interpret 4xx / 5xx ourselves rather than have curl exit
# non-zero.
TMP_RESPONSE=$(mktemp -t ostler-register-response.XXXXXX)
trap 'rm -f "${TMP_RESPONSE}"' EXIT

HTTP_CODE=$(
    /usr/bin/curl --silent --show-error \
        --max-time 30 \
        --request POST \
        --header "Content-Type: application/json" \
        --header "User-Agent: OstlerDeferredRegister/1" \
        --data "${REQ_BODY}" \
        --output "${TMP_RESPONSE}" \
        --write-out "%{http_code}" \
        "${ENDPOINT}" 2>>"${LOG_FILE}"
) || HTTP_CODE="000"

case "${HTTP_CODE}" in
    200)
        log "register-device 200 -- caching fingerprint, clearing queue"
        mkdir -p "${STATE_DIR}"
        printf '%s\n' "${FINGERPRINT}" > "${FP_CACHE}"
        chmod 600 "${FP_CACHE}"
        rm -f "${PENDING}" "${WARNING}"
        exit 0
        ;;
    409)
        # ------------------------------------------------------------------
        # WALK-361-SIBLING (2026-09-02): THIS ARM USED TO BE A DEAD END.
        #
        # It wrote `cap_reached <timestamp>` into registration_warning.txt and
        # exited 0. That file was READ BY NOTHING -- the only other mention of
        # it anywhere in the repo was a COMMENT in FingerprintState.swift
        # describing a Doctor banner that was never built. So a customer whose
        # deferred retry hit the cap was told nothing, by anything, ever. The
        # install-time path does surface this properly (DeviceLimitReachedView);
        # only this deferred path was silent.
        #
        # Now it does three things, and the last one is the one that reaches a
        # human without depending on any other repo shipping first:
        #   1. a STRUCTURED record, matching the ~/.ostler/state/*.json
        #      convention the Doctor already reads elsewhere;
        #   2. the legacy plain-text file, still written, so an older reader
        #      is not broken by this change;
        #   3. a macOS notification, because a state file nobody opens is the
        #      same silence in a different format.
        # ------------------------------------------------------------------
        NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        # Pull the counts out of the Worker's 409 body. register-device echoes
        # max_hardware_fingerprints and registered_count (CM050
        # register-device.ts). Absent/unparseable -> -1, an explicit
        # "not known" that a reader can branch on. NEVER 0: a real zero and a
        # failed parse must not print identically.
        COUNTS=$(/usr/bin/env python3 - "${TMP_RESPONSE}" <<'PYEOF' || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(f'{int(d.get("max_hardware_fingerprints", -1))}\t{int(d.get("registered_count", -1))}')
except Exception:
    print("-1\t-1")
PYEOF
)
        CAP_MAX="$(printf '%s' "${COUNTS}" | awk -F'\t' '{print $1}')"
        CAP_NOW="$(printf '%s' "${COUNTS}" | awk -F'\t' '{print $2}')"
        [ -n "${CAP_MAX}" ] || CAP_MAX="-1"
        [ -n "${CAP_NOW}" ] || CAP_NOW="-1"

        log "register-device 409 (cap reached: ${CAP_NOW}/${CAP_MAX} Macs) -- recording, notifying, clearing queue"
        mkdir -p "${STATE_DIR}"

        # 1. structured, for the Doctor.
        /usr/bin/env python3 - "${STATE_DIR}/registration_warning.json" \
            "${NOW}" "${CAP_MAX}" "${CAP_NOW}" <<'PYEOF' || true
import json, sys
path, now, cap_max, cap_now = sys.argv[1:5]
with open(path, "w") as f:
    json.dump({
        "state": "cap_reached",
        "observed_at": now,
        "max_hardware_fingerprints": int(cap_max),
        "registered_count": int(cap_now),
        "source": "deferred-register-device",
        "customer_message": (
            "This Mac could not be added to your Ostler licence because the "
            "licence is already in use on the maximum number of Macs. Ostler "
            "still works here, but this Mac is not registered. Remove a Mac "
            "you no longer use, or get in touch, and it will register itself."
        ),
    }, f, indent=2)
PYEOF
        chmod 600 "${STATE_DIR}/registration_warning.json" 2>/dev/null || true

        # 2. legacy plain-text, unchanged shape, so nothing that reads the old
        #    file starts failing because we added a better one beside it.
        printf 'cap_reached %s\n' "${NOW}" > "${WARNING}"
        chmod 600 "${WARNING}"

        # 3. tell the human. Best-effort: on a box where osascript is
        #    unavailable or notifications are muted this is a no-op, which is
        #    why it is the THIRD mechanism and not the only one.
        #
        #    System Events is deliberately NOT used here -- see WALK-361.
        #    `display notification` addresses no target application, so it
        #    raises no Apple Events consent dialog.
        #
        #    ⚠️ BOUNDED. This runs inside a launchd agent. An osascript that
        #    blocks (no Aqua session, a wedged notification centre, a login
        #    window) would hold the job open indefinitely and the agent would
        #    look "running" forever. macOS has no timeout(1), and
        #    _ostler_run_with_deadline lives in install.sh which this
        #    standalone script does not source -- so the bound is inline.
        _notify_bounded() {
            osascript -e "$1" >/dev/null 2>&1 &
            _osa=$!
            ( sleep "${OSTLER_NOTIFY_TIMEOUT_S:-10}"; kill -9 "${_osa}" 2>/dev/null ) >/dev/null 2>&1 &
            _watchdog=$!
            wait "${_osa}" 2>/dev/null || true
            kill "${_watchdog}" 2>/dev/null || true
        }
        _notify_bounded 'display notification "This Mac is not registered: your licence is already on the maximum number of Macs. Ostler still works here." with title "Ostler licence"'

        rm -f "${PENDING}"
        # Exit 0 so launchd does not retry this hopeless case; the records
        # above are the durable signal.
        exit 0
        ;;
    404)
        log "register-device 404 (licence not found) -- clearing queue"
        rm -f "${PENDING}"
        exit 0
        ;;
    410)
        log "register-device 410 (revoked/refunded) -- clearing queue"
        rm -f "${PENDING}"
        exit 0
        ;;
    400)
        log "register-device 400 (bad request) -- clearing queue to avoid loop"
        rm -f "${PENDING}"
        exit 0
        ;;
    "000")
        log "register-device transport failed (curl could not reach ${ENDPOINT}) -- will retry next fire"
        exit 0
        ;;
    *)
        log "register-device unexpected status ${HTTP_CODE} -- will retry next fire"
        exit 0
        ;;
esac
