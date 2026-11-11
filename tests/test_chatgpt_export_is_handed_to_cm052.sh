#!/usr/bin/env bash
# A ChatGPT export left in Downloads must reach CM052's drop folder.
#
# WHY THIS EXISTS. The Downloads watcher recognises no ChatGPT signature, and
# CM052's adapter reads only a plain conversations.json under its drop folder,
# never a zip. A customer's ChatGPT export was unzipped by the detector and then
# ignored, with no line in the log. This test runs the SHIPPED path end to end:
# it extracts the helper that install.sh writes, extracts the scanner that
# install.sh writes, plants SYNTHETIC exports in a fixture HOME, runs the
# scanner, and then asks CM052's own adapter whether it can read what landed.
#
# Synthetic fixtures only. Nothing here reads a real Downloads or drop folder.
# macOS only (BSD stat / shasum / touch -t), like the watcher it tests.
#
# ARMS (0 pass, 1 fail, 2 cannot-run):
#   1 install.sh embeds the helper (quoted heredoc present)
#   2 the embedded copy equals lib/ostler-chatgpt-handoff.sh (drift guard)
#   3 the shipped scanner calls the helper
#   4 scanner run: 2-conversation zip is copied, not moved; one drop folder
#   5 producer invoked with --source chatgpt once; second run is a no-op
#   6 a zip without conversations.json is not handed over
#   7 the same export twice lands in one folder
#   8 CM052's real adapter reads the drop folder and yields 2 conversations
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${INSTALL_SH:-${REPO}/install.sh}"
CANON="${REPO}/lib/ostler-chatgpt-handoff.sh"
CM052_SRC="${REPO}/vendor/cm052_ai_conversations/src"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
cannot() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$SUBJECT" ] || cannot "no install.sh at ${SUBJECT}"
[ -f "$CANON" ]   || cannot "no canonical helper at ${CANON}"
command -v shasum >/dev/null 2>&1 || cannot "shasum not on PATH"
command -v python3 >/dev/null 2>&1 || cannot "python3 not on PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-handoff-test.XXXXXX")" || cannot "no working directory"
trap 'rm -rf "$WORK"' EXIT
EMBED="${WORK}/embedded-helper.sh"
SCANNER="${WORK}/ostler-scan-exports"
FH="${WORK}/home"
mkdir -p "${FH}/Downloads"

# --- 1. install.sh embeds the helper ------------------------------------------
awk '/<<.OSTLER_CHATGPT_HANDOFF_EOF./ { f = 1; next } /^OSTLER_CHATGPT_HANDOFF_EOF$/ { f = 0 } f' \
    "$SUBJECT" > "$EMBED"
if [ -s "$EMBED" ]; then
    ok "install.sh embeds the ChatGPT hand-off helper ($(wc -l < "$EMBED" | tr -d ' ') lines)"
else
    bad "install.sh embeds no ChatGPT hand-off helper (no OSTLER_CHATGPT_HANDOFF_EOF heredoc)"
fi

# --- 2. drift guard: embedded copy == canonical lib ----------------------------
if [ -s "$EMBED" ] && cmp -s "$EMBED" "$CANON"; then
    ok "embedded helper is byte-identical to lib/ostler-chatgpt-handoff.sh"
else
    bad "embedded helper diverges from lib/ostler-chatgpt-handoff.sh (or is absent)"
fi

# --- 3. the shipped scanner calls the helper ----------------------------------
awk '/<<.SCANEOF./ { f = 1; next } /^SCANEOF$/ { f = 0 } f' "$SUBJECT" > "$SCANNER"
if [ -s "$SCANNER" ] && grep -q 'ostler-chatgpt-handoff.sh' "$SCANNER"; then
    ok "ostler-scan-exports calls the helper"
else
    bad "ostler-scan-exports never calls the helper"
fi

# Install the EMBEDDED copy into the fixture, as install.sh would. Without it
# arms 4-7 would test the repo file, not what ships.
if [ -s "$EMBED" ]; then
    mkdir -p "${FH}/.ostler/lib" "${FH}/.ostler/bin"
    cp "$EMBED" "${FH}/.ostler/lib/ostler-chatgpt-handoff.sh"
    cp "$SCANNER" "${FH}/.ostler/bin/ostler-scan-exports"
