#!/usr/bin/env bash
# The todos_reach_reminders probe's synthetic todo text was 110 chars; the
# product rejects titles over MAX_TITLE_CHARS (reminders_push.py, 80) as
# "too_long", so the probe measured a rejection it caused itself (v1.0.120).
# Reads the limit from the shipped source, expands the probe's REAL text line
# with a worst-case token, and asserts it fits and still carries the token.
# Exit: 0 holds | 1 broken | 2 CANNOT RUN
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${1:-$HERE/../scripts/box_walk_probes/probes/todos_reach_reminders.sh}"
SRC="$HERE/../vendor/cm048_pipeline/src/reminders_push.py"
[ -f "$PROBE" ] && [ -f "$SRC" ] || { echo "CANNOT RUN: probe or reminders_push.py missing" >&2; exit 2; }
limit="$(sed -n 's/^MAX_TITLE_CHARS *= *\([0-9][0-9]*\).*/\1/p' "$SRC" | head -1)"
[ -n "$limit" ] || { echo "CANNOT RUN: MAX_TITLE_CHARS not found in the shipped source" >&2; exit 2; }
line="$(/usr/bin/grep -E '^[[:space:]]*text="' "$PROBE" | head -1 | sed 's/^[[:space:]]*//')"
[ -n "$line" ] || { echo "CANNOT RUN: no text=\"...\" line in the probe" >&2; exit 2; }
# Worst case token: 7-digit pid and 10-digit epoch, same shape the probe builds.
token="ostler-walk-todo-9999999-9999999999"
text=""
eval "$line"
n=${#text}
fail=0
if [ "$n" -lt "$limit" ]; then echo "  ok    probe text is $n chars, under the product limit $limit"; else echo "  FAIL  probe text is $n chars; the product rejects over $limit"; fail=1; fi
case "$text" in *"$token"*) echo "  ok    the unique token is still in the text";; *) echo "  FAIL  the unique token is missing"; fail=1;; esac
exit "$fail"
