#!/usr/bin/env bash
#
# tests/test_pgrep_no_match_does_not_fabricate_a_done.sh
#
# #642. `pgrep` exits 1 when NOTHING MATCHES. In a bare command-substitution
# assignment under `set -Eeuo pipefail` (install.sh:29) that failure runs the
# ERR trap INSIDE the substitution's subshell -- `set -E` put it there -- so the
# subshell emits a TERMINAL `DONE status=fail` marker and dies, while the PARENT
# shell carries on installing. The customer gets a red failure banner over an
# install that is still working.
#
# Seen live on the v1.0.62 walk: two DONE markers with DIFFERENT line numbers
# (L21925 from the subshell, L22393 from the parent), followed by steps 27, 28
# and 29 completing normally. It also explains #639, which stood open for a day.
#
# THIS TEST HAS TWO ARMS AND NEEDS BOTH.
#
#   Arm 1 (BEHAVIOURAL) proves WHY the source rule below matters, by running the
#   real shipped ERR handler against both spellings. Without it, arm 2 is an
#   unexplained style rule that a future editor will delete.
#
#   Arm 2 (SOURCE) is the actual guard on install.sh. Without it, arm 1 passes
#   forever while the real script regresses.
#
# THERE IS NO EXEMPTION, AND THAT IS THE POINT OF ARM 1c.
#
# I first believed a `for` LIST was safe, on a control that used
# `for x in $( exit 1 )`. `exit` is the one construct that does NOT trigger ERR,
# so that control could not fail and my "safe" reading was a false negative. Run
# against a real `pgrep` the for-list fabricates markers exactly like a bare
# assignment. Arm 1c now PROVES the for-list is unsafe rather than exempting it,
# so nobody can reintroduce the hole on the reasoning I used.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO_ROOT}/lib/progress_emitter.sh"
INSTALLER="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LIB"       ]] || fail "lib/progress_emitter.sh not found"
[[ -f "$INSTALLER" ]] || fail "install.sh not found"

# PORTABILITY: `mktemp -d -t NAME` with no X's in the template is BSD-only.
# GNU mktemp (ubuntu-latest, which is what CI runs) refuses it outright with
# "too few X's in template", leaves WORK EMPTY, and every subsequent write goes
# to `/`. This is the repo's existing idiom: plain `-d` first (GNU + BSD both
# accept it), BSD `-t` only as the fallback.
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ostler-642)"
[[ -n "$WORK" && -d "$WORK" ]] || fail "mktemp produced no directory. CANNOT-RUN."
trap 'rm -rf "$WORK"' EXIT
rc=0

# ── Extract the REAL ERR handler, by its own delimiters ───────────
awk '/^_ostler_on_err\(\) \{$/,/^# ─── OSTLER_ERR_TRAP_END/' \
    "$INSTALLER" > "${WORK}/handler.inc"
hl="$(wc -l < "${WORK}/handler.inc" | tr -d ' ')"
[[ "$hl" -ge 20 ]] || fail "could not extract _ostler_on_err (${hl} lines).
      CANNOT-RUN, not a pass: install.sh's delimiters moved."
grep -q "^trap '_ostler_on_err" "${WORK}/handler.inc" \
    || fail "extracted handler has no ERR trap. CANNOT-RUN, not a pass."

# ── Arm 1: the behaviour, three spellings ─────────────────────────
#
# A pattern that cannot match any real process. Deliberately not a plausible
# binary name: this must be a guaranteed no-match on ANY machine, including a
# CI runner, or the arm measures the runner rather than the code.
NOMATCH='ostler-642-no-such-process-zzq'

run_arm() {   # $1 = shell fragment producing the assignment
    cat > "${WORK}/arm.sh" <<EOF
#!/bin/bash
set -Eeuo pipefail
export OSTLER_GUI=1
source "${LIB}"
source "${WORK}/handler.inc"
OSTLER_DONE_EMITTED=""
gui_step_begin t642 "harness" 3 1 1
$1
false
EOF
    bash "${WORK}/arm.sh" 2>&1 >/dev/null | grep -c 'DONE' || true
}

