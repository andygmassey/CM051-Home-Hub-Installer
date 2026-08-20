#!/bin/bash
# Runs ON THE BOX. Answers: which WhatsApp code path is the daemon actually on,
# and does the binary even contain the WhatsApp Web WebSocket transport.
#
# Every zero here carries a positive control, because "nothing found" and
# "nothing looked at" print identically.
set -uo pipefail

echo "=== 1. running daemon: pid, path, version ==="
ps -Ao pid,comm,args | grep -E 'ostler-assistant|zeroclaw' | grep -v grep || echo "  (no matching process)"
echo
for p in "$HOME/.ostler/bin/ostler-assistant" "/usr/local/bin/ostler-assistant" "$HOME/.ostler/ostler-assistant"; do
    [ -x "$p" ] && { echo "  binary: $p"; "$p" --version 2>&1 | head -2; }
done
BIN="$(ps -Ao args | grep -E '^[^ ]*ostler-assistant' | grep -v grep | head -1 | awk '{print $1}')"
echo "  BIN from ps: '${BIN:-<none>}'"
echo

echo "=== 2. does the SHIPPED BINARY contain the WhatsApp Web transport? ==="
if [ -n "${BIN:-}" ] && [ -f "$BIN" ]; then
    echo "  measuring: $BIN  ($(wc -c < "$BIN") bytes)"
    for s in 'wa-rs' 'wa_rs' 'whatsapp_web' 'web.whatsapp.com' 'g.whatsapp.net' 'graph.facebook.com' 'mmg.whatsapp.net' 'WhatsApp Web'; do
        n="$(strings -a "$BIN" 2>/dev/null | grep -cF "$s")"
        printf '    %-22s %s\n' "$s" "$n"
    done
    echo "  -- controls --"
    for s in 'ostler' 'zeroclaw' 'THIS_STRING_IS_NOT_IN_ANY_BINARY_12345'; do
        n="$(strings -a "$BIN" 2>/dev/null | grep -cF "$s")"
        printf '    %-22s %s   (control)\n' "$s" "$n"
    done
else
    echo "  CANNOT-RUN: no binary path resolved from ps"
fi
echo

echo "=== 3. the assistant config: which backend is selected? ==="
for c in "$HOME/.ostler/assistant/zeroclaw.toml" "$HOME/.zeroclaw/config.toml" "$HOME/.ostler/zeroclaw.toml"; do
    [ -f "$c" ] && echo "  found: $c"
done
CFG="$(ls "$HOME"/.ostler/**/*.toml "$HOME"/.zeroclaw/*.toml 2>/dev/null | head -20)"
echo "  candidate configs:"; printf '%s\n' "$CFG" | sed 's/^/    /'
echo
echo "  --- [channels.whatsapp] blocks, values REDACTED to shape ---"
for f in $CFG; do
    if [ "$(grep -cE '\[channels\.whatsapp\]' "$f")" -gt 0 ]; then
        echo "    in $f:"
        awk '/^\[channels\.whatsapp\]/{f=1} f&&/^\[/&&!/channels\.whatsapp/{f=0} f{print "      "$0}' "$f" \
          | sed -E 's/=[[:space:]]*".*"/= "<SET>"/'
    fi
done
echo

echo "=== 4. established sockets held by the daemon, right now ==="
lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | awk 'NR==1 || /ostler-as|zeroclaw/' || echo "  (none)"
echo

echo "=== 5. consent record ==="
if [ -f "$HOME/.ostler/posture/consent.json" ]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d, indent=2)[:2000])' "$HOME/.ostler/posture/consent.json" 2>&1 | head -40
else
    echo "  no consent.json at ~/.ostler/posture/consent.json"
fi
echo

echo "=== 6. assistant log: which channels came up ==="
find "$HOME/.ostler/logs" -name '*assistant*' -o -name '*zeroclaw*' 2>/dev/null | head -5
for L in $(find "$HOME/.ostler/logs" -name '*assistant*' 2>/dev/null | head -3); do
    echo "  --- $L"
    grep -aE 'Channels:|WhatsApp' "$L" 2>/dev/null | tail -15 | sed 's/^/    /'
done
