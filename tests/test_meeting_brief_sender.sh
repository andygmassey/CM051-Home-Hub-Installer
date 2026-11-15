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
   ! grep -q 'CANNOT-RUN hub degraded' "$INSTALL_SCRIPT"; then
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

# ── Port defaults match what the installer actually binds ────────
# The sender's tests all set OSTLER_HUB_HOST / OSTLER_ASSISTANT_URL, so a
# wrong DEFAULT is invisible to them and only shows on a customer Mac as a
# brief that never arrives. Compare each default against its producer:
#   HUB_HOST      -> the ical-server plist's OSTLER_API_PORT
#   ASSISTANT_URL -> the [gateway] port the installer writes (/announce lives there)
hub_default_port="$(sed -n 's/^HUB_HOST="\${OSTLER_HUB_HOST:-http:\/\/[^:]*:\([0-9]*\)}"$/\1/p' "$INSTALL_SCRIPT")"
asst_default_port="$(sed -n 's/^ASSISTANT_URL="\${OSTLER_ASSISTANT_URL:-http:\/\/[^:]*:\([0-9]*\)}"$/\1/p' "$INSTALL_SCRIPT")"
ical_port="$(awk '/<key>OSTLER_API_PORT<\/key>/{getline; gsub(/[^0-9]/,""); print; exit}' "$INSTALL_SCRIPT")"
gateway_port="$(sed -n 's/^ *echo "port = \([0-9]*\)"$/\1/p' "$INSTALL_SCRIPT" | head -1)"
for v in hub_default_port asst_default_port ical_port gateway_port; do
    if [ -z "${!v}" ]; then
        echo "CANNOT-RUN [port-defaults]: could not read $v from install.sh" >&2
        exit 2
    fi
done
if [ "$hub_default_port" != "$ical_port" ]; then
    echo "FAIL [hub-port]: sender HUB_HOST defaults to :$hub_default_port but the ical-server binds :$ical_port" >&2
    exit 1
fi
echo "PASS: sender HUB_HOST default :$hub_default_port is the ical-server port"
if [ "$asst_default_port" != "$gateway_port" ]; then
    echo "FAIL [announce-port]: sender ASSISTANT_URL defaults to :$asst_default_port but /announce is on the gateway :$gateway_port" >&2
    exit 1
fi
echo "PASS: sender ASSISTANT_URL default :$asst_default_port is the gateway port"

# Owner-facing header in the owner's language (same-shape sweep 2026-11-14,
# item 2). Runs the sender's own Python block against a stub curl and a stub
# composer, then reads the body that would have been POSTed to /announce.
# RED on the pre-change sender: a ja owner was sent "Meeting: ... at <English date>, 10:00."
HDR_W="$(mktemp -d)"
trap 'rm -rf "$HDR_W"' EXIT
/usr/bin/python3 - "$INSTALL_SCRIPT" "$HDR_W/block.py" <<'PYX'
import sys
s = open(sys.argv[1], encoding="utf-8").read().split("\n")
i = next(k for k, l in enumerate(s) if "<<'PYEOF' || _send_rc=$?" in l and "SENT_DB" in l)
j = next(k for k in range(i + 1, len(s)) if s[k] == "PYEOF")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(s[i + 1:j]) + "\n")
PYX
mkdir -p "$HDR_W/bin"
cat > "$HDR_W/bin/curl" <<'CURLX'
#!/bin/bash
prev=""; for a in "$@"; do if [ "$prev" = "--data-binary" ]; then printf '%s' "$a" > "$CAPTURE"; fi; prev="$a"; done
exit 0
CURLX
printf '#!/bin/bash\necho "Synthetic attendee note."\n' > "$HDR_W/composer"
chmod +x "$HDR_W/bin/curl" "$HDR_W/composer"
send_header() {  # $1 owner_language (NONE = pre-change arity), $2 attendees json, $3 start_iso (optional), $4 TZ (optional)
    rm -f "$HDR_W/body.json"
    rm -f "$HDR_W/sent.db"
    /usr/bin/python3 -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);c.execute('CREATE TABLE IF NOT EXISTS sent_briefs (key TEXT PRIMARY KEY, meeting_uid TEXT NOT NULL, scheduled_start TEXT NOT NULL, sent_at TEXT NOT NULL)');c.commit()" "$HDR_W/sent.db"
    local hub args=()
    hub="{\"considered\":1,\"meetings\":[{\"uid\":\"u-1\",\"meeting\":\"Q3 review\",\"start\":\"2026-11-14, 10:00\",\"start_iso\":\"${3:-20261114T100000}\",\"location\":\"\",\"attendees\":$2}]}"
    [ "$1" = "NONE" ] || args=("$1")
    CAPTURE="$HDR_W/body.json" PATH="$HDR_W/bin:$PATH" OSTLER_BRIEF_HUB_JSON="$hub" TZ="${4:-}" \
        OSTLER_BRIEF_COMPOSER="$HDR_W/composer" OSTLER_BRIEF_OWNER_NAME="" \
        /usr/bin/python3 "$HDR_W/block.py" "$HDR_W/sent.db" "http://127.0.0.1:8000" "$HDR_W/log.txt" \
        "http://127.0.0.1:8090" "$HDR_W" "test-channel" ${args[@]+"${args[@]}"} >/dev/null 2>&1 || true
    if [ -f "$HDR_W/body.json" ]; then
        /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['message'].split(chr(10))[0])" "$HDR_W/body.json"
    else
        echo "(none sent)"
    fi
}
JA_ALONE="$(send_header ja '[]')"
JA_WITH="$(send_header ja '[{"name":"Synthetic Person","wiki_url":"","outstanding_todos":[]}]')"
case "$JA_WITH" in *"Meeting:"*|*"at Sat"*) echo "FAIL [header-language]: ja owner got English header: $JA_WITH" >&2; exit 1 ;; esac
case "$JA_WITH" in *"会議"*"10:00"*) ;; *) echo "FAIL [header-language]: ja header missing localised text or 24h time: $JA_WITH" >&2; exit 1 ;; esac
case "$JA_ALONE" in *", 10:00"*) echo "FAIL [header-time]: the pre-change date form leaked into the header: $JA_ALONE" >&2; exit 1 ;; esac
US_ALONE="$(send_header en-US '[]')"
case "$US_ALONE" in *"10:00 AM"*) ;; *) echo "FAIL [header-time-us]: en-US owner not given 12-hour time: $US_ALONE" >&2; exit 1 ;; esac
# A Z time is shown on the owner's clock (Hong Kong, +08): 01:00Z is 09:00 HK.
# RED on the pre-change _when: it printed the UTC hour, 01:00.
HK_Z="$(send_header ja '[]' '2026-11-14T01:00:00Z' 'Asia/Hong_Kong')"
case "$HK_Z" in *"09:00"*) ;; *) echo "FAIL [header-time-zone]: 01:00Z on a Hong Kong Mac should read 09:00: $HK_Z" >&2; exit 1 ;; esac
# A naive local time stays as written.
NAIVE="$(send_header ja '[]' '20261114T100000' 'Asia/Hong_Kong')"
case "$NAIVE" in *"10:00"*) ;; *) echo "FAIL [header-time-naive]: a naive local 10:00 must stay 10:00: $NAIVE" >&2; exit 1 ;; esac
echo "PASS: owner-language header (ja: $JA_WITH; en-US: $US_ALONE; Z 01:00 on HK clock: $HK_Z)"

echo ""
echo "All meeting-brief-sender wiring checks passed."
