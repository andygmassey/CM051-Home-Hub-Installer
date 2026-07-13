#!/usr/bin/env bash
#
# tests/test_fda_assist_ordering.sh
#
# DMG #48d (2026-05-28) ordering regression test.
#
# Locks the invariant that the FDA assist dialog (open System Settings
# at the Full Disk Access pane + blocking osascript modal) fires
# BEFORE the ostler_fda.extract_all.run_all() Python heredoc inside
# the fda_extract step of install.sh.
#
# WHY THIS TEST EXISTS
#
# DMG #48c (PR #195) claimed to move the FDA assist before the
# extractor but the move was undone by a false-positive probe at the
# top of the fda_extract step. The probe tested `[[ -r ~/Library/Mail ]]`
# (a user-owned directory that passes `-r` even without FDA) and
# `ls ~/Library/Application Support/com.apple.TCC/TCC.db` (`ls` on a
# file only needs read on the parent dir, not the file itself), so
# FDA_GRANTED was set to true on every fresh customer Mac. The
# assist block at lines ~4915-4988 was gated `if [[ FDA_GRANTED ==
# false ]]` and was therefore skipped. The Python extractor then ran
# without FDA and every macOS-DB source failed with "unable to open
# database file" -- leaving the customer's wiki empty.
#
# DMG #48d replaces the probe with an honest first-byte read of
# Safari/Messages/Mail DBs (paths macOS TCC denies open() on without
# FDA) and adds the FDA_ASSIST_TRIGGER marker. This test asserts:
#
#   1. The FDA_ASSIST_TRIGGER marker is present in install.sh.
#   2. The marker appears BEFORE the `progress "Extracting data
#      from your Mac"` line that starts the fda_extract step.
#   3. The marker appears BEFORE the Python extract_all import.
#   4. The honest read-probe is in place (head -c 1 against
#      FDA-gated SQLite DBs, not the broken [[ -r ]] || ls test).
#   5. The probe references Safari/Messages/Mail paths that
#      actually require FDA to open.
#   6. The assist dialog still opens System Settings to the Full
#      Disk Access pane and renders the osascript modal.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL [setup]: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

# ── Case 1: FDA_ASSIST_TRIGGER marker present ──────────────────────
if ! grep -q "FDA_ASSIST_TRIGGER" "$INSTALL_SH"; then
    echo "FAIL [case-1]: FDA_ASSIST_TRIGGER marker missing from install.sh" >&2
    echo "  The marker locks the ordering invariant at CI level. Add a" >&2
    echo "  comment containing FDA_ASSIST_TRIGGER above the fda_extract" >&2
    echo "  step's progress line to satisfy this guard." >&2
    exit 1
fi
echo "PASS [case-1]: FDA_ASSIST_TRIGGER marker present"

