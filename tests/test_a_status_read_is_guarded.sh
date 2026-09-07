#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_a_status_read_is_guarded.sh
#
# A STANDALONE READ OF `$?` MEANS SOMEONE IS TREATING A NON-ZERO EXIT AS DATA.
# Under `set -e` that is a defect unless the region has deliberately disabled
# errexit, or the enclosing function is called via `$( )`.
#
# WHAT IT COST, MEASURED 2026-09-07
# ---------------------------------------------------------------------------
# Two box walks of v1.0.73 aborted on this class, both with the correct
# handling sitting DOWNSTREAM of the line that aborted:
#
#     :12399   _ollama_agent_is_running; [[ $? -eq 2 ]] && ...
#              the 90s poll built to wait out that exact window never ran
#     :13022   tr < /dev/urandom | head -c 20      (SIGPIPE, same family)
#
# Three more were found by hand afterwards, two of them live:
#
#     :16613   _check_port ...; case $? in        port preflight
#     :2941    _rr_out="$(...)"; _rr_rc=$?        install path
#     :995     same shape, UPGRADE path -- NOT live, that region runs
#              under a deliberate `set +e`
#
# CM051 #1756 and #1759.
#
# WHY A RATCHET AND NOT A CLASSIFIER
# ---------------------------------------------------------------------------
# Whether a given site is fatal depends on two things no line-local check can
# see, and I got both wrong before measuring them:
#
#   1. HOW THE ENCLOSING FUNCTION IS CALLED. The same body aborts when the
#      function is called bare and survives when it is called via `$( )`:
#
#          g(){ local o r; o="$(f)"; r=$?; echo "reached $r"; }   # f returns 1
#          g          -> exit 1, "reached" never prints
#          x=$(g)     -> exit 0, "reached 1" prints
#
#   2. WHETHER A CONDITIONAL `set +e` HAS RUN. install.sh:499 is `set +e`
#      inside the upgrade-mode branch opened at :495, so file-order "last
#      toggle before line N" is wrong: lines execute in call order.
#
# So this file does NOT decide which sites are fatal. It freezes the
# population and requires a NEW one to be justified, which is the same
# contract as tests/pipefail_shortcircuit_baseline.txt.
#
# AND SHELLCHECK DOES NOT COVER IT. Calibrated with a positive control:
# SC2181 fires on `foo; if [ $? -eq 0 ]` but NOT on `foo; case $? in` and NOT
# on `x="$(foo)"; rc=$?` -- the two shapes that actually bit us. shellcheck
# runs in 0 workflows here, and wiring it would not have caught any of the
# five sites.
#
# THE SAFE FORM NEEDS NO BASELINE ENTRY:
#
#     rc=0
#     cmd || rc=$?
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
BASELINE="${HERE}/status_read_baseline.txt"

