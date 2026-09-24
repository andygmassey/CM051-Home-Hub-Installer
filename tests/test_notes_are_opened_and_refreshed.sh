#!/usr/bin/env bash
# Apple Notes: an empty store is opened, not believed, and the rerun catches up.
# ============================================================================
#
# THE DEFECT, measured on a walk box 2026-09-24. NoteStore.sqlite had existed
# since July with 0 rows in ZICNOTEDATA, because Notes had never been opened
# and iCloud only fills the store while Notes runs. install.sh's pre-launch
# gate asked "does NoteStore.sqlite exist?", got yes, and never opened Notes.
# Every extract then read 0 notes. The only step that embeds notes into
# apple_notes_knowledge is the install-time hydrate leg, so the 0 was final.
# Opened once by hand, the same store held 412 notes.
#
# WHAT THIS PROVES, by EXECUTING the shipped code against synthetic stores:
#   A. _store_populated_notes (install.sh) answers on ROWS, not file presence,
#      and the pre-launch gate uses it and leaves Notes running.
#   B. _ostler_notes_refresh (the ostler-fda wrapper install.sh writes):
#      opens an empty store's app at most once a dwell, records the sidecar
#      without dropping other keys, embeds when the extract changes, retries a
#      failed embed, and treats an unreadable store as CANNOT-RUN.
#
# `open` and ostler-knowledge are shims that RECORD their calls. Nothing here
# opens an app or touches a real store. Synthetic data only.
#
# EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${1:-${REPO_ROOT}/install.sh}"
PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cannot_run() { echo "CANNOT-RUN: $1" >&2; exit 2; }

command -v sqlite3 >/dev/null 2>&1 || cannot_run "sqlite3 not on PATH"
command -v python3 >/dev/null 2>&1 || cannot_run "python3 not on PATH"
[[ -f "$INSTALL_SH" ]] || cannot_run "no install.sh at $INSTALL_SH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── extract a top-level bash function by name ──────────────────────────────
extract_fn() {  # <file> <name>
    awk -v n="$2" '
        $0 ~ "^" n "\\(\\) \\{" { f = 1 }
        f { print }
        f && /^}$/ { exit }
    ' "$1"
}

# The ostler-fda wrapper exactly as install.sh writes it.
awk '
    index($0, "bin/ostler-fda\" <<'"'"'FDAEOF'"'"'") { f = 1; next }
    f && $0 == "FDAEOF" { exit }
    f { print }
' "$INSTALL_SH" > "${WORK}/ostler-fda"
[[ -s "${WORK}/ostler-fda" ]] || cannot_run "could not extract the ostler-fda wrapper from install.sh"

make_store() {  # <path> <rows>
    mkdir -p "$(dirname "$1")"; rm -f "$1"
    sqlite3 "$1" "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB);"
    local i=0
    while (( i < $2 )); do
        sqlite3 "$1" "INSERT INTO ZICNOTEDATA (ZDATA) VALUES (x'00');"
        i=$((i + 1))
    done
}

echo "A. install.sh: the populated probe and the pre-launch gate"
extract_fn "$INSTALL_SH" _store_populated_notes > "${WORK}/probe.sh"
if [[ ! -s "${WORK}/probe.sh" ]]; then
    bad "install.sh defines _store_populated_notes"
else
    ok "install.sh defines _store_populated_notes"
    STORE_A="${WORK}/homeA/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    run_probe() { HOME="${WORK}/homeA" bash -c ". '${WORK}/probe.sh'; _store_populated_notes"; }
    check "no store file -> not populated" '! run_probe'
    make_store "$STORE_A" 0
    check "store file with 0 note rows -> NOT populated (the measured defect)" '! run_probe'
    make_store "$STORE_A" 3
    check "store with note rows -> populated" 'run_probe'
fi
GATE="$(grep -n 'APPS_TO_OPEN+=("Notes")' "$INSTALL_SH" | grep -v '^[0-9]*: *#' || true)"
check "the pre-launch gate adds Notes on the row probe, not on file presence" \
    '[[ "$GATE" == *"_store_populated_notes"* ]] && [[ "$GATE" != *"NoteStore.sqlite"* ]]'
check "the pre-launch quit loop leaves Notes running" \
    'grep -q "^ *\[\[ \"\$app\" == \"Notes\" \]\] && continue" "$INSTALL_SH"'

echo "B. ostler-fda: the Notes refresh step"
extract_fn "${WORK}/ostler-fda" _ostler_notes_refresh > "${WORK}/refresh.sh"
if [[ ! -s "${WORK}/refresh.sh" ]]; then
    bad "the ostler-fda wrapper defines _ostler_notes_refresh"
