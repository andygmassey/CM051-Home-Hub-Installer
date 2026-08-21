#!/usr/bin/env bash
# The upgrade path must repair the fda venv (HR015 #595)
# ======================================================
#
# BEHAVIOURAL: extracts the real `_upg_repair_fda_venv` from install.sh and
# EXECUTES it against a real venv and a stub package. Not a grep for the
# function name -- the defect this guards was a function that existed and was
# never reached, so proving presence proves nothing.
#
# THE DEFECT. CM051 #939 fixed a missing `ostler_fda` in the promoted venv, in
# `_ostler_repair_venv_after_promote`, called from
# `_ostler_promote_prelaunch_tree` at ~install.sh:3495. The upgrade block
# (install.sh:122-553) ALWAYS exits before reaching it: line ~552 is an
# unconditional `exit 0` under a comment reading "Neither returns; both exit
# explicitly".
#
# So #939 fixed NEW INSTALLS ONLY. Measured on origin/main before the fix:
# inside the upgrade block `ostler_fda` appeared 0 times against a whole-file
# control of 101, and the repair function was called 0 times against a control
# of 4. Every machine already on a bad version kept a frozen graph
# permanently, updates included -- `com.ostler.fda-rerun` is the only
# recurring ingest for contacts, calendar, iMessage, WhatsApp, browsing and
# notes.
#
# WHAT IS ASSERTED
#   1. the repair is CALLED from inside the upgrade block (structural, with a
#      control proving the search can fail)
#   2. a venv that cannot import ostler_fda gets it installed  <- the defect
#   3. a venv that already can is left alone                   <- idempotent
#   4. a missing package directory is skipped, rc 0            <- non-fatal
#
# (3) and (4) are not padding. An upgrade runs after the daemon swap has
# already succeeded, so a repair that hard-failed or reinstalled on every tick
# would trade a frozen graph for a rolled-back Hub.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

printf 'test_upgrade_repairs_the_fda_venv\n'

[ -f "$INSTALL_SH" ] || { bad "premise: install.sh not found at $INSTALL_SH"; exit 1; }

# --- 1. the call site, inside the upgrade block -----------------------------
BLOCK_END="$(awk 'NR>=122 && /^fi$/{print NR; exit}' "$INSTALL_SH")"
if [ -z "$BLOCK_END" ]; then
    bad "premise: could not find the end of the upgrade block; every check below would be vacuous"
    exit 1
fi
BLOCK="$(sed -n "122,${BLOCK_END}p" "$INSTALL_SH")"

if grep -qE '^\s+_upg_repair_fda_venv\s*$' <<< "$BLOCK"; then
    ok "the repair is CALLED inside the upgrade block (lines 122-${BLOCK_END})"
else
    bad "the repair is never called inside the upgrade block -- this is exactly #595"
fi

# CONTROL: the same search for something that is NOT there must fail, or the
# check above proves nothing about the predicate.
if grep -qE '^\s+_upg_repair_a_thing_that_does_not_exist\s*$' <<< "$BLOCK"; then
    bad "control: the search matched a function that does not exist"
else
    ok "control: the same search correctly finds nothing for an absent name"
fi

# --- extract the function ---------------------------------------------------
FN="$(awk '/^    _upg_repair_fda_venv\(\) \{/{f=1} f{print} f && /^    \}$/{exit}' "$INSTALL_SH")"
LINES="$(printf '%s\n' "$FN" | grep -c .)"
if [ "${LINES:-0}" -lt 15 ]; then
    bad "premise: extracted only ${LINES} lines of _upg_repair_fda_venv; refusing to report on a stub"
    exit 1
fi
ok "extracted the real function (${LINES} lines)"

# INTERPRETER CHOICE IS PART OF THE FIXTURE, NOT AN INCIDENTAL DETAIL.
# `pip install -e` on a pyproject-only project needs PEP 660 support. macOS's
# system python3 is 3.9 with pip 21.2, which refuses with "editable mode
# currently requires a setuptools-based build" and exits 0 -- so the repair
# appears to fail when it is the interpreter that cannot do it. The real venv
# is 3.11.15 with pip 24.0 (measured from its pyvenv.cfg on a live box), so
# the fixture must be at least that capable.
PY_BIN=""
# Named versions first, then plain python3 IF it is new enough. CI images vary
# in which of these exist, and hard-coding python3.11 would make this
# CANNOT-RUN on a runner whose python3 is perfectly capable.
for _cand in python3.13 python3.12 python3.11 python3; do
    _p="$(command -v "$_cand" 2>/dev/null || true)"
    [ -n "$_p" ] || continue
    if "$_p" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
        PY_BIN="$_p"; break
    fi
done
if [ -z "$PY_BIN" ]; then
    printf '  CANNOT-RUN: no python3.11+ available; PEP 660 editable installs are\n'
    printf '              not testable on the system 3.9. This is NOT a pass.\n' >&2
    exit 2
fi
ok "fixture interpreter: $("$PY_BIN" -V 2>&1)"

