#!/usr/bin/env bash
# ChatGPT export hand-off: Downloads -> CM052's drop folder.
#
# A ChatGPT export is a .zip whose root holds conversations.json. The Downloads
# detector recognises no signature for it, and CM052's adapter cannot read a
# zip, so before this file the export was unzipped and then ignored. This copies
# conversations.json into CM052's drop folder, where pwg-ai-convo's chatgpt
# adapter reads it, then runs the producer once for the new folders.
#
# Usage: ostler-chatgpt-handoff.sh <downloads-dir>
# stdout is counts only: never a file name, never transcript text. The user's
# zip is copied from, never moved or changed. Idempotent: the folder name is the
# first 16 hex chars of SHA-256(conversations.json), so a re-run, or the same
# export downloaded twice, is a no-op.
#
# Canonical source. install.sh embeds a copy (quoted heredoc at the end of the
# file). tests/test_chatgpt_export_is_handed_to_cm052.sh fails if they diverge.
set -uo pipefail

DIR="${1:-}"
[[ -n "$DIR" && -d "$DIR" ]] || { echo "chatgpt-handoff: no downloads folder" >&2; exit 1; }
OSTLER_HOME_DIR="${OSTLER_DIR:-${HOME}/.ostler}"
# Same default CM052 reads (adapters/chatgpt_export.py _DEFAULT_DROP_FOLDER).
DROP="${OSTLER_CHATGPT_IMPORT_DIR:-${HOME}/Documents/Ostler/imports/chatgpt}"
PRODUCER="${OSTLER_HOME_DIR}/services/cm052/.venv/bin/pwg-ai-convo"
# A zip modified this recently may still be downloading: leave it for next tick.
STALE_S=120

mkdir -p "$DROP" 2>/dev/null || { echo "chatgpt-handoff: cannot create the CM052 drop folder" >&2; exit 1; }

now="$(date +%s)"
staged=0; present=0; waiting=0; not_chatgpt=0; failed=0

while IFS= read -r -d '' z; do
    mt="$(stat -f%m "$z" 2>/dev/null)" || mt=""
    if [[ -z "$mt" ]]; then failed=$((failed + 1)); continue; fi
    if (( now - mt < STALE_S )); then waiting=$((waiting + 1)); continue; fi
    if ! listing="$(unzip -Z1 "$z" 2>/dev/null)"; then failed=$((failed + 1)); continue; fi
    member="$(printf '%s\n' "$listing" | awk '/(^|\/)conversations\.json$/ { print; exit }')"
    if [[ -z "$member" ]]; then not_chatgpt=$((not_chatgpt + 1)); continue; fi
    stage="$(mktemp -d "${DROP}/.stage.XXXXXX")" || { failed=$((failed + 1)); continue; }
    if ! unzip -p "$z" "$member" > "${stage}/conversations.json" 2>/dev/null || [[ ! -s "${stage}/conversations.json" ]]; then
        rm -rf "$stage"; failed=$((failed + 1)); continue
    fi
    h="$(shasum -a 256 "${stage}/conversations.json" 2>/dev/null | cut -c1-16)"
    if [[ -z "$h" ]]; then rm -rf "$stage"; failed=$((failed + 1)); continue; fi
    dest="${DROP}/chatgpt-${h}"
    if [[ -d "$dest" ]]; then
        rm -rf "$stage"; present=$((present + 1))
    elif mv "$stage" "$dest" 2>/dev/null; then
        staged=$((staged + 1))
    else
        rm -rf "$stage"; failed=$((failed + 1))
    fi
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -type f -name '*.zip' -print0)

# Ingest: one producer run covers every folder that has no .ingested marker.
# The marker is written only on producer success, so a failed run is retried.
pending=0
for d in "${DROP}"/chatgpt-*/; do
    [[ -d "$d" && ! -f "${d}.ingested" ]] && pending=$((pending + 1))
done
ingest="none"
if (( pending > 0 )); then
    if [[ -x "$PRODUCER" ]]; then
        ingest_json="$("$PRODUCER" --source chatgpt --json)"; ingest_rc=$?
        if [[ "$ingest_rc" -eq 0 ]]; then
            for d in "${DROP}"/chatgpt-*/; do [[ -d "$d" ]] && : > "${d}.ingested"; done
            ingest="ok ${ingest_json}"
        else
            ingest="failed rc=${ingest_rc}"
        fi
    else
        ingest="producer_missing"
    fi
fi

printf 'chatgpt-handoff: staged=%s already_in_drop=%s waiting=%s not_chatgpt=%s failed=%s pending_ingest=%s ingest=%s\n' \
    "$staged" "$present" "$waiting" "$not_chatgpt" "$failed" "$pending" "$ingest"
exit 0
