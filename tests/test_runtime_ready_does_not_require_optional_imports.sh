#!/usr/bin/env bash
#
# _ostler_verify_runtime_ready MUST NOT REQUIRE AN OPTIONAL IMPORT.
# =================================================================
#
# WHY THIS TEST EXISTS: v1.0.43 could not install. Any of it. Every attempt
# aborted at 19%, step fda_extract, and the artefact was otherwise perfect --
# signature, staple, hash and embedded version all verified clean. The cut had
# green gates and a dead installer.
#
# The cause was this function reporting four missing dependencies that were
# not missing. The shipped ostler_fda package carries the script-mode fallback
# pattern in several files:
#
#     try:
#         from .role_addresses import is_role_identifier
#     except ImportError:      # running as a plain script (repair on the box)
#         from role_addresses import is_role_identifier   # type: ignore
#
# `node.level` already skipped the relative arm. Nothing skipped the FALLBACK
# arm, and ast.walk() does not care about control flow -- so a branch that
# never runs when the relative import works was collected as a hard
# requirement. importlib.util.find_spec("role_addresses") returns None from
# the venv, because a bare sibling only resolves with the package directory on
# sys.path. Four optional imports -> missing=4 -> return 1 -> abort.
#
# Measured on the walk box, 2026-08-24, before the fix:
#
#     scanned=30 third_party=7 missing=4
#     MISSING given_name_variants
#     MISSING pwg_ingest
#     MISSING relationship_labels
#     MISSING role_addresses
#
# ...while `import ostler_fda.identifier_quality` succeeded throughout.
#
# ── 🔴 THE ARM THAT STOPS THIS FIX BECOMING A BLIND SPOT ──────────────────
#
# A guard that ignores more imports is trivially easy to make green. Case 3
# plants a genuinely absent third-party dependency, UNGUARDED, and requires
# the function to still fail. Without it this file would pass just as happily
# against a guard that returned 0 unconditionally, and we would have replaced
# a loud false positive with a silent false negative -- which is the strictly
# worse of the two.
#
# Case 4 is the anti-vacuity floor: an empty package must still be CANNOT-RUN
# (exit 2), not a pass. Case 5 keeps the CANNOT-RUN/FAIL distinction honest --
# they are different exit codes for a reason (#765).
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

echo
echo "== the runtime-ready guard separates OPTIONAL imports from MISSING ones =="
echo

# ── 0. CANNOT-RUN FIRST, AND IT IS NOT A PASS ─────────────────────────────
if [[ ! -r "$INSTALL_SH" ]]; then
    echo "CANNOT-RUN: no install.sh at ${INSTALL_SH}. Nothing measured -- exit 2." >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "CANNOT-RUN: python3 absent. This test cannot look -- exit 2." >&2
    exit 2
fi

# Extract the function by NAME and brace matching, never by line number: my
# own earlier attempt at a sibling test sliced fixed line numbers and silently
# compiled a neighbouring function the day someone inserted a line above.
FN="$(awk '
    /^_ostler_verify_runtime_ready\(\) \{/ {f=1}
    f {print}
    f && /^\}$/ {exit}
' "$INSTALL_SH")"

if [[ -z "$FN" ]]; then
    echo "CANNOT-RUN: could not extract _ostler_verify_runtime_ready from install.sh." >&2
    echo "  It was renamed or its brace style changed. NOT a pass -- exit 2." >&2
    exit 2
fi
ok "extracted the function by name + brace matching ($(wc -l <<<"$FN" | tr -d ' ') lines)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# shellcheck disable=SC1090
source /dev/stdin <<<"$FN"

VENV_PY="$(command -v python3)"

# make_pkg <dir> -- a minimal ostler_fda carrying the real fallback shape
make_pkg() {
    local d="$1/ostler_fda"; mkdir -p "$d"
    cat > "$d/__init__.py" <<'EOF'
EOF
    cat > "$d/role_addresses.py" <<'EOF'
def is_role_identifier(x): return False
EOF
    cat > "$d/identifier_quality.py" <<'EOF'
QUALITY = "ok"
EOF
    # THE PATTERN THAT BROKE v1.0.43 -- guarded bare-sibling fallback
    cat > "$d/repair_role_address_people.py" <<'EOF'
import os
try:
    from .role_addresses import is_role_identifier
except ImportError:  # running as a plain script
    from role_addresses import is_role_identifier  # type: ignore
EOF
    printf '%s\n' "$d"
}

