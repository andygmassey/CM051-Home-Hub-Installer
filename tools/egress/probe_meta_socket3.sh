#!/bin/bash
# Third pass. Every zero above needs its shape checked before I write any of it
# down, because "the log never said connected" and "the log CANNOT say
# connected" print identically.
set -uo pipefail

BIN="${OSTLER_APP_ROOT:-$HOME/.ostler}/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
L="$HOME/.ostler/logs/ostler-assistant.err"

echo "=== A. can the log even SAY the things I counted as zero? ==="
for s in 'connected successfully' 'giving up' 'was logged out' 'reconnecting in' 'QR code received'; do
    printf '  binary contains %-24s %s\n' "\"$s\"" "$(strings -a "$BIN" 2>/dev/null | grep -cF "$s")"
done
echo "  (a zero on the LEFT would mean my zero on the right was uninterpretable)"
echo

echo "=== B. everything whatsapp-ish after 07:49, and any error at all ==="
grep -aE 'whatsapp|WhatsApp' "$L" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' \
  | awk '$1 > "2026-08-17T07:49:19"' | tail -20 | sed 's/^/  /'
echo "  --- count of lines after that point: $(grep -aE 'whatsapp|WhatsApp' "$L" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' | awk '$1 > "2026-08-17T07:49:19"' | grep -c .)"
echo
echo "  --- last 8 lines of the log overall, whatever they are ---"
tail -8 "$L" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' | sed 's/^/  /'
echo

echo "=== C. daemon uptime vs log window ==="
ps -o pid,lstart,etime,comm -p 21592 2>/dev/null
echo

echo "=== D. the session_path value, verbatim (a path, not a secret) ==="
grep -E '^\s*session_path' "$HOME/.ostler/assistant-config/config.toml" 2>/dev/null | sed 's/^/  /'
grep -E '^\s*mode|^\s*dm_policy|^\s*group_policy' "$HOME/.ostler/assistant-config/config.toml" 2>/dev/null | sed 's/^/  /'
echo "  does that path exist?"
SP="$(grep -E '^\s*session_path' "$HOME/.ostler/assistant-config/config.toml" 2>/dev/null | sed -E 's/.*=\s*"(.*)"/\1/')"
echo "    resolved: ${SP:-<unset>}"
if [ -n "${SP:-}" ]; then
    if [ -e "$SP" ]; then ls -l "$SP" | sed 's/^/    /'; else echo "    DOES NOT EXIST"; fi
fi
echo "  is /tmp/ostler-prelaunch-* still present?"
ls -d /tmp/ostler-prelaunch-* 2>/dev/null | sed 's/^/    /' || echo "    none"
echo

echo "=== E. what the Doctor/GUI would show: the pair-panel artefact ==="
if [ -f "$HOME/.ostler/state/whatsapp_pair.json" ]; then
    ls -l "$HOME/.ostler/state/whatsapp_pair.json" | sed 's/^/  /'
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print({k:("<SET>" if k in ("code","qr") else v) for k,v in d.items()})' \
      "$HOME/.ostler/state/whatsapp_pair.json" 2>&1 | sed 's/^/  /'
else
    echo "  absent"
fi
