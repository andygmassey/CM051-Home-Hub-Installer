#!/usr/bin/env bash
# test_no_finder_appleevent.sh
#
# WALK-361. Andy hit this on the v1.0.57 launch walk and had hit it before:
# macOS raised "OstlerInstaller wants access to control Finder. Allowing
# control will provide access to documents and data in Finder."
#
# THE INSTALLER MUST NEVER SEND AN APPLE EVENT TO FINDER.
#
# Any `tell application "Finder"` makes macOS raise a TCC consent dialog
# naming Finder and "documents and data". macOS permits exactly ONE
# NSAppleEventsUsageDescription per app, so that dialog is stamped with the
# same sentence used for the System Events password prompt -- i.e. a
# documents-and-data prompt explained by a sentence about passwords. The
# string cannot be worded per target, so better copy was never a fix. Not
# sending the event is the fix, and this test is what keeps it fixed.
#
# `open -R` is LaunchServices, NOT an Apple Event, and raises no prompt. It
# is explicitly still allowed -- this test must not forbid it.
#
# ANTI-VACUITY: a bare "count is zero" passes when the file is unreadable,
# the path is wrong, or the pattern is malformed. Every zero here is paired
# with a POSITIVE CONTROL that must be non-zero on the same file, read by
# the same grep, in the same run. If a control reads zero the test FAILS as
# CANNOT-RUN rather than passing as clean.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
GREP=/usr/bin/grep

rc=0
fail() { printf 'FAIL: %s\n' "$*" >&2; rc=1; }
pass() { printf 'ok: %s\n' "$*"; }

if [ ! -r "${INSTALL_SH}" ]; then
    printf 'CANNOT-RUN: install.sh not readable at %s\n' "${INSTALL_SH}" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# POSITIVE CONTROLS -- prove the reader can see this file and that the
# matcher fires on a real Apple Event before any zero below is believed.
# ---------------------------------------------------------------------------
CONTROL_SYSEV=$("${GREP}" -c 'application "System Events"' "${INSTALL_SH}" || true)
if [ "${CONTROL_SYSEV}" -eq 0 ]; then
    printf 'CANNOT-RUN: control failed -- 0 System Events Apple Events found in install.sh.\n' >&2
    printf '            The grep, the path or the pattern is broken, so a Finder zero\n' >&2
    printf '            below would be a FALSE ABSENCE. Refusing to report clean.\n' >&2
    exit 2
fi
pass "control: matcher sees ${CONTROL_SYSEV} System Events Apple Events (non-zero, so a Finder zero is real)"

CONTROL_LINES=$(wc -l < "${INSTALL_SH}")
if [ "${CONTROL_LINES}" -lt 1000 ]; then
    printf 'CANNOT-RUN: control failed -- install.sh is only %s lines; expected a large file.\n' "${CONTROL_LINES}" >&2
    exit 2
fi
pass "control: install.sh is ${CONTROL_LINES} lines (a truncated read would not reach here)"

# ---------------------------------------------------------------------------
# THE SUBJECT -- zero Apple Events addressed to Finder.
# ---------------------------------------------------------------------------
FINDER_HITS=$("${GREP}" -c 'application "Finder"' "${INSTALL_SH}" || true)
if [ "${FINDER_HITS}" -ne 0 ]; then
    fail "install.sh sends ${FINDER_HITS} Apple Event(s) to Finder. This raises the \
\"control Finder / access to documents and data\" consent dialog on every walk (WALK-361). \
Remove the event; do not try to reword it -- macOS allows only one \
NSAppleEventsUsageDescription per app, so it cannot be worded per target."
    "${GREP}" -n 'application "Finder"' "${INSTALL_SH}" >&2 || true
else
    pass "subject: 0 Apple Events to Finder (denominator: ${CONTROL_LINES} lines, control fired)"
fi

# `osascript ... Finder` in any other spelling is the same defect.
OSA_FINDER=$("${GREP}" -c -E 'osascript.*Finder' "${INSTALL_SH}" || true)
if [ "${OSA_FINDER}" -ne 0 ]; then
    fail "install.sh has ${OSA_FINDER} osascript line(s) mentioning Finder (alternate spelling of WALK-361)"
    "${GREP}" -n -E 'osascript.*Finder' "${INSTALL_SH}" >&2 || true
else
    pass "subject: 0 osascript lines naming Finder"
fi

# ---------------------------------------------------------------------------
# `open -R` MUST SURVIVE. If a future tidy-up deletes the reveal instead of
# the Apple Event, the drag-in fallback silently loses its Finder window and
# the customer is told to drag an app they can no longer see. That failure
# is invisible to the two zeros above, so it is asserted explicitly.
# ---------------------------------------------------------------------------
# Count INVOCATIONS, not prose. The fix comment above the removed Apple Event
# mentions `open -R` by name, and a bare substring count folded that comment
# into the control -- the control was then partly satisfied by the very change
# it is meant to police. Anchor on the quoted argument so only a real call
# counts.
OPEN_R=$("${GREP}" -c -E '(^|[^-[:alnum:]])open -R "' "${INSTALL_SH}" || true)
if [ "${OPEN_R}" -eq 0 ]; then
    fail "the 'open -R' Finder reveal is GONE. LaunchServices raises no consent prompt \
and is the correct way to show the app; removing it breaks the FDA drag-in fallback."
else
    pass "open -R reveal still present (${OPEN_R} site(s)) -- LaunchServices, no consent prompt"
fi

# ---------------------------------------------------------------------------
# THE USAGE STRING MUST NOT PROMISE SOMETHING FINDER-SHAPED. It is stamped on
# every Apple Events prompt, so it has to be true of every target we address.
# ---------------------------------------------------------------------------
for PLIST_REL in gui/project.yml gui/OstlerInstaller/Info.plist; do
    PLIST="${REPO_ROOT}/${PLIST_REL}"
    [ -r "${PLIST}" ] || { fail "CANNOT-RUN: ${PLIST_REL} not readable"; continue; }

    CTRL=$("${GREP}" -c 'NSAppleEventsUsageDescription' "${PLIST}" || true)
    if [ "${CTRL}" -eq 0 ]; then
        fail "CANNOT-RUN: no NSAppleEventsUsageDescription key in ${PLIST_REL}"
        continue
    fi

    # The old string described only the password path, which was untrue of the
    # Finder prompt it also stamped.
    STALE=$("${GREP}" -c 'needs to ask for your administrator password to install Hub services' "${PLIST}" || true)
    if [ "${STALE}" -ne 0 ]; then
        fail "${PLIST_REL} still carries the pre-WALK-361 usage string, which described a \
password request while also being stamped on a documents-and-data prompt."
    else
        pass "${PLIST_REL}: pre-WALK-361 usage string is gone (control: key present)"
    fi
done

exit "${rc}"
