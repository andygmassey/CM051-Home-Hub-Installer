#!/bin/bash
# A guard that cannot distinguish its own failure from a clean result is not a
# guard. BOARD ROW 2211.
#
# ${OSTLER_DIR}/bin/ostler-meeting-brief-sender asks the hub whether the People
# Graph is degraded and must not send a brief with missing attendee facts. The
# shipped check collapsed EVERY failure of its own pipeline into the single
# answer that SENDS:
#
#     DEGRADED=$(... | python3 -c '...' 2>>"$LOG_FILE") || DEGRADED="False"
#
# so malformed JSON, a truncated response, an unwritable log, or python3
# resolving to the Apple stub on a box without Command Line Tools all read as
# "healthy". It runs unattended on a schedule and its own log recorded nothing,
# because the failure was consumed by the ||.
#
# THIS DRIVES THE REAL BLOCK, lifted from install.sh BY MARKER rather than by
# line number, so the test cannot silently drift onto different code. It runs
# each outcome with a stub python3 on PATH and asserts which of them reach the
# send path.
#
# The MUTANT is the pre-fix block. It must SEND on a python3 failure, or this
# file proves nothing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$INSTALL" ] || cant "install.sh is not readable at ${INSTALL}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- lift the real block, by marker ---
BLOCK="${WORK}/block.sh"
awk '/# Degraded short-circuit, with THREE outcomes rather than two\./{f=1}
     f{print}
     f&&/^esac$/{exit}' "$INSTALL" > "$BLOCK"

if [ ! -s "$BLOCK" ]; then
    cant "the degraded block could not be lifted from install.sh by its marker. The marker may have been reworded, in which case this gate is reading nothing and must not report a pass."
fi
if ! grep -q 'DEGRADED_RC' "$BLOCK" || ! grep -q '^esac$' "$BLOCK"; then
    cant "the lifted block does not contain the three-outcome shape; refusing to grade it"
fi
printf '     EXAMINED: %d line(s) lifted from install.sh by marker\n' "$(wc -l < "$BLOCK" | tr -d ' ')"

# --- harness: run a block with a stubbed python3 ---
run_case() {  # run_case <block> <python3-stub-body> <response> -> prints VERDICT
    local blk="$1" stub="$2" resp="$3"
    local d="${WORK}/case.$$.$RANDOM"
    mkdir -p "${d}/bin"
    printf '%s\n' "$stub" > "${d}/bin/python3"
    chmod +x "${d}/bin/python3"
    {
        printf 'PATH="%s/bin:$PATH"\n' "$d"
        printf 'LOG_FILE="%s/log"\n' "$d"
        printf 'RESPONSE=%q\n' "$resp"
        cat "$blk"
        printf '\necho SENT_THE_BRIEF >> "%s/log"\n' "$d"
    } > "${d}/run.sh"
    bash "${d}/run.sh" >/dev/null 2>&1
    if grep -q SENT_THE_BRIEF "${d}/log" 2>/dev/null; then printf 'SENT'; else printf 'SKIPPED'; fi
    cat "${d}/log" > "${WORK}/lastlog" 2>/dev/null || :
}

REAL_PY='#!/bin/bash
exec /usr/bin/python3 "$@"'
FAILING_PY='#!/bin/bash
echo "boom" >&2
exit 1'
GARBAGE_PY='#!/bin/bash
echo banana'

echo "-- controls: the harness must be able to say SENT --"
v="$(run_case "$BLOCK" "$REAL_PY" '{"degraded": false}')"
if [ "$v" = "SENT" ]; then
    ok "CONTROL: a healthy hub reaches the send path, so SKIPPED below is a real refusal and not a broken harness"
else
    bad "CONTROL: a healthy hub did NOT reach the send path, so every SKIPPED below is meaningless"
fi

echo "-- subject: the three outcomes --"
v="$(run_case "$BLOCK" "$REAL_PY" '{"degraded": true}')"
[ "$v" = "SKIPPED" ] && ok "degraded=true does not send" || bad "degraded=true SENT the brief"

v="$(run_case "$BLOCK" "$FAILING_PY" '{"degraded": false}')"
if [ "$v" = "SKIPPED" ]; then
    ok "THE ROW 2211 CASE: python3 fails and the brief is NOT sent"
    grep -q 'CANNOT-RUN' "${WORK}/lastlog" 2>/dev/null \
        && ok "and the log SAYS it could not determine, so the skip is visible" \
        || bad "the brief was skipped but the log does not say why, which is the half that made this invisible"
else
    bad "THE ROW 2211 DEFECT IS LIVE: python3 failed and the brief was SENT, with possibly missing attendee facts"
fi

v="$(run_case "$BLOCK" "$REAL_PY" 'this is not json at all')"
[ "$v" = "SKIPPED" ] && ok "malformed JSON does not send" || bad "malformed JSON SENT the brief"

v="$(run_case "$BLOCK" "$GARBAGE_PY" '{"degraded": false}')"
[ "$v" = "SKIPPED" ] && ok "an unrecognised degraded value does not send" || bad "an unrecognised value SENT the brief"

echo "-- MUTANT: the pre-fix block must send on a failure --"
MUT="${WORK}/mutant.sh"
cat > "$MUT" <<'MUTEOF'
DEGRADED=$(printf '%s' "${RESPONSE}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("degraded", False))' \
    2>>"${LOG_FILE}") || DEGRADED="False"
if [[ "${DEGRADED}" == "True" ]]; then
    echo "skip: hub degraded" >> "${LOG_FILE}"
    exit 0
fi
MUTEOF
v="$(run_case "$MUT" "$FAILING_PY" '{"degraded": false}')"
if [ "$v" = "SENT" ]; then
    ok "MUTANT: the pre-fix block SENDS when python3 fails, so the arms above discriminate rather than merely pass"
else
    bad "MUTANT: the pre-fix block also refused, so this file cannot tell the fix from the defect and proves nothing"
fi

echo
printf '== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
