#!/usr/bin/env bash
# test_store_auth_pth_uses_final_dir.sh
#
# #595. Found on the v1.0.57 launch walk by the post-install QA suite, in a
# .pth read verbatim off a freshly installed box:
#
#   import sys, os; sys.path.append("/tmp/ostler-prelaunch-2026/lib"); ...
#
# The STAGING path was baked in. That directory does not survive the install,
# so `__import__("ostler_store_auth")` fails at EVERY python startup, for ever,
# on every install. Python prints "Remainder of file ignored", which means the
# OSTLER_SECRETS_DIR default is never set and the auth wiring never happens --
# the A1 mechanism (cm059-editor 401s, Front Page never populates).
#
# 🔴 A FILE-PRESENCE CHECK CANNOT CATCH THIS, WHICH IS WHY THIS TEST IS
# BEHAVIOURAL. The .pth was present. The module was present, correctly
# installed at <final>/lib. Only the PATH INSIDE the .pth was wrong. Any test
# that asserts "the .pth exists" or "the module exists" passes on the defect.
#
# So this extracts the REAL function from install.sh, runs it with OSTLER_DIR
# deliberately pointing at a staging tree and OSTLER_FINAL_DIR at the real one,
# and reads what it actually wrote.
#
# THIRD OCCURRENCE OF THE CLASS: #177 (ollama-logrotate plist baked
# /tmp/ostler-prelaunch, died at reboot), #578 (9 plists bake ${OSTLER_DIR}
# while the staging tree is still live), and this. A value captured during
# staging and never rebound to the tree it will run from.
#
# SECOND DEFECT, SAME FILE (v1.0.82 walk, 2026-09-09). The .pth is written
# before <final>/lib/ostler_store_auth.py exists at its final path, and CPython
# runs every `import` line of a .pth at EVERY interpreter start. So each
# interpreter started in that window printed
#   Error processing line 1 of .../ostler_store_auth.pth:
#   ModuleNotFoundError: No module named 'ostler_store_auth'
# into install.log (three times on the box: install.log:175, :492, :500), and
# the install_error_honesty walk probe counted them against a run the
# installer called clean. The fix guards the import so the line is a no-op
# while the module is absent and identical in effect once it lands. Arms C
# to F below pin that, BEHAVIOURALLY, on the .pth the real function wrote:
# a real interpreter is started with the module absent (must be silent),
# with a stub present (must import it), and then with the OLD line form
# (must print the traceback, or the silence check cannot fail and is worth
# nothing).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0
ok()     { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()    { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
cannot() { printf '\n🔴 CANNOT-RUN: %s\n' "$*"; printf 'Neither a pass nor a failure. Refusing.\n'; exit 2; }

[ -f "${INSTALL_SH}" ] || cannot "install.sh not found at ${INSTALL_SH}"
command -v python3 >/dev/null 2>&1 || cannot "no python3"

# ---------------------------------------------------------------------------
# ARM A (SOURCE): the default must resolve OSTLER_FINAL_DIR, never OSTLER_DIR.
# Cheap, and it names the exact regression in the exact place.
# ---------------------------------------------------------------------------
DEFAULT_LINE=$(/usr/bin/grep -n 'local _root=' "${INSTALL_SH}" | head -1 || true)
if [ -z "${DEFAULT_LINE}" ]; then
    cannot "could not find the _root default in _ostler_wire_store_auth_pth; the function moved or was renamed"
fi
if grep -q 'local _root="\${2:-\${OSTLER_FINAL_DIR' <<< "${DEFAULT_LINE}"; then
    ok "the _root default resolves OSTLER_FINAL_DIR (${DEFAULT_LINE%%:*})"
elif grep -q 'local _root="\${2:-\${OSTLER_DIR' <<< "${DEFAULT_LINE}"; then
    bad "the _root default resolves OSTLER_DIR, which points at the STAGING tree during \
the install. That is the #595 defect verbatim -- the .pth gets a /tmp/ostler-prelaunch \
path baked in and the import fails for ever. Use OSTLER_FINAL_DIR."
else
    cannot "the _root default is neither OSTLER_FINAL_DIR nor OSTLER_DIR; read it and re-decide: ${DEFAULT_LINE}"
fi

# ---------------------------------------------------------------------------
# ARM B (BEHAVIOURAL): run the REAL function and read what it wrote.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d -t ostler-pth595)"
trap 'rm -rf "${SANDBOX}"' EXIT

STAGING="${SANDBOX}/tmp/ostler-prelaunch-9999"
# NOT a /Users/<name> path: ci-pii-shape-scan matches operator paths on SHAPE
# ('/Users/[a-z0-9._-]+/?'), so even an invented home directory trips it. The
# guard is correct -- an operator path must never enter this PUBLIC repo -- and
# the fixture does not need a realistic home, only a tree that is NOT staging.
FINAL="${SANDBOX}/final-home/.ostler"
mkdir -p "${STAGING}/lib" "${STAGING}/secrets" "${FINAL}/lib" "${FINAL}/secrets"

# A venv-shaped tree with a real interpreter, because the function asks the
# interpreter for its own site-packages rather than guessing the path.
VENV="${SANDBOX}/venv"
python3 -m venv "${VENV}" >/dev/null 2>&1 || cannot "could not create a venv for the fixture"
[ -x "${VENV}/bin/python3" ] || cannot "fixture venv has no bin/python3"

# Extract the real function body. Anchored on its opening and the first
# line-start `}` after it.
FUNC=$(/usr/bin/awk '
    /^_ostler_wire_store_auth_pth\(\) \{/ { on=1 }
    on { print }
    on && /^\}$/ { exit }
' "${INSTALL_SH}")
if [ -z "${FUNC}" ]; then
    cannot "could not extract _ostler_wire_store_auth_pth from install.sh"
fi
# CONTROL: the extracted text must actually contain the writer, or arm B would
# be testing an empty function and reporting a pass.
if ! grep -q 'ostler_store_auth.pth' <<< "${FUNC}"; then
    cannot "extracted function does not contain the .pth writer -- extraction is wrong, \
so any result below is about the wrong text"
fi
ok "control: extracted the real function, $(printf '%s' "${FUNC}" | wc -l | tr -d ' ') lines, writer present"

printf '%s\n' "${FUNC}" > "${SANDBOX}/fn.sh"

# THE ADVERSARIAL SETUP: OSTLER_DIR points at staging, as it does mid-install.
# A correct implementation must ignore it in favour of OSTLER_FINAL_DIR.
set +e
OSTLER_DIR="${STAGING}" OSTLER_FINAL_DIR="${FINAL}" \
    /bin/bash -c "source '${SANDBOX}/fn.sh'; _ostler_wire_store_auth_pth '${VENV}'" >/dev/null 2>&1
WIRE_RC=$?
set -e

SP=$("${VENV}/bin/python3" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)
PTH="${SP}/ostler_store_auth.pth"

if [ ! -f "${PTH}" ]; then
    bad "no .pth written (function rc=${WIRE_RC}); cannot judge its contents"
else
    ok ".pth written to the venv's own site-packages"
    CONTENT=$(cat "${PTH}")

    if grep -q 'ostler-prelaunch' <<< "${CONTENT}"; then
        bad "THE .pth CONTAINS A STAGING PATH. This is #595 reproduced: the path is \
frozen at install time and the directory does not survive. Written: ${CONTENT}"
    else
        ok "no staging path in the .pth"
    fi

    if grep -qF "${FINAL}/lib" <<< "${CONTENT}"; then
        ok "sys.path points at the FINAL lib dir"
    else
        bad "sys.path does not point at the final lib dir (${FINAL}/lib). Written: ${CONTENT}"
    fi

    # ⚠️ BOTH HALVES, per the function's own header: a .pth that sets only
    # sys.path loads the shim from the right place and sends it looking for
    # credentials in the wrong one -- loudly loaded, silently useless.
    if grep -qF "${FINAL}/secrets" <<< "${CONTENT}"; then
        ok "OSTLER_SECRETS_DIR points at the FINAL secrets dir"
    else
        bad "OSTLER_SECRETS_DIR does not point at the final secrets dir (${FINAL}/secrets). \
Written: ${CONTENT}"
    fi
fi

# ---------------------------------------------------------------------------
# ARMS C, D, E (BEHAVIOURAL): start a REAL interpreter against the .pth the
# real function wrote, and read stderr. A grep of the .pth text cannot say
# whether the interpreter is silent; only the interpreter can.
# ---------------------------------------------------------------------------
# errexit was switched on above; every command below reads its own rc.
set +e
if [ -f "${PTH}" ]; then
    RUN_OUT="${SANDBOX}/run.out"; RUN_ERR="${SANDBOX}/run.err"
    MARKER="${SANDBOX}/imported.marker"
    STUB="${FINAL}/lib/ostler_store_auth.py"
    start_interp() {
        # Prints OSTLER_SECRETS_DIR so a pass also proves the line ran to
        # completion rather than being skipped wholesale.
        rm -f "${MARKER}"
        OSTLER_PTH_TEST_MARKER="${MARKER}" "${VENV}/bin/python3" \
            -c 'import os; print(os.environ.get("OSTLER_SECRETS_DIR", "<unset>"))' \
            >"${RUN_OUT}" 2>"${RUN_ERR}"
    }

    # ARM C: module ABSENT (the lib dir exists and is empty, as it is when the
    # .pth is written mid-install). Must be silent, rc 0, env default set.
    rm -f "${STUB}"
    start_interp; C_RC=$?
    C_ERR_BYTES=$(wc -c < "${RUN_ERR}" | tr -d ' ')
    if [ "${C_RC}" -eq 0 ] && [ "${C_ERR_BYTES}" -eq 0 ]; then
        ok "arm C: module absent, interpreter start is SILENT (rc=0, stderr 0 bytes)"
    else
        bad "arm C: module absent, interpreter start printed ${C_ERR_BYTES} bytes to stderr \
(rc=${C_RC}). This is the v1.0.82 install.log noise: $(tr '\n' '|' < "${RUN_ERR}")"
    fi
    if [ "$(cat "${RUN_OUT}")" = "${FINAL}/secrets" ]; then
        ok "arm C: the line ran to completion (OSTLER_SECRETS_DIR default set)"
    else
        bad "arm C: OSTLER_SECRETS_DIR was not set by the .pth; got: $(cat "${RUN_OUT}")"
    fi
    if [ -f "${MARKER}" ]; then
        bad "arm C: marker present with NO module on disk; the marker predicate is broken"
    else
        ok "arm C: control, no module means no marker"
    fi

    # ARM D: module PRESENT. A stub that drops a marker on import; the guard
    # must let it through, silently.
    printf 'import os\nopen(os.environ["OSTLER_PTH_TEST_MARKER"], "w").close()\n' > "${STUB}"
    start_interp; D_RC=$?
    D_ERR_BYTES=$(wc -c < "${RUN_ERR}" | tr -d ' ')
    if [ -f "${MARKER}" ]; then
        ok "arm D: module present, the .pth IMPORTED it (marker written)"
    else
        bad "arm D: module present but NOT imported (no marker). The guard is too strong: \
the store-auth shim would never load. rc=${D_RC}, stderr: $(tr '\n' '|' < "${RUN_ERR}")"
    fi
    if [ "${D_RC}" -eq 0 ] && [ "${D_ERR_BYTES}" -eq 0 ]; then
        ok "arm D: module present, interpreter start is silent (rc=0, stderr 0 bytes)"
    else
        bad "arm D: module present, stderr ${D_ERR_BYTES} bytes, rc=${D_RC}: $(tr '\n' '|' < "${RUN_ERR}")"
    fi
    rm -f "${STUB}"

    # ARM E (MUST-FAIL): the OLD, unguarded line form, module absent, in the
    # same venv. It must print the traceback. If it does not, arm C's silence
    # proves nothing on this interpreter, and that is CANNOT-RUN, not a pass.
    OLD_LINE="import sys, os; sys.path.append(\"${FINAL}/lib\"); os.environ.setdefault(\"OSTLER_SECRETS_DIR\", \"${FINAL}/secrets\"); __import__(\"ostler_store_auth\")"
    printf '%s\n' "${OLD_LINE}" > "${PTH}"
    start_interp; E_RC=$?
    if grep -q "No module named 'ostler_store_auth'" "${RUN_ERR}"; then
        ok "arm E: must-fail, the OLD unguarded form prints the traceback \
($(wc -c < "${RUN_ERR}" | tr -d ' ') bytes on stderr, rc=${E_RC}), so arm C can fail"
    else
        cannot "the OLD unguarded .pth form did NOT print ModuleNotFoundError on this interpreter \
($(command -v python3), rc=${E_RC}); arm C's silence cannot be trusted. stderr: $(tr '\n' '|' < "${RUN_ERR}")"
    fi
else
    bad "arms C, D, E: no .pth to start an interpreter against"
fi

# ---------------------------------------------------------------------------
# ARM F (SOURCE): the writer must carry the guard, so the old form is named
# at its line rather than discovered on the next walk.
# ---------------------------------------------------------------------------
if grep -qF 'find_spec("ostler_store_auth") is not None and __import__("ostler_store_auth")' <<< "${FUNC}"; then
    ok "arm F: the .pth writer guards the import with find_spec"
elif grep -qF '__import__("ostler_store_auth")' <<< "${FUNC}"; then
    bad "arm F: the .pth writer imports ostler_store_auth UNGUARDED. Every interpreter \
started before <final>/lib exists prints a traceback into install.log."
else
    cannot "arm F: the .pth writer has no __import__ of ostler_store_auth at all; read it and re-decide"
fi

echo
echo "PASS ${PASS}   FAIL ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
