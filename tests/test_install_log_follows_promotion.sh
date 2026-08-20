#!/usr/bin/env bash
# INSTALL_LOG must follow the tree across promotion, and the marker
# append must be genuinely silent when it cannot write
# =====================================================================
#
# THE DEFECT THIS PINS, MEASURED ON A LIVE v1.0.37 WALK 2026-08-20
# ----------------------------------------------------------------
# On the 16 GB Mini, ~/.ostler/logs/install.log reached 1397 lines with
# ZERO ERR- lines. The install was fine. The LOG was not:
#
#     151 [gui-marker] lines, the LAST at line 707
#     267 copies of, starting at line 709:
#       progress_emitter.sh: line 227:
#         /tmp/ostler-prelaunch-2796/logs/install.log: No such file
#
# So the durable operator trace covered the first half of the install
# and went dark for the whole remainder -- ingest, wiki compile,
# pairing, and the step 35+ region where task #258 lives. Every
# box-walk log handed to an agent was missing markers for exactly the
# part that needs diagnosing.
#
# TWO INDEPENDENT CAUSES, AND THE TEST HAS AN ARM FOR EACH
# ---------------------------------------------------------
# 1. install.sh derived INSTALL_LOG once, while OSTLER_DIR was still
#    the /tmp/ostler-prelaunch-<pid> staging tree, and never rebound
#    it. `_ostler_set_paths` exists precisely to rebind derived paths
#    across promotion -- its own CX-87 comment names the class ("path
#    vars assigned BEFORE the FDA grant flow and read AFTER promotion
#    -- must be rebound here too") and lists FDA_DIR, SECRETS_DIR,
#    OSTLER_ENV_FILE. INSTALL_LOG was simply left off that list.
#
#    The STREAM survived regardless, because `exec > >(tee -a ...)`
#    holds an open fd and the rename carries the inode. Only a
#    consumer that re-opens BY PATH breaks, and the emitter does.
#
# 2. The emitter's append was written to fail quietly and CANNOT:
#        printf ... >> "$f" 2>/dev/null || true
#    Bash applies redirections LEFT TO RIGHT, so the append is
#    attempted -- and its failure reported to the still-inherited
#    stderr -- BEFORE 2>/dev/null takes effect. A statement whose
#    author intended silence produced 267 visible errors.
#
# WHY ARM 3 IS THE LOAD-BEARING ONE
# ---------------------------------
# Arms 1 and 4 are structural and would pass on any file that merely
# mentions the right token. Arm 2 EXECUTES the real `_ostler_set_paths`
# body lifted out of install.sh. Arm 3 executes BOTH redirection forms
# against an unwriteable path and asserts the old one leaks while the
# new one does not. If the old form ever stops leaking, arm 3 fails
# loudly rather than going quietly green, because a control that
# cannot reproduce the defect proves nothing about the fix.
#
# No install runs. No real log is read. Synthetic paths only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

EMITTER="lib/progress_emitter.sh"

pass=0
fail=0
ok()  { printf '  [ok]   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }

printf '== INSTALL_LOG follows promotion, and the marker append is silent ==\n\n'

# ---------------------------------------------------------------------
# ARM 1. STRUCTURAL. The rebind lives inside _ostler_set_paths.
#
# grep -F throughout: BSD grep reads `$` as an anchor mid-pattern, so a
# literal `$VAR` pattern matches NOTHING under the default engine and a
# structural arm would go quietly green on a broken file.
# ---------------------------------------------------------------------
_fn_body="$(
    awk '/^_ostler_set_paths\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' install.sh
)"

if [[ -z "$_fn_body" ]]; then
    bad "1a. could not extract _ostler_set_paths from install.sh; every later arm is meaningless"
else
    ok "1a. _ostler_set_paths extracted from install.sh ($(printf '%s\n' "$_fn_body" | wc -l | tr -d ' ') lines)"
fi

if printf '%s' "$_fn_body" | grep -Fq 'INSTALL_LOG="${LOGS_DIR}/install.log"'; then
    ok "1b. _ostler_set_paths re-derives INSTALL_LOG from LOGS_DIR"
else
    bad "1b. _ostler_set_paths does NOT re-derive INSTALL_LOG; it will stay pinned to the staging tree"
fi

if printf '%s' "$_fn_body" | grep -Fq 'INSTALL_LOG_FALLBACK_ACTIVE'; then
    ok "1c. the rebind honours the /tmp fallback opt-out"
else
    bad "1c. the rebind ignores INSTALL_LOG_FALLBACK_ACTIVE and will re-aim at an unwriteable dir"
fi

# ---------------------------------------------------------------------
# ARM 2. BEHAVIOURAL. Run the REAL function body across a promotion.
# ---------------------------------------------------------------------
_stage="/tmp/ostler-prelaunch-testpid"
_final="/tmp/ostler-final-test"

