#!/usr/bin/env bash
# Poll the Hub's pre-meeting brief endpoint and ship unsent briefs
# via WhatsApp. Idempotent via a SQLite-backed sent-briefs cache.
#
# Designed to be safe under launchd: any hard failure exits 0 with
# a stderr log line so the LaunchAgent does not get throttled.
set -uo pipefail

OSTLER_DIR="${HOME}/.ostler"
STATE_DIR="${OSTLER_DIR}/state"
SENT_DB="${STATE_DIR}/sent_briefs.db"
LOG_FILE="${OSTLER_DIR}/logs/meeting-brief-sender.log"
HUB_HOST="${OSTLER_HUB_HOST:-http://localhost:8089}"
ASSISTANT_URL="${OSTLER_ASSISTANT_URL:-http://localhost:8090}"
WITHIN_MINUTES="${OSTLER_BRIEF_WITHIN_MINUTES:-20}"

mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

# Quiet hours guard. Default 07:00 - 21:00 local; overridable via env
# for operators on shifted schedules.
HOUR_NOW=$(date +%H)
QUIET_START="${OSTLER_BRIEF_QUIET_START:-21}"
QUIET_END="${OSTLER_BRIEF_QUIET_END:-7}"
if (( 10#${HOUR_NOW} >= 10#${QUIET_START} || 10#${HOUR_NOW} < 10#${QUIET_END} )); then
    echo "$(date -u +%FT%TZ) skip: quiet hours (hour=${HOUR_NOW})" >> "${LOG_FILE}"
    exit 0
fi

# Bootstrap the sent-briefs DB on first run.
sqlite3 "${SENT_DB}" <<'SQLINIT' 2>>"${LOG_FILE}" || true
CREATE TABLE IF NOT EXISTS sent_briefs (
    key TEXT PRIMARY KEY,
    meeting_uid TEXT NOT NULL,
    scheduled_start TEXT NOT NULL,
    sent_at TEXT NOT NULL
);
SQLINIT

# Fetch upcoming meetings from the Hub. Curl returns 200 even on
# degraded payloads so we check `degraded` server-side and skip
# delivery rather than emitting stale messages.
RESPONSE=$(curl -sS -m 8 \
    "${HUB_HOST}/api/v1/meeting/upcoming?within_minutes=${WITHIN_MINUTES}" \
    2>>"${LOG_FILE}") || {
    echo "$(date -u +%FT%TZ) skip: hub fetch failed" >> "${LOG_FILE}"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    echo "$(date -u +%FT%TZ) skip: empty hub response" >> "${LOG_FILE}"
    exit 0
fi

# Degraded short-circuit, with THREE outcomes rather than two.
# The hub returns degraded=true when the People Graph is unreachable; we do
# not want to ship a brief with missing attendee facts.
#
# 🔴 BOARD ROW 2211. This previously collapsed EVERY failure of the pipeline
# into DEGRADED="False", which is the single answer that ships the brief:
#
#     ... 2>>"${LOG_FILE}") || DEGRADED="False"
#
# Malformed JSON, a truncated response, an unwritable LOG_FILE, or python3
# resolving to the Apple stub on a box without Command Line Tools each read
# as "the People Graph is healthy". The comment above stated the intent
# exactly and the code inverted it on every error path. A guard that cannot
# tell its own failure from a clean result is not a guard, and this one was
# confidently wrong in the precise direction the comment says must not
# happen, on a schedule, unattended, with its own log recording nothing
# because the failure was consumed by the ||.
#
# A brief NOT sent is recoverable. A brief sent with missing attendee facts
# is not. So COULD-NOT-DETERMINE skips, and says why.
DEGRADED_RC=0
DEGRADED_RAW=$(printf '%s' "${RESPONSE}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("degraded", False))' \
    2>>"${LOG_FILE}") || DEGRADED_RC=$?
if [[ "${DEGRADED_RC}" -ne 0 ]]; then
    echo "$(date -u +%FT%TZ) skip: CANNOT-RUN, could not read degraded state (rc=${DEGRADED_RC}); not sending rather than sending a brief that may be missing attendee facts" >> "${LOG_FILE}"
    exit 0
fi
DEGRADED=$(printf '%s' "${DEGRADED_RAW}" | tr -d '[:space:]')
case "${DEGRADED}" in
    True)
        echo "$(date -u +%FT%TZ) skip: hub degraded" >> "${LOG_FILE}"
        exit 0
        ;;
    False)
        : # the only path that sends
        ;;
    *)
        echo "$(date -u +%FT%TZ) skip: CANNOT-RUN, unrecognised degraded value; not sending rather than guessing" >> "${LOG_FILE}"
        exit 0
        ;;
esac

# Iterate meetings. Each meeting's idempotency key is UID + start;
# the assistant's announcement endpoint is the WhatsApp arm.
printf '%s' "${RESPONSE}" | python3 - "${SENT_DB}" "${ASSISTANT_URL}" "${LOG_FILE}" <<'PYEOF'
import json, sqlite3, subprocess, sys, time
from datetime import datetime, timezone

db_path, assistant_url, log_path = sys.argv[1:]
payload = json.load(sys.stdin)
meetings = payload.get("meetings") or []

def _log(msg):
    with open(log_path, "a") as fh:
        fh.write(f"{datetime.now(timezone.utc).isoformat()} {msg}\n")

if not meetings:
    _log(f"no meetings in window")
    sys.exit(0)

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    for m in meetings:
        uid = m.get("uid") or ""
        start = m.get("start_iso") or m.get("start") or ""
        if not uid or not start:
            _log(f"skip: missing uid/start in meeting {m.get('meeting', '?')}")
            continue
        key = f"{uid}|{start}"
        cur.execute("SELECT 1 FROM sent_briefs WHERE key = ?", (key,))
        if cur.fetchone():
            _log(f"skip: already sent {key}")
            continue

        # Render plain-text message client-side. The renderer lives
        # on the brief module side (CM041) for v1.0.1; here we build
        # a minimal echo so the LaunchAgent does not depend on a
        # Python import path matching the source tree layout.
        title = m.get("meeting") or "Upcoming meeting"
        when = m.get("start") or ""
        attendees = m.get("attendees") or []
        names = ", ".join(
            (a.get("name") or a.get("email") or "Unknown")
            for a in attendees[:3]
        )
        lines = [f"Meeting: {title}"]
        if when:
            lines[0] += f" at {when}"
        lines[0] += "."
        if m.get("maps_url"):
            lines.append(f"Location: {m.get('location', '')} {m['maps_url']}")
        if names:
            lines.append(f"With: {names}.")
        first = attendees[0] if attendees else {}
        if first.get("wiki_url"):
            lines.append(f"Wiki: {first['wiki_url']}")
        if first.get("last_discussion_url"):
            lines.append(f"Last chat: {first['last_discussion_url']}")
        open_todos = []
        for a in attendees:
            for t in (a.get("outstanding_todos") or [])[:3]:
                open_todos.append(t)
        if open_todos:
            short = []
            for t in open_todos[:3]:
                owner = t.get("owner_display") or t.get("owner") or ""
                owner_label = f"{owner}: " if owner else ""
                deadline = f" (by {t['deadline']})" if t.get("deadline") else ""
                short.append(f"{owner_label}{t.get('text', '')}{deadline}")
            lines.append("Open: " + " | ".join(short))
        message = "\n".join(lines)

        # Ship to the assistant. The assistant's announce endpoint
        # is the WhatsApp arm reused from the daily-brief delivery
        # path. Failure here is non-fatal (we just retry next tick
        # because the row was not written to sent_briefs).
        body = json.dumps({
            "channel": "whatsapp",
            "kind": "meeting_brief",
            "message": message,
            "meeting_uid": uid,
        }).encode()
        try:
            res = subprocess.run([
                "curl", "-sS", "-m", "6", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--data-binary", body.decode(),
                f"{assistant_url}/announce",
            ], capture_output=True, timeout=10)
            if res.returncode != 0:
                _log(f"deliver failed key={key} rc={res.returncode}")
                continue
        except Exception as exc:
            _log(f"deliver exception key={key} err={exc}")
            continue

        cur.execute(
            "INSERT OR REPLACE INTO sent_briefs "
            "(key, meeting_uid, scheduled_start, sent_at) VALUES (?,?,?,?)",
            (key, uid, start, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()
        _log(f"sent key={key}")
finally:
    conn.close()
PYEOF

exit 0