else
    ok "the ostler-fda wrapper defines _ostler_notes_refresh"
    check "the wrapper runs it after the ingest and exits with both rcs" \
        'grep -q "^_ostler_notes_refresh || _notes_rc=" "${WORK}/ostler-fda" && grep -q "^\" || _fda_rc=" "${WORK}/ostler-fda"'

    H="${WORK}/homeB"
    BIN="${WORK}/shim"; mkdir -p "$BIN"
    OPENLOG="${WORK}/open.log"; KLOG="${WORK}/knowledge.log"
    printf '#!/bin/sh\necho "$*" >> "%s"\n' "$OPENLOG" > "${BIN}/open"
    cat > "${WORK}/ostler-knowledge" <<EOF
#!/bin/sh
echo "\$1 \$*" >> "$KLOG"
[ "\${KNOWLEDGE_FAIL:-0}" = "1" ] && [ "\$1" = "embed" ] && exit 1
exit 0
EOF
    chmod +x "${BIN}/open" "${WORK}/ostler-knowledge"
    STORE_B="${H}/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    SIG="${H}/.ostler/state/pipeline_signals.json"
    JSON="${H}/.ostler/imports/fda/apple_notes.json"
    mkdir -p "$(dirname "$SIG")" "$(dirname "$JSON")"

    refresh() {
        : > "$OPENLOG"; : > "$KLOG"
        HOME="$H" PATH="${BIN}:${PATH}" OSTLER_DIR="${H}/.ostler" OSTLER_PYTHON="$(command -v python3)" \
        OSTLER_KNOWLEDGE_BIN="${WORK}/ostler-knowledge" \
            bash -c "set -euo pipefail; . '${WORK}/refresh.sh'; _ostler_notes_refresh" >"${WORK}/refresh.out" 2>&1
    }
    sig() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$SIG" "$1" 2>/dev/null; }

    printf '{"mail_has_fetched": true, "install_completed_ts": 1}\n' > "$SIG"
    make_store "$STORE_B" 0
    refresh; rc=$?
    check "empty store: the step succeeds" '[[ $rc -eq 0 ]]'
    check "empty store: Notes is opened hidden" 'grep -qx -- "-g -j -a Notes" "$OPENLOG"'
    check "empty store: sidecar notes_has_fetched=False" '[[ "$(sig notes_has_fetched)" == "False" ]]'
    check "the sidecar keeps the keys it did not write" '[[ "$(sig mail_has_fetched)" == "True" && "$(sig install_completed_ts)" == "1" ]]'
    refresh
    check "empty store again inside the dwell: Notes is NOT re-opened" '[[ ! -s "$OPENLOG" ]]'
    OSTLER_NOTES_REOPEN_S=0 refresh
    check "dwell elapsed: Notes is re-opened" 'grep -qx -- "-g -j -a Notes" "$OPENLOG"'

    make_store "$STORE_B" 2
    printf '[{"note_id":"syn-1"},{"note_id":"syn-2"}]\n' > "$JSON"
    KNOWLEDGE_FAIL=1 refresh; rc=$?
    check "a failed embed makes the step non-zero" '[[ $rc -ne 0 ]]'
    check "a failed embed records no hash, so the next tick retries" '[[ ! -f "${H}/.ostler/state/hydrate/apple_notes_knowledge.sha256" ]]'
    refresh; rc=$?
    check "populated store: Notes is not opened" '[[ ! -s "$OPENLOG" ]]'
    check "populated store: sidecar notes_has_fetched=True" '[[ "$(sig notes_has_fetched)" == "True" ]]'
    check "new extract: convert then embed into apple_notes_knowledge" \
        'grep -q "^convert " "$KLOG" && grep -q "^embed .*--collection apple_notes_knowledge" "$KLOG"'
    check "the hydrate sentinel records ok with the note count" \
        'grep -qx "status=ok" "${H}/.ostler/state/hydrate/apple_notes.done" && grep -qx "item_count=2" "${H}/.ostler/state/hydrate/apple_notes.done"'
    refresh
    check "unchanged extract: no second embed" '[[ ! -s "$KLOG" ]]'
    printf '[]\n' > "$JSON"
    refresh
    check "an empty extract embeds nothing" '[[ ! -s "$KLOG" ]]'

    printf 'not a database' > "$STORE_B"
    rm -f "$SIG"
    refresh
    check "unreadable store: CANNOT-RUN, nothing recorded, Notes not opened" \
        'grep -q "CANNOT-RUN" "${WORK}/refresh.out" && [[ ! -f "$SIG" && ! -s "$OPENLOG" ]]'

    make_store "$STORE_B" 0
    OSTLER_FDA_SOURCES="calendar,reminders" OSTLER_NOTES_REOPEN_S=0 refresh
    check "Notes not among the customer's sources: nothing opened, nothing recorded" '[[ ! -s "$OPENLOG" && ! -f "$SIG" ]]'
    OSTLER_NOTES_REFRESH=0 OSTLER_NOTES_REOPEN_S=0 refresh
    check "OSTLER_NOTES_REFRESH=0 turns the step off" '[[ ! -s "$OPENLOG" && ! -f "$SIG" ]]'
fi

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[[ $FAIL -eq 0 ]]
