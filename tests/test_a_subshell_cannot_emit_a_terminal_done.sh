#!/usr/bin/env bash
# A subshell may not speak the last word (#642)
# ============================================
#
# THE INPUT THIS TEST REPLAYS
#
# `set -E` (install.sh) propagates the ERR trap INTO command substitutions.
# When the substituted command exits non-zero the trap fires in the CHILD, the
# child emits a terminal DONE marker and dies, and `OSTLER_DONE_EMITTED=1` dies
# with it -- a subshell cannot write to its parent. The parent's flag is still
# empty. The parent never learned anything happened.
#
# MEASURED on /bin/bash 3.2.57, printing $$ and $BASH_SUBSHELL at every emit:
#
#     local v="$(pgrep -f '<no-match>')"
#         pid=55691  subshell=1   DONE status=fail  failed_steps=1
#         pid=55691  subshell=0   DONE status=ok    failed_steps=0
#
# SAME PID, DIFFERENT SUBSHELL, `fail` then `ok`. The GUI is handed a failed
# install reported as a success.
#
# WHY `local` AND NOT A BARE ASSIGNMENT
#
# A bare `v="$(...)"` emits two markers but BOTH say fail: the parent aborts on
# its own failed assignment, so it agrees with the child. `local` ALWAYS
# RETURNS 0, so it hides the substitution's status from the parent while doing
# nothing about the trap already fired in the child. That difference is the
# whole defect, and it is why this test drives the `local` shape.
#
# WHAT THIS ASSERTS
#
#   1  MUTATION / anti-vacuity. The PRE-FIX handler, read from git, must still
#      produce the defect on this same input: 2 markers, fail then ok. Without
#      this the arms below could pass because the harness stopped reproducing.
#   2  With the fix: exactly ONE terminal marker.
#   3  ...and the subshell failure still LOGS. A LOG marker is not terminal and
#      the GUI does not close on it. progress_emitter.sh:717-725 records what
#      happens when this handler is made quieter without care -- 0 DONE
#      markers, a silent run -- which is the worse half.
#   4  A REAL unmasked failure must STILL report status=fail. The fix must not
#      buy silence.
#   5  CONTROL: a clean run still emits exactly one status=ok failed_steps=0,
#      unchanged.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
LIB="${REPO}/lib/progress_emitter.sh"
INSTALLER="${REPO}/install.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
cannot(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$LIB" ]       || cannot "lib/progress_emitter.sh not found"
[ -f "$INSTALLER" ] || cannot "install.sh not found"

W="$(mktemp -d 2>/dev/null || mktemp -d -t ostler-642sub)"
[ -n "$W" ] && [ -d "$W" ] || cannot "mktemp produced no directory"
trap 'rm -rf "$W"' EXIT

awk '/^_ostler_on_err\(\) \{$/,/^# ─── OSTLER_ERR_TRAP_END/' "$INSTALLER" > "${W}/h.fixed"
hl="$(wc -l < "${W}/h.fixed" | tr -d ' ')"
[ "$hl" -ge 20 ] || cannot "could not extract _ostler_on_err (${hl} lines); its delimiters moved"

# The PRE-FIX handler for arm 1. Read from origin/main; if that is not
# resolvable this is CANNOT-RUN, never a silent skip -- an anti-vacuity arm
# that quietly does not run is exactly the hole it exists to close.
# ── THE PRE-FIX HANDLER: PINNED BLOB FIRST, MUTATION AS FALLBACK ─────
#
# a752275d is the v1.0.66 cut -- the artefact that SHIPPED with this defect.
# Pinned to a fixed sha, never a branch: a control that reads origin/main
# inverts the moment this fix merges. Same rationale as the 7b2130ac pin in
# tests/test_config_reader_absence_does_not_abort_the_install.sh.
#
# CI CLONES SHALLOW (111 of 124 workflows take the depth-1 default), so the
# blob is usually absent. Fetch just that one object, as the launchagent
# bootout test already does, rather than demanding fetch-depth:0 everywhere.
#
# AND IF IT IS STILL UNREACHABLE, MUTATE INSTEAD OF GIVING UP. The pre-fix
# handler is exactly the current handler minus the guard, so it can be
# rebuilt deterministically with no network at all. An anti-vacuity limb that
# silently does not run is the hole it exists to close -- my first version
# used `git show origin/main:` and reported CANNOT-RUN on every PR.
#
# Either route must yield a handler WITHOUT the guard. That invariant is
# asserted below whichever path produced it.
_PREFIX_SHA=a752275d   # v1.0.66 -- the cut that shipped the defect
_pre_src="pinned blob ${_PREFIX_SHA} (v1.0.66)"
if ! git -C "$REPO" cat-file -e "${_PREFIX_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --quiet --depth=1 origin "${_PREFIX_SHA}" 2>/dev/null || true
fi
if git -C "$REPO" show "${_PREFIX_SHA}:install.sh" 2>/dev/null \
     | awk '/^_ostler_on_err\(\) \{$/,/^# ─── OSTLER_ERR_TRAP_END/' > "${W}/h.pre" \
   && [ "$(wc -l < "${W}/h.pre" | tr -d ' ')" -ge 20 ]; then
    :
else
    _pre_src="mutation of the live handler (blob unreachable: shallow clone, no network)"
    awk '
        /BASH_SUBSHELL:-0/ { skip = 1 }
        skip && /^    fi$/ { skip = 0; next }
        !skip              { print }
    ' "${W}/h.fixed" > "${W}/h.pre"
    [ "$(wc -l < "${W}/h.pre" | tr -d ' ')" -lt "$hl" ] \
        || cannot "the mutation removed nothing; the limb would compare the handler with itself"
fi
printf '  pre-fix handler from: %s\n' "$_pre_src"

# THE INVARIANT, whichever route produced it. Match the guard LINE, not the
# word: the comment block above the guard names $BASH_SUBSHELL while
# explaining the defect, so a bare word match reports failure on success.
grep -q 'BASH_SUBSHELL:-0' "${W}/h.pre" \
    && cannot "the pre-fix handler still contains the guard line; it is not pre-fix"
[ "$(wc -l < "${W}/h.pre" | tr -d ' ')" -ge 20 ] \
    || cannot "the pre-fix handler is only $(wc -l < "${W}/h.pre" | tr -d ' ') lines; it did not extract"

cat > "${W}/probe.inc" <<PROBE
eval "\$(declare -f gui_emit | sed '1s/^gui_emit/__real_gui_emit/')"
gui_emit() {
    printf '%s sub=%s %s\n' "\$1" "\$BASH_SUBSHELL" "\$*" >> "${W}/log"
    __real_gui_emit "\$@"
}
PROBE

# A pattern that cannot match any real process. Not a plausible binary name:
# `pgrep -f` matches full command lines, and a pattern that appears in the
# process asking the question exits 0 and measures nothing.
N='ostler-642-no-such-process-zzq'

run() {   # $1 = handler file, $2 = fragment
    : > "${W}/log"
    cat > "${W}/arm.sh" <<EOF
#!/bin/bash
set -Eeuo pipefail
export OSTLER_GUI=1
source "${LIB}"
source "${W}/probe.inc"
source "$1"
OSTLER_DONE_EMITTED=""
gui_step_begin t642 "harness" 3 1 1
$2
gui_step_end ok
gui_done ok
EOF
    bash "${W}/arm.sh" >/dev/null 2>&1
}
n_done(){ grep -c '^DONE' "${W}/log" 2>/dev/null || true; }
n_sublog(){ grep '^LOG' "${W}/log" 2>/dev/null | grep -ci 'inside a subshell' || true; }
done_status(){ grep '^DONE' "${W}/log" 2>/dev/null | sed -n "${1}p" | sed 's/.*status=\([a-z]*\).*/\1/'; }

MASKED="f() { local v=\"\$(pgrep -f '${N}' 2>/dev/null | sort -u)\"; }; f"
BARE="v=\"\$(pgrep -f '${N}' 2>/dev/null | sort -u)\""

# ── 1. MUTATION: the pre-fix handler must still show the defect ────────────
run "${W}/h.pre" "$MASKED"
_n="$(n_done)"; _s1="$(done_status 1)"; _s2="$(done_status 2)"
if [ "$_n" = "2" ] && [ "$_s1" = "fail" ] && [ "$_s2" = "ok" ]; then
    ok "MUTATION: the pre-fix handler still produces 2 markers, ${_s1} then ${_s2}"
else
    bad "MUTATION: expected 2 markers fail-then-ok from the PRE-FIX handler, got ${_n} (${_s1:-?}, ${_s2:-?}).
        The harness no longer reproduces #642, so every arm below proves nothing.
        This is CANNOT-RUN dressed as a pass."
fi

# ── 2 + 3. The fix: one terminal marker, and the failure still speaks ──────
run "${W}/h.fixed" "$MASKED"
_n="$(n_done)"; _l="$(n_sublog)"
[ "$_n" = "1" ] \
    && ok "exactly ONE terminal marker survives the subshell escape (was 2)" \
    || bad "expected 1 terminal marker after the fix, got ${_n}"
[ "$_l" -ge 1 ] \
    && ok "the subshell failure still LOGS (${_l} line): quieter, not silent" \
    || bad "the subshell failure produced no LOG line. progress_emitter.sh:717-725 is the record of why silence is the worse half."

# ── 4. A real unmasked failure must still report fail ──────────────────────
run "${W}/h.fixed" "$BARE"
_n="$(n_done)"; _s="$(done_status 1)"
if [ "$_n" = "1" ] && [ "$_s" = "fail" ]; then
    ok "an UNMASKED failure still reports exactly one status=fail (the fix bought no silence)"
else
    bad "expected 1 marker status=fail for the unmasked assignment, got ${_n} status=${_s:-?}"
fi

# ── 4b. THE BARE SITES MUST STILL ABORT, not merely still report ──────────
#
# 410 assignments in install.sh are bare `X="$(cmd)"` with NO mask. They have
# no handling block, so they are the ones that depend on the parent dying.
# Arm 4 proves such a failure still REPORTS status=fail. It does not prove the
# parent STOPPED, and "reported the failure then carried on doing the install"
# would be a worse outcome than the phantom marker this fix removes.
#
# A sentinel after the failing assignment must never execute.
run "${W}/h.fixed" "${BARE}
gui_log info SENTINEL_REACHED_AFTER_BARE_FAILURE"
if grep -q 'SENTINEL_REACHED' "${W}/log" 2>/dev/null; then
    bad "the parent CONTINUED past a bare failing substitution. The guard has
        turned a fatal abort into a warning, which is worse than the phantom."
else
    ok "a bare failing substitution still ABORTS the parent (sentinel never ran)"
fi

# ── 4c. NO-CHANGE ARM. `|| { }` was ALREADY safe, and this proves the fix
#        did not disturb it. IT DOES NOT DEMONSTRATE THE FIX.
#
# Labelled honestly because it passes with or without the guard, and an arm
# that cannot fail is decoration unless it says so. MEASURED, both handlers,
# counting the handler's OWN log lines to see whether the trap fired at all:
#
#     shape                      pre-fix DONE   fixed DONE   ERR fired
#     bare   X="$(cmd)"               2             1           2
#     masked X="$(cmd)" || { }        1             1           0   <- never
#     local  X="$(cmd)"               2             1           1
#
# `||` puts the assignment in a tested context, and bash suppresses the ERR
# trap there -- INCLUDING inside the substitution's subshell. So the 19
# `|| { }` sites in install.sh never produced a phantom marker and never
# could. The fix's real subject is the 410 BARE sites, which went 2 -> 1.
#
# This arm still earns its place: the `|| { }` block is the deliberate,
# load-bearing mask the hydrate family depends on, and a guard that swallowed
# the failure would break the recording without breaking any marker count.
# Both halves are asserted -- one marker AND the block ran.
run "${W}/h.fixed" "_UNMEASURED=false
v=\"\$(pgrep -f '${N}' 2>/dev/null | sort -u)\" || { _UNMEASURED=true; v=\"\"; }
gui_log info \"UNMEASURED=\${_UNMEASURED}\""
_n="$(n_done)"
_flag="$(grep -o 'UNMEASURED=true' "${W}/log" | head -1)"
if [ "$_n" = "1" ] && [ "$_flag" = "UNMEASURED=true" ]; then
    ok "NO-CHANGE: a '|| { }' site still emits ONE marker and still records (it was already safe)"
else
    bad "expected 1 marker and UNMEASURED=true from the '|| { }' shape; got ${_n} marker(s), flag='${_flag:-unset}'"
fi

# ── 5. CONTROL: the clean run is untouched ─────────────────────────────────
run "${W}/h.fixed" "v=ok"
_n="$(n_done)"; _s="$(done_status 1)"
_fs="$(grep '^DONE' "${W}/log" | sed -n '1p' | sed 's/.*failed_steps=\([0-9]*\).*/\1/')"
if [ "$_n" = "1" ] && [ "$_s" = "ok" ] && [ "$_fs" = "0" ]; then
    ok "CONTROL: a clean run still emits exactly one status=ok failed_steps=0"
else
    bad "CONTROL BROKEN: clean run gave ${_n} marker(s) status=${_s:-?} failed_steps=${_fs:-?}.
        A fix that changes this line has traded a false OK for a silent run."
fi

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