fi

# --- synthetic fixtures -------------------------------------------------------
# Two conversations in ChatGPT's conversations.json shape, and one zip that has
# no conversations.json at all. Written with the stdlib; -I ignores the env.
python3 -I - "$WORK" <<'PY'
import json, sys, zipfile, pathlib
work = pathlib.Path(sys.argv[1])
def conv(cid, title, text):
    return {
        "id": cid, "title": title,
        "create_time": 1767225600.0, "update_time": 1767225660.0,
        "current_node": "m2",
        "mapping": {
            "root": {"id": "root", "message": None, "parent": None, "children": ["m1"]},
            "m1": {"id": "m1", "parent": "root", "children": ["m2"],
                   "message": {"id": "m1", "author": {"role": "user"},
                               "create_time": 1767225600.0,
                               "content": {"content_type": "text", "parts": [text]},
                               "metadata": {}}},
            "m2": {"id": "m2", "parent": "m1", "children": [],
                   "message": {"id": "m2", "author": {"role": "assistant"},
                               "create_time": 1767225660.0,
                               "content": {"content_type": "text", "parts": ["synthetic reply"]},
                               "metadata": {"model_slug": "synthetic"}}},
        },
    }
convs = [conv("synthetic-conv-a", "Synthetic A", "synthetic question A"),
         conv("synthetic-conv-b", "Synthetic B", "synthetic question B")]
body = json.dumps(convs).encode()
with zipfile.ZipFile(work / "chatgpt-export-synthetic.zip", "w") as z:
    z.writestr("conversations.json", body)
    z.writestr("user.json", b"{}")
with zipfile.ZipFile(work / "chatgpt-export-synthetic-copy.zip", "w") as z:
    z.writestr("conversations.json", body)
with zipfile.ZipFile(work / "not-chatgpt.zip", "w") as z:
    z.writestr("readme.txt", b"synthetic, no conversations")
