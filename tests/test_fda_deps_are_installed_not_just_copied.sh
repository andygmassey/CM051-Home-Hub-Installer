#!/usr/bin/env bash
# ============================================================================
# THE CODE WAS COPIED. ITS DEPENDENCIES WERE NEVER INSTALLED.
#
# #805, measured on the live v1.0.37 box 2026-08-20 (not inferred):
#
#     ~/.ostler/.venv/bin/python3 -c 'import ostler_fda.identifier_quality'
#       -> ModuleNotFoundError: No module named 'nameparser'
#
# install.sh:5385 does `cp -R "${SCRIPT_DIR}/ostler_fda" "$FDA_DIR/"`. A bare
# copy. No pip. So the venv the recurring tick runs under never received
# nameparser, which identifier_quality.py imports at module scope -- and the
# tick imports identifier_quality before it can do any work.
#
# fda-rerun therefore died on EVERY fire, on EVERY box, from the first install,
# while the product told the customer their data was "still loading in the
# background".
#
# WHY THIS TEST EXECUTES INSTEAD OF READING
#
# The tempting check is "does pyproject.toml declare nameparser". That check
# PASSES ON EXACTLY THE BROKEN BOXES: the declaration was always correct, it is
# the INSTALLATION that was missing. A predicate whose surface differs from the
# defect's surface is green forever. So limb 3 builds a real venv, reproduces
# the ModuleNotFoundError with the pre-fix mechanism, then proves the shipped
# mechanism resolves it.
#
# WHY BARE IMPORT AND NOT sys.path-ASSISTED
#
# The wrapper at ~/.ostler/bin/ostler-fda does sys.path.insert(0, FDA_DIR), so
# it can load the package even when it is not installed. That masks the state:
# on the box today the tick works while a bare `import ostler_fda` still fails.
# The wrapper is not the only consumer, so the bare import is the honest floor
# and it is what the box-walk probe (fda_tick_can_import) asserts.
#
# Non-zero = BLOCK THE CUT. An extractor that cannot load is an extractor that
# never runs, and every diagnostic upstream of it reports success.
#
# Exit: 0 fix present and proven | 1 defect present | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/.."
INSTALL_SH="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
PKG="${REPO}/vendor/ostler_fda"

