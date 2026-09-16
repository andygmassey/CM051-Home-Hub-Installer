#!/usr/bin/env bash
# BOTH BRANCHES OF THE EXPORT WATCHER CLAIMED AN IMPORT (#1571).
#
# ostler-scan-exports ran the importer and then said, on rc=0:
#     "Your latest export is now part of your world."
# and on NON-ZERO rc:
#     "Imported your latest export. Some parts will finish in the background."
#
# The second is said on the path where the importer FAILED. Nothing was
# imported and nothing is finishing in the background. A customer whose import
# failed was told it had succeeded, in slightly different words.
#
# Worse, and this is the part that made it permanent: the dedupe hash was
# written AFTER the if/else, so it was recorded on the failure path too. The
# hash is the skip key -- once it is in scan_state that export set is never
# looked at again. So a failed import was announced as done AND made
# unretryable, by a line whose own comment read "Record only after a real
# import attempt, so a failed/partial run is retried next tick rather than
# silently marked done". The comment described the fix; the code did the
# opposite.
#
# This test runs the SHIPPED scanner, extracted from install.sh's heredoc,
# against a stub importer, with osascript shimmed so the assertions are made
# on THE TEXT A CUSTOMER IS SHOWN rather than on the source.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '\n=== A FAILED IMPORT IS NOT ANNOUNCED AS DONE ===\n\n'

# --- extract the shipped scanner from install.sh -----------------------------
SCAN="$WORK/ostler-scan-exports"
awk "/^cat > \"\\\${OSTLER_DIR}\/bin\/ostler-scan-exports\" <<'SCANEOF'\$/{f=1;next} f&&/^SCANEOF\$/{exit} f{print}" \
    install.sh > "$SCAN"
n_lines=$(wc -l < "$SCAN" | tr -d ' ')
if [ "$n_lines" -gt 100 ]; then
    ok "extracted the shipped scanner from install.sh (${n_lines} lines)"
else
    bad "could not extract the scanner (${n_lines} lines); every arm below would be vacuous"
    printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"; exit 1
fi
chmod +x "$SCAN"
bash -n "$SCAN" || { bad "the extracted scanner does not parse"; }

# --- a hermetic HOME with a recognised export and a stub importer ------------
# $1 = exit code the stub importer returns
setup_box() {
    local rc="$1" box="$WORK/box_$1"
    rm -rf "$box"; mkdir -p "$box/Downloads/Takeout" "$box/.ostler/bin" "$box/.ostler/state" "$box/shim"
    printf '%s\n' '#!/usr/bin/env bash' "exit ${rc}" > "$box/.ostler/bin/ostler-import"
    chmod +x "$box/.ostler/bin/ostler-import"
    # osascript shim: record exactly what the customer would be shown.
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${NOTIFY_LOG}"' > "$box/shim/osascript"
    chmod +x "$box/shim/osascript"
    printf '%s' "$box"
}
run_box() {
    local box="$1"
    NOTIFY_LOG="$box/notifications.txt" HOME="$box" PATH="$box/shim:$PATH" \
        bash "$SCAN" >/dev/null 2>&1
    printf '%s' "$?"
}

# ---------------------------------------------------------------------------
# CONTROL FIRST: the SUCCESS path must still work. If the harness cannot make
# the scanner reach the importer at all, every "it did not say X" assertion
# below would pass for the wrong reason.
# ---------------------------------------------------------------------------
box_ok="$(setup_box 0)"; rc_ok="$(run_box "$box_ok")"
notif_ok="$(cat "$box_ok/notifications.txt" 2>/dev/null || true)"

if [ "$(printf '%s' "$notif_ok" | grep -c 'now part of your world')" -gt 0 ]; then
    ok "CONTROL: on a SUCCESSFUL import the customer is still told it is part of their world"
else
    bad "the harness never reached the importer, so the failure arms below prove nothing" \
        "notifications seen: ${notif_ok:-<none>}"
fi

if [ -s "$box_ok/.ostler/state/scan_state.json" ]; then
    ok "CONTROL: a successful import DOES record the dedupe hash, so it is not retried for ever"
else
    bad "a successful import failed to record the hash; this change broke the working path"
fi

# ---------------------------------------------------------------------------
# THE SUBJECT: the importer fails.
# ---------------------------------------------------------------------------
box_bad="$(setup_box 1)"; rc_bad="$(run_box "$box_bad")"
notif_bad="$(cat "$box_bad/notifications.txt" 2>/dev/null || true)"

if [ -n "$notif_bad" ]; then
    ok "on a FAILED import the customer is still told something (silence would be its own defect)"
else
    bad "a failed import told the customer nothing at all" "(no notification recorded)"
fi

# The exact regression: the old text claimed an import on this path.
if [ "$(printf '%s' "$notif_bad" | grep -c 'Imported your latest export')" -eq 0 ]; then
    ok "the failure notification no longer claims 'Imported your latest export'"
else
    bad "a FAILED import is still announced as 'Imported your latest export'" "$notif_bad"
fi

if [ "$(printf '%s' "$notif_bad" | grep -c 'now part of your world')" -eq 0 ]; then
    ok "and does not claim the export is now part of their world"
else
    bad "a FAILED import is announced with the success message" "$notif_bad"
fi

if [ "$(printf '%s' "$notif_bad" | grep -ci 'could not finish')" -gt 0 ]; then
    ok "it says plainly that the import could not finish"
else
    bad "the failure notification does not tell the customer the import did not finish" "$notif_bad"
fi

# ---------------------------------------------------------------------------
# THE CONSEQUENCE, which is the half that made it permanent: a failed import
# must NOT record the dedupe hash, or the export set is skipped for ever.
# ---------------------------------------------------------------------------
if [ ! -s "$box_bad/.ostler/state/scan_state.json" ]; then
    ok "a failed import records NO dedupe hash, so the export set is not skipped for ever"
else
    bad "a failed import recorded the dedupe hash; this export will never be retried" \
        "$(cat "$box_bad/.ostler/state/scan_state.json")"
fi

# And prove the CONSEQUENCE behaviourally rather than by inspecting state:
# run the same box again with a now-working importer and require that it
# actually retries and succeeds.
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$box_bad/.ostler/bin/ostler-import"
chmod +x "$box_bad/.ostler/bin/ostler-import"
: > "$box_bad/notifications.txt"
run_box "$box_bad" >/dev/null
notif_retry="$(cat "$box_bad/notifications.txt" 2>/dev/null || true)"
if [ "$(printf '%s' "$notif_retry" | grep -c 'now part of your world')" -gt 0 ]; then
    ok "BEHAVIOURAL: the next tick RETRIES the failed export and succeeds, which the old code made impossible"
else
    bad "the export was not retried after the importer recovered" "notifications: ${notif_retry:-<none>}"
fi

# ---------------------------------------------------------------------------
# MUST-FAIL CONTROL on the dedupe predicate itself: an export set whose hash
# IS recorded must be skipped, or the arm above would pass even if dedupe were
# broken entirely and everything were retried always.
# ---------------------------------------------------------------------------
: > "$box_ok/notifications.txt"
run_box "$box_ok" >/dev/null
notif_second="$(cat "$box_ok/notifications.txt" 2>/dev/null || true)"
if [ -z "$notif_second" ]; then
    ok "MUST-MISS: an already-imported export set is skipped on the next tick, so dedupe still works"
else
    bad "dedupe is broken: an already-imported export was imported again" "$notif_second"
fi

printf '\n== %d pass / %d fail / %d total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
