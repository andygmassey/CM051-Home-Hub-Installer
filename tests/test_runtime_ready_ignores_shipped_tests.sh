#!/bin/bash
# NEW-119 (row 2444a) -- a test suite is not a runtime, and is not product.
#
# A clean macOS 27.2 install (2026-10-29) logged
#     runtime-ready FAILED (install path) -- scheduled agents will die on every
#     tick: scanned=46 third_party=5 missing=1 / MISSING pytest
# because _ostler_verify_runtime_ready walked vendor/ostler_fda/tests/, whose
# files import pytest. Nothing a scheduled agent runs imports tests/.
#
# Two fixes, both asserted here:
#   A. the runtime scan prunes directories named exactly `tests`;
#   B. the DMG build phase stops shipping them (gui/project.yml AND the
#      tracked pbxproj, which is what xcodebuild actually runs).
# And the control that keeps A honest: a missing import in RUNTIME code, and
# in a directory merely named like tests, still FAILS.
#
# Every limb executes the real code: the function sourced out of install.sh,
# and the build-phase script text taken out of project.yml and the pbxproj.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

FN_SRC="$(awk '/^_ostler_verify_runtime_ready\(\) \{/,/^\}/' "$INSTALL_SH")"
[[ -n "$FN_SRC" ]] || { echo "FATAL: could not extract _ostler_verify_runtime_ready"; exit 1; }
eval "$FN_SRC"

PY="$(command -v python3)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="${TMP}/home"; mkdir -p "$HOME"

# Synthetic stand-ins. A real `import pytest` would pass on any runner that
# happens to have pytest, so the red would depend on the runner, not the code.
TESTDEP="ostler_new119_pytest_standin"
RUNDEP="ostler_new119_runtime_dep_absent"

# The package must carry identifier_quality: the function also asserts that
# module imports. Stdlib-only, so it does.
mk_pkg() {
    local d="$1"
    mkdir -p "$d"
    : > "${d}/__init__.py"
    printf 'import os\n' > "${d}/identifier_quality.py"
}

echo "== A1. RED->GREEN: a tests/ dir importing an absent dep does NOT fail the scan =="
mk_pkg "${TMP}/a1/ostler_fda"
mkdir -p "${TMP}/a1/ostler_fda/tests"
printf 'import %s\n' "$TESTDEP" > "${TMP}/a1/ostler_fda/tests/test_x.py"
out="$(cd "${TMP}/a1" && _ostler_verify_runtime_ready "$PY" "${TMP}/a1/ostler_fda" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && ! grep -q "MISSING ${TESTDEP}" <<<"$out"; then
    ok "tests/ import ignored (rc=0): ${out%%$'\n'*}"
else
    bad "tests/ import still scored as runtime: rc=$rc out=<$out>"
fi

echo "== A2. CONTROL: a missing RUNTIME import beside it still FAILS =="
mk_pkg "${TMP}/a2/ostler_fda"
mkdir -p "${TMP}/a2/ostler_fda/tests"
printf 'import %s\n' "$TESTDEP" > "${TMP}/a2/ostler_fda/tests/test_x.py"
printf 'import %s\n' "$RUNDEP"  > "${TMP}/a2/ostler_fda/worker.py"
out="$(cd "${TMP}/a2" && _ostler_verify_runtime_ready "$PY" "${TMP}/a2/ostler_fda" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "^MISSING ${RUNDEP}$" <<<"$out" && ! grep -q "MISSING ${TESTDEP}" <<<"$out"; then
    ok "runtime dep reported missing (rc=1), tests/ dep still not: $(tr '\n' ' ' <<<"$out")"
else
    bad "expected rc=1 with MISSING ${RUNDEP} only; rc=$rc out=<$out>"
fi

echo "== A3. CONTROL: the prune is EXACT-NAME -- testsupport/ is runtime and still FAILS =="
mk_pkg "${TMP}/a3/ostler_fda"
mkdir -p "${TMP}/a3/ostler_fda/testsupport"
: > "${TMP}/a3/ostler_fda/testsupport/__init__.py"
printf 'import %s\n' "$RUNDEP" > "${TMP}/a3/ostler_fda/testsupport/helper.py"
out="$(cd "${TMP}/a3" && _ostler_verify_runtime_ready "$PY" "${TMP}/a3/ostler_fda" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "^MISSING ${RUNDEP}$" <<<"$out"; then
    ok "a dir merely named like tests is still scanned (rc=1)"
else
    bad "testsupport/ was pruned too -- prune is a prefix match; rc=$rc out=<$out>"
fi

