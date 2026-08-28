#!/bin/bash
# tests/test_manifest_gate_cannot_run_is_not_a_missing_fix.sh
# ============================================================================
# CANNOT-RUN IS NOT FAIL AND IS NOT PASS. THREE OUTCOMES, THREE BRANCHES.
#
# THE INCIDENT THIS TEST EXISTS FOR (2026-08-29, v1.0.50 assembly)
#
# `make ship` died reporting:
#
#     ERROR: cut-manifest preflight FAILED -- a required fix is missing from
#     the built .app. Read the RED rows above.
#
# There were no RED rows. There were no rows at all. The operator's PATH had
# put /usr/bin first, `python3` resolved to macOS system 3.9.6, and
# verify_cut_manifest.py died at IMPORT on a PEP 604 `str | None` annotation.
# The gate examined nothing and the caller reported it as a product defect,
# after a full build + sign + notarise cycle.
#
# TWO DISTINCT CONFLATIONS WERE FOUND, AND THE SECOND IS THE WORSE ONE
#
#   1. A crash exits 1. gui/Makefile keyed its accusation on "non-zero and not
#      2", so every crash became "a required fix is missing".
#
#   2. verify_cut_manifest.py ALREADY defined exit 3 as its own CANNOT-RUN
#      code -- "a required KIND of proof never ran at all", the strongest
#      could-not-look statement it makes. gui/Makefile had no branch for 3, so
#      the script's deliberate third state was reported as a missing fix too.
#      The author built the third outcome; the caller collapsed it back into
#      two. That is a live defect independent of anyone's PATH.
#
# WHAT IS ASSERTED HERE
#
#   A  the module imports under macOS system python 3.9 (no TypeError)
#   B  it still runs under a modern python (no regression)
#   C  a crash INSIDE main() exits 2 (could-not-run), never 1 (product fail)
#   D  gui/Makefile routes 0/1/2/3/undefined to four distinct verdicts, and
#      ONLY rc=1 is allowed to say "a required fix is missing"
#
# ON ARM D'S METHOD. The Makefile recipe cannot be invoked directly here: the
# target needs a built .app. So the branch block is EXTRACTED FROM
# gui/Makefile and executed. Extraction is the risk -- a test that runs a
# retyped copy proves the tester's predicate, not the subject. Two guards:
# the extraction is located by CONTENT not by line number, and a positive
# control asserts every branch condition survived the extraction before any
# arm runs. If the block moves, the control fails loudly rather than the test
# passing on an empty string.
# ============================================================================
# 🔴 NO `printf ... | grep -q` IN THIS FILE. It INVERTS a successful match.
# Under `pipefail`, `grep -q` exits the moment it finds the needle, the writer
# takes SIGPIPE, and the PIPELINE reports FAILURE on a match that succeeded.
# The first version of this file had five of them and CI's
# appcast-ship-wiring gate caught every one. Herestrings throughout: no pipe,
# no inversion, and `grep -c` where a count is wanted.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${REPO_ROOT}/scripts/verify_cut_manifest.py"
MAKEFILE="${REPO_ROOT}/gui/Makefile"

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

