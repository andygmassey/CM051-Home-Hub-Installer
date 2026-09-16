#!/usr/bin/env bash
# An upgrade must not carry a customer's OLD PATH over the template's
# ==================================================================
#
# THE DEFECT, reproduced 2026-09-04 by extracting the real
# `_upg_preserve_plist_env` out of install.sh and running it:
#
#     BEFORE  new plist PATH = /usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
#     AFTER   new plist PATH = /usr/bin:/bin:/usr/sbin:/sbin
#
# The function walks every key in the OLD plist and `Set`s it over the new
# one. `Set` replaces. There was no PATH exclusion, so a customer upgrading
# from a pre-2026-08-20 install had the Homebrew-prefix fix SILENTLY REVERTED.
#
# WHY THAT MATTERS, from the template's own comment (assistant.plist:70),
# measured on the Mini after a real power cycle:
#
#     colima  FATA  exec "limactl": executable file not found in $PATH
#
# "Qdrant, Oxigraph, Redis, Vane, wiki-site and store-proxy were all gone
# until someone started Colima by hand." `/usr/bin:/bin:/usr/sbin:/sbin` is
# launchd's default and is exactly the PATH that produces it.
#
# WHY THE EXISTING GATE DID NOT CATCH IT. tests/test_launchagent_homebrew_path
# .sh calls itself "the rule" and is a good file, but it asserts that the
# TEMPLATES carry the prefix. Measured: it contains ZERO references to
# `upgrade`, `preserve` or `_upg_`. Nothing asserted the value SURVIVES an
# upgrade, so the fix shipped, the gate stayed green, and it never arrived on
# an upgrading customer's box.
#
# WHAT THIS ASSERTS
#   1  MUTATION. The PRE-FIX function (this one with the exclusion stripped)
#      must still revert PATH. Without this the arms below could pass because
#      the harness stopped reproducing rather than because the fix works.
#   2  The template's PATH survives the merge.
#   3  CONTROL: a customer value the template cannot re-derive (the service
#      token) is STILL preserved. The fix must not buy its correctness by
#      breaking what this function is for.
#   4  CONTROL: a key present only in the OLD plist is still ADDED.
#   5  THE SAME DEFECT, ONE VARIABLE ALONG. PATH was not special; it was the
#      first product-owned key anyone noticed. The whatsapp-keepalive runner
#      added four more (OSTLER_DIR, OSTLER_GATEWAY_URL, OSTLER_ASSISTANT_LABEL,
#      PYTHONDONTWRITEBYTECODE), all stated outright by the template rather
#      than captured from the customer. OSTLER_GATEWAY_URL is the sharp one: it
#      is pinned to the daemon's [gateway] port, so a customer carrying a stale
#      one would probe a dead port twice a day and the keepalive would report
#      the channel unmeasurable forever. Mutation-tested separately from PATH,
#      because one exclusion passing says nothing about the other.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL="${REPO}/install.sh"
PB=/usr/libexec/PlistBuddy
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
cannot(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$INSTALL" ] || cannot "install.sh not found"
[ -x "$PB" ]      || cannot "PlistBuddy not at ${PB}; this test cannot build its fixtures"

W="$(mktemp -d 2>/dev/null || mktemp -d -t upgpath)"
[ -n "$W" ] && [ -d "$W" ] || cannot "mktemp produced no directory"
trap 'rm -rf "$W"' EXIT

# The REAL function, by its own delimiters -- never a copy.
awk '/^    _upg_preserve_plist_env\(\) \{$/,/^    \}$/' "$INSTALL" | sed 's/^    //' > "${W}/fn.inc"
_fl="$(wc -l < "${W}/fn.inc" | tr -d ' ')"
[ "$_fl" -ge 15 ] || cannot "could not extract _upg_preserve_plist_env (${_fl} lines); its delimiters moved"
grep -q 'EnvironmentVariables' "${W}/fn.inc" || cannot "the extracted block is not the env-preserving function"

# The PRE-FIX form: the same function with the PATH exclusion stripped.
grep -vE '^[[:space:]]*\[\[ "\$_k" == "PATH" \]\] && continue[[:space:]]*$' "${W}/fn.inc" > "${W}/fn.pre"
if [ "$(wc -l < "${W}/fn.pre" | tr -d ' ')" -ge "$_fl" ]; then
    cannot "the mutation removed nothing -- the PATH exclusion line was not found, so arm 1 would compare the function with itself"
fi

# The PRE-FIX form for arm 5: the same function with the product-owned-key
# case block deleted, from `case "$_k" in` through its `esac`.
#
# The line COUNT is asserted, not just "something was removed". A grep-based
# first attempt removed a different set of lines, the >= guard was satisfied,
# and arm 5 then ran against a function that still had the exclusion -- it
# reported the defect as not reproducing, which is the mutation failing open.
awk '/^ *case "\$_k" in$/{skip=1} skip{if(/^ *esac$/){skip=0}; next} {print}' \
    "${W}/fn.inc" > "${W}/fn.prekeys"
_removed=$(( _fl - $(wc -l < "${W}/fn.prekeys" | tr -d ' ') ))
if [ "$_removed" -ne 4 ]; then
    cannot "the product-owned-key mutation removed ${_removed} line(s), expected exactly 4 (case, labels, continue, esac). The block moved, so arm 5 would compare the function with itself or with the wrong mutant."
fi

TEMPLATE_PATH='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin'
LAUNCHD_PATH='/usr/bin:/bin:/usr/sbin:/sbin'

# Product-owned keys the TEMPLATE states. Stale customer value vs the one this
# version ships.
STALE_GATEWAY='http://127.0.0.1:42617'
TEMPLATE_GATEWAY='http://127.0.0.1:8000'

build() {   # $1 = dir prefix
    rm -f "${W}/${1}_old.plist" "${W}/${1}_new.plist"
    "$PB" -c "Add :EnvironmentVariables dict" "${W}/${1}_old.plist" >/dev/null 2>&1
    "$PB" -c "Add :EnvironmentVariables:PATH string ${LAUNCHD_PATH}" "${W}/${1}_old.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:PWG_SERVICE_TOKEN string customer-token-abc" "${W}/${1}_old.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:OSTLER_LEGACY_ONLY string kept" "${W}/${1}_old.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:OSTLER_GATEWAY_URL string ${STALE_GATEWAY}" "${W}/${1}_old.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:PYTHONDONTWRITEBYTECODE string 0" "${W}/${1}_old.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables dict" "${W}/${1}_new.plist" >/dev/null 2>&1
    "$PB" -c "Add :EnvironmentVariables:PATH string ${TEMPLATE_PATH}" "${W}/${1}_new.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:PWG_SERVICE_TOKEN string PWG_SERVICE_TOKEN_VALUE" "${W}/${1}_new.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:OSTLER_GATEWAY_URL string ${TEMPLATE_GATEWAY}" "${W}/${1}_new.plist" >/dev/null
    "$PB" -c "Add :EnvironmentVariables:PYTHONDONTWRITEBYTECODE string 1" "${W}/${1}_new.plist" >/dev/null
}

run_with() {   # $1 = function file, $2 = prefix
    bash -c "
        set -uo pipefail
        _UPG_PB=${PB}
        _upg_log() { :; }
        $(cat "$1")
        _upg_preserve_plist_env '${W}/${2}_old.plist' '${W}/${2}_new.plist'
    " >/dev/null 2>&1
}
val() { "$PB" -c "Print :EnvironmentVariables:$2" "${W}/${1}_new.plist" 2>/dev/null; }

# ── 1. MUTATION: the pre-fix function must still revert PATH ───────────────
build pre
run_with "${W}/fn.pre" pre
_pre_path="$(val pre PATH)"
if [ "$_pre_path" = "$LAUNCHD_PATH" ]; then
    ok "MUTATION: without the exclusion the customer's old PATH still wins (defect reproduces)"
else
    bad "MUTATION: expected the pre-fix function to revert PATH to '${LAUNCHD_PATH}', got '${_pre_path}'.
        The harness no longer reproduces the defect, so the arms below prove nothing."
fi

# ── 2 + 3 + 4. The fixed function ─────────────────────────────────────────
build fix
run_with "${W}/fn.inc" fix

_path="$(val fix PATH)"
[ "$_path" = "$TEMPLATE_PATH" ] \
    && ok "the template's PATH survives the upgrade merge" \
    || bad "PATH after merge is '${_path}', expected the template's '${TEMPLATE_PATH}'"

_tok="$(val fix PWG_SERVICE_TOKEN)"
[ "$_tok" = "customer-token-abc" ] \
    && ok "CONTROL: a customer value the template cannot re-derive is STILL preserved" \
    || bad "CONTROL BROKEN: PWG_SERVICE_TOKEN is '${_tok}', expected the customer's 'customer-token-abc'.
        The fix has bought PATH correctness by breaking what this function exists for."

_leg="$(val fix OSTLER_LEGACY_ONLY)"
[ "$_leg" = "kept" ] \
    && ok "CONTROL: a key present only in the OLD plist is still added" \
    || bad "CONTROL BROKEN: OSTLER_LEGACY_ONLY is '${_leg}', expected 'kept'"

_gw="$(val fix OSTLER_GATEWAY_URL)"
[ "$_gw" = "$TEMPLATE_GATEWAY" ] \
    && ok "the template's OSTLER_GATEWAY_URL survives the upgrade merge" \
    || bad "OSTLER_GATEWAY_URL after merge is '${_gw}', expected the template's '${TEMPLATE_GATEWAY}'.
        An upgrading customer would keep probing the old gateway port and the
        WhatsApp keepalive would report the channel unmeasurable forever."

_pyc="$(val fix PYTHONDONTWRITEBYTECODE)"
[ "$_pyc" = "1" ] \
    && ok "the template's PYTHONDONTWRITEBYTECODE survives the upgrade merge" \
    || bad "PYTHONDONTWRITEBYTECODE after merge is '${_pyc}', expected the template's '1'"

# ── 5. MUTATION: without the case block the stale values must win ─────────
build prekeys
run_with "${W}/fn.prekeys" prekeys
_pre_gw="$(val prekeys OSTLER_GATEWAY_URL)"
if [ "$_pre_gw" = "$STALE_GATEWAY" ]; then
    ok "MUTATION: without the product-owned-key exclusion the stale gateway still wins (defect reproduces)"
else
    bad "MUTATION: expected the pre-fix function to revert OSTLER_GATEWAY_URL to '${STALE_GATEWAY}', got '${_pre_gw}'.
        The harness no longer reproduces the defect, so the two arms above prove nothing."
fi

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
