#!/usr/bin/env bash
#
# tests/test_cx101_calendar_hydrate_path.sh
#
# Byte-walking regression test for CX-101 (calendar half):
# the hydrate phase pulls Calendar data via the local FDA path
# (ostler_fda.calendar -> calendar_events.json -> pwg_ingest.
# ingest_calendar) instead of via meeting_syncer + the localhost
# ical-server -> CalDAV path that required an iCloud app-specific
# password install.sh never captured.
#
# What the failure looked like (PRE-CX-101, must never recur):
#
#   1. install.sh's hydrate phase ran:
#         python -m meeting_syncer.syncer --api-url localhost:8089
#      against an ical-server that ran ~/.zeroclaw/ical-query.sh,
#      which required OSTLER_ICLOUD_USER + OSTLER_ICLOUD_APP_PASSWORD
#      in ~/.ostler/config/.env.
#   2. install.sh never prompted for either env var. The wrapper
#      hit `[[ -z "$creds" ]] && exit 0 with empty output`.
#   3. meeting_syncer parsed zero events.
#   4. install.sh emitted "No calendar events in the last 5 years"
#      on EVERY clean install, regardless of how full the customer's
#      calendar actually was.
#
# Post-CX-101 the hydrate path is: ostler_fda.calendar.extract_events
# -> calendar_events.json -> ostler_fda.pwg_ingest.ingest_calendar.
# No CalDAV. No app-password. Same shape as iMessage (which works).
#
# Axes covered:
#   1. install.sh's hydrate Calendar block calls ingest_calendar (or
#      ostler_fda.pwg_ingest) -- NOT meeting_syncer.syncer.
#   2. The since_days argument plumbs through OSTLER_HYDRATE_BACKFILL_DAYS
#      (5 years default) so the hydrate reads the full window, not
#      the Phase-3.7 onboarding 365-day window.
#   3. The hydrate writes calendar_events.json into
#      ~/.ostler/imports/fda/ (the canonical location ingest_calendar
#      reads from -- enforces the writer/reader contract).
#   4. State 2 wait-for-populate fires when accounts > 0 + cache empty.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# Locate the calendar hydration block. The header line is stable.
CAL_HEADER_LINE="$(grep -n '^# Calendar hydration' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "$CAL_HEADER_LINE" ]]; then
    failure "could not locate '# Calendar hydration' block header"
    echo "FAILED" >&2
    exit 1
fi

# Carve out the block: from header to the next major hydration block.
NEXT_HEADER_LINE="$(awk -v start="$CAL_HEADER_LINE" '
    NR > start && /^# (Email|WhatsApp|Browser|iMessage) hydration/ { print NR; exit }
' "$INSTALL_SH")"
if [[ -z "$NEXT_HEADER_LINE" ]]; then
    failure "could not locate end of Calendar hydration block"
    echo "FAILED" >&2
    exit 1
fi

CAL_BLOCK="$(sed -n "${CAL_HEADER_LINE},${NEXT_HEADER_LINE}p" "$INSTALL_SH")"

# Axis 1: meeting_syncer.syncer is GONE from the calendar block.
# (It can legitimately appear elsewhere in install.sh -- the Phase 3
# pipeline copy + the cm041/meeting_syncer dir bundle -- so we only
# enforce its absence inside the Calendar hydration block.)
if printf '%s' "$CAL_BLOCK" | grep -qE 'python.*-m meeting_syncer'; then
    failure "Calendar hydration block still invokes 'python -m meeting_syncer' -- CX-101 contract broken"
fi
if printf '%s' "$CAL_BLOCK" | grep -qE 'meeting_syncer\.syncer'; then
    failure "Calendar hydration block still references meeting_syncer.syncer -- CX-101 contract broken"
fi

# Axis 2: ingest_calendar (or its module path) IS present.
if ! printf '%s' "$CAL_BLOCK" | grep -qE 'ingest_calendar|pwg_ingest'; then
    failure "Calendar hydration block does not reference ingest_calendar / pwg_ingest -- FDA path missing"
fi

# Axis 3 (CX-106, DMG #48l, 2026-05-29): OSTLER_HYDRATE_CALENDAR_DAYS
# is used as the since_days parameter. Pre-CX-106 this axis required
# OSTLER_HYDRATE_BACKFILL_DAYS (5 years) but Studio retest of DMG #48k
# showed multi-year calendar reads blowing the 180s install-time
# wall-clock cap. CX-106 introduces a dedicated install-time window
# (90 days default) while the +12h fda-rerun LaunchAgent walks the
# 5-year history asynchronously. Either the new install-time var or
# the legacy 5-year var counts -- the contract is "the calendar
# hydration block uses a documented env var for since_days", not a
# specific name.
if ! printf '%s' "$CAL_BLOCK" | grep -qE 'OSTLER_HYDRATE_CALENDAR_DAYS|OSTLER_HYDRATE_BACKFILL_DAYS'; then
    failure "Calendar hydration block does not pass a documented backfill-days env var"
fi
if ! printf '%s' "$CAL_BLOCK" | grep -qE 'since_days=.{0,30}OSTLER_HYDRATE_(CALENDAR|BACKFILL)_DAYS'; then
    failure "Calendar hydration block does not plumb backfill days to extract_events since_days"
fi

# Axis 4: writer/reader contract -- calendar_events.json under
# ~/.ostler/imports/fda/ is written by the inline extractor block
# AND read by ingest_calendar(fda_dir). The block must reference
# imports/fda explicitly.
if ! printf '%s' "$CAL_BLOCK" | grep -qE 'imports/fda'; then
    failure "Calendar hydration block does not reference ~/.ostler/imports/fda/ -- writer/reader contract drift risk"
fi

# Axis 5: state-2 wait helper invocation for calendar.
if ! printf '%s' "$CAL_BLOCK" | grep -q '_three_state_wait_for_populate'; then
    failure "Calendar hydration block does not invoke _three_state_wait_for_populate for state 2"
fi
if ! printf '%s' "$CAL_BLOCK" | grep -q '"calendar"'; then
    failure "Calendar hydration block does not pass 'calendar' slug to the wait helper"
fi

if (( FAILED == 0 )); then
    echo "PASS: tests/test_cx101_calendar_hydrate_path.sh"
    exit 0
else
    echo "FAILED: tests/test_cx101_calendar_hydrate_path.sh" >&2
    exit 1
fi
