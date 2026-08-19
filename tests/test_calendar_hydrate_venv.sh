#!/usr/bin/env bash
#
# tests/test_calendar_hydrate_venv.sh
#
# Byte-walking regression test for the 2026-06-03 Studio calendar-dead
# blocker: the two calendar hydrate heredocs imported ostler_fda but ran
# under the contact-syncer import-pipeline venv ($_HYDRATE_PIPELINE_PY =
# ~/.ostler/import-pipeline/.venv), which never has ostler_fda installed.
# Their imports raised ModuleNotFoundError, calendar silently never landed
# (Oxigraph calendar events = 0), and install.sh mislabelled the import
# crash as "Your Calendar app has not synced events yet."
#
# ostler_fda IS pip-installed into the email-ingest venv
# (~/.ostler/services/email-ingest/.venv), which the sibling browsing /
# imessage / people ingests already use. The fix repoints the two calendar
# steps at that same venv and stops swallowing a genuine extractor error as
# the empty-iCloud "not synced" state.
#
# What the failure looked like (PRE-FIX, must never recur):
#   1. the calendar extract + ingest heredocs run under $_HYDRATE_PIPELINE_PY
#      (the pipeline venv with no ostler_fda) -> ModuleNotFoundError
#   2. a raised ModuleNotFoundError/exception is rendered as the
#      "Calendar app has not synced" message, indistinguishable from a
#      genuinely empty iCloud calendar (silent-bail shape).
#
# All axes per locked memory feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_SH="${REPO_ROOT}/install.sh.strings.en-GB.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# Carve the Calendar hydration block (same boundaries as the CX-101 test).
CAL_HEADER_LINE="$(grep -n '^# Calendar hydration' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "$CAL_HEADER_LINE" ]]; then
    failure "could not locate '# Calendar hydration' block header"
    echo "FAILED" >&2
    exit 1
fi
NEXT_HEADER_LINE="$(awk -v start="$CAL_HEADER_LINE" '
    NR > start && /^# (Email|WhatsApp|Browser|iMessage) hydration/ { print NR; exit }
' "$INSTALL_SH")"
if [[ -z "$NEXT_HEADER_LINE" ]]; then
    failure "could not locate end of Calendar hydration block"
    echo "FAILED" >&2
    exit 1
fi
CAL_BLOCK="$(sed -n "${CAL_HEADER_LINE},${NEXT_HEADER_LINE}p" "$INSTALL_SH")"

# Axis 1: the calendar venv resolves to the email-ingest venv -- the one
# that pip-installs ostler_fda -- NOT the contact-syncer pipeline venv.
if ! printf '%s' "$CAL_BLOCK" | grep -qE '_HYDRATE_CALENDAR_VENV="\$\{OSTLER_DIR\}/services/email-ingest/\.venv"'; then
    failure "calendar steps do not target the email-ingest venv (the one with ostler_fda installed)"
fi
if ! printf '%s' "$CAL_BLOCK" | grep -qE '_HYDRATE_CALENDAR_PY="\$\{_HYDRATE_CALENDAR_VENV\}/bin/python"'; then
    failure "_HYDRATE_CALENDAR_PY is not derived from _HYDRATE_CALENDAR_VENV"
fi

# Axis 2: BOTH ostler_fda heredocs (extract_events + ingest_calendar) are
# invoked with $_HYDRATE_CALENDAR_PY, the email-ingest interpreter.
_CAL_PY_INVOCATIONS="$(printf '%s' "$CAL_BLOCK" | grep -cE '"\$_HYDRATE_CALENDAR_PY" - <<EOF' || true)"
if [[ "${_CAL_PY_INVOCATIONS:-0}" -lt 2 ]]; then
    failure "expected both calendar heredocs (extract + ingest) under \$_HYDRATE_CALENDAR_PY, found ${_CAL_PY_INVOCATIONS:-0}"
fi

# Axis 3: the calendar block must NOT run an ostler_fda import under the
# pipeline venv. $_HYDRATE_PIPELINE_PY may only appear in an explanatory
# comment here -- never as a command invocation in this block.
if printf '%s' "$CAL_BLOCK" | grep -E '"\$_HYDRATE_PIPELINE_PY"' | grep -qv '^#'; then
    failure "Calendar block still invokes \$_HYDRATE_PIPELINE_PY (pipeline venv, no ostler_fda) -- the dead-import bug"
fi

# Axis 4: a genuine extractor error is told apart from "not synced". The
# block must branch on an "error" status to a DISTINCT message, and that
# branch must come BEFORE (take priority over) the accounts>0 PENDING
# ("not synced") branch.
if ! printf '%s' "$CAL_BLOCK" | grep -qE '_HYDRATE_CALENDAR_(EXTRACT|INGEST)_STATUS.*==.*"error"'; then
    failure "no branch distinguishes a raised extractor/ingest error from the empty-calendar state"
fi
if ! printf '%s' "$CAL_BLOCK" | grep -q 'MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED'; then
    failure "the error branch does not emit MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED"
fi
# Ordering: the EXTRACTOR_FAILED line must appear before the
# CALENDAR_PENDING ("not synced") line so an import crash never falls
# through to the sync-state message.
_ERR_LINE="$(printf '%s\n' "$CAL_BLOCK" | grep -n 'MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED' | head -1 | cut -d: -f1)"
_PENDING_LINE="$(printf '%s\n' "$CAL_BLOCK" | grep -n 'MSG_HYDRATE_CALENDAR_PENDING' | head -1 | cut -d: -f1)"
if [[ -n "$_ERR_LINE" && -n "$_PENDING_LINE" ]]; then
    if (( _ERR_LINE >= _PENDING_LINE )); then
        failure "EXTRACTOR_FAILED branch does not take priority over the 'not synced' PENDING branch"
    fi
else
    failure "could not locate both EXTRACTOR_FAILED and CALENDAR_PENDING branches for ordering check"
fi

# Axis 5: the new customer-facing string exists and is distinct from the
# "not synced" copy.
if [[ -f "$STRINGS_SH" ]]; then
    if ! grep -q 'MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED=' "$STRINGS_SH"; then
        failure "MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED string is missing"
    fi
else
    failure "install.sh.strings.en-GB.sh missing"
fi

if (( FAILED == 0 )); then
    echo "PASS: tests/test_calendar_hydrate_venv.sh"
    exit 0
else
    echo "FAILED: tests/test_calendar_hydrate_venv.sh" >&2
    exit 1
fi
