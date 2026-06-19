#!/usr/bin/env bash
#
# scripts/ostler-meeting-brief-sender-hardened.sh
#
# NO-MERGE harden of the pre-meeting brief sender (job #3 trigger).
#
# This is a self-contained, behaviourally-tested replacement for the
# bin script install.sh emits at ${OSTLER_DIR}/bin/ostler-meeting-brief-sender.
# It closes two reliability gaps the shipped sender has:
#
#   1. SILENT FAILURE. The shipped sender exit-0s on every failure with
#      only a log line, so a wedged trigger (hub down, assistant down,
#      DB locked) is invisible -- the user simply stops getting briefs
#      and never learns why. This version writes a machine-readable
#      heartbeat at ${STATE_DIR}/meeting-brief-sender.health.json on
#      EVERY run, recording last_run / last_success / last_error /
#      consecutive_failures, so Doctor (or a human) can detect a
#      silently-broken trigger. Loud-fail without breaking launchd's
#      throttle contract (the process still exits 0).
#
#   2. LEAD-TIME GUARANTEE. The shipped sender pairs a 10-min poll with
#      a 20-min look-ahead window. A meeting that first appears on the
#      calendar between two polls and starts <10 min later can get
#      almost no notice. This version uses a >= 30-min default window
#      (OSTLER_BRIEF_WITHIN_MINUTES) so a 10-min poll guarantees every
#      meeting is seen with at least (window - interval) = 20 min of
#      lead time, and a missed poll still leaves a second chance.
#
# Everything else (idempotency cache, quiet hours, degraded short-circuit,
# the announce delivery path) matches the shipped sender's semantics so
# this is a drop-in. British English throughout.
#
# Designed to be safe under launchd: any hard failure exits 0 with a
# heartbeat + stderr log line so the LaunchAgent does not get throttled.
set -uo pipefail

OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"
STATE_DIR="${OSTLER_DIR}/state"
SENT_DB="${STATE_DIR}/sent_briefs.db"
HEALTH_FILE="${STATE_DIR}/meeting-brief-sender.health.json"
LOG_FILE="${OSTLER_DIR}/logs/meeting-brief-sender.log"
HUB_HOST="${OSTLER_HUB_HOST:-http://localhost:8089}"
ASSISTANT_URL="${OSTLER_ASSISTANT_URL:-http://localhost:8090}"
# Lead-time guarantee: default 30-min window vs the shipped 20. With a
# 10-min poll this guarantees >= 20 min notice and a second-chance poll.
WITHIN_MINUTES="${OSTLER_BRIEF_WITHIN_MINUTES:-30}"

mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

_now_iso() { date -u +%FT%TZ; }
_log() { echo "$(_now_iso) $*" >> "${LOG_FILE}"; }

# Write the heartbeat. Always called exactly once per run, on every exit
# path, so an absent or stale heartbeat is itself a signal the agent is
# not running. consecutive_failures lets Doctor escalate a persistent
# outage versus a one-off blip.
#
# Args: status (ok|degraded|error|skip)  detail (free text)  sent_count
_write_health() {
    local status="$1" detail="${2:-}" sent="${3:-0}"
    local prev_fail=0 last_success=""
    if [[ -f "${HEALTH_FILE}" ]]; then
        prev_fail=$(python3 - "${HEALTH_FILE}" <<'PYH' 2>/dev/null || echo 0
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(int(d.get("consecutive_failures", 0)))
except Exception:
    print(0)
PYH
)
        last_success=$(python3 - "${HEALTH_FILE}" <<'PYH' 2>/dev/null || echo ""
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("last_success", "") or "")
except Exception:
    print("")
PYH
)
    fi

    local consecutive_failures="${prev_fail}"
    local now
    now="$(_now_iso)"
    if [[ "${status}" == "ok" || "${status}" == "skip" ]]; then
        # A successful poll (even one that found nothing to send) clears
        # the failure streak; skips (quiet hours) are not failures.
        consecutive_failures=0
        if [[ "${status}" == "ok" ]]; then
            last_success="${now}"
        fi
    else
        consecutive_failures=$((prev_fail + 1))
    fi

    HEALTH_STATUS="${status}" HEALTH_DETAIL="${detail}" \
    HEALTH_SENT="${sent}" HEALTH_NOW="${now}" \
    HEALTH_LAST_SUCCESS="${last_success}" \
    HEALTH_FAILS="${consecutive_failures}" \
    HEALTH_WINDOW="${WITHIN_MINUTES}" \
    python3 - "${HEALTH_FILE}" <<'PYWRITE' 2>>"${LOG_FILE}" || true
