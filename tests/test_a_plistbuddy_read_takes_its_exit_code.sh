#!/usr/bin/env bash
# A PlistBuddy READ MUST TAKE ITS EXIT CODE, BECAUSE IT ANSWERS ON STDOUT WHEN IT FAILS.
#
# WHY THIS EXISTS. MEASURED on macOS, /usr/libexec/PlistBuddy, three arms:
#
#     missing FILE   rc=1   stdout: a "file does not exist, will create" diagnostic
#     missing KEY    rc=1   stdout: ""
#     key present    rc=0   stdout: the value
#
# The first line is the whole defect: a FAILURE that writes to STDOUT. So
#
#     x="$(PlistBuddy -c 'Print :Key' "$f" 2>/dev/null)"
#     if [[ -n "$x" ]]; then ...
#
# reads a diagnostic as a value. `2>/dev/null` suppresses nothing, because the
# text was never on stderr. This is #1497: ~/.walk-artefact-version was written
# with PlistBuddy's error string and the walk record was refused for a version
# of the tool's error string instead of a version.
#
# In _upg_ensure_token the consequence is quieter and worse: `[[ -n ]]` is true,
# the function returns 0, and the service token is never written. A SILENT SKIP
# of the upgrade, not a crash.
#
# PlistBuddy DOES exit non-zero, so one `|| var=""` removes the whole class.
# This gate asserts the read takes it, and proves it can detect the absence.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Pull the REAL line out of install.sh rather than restating it.
LINE="$(grep -m1 -F 'Print :EnvironmentVariables:PWG_SERVICE_TOKEN" "$_plist" 2>/dev/null)' "$SUBJECT")"
[ -n "$LINE" ] || { echo "CANNOT-RUN: the _upg_ensure_token PlistBuddy read was not found in install.sh." >&2
                    echo "  It is extracted by its literal text so a rewrite fails LOUDLY here" >&2
                    echo "  rather than silently testing nothing." >&2; exit 2; }

# Drive the extracted line against a PlistBuddy that behaves like the real one
# on a missing file: diagnostic on STDOUT, non-zero exit.
_drive() {
    local guard="$1"
    cat > "${WORK}/pb" <<'PBEOF'
#!/bin/bash
printf "file does not exist, will create: /nope/Info.plist\n"
exit 1
PBEOF
    chmod +x "${WORK}/pb"
    cat > "${WORK}/run.sh" <<EOF
set -uo pipefail
_UPG_PB="${WORK}/pb"
_plist="/nope/Info.plist"
${guard}
if [[ -n "\$_cur" ]]; then echo "SHORT-CIRCUIT"; else echo "PROCEEDS"; fi
EOF
    /bin/bash "${WORK}/run.sh" 2>/dev/null
}

printf '\n== the shipped read ==\n'
r="$(_drive "$LINE")"
[ "$r" = PROCEEDS ] && ok "a failing PlistBuddy read leaves _cur empty -> ${r}" \
                    || bad "a failing PlistBuddy read left a DIAGNOSTIC in _cur -> ${r} (want PROCEEDS)"

printf '\n== mutation control: the pre-fix line must still show the defect ==\n'
MUT='_cur="$("$_UPG_PB" -c "Print :EnvironmentVariables:PWG_SERVICE_TOKEN" "$_plist" 2>/dev/null)"'
r2="$(_drive "$MUT")"
[ "$r2" = SHORT-CIRCUIT ] && ok "without '|| _cur=\"\"' the diagnostic is read as a value -> ${r2} (defect reproduced)" \
                          || bad "the pre-fix line did NOT reproduce the defect -> ${r2}; this harness proves nothing"

printf '\n== the real tool still behaves as measured (skipped if absent) ==\n'
PB=/usr/libexec/PlistBuddy
if [ -x "$PB" ]; then
    out="$("$PB" -c 'Print :Any' "${WORK}/definitely-not-here.plist" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
        ok "PlistBuddy still exits ${rc} with non-empty stdout on a missing file"
    else
        bad "PlistBuddy behaviour changed: rc=${rc} stdout=$([ -n "$out" ] && echo non-empty || echo empty)"
    fi
else
    printf '  [note] PlistBuddy absent on this host; the two arms above still hold\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
