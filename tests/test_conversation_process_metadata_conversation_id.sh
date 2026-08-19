#!/usr/bin/env bash
#
# test_conversation_process_metadata_conversation_id.sh
#
# Byte-walking regression test for the /api/v1/conversation/process
# metadata-injection fix (recut 2026-06-18). Refuses the exact failure
# shape that made every POSTed transcript -- notably the iOS Watch path
# (POST /api/v1/conversation/process) -- silently vanish.
#
# What the failure looked like (PRE-FIX, must never recur):
#   The vendored ical-server.py _conversation_process_background() derived
#   a conversation_id (used as the per-conversation state-dir name) but
#   wrote the caller's raw metadata dict to 00_metadata.json WITHOUT it.
#   CM048's CLI (src/cli.py cmd_process) then rejected the job with exit 2
#   ("metadata.json must include a conversation_id") and the conversation
#   was lost after the raw-file write. Runtime-proven on the live Hub:
#   a no-conversation_id submit -> failed_step=processor with that exact
#   message; the same submit carrying conversation_id -> accepted.
#
# The vendored handler MUST inject the derived conversation_id into the
# metadata it persists. This guard asserts that on the SHIPPED copy, so a
# future re-vendor of CM041 that drops the graft fails the cut (same class
# as the divergent-vendor-twin / ungrafted-fix trap). It runs at cut time,
# is network-free and dependency-free.
#
# Pairs with the source-side unit test in CM041:
#   assistant_api/tests/test_endpoints_extended.py
#   ::TestConversationProcessBackgroundMetadata
# which runs the real worker (subprocess stubbed) and asserts the on-disk
# 00_metadata.json carries conversation_id.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

SERVER="$REPO_ROOT/vendor/cm041/assistant_api/ical-server.py"

if [[ ! -f "$SERVER" ]]; then
    failure "vendored ical-server.py missing: vendor/cm041/assistant_api/ical-server.py"
    exit 1
fi

# Extract the _conversation_process_background function body so the
# assertions cannot be satisfied by an unrelated occurrence elsewhere in
# the file. From the def line to the next top-level 'def ' / 'class '.
BODY="$(awk '
    /^def _conversation_process_background\(/ {grab=1}
    grab && NR>1 && (/^def /||/^class /) && $0 !~ /_conversation_process_background/ {if(seen){exit}}
    grab {print; seen=1}
' "$SERVER")"

if [[ -z "$BODY" ]]; then
    failure "could not locate _conversation_process_background() in vendored ical-server.py"
    exit 1
fi

# Axis 1: the function must assign the derived conversation_id into the
# metadata that gets written to 00_metadata.json.
if ! grep -Eq 'conversation_id["'\'']?\]?[[:space:]]*=[[:space:]]*conversation_id' <<<"$BODY"; then
    failure "_conversation_process_background() does not inject conversation_id into the metadata it writes -- CM048 will reject every POSTed transcript with exit 2"
fi

# Axis 2: the write to 00_metadata.json must serialise the injected dict,
# NOT the raw caller 'metadata'. Pre-fix wrote json.dumps(metadata, ...);
# the fix writes the augmented copy. Refuse a write of the bare 'metadata'.
WRITE_LINE="$(grep -nE '00_metadata\.json' <<<"$BODY" | head -1 || true)"
if [[ -z "$WRITE_LINE" ]]; then
    failure "_conversation_process_background() no longer writes 00_metadata.json"
else
    # The json.dumps(...) feeding the 00_metadata.json write must not pass
    # the bare 'metadata' variable. We look at the dumps call within the
    # function body.
    if grep -Eq 'json\.dumps\([[:space:]]*metadata[[:space:]]*,' <<<"$BODY"; then
        failure "00_metadata.json is written from the bare caller 'metadata' (missing conversation_id) -- this is the pre-fix silent-drop shape"
    fi
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_conversation_process_metadata_conversation_id: RED" >&2
    exit 1
fi

echo "test_conversation_process_metadata_conversation_id: GREEN -- vendored handler injects conversation_id into 00_metadata.json"
exit 0