# ── Case 2: marker appears BEFORE the progress line ────────────────
# The prompt's spec: `awk '/FDA_ASSIST_TRIGGER/{a=NR}
# /fda_extract/{e=NR} END{exit !(a>0 && a<e)}'`. We use a stricter
# variant pinned to the exact `progress` line that kicks off the
# step, so a future refactor that adds new fda_extract references
# downstream cannot mask a regression.
PROGRESS_LINE=$(awk '/progress "Extracting data from your Mac.*fda_extract"/{print NR; exit}' "$INSTALL_SH")
FIRST_TRIGGER_LINE=$(awk '/FDA_ASSIST_TRIGGER/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$PROGRESS_LINE" ]]; then
    echo "FAIL [case-2]: could not locate the fda_extract progress line" >&2
    exit 1
fi
if [[ -z "$FIRST_TRIGGER_LINE" ]]; then
    echo "FAIL [case-2]: could not locate any FDA_ASSIST_TRIGGER marker" >&2
    exit 1
fi
if (( FIRST_TRIGGER_LINE >= PROGRESS_LINE )); then
    echo "FAIL [case-2]: FDA_ASSIST_TRIGGER (line $FIRST_TRIGGER_LINE) must appear BEFORE the fda_extract progress line ($PROGRESS_LINE)" >&2
    echo "  Move the marker comment above 'progress \"Extracting data from your Mac\"' to restore the ordering invariant." >&2
    exit 1
fi
echo "PASS [case-2]: FDA_ASSIST_TRIGGER at line $FIRST_TRIGGER_LINE precedes fda_extract progress at line $PROGRESS_LINE"

# ── Case 3: marker also satisfies the prompt's awk-style guard ─────
# This is the exact ordering check spelled out in the DMG #48d brief.
# Tracks the LAST FDA_ASSIST_TRIGGER (a) and the LAST occurrence of
# `fda_extract` anywhere in install.sh (e); a must be > 0 and < e.
if ! awk '/FDA_ASSIST_TRIGGER/{a=NR} /fda_extract/{e=NR} END{exit !(a>0 && a<e)}' "$INSTALL_SH"; then
    echo "FAIL [case-3]: awk ordering guard failed" >&2
    exit 1
fi
echo "PASS [case-3]: awk ordering guard satisfied"

# ── Case 4: marker appears BEFORE the Python extract_all import ────
# This is the load-bearing assertion -- the actual extractor runs
# inside this heredoc. If the marker slipped below the import, the
# assist would be running AFTER the extractor and we would be back
# in the DMG #48c regression.
IMPORT_LINE=$(awk '/^from ostler_fda.extract_all import run_all/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$IMPORT_LINE" ]]; then
    echo "FAIL [case-4]: could not locate the run_all import" >&2
    exit 1
fi
if (( FIRST_TRIGGER_LINE >= IMPORT_LINE )); then
    echo "FAIL [case-4]: FDA_ASSIST_TRIGGER (line $FIRST_TRIGGER_LINE) must appear BEFORE the run_all import (line $IMPORT_LINE)" >&2
    exit 1
fi
echo "PASS [case-4]: FDA_ASSIST_TRIGGER precedes run_all import (line $IMPORT_LINE)"

# ── Case 5: honest read-probe is in place ──────────────────────────
# DMG #48c shipped `[[ -r "$probe" ]] || ls "$probe" >/dev/null 2>&1`
# which silently returned true without FDA. DMG #48d replaces it with
# `head -c 1` (or equivalent first-byte read) against FDA-gated paths.
# Asserting the new shape AND the absence of the old shape locks the
# fix at the byte level.
if ! grep -q "_fda_read_probe" "$INSTALL_SH"; then
    echo "FAIL [case-5]: install.sh missing the _fda_read_probe helper" >&2
    exit 1
fi
if ! grep -q 'head -c 1 "\$1"' "$INSTALL_SH"; then
    echo "FAIL [case-5]: _fda_read_probe must use 'head -c 1' to force an open() against the file (not the parent dir)" >&2
    exit 1
fi
# Negative: the broken `[[ -r "$probe" ]] || ls "$probe"` combination
# from DMG #48c must NOT reappear inside the fda_extract step. We
# limit the scan to the step body to avoid false positives from
# unrelated `[[ -r ]]` checks elsewhere in install.sh.
FDA_STEP_BODY=$(awk '
    /progress "Extracting data from your Mac.*fda_extract"/ { in_step=1 }
    in_step && /^# ── 3\.8 Docker services/ { exit }
    in_step { print }
' "$INSTALL_SH")
if printf '%s\n' "$FDA_STEP_BODY" | grep -q '\[\[ -r "\$probe" \]\] || ls "\$probe"'; then
    echo "FAIL [case-5]: the broken DMG #48c heuristic ([[ -r ]] || ls) is still in the fda_extract step" >&2
    exit 1
fi
echo "PASS [case-5]: honest read-probe (head -c 1) replaces the DMG #48c heuristic"

# ── Case 6: probe references FDA-gated paths, not user-owned dirs ──
# The probe MUST target paths that macOS TCC actually denies open()
# on without FDA. ~/Library/Safari/History.db and
# ~/Library/Messages/chat.db are the canonical examples. The DMG
# #48c paths (~/Library/Mail as a directory) are user-owned and pass
# `-r` even without FDA, which is what produced the false positive.
if ! printf '%s\n' "$FDA_STEP_BODY" | grep -q 'Library/Safari/History.db'; then
    echo "FAIL [case-6]: probe missing Safari History.db reference" >&2
    exit 1
fi
if ! printf '%s\n' "$FDA_STEP_BODY" | grep -q 'Library/Messages/chat.db'; then
    echo "FAIL [case-6]: probe missing Messages chat.db reference" >&2
    exit 1
fi
echo "PASS [case-6]: probe targets FDA-gated SQLite DBs (Safari + Messages)"

# ── Case 7: assist dialog still opens FDA pane + osascript modal ───
# Move/duplicate must not have stripped the System Settings deep
# link or the blocking dialog.
#
# Platform seam (2026-07): the deep link itself now lives behind
# platform_open_fda_pane in platform/macos.sh, so the guarantee is
# asserted in two fail-closed halves: (a) the step body invokes the
# opener (or still carries the raw link), AND (b) the macOS platform
# module carries the deep link. Dropping either half fails.
if ! printf '%s\n' "$FDA_STEP_BODY" | grep -qE 'platform_open_fda_pane|x-apple\.systempreferences.*Privacy_AllFiles'; then
    echo "FAIL [case-7]: assist block missing System Settings FDA-pane deep link (raw or via platform_open_fda_pane)" >&2
    exit 1
fi
PLATFORM_MODULE="${REPO_ROOT}/platform/macos.sh"
if ! grep -q 'x-apple.systempreferences.*Privacy_AllFiles' "$PLATFORM_MODULE"; then
    echo "FAIL [case-7]: platform/macos.sh missing the FDA-pane deep link behind platform_open_fda_pane" >&2
    exit 1
fi
if ! printf '%s\n' "$FDA_STEP_BODY" | grep -q 'display dialog'; then
    echo "FAIL [case-7]: assist block missing display dialog AppleScript" >&2
    exit 1
fi
if ! printf '%s\n' "$FDA_STEP_BODY" | grep -q 'OSTLER_GUI.*== "1"'; then
    echo "FAIL [case-7]: assist block missing OSTLER_GUI gate" >&2
    exit 1
fi
echo "PASS [case-7]: assist dialog still opens FDA pane + renders modal under OSTLER_GUI"

# ── Case 8: install.sh remains bash-syntax-clean ───────────────────
if ! bash -n "$INSTALL_SH"; then
    echo "FAIL [case-8]: bash -n install.sh reported a syntax error" >&2
    exit 1
fi
echo "PASS [case-8]: bash -n install.sh clean"

echo ""
echo "ALL DMG #48d FDA ASSIST ORDERING TESTS PASSED"
