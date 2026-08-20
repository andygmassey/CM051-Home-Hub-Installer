#!/bin/bash
# Pass 4. Two of my own measurements in pass 3 were unsound and I am not
# writing either of them down until they are re-taken:
#
#   * the session_path "DOES NOT EXIST" was my sed failing to strip the KEY,
#     so it tested the literal string `session_path = "..."` as a filename
#   * "11 lines after 07:49:19" compared $1 on lines that have no timestamp
#     (the raw QR art), so the filter was meaningless
set -uo pipefail

L="$HOME/.ostler/logs/ostler-assistant.err"
CFG="$HOME/.ostler/assistant-config/config.toml"

echo "=== D-redo. the WhatsApp Web session store ==="
SP="$(awk -F'=' '/^[[:space:]]*session_path/{gsub(/^[[:space:]]*"|"[[:space:]]*$/,"",$2); gsub(/^[[:space:]]*/,"",$2); gsub(/"/,"",$2); print $2; exit}' "$CFG")"
echo "  session_path = '${SP:-<unset>}'"
if [ -n "${SP:-}" ] && [ -e "$SP" ]; then
    ls -l "$SP" | sed 's/^/    /'
    echo "    size: $(wc -c < "$SP") bytes"
else
    echo "    NOT PRESENT on disk"
fi
echo "  -- positive control: a path that definitely exists --"
ls -ld "$HOME/.ostler" | sed 's/^/    /'
echo "  -- the /tmp parent --"
ls -la /tmp/ostler-prelaunch-3992/ 2>/dev/null | sed 's/^/    /'
ls -la /tmp/ostler-prelaunch-3992/state/ 2>/dev/null | sed 's/^/    /'
echo

echo "=== B-redo. TIMESTAMPED whatsapp_web lines only, full list ==="
grep -a 'zeroclaw_channels::whatsapp_web' "$L" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' \
  | sed 's/^/  /'
echo "  total timestamped whatsapp_web lines: $(grep -ac 'zeroclaw_channels::whatsapp_web' "$L" 2>/dev/null)"
echo

echo "=== F. is the daemon STILL trying? watch for 45s ==="
before="$(grep -ac 'zeroclaw_channels::whatsapp_web' "$L" 2>/dev/null)"
echo "  whatsapp_web lines now: $before"
echo "  sockets outside loopback held by the daemon now:"
lsof -nP -iTCP -sTCP:ESTABLISHED -p 21592 2>/dev/null | grep -vc '127\.0\.0\.1' | sed 's/^/    outside-loopback count (incl header): /'
lsof -nP -iTCP -sTCP:ESTABLISHED -p 21592 2>/dev/null | sed 's/^/    /'
perl -e 'select(undef,undef,undef,45)'
after="$(grep -ac 'zeroclaw_channels::whatsapp_web' "$L" 2>/dev/null)"
echo "  whatsapp_web lines 45s later: $after   (delta $((after-before)))"
lsof -nP -iTCP -sTCP:ESTABLISHED -p 21592 2>/dev/null | sed 's/^/    /'
echo

echo "=== G. pair artefact expiry, in human terms ==="
python3 - <<'PY'
import json,datetime
p="${OSTLER_STATE_DIR:-$HOME/.ostler/state}/whatsapp_pair.json"
d=json.load(open(p))
for k in ("requested_at","expires_at"):
    print(f"  {k}: {d[k]}  ->  {datetime.datetime.fromtimestamp(d[k], datetime.timezone.utc).isoformat()}")
now=datetime.datetime.now(datetime.timezone.utc).timestamp()
print(f"  now: {int(now)}  ->  expired {int(now-d['expires_at'])}s ago" if now>d["expires_at"] else "  still valid")
PY
