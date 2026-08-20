#!/bin/bash
# Follow-up: is the Meta socket STEADY STATE or only during a pairing attempt,
# and is the daemon still in a pairing retry loop right now?
set -uo pipefail

echo "=== box clock ==="
date -u '+%Y-%m-%dT%H:%M:%SZ'
echo

L="$HOME/.ostler/logs/ostler-assistant.err"
echo "=== last 12 whatsapp_web lines, with timestamps ==="
grep -a 'whatsapp_web' "$L" 2>/dev/null | tail -12 | sed -E 's/\x1b\[[0-9;]*m//g' | sed 's/^/  /'
echo
echo "=== how many pair/QR events, and the window they span ==="
n_qr="$(grep -ac 'QR code received' "$L" 2>/dev/null)"
n_pair="$(grep -ac 'pair code received' "$L" 2>/dev/null)"
n_conn="$(grep -ac 'connected successfully' "$L" 2>/dev/null)"
n_give="$(grep -ac 'giving up' "$L" 2>/dev/null)"
n_logout="$(grep -ac 'logged out' "$L" 2>/dev/null)"
printf '  QR received        %s\n  pair code received %s\n  connected ok       %s\n  gave up            %s\n  logged out         %s\n' \
  "$n_qr" "$n_pair" "$n_conn" "$n_give" "$n_logout"
echo "  -- control: a string that must be present in any tracing log --"
printf '  INFO lines         %s\n' "$(grep -ac 'INFO' "$L" 2>/dev/null)"
echo "  -- control: a string that must be absent --"
printf '  NOT_A_REAL_MARKER  %s\n' "$(grep -ac 'NOT_A_REAL_MARKER_98765' "$L" 2>/dev/null)"
echo
echo "  first and last whatsapp_web timestamps:"
grep -a 'whatsapp_web' "$L" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z' | head -1 | sed 's/^/    first  /'
grep -a 'whatsapp_web' "$L" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z' | tail -1 | sed 's/^/    last   /'
echo

echo "=== ALL established sockets on the box right now (full picture) ==="
lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | awk '{print $1"\t"$2"\t"$9}' | sort -u
echo

echo "=== does any process hold a socket in the Meta 57.144.0.0/16 range? ==="
hits="$(lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -cE '57\.144\.')"
echo "  57.144.x hits: $hits"
lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -E '57\.144\.' | sed 's/^/    /'
echo
echo "=== what do WhatsApp's own hostnames resolve to, from THIS box, right now? ==="
for h in web.whatsapp.com g.whatsapp.net mmg.whatsapp.net graph.facebook.com; do
    printf '  %-22s %s\n' "$h" "$(dig +short "$h" A 2>/dev/null | tr '\n' ' ')"
done
echo "  -- controls --"
printf '  %-22s %s\n' 'example.com' "$(dig +short example.com A 2>/dev/null | tr '\n' ' ')"
printf '  %-22s %s\n' 'nxdomain.invalid' "$(dig +short thisdoesnotexist12345.invalid A 2>/dev/null | tr '\n' ' ')"
