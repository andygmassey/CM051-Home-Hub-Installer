#!/usr/bin/env bash
#
# NO CALL SITE OF _ostler_wire_store_auth_pth MAY PASS A STAGING ROOT.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS, AND WHY THE EXISTING TESTS DID NOT CATCH IT
# ---------------------------------------------------------------------------
# #595 (A1) was found by walking v1.0.57: the store-auth .pth had
# /tmp/ostler-prelaunch-<pid>/lib baked into it, so the import failed at every
# python startup, for ever, on every install.
#
# CM051 #1316 fixed that by hardening the FUNCTION'S DEFAULT:
#
#     local _root="${2:-${OSTLER_FINAL_DIR:-${HOME}/.ostler}}"
#
# and tests/test_store_auth_pth_uses_final_dir.sh pins that default. Both are
# correct and both still pass.
#
# 🔴 AND THE DEFECT SURVIVED ANYWAY, because a default only applies when the
# argument is ABSENT. install.sh:6815 passed $2 EXPLICITLY as ${OSTLER_DIR},
# which overrode the hardened default in silence. The function was fixed; one
# of its CALLERS was never in the fix's population.
#
# That is the #600 lesson repeating one layer down: a guard that checks the
# DEFINITION cannot see a CALL SITE. So this test's population is the call
# sites, and its denominator is printed on every run.
#
# THE PREDICATE, stated so it can be argued with:
#   a call to _ostler_wire_store_auth_pth,
#   executing ABOVE the OSTLER-PROMOTE-BOUNDARY contract line,
#   whose SECOND argument interpolates ${OSTLER_DIR}
#   -- because above that line OSTLER_DIR is still the /tmp staging tree, and
#      a .pth is a DURABLE artefact that outlives it.
#
# ${OSTLER_FINAL_DIR} and ${_UPG_OSTLER_DIR} are NOT staging and must not be
# flagged. Note ${_UPG_OSTLER_DIR} CONTAINS the substring OSTLER_DIR, so a
# careless pattern convicts the three innocent upgrade-path callers. The
# negative control below exists precisely to catch that mistake.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"

if [ ! -r "${INSTALL_SH}" ]; then
    printf 'CANNOT-RUN: install.sh not readable at %s\n' "${INSTALL_SH}" >&2
    exit 2
fi

# --- the boundary, located the way the shipped estate locates it -------------
#
# ⚠️ EXACTLY ONE, AND THE FIRST DRAFT OF THIS TEST PROVED WHY.
#
# The first draft took `| head -1` and accepted any number of matches. The fix
# commit's own explanatory comment mentioned the marker token, so grep found
# THAT at ~6818 instead of the real contract line at ~14505. The boundary moved
# 7,700 lines earlier, the "above the boundary" population collapsed to 4, and
# the test printed a confident PASS over a subject it had mostly not examined.
#
# The controls still fired -- they are string-based and independent of the
# boundary -- which is exactly why a green control set is not a licence to
# trust the denominator. A marker that anchors a population MUST be unique, so
# a second occurrence is CANNOT-RUN, not a tie-break.
BOUNDARY_COUNT="$(/usr/bin/grep -c 'OSTLER-PROMOTE''-BOUNDARY' "${INSTALL_SH}" || true)"
if [ "${BOUNDARY_COUNT}" -ne 1 ]; then
    printf 'CANNOT-RUN: expected EXACTLY 1 promote-boundary marker, found %s.\n' "${BOUNDARY_COUNT}" >&2
    printf '            The marker anchors this test population. Zero means the\n' >&2
    printf '            contract line is gone; more than one means something else\n' >&2
    printf '            (probably a COMMENT ABOUT the marker) is shadowing it and\n' >&2
    printf '            the boundary would be wrong. Either way: no verdict.\n' >&2
    exit 2
fi
BOUNDARY_LINE="$(/usr/bin/grep -n 'OSTLER-PROMOTE''-BOUNDARY' "${INSTALL_SH}" | cut -d: -f1)"

# The staging shape. Anchored on "${OSTLER_DIR" with a following : or } so that
# "${_UPG_OSTLER_DIR" and "${OSTLER_FINAL_DIR" cannot match.
STAGING_RE='\$\{OSTLER_DIR[:}]'

# _is_staging_call <line-text> -> rc 0 if the call passes a staging root
_is_staging_call() {
    # Strip everything up to and including the function name, so the FIRST
    # argument's own text cannot be mistaken for the second.
    local rest="${1#*_ostler_wire_store_auth_pth}"
    printf '%s' "${rest}" | /usr/bin/grep -qE "${STAGING_RE}"
}

