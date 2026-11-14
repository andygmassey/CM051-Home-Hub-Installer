#!/usr/bin/env bash
# ChatGPT export: detected in Downloads, staged into the CM052 drop folder,
# and read by the real CM052 ChatGPT adapter.
#
# Synthetic data only (a made-up conversation). Every temp path is mktemp -d.
# LIB=<path> runs the checks against another detector (used for the RED run
# against origin/main). Exit 0 pass, 1 fail, 2 CANNOT-RUN.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${LIB:-$REPO/lib/ostler-detect-exports.sh}"
CM052_SRC="$REPO/vendor/cm052_ai_conversations/src"
FAILS=0
W="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-export-test.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }

[[ -f "$LIB" ]] || { echo "CANNOT-RUN: detector missing: $LIB"; exit 2; }
command -v zip >/dev/null 2>&1 || { echo "CANNOT-RUN: zip not on PATH"; exit 2; }

# --- synthetic export: a zip holding conversations.json and chat.html ---------
mkdir -p "$W/src/chatgpt-export" "$W/dl" "$W/bare"
cat > "$W/src/chatgpt-export/conversations.json" <<'JSON'
[{"id":"conv-synthetic-1","title":"Synthetic","create_time":1700000000,"update_time":1700000100,
  "default_model_slug":"gpt-5","mapping":{
  "root":{"id":"root","parent":null,"children":["m1"],"message":null},
  "m1":{"id":"m1","parent":"root","children":[],"message":{"id":"m1",
    "author":{"role":"user"},"content":{"content_type":"text","parts":["hello from a synthetic user"]},
    "create_time":1700000001,"metadata":{}}}}}]
JSON
printf '<html><body>synthetic</body></html>\n' > "$W/src/chatgpt-export/chat.html"
(cd "$W/src" && zip -qr "$W/dl/chatgpt-export.zip" chatgpt-export) || { echo "CANNOT-RUN: zip failed"; exit 2; }

# negative: a bare conversations.json with NO chat.html beside it
mkdir -p "$W/dl/other-tool"
printf '[{"id":"not-chatgpt"}]\n' > "$W/dl/other-tool/conversations.json"

echo "1. a ChatGPT zip in Downloads is detected (label ChatGPT)"
hits="$(bash "$LIB" "$W/dl" --unzip 2>/dev/null)"
if printf '%s\n' "$hits" | grep -Fq "$(printf 'ChatGPT\t')"; then ok "ChatGPT label reported"; else fail "no ChatGPT label in: $hits"; fi

echo "2. a bare conversations.json without chat.html is NOT an export"
bare_hits="$(bash "$LIB" "$W/dl/other-tool" 2>/dev/null)"
if printf '%s\n' "$bare_hits" | grep -Fq "$(printf 'ChatGPT\t')"; then fail "bare json reported as ChatGPT"; else ok "bare json not reported"; fi

echo "3. control: a mutant without the chat.html guard reports the bare json"
mutant="$W/mutant-lib.sh"
grep -v 'chat.html" \]\]; then continue; fi' "$LIB" > "$mutant"
if [[ "$(wc -l < "$LIB")" -eq "$(wc -l < "$mutant")" ]]; then fail "mutant edit did not apply"; fi
mut_hits="$(bash "$mutant" "$W/dl/other-tool" 2>/dev/null)"
if printf '%s\n' "$mut_hits" | grep -Fq "$(printf 'ChatGPT\t')"; then ok "mutant reports the bare json, so check 2 can fail"; else fail "mutant did not report the bare json; check 2 proves nothing"; fi

echo "4. stage copies conversations.json into the drop folder"
DROP="$W/drop"
top="$(printf '%s\n' "$hits" | awk -F'\t' '$1=="ChatGPT"{print $2; exit}')"
bash "$LIB" "$top" --stage-chatgpt "$DROP" >/dev/null 2>&1; rc=$?
staged="$DROP/chatgpt-export/conversations.json"
if [[ "$rc" -eq 0 && -f "$staged" ]] && cmp -s "$staged" "$W/src/chatgpt-export/conversations.json"; then
    ok "staged byte-identical to the export"
else
    fail "stage rc=$rc, staged file missing or different"
fi

echo "5. stage refuses a folder with no ChatGPT export (no drop folder created)"
bash "$LIB" "$W/dl/other-tool" --stage-chatgpt "$W/drop2" >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 && ! -e "$W/drop2" ]]; then ok "refused, nothing written"; else fail "rc=$rc or drop2 created"; fi

echo "6. the real CM052 ChatGPT adapter reads the staged folder"
if ! command -v python3 >/dev/null 2>&1; then
    echo "  CANNOT-RUN: python3 not on PATH"
else
    n="$(PYTHONPATH="$CM052_SRC" python3 -c '
import sys
from pathlib import Path
from cm052.adapters import chatgpt_export
print(len(list(chatgpt_export.read(Path(sys.argv[1])))))' "$DROP" 2>"$W/adapter.err")"
    if [[ "$n" == "1" ]]; then ok "adapter yields 1 conversation from the staged folder"
    else fail "adapter yielded '${n}' (stderr: $(head -c 300 "$W/adapter.err"))"; fi
fi

echo
if [[ "$FAILS" -gt 0 ]]; then echo "RESULT: $FAILS FAIL"; exit 1; fi
echo "RESULT: all checks pass"
exit 0
