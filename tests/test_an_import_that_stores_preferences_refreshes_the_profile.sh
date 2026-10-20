#!/usr/bin/env bash
#
# tests/test_an_import_that_stores_preferences_refreshes_the_profile.sh
#
# A new customer's FIRST export import (Spotify, Netflix, a Takeout ...) wrote
# preference rows, but the interest profile that the owner digest and the
# assistant's pwg_preferences tool read is compiled only by the hourly
# editor-frontpage tick. For up to an hour the customer saw "nothing stored".
#
# ostler-import (the IMPORTEOF heredoc in install.sh) must, when its CM019 leg
# reports "Preferences created: N" with N > 0, kickstart the EXISTING
# com.creativemachines.ostler.editor-frontpage job, debounced so importers that
# finish together cause one compile.
#
# RUNTIME: the heredoc is carved out of install.sh and run against recording
# stubs. launchctl is a stub on PATH (the real one is never called). Synthetic
# data only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
LABEL="com.creativemachines.ostler.editor-frontpage"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); else printf '  [FAIL] %s\n         %s\n' "$1" "${3:-}"; FAIL=$((FAIL+1)); fi; }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL_SH"; exit 2; }
START="$(/usr/bin/grep -n "cat > \"\$IMPORT_SCRIPT\" <<'IMPORTEOF'" "$INSTALL_SH" | head -1 | cut -d: -f1)"
[ -n "$START" ] || { echo "CANNOT-RUN: the ostler-import heredoc opener is gone"; exit 2; }
END="$(awk -v s="$START" 'NR > s && /^IMPORTEOF$/ { print NR; exit }' "$INSTALL_SH")"
[ -n "$END" ] || { echo "CANNOT-RUN: the ostler-import heredoc terminator is gone"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
H="$WORK/home"; O="$H/.ostler"; BIN="$WORK/bin"
mkdir -p "$O/bin" "$O/config" "$O/services/cm019/.venv/bin" "$BIN"
IMP="$O/bin/ostler-import"
sed -n "$((START + 1)),$((END - 1))p" "$INSTALL_SH" > "$IMP"
chmod +x "$IMP"
CALLS="$WORK/calls.log"; LC="$WORK/launchctl.log"

# CM019 stub: the ingest-dir leg prints the real summary line on stderr.
cat > "$O/services/cm019/.venv/bin/python" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" ingest-dir "*) echo "  Preferences created: \${STUB_PREFS:-0}" >&2 ;;
esac
exit 0
STUB
# launchctl stub: records argv; "print" answers STUB_LC_PRINT_RC (0 = loaded).
cat > "$BIN/launchctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$LC"
[ "\${1:-}" = "print" ] && exit "\${STUB_LC_PRINT_RC:-0}"
exit 0
STUB
chmod +x "$O/services/cm019/.venv/bin/python" "$BIN/launchctl"

DROP="$WORK/drop/Spotify_Extended_Streaming"; mkdir -p "$DROP"
printf '[]\n' > "$DROP/Streaming_History_Audio_2024.json"

DEB=2   # debounce window for the test, seconds
imp() {  # imp ENV=VAL... : one ostler-import run in the foreground
    ( env -u USER_NAME HOME="$H" PATH="$BIN:$PATH" OSTLER_PREFS_RECOMPILE_DEBOUNCE_SECONDS="$DEB" "$@" "$IMP" "$WORK/drop" ) >"$WORK/out.log" 2>&1
}
settle() { sleep $((DEB + 3)); }
kicks() { { /usr/bin/grep -c "^kickstart .*${LABEL}\$" "$LC" 2>/dev/null || true; } | head -1; }
reset() { : > "$LC"; rm -rf "$O/state"; }

echo "1. an import that stored preferences refreshes the profile once"
reset; imp STUB_PREFS=42; settle
n="$(kicks)"
arm "Preferences created: 42 -> exactly one kickstart of the editor-frontpage job" "$([ "$n" = 1 ] && echo 0 || echo 1)" "kickstarts=$n; launchctl calls: $(tr '\n' '|' < "$LC")"
/usr/bin/grep -q "^kickstart -k gui/[0-9]*/${LABEL}\$" "$LC"
arm "and it is 'kickstart -k' on the gui/<uid> domain (clears a parked job)" $? "$(tr '\n' '|' < "$LC")"

echo "2. an import that stored nothing does not"
reset; imp STUB_PREFS=0; settle
n="$(kicks)"
arm "Preferences created: 0 -> no kickstart" "$([ "$n" = 0 ] && echo 0 || echo 1)" "kickstarts=$n"

echo "3. importers finishing together cause ONE compile"
reset
( imp STUB_PREFS=7 ) & ( imp STUB_PREFS=9 ) & ( imp STUB_PREFS=3 ) &
wait; settle
n="$(kicks)"
arm "three concurrent imports with preferences -> exactly one kickstart" "$([ "$n" = 1 ] && echo 0 || echo 1)" "kickstarts=$n"

echo "4. the debounce does not suppress a later import"
reset; imp STUB_PREFS=5; settle; imp STUB_PREFS=5; settle
n="$(kicks)"
arm "two imports a window apart -> two kickstarts" "$([ "$n" = 2 ] && echo 0 || echo 1)" "kickstarts=$n"

echo "5. no agent loaded (first install, before the agent exists) is not an error"
reset; imp STUB_PREFS=5 STUB_LC_PRINT_RC=113; rc=$?; settle
n="$(kicks)"
arm "label not loaded -> no kickstart and ostler-import exits 0" "$([ "$n" = 0 ] && [ "$rc" = 0 ] && echo 0 || echo 1)" "kickstarts=$n rc=$rc"

echo "6. the import does not wait for the compile"
reset; t0=$(date +%s); imp STUB_PREFS=5; t1=$(date +%s); settle
arm "ostler-import returns before the debounce window has elapsed" "$([ $((t1 - t0)) -lt "$DEB" ] && echo 0 || echo 1)" "took $((t1 - t0))s, window ${DEB}s"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
