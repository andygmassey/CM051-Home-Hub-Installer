#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_runtime_ready_status_is_read_not_fatal.sh
#
# `_ostler_verify_runtime_ready` reports THREE outcomes and install.sh has a
# `case` for each. Two of the three could never be reached.
#
# THE DEFECT (same class as #1756's :12399 / :13022 and the port preflight)
# ---------------------------------------------------------------------------
# Both call sites capture the output with a command substitution:
#
#     _rr_out="$(_ostler_verify_runtime_ready ... 2>&1)"
#     _rr_rc=$?
#     case "$_rr_rc" in
#         0) ... OK ...
#         2) ... CANNOT-RUN ...
#         *) ... FAILED ...
#     esac
#
# A simple assignment carries the exit status of its command substitution, so
# under `set -e` a non-zero return aborts AT THE ASSIGNMENT. `_rr_rc=$?` never
# runs and the case never sees anything but 0. Measured:
#
#     x="$(f)"  where f returns 1, under set -Eeuo pipefail  -> rc=1, aborts
#
# So the CANNOT-RUN and FAILED branches were dead code, and the comment above
# the install-path site -- "distinguishes not-ready from could-not-look" --
# described a distinction that could not happen.
#
# WHY IT MATTERS MORE THAN IT LOOKS. Both sites are deliberately
# NON-fatal by design. The upgrade-path comment says a rollback here "would
# be worse than a loud log line the Hub health-check and support bundle both
# carry". The defect turned an intentional log-and-continue into an abort, at
# two points on the two paths every customer takes.
#
# ARM 7 IS THE RED CONTROL. Arms 1-6 would read the same if the harness had
# stopped executing the regions. It rebuilds the PRE-FIX assignment and
# requires it to abort.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH} (exit 2)" >&2; exit 2; }

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rrs.XXXXXX")" || { echo "CANNOT-RUN: mktemp failed (exit 2)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Take each region VERBATIM from install.sh: a restated copy drifts, and then
# this file tests its own fiction rather than the shipped code.
slice() { # $1 = start marker (fixed string), $2 = out file
    local n e
    n="$(grep -nF "$1" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [[ -n "$n" ]] || return 1
    e="$(awk -v s="$n" 'NR>=s && /^[[:space:]]*esac[[:space:]]*$/ {print NR; exit}' "$INSTALL_SH")"
    [[ -n "$e" ]] || return 1
    sed -n "${n},${e}p" "$INSTALL_SH" > "$2"
}

slice '_upg_rr_out=""; _upg_rr_rc=0' "${WORK}/upgrade" \
    || { echo "CANNOT-RUN: could not slice the upgrade-path region (exit 2)" >&2; exit 2; }
slice '_rr_out=""; _rr_rc=0' "${WORK}/install" \
    || { echo "CANNOT-RUN: could not slice the install-path region (exit 2)" >&2; exit 2; }
ok "0 sliced both regions verbatim ($(wc -l < "${WORK}/upgrade" | tr -d ' ') and $(wc -l < "${WORK}/install" | tr -d ' ') lines)"

drive() { # $1 region file, $2 stub rc, $3 logger definition -> "exit|output"
    {
        printf 'set -Eeuo pipefail\n'
        printf 'HOME=/tmp; OSTLER_DIR=/tmp; OSTLER_FINAL_DIR=/tmp\n'
        printf '%s\n' "$3"
        printf '_ostler_verify_runtime_ready() { echo stub; return %s; }\n' "$2"
        printf 'run() {\n'; cat "$1"; printf '}\n'
        printf 'run\nprintf "SURVIVED"\n'
    } > "${WORK}/drive.sh"
    local out rc; out="$(bash "${WORK}/drive.sh" 2>/dev/null)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

UPLOG='_upg_log() { printf "%s" "$1"; }'
INLOG='_ostler_promote_venv_note() { printf "%s" "$1"; }'

check() { # $1 label, $2 region, $3 rc, $4 logger, $5 expected substring, $6 arm
    local r; r="$(drive "$2" "$3" "$4")"
    if [[ "$r" == 0\|* && "$r" == *"$5"* ]]; then
        ok "$6 ${1} rc ${3} -> survives, took the ${5} branch"
    else
        bad "$6 ${1} rc ${3} -> [${r%%|*}] wanted exit 0 and '${5}' (aborted or wrong branch)"
    fi
}

check "upgrade" "${WORK}/upgrade" 0 "$UPLOG" "OK"         1
check "upgrade" "${WORK}/upgrade" 2 "$UPLOG" "CANNOT-RUN" 2
check "upgrade" "${WORK}/upgrade" 1 "$UPLOG" "FAILED"     3
check "install" "${WORK}/install" 0 "$INLOG" "OK"         4
check "install" "${WORK}/install" 2 "$INLOG" "CANNOT-RUN" 5
check "install" "${WORK}/install" 1 "$INLOG" "FAILED"     6

# 7. RED CONTROL: the pre-fix assignment must abort, or arms 1-6 prove nothing.
{
    printf '_rr_out="$(_ostler_verify_runtime_ready x y 2>&1)"\n'
    printf '_rr_rc=$?\ncase "$_rr_rc" in\n    0) printf OK ;;\n    *) printf FAILED ;;\nesac\n'
} > "${WORK}/prefix"
rp="$(drive "${WORK}/prefix" 1 "$INLOG")"
if [[ "$rp" == 0\|* ]]; then
    bad "7 RED CONTROL: the pre-fix assignment did NOT abort -- this test cannot fail"
else
    ok "7 RED CONTROL: the pre-fix assignment aborts on a non-zero return (rc ${rp%%|*})"
fi

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
