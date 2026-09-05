#!/usr/bin/env bash
# ttywalk's artefact-version read must produce a VERSION or NOTHING, never a
# diagnostic wearing a value's clothes.
#
# WHY THIS EXISTS. MEASURED 2026-09-05 on the real v1.0.67 DMG. Two bugs lived
# in one line of ttywalk.sh and they hid each other:
#
#   1. ONE dirname TOO MANY. $_res is <app>/Contents/Resources, so two dirnames
#      give <app>/Info.plist, which does not exist. It is at
#      <app>/Contents/Info.plist.
#
#   2. PlistBuddy WRITES ITS ERROR TO STDOUT. `2>/dev/null` suppressed nothing.
#      Its "file does not exist, will create" diagnostic landed in
#      ARTEFACT_VERSION, `[[ -n ]]` PASSED, and the walk announced
#      `version: FileDoesn'tExist,WillCreate:...` as a success.
#
# Bug 2 is why bug 1 survived a whole walk: AN EMPTINESS CHECK CANNOT SEE A
# FAILURE THAT ANSWERS ON STDOUT. The damage was downstream -- post_walk_qa
# refused to write walks/v1.0.67.tsv because the box "said" its version was an
# error message, and a walk record is what gates promoting a release.
#
# THE FIX IS A SHAPE GUARD, NOT A PATH FIX ALONE. Correcting the path removes
# today's error; requiring digits-and-dots removes the CLASS, because any
# future diagnostic on stdout also fails the shape.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUBJECT="${ROOT}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${SUBJECT}" >&2; exit 2; }
command -v /usr/libexec/PlistBuddy >/dev/null || { echo "CANNOT-RUN: no PlistBuddy" >&2; exit 2; }
W="$(mktemp -d)" || { echo "CANNOT-RUN: no working dir" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

# A fixture bundle with the REAL layout: <app>/Contents/{Info.plist,Resources}
mkdir -p "$W/Fix.app/Contents/Resources"
cat > "$W/Fix.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>9.9.99</string>
</dict></plist>
PLIST

# The read, exactly as ttywalk performs it after the fix.
_read() {
    local res="$1" plist v
    plist="$(dirname "$res")/Info.plist"
    v=""
    if [ -f "$plist" ]; then
        v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null | tr -d '[:space:]')"
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || v=""
    fi
    printf '%s' "$v"
}

_v="$(_read "$W/Fix.app/Contents/Resources")"
[ "$_v" = "9.9.99" ] \
    && ok "a correct bundle yields its version (${_v})" \
    || bad "a correct bundle yielded '${_v}', expected 9.9.99"

# ── MUST-FLAG: the OLD two-dirname path ─────────────────────────────────
# This is the defect itself. Two dirnames point at <app>/Info.plist.
_old_path="$(dirname "$(dirname "$W/Fix.app/Contents/Resources")")/Info.plist"
[ ! -f "$_old_path" ] \
    && ok "MUST-FLAG: the two-dirname path does NOT exist on a real layout (${_old_path##*Fix.app})" \
    || bad "the two-dirname path exists, so this fixture does not reproduce the defect"

# ── THE CLASS: PlistBuddy answers on STDOUT, so emptiness is not a guard ──
_raw="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$_old_path" 2>/dev/null | tr -d '[:space:]')"
[ -n "$_raw" ] \
    && ok "CONTROL: PlistBuddy answers a MISSING file on stdout ('${_raw:0:28}...'), so a -n check passes on failure" \
    || bad "PlistBuddy returned empty for a missing file; this control no longer reproduces the class"

_guarded="$(_read "$W/Fix.app/Contents/Resources/nope")"
[ -z "$_guarded" ] \
    && ok "the SHAPE GUARD turns that diagnostic into empty, so the caller warns instead of lying" \
    || bad "the shape guard let a diagnostic through as a version: '${_guarded}'"

# ── THE BLOCK MUST RUN AT TOP LEVEL, WHICH IS WHERE IT LIVES ─────────────
# The first version of this fix used `local`. It PARSES fine -- `bash -n`
# passed -- and dies at RUNTIME with "local: can only be used in a function",
# because that block is top-level script and not a function body. Under
# `set -u` the unset name then trips unbound-variable and the walk aborts
# before staging.
#
# `bash -n` IS A PARSE, NOT AN EXECUTION. So this arm EXECUTES the extracted
# block in a top-level context under the same shell options ttywalk uses.
_BLOCK="${W}/toplevel.sh"
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' '_res="$1"'
    awk '/^    _ARTEFACT_PLIST=/,/^    fi$/' "$SUBJECT" | sed 's/^    //'
    printf '%s\n' 'printf "%s" "$ARTEFACT_VERSION"'
} > "$_BLOCK"
_out="$(bash "$_BLOCK" "$W/Fix.app/Contents/Resources" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && [ "$_out" = "9.9.99" ]; then
    ok "the block EXECUTES at top level under set -Eeuo pipefail and yields 9.9.99"
else
    bad "the block failed at top level (rc=${_rc}): ${_out:0:80}"
fi

# And the specific regression: no `local` in that block.
if awk '/^    _ARTEFACT_PLIST=/,/^    fi$/' "$SUBJECT" | /usr/bin/grep -q '^\s*local '; then
    bad "the block uses 'local' at top level -- parses, dies at runtime"
else
    ok "the block does not use 'local' outside a function"
fi

# ── The subject must actually carry the fix ──────────────────────────────
if /usr/bin/grep -q 'dirname "$(dirname "$_res")"' "$SUBJECT"; then
    bad "ttywalk.sh still uses the two-dirname path"
else
    ok "ttywalk.sh no longer uses the two-dirname path"
fi
if /usr/bin/grep -qE 'ARTEFACT_VERSION.*=~.*\^\[0-9\]' "$SUBJECT"; then
    ok "ttywalk.sh guards ARTEFACT_VERSION on SHAPE, not merely emptiness"
else
    bad "ttywalk.sh has no shape guard on ARTEFACT_VERSION; a stdout diagnostic can still pass -n"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