_probe() {
    # $1 = value of INSTALL_LOG_FALLBACK_ACTIVE for this run
    (
        set +u
        INSTALL_LOG_FALLBACK_ACTIVE="$1"
        eval "$_fn_body"
        _ostler_set_paths "$_stage"
        printf 'staged=%s\n' "${INSTALL_LOG}"
        _ostler_set_paths "$_final"
        printf 'promoted=%s\n' "${INSTALL_LOG}"
    ) 2>/dev/null
}

_out="$(_probe false)"
_staged="$(printf '%s\n' "$_out" | sed -n 's/^staged=//p')"
_promoted="$(printf '%s\n' "$_out" | sed -n 's/^promoted=//p')"

if [[ "$_staged" == "${_stage}/logs/install.log" ]]; then
    ok "2a. pre-promotion INSTALL_LOG points into the staging tree"
else
    bad "2a. pre-promotion INSTALL_LOG was '${_staged}', expected '${_stage}/logs/install.log'"
fi

if [[ "$_promoted" == "${_final}/logs/install.log" ]]; then
    ok "2b. post-promotion INSTALL_LOG FOLLOWED the tree (this is the defect)"
else
    bad "2b. post-promotion INSTALL_LOG was '${_promoted}', expected '${_final}/logs/install.log'"
fi

if [[ "$_staged" != "$_promoted" ]]; then
    ok "2c. the two values DIFFER, so the fixture can discriminate"
else
    bad "2c. staged and promoted collapsed to one value; this fixture proves nothing"
fi

# The /tmp fallback must survive promotion untouched.
_fb_out="$(
    (
        set +u
        INSTALL_LOG_FALLBACK_ACTIVE=true
        INSTALL_LOG="/tmp/ostler-install-FALLBACK.log"
        eval "$_fn_body"
        _ostler_set_paths "$_final"
        printf '%s\n' "${INSTALL_LOG}"
    ) 2>/dev/null
)"
if [[ "$_fb_out" == "/tmp/ostler-install-FALLBACK.log" ]]; then
    ok "2d. the /tmp fallback is NOT clobbered by the rebind"
else
    bad "2d. the fallback was rewritten to '${_fb_out}'; an unwriteable LOGS_DIR would swallow the trace"
fi

# ---------------------------------------------------------------------
# ARM 3. THE CONTROL. Both redirection forms, executed for real.
#
# This is the arm that matters. It reproduces the defect and then
# proves the fix, using the mechanism itself rather than a pattern.
# ---------------------------------------------------------------------
_gone="/tmp/ostler-no-such-dir-$$/install.log"

_old_form_stderr="$(
    ( printf 'x\n' >> "$_gone" 2>/dev/null || true ) 2>&1
)"
_new_form_stderr="$(
    ( { printf 'x\n' >> "$_gone"; } 2>/dev/null || true ) 2>&1
)"

if [[ -n "$_old_form_stderr" ]]; then
    ok "3a. CONTROL: the pre-fix form DOES leak to stderr, so this arm can discriminate"
else
    bad "3a. CONTROL FAILED: the pre-fix form was silent here, so 3b proves nothing about the fix"
fi

if [[ -z "$_new_form_stderr" ]]; then
    ok "3b. the braced form is genuinely silent when the path cannot be opened"
else
    bad "3b. the braced form still leaked: ${_new_form_stderr}"
fi

# ---------------------------------------------------------------------
# ARM 4. STRUCTURAL. The emitter carries the braced form.
# ---------------------------------------------------------------------
if [[ ! -f "$EMITTER" ]]; then
    bad "4a. ${EMITTER} not found; arms 4b and 4c are meaningless"
else
    ok "4a. ${EMITTER} present"

    if grep -Fq '{ printf '"'"'[gui-marker] %s%s\n'"'"' "$event" "$trace" \' "$EMITTER"; then
        ok "4b. the marker append is wrapped in a group"
    else
        bad "4b. the marker append is NOT group-wrapped; its 2>/dev/null cannot suppress the open failure"
    fi

    # The un-braced form must not survive anywhere in the emitter.
    if grep -Fq "        printf '[gui-marker] %s%s\\n' \"\$event\" \"\$trace\" \\" "$EMITTER"; then
        bad "4c. the un-braced pre-fix append is STILL present"
    else
        ok "4c. the un-braced pre-fix append is gone"
    fi
fi

# ---------------------------------------------------------------------
# ARM 5. Both edited files must still parse.
# ---------------------------------------------------------------------
for f in install.sh "$EMITTER"; do
    if bash -n "$f" 2>/dev/null; then
        ok "5. ${f} parses"
    else
        bad "5. ${f} FAILS bash -n"
    fi
done

printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