# 1a UNGUARDED -- the defect. Must emit TWO terminal markers.
a="$(run_arm "v=\"\$(pgrep -f '${NOMATCH}' 2>/dev/null | sort -u)\"")"
# 1b GUARDED -- the fix. Must emit exactly ONE.
b="$(run_arm "v=\"\$(pgrep -f '${NOMATCH}' 2>/dev/null | sort -u || true)\"")"
# 1c FOR-LIST, UNGUARDED -- must emit TWO. Proves there is no exemption.
c="$(run_arm "for k in \$(pgrep -f '${NOMATCH}' 2>/dev/null); do :; done")"
# 1d FOR-LIST, GUARDED -- must emit ONE. Proves the same fix works there.
d="$(run_arm "for k in \$(pgrep -f '${NOMATCH}' 2>/dev/null || true); do :; done")"

if [[ "$a" == "2" ]]; then
    echo "ok   arm 1a: an UNGUARDED pgrep substitution fabricates 2 DONE markers"
else
    echo "FAIL arm 1a: expected 2 DONE markers from the unguarded form, got ${a}."
    echo "     The harness no longer reproduces #642, so arms 1b/2 prove nothing."
    echo "     This is CANNOT-RUN, not a pass."
    rc=1
fi
if [[ "$b" == "1" ]]; then
    echo "ok   arm 1b: '|| true' brings it back to exactly 1"
else
    echo "FAIL arm 1b: expected 1 DONE marker from the guarded form, got ${b}."
    rc=1
fi
if [[ "$c" == "2" ]]; then
    echo "ok   arm 1c: an UNGUARDED for-list fabricates 2 markers too (no exemption)"
else
    echo "FAIL arm 1c: expected 2 DONE markers from the unguarded for-list, got ${c}."
    echo "     Either bash changed, or the harness stopped reproducing the defect."
    echo "     CANNOT-RUN, not a pass."
    rc=1
fi
if [[ "$d" == "1" ]]; then
    echo "ok   arm 1d: '|| true' fixes the for-list form as well"
else
    echo "FAIL arm 1d: expected 1 DONE marker from the guarded for-list, got ${d}."
    rc=1
fi

# ── Arm 2: the rule, on the real install.sh ───────────────────────
#
# NOT `[^)]*` -- that spans '|| true' and would match the very lines the fix
# adds, which is exactly the false reading that nearly shipped here.
# bash 3.2 (the /bin/bash the product ships to) has no `mapfile`; it is a
# bash 4 builtin. This file was green on ubuntu CI and died on macOS at this
# line, AFTER printing four `ok` arms -- partial credit that reads as a run.
unguarded=()
while IFS= read -r _line; do unguarded+=("$_line"); done < <(grep -nE '\$\(pgrep' "$INSTALLER" | grep -v '|| true' || true)

# POSITIVE CONTROL: the predicate must be able to SEE guarded sites, or its
# zero would be a dead predicate rather than a clean tree.
guarded_n="$(grep -nE '\$\(pgrep' "$INSTALLER" | grep -c '|| true' || true)"
if [[ "$guarded_n" -lt 1 ]]; then
    echo "FAIL arm 2 control: found 0 GUARDED pgrep substitutions."
    echo "     The predicate cannot see the shape it is grading. CANNOT-RUN."
    rc=1
fi

offenders=0
# ${a[@]+"${a[@]}"} because an EMPTY array under `set -u` is an
# unbound-variable error on bash 3.2 -- fixing only the mapfile would
# have swapped one 3.2 death for another.
for line in ${unguarded[@]+"${unguarded[@]}"}; do
    # NO EXEMPTIONS. Arm 1c proves a for-list is just as unsafe.
    echo "FAIL arm 2: unguarded pgrep command substitution: ${line}"
    offenders=$(( offenders + 1 ))
done
if [[ "$offenders" -eq 0 ]]; then
    echo "ok   arm 2: every pgrep command substitution is guarded (${guarded_n} guarded)"
else
    echo "     pgrep returns 1 on NO MATCH. Append '|| true' inside the \$( )."
    rc=1
fi

[[ "$rc" -eq 0 ]] && echo "PASS: tests/test_pgrep_no_match_does_not_fabricate_a_done.sh"
exit "$rc"