# --- harness ----------------------------------------------------------------
# Builds a REAL venv and a stub `ostler_fda` package, then runs the extracted
# function against them with the two globals it reads.
run_case() {
    local mode="$1" tmp py
    tmp="$(mktemp -d)"
    mkdir -p "${tmp}/.ostler"
    # --system-site-packages so the stub can build without reaching PyPI for
    # setuptools. A bare venv has pip but no setuptools, so `pip install -e`
    # on the stub failed and BOTH the repair case and the already-installed
    # case reported "missing" -- a harness defect that looked exactly like the
    # product defect. Worth the comment: a fixture that cannot install is
    # indistinguishable from a repair that does not work.
    "$PY_BIN" -m venv "${tmp}/.ostler/.venv" >/dev/null 2>&1 || return 99
    py="${tmp}/.ostler/.venv/bin/python3"

    if [ "$mode" != "nopkg" ]; then
        mkdir -p "${tmp}/.ostler/fda-module/ostler_fda"
        # MIRRORS THE REAL LAYOUT, which is not the obvious one: the package
        # metadata lives INSIDE ostler_fda/, so the install target is
        # .../fda-module/ostler_fda and not .../fda-module. Verified on a live
        # box: ~/.ostler/fda-module/ contains only ostler_fda/, and the
        # pyproject.toml is at ostler_fda/pyproject.toml. A fixture with the
        # metadata one level up installs fine and tests the wrong path.
        cat > "${tmp}/.ostler/fda-module/ostler_fda/pyproject.toml" <<'TOML'
[build-system]
requires = ["setuptools>=61", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "ostler-fda"
version = "0.1.0"
requires-python = ">=3.10"

[tool.setuptools]
packages = ["ostler_fda"]

[tool.setuptools.package-dir]
ostler_fda = "."
TOML
        : > "${tmp}/.ostler/fda-module/ostler_fda/__init__.py"
        printf 'def observe(*a, **k):\n    return None\n' \
            > "${tmp}/.ostler/fda-module/ostler_fda/identifier_quality.py"
    fi

    if [ "$mode" = "already" ]; then
        "${tmp}/.ostler/.venv/bin/pip" install --quiet -e "${tmp}/.ostler/fda-module/ostler_fda" >/dev/null 2>&1
    fi

    # NOTE the package path the function uses is <ostler_dir>/fda-module/ostler_fda,
    # so point _UPG_OSTLER_DIR at our temp .ostler.
    local out rc
    out="$(
        _UPG_OSTLER_DIR="${tmp}/.ostler"
        OSTLER_UPGRADE_LOG_PATH=/dev/null
        _upg_log() { printf '%s\n' "$*"; }
        eval "$FN"
        _upg_repair_fda_venv 2>&1
        printf 'RC=%s\n' "$?"
    )"
    rc="$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)"
    # EMIT the verdicts rather than assigning them: run_case is invoked in a
    # command substitution, so it runs in a SUBSHELL and any variable set here
    # is discarded on return. The first draft assigned LAST_IMPORT and the
    # caller read an unbound variable -- caught by `set -u` rather than
    # silently comparing against an empty string, which would have made every
    # assertion below pass for the wrong reason.
    local imported="missing"
    if [ -x "$py" ] && "$py" -c 'import ostler_fda.identifier_quality' >/dev/null 2>&1; then
        imported="present"
    fi
    printf '%s\n' "$out"
    printf 'IMPORT=%s\n' "$imported"
    printf 'FINAL_RC=%s\n' "$rc"
    rm -rf "$tmp"
    return 0
}

# Read one emitted verdict out of a run_case result.
verdict() { printf '%s' "$1" | sed -n "s/^$2=//p" | tail -1; }

# --- 2. THE DEFECT: a venv that cannot import it must get it ----------------
OUT="$(run_case missing)"
if [ "$(verdict "$OUT" IMPORT)" = "present" ]; then
    ok "a venv missing ostler_fda has it installed (import works afterwards)"
else
    bad "the repair did NOT make ostler_fda importable -- output: ${OUT}"
fi
if grep -q 'does NOT import' <<< "$OUT"; then
    ok "and it says so in the upgrade log rather than repairing silently"
else
    bad "no log line naming the condition it repaired: ${OUT}"
fi

# --- 3. idempotent ----------------------------------------------------------
OUT="$(run_case already)"
if grep -q 'already imports; nothing to do' <<< "$OUT"; then
    ok "a venv that can already import it is left alone (idempotent)"
else
    bad "expected a no-op on an already-working venv, got: ${OUT}"
fi

# --- 4. non-fatal when the package is absent --------------------------------
OUT="$(run_case nopkg)"
if [ "$(verdict "$OUT" FINAL_RC)" = "0" ]; then
    ok "a missing package directory is skipped with rc=0 (an upgrade must not hard-fail here)"
else
    bad "expected rc=0 when the package is absent, got rc=$(verdict "$OUT" FINAL_RC): ${OUT}"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'UPGRADE REPAIRS THE FDA VENV\n'
