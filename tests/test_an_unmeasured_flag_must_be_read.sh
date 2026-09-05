#!/usr/bin/env bash
# A FLAG THAT RECORDS "COULD NOT MEASURE" MUST BE READ BY SOMETHING.
#
# WHY THIS EXISTS. MEASURED 2026-09-04 against the SHIPPED v1.0.66 install.sh
# (sha256 e1cdd10c, byte-identical to the blob inside the DMG):
#
#     _HYDRATE_EMAIL_COUNTS_UNMEASURED   occurrences=1
#     _AICONV_UNMEASURED                 occurrences=1
#
# One occurrence means the flag is ASSIGNED and then read by nothing at all.
# Both sat on the failure arm of a command substitution:
#
#     )" || { _HYDRATE_EMAIL_COUNTS_UNMEASURED=true; _HYDRATE_EMAIL_COUNTS=""; }
#     )" || { _AICONV_UNMEASURED=true; _AICONV_COUNT=""; }
#
# and in both cases the very next lines turned the empty value into 0 -- via
# `case ''|*[!0-9]*) X=0` and via `${X:-0}`. So a counter that COULD NOT RUN
# was published as a MEASURED ZERO. For email the run then landed on
# "no_correspondents_in_window", a cause nobody observed.
#
# The calendar and contacts arms of the SAME FILE already carried the guard,
# and calendar's comment states the mechanism exactly:
#
#     "An UNMEASURED count must not fall through this chain. `:-0` makes it 0,
#      `-gt 0` is then false, and the run lands on a branch that declares
#      calendar_not_synced_yet -- a cause nobody observed."
#
# Seven flags of this family existed. Five were consulted, two were not, and
# nothing in the tree could tell you which. CANNOT-RUN is a third state; a
# flag nobody reads collapses it into one of the other two silently.
#
# SCOPE: install.sh only. These flags are all local to it.
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

# Echoes one "NAME total assigns" line per flag found. A flag is DEAD when
# total == assigns, i.e. every mention of it is an assignment.
_scan() {
    local f="$1" name total assigns
    grep -oE '[A-Za-z_][A-Za-z0-9_]*UNMEASURED' "$f" 2>/dev/null | sort -u | while IFS= read -r name; do
        [ -n "$name" ] || continue
        total=$(grep -oE "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|\$)" "$f" 2>/dev/null | grep -c . || true)
        assigns=$(grep -oE "(^|[^A-Za-z0-9_])${name}=" "$f" 2>/dev/null | grep -c . || true)
        printf '%s %s %s\n' "$name" "${total:-0}" "${assigns:-0}"
    done
}

# Echoes the names that are assigned and never read.
_dead() {
    _scan "$1" | while read -r name total assigns; do
        [ "${assigns:-0}" -ge 1 ] 2>/dev/null || continue
        [ "${total:-0}" -le "${assigns:-0}" ] 2>/dev/null && printf '%s\n' "$name"
    done
}

echo "── controls: the scan must prove it can SEE and can ABSTAIN ──"

cat > "${WORK}/dead.sh" <<'FIX'
#!/usr/bin/env bash
X="$(some_counter)" || { MY_COUNT_UNMEASURED=true; X=""; }
X="${X:-0}"
echo "$X"
FIX
if [ "$(_dead "${WORK}/dead.sh" | tr -d '[:space:]')" = "MY_COUNT_UNMEASURED" ]; then
    ok "MUST-FLAG: a flag set on a failure arm and never read is caught"
else
    bad "MUST-FLAG: the measured shape was MISSED. The scan is blind and every zero below is meaningless."
fi

cat > "${WORK}/live.sh" <<'FIX'
#!/usr/bin/env bash
X="$(some_counter)" || { MY_COUNT_UNMEASURED=true; X=""; }
if [[ "${MY_COUNT_UNMEASURED:-false}" == true ]]; then
    record_cannot_run
fi
X="${X:-0}"
FIX
if [ -z "$(_dead "${WORK}/live.sh")" ]; then
    ok "MUST-MISS: a flag that IS consulted is not reported"
else
    bad "MUST-MISS: flagged a guard that is present. The scan is loud, not right."
fi

cat > "${WORK}/braced.sh" <<'FIX'
#!/usr/bin/env bash
X="$(some_counter)" || { MY_COUNT_UNMEASURED=true; X=""; }
echo "${MY_COUNT_UNMEASURED}"
FIX
if [ -z "$(_dead "${WORK}/braced.sh")" ]; then
    ok "MUST-MISS: a \${BRACED} read counts as a read"
else
    bad "MUST-MISS: a \${BRACED} read was not recognised, so real guards would be reported as missing."
fi

cat > "${WORK}/prefix.sh" <<'FIX'
#!/usr/bin/env bash
A_UNMEASURED=true
LONGER_A_UNMEASURED=true
if [[ "$LONGER_A_UNMEASURED" == true ]]; then :; fi
if [[ "$A_UNMEASURED" == true ]]; then :; fi
FIX
if [ -z "$(_dead "${WORK}/prefix.sh")" ]; then
    ok "MUST-MISS: a shorter name is not matched inside a longer one"
else
    bad "MUST-MISS: substring collision -- one flag's mentions were credited to another."
fi

# ── NEGATIVE CONTROL: the tree that shipped both dead flags ──────────────
# a752275d is main at the v1.0.66 cut. Pinned to a sha, never a branch: a
# control that reads origin/main inverts the moment this fix merges.
_CONTROL_SHA="a752275d"
echo "── negative control: ${_CONTROL_SHA} (main at the v1.0.66 cut) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi
_cd="$(_dead "$_ctl" | sort | tr '\n' ' ')"
case "$_cd" in
    *_AICONV_UNMEASURED*|*_HYDRATE_EMAIL_COUNTS_UNMEASURED*)
        ok "control ${_CONTROL_SHA}: reports the two dead flags that shipped [ ${_cd}]" ;;
    "") bad "control ${_CONTROL_SHA}: reports NOTHING. That tree shipped two flags read by nothing, so this harness is not measuring the defect." ;;
    *)  bad "control ${_CONTROL_SHA}: reported [ ${_cd}] but not the two measured ones." ;;
esac

# ── THE SUBJECT ──────────────────────────────────────────────────────────
echo "── subject: this tree ──"
_sd="$(_dead "$SUBJECT" | sort | tr '\n' ' ')"
_n=$(_scan "$SUBJECT" | grep -c . || true)
if [ -z "$_sd" ]; then
    ok "all ${_n} *_UNMEASURED flag(s) in install.sh are consulted by something"
else
    bad "flag(s) assigned and read by NOTHING: ${_sd}"
    bad "  each one silently collapses CANNOT-RUN into a measured value."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
