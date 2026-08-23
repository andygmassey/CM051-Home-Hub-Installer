#!/bin/bash
# #595 layer 1 -- the runtime-ready invariant.
#
# #805/#939/#942 are three point fixes for ONE missing module. This asserts the
# INVARIANT that closes the class: the requirement is DERIVED from the shipped
# package, not enumerated, and it is checked on BOTH the install and the
# upgrade path.
#
# Every limb asserts behaviour of the real function sourced out of install.sh.
# Nothing here greps for a string that a refactor could rename while the
# defect returns.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Extract just the function under test. Sourcing all of install.sh would run
# an installer; this pulls the definition and nothing else.
FN_SRC="$(awk '/^_ostler_verify_runtime_ready\(\) \{/,/^\}/' "$INSTALL_SH")"
if [[ -z "$FN_SRC" ]]; then
    echo "FATAL: could not extract _ostler_verify_runtime_ready from install.sh"
    exit 1
fi
eval "$FN_SRC"

PY="$(command -v python3)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_pkg() {  # $1=dir  $2...=import lines
    local d="$1"; shift
    mkdir -p "$d"
    : > "${d}/__init__.py"
    { for line in "$@"; do echo "$line"; done; } > "${d}/mod.py"
}

echo "== 1. PREMISE / ANTI-VACUITY: a package with a bogus dep must be NOT-READY =="
mk_pkg "${TMP}/p1/ostler_fda" "import ostler_totally_absent_xyz"
out="$(_ostler_verify_runtime_ready "$PY" "${TMP}/p1/ostler_fda" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "MISSING ostler_totally_absent_xyz" <<<"$out"; then
    ok "derives a third-party import and reports it missing (rc=1)"
else
    bad "expected rc=1 + MISSING ostler_totally_absent_xyz; rc=$rc out=<$out>"
fi

echo "== 2. CONTROL: stdlib-only imports must NOT be reported missing =="
mk_pkg "${TMP}/p2/ostler_fda" "import os, sys, json, re" "from pathlib import Path"
out="$(_ostler_verify_runtime_ready "$PY" "${TMP}/p2/ostler_fda" 2>&1)"; rc=$?
if grep -q "MISSING os$\|MISSING sys$\|MISSING json$\|MISSING pathlib$" <<<"$out"; then
    bad "stdlib modules were reported as missing -- stdlib_module_names filter is not working"
else
    ok "stdlib imports are filtered out (this is the control that proves limb 1 is selective)"
fi

echo "== 3. Relative imports are NOT treated as third-party dependencies =="
mk_pkg "${TMP}/p3/ostler_fda" "from . import sibling" "from .deep.thing import X"
out="$(_ostler_verify_runtime_ready "$PY" "${TMP}/p3/ostler_fda" 2>&1)"
if grep -qE "MISSING (sibling|deep)" <<<"$out"; then
    bad "a relative import was scored as a third-party dependency; out=<$out>"
else
    ok "relative imports ignored"
fi

echo "== 4. CANNOT-RUN is rc=2 and is NOT confused with ready =="
out="$(_ostler_verify_runtime_ready "$PY" "${TMP}/does-not-exist" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "absent package -> rc=2 CANNOT-RUN" \
                || bad "absent package gave rc=$rc, expected 2; out=<$out>"
out="$(_ostler_verify_runtime_ready "${TMP}/no-such-python" "${TMP}/p2/ostler_fda" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "absent interpreter -> rc=2 CANNOT-RUN" \
                || bad "absent interpreter gave rc=$rc, expected 2; out=<$out>"

echo "== 5. An EMPTY package must be CANNOT-RUN, not READY =="
# The failure this guards: a walk that finds nothing derives an empty
# requirement set and reports a perfectly healthy runtime. "Nothing found" and
# "nothing looked at" print identically unless you separate them.
mkdir -p "${TMP}/p5/ostler_fda"
out="$(_ostler_verify_runtime_ready "$PY" "${TMP}/p5/ostler_fda" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && grep -q "parsed 0 python files" <<<"$out"; then
    ok "empty package -> rc=2, refuses to report ready off a zero denominator"
