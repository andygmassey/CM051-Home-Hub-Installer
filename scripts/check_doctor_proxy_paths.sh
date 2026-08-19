#!/usr/bin/env bash
# Assert the Doctor LaunchAgent's DOCTOR_PROXY_PATHS carries every iOS
# endpoint template the app calls.
#
# WHY THIS IS A SCRIPT AND NOT FOUR LINES INSIDE THE VENDOR TEST
#
# It used to be four lines inside vendor/cm041/assistant_api/test_vendor_import.sh,
# and it had two problems that only become visible once you try to test it.
#
# 1. THE PREDICATE WAS A WHOLE-FILE GREP.
#
#    The old check was `grep -q "${path}" install.sh`. install.sh is ~15k
#    lines and it TALKS about these paths: the plist stanza is surrounded by
#    comments naming individual endpoints and why they were added. So the
#    gate passed when a path appeared in a COMMENT, whether or not it was in
#    the rendered <string> the Doctor actually reads. Deleting a path from
#    the proxy list while leaving the comment that explains it, which is the
#    single most likely way to break this, was a green.
#
#    It was also a substring match, so a path that is a PREFIX of another
#    required path could never fail. /api/v1/calendar is a prefix of
#    /api/v1/calendar/today; deleting the bare path left the gate green. The
#    same trap was about to be laid a second time, because /api/v1/topics
#    and /api/v1/topics/{slug}/mentions are both required and one contains
#    the other.
#
#    This version extracts the rendered value and compares COMMA-DELIMITED
#    FIELDS. A path is present when it is a whole field, and a comment
#    mentioning it is worth exactly nothing.
#
# 2. IT COULD NOT BE TESTED WITHOUT MUTATING install.sh.
#
#    Taking the install.sh path as an argument means the controls in
#    tests/test_doctor_proxy_paths_predicate.sh can build 30-line fixtures
#    and prove this refuses, including the two shapes the old predicate
#    passed. A gate with no demonstrated red is a hope.
#
# WHAT BREAKS WHEN THIS LIST IS WRONG
#
# DOCTOR_PROXY_PATHS is read at vendor/doctor/agent/proxy.py:115 and
# rendered into the Doctor LaunchAgent by install.sh. Each entry becomes an
# add_api_route() on the Doctor, which is the only thing the iOS app can
# reach across the auth boundary. A route can exist and answer perfectly in
# ical-server.py and still be completely dark to the phone if its template
# is missing here. That is not hypothetical: the five moat endpoints shipped
# to main WITHOUT their proxy entries, and the iOS read path for all five
# was dark until CM051 #370 and #371.
#
# Exit codes, and they are distinct on purpose:
#   0  every required path is a field in the rendered value
#   1  at least one required path is MISSING (the list is printed)
#   3  CANNOT-RUN. The value could not be read at all, so this script has
#      NOT checked anything. A caller that treats 3 as a pass has learned
#      nothing and believes it has.

set -euo pipefail

RC_OK=0
RC_MISSING=1
RC_CANNOT_RUN=3

# Every iOS endpoint template that must survive into the Doctor proxy list.
#
# Order here is presentational only; the check is by field, not position.
REQUIRED_PROXY_PATHS=(
    "/api/v1/hub/health"
    "/api/v1/timeline"
    "/api/v1/people/search"
    "/api/v1/people/context"
    "/api/v1/people/stale"
    "/api/v1/suggestions"
    "/api/v1/calendar"
    "/api/v1/conversation/process"
    "/api/v1/conversation/status/{id}"
    "/api/v1/ingest/ios"
    "/api/v1/people/{slug}/forget"
    "/api/v1/email/recent"
    "/api/v1/recording/active"
    "/api/v1/coach/recent"
    # CM051 #370 -- per-person timeline. NOTE this is /person/ singular and
    # is NOT covered by the bare /api/v1/timeline entry above: proxy.py:550
    # uses add_api_route(path, ...) with the exact template, so a route is
    # reachable only if its own template is listed.
    "/api/v1/person/{slug}/timeline"
    # CM051 #371 -- the four moat read endpoints. Their handlers have been on
    # main since ical-server.py:7085-7162 and were unreachable from iOS.
    "/api/v1/decisions"
    "/api/v1/topics"
    "/api/v1/topics/{slug}/mentions"
    "/api/v1/commitments"
)

# A floor, in the ratchet sense. If someone deletes an entry above, the
# array silently shrinks and the gate silently checks less while still
# printing PASS. Removing a required endpoint is a real decision and it has
# to be made in two places, deliberately.
EXPECTED_REQUIRED_COUNT=19

