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

echo ""
echo "All meeting-brief-sender wiring checks passed."