# --- CONTROLS FIRST. A predicate that has not been shown to fire proves -------
# --- nothing when it reports zero. -------------------------------------------
POS='    _ostler_wire_store_auth_pth "$PYTHON3_BIN" "${OSTLER_DIR:-${HOME}/.ostler}" \'
NEG_FINAL='    _ostler_wire_store_auth_pth "$PYTHON3_BIN" "${OSTLER_FINAL_DIR:-${HOME}/.ostler}" \'
NEG_UPG='        _ostler_wire_store_auth_pth "${_dir}/.venv" "${_UPG_OSTLER_DIR:-${HOME}/.ostler}" \'
NEG_NOROOT='    _ostler_wire_store_auth_pth "$OSTLER_VENV" \'

_control_fail=0

# POSITIVE: this is the REAL pre-fix text of install.sh:6815, verbatim, not a
# synthetic mutant. If the predicate does not convict it, the predicate is
# broken and every zero it reports below is meaningless.
if _is_staging_call "${POS}"; then
    printf '  control+ OK   the real pre-fix 6815 line IS convicted\n'
else
    printf '  control+ FAIL the real pre-fix 6815 line was NOT convicted --\n' >&2
    printf '                the predicate is broken, ignore any zero below\n' >&2
    _control_fail=1
fi

# NEGATIVE x3: the three shapes that must NEVER be convicted.
for _neg_label in FINAL UPG NOROOT; do
    case "${_neg_label}" in
        FINAL)  _neg="${NEG_FINAL}" ;;
        UPG)    _neg="${NEG_UPG}" ;;
        NOROOT) _neg="${NEG_NOROOT}" ;;
    esac
    if _is_staging_call "${_neg}"; then
        printf '  control- FAIL %s was convicted and must not be --\n' "${_neg_label}" >&2
        printf '                the pattern is too wide (OSTLER_DIR is a SUBSTRING\n' >&2
        printf '                of _UPG_OSTLER_DIR); fix the anchor, not the subject\n' >&2
        _control_fail=1
    else
        printf '  control- OK   %s correctly not convicted\n' "${_neg_label}"
    fi
done

if [ "${_control_fail}" -ne 0 ]; then
    printf 'CANNOT-RUN: controls did not fire as specified. No verdict is offered.\n' >&2
    exit 2
fi

# --- the subject -------------------------------------------------------------
total=0
above=0
findings=0
finding_lines=""

while IFS= read -r _row; do
    _ln="${_row%%:*}"
    _txt="${_row#*:}"
    # Skip the definition itself and pure comment lines.
    case "${_txt}" in
        *'_ostler_wire_store_auth_pth()'*) continue ;;
    esac
    _trimmed="${_txt#"${_txt%%[![:space:]]*}"}"
    case "${_trimmed}" in
        '#'*) continue ;;
    esac

    total=$((total + 1))
    [ "${_ln}" -lt "${BOUNDARY_LINE}" ] || continue
    above=$((above + 1))

    if _is_staging_call "${_txt}"; then
        findings=$((findings + 1))
        finding_lines="${finding_lines} ${_ln}"
    fi
done <<EOF
$(/usr/bin/grep -n '_ostler_wire_store_auth_pth' "${INSTALL_SH}")
EOF

printf '\n'
printf 'OSTLER-PROMOTE-BOUNDARY at line %s\n' "${BOUNDARY_LINE}"
printf 'call sites examined:      %s\n' "${total}"
printf '  above the boundary:     %s   (the population that can freeze /tmp)\n' "${above}"
printf '  passing a staging root: %s\n' "${findings}"
printf '\n'

if [ "${above}" -eq 0 ]; then
    printf 'CANNOT-RUN: ZERO call sites above the boundary. That is not a clean\n' >&2
    printf '            result, it is an empty denominator -- the enumeration or\n' >&2
    printf '            the boundary is wrong. Refusing to report a pass.\n' >&2
    exit 2
fi

if [ "${findings}" -ne 0 ]; then
    printf 'FAIL: %s call site(s) pass a STAGING root to _ostler_wire_store_auth_pth.\n' "${findings}" >&2
    printf '      line(s):%s\n' "${finding_lines}" >&2
    printf '\n' >&2
    printf '      Above the promote boundary ${OSTLER_DIR} is /tmp/ostler-prelaunch-<pid>.\n' >&2
    printf '      A .pth written with that root names a directory that does not\n' >&2
    printf '      survive the install: the import fails at EVERY python startup,\n' >&2
    printf '      python prints "Remainder of file ignored" so the rest of the\n' >&2
    printf '      line is dropped too, and the services reach the stores with no\n' >&2
    printf '      credential. That is A1 / #595, measured on a real v1.0.57 walk.\n' >&2
    printf '\n' >&2
    printf '      FIX: pass ${OSTLER_FINAL_DIR}, or pass no root at all and let\n' >&2
    printf '      the hardened default in _ostler_wire_store_auth_pth apply.\n' >&2
    exit 1
fi

printf 'PASS: %s of %s call site(s) sit above the promote boundary and NONE of\n' "${above}" "${total}"
printf '      them passes a staging root. Controls fired: the real pre-fix 6815\n'
printf '      line is convicted by this same predicate, and the FINAL / _UPG /\n'
printf '      no-root shapes are not.\n'
exit 0