echo "== A4. ANTI-VACUITY: a package that is ONLY tests/ is CANNOT-RUN, not READY =="
mkdir -p "${TMP}/a4/ostler_fda/tests"
printf 'import %s\n' "$TESTDEP" > "${TMP}/a4/ostler_fda/tests/test_x.py"
out="$(cd "${TMP}/a4" && _ostler_verify_runtime_ready "$PY" "${TMP}/a4/ostler_fda" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && grep -q "parsed 0 python files" <<<"$out"; then
    ok "pruning to zero files reports CANNOT-RUN (rc=2)"
else
    bad "expected rc=2 parsed 0; rc=$rc out=<$out>"
fi

# ---------------------------------------------------------------------------
# B. The DMG build phase. Run the phase script EXACTLY as each source spells
# it, against a synthetic vendor tree, and look at what lands in Resources.
# ---------------------------------------------------------------------------
PHASE="Bundle ostler_fda Python package into Resources"

yml_script="$("$PY" - "${REPO}/gui/project.yml" "$PHASE" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
hits = []
def walk(o):
    if isinstance(o, dict):
        if o.get("name") == sys.argv[2] and "script" in o:
            hits.append(o["script"])
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(doc)
if len(hits) != 1:
    sys.exit("found %d phases named %r" % (len(hits), sys.argv[2]))
sys.stdout.write(hits[0])
PYEOF
)" || { bad "could not extract the phase from project.yml"; yml_script=""; }

pbx_script="$("$PY" - "${REPO}/gui/OstlerInstaller.xcodeproj/project.pbxproj" "$PHASE" <<'PYEOF'
import sys, re, json
src = open(sys.argv[1]).read()
blk = re.search(r'/\* ' + re.escape(sys.argv[2]) + r' \*/ = \{(.*?)\n\t\t\};', src, re.S)
if not blk:
    sys.exit("phase not found in pbxproj")
m = re.search(r'shellScript = (".*?(?<!\\)");', blk.group(1), re.S)
if not m:
    sys.exit("no shellScript in phase")
sys.stdout.write(json.loads(m.group(1)))
PYEOF
)" || { bad "could not extract the phase from the pbxproj"; pbx_script=""; }

run_phase() {  # $1=label $2=script text
    local label="$1" script="$2" root="${TMP}/b-$1"
    mkdir -p "${root}/src/gui" "${root}/src/vendor/ostler_fda/tests" "${root}/src/vendor/ostler_fda/sub/tests" "${root}/build/Res"
    : > "${root}/src/vendor/ostler_fda/__init__.py"
    : > "${root}/src/vendor/ostler_fda/identifier_quality.py"
    : > "${root}/src/vendor/ostler_fda/sub/runtime.py"
    printf 'import %s\n' "$TESTDEP" > "${root}/src/vendor/ostler_fda/tests/test_x.py"
    printf 'import %s\n' "$TESTDEP" > "${root}/src/vendor/ostler_fda/sub/tests/test_y.py"
    # /usr/bin/xattr is macOS-only. On a runner without it, swap that ONE
    # call for a no-op; everything else runs as written.
    [[ -x /usr/bin/xattr ]] || script="${script//\/usr\/bin\/xattr/:}"
    if ! SRCROOT="${root}/src/gui" TARGET_BUILD_DIR="${root}/build" UNLOCALIZED_RESOURCES_FOLDER_PATH="Res" \
         /bin/sh -c "$script" >"${root}/phase.log" 2>&1; then
        bad "[$label] phase script exited non-zero: $(cat "${root}/phase.log")"; return
    fi
    local dest="${root}/build/Res/ostler_fda"
    local nt; nt="$(find "$dest" -type d -name tests | wc -l | tr -d ' ')"
    # Control: the copy happened at all, so "no tests/ found" is not "nothing copied".
    if [[ -f "${dest}/identifier_quality.py" && -f "${dest}/sub/runtime.py" ]]; then
        ok "[$label] control: runtime files were bundled"
    else
        bad "[$label] runtime files missing from the bundle -- the phase copied nothing"
    fi
    [[ "$nt" -eq 0 ]] && ok "[$label] no tests/ directory ships (found $nt)" \
                      || bad "[$label] tests/ still ships: $nt dir(s) under Resources/ostler_fda"
}
[[ -n "$yml_script" ]] && run_phase yml "$yml_script"
[[ -n "$pbx_script" ]] && run_phase pbxproj "$pbx_script"

echo "== C. install.sh still parses =="
bash -n "$INSTALL_SH" && ok "bash -n clean" || bad "bash -n FAILED"

echo
echo "PASS=${PASS} FAIL=${FAIL}"
[[ $FAIL -eq 0 ]]