else
    bad "empty package gave rc=$rc (expected 2); out=<$out>"
fi

echo "== 6. The scanned count is REPORTED, so a shrinking denominator is visible =="
mk_pkg "${TMP}/p6/ostler_fda" "import os"
: > "${TMP}/p6/ostler_fda/extra.py"
out="$(_ostler_verify_runtime_ready "$PY" "${TMP}/p6/ostler_fda" 2>&1)"
if grep -qE "scanned=[0-9]+ third_party=[0-9]+ missing=[0-9]+" <<<"$out"; then
    ok "emits scanned/third_party/missing counts"
else
    bad "no denominator line in output; out=<$out>"
fi

echo "== 7. WIRED ON BOTH PATHS -- the whole point of the invariant =="
# Anti-vacuity for this limb: the control must find the function DEFINITION,
# so a zero on the call sites cannot be a broken pattern.
defs=$(grep -c '^_ostler_verify_runtime_ready() {' "$INSTALL_SH")
calls=$(grep -c '_ostler_verify_runtime_ready \\$' "$INSTALL_SH")
[[ $defs -eq 1 ]] && ok "control: exactly 1 definition found ($defs)" \
                  || bad "control failed: expected 1 definition, found $defs"
[[ $calls -ge 2 ]] && ok "called from >=2 sites ($calls) -- install AND upgrade" \
                   || bad "expected >=2 call sites, found $calls"

# And specifically INSIDE the upgrade block, which is the gap #595 exposed.
upg_start=$(grep -n 'OSTLER_UPGRADE_MODE' "$INSTALL_SH" | head -1 | cut -d: -f1)
# ANCHORED TO upg_start. This was `NR>1`, which finds the first eight-space
# `exit 0` in the WHOLE FILE rather than the first one AFTER the block starts.
# The end of the range was computed independently of its start, so it was
# correct only because that line happens to fall inside the intended block
# today. Any edit introducing an earlier eight-space `exit 0` moves upg_end
# BACKWARDS, the range silently becomes a different range, and "the call is
# inside it" quietly begins asserting something else. The predicate has to be
# anchored to the thing it claims to measure. (TNM, 2026-08-23.)
upg_end=$(awk -v a="$upg_start" 'NR>a && /^        exit 0$/ {print NR; exit}' "$INSTALL_SH")
if [[ -n "$upg_start" && -n "$upg_end" ]] && \
   awk -v a="$upg_start" -v b="$upg_end" 'NR>=a && NR<=b' "$INSTALL_SH" \
   | grep -q '_ostler_verify_runtime_ready'; then
    ok "invoked INSIDE the upgrade block (lines ${upg_start}-${upg_end})"
else
    # SAY WHAT WAS MEASURED. This printed nothing but a verdict, so a failure
    # that reproduces on one platform and not another gives the reader no way
    # to tell WHICH of the three numbers moved. A gate that refuses without
    # reporting its inputs cannot be diagnosed, only guessed at.
    bad "NOT invoked inside the upgrade block -- this is exactly the #595 gap"
    printf '       upg_start=%s upg_end=%s call_lines=[%s] total_lines=%s\n' \
        "${upg_start:-<empty>}" "${upg_end:-<empty>}" \
        "$(grep -n '_ostler_verify_runtime_ready' "$INSTALL_SH" | cut -d: -f1 | tr '\n' ' ')" \
        "$(wc -l < "$INSTALL_SH" | tr -d ' ')" >&2
    printf '       awk=%s\n' "$(awk --version 2>&1 | head -1)" >&2
fi

echo "== 8. install.sh still parses =="
bash -n "$INSTALL_SH" 2>/dev/null && ok "bash -n clean" || bad "bash -n FAILED"

echo
echo "PASS=${PASS} FAIL=${FAIL}"
[[ $FAIL -eq 0 ]]