pass=0; fail=0
ok()     { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note()   { printf '        %s\n' "$1"; }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

[ -r "$INSTALL_SH" ] || cannot "install.sh not readable at ${INSTALL_SH}"
[ -r "$STRINGS" ]    || cannot "string catalogue not readable at ${STRINGS}"
[ -d "$PKG" ]        || cannot "vendored ostler_fda not found at ${PKG} -- limb 3 has nothing to install"

echo "== #805: the FDA module's dependencies must be INSTALLED, not merely copied =="

# ── PREMISE. Assert the defect is still reachable in the code we ship. ───
# If identifier_quality stops importing nameparser at module scope, limb 3's
# negative control silently stops reproducing anything and this whole file
# becomes decoration. Fail loudly rather than pass vacuously.
IDQ="${PKG}/identifier_quality.py"
[ -r "$IDQ" ] || cannot "vendor/ostler_fda/identifier_quality.py absent -- the module this defect is about does not exist here"
if grep -qE '^[[:space:]]*from nameparser import|^[[:space:]]*import nameparser' "$IDQ"; then
    ok "premise: identifier_quality.py still imports nameparser at module scope"
else
    bad "PREMISE GONE: identifier_quality.py no longer imports nameparser at module scope. The negative control in limb 3 can no longer reproduce #805, so a green result below would prove nothing. Re-target this test at whatever the module now needs, or retire it."
    finish
fi

# ── 1. THE JOIN. install.sh must install the package into the venv the
#       tick actually resolves, and it must do it from the COPY, not from
#       the bundle (pip writes .egg-info into its source dir; SCRIPT_DIR is
#       inside the notarised .app -- CM051 #767, 256 unsealed files).
# ------------------------------------------------------------------------
# COUNT THE POPULATION BEFORE SCOPING IT.
#
# `FDA_DIR="${OSTLER_DIR}/fda-module"` is assigned TWICE in install.sh: once at
# the staging site, and again in the fda-rerun wrapper section far below. An
# awk RANGE (/start/,/end/) restarts on the second start and, finding no second
# end, runs to end-of-file -- so the "block" silently became several thousand
# lines and picked up unrelated `pyproject.toml` matches from other packages.
# The first draft of this test did exactly that and reported a defect that was
# not there.
#
# So: take the FIRST range only, and state the anchor count.
n_starts="$(grep -c '^FDA_DIR="\${OSTLER_DIR}/fda-module"' "$INSTALL_SH")"
note "FDA_DIR assignment sites in install.sh: ${n_starts} (this test reads the first)"

BLOCK="$(awk '
    /^FDA_DIR="\$\{OSTLER_DIR\}\/fda-module"/ { if (!seen) { inb = 1; seen = 1 } }
    inb { print }
    inb && /^RECOVERY_KEY=""/ { inb = 0 }
' "$INSTALL_SH")"

if [ -z "$BLOCK" ]; then
    bad "could not locate the FDA staging block in install.sh (FDA_DIR=... through RECOVERY_KEY=\"\"). It moved, and every assertion below is blind."
    finish
fi
# A range that ran away is not a block. Bound it, so a future anchor change
# cannot silently widen what every predicate below is reading.
n_block="$(printf '%s\n' "$BLOCK" | grep -c .)"
if [ "$n_block" -gt 400 ]; then
    bad "the extracted block is ${n_block} lines, which means the end anchor did not match and this test is now reading unrelated parts of install.sh. Every verdict below would be about the wrong code."
    finish
fi
note "block: ${n_block} lines"

# ASSERT ON THE CODE, NOT ON THE PROSE. This block carries a long comment that
# names pyproject.toml, SCRIPT_DIR and pip -- so a predicate run over the raw
# text scores the explanation instead of the mechanism. (This is the same
# wrong-object error the block itself documents, and the first draft of this
# test made it: it read its own comment and went red.)
#
# Via the SHARED stripper, not a local `sed 's/#.*$//'`. That one-liner
# truncates at a `#` inside a quoted string, and #857/#858 already paid for
# having two copies of it. scripts/lib/strip_comments.sh is the one
# implementation, and its bias is documented: strip too much (false RED) is
# always preferred to strip too little (false GREEN).
STRIPPER="${REPO}/scripts/lib/strip_comments.sh"
[ -r "$STRIPPER" ] || cannot "shared comment-stripper missing at scripts/lib/strip_comments.sh -- refusing to hand-roll a second copy"
# shellcheck source=../scripts/lib/strip_comments.sh
. "$STRIPPER"

printf '%s\n' "$BLOCK" > "${TMPDIR:-/tmp}/ostler-805-block.$$"
CODE="$(strip_comments_file "${TMPDIR:-/tmp}/ostler-805-block.$$")" \
    || cannot "strip_comments_file failed on the extracted block"
rm -f "${TMPDIR:-/tmp}/ostler-805-block.$$"

if grep -qE '\$\{?FDA_VENV_PIP\}?"?[[:space:]]+install.*-e[[:space:]]+"\$\{FDA_DIR\}/ostler_fda"' <<< "$CODE"; then
    ok "install.sh pip-installs the package from FDA_DIR (the copy), editable"
else
    bad "install.sh does not pip-install ostler_fda from FDA_DIR. cp -R alone leaves the venv without nameparser and fda-rerun dies on every fire (#805)."
fi

# The source of the install must NOT be SCRIPT_DIR. This is the seal defect.
if grep -qE 'install.*-e[[:space:]]+"\$\{?SCRIPT_DIR' <<< "$CODE"; then
    bad "the editable install is sourced from SCRIPT_DIR. pip writes .egg-info into its source directory, and SCRIPT_DIR is inside the notarised bundle -- this breaks the code seal and Gatekeeper refuses the app (CM051 #767)."
else
    ok "the editable install is not sourced from SCRIPT_DIR (code seal intact)"
fi

# ── 2. THE CONTROL MUST IMPORT, NOT READ. ───────────────────────────────
# Archie's constraint on #805, and the reason the defect survived: a
# declaration check passes on the broken boxes.
# ------------------------------------------------------------------------
if grep -qE "PYTHON\}?\"?[[:space:]]+-c[[:space:]]+'import ostler_fda" <<< "$CODE"; then
    ok "install.sh verifies by EXECUTING the import"
else
    bad "install.sh does not execute an import to verify the install. Checking pyproject.toml or pip's exit code instead would pass on exactly the boxes that are broken."
fi

if grep -qE 'grep .*nameparser.*pyproject|pyproject\.toml' <<< "$CODE"; then
    bad "the block inspects pyproject.toml. The declaration was correct on every broken box -- reading it measures the wrong object."
else
    ok "the block does not fall back to reading the declaration"
fi

# The verification must use the venv python, not whatever is on PATH.
if grep -qE '"\$FDA_VENV_PYTHON"[[:space:]]+-c' <<< "$CODE"; then
    ok "the import runs under the venv interpreter the tick resolves"
else
    bad "the import verification does not run under \$FDA_VENV_PYTHON. A system python3 that happens to have nameparser would give a false pass while the tick's venv stays broken."
fi

# ── 3. FAILURE MUST BE LOUD. ────────────────────────────────────────────
if grep -q 'ERR-10-FDA-DEPS-IMPORT' <<< "$CODE"; then
    ok "an unloadable module hard-fails the install with a reference code"
else
    bad "no fail_with_code on the import failure path. A module that is present but cannot load is worse than an absent one: every surface reports it installed."
fi

# ── 4. STRINGS. No hardcoded English in install.sh. ─────────────────────
missing=""
for key in MSG_INFO_INSTALLING_FDA_DEPENDENCIES \
           MSG_OK_FDA_DEPENDENCIES_IMPORTABLE \
           MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE \
           MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT \
           MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN \
           MSG_FAIL_FDA_DEPS_UNSAFE_PATH; do
    grep -qE "^${key}=" "$STRINGS" || missing="${missing} ${key}"
done
if [ -z "$missing" ]; then
    ok "all 6 new MSG_ keys are defined in the en-GB catalogue"
else
    bad "MSG_ keys used by install.sh but absent from the catalogue:${missing}. Under set -u the installer dies on an unbound variable at exactly this step."
fi

# ── 5. BEHAVIOURAL. Reproduce #805, then prove the fix resolves it. ─────
#
# This is the limb that matters. Everything above reads install.sh; only this
# one runs the mechanism. Two arms, because a checker that always reports
# "broken" would satisfy a one-sided control while being useless:
#
#   arm A (negative control)  cp -R only, no pip  -> MUST fail to import
#   arm B (the fix)           cp -R then pip -e   -> MUST import
# ------------------------------------------------------------------------
PY3="$(command -v python3 2>/dev/null || true)"
if [ -z "$PY3" ]; then
    note "SKIPPED limb 5: no python3 on this machine."
    note "That is NOT a pass -- the mechanism was never exercised."
    finish
fi

WORK=""
cleanup() { [ -n "${WORK}" ] && rm -rf "${WORK}"; return 0; }
trap cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-805-XXXXXX")" || cannot "could not create a work directory"
mkdir -p "${WORK}/fda-module"
cp -R "$PKG" "${WORK}/fda-module/" || cannot "could not stage the package"

"$PY3" -m venv "${WORK}/.venv" >/dev/null 2>&1 || cannot "could not create a venv with ${PY3}"
VPY="${WORK}/.venv/bin/python3"
VPIP="${WORK}/.venv/bin/pip"
[ -x "$VPY" ] || cannot "venv produced no python3 at ${VPY}"

# arm A -- the pre-fix state, exactly: code on disk, nothing installed.
if "$VPY" -c 'import ostler_fda.identifier_quality' >/dev/null 2>&1; then
    bad "NEGATIVE CONTROL DID NOT FIRE: a copy-only venv imported ostler_fda.identifier_quality. Either the host python is leaking site-packages into the venv, or the package no longer needs installing -- either way limb 5's green arm proves nothing."
else
    ARM_A="$("$VPY" -c 'import ostler_fda.identifier_quality' 2>&1 | tail -1)"
    # And it must fail for the RIGHT reason. A SyntaxError would also "fail".
    if grep -q 'No module named' <<< "$ARM_A"; then
        ok "negative control: copy-only venv cannot import -- ${ARM_A}"
    else
        bad "negative control fired for the WRONG reason. Expected a ModuleNotFoundError, got: ${ARM_A}"
    fi
fi

# arm B -- the shipped mechanism.
if ! "$VPIP" install --quiet -e "${WORK}/fda-module/ostler_fda" >"${WORK}/pip.log" 2>&1; then
    note "pip install failed. Last 5 lines:"
    tail -5 "${WORK}/pip.log" | sed 's/^/          /'
    note "SKIPPED the positive arm: pip could not reach an index."
    note "That is NOT a pass -- the fix was never exercised on this runner."
    finish
fi

if "$VPY" -c 'import ostler_fda.identifier_quality, nameparser' >/dev/null 2>&1; then
    ok "the fix works: after pip install -e, both ostler_fda.identifier_quality and nameparser import"
else
    bad "THE FIX DOES NOT WORK: after pip install -e the import still fails -- $("$VPY" -c 'import ostler_fda.identifier_quality, nameparser' 2>&1 | tail -1)"
fi

# ONE copy, not two. The reason for -e over a plain install: pyproject pins a
# static version (0.1.0), so a later install refreshes the cp -R copy while pip
# skips site-packages as already-satisfied, and non-wrapper consumers then load
# stale code. Prove the resolved module is the copy on disk.
RESOLVED="$("$VPY" -c 'import ostler_fda.identifier_quality as m; print(m.__file__)' 2>/dev/null)"
# COMPARE REAL PATHS. On macOS `mktemp -d` hands back /var/folders/... while
# Python reports /private/var/folders/... -- /var is a symlink to /private/var.
# A plain prefix match on the two strings disagrees with itself and reds a
# working fix. (It did, on the first run of this test.)
WORK_REAL="$("$VPY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WORK")"
RESOLVED_REAL="$("$VPY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RESOLVED")"
case "$RESOLVED_REAL" in
    "${WORK_REAL}/fda-module/ostler_fda/"*)
        ok "single copy: the module resolves to the staged directory, not to site-packages"
        ;;
    *)
        bad "TWO COPIES: the module resolved to '${RESOLVED_REAL}', not under '${WORK_REAL}/fda-module/ostler_fda/'. A future install would refresh the staged copy and leave this one stale, and consumers that do not insert FDA_DIR would silently load old code."
        ;;
esac

finish