[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH} (exit 2)" >&2; exit 2; }
[[ -f "$BASELINE"   ]] || { echo "CANNOT-RUN: no baseline at ${BASELINE} (exit 2)" >&2; exit 2; }

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/srg.XXXXXX")" || { echo "CANNOT-RUN: mktemp failed (exit 2)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# The predicate, in one place so the controls below exercise the SAME code
# the verdict uses. `|| rc=$?` is excluded because that IS the fix; `trap`
# lines and `return $?` pass the status on rather than branching on it.
scan() { # $1 = file -> "<count>\t<statement>" rows, sorted
    grep -hE '\$\?' "$1" \
        | grep -vE '^[[:space:]]*#' \
        | grep -vE '\|\|' \
        | grep -vE 'trap |return \$\?' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | sort | uniq -c \
        | sed -E 's/^[[:space:]]*([0-9]+) /\1\t/'
}

grep -v '^#' "$BASELINE" | grep -vE '^[[:space:]]*$' > "${WORK}/base"
scan "$INSTALL_SH" > "${WORK}/now"

_bn="$(grep -c . "${WORK}/base")"
_nn="$(grep -c . "${WORK}/now")"
if [[ "$_bn" -ge 1 && "$_nn" -ge 1 ]]; then
    ok "0 baseline has ${_bn} shape(s), the scan found ${_nn}"
else
    echo "CANNOT-RUN: baseline ${_bn} rows, scan ${_nn} rows -- one of them is" >&2
    echo "            empty, so every comparison below would be vacuous (exit 2)" >&2
    exit 2
fi

# 1. POSITIVE CONTROL. The predicate must FIND a standalone status read, or
#    every "no new sites" verdict below is a broken search reading as clean.
cat > "${WORK}/positive" <<'POS'
#!/usr/bin/env bash
some_command_that_returns_data
SYNTHETIC_CONTROL_RC=$?
POS
if grep -q 'SYNTHETIC_CONTROL_RC' <<< "$(scan "${WORK}/positive")"; then
    ok "1 CONTROL: the predicate detects a synthetic standalone status read"
else
    bad "1 CONTROL: the predicate found NOTHING in a file built to contain one"
fi

# 2. MUST-MISS. The guarded form is the remedy, so flagging it would make the
#    fix impossible and the gate would push people back to the defect.
cat > "${WORK}/mustmiss" <<'MISS'
#!/usr/bin/env bash
rc=0
some_command_that_returns_data || rc=$?
MISS
if grep -q '\$?' <<< "$(scan "${WORK}/mustmiss")"; then
    bad "2 MUST-MISS: the guarded form '|| rc=\$?' was flagged -- it is the FIX"
else
    ok "2 MUST-MISS: the guarded form is not flagged"
fi

# 3. no NEW statement shape
comm -13 <(cut -f2- "${WORK}/base" | sort) <(cut -f2- "${WORK}/now" | sort) > "${WORK}/new"
if [[ ! -s "${WORK}/new" ]]; then
    ok "3 no new standalone status-read shape"
else
    bad "3 NEW standalone status read(s) -- guard with '|| rc=\$?' or justify in the baseline:"
    sed 's/^/          /' "${WORK}/new" | head -10
fi

# 4. THE RATCHET, AND IT LOWERS ITSELF. The ceiling is the baseline total
#    MINUS anything that has since been fixed, so a struck shape tightens the
#    gate instead of leaving slack behind. A plain "total <= baseline total"
#    would let a fixed site's allowance be spent on a new one somewhere else.
comm -23 <(cut -f2- "${WORK}/base" | sort) <(cut -f2- "${WORK}/now" | sort) > "${WORK}/gone"
_ceiling="$(awk -F'\t' -v G="${WORK}/gone" '
    FILENAME==G { gone[$0]=1; next }
    !($2 in gone) { s+=$1 }
    END { print s+0 }' "${WORK}/gone" "${WORK}/base")"
_nt="$(awk -F'\t' '{s+=$1} END {print s+0}' "${WORK}/now")"
_bt="$(awk -F'\t' '{s+=$1} END {print s+0}' "${WORK}/base")"
if [[ "$_nt" -le "$_ceiling" ]]; then
    ok "4 ratchet: ${_nt} occurrence(s), ceiling ${_ceiling} (baseline ${_bt} minus $(grep -c . "${WORK}/gone" || true) struck)"
else
    bad "4 ratchet: ${_nt} occurrence(s) exceeds the ceiling of ${_ceiling}"
fi

# 5. STRUCK SHAPES ARE A NOTE, NOT A FAILURE, AND THIS IS DELIBERATE.
#    A frozen shape disappearing means someone FIXED it. Failing on that
#    would make my gate go red on somebody else's fix -- which it did, in a
#    merge simulation against CM051 #1756: that PR removes
#    `_ollama_agent_is_running; [[ $? -eq 2 ]]` from the population, and an
#    earlier version of this file failed because of it. A gate that punishes
#    the remedy teaches people to route around the gate.
#
#    Rot cannot hide growth here, because arm 4's ceiling already excludes
#    struck shapes and arm 3 rejects new ones outright.
if [[ ! -s "${WORK}/gone" ]]; then
    ok "5 every frozen shape was found by this scan"
else
    ok "5 $(grep -c . "${WORK}/gone") shape(s) fixed since the baseline; ceiling lowered, strike them when convenient:"
    sed 's/^/          /' "${WORK}/gone" | head -6
fi

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