import json, os, sys
out = {
    "status": os.environ.get("HEALTH_STATUS", ""),
    "detail": os.environ.get("HEALTH_DETAIL", ""),
    "last_run": os.environ.get("HEALTH_NOW", ""),
    "last_success": os.environ.get("HEALTH_LAST_SUCCESS", "") or None,
    "briefs_sent_this_run": int(os.environ.get("HEALTH_SENT", "0") or 0),
    "consecutive_failures": int(os.environ.get("HEALTH_FAILS", "0") or 0),
    "within_minutes": int(os.environ.get("HEALTH_WINDOW", "0") or 0),
}
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as fh:
    json.dump(out, fh, indent=2)
os.replace(tmp, sys.argv[1])
PYWRITE
}

# Quiet hours guard. Default 07:00 - 21:00 local; overridable.
HOUR_NOW=$(date +%H)
QUIET_START="${OSTLER_BRIEF_QUIET_START:-21}"
QUIET_END="${OSTLER_BRIEF_QUIET_END:-7}"
if (( 10#${HOUR_NOW} >= 10#${QUIET_START} || 10#${HOUR_NOW} < 10#${QUIET_END} )); then
    _log "skip: quiet hours (hour=${HOUR_NOW})"
    _write_health "skip" "quiet hours" 0
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

# Fetch upcoming meetings from the Hub.
RESPONSE=$(curl -sS -m 8 \
    "${HUB_HOST}/api/v1/meeting/upcoming?within_minutes=${WITHIN_MINUTES}" \
    2>>"${LOG_FILE}") || {
    _log "error: hub fetch failed"
    _write_health "error" "hub fetch failed (${HUB_HOST})" 0
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    _log "error: empty hub response"
    _write_health "error" "empty hub response" 0
    exit 0
fi

# Degraded short-circuit. The hub returns degraded=true when the People
# Graph is unreachable; we do not ship a brief with missing attendee facts.
DEGRADED=$(printf '%s' "${RESPONSE}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("degraded", False))' \
    2>>"${LOG_FILE}") || DEGRADED="False"
if [[ "${DEGRADED}" == "True" ]]; then
    _log "degraded: hub people-graph unreachable"
    _write_health "degraded" "hub returned degraded=true" 0
    exit 0
fi

# Iterate meetings and deliver. The Python block prints the number of
# briefs sent on its last stdout line so the shell can record it in the
# heartbeat.
#
# The hub response is passed via a temp file (NOT stdin): a heredoc and a
# stdin pipe cannot coexist -- the heredoc wins and the piped data is
# lost. ``python3 -`` reads the program from the heredoc; the response
# path is argv[4].
RESP_FILE="${STATE_DIR}/.last_upcoming.json"
printf '%s' "${RESPONSE}" > "${RESP_FILE}"
SENT_COUNT=$(python3 - "${SENT_DB}" "${ASSISTANT_URL}" "${LOG_FILE}" "${RESP_FILE}" <<'PYEOF'
import json, sqlite3, subprocess, sys
from datetime import datetime, timezone

db_path, assistant_url, log_path, resp_path = sys.argv[1:]
with open(resp_path) as _fh:
    payload = json.load(_fh)
meetings = payload.get("meetings") or []

def _log(msg):
    with open(log_path, "a") as fh:
        fh.write(f"{datetime.now(timezone.utc).isoformat()} {msg}\n")

sent = 0
if not meetings:
    _log("no meetings in window")
    print(0)
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

        body = json.dumps({
            "channel": "whatsapp",
            "kind": "meeting_brief",
            "message": message,
            "meeting_uid": uid,
        })
        try:
            res = subprocess.run([
                "curl", "-sS", "-m", "6", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--data-binary", body,
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
        sent += 1
        _log(f"sent key={key}")
finally:
    conn.close()

print(sent)
PYEOF
) || {
    _log "error: delivery pass crashed"
    _write_health "error" "delivery pass crashed" 0
    exit 0
}

# SENT_COUNT is the last stdout line of the Python block.
SENT_COUNT="${SENT_COUNT##*$'\n'}"
[[ "${SENT_COUNT}" =~ ^[0-9]+$ ]] || SENT_COUNT=0
_log "run ok: sent=${SENT_COUNT}"
_write_health "ok" "poll ok" "${SENT_COUNT}"
exit 0
