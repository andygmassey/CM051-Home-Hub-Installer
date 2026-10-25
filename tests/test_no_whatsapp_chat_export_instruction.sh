#!/usr/bin/env bash
# NO CUSTOMER SURFACE TELLS ANYONE TO EXPORT A WHATSAPP CHAT (owner direction, 2026-10-25).
#
# Ostler never parsed a per-chat WhatsApp "Export chat" .txt: universal_import
# recognises the name and has no dispatcher (recognised_no_parser). WhatsApp
# history comes from WhatsApp Desktop's own store via Full Disk Access.
#
# 1. COPY GUARD: no customer string (the installer catalogue, the GUI copy
#    files) pairs WhatsApp with an instruction to export a chat.
# 2. BEHAVIOUR: a "WhatsApp Chat ....txt" dropped into Downloads is answered
#    "skip" with a plain reason that names WhatsApp Desktop, never "import".
#    Run through the SHIPPED lib/ostler-detect-exports.sh --loose.
#
# Synthetic fixtures only. THREE OUTCOMES: 0 pass, 1 fail, 2 CANNOT-RUN.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${WA_GUARD_ROOT:-}" ] && REPO="$WA_GUARD_ROOT"
LIB="${REPO}/lib/ostler-detect-exports.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
for f in "$LIB" "$STRINGS"; do
    [ -f "$f" ] || { echo "CANNOT-RUN: missing ${f}" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

FAIL=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAIL=1; }

echo "-- 1. copy guard: no customer string tells anyone to export a WhatsApp chat --"
HITS="$(python3 -I - "$REPO" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
files = [root / "install.sh.strings.en-GB.sh"] + sorted((root / "gui").glob("OstlerInstaller/Resources/*.json"))
wa = re.compile(r"whatsapp", re.I)
exp = re.compile(r"export(?:ing)?\s+(?:an?\s+|each\s+|your\s+|individual\s+|the\s+|single\s+)*(?:chats?|conversations?)\b|more\s*>\s*export chat|export chat", re.I)
neg = re.compile(r"\b(?:no export|needs no export|nothing to export|do not|don't|never|no need)\b", re.I)
n = 0
scanned = 0
for f in files:
    if not f.is_file():
        continue
    scanned += 1
    for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if wa.search(line) and exp.search(line) and not neg.search(line):
            print(f"{f.relative_to(root)}:{i}: {line.strip()[:110]}")
            n += 1
sys.stderr.write(f"scanned={scanned}\n")
PY
)"
if [ -n "$HITS" ]; then
    bad "a customer string tells the reader to export a WhatsApp chat:"; printf '%s\n' "$HITS" | sed 's/^/       /'
else
    ok "no customer string pairs WhatsApp with an export-a-chat instruction"
fi
/usr/bin/grep -q 'WhatsApp needs no export' "$STRINGS" \
    && ok "the exports prompt says WhatsApp needs no export" \
    || bad "the exports prompt does not say WhatsApp needs no export"

echo "-- 2. a dropped WhatsApp chat file is answered plainly, never imported --"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wa-guard.XXXXXX")" || { echo "CANNOT-RUN: no scratch dir" >&2; exit 2; }
trap 'rm -rf "$SB"' EXIT
D="$SB/Downloads"; mkdir -p "$D"
printf '[01/01/2026, 09:00:00] Jane Doe: hello\n' > "$D/WhatsApp Chat with Jane Doe.txt"
printf 'BEGIN:VCALENDAR\n%s\nEND:VCALENDAR\n' "$(printf 'X-PAD:%0990d' 0)" > "$D/calendar.ics"
OUT="$(/bin/bash "$LIB" "$D" --loose 2>"$SB/err")"
WA_LINE="$(printf '%s\n' "$OUT" | /usr/bin/grep -F 'WhatsApp chat' || true)"
ICS_LINE="$(printf '%s\n' "$OUT" | /usr/bin/grep -F 'Calendar' || true)"
[ -n "$ICS_LINE" ] || { echo "CANNOT-RUN: control (a calendar file) was not detected, so the scan did not run: $(head -2 "$SB/err")" >&2; exit 2; }
printf '%s' "$ICS_LINE" | /usr/bin/grep -q "$(printf '\t')import" \
    && ok "control: a calendar file is still answered import" \
    || bad "control: the calendar file was not answered import: ${ICS_LINE}"
if [ -z "$WA_LINE" ]; then
    bad "the WhatsApp chat file was not recognised at all (silent): output was: ${OUT}"
elif printf '%s' "$WA_LINE" | /usr/bin/grep -q "$(printf '\t')skip$(printf '\t')"; then
    ok "the WhatsApp chat file is answered skip"
else
    bad "the WhatsApp chat file is not answered skip: ${WA_LINE}"
fi
printf '%s' "$WA_LINE" | /usr/bin/grep -q 'WhatsApp Desktop' \
    && ok "the reason names WhatsApp Desktop" \
    || bad "the reason does not name WhatsApp Desktop: ${WA_LINE}"
printf '%s' "$WA_LINE" | /usr/bin/grep -q "$(printf '\t')import" \
    && bad "the WhatsApp chat file is still answered import" \
    || ok "the WhatsApp chat file is never answered import"

if [ "$FAIL" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAIL"; exit 1
