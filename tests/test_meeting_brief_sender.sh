#!/usr/bin/env bash
#
# tests/test_meeting_brief_sender.sh
#
# Locks install.sh's pre-meeting brief sender wiring:
#
#   1. install.sh emits a com.ostler.meeting-brief-sender LaunchAgent
#      plist.
#   2. The plist polls every 600 s (10 min). Anything tighter risks
#      WhatsApp rate-limiting; anything looser misses meetings.
#   3. The bin script ${OSTLER_DIR}/bin/ostler-meeting-brief-sender
#      exists, polls /api/v1/meeting/upcoming, and short-circuits
#      on degraded responses.
#   4. The sent-briefs SQLite cache lives at
#      ~/.ostler/state/sent_briefs.db (idempotency).
#   5. The success message is sourced from the strings catalogue,
#      not inlined (Rule 0.9).
#
# Why these axes matter:
#   - LaunchAgent label drift breaks ostler-uninstall.
#   - Interval drift below 60 s burns WhatsApp Web's session.
#   - Missing degraded check would ship stale meetings on People-
#     Graph blips.
#   - Missing idempotency cache would re-spam every 10 min.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── Bin script + LaunchAgent label ───────────────────────────────
if ! grep -q 'ostler-meeting-brief-sender' "$INSTALL_SCRIPT"; then
    echo "FAIL [bin-script-missing]: install.sh does not install ostler-meeting-brief-sender" >&2
    exit 1
fi
echo "PASS: install.sh installs ostler-meeting-brief-sender"

if ! grep -q 'com\.ostler\.meeting-brief-sender' "$INSTALL_SCRIPT"; then
    echo "FAIL [plist-label]: LaunchAgent label drift" >&2
    exit 1
fi
echo "PASS: LaunchAgent label is com.ostler.meeting-brief-sender"

# ── Poll interval ────────────────────────────────────────────────
# StartInterval must be 600 (10 minutes). Drift below 60 s burns
# WhatsApp Web's session.
if ! grep -qE '<integer>600</integer>' "$INSTALL_SCRIPT"; then
    echo "FAIL [interval-600]: StartInterval is not 600 s (10 min)" >&2
    exit 1
fi
echo "PASS: StartInterval is 600 s (10 min)"

# ── Hub endpoint ─────────────────────────────────────────────────
if ! grep -q '/api/v1/meeting/upcoming' "$INSTALL_SCRIPT"; then
    echo "FAIL [hub-endpoint]: bin script does not call /api/v1/meeting/upcoming" >&2
    exit 1
fi
echo "PASS: bin script polls /api/v1/meeting/upcoming"

# ── Degraded short-circuit ───────────────────────────────────────
# The bin script must check the `degraded` flag from the hub
# response and skip delivery rather than emitting stale messages.
if ! grep -q 'degraded' "$INSTALL_SCRIPT" || \
   ! grep -q 'skip: hub degraded' "$INSTALL_SCRIPT"; then
    echo "FAIL [degraded-check]: bin script does not short-circuit on degraded hub response" >&2
    exit 1
fi
echo "PASS: bin script short-circuits on degraded hub response"

# ── Idempotency cache ────────────────────────────────────────────
if ! grep -q 'sent_briefs\.db' "$INSTALL_SCRIPT"; then
    echo "FAIL [idempotency-cache]: bin script does not use sent_briefs.db" >&2
    exit 1
fi
echo "PASS: bin script uses sent_briefs.db for idempotency"

# ── Catalogue lift (Rule 0.9) ────────────────────────────────────
# The success message must reference a MSG_* key, not be inlined.
if ! grep -qE 'ok "\$MSG_OK_MEETING_BRIEF_SENDER_INSTALLED"' "$INSTALL_SCRIPT"; then
    echo "FAIL [catalogue-lift]: success message is not catalogue-keyed" >&2
    exit 1
fi
echo "PASS: success message is catalogue-keyed"

if [[ -f "$STRINGS" ]]; then
    if ! grep -q 'MSG_OK_MEETING_BRIEF_SENDER_INSTALLED=' "$STRINGS"; then
        echo "FAIL [catalogue-missing]: MSG_OK_MEETING_BRIEF_SENDER_INSTALLED missing from strings catalogue" >&2
        exit 1
    fi
    echo "PASS: MSG_OK_MEETING_BRIEF_SENDER_INSTALLED present in strings catalogue"
fi

# ── Quiet hours guard ────────────────────────────────────────────
# Default 07:00 - 21:00. The script should not ship briefs at 3am.
if ! grep -q 'QUIET_START' "$INSTALL_SCRIPT" || \
   ! grep -q 'QUIET_END' "$INSTALL_SCRIPT"; then
    echo "FAIL [quiet-hours]: bin script does not implement a quiet-hours guard" >&2
    exit 1
fi
echo "PASS: bin script implements quiet-hours guard"

# ── Port defaults match what the installer actually binds ────────
# The sender's tests all set OSTLER_HUB_HOST / OSTLER_ASSISTANT_URL, so a
# wrong DEFAULT is invisible to them and only shows on a customer Mac as a
# brief that never arrives. Compare each default against its producer:
#   HUB_HOST      -> the ical-server plist's OSTLER_API_PORT
#   ASSISTANT_URL -> the [gateway] port the installer writes (/announce lives there)
hub_default_port="$(sed -n 's/^HUB_HOST="\${OSTLER_HUB_HOST:-http:\/\/[^:]*:\([0-9]*\)}"$/\1/p' "$INSTALL_SCRIPT")"
asst_default_port="$(sed -n 's/^ASSISTANT_URL="\${OSTLER_ASSISTANT_URL:-http:\/\/[^:]*:\([0-9]*\)}"$/\1/p' "$INSTALL_SCRIPT")"
ical_port="$(awk '/<key>OSTLER_API_PORT<\/key>/{getline; gsub(/[^0-9]/,""); print; exit}' "$INSTALL_SCRIPT")"
gateway_port="$(sed -n 's/^ *echo "port = \([0-9]*\)"$/\1/p' "$INSTALL_SCRIPT" | head -1)"
for v in hub_default_port asst_default_port ical_port gateway_port; do
    if [ -z "${!v}" ]; then
        echo "CANNOT-RUN [port-defaults]: could not read $v from install.sh" >&2
        exit 2
    fi
done
if [ "$hub_default_port" != "$ical_port" ]; then
    echo "FAIL [hub-port]: sender HUB_HOST defaults to :$hub_default_port but the ical-server binds :$ical_port" >&2
    exit 1
fi
echo "PASS: sender HUB_HOST default :$hub_default_port is the ical-server port"
if [ "$asst_default_port" != "$gateway_port" ]; then
    echo "FAIL [announce-port]: sender ASSISTANT_URL defaults to :$asst_default_port but /announce is on the gateway :$gateway_port" >&2
    exit 1
fi
echo "PASS: sender ASSISTANT_URL default :$asst_default_port is the gateway port"

echo ""
echo "All meeting-brief-sender wiring checks passed."
