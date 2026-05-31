#!/bin/bash
# Ostler iMessage bundle tick (CM040 product path).
#
# Runs one pass of the iMessage source: read chat.db, thread recent
# conversations into sessions, hand each new session to CM048's
# pwg-convo processor (four-artefact bundle).
#
# Mirrors email-ingest-tick.sh. The installer renders the placeholders:
#   OSTLER_PYTHON      -> imessage-source venv python3 (env or below)
#   OSTLER_SOURCE_DIR  -> $OSTLER_DIR/services/imessage-source
#   PWG_CONVO_CMD      -> absolute pwg-convo invocation (CM048 venv)
#   OSTLER_USER_DISPLAY_NAME -> the operator's display name
#   OSTLER_CONTACTS    -> optional contacts.yaml (handle -> name, L3)
#
# Fresh-install clamp: --since-days bounds the first read window so we
# don't bundle the entire history in one tick. British English.
set -euo pipefail

PYTHON_BIN="${OSTLER_PYTHON:-python3}"
SOURCE_DIR="${OSTLER_SOURCE_DIR:-OSTLER_SOURCE_DIR_PLACEHOLDER}"
SINCE_DAYS="${OSTLER_IMESSAGE_SINCE_DAYS:-30}"
USER_NAME="${OSTLER_USER_DISPLAY_NAME:-You}"

ARGS=(--user-name "$USER_NAME" --since-days "$SINCE_DAYS")
if [ -n "${OSTLER_CONTACTS:-}" ] && [ -f "${OSTLER_CONTACTS}" ]; then
    ARGS+=(--contacts "${OSTLER_CONTACTS}")
fi

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR
# is the parent of the `services/` tree on the Hub install layout.
exec "$PYTHON_BIN" -m services.imessage_source.pipeline "${ARGS[@]}"