INSTALL_SH="${1:-}"
if [[ -z "$INSTALL_SH" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    INSTALL_SH="$(cd "$SCRIPT_DIR/.." && pwd)/install.sh"
fi

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "CANNOT-RUN: no install.sh at $INSTALL_SH" >&2
    echo "  Nothing was checked. This is not a pass." >&2
    exit "$RC_CANNOT_RUN"
fi

if [[ ${#REQUIRED_PROXY_PATHS[@]} -ne $EXPECTED_REQUIRED_COUNT ]]; then
    echo "CANNOT-RUN: REQUIRED_PROXY_PATHS holds ${#REQUIRED_PROXY_PATHS[@]} entries," >&2
    echo "            EXPECTED_REQUIRED_COUNT says $EXPECTED_REQUIRED_COUNT." >&2
    echo "  An endpoint was added or removed without updating the floor. If the" >&2
    echo "  removal is intended, change both and say why in the commit." >&2
    exit "$RC_CANNOT_RUN"
fi

# ---------------------------------------------------------------- extract
#
# Exactly one rendering, or we do not know which one the Doctor gets.
KEY_COUNT=$(grep -c '<key>DOCTOR_PROXY_PATHS</key>' "$INSTALL_SH" || true)
if [[ "${KEY_COUNT:-0}" -eq 0 ]]; then
    echo "CANNOT-RUN: no <key>DOCTOR_PROXY_PATHS</key> in $INSTALL_SH" >&2
    echo "  Either the plist stanza was renamed or this is the wrong file." >&2
    echo "  Nothing was checked. This is not a pass." >&2
    exit "$RC_CANNOT_RUN"
fi
if [[ "$KEY_COUNT" -ne 1 ]]; then
    echo "CANNOT-RUN: $KEY_COUNT renderings of <key>DOCTOR_PROXY_PATHS</key>." >&2
    echo "  With more than one, checking the first proves nothing about the one" >&2
    echo "  the installed Doctor actually receives." >&2
    exit "$RC_CANNOT_RUN"
fi

RAW="$(awk '/<key>DOCTOR_PROXY_PATHS<\/key>/ { getline nextline; print nextline; exit }' "$INSTALL_SH")"

case "$RAW" in
    *"<string>"*"</string>"*) : ;;
    *)
        echo "CANNOT-RUN: the line after <key>DOCTOR_PROXY_PATHS</key> is not a" >&2
        echo "            <string>...</string> value. Got:" >&2
        echo "    $RAW" >&2
        exit "$RC_CANNOT_RUN"
        ;;
esac

VALUE="${RAW#*<string>}"
VALUE="${VALUE%%</string>*}"

if [[ -z "$VALUE" ]]; then
    echo "CANNOT-RUN: DOCTOR_PROXY_PATHS renders as an EMPTY string." >&2
    echo "  Every iOS endpoint is dark. Reporting that as 'missing paths' would" >&2
    echo "  understate it, so it is refused separately." >&2
    exit "$RC_CANNOT_RUN"
fi

# ------------------------------------------------------------------ check
#
# Wrapping in commas turns "is this a field" into a plain substring test,
# which is the whole point: /api/v1/topics matches ",/api/v1/topics," and
# does NOT match ",/api/v1/topics/{slug}/mentions,".
HAYSTACK=",${VALUE},"

MISSING=()
for path in "${REQUIRED_PROXY_PATHS[@]}"; do
    case "$HAYSTACK" in
        *",${path},"*) : ;;
        *) MISSING+=("$path") ;;
    esac
done

FIELD_COUNT=$(printf '%s' "$VALUE" | tr ',' '\n' | grep -c . || true)

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "FAIL: DOCTOR_PROXY_PATHS is missing ${#MISSING[@]} of $EXPECTED_REQUIRED_COUNT required paths:" >&2
    for p in "${MISSING[@]}"; do
        echo "    - $p" >&2
    done
    echo "" >&2
    echo "  The rendered value carries $FIELD_COUNT field(s). The handler can exist" >&2
    echo "  and work in ical-server.py and still be unreachable from iOS without" >&2
    echo "  its template here." >&2
    echo "  File: $INSTALL_SH" >&2
    exit "$RC_MISSING"
fi

echo "PASS: all $EXPECTED_REQUIRED_COUNT required Doctor proxy paths are fields in DOCTOR_PROXY_PATHS ($FIELD_COUNT total)"
exit "$RC_OK"
