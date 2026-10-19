#!/usr/bin/env bash
# A Pro refusal (exit 5, paused_not_pro) is not an import failure.
#
# THE RULE (coordinator ruling (a), 19 Oct). Every importer exits 5 when
# Ostler Pro is not active and the source's free first import is already
# used (EXIT_PAUSED_NOT_PRO in CM052 src/cm052/first_import.py). Before this
# change the shipped import chain read 5 like any other non-zero:
#   * ostler-import set rc=5, so the run "failed";
#   * the Downloads scanner said "Ostler could not finish importing your ...
#     export. It will try again." and retried it every 4 hours, for ever;
#   * the install-time import printed "import had errors".
# The customer had done nothing wrong and was told the product was broken.
#
# This test runs the REAL ostler-import and the REAL scanner, extracted from
# install.sh, with stub importers. No Keychain, no TCC, no network.
#
#   ARM A  ostler-import, universal_import exits 5: rc 5 (paused), the refusal
#          text reaches the output unchanged, no failure line.
#   ARM B  CONTROL: universal_import exits 1: ostler-import still fails (rc 1).
#   ARM C  CONTROL: universal_import exits 0: rc 0.
#   ARM D  scanner, ostler-import exits 5 after printing the refusal: the
#          customer sees the refusal words, never "could not finish" and never
#          "now part of your world"; the export set is recorded (one mention
#          per attempt, no 4-hourly nag); the Doctor record says why.
#   ARM F  a refusal after a real failure keeps the failure's code (rc 1).
#   ARM E  CONTROL: scanner, ostler-import exits 1: still "could not finish",
#          and the hash is NOT recorded (retry stays).
#
# bash 3.2 compatible (macOS /bin/bash). Exit 2 = CANNOT RUN.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }
cannot() { echo "CANNOT RUN: $*" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REFUSAL_1="You've already imported your Instagram history once, free. Bringing in newer exports, and keeping Instagram up to date automatically, is part of Ostler Pro."
REFUSAL_2="Everything you've already imported stays here, and you can still search it."
CNC_TEXT="Couldn't check your Pro status. Try again."

printf '\n=== A PRO REFUSAL IS NOT AN IMPORT FAILURE ===\n\n'

# ── the real ostler-import ────────────────────────────────────────────────
IMP="$WORK/ostler-import"
awk '/cat > "\$IMPORT_SCRIPT" <<.IMPORTEOF./{f=1;next} f&&/^IMPORTEOF$/{exit} f{print}' install.sh > "$IMP"
grep -q 'ostler_fda.universal_import' "$IMP" || cannot "could not extract ostler-import from install.sh"
chmod +x "$IMP"
/bin/bash -n "$IMP" || cannot "the extracted ostler-import does not parse under /bin/bash"

imp_arm() {
    # imp_arm <universal_import rc> -> runs ostler-import, prints its rc
    local rc="$1" h="$WORK/imp_home_$1"
    rm -rf "$h"; mkdir -p "$h/.ostler/services/email-ingest/.venv/bin" "$h/.ostler/config" "$WORK/exports_$1/x"
    : > "$WORK/exports_$1/x/placeholder.json"
    {
        echo '#!/usr/bin/env bash'
        echo 'case " $* " in'
        echo '  *" -m ostler_fda.universal_import "*)'
        if [ "$rc" -eq 5 ]; then
            printf '    printf "%%s\\n" "%s" "%s"\n' "$REFUSAL_1" "$REFUSAL_2"
        fi
        if [ "$rc" -eq 6 ]; then
            printf '    printf "%%s\\n" "%s"\n' "$CNC_TEXT"
        fi
        echo "    exit $rc ;;"
        echo 'esac'
        echo 'exit 0'
    } > "$h/.ostler/services/email-ingest/.venv/bin/python"
    chmod +x "$h/.ostler/services/email-ingest/.venv/bin/python"
    HOME="$h" /bin/bash "$IMP" "$WORK/exports_$1" >"$WORK/imp_$1.log" 2>&1
    printf '%s' "$?"
}

rc_a="$(imp_arm 5)"
if [ "$rc_a" -eq 5 ]; then ok "ARM A: universal_import exit 5 makes ostler-import exit 5 (paused), not a failure code"
else bad "ARM A: ostler-import exited ${rc_a} on a Pro refusal (want 5)" "$(tail -n 5 "$WORK/imp_5.log")"; fi
if grep -qF "$REFUSAL_1" "$WORK/imp_5.log" && grep -qF "$REFUSAL_2" "$WORK/imp_5.log"; then
    ok "ARM A: the refusal text reaches the output word for word"
else bad "ARM A: the refusal text did not reach the output unchanged" "$(cat "$WORK/imp_5.log")"; fi
if grep -qiE 'fail|error|could not finish' "$WORK/imp_5.log"; then
    bad "ARM A: a Pro refusal printed a failure line" "$(cat "$WORK/imp_5.log")"
else ok "ARM A: no failure line"; fi

rc_b="$(imp_arm 1)"
if [ "$rc_b" -eq 1 ]; then ok "ARM B (control): a real universal_import failure still fails ostler-import (rc 1)"
else bad "ARM B (control): a real failure exited ${rc_b}; the 5 branch swallowed failures"; fi

rc_c="$(imp_arm 0)"
if [ "$rc_c" -eq 0 ]; then ok "ARM C (control): a clean run exits 0"
else bad "ARM C (control): a clean run exited ${rc_c}; the harness is broken" "$(tail -n 5 "$WORK/imp_0.log")"; fi

# ARM F: a refusal must never HIDE a real failure. Two export folders in one
# run: the first one's universal_import fails (1), the second is refused (5).
# The run must exit 1, because the failure is what needs fixing. Without the
# dedicated 5 branch, the later 5 overwrites rc and the failure reads as paused.
hf="$WORK/imp_home_mixed"
rm -rf "$hf"; mkdir -p "$hf/.ostler/services/email-ingest/.venv/bin" "$WORK/mixed/a_fail/x" "$WORK/mixed/b_paused/x"
: > "$WORK/mixed/a_fail/x/p.json"; : > "$WORK/mixed/b_paused/x/p.json"
{
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do last="$a"; done'
    echo 'case "$last" in'
    echo '  *a_fail*) exit 1 ;;'
    printf '  *b_paused*) printf "%%s\n" "%s" "%s"; exit 5 ;;
' "$REFUSAL_1" "$REFUSAL_2"
    echo 'esac'
    echo 'exit 0'
} > "$hf/.ostler/services/email-ingest/.venv/bin/python"
chmod +x "$hf/.ostler/services/email-ingest/.venv/bin/python"
HOME="$hf" /bin/bash "$IMP" "$WORK/mixed/a_fail" "$WORK/mixed/b_paused" >"$WORK/imp_mixed.log" 2>&1
rc_f=$?
if [ "$rc_f" -eq 1 ]; then ok "ARM F: a refusal after a real failure does not hide it (rc 1)"
else bad "ARM F: a real failure followed by a refusal exited ${rc_f} (want 1); the refusal hid the failure"; fi

# ARM G: exit 6 (could_not_check, Archie ruling) is CANNOT-RUN: rc 6, the
# "Try again" words pass through, no failure line.
rc_g="$(imp_arm 6)"
if [ "$rc_g" -eq 6 ]; then ok "ARM G: universal_import exit 6 makes ostler-import exit 6 (could not check)"
else bad "ARM G: ostler-import exited ${rc_g} on could-not-check (want 6)" "$(tail -n 5 "$WORK/imp_6.log")"; fi
if grep -qF "$CNC_TEXT" "$WORK/imp_6.log" && ! grep -qiE 'fail|error|could not finish|already imported' "$WORK/imp_6.log"; then
    ok "ARM G: says try again, and is neither a failure nor a refusal"
else bad "ARM G: wrong words on could-not-check" "$(cat "$WORK/imp_6.log")"; fi

# ── the real Downloads scanner ────────────────────────────────────────────
SCAN="$WORK/ostler-scan-exports"
awk "/^cat > \"\\\${OSTLER_DIR}\/bin\/ostler-scan-exports\" <<'SCANEOF'\$/{f=1;next} f&&/^SCANEOF\$/{exit} f{print}" \
    install.sh > "$SCAN"
[ "$(wc -l < "$SCAN" | tr -d ' ')" -gt 100 ] || cannot "could not extract the scanner from install.sh"
chmod +x "$SCAN"
/bin/bash -n "$SCAN" || cannot "the extracted scanner does not parse under /bin/bash"

setup_box() {
    local rc="$1" box="$WORK/box_$1"
    rm -rf "$box"; mkdir -p "$box/Downloads/Takeout" "$box/.ostler/bin" "$box/.ostler/state" "$box/shim"
    {
        echo '#!/usr/bin/env bash'
        if [ "$rc" -eq 5 ]; then printf 'printf "%%s\\n" "%s" "%s"\n' "$REFUSAL_1" "$REFUSAL_2"; fi
        if [ "$rc" -eq 6 ]; then printf 'printf "%%s\\n" "%s"\n' "$CNC_TEXT"; fi
        echo "exit ${rc}"
    } > "$box/.ostler/bin/ostler-import"
    chmod +x "$box/.ostler/bin/ostler-import"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${NOTIFY_LOG}"' > "$box/shim/osascript"
    chmod +x "$box/shim/osascript"
    printf '%s' "$box"
}
run_box() {
    local box="$1"
    OSTLER_CADENCE_NOW=$(( 2000000000 + 14400 )) \
    NOTIFY_LOG="$box/notifications.txt" HOME="$box" PATH="$box/shim:$PATH" \
        /bin/bash "$SCAN" >/dev/null 2>&1
    printf '%s' "$?"
}

box_p="$(setup_box 5)"; run_box "$box_p" >/dev/null
notif_p="$(cat "$box_p/notifications.txt" 2>/dev/null || true)"
act_p="$(cat "$box_p/.ostler/state/source_activity/downloads_exports.tsv" 2>/dev/null || true)"
if [ -z "$notif_p" ]; then
    bad "ARM D: the harness never reached the importer (no notification at all), so ARM D proves nothing"
else
    if printf '%s' "$notif_p" | grep -qF "$REFUSAL_1"; then ok "ARM D: the customer is shown the refusal words"
    else bad "ARM D: the refusal words were not shown" "$notif_p"; fi
    if printf '%s' "$notif_p" | grep -qi 'could not finish'; then bad "ARM D: a Pro refusal was announced as 'could not finish'" "$notif_p"
    else ok "ARM D: not announced as 'could not finish'"; fi
    if printf '%s' "$notif_p" | grep -q 'now part of your world'; then bad "ARM D: a refused import was announced as done" "$notif_p"
    else ok "ARM D: not announced as done"; fi
fi
if [ -s "$box_p/.ostler/state/scan_state.json" ]; then ok "ARM D: the export set is recorded, so the refusal is not repeated every 4 hours"
else bad "ARM D: no hash recorded; the same refusal would fire on every tick"; fi
if printf '%s' "$act_p" | grep -q '^failed=0$' && printf '%s' "$act_p" | grep -qF "already imported your Instagram history once"; then
    ok "ARM D: the Doctor record counts no failure and says why"
else bad "ARM D: the Doctor record does not say why, or counts a failure" "$act_p"; fi

box_f="$(setup_box 1)"; run_box "$box_f" >/dev/null
notif_f="$(cat "$box_f/notifications.txt" 2>/dev/null || true)"
if printf '%s' "$notif_f" | grep -qi 'could not finish'; then ok "ARM E (control): a real failure still says 'could not finish'"
else bad "ARM E (control): a real failure is no longer reported" "$notif_f"; fi
if [ ! -s "$box_f/.ostler/state/scan_state.json" ]; then ok "ARM E (control): a real failure records no hash, so it is retried"
else bad "ARM E (control): a real failure recorded the hash"; fi

box_c="$(setup_box 6)"; run_box "$box_c" >/dev/null
notif_c="$(cat "$box_c/notifications.txt" 2>/dev/null || true)"
act_c="$(cat "$box_c/.ostler/state/source_activity/downloads_exports.tsv" 2>/dev/null || true)"
if printf '%s' "$notif_c" | grep -qF "$CNC_TEXT" && ! printf '%s' "$notif_c" | grep -qiE "could not finish|already imported|now part of your world"; then
    ok "ARM H: scanner on exit 6 says try again, never a failure, refusal or done"
else bad "ARM H: wrong notification on could-not-check" "$notif_c"; fi
if [ ! -s "$box_c/.ostler/state/scan_state.json" ]; then ok "ARM H: could-not-check records no hash, so the next tick tries again"
else bad "ARM H: could-not-check recorded the hash; it would never be retried"; fi
if printf '%s' "$act_c" | grep -q '^failed=0$' && printf '%s' "$act_c" | grep -q '^last_status=cannot_run$'; then
    ok "ARM H: the Doctor record says cannot_run and counts no failure"
else bad "ARM H: the Doctor record is wrong for could-not-check" "$act_c"; fi

printf '\ndenominator: 5 runs of the real ostler-import, 3 runs of the real scanner\n'
printf '== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