# PYTHONPATH is set to the package's PARENT so `import ostler_fda` resolves,
# which is the condition the real venv provides. Without it the function's
# final hardcoded __import__ fails on every fixture and EVERY case goes red
# for the same irrelevant reason -- including the discriminating control,
# which would then be green-looking for the wrong cause. (Learned the hard
# way: my first run scored 5/2 and the two reds were my harness, not the fix.)
run_guard() {  # run_guard <pkgdir> -> prints output, sets RC
    local out rc parent
    parent="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || parent="/nonexistent"
    out="$(PYTHONPATH="$parent" _ostler_verify_runtime_ready "$VENV_PY" "$1" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    return $rc
}

# ── 1. THE REGRESSION ITSELF ──────────────────────────────────────────────
P1="$WORK/case1"; mkdir -p "$P1"; PKG1="$(make_pkg "$P1")"
OUT1="$(run_guard "$PKG1")"; RC1=$?
if [[ "$RC1" -eq 0 ]]; then
    ok "guarded bare-sibling fallback is NOT required: rc=0 ($(grep -o 'missing=[0-9]*' <<<"$OUT1" | head -1))"
else
    bad "the v1.0.43 abort REPRODUCES: rc=${RC1}" \
        "$(grep -E 'MISSING|missing=' <<<"$OUT1" | tr '\n' ' ')"
fi

# ── 2. UNGUARDED BARE SIBLING -- layer two ────────────────────────────────
P2="$WORK/case2"; mkdir -p "$P2"; PKG2="$(make_pkg "$P2")"
cat > "$PKG2/uses_sibling_unguarded.py" <<'EOF'
from role_addresses import is_role_identifier   # bare, NOT guarded
EOF
OUT2="$(run_guard "$PKG2")"; RC2=$?
if [[ "$RC2" -eq 0 ]]; then
    ok "UNGUARDED bare sibling also not required (own-module layer holds): rc=0"
else
    bad "unguarded bare sibling still counted missing: rc=${RC2}" \
        "$(grep -E 'MISSING' <<<"$OUT2" | tr '\n' ' ')"
fi

# ── 3. 🔴 THE DISCRIMINATING ARM. A REAL MISSING DEP MUST STILL FAIL ──────
# Without this the whole file passes against a guard that returns 0 blindly.
P3="$WORK/case3"; mkdir -p "$P3"; PKG3="$(make_pkg "$P3")"
cat > "$PKG3/needs_absent_third_party.py" <<'EOF'
import ostler_definitely_not_installed_xyzzy
EOF
OUT3="$(run_guard "$PKG3")"; RC3=$?
if [[ "$RC3" -eq 1 ]] && grep -q 'MISSING ostler_definitely_not_installed_xyzzy' <<<"$OUT3"; then
    ok "CONTROL: a genuinely absent UNGUARDED dependency still FAILS (rc=1, named)"
else
    bad "CONTROL FAILED: absent third-party dependency was not caught (rc=${RC3})" \
        "the fix has become a blind spot -- worse than the false positive it replaced"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── 4. ANTI-VACUITY FLOOR STILL INTACT ────────────────────────────────────
P4="$WORK/case4/ostler_fda"; mkdir -p "$P4"
OUT4="$(run_guard "$P4")"; RC4=$?
if [[ "$RC4" -eq 2 ]] && grep -q 'CANNOT-RUN' <<<"$OUT4"; then
    ok "empty package is CANNOT-RUN (exit 2), not a pass"
else
    bad "anti-vacuity floor gone: empty package returned rc=${RC4}" \
        "'nothing found' and 'nothing looked at' must not share an exit code"
fi

# ── 5. CANNOT-RUN AND FAIL REMAIN DIFFERENT CODES ─────────────────────────
OUT5="$(run_guard "$WORK/case5-does-not-exist")"; RC5=$?
if [[ "$RC5" -eq 2 ]]; then
    ok "absent package directory is CANNOT-RUN (exit 2), distinct from FAIL (1)"
else
    bad "absent package returned rc=${RC5}, not 2" \
        "a caller cannot distinguish 'could not look' from 'looked and it was bad'"
fi

# ── 6. AND THE INTERPRETER LIMB ───────────────────────────────────────────
OUT6="$(run_guard_noexec() { :; }; _ostler_verify_runtime_ready "$WORK/no-such-python" "$PKG1" 2>&1)"; RC6=$?
if [[ "$RC6" -eq 2 ]]; then
    ok "absent interpreter is CANNOT-RUN (exit 2)"
else
    bad "absent interpreter returned rc=${RC6}, not 2" "$OUT6"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