for f in "${PY}" "${MAKEFILE}"; do
    [ -f "${f}" ] || { echo "CANNOT-RUN: missing ${f}"; exit 78; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/manifestgate.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT INT TERM

# --- pick interpreters -------------------------------------------------------
# 3.9 is the WHOLE POINT of arm A: it is what a tidied PATH selects on macOS.
PY39="/usr/bin/python3"
PY_MODERN="$(command -v python3 || true)"
[ -n "${PY_MODERN}" ] || { echo "CANNOT-RUN: no python3 on PATH"; exit 78; }

echo "=== interpreters under test ==="
if [ -x "${PY39}" ]; then
    echo "  ${PY39} -> $("${PY39}" -V 2>&1)"
else
    echo "  ${PY39} -> ABSENT (arm A will report CANNOT-RUN, not PASS)"
fi
echo "  ${PY_MODERN} -> $("${PY_MODERN}" -V 2>&1)"
echo

# --- ARM A -------------------------------------------------------------------
echo "=== ARM A: imports under macOS system python 3.9 ==="
if [ ! -x "${PY39}" ]; then
    echo "  CANNOT-RUN  ${PY39} absent on this host. NOT counted as a pass."
else
    a_out="$("${PY39}" "${PY}" --help 2>&1)"; a_rc=$?
    if [ "${a_rc}" -eq 0 ] && ! grep -q 'TypeError' <<< "${a_out}"; then
        ok "3.9 imports and runs (rc=0, no TypeError)"
    else
        bad "3.9 rc=${a_rc}; TypeError present: $(printf '%s' "${a_out}" | grep -c 'TypeError')"
        printf '%s\n' "${a_out}" | tail -5
    fi
fi
echo

# --- ARM B -------------------------------------------------------------------
echo "=== ARM B: no regression on a modern python ==="
b_out="$("${PY_MODERN}" "${PY}" --help 2>&1)"; b_rc=$?
if [ "${b_rc}" -eq 0 ] && grep -q 'usage:' <<< "${b_out}"; then
    ok "modern python rc=0 and prints usage (control: the run really happened)"
else
    bad "modern python rc=${b_rc}, usage line missing"
fi
echo

# --- ARM C -------------------------------------------------------------------
# A crash AFTER import. Arm A covers the import-time crash; this covers the
# rest of the surface, which no __future__ import can protect.
echo "=== ARM C: a crash inside main() exits 2, not 1 ==="
"${PY_MODERN}" - "${PY}" "${WORK}/mutant.py" <<'INJECT'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
i = src.index("def main(")
j = src.index("\n", src.index(":", src.index(")", i)))
pathlib.Path(sys.argv[2]).write_text(
    src[:j+1]
    + '    raise RuntimeError("MUTATION: deliberate crash inside main()")\n'
    + src[j+1:])
INJECT
if [ ! -s "${WORK}/mutant.py" ]; then
    bad "could not build the mutant -- arm C did not run"
else
    c_out="$("${PY_MODERN}" "${WORK}/mutant.py" --help 2>&1)"; c_rc=$?
    if [ "${c_rc}" -eq 2 ]; then
        ok "crash -> rc=2 (could-not-run), not rc=1 (product fail)"
    else
        bad "crash -> rc=${c_rc}; MUST be 2 or the Makefile blames the .app"
    fi
    if grep -q 'it failed to look' <<< "${c_out}"; then
        ok "crash message says it failed to look, not that a fix is missing"
    else
        bad "crash message does not disclaim having examined the artefact"
    fi
fi
echo

# --- ARM D -------------------------------------------------------------------
echo "=== ARM D: gui/Makefile gives 0/1/2/3/undefined four distinct verdicts ==="

# Locate by CONTENT, never by line number.
"${PY_MODERN}" - "${MAKEFILE}" "${WORK}/branch.sh" <<'EXTRACT'
import sys, pathlib
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next((n for n, l in enumerate(lines)
              if l.startswith("\tif [ ") and '{rc:-0}" -eq 2 ' in l), None)
if start is None:
    sys.exit("EXTRACT-FAILED: could not find the rc branch block")
end = next((n for n in range(start + 1, len(lines)) if lines[n] == "\tfi"), None)
if end is None:
    sys.exit("EXTRACT-FAILED: no closing fi")
body = []
for l in lines[start:end + 1]:
    l = l[1:] if l.startswith("\t") else l          # drop the recipe tab
    if l.endswith(" \\"):
        l = l[:-2]                                   # drop make's continuation
    body.append(l.replace("$$", "$"))                # un-escape make's $$
pathlib.Path(sys.argv[2]).write_text(
    'rc="$1"\n' + "\n".join(body) + "\nexit 0\n")
print(f"  extracted {end - start + 1} lines from gui/Makefile, located by content")
EXTRACT
[ -s "${WORK}/branch.sh" ] || { echo "  CANNOT-RUN: extraction produced nothing"; exit 78; }

# POSITIVE CONTROL, before any arm trusts the extracted text. An extraction
# that silently lost a branch would let every arm below "pass" for the wrong
# reason -- the block would simply fall through.
missing=0
for needle in '-eq 2' '-eq 3' '-ne 1' '-ne 0' 'required fix is missing'; do
    if ! grep -q -- "${needle}" "${WORK}/branch.sh"; then
        echo "  CONTROL FAILED: extracted block has no '${needle}'"
        missing=$((missing+1))
    fi
done
cannot_run_armd=0
if [ "${missing}" -ne 0 ]; then
    # 🔴 THIS SCRIPT ONCE COMMITTED THE DEFECT IT TESTS FOR. It used to
    # `exit 78` here, skipping the summary -- so a run with real FAILs in arms
    # A and C exited 78 (could-not-run) instead of 1 (failed). Measured on the
    # pre-fix tree 2026-08-29: 3 FAILs recorded, process exit 78.
    #
    # CANNOT-RUN and FAIL are different, and a recorded FAIL is not erased by a
    # later arm being unable to run. Arm D goes CANNOT-RUN; the summary still
    # reports what the other arms found, and a real failure still exits 1.
    echo "  CANNOT-RUN: the extraction is not the subject. ${missing} branch marker(s) absent."
    echo "              Arm D did NOT run. Arms A-C above still stand."
    cannot_run_armd=1
else
    echo "  control: all 5 branch markers present in the extracted block"
fi

if [ "${cannot_run_armd}" -eq 0 ]; then

# rc -> (expected exit, must-say, must-NOT-say)
run_arm() {
    local rc="$1" want_exit="$2" want_text="$3" forbid_text="$4"
    local out; out="$(bash "${WORK}/branch.sh" "${rc}" 2>&1)"; local got=$?
    local why=""
    [ "${got}" -eq "${want_exit}" ] || why="exit ${got} != ${want_exit}"
    if [ -n "${want_text}" ] && ! grep -q -- "${want_text}" <<< "${out}"; then
        why="${why}; did not say '${want_text}'"
    fi
    if [ -n "${forbid_text}" ] && grep -q -- "${forbid_text}" <<< "${out}"; then
        why="${why}; WRONGLY said '${forbid_text}'"
    fi
    if [ -z "${why}" ]; then ok "rc=${rc} -> exit ${want_exit}, correct verdict"
    else bad "rc=${rc}: ${why}"; fi
}

ACCUSE="required fix is missing"
run_arm 0  0 ""                        "${ACCUSE}"
run_arm 1  1 "${ACCUSE}"               ""
run_arm 2  2 "COULD NOT RUN"           "${ACCUSE}"
run_arm 3  3 "COULD NOT RUN a REQUIRED KIND" "${ACCUSE}"
run_arm 99 2 "a code it does not"      "${ACCUSE}"
fi

echo
echo "=============================================================="
echo " ${pass} PASS   ${fail} FAIL   arm-D-could-not-run: ${cannot_run_armd}"
echo "=============================================================="

# THREE OUTCOMES, THREE EXIT CODES. A recorded FAIL outranks a CANNOT-RUN:
# something was measured and it was wrong, which is a stronger statement than
# something else being unmeasurable.
if [ "${fail}" -ne 0 ]; then
    echo " VERDICT: FAIL"
    exit 1
elif [ "${cannot_run_armd}" -ne 0 ]; then
    echo " VERDICT: CANNOT-RUN -- arm D never ran. This is NOT a pass."
    exit 78
fi
echo " VERDICT: PASS"
exit 0