PY
[ $? -eq 0 ] || cannot "could not build synthetic zips"
DL="${FH}/Downloads"
mv "${WORK}/chatgpt-export-synthetic.zip" "${WORK}/not-chatgpt.zip" "$DL/"
cp "${WORK}/chatgpt-export-synthetic-copy.zip" "$DL/"
# Age them: the helper leaves a zip modified in the last 120s for the next tick.
touch -t 202001010000 "$DL"/*.zip
SRC_SHA_BEFORE="$(shasum -a 256 "$DL/chatgpt-export-synthetic.zip" | cut -c1-64)"

# A stub producer that records its argv and prints a counts-only summary.
PRODUCER="${FH}/.ostler/services/cm052/.venv/bin/pwg-ai-convo"
mkdir -p "$(dirname "$PRODUCER")"
cat > "$PRODUCER" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${WORK}/producer-calls.log"
printf '{"discovered": 2, "ingested": 2, "written": 2, "l3_skipped": 0, "failed": 0}\n'
STUB
chmod +x "$PRODUCER"

# Stub the notifier and importer, so the scanner runs without touching the Mac.
mkdir -p "${WORK}/stubs"
printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/stubs/osascript"; chmod +x "${WORK}/stubs/osascript"

DROP="${FH}/Documents/Ostler/imports/chatgpt"

# --- 4. scanner run: copied, not moved, one folder ----------------------------
HOME="$FH" PATH="${WORK}/stubs:${PATH}" bash "${FH}/.ostler/bin/ostler-scan-exports" >/dev/null 2>&1
DROPPED=$(find "$DROP" -mindepth 1 -maxdepth 1 -type d -name 'chatgpt-*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$DROPPED" = "1" ] && [ -f "$(find "$DROP" -mindepth 2 -maxdepth 2 -name conversations.json 2>/dev/null | head -1)" ]; then
    ok "the synthetic export landed in the CM052 drop folder (1 folder)"
else
    bad "expected 1 chatgpt-* folder with conversations.json in ${DROP}, found ${DROPPED}"
fi
SRC_SHA_AFTER="$(shasum -a 256 "$DL/chatgpt-export-synthetic.zip" 2>/dev/null | cut -c1-64)"
if [ -f "$DL/chatgpt-export-synthetic.zip" ] && [ "$SRC_SHA_BEFORE" = "$SRC_SHA_AFTER" ]; then
    ok "the user's zip is still in Downloads, unchanged (copied, not moved)"
else
    bad "the user's zip was moved or changed"
fi

# --- 5. producer once with --source chatgpt; second run is a no-op ------------
if [ -f "${WORK}/producer-calls.log" ] && [ "$(grep -c -- '--source chatgpt --json' "${WORK}/producer-calls.log")" = "1" ] \
   && [ -f "$(find "$DROP" -mindepth 2 -maxdepth 2 -name .ingested 2>/dev/null | head -1)" ]; then
    ok "pwg-ai-convo ran once with --source chatgpt --json and marked the folder ingested"
else
    bad "producer not run once with --source chatgpt --json, or no .ingested marker"
fi
HOME="$FH" PATH="${WORK}/stubs:${PATH}" bash "${FH}/.ostler/bin/ostler-scan-exports" >/dev/null 2>&1
CALLS="$(wc -l < "${WORK}/producer-calls.log" 2>/dev/null | tr -d ' ')"
DROPPED2=$(find "$DROP" -mindepth 1 -maxdepth 1 -type d -name 'chatgpt-*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$CALLS" = "1" ] && [ "$DROPPED2" = "1" ]; then
    ok "second run: no new folder, no second producer call (idempotent)"
else
    bad "second run not idempotent: producer calls=${CALLS}, folders=${DROPPED2}"
fi

# --- 6. a zip without conversations.json is not handed over -------------------
STRAY=$(find "$DROP" -mindepth 1 -maxdepth 1 ! -name 'chatgpt-*' ! -name '.stage.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$STRAY" = "0" ]; then
    ok "nothing but chatgpt-* folders in the drop folder (the non-ChatGPT zip was not handed over)"
else
    bad "a non-ChatGPT zip reached the drop folder"
fi

# --- 7. same export twice lands in one folder ---------------------------------
# The copy zip is byte-different but its conversations.json is identical, so the
# hash-named folder must be the same one: arm 4 already showed 1 folder for 2 zips.
if [ "$DROPPED" = "1" ] && [ "$DROPPED2" = "1" ]; then
    ok "two zips with the same conversations.json share one folder (hash-named)"
else
    bad "duplicate export created more than one folder"
fi

# --- 8. CM052's real adapter reads what landed --------------------------------
ADAPTER_OUT="$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
try:
    from pathlib import Path
    from cm052.adapters import chatgpt_export
except Exception as exc:
    print("IMPORT_FAILED " + type(exc).__name__ + ": " + str(exc)[:200]); sys.exit(3)
convs = list(chatgpt_export.read(Path(sys.argv[2])))
print("CONVERSATIONS " + str(len(convs)))
' "$CM052_SRC" "$DROP" 2>&1)"
ADAPTER_RC=$?
if [ "$ADAPTER_RC" -eq 3 ] || printf '%s' "$ADAPTER_OUT" | grep -q '^IMPORT_FAILED'; then
    cannot "CM052 adapter would not import: ${ADAPTER_OUT}"
elif [ "$ADAPTER_RC" -ne 0 ]; then
    bad "CM052 adapter raised (rc=${ADAPTER_RC}): $(printf '%s' "$ADAPTER_OUT" | tail -1 | cut -c1-200)"
elif printf '%s' "$ADAPTER_OUT" | grep -qx 'CONVERSATIONS 2'; then
    ok "CM052's chatgpt adapter reads the drop folder and yields 2 conversations"
else
    bad "CM052's chatgpt adapter yielded: $(printf '%s' "$ADAPTER_OUT" | tail -1 | cut -c1-200)"
fi

echo ""
echo "  chatgpt-handoff: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
