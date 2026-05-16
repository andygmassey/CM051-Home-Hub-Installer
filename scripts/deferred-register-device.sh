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
        log "register-device 409 (cap reached) -- writing warning, clearing queue"
        mkdir -p "${STATE_DIR}"
        printf 'cap_reached %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${WARNING}"
        chmod 600 "${WARNING}"
        rm -f "${PENDING}"
        # Exit 0 so launchd does not retry this hopeless case; the
        # warning file is the Doctor surface's signal.
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
