#!/usr/bin/env bash
# No shipped test may depend on a bash 4 builtin (macOS ships bash 3.2.57)
# =======================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# `/bin/bash` on macOS is 3.2.57, released 2007. `mapfile` and `readarray` are
# bash 4 builtins and simply do not exist there. Two shipped tests called
# `mapfile` and died on the platform the product installs onto, while passing
# on ubuntu CI:
#
#     tests/test_pgrep_no_match_does_not_fabricate_a_done.sh   line 128
#     tests/test_upgrade_path_can_wire_store_auth.sh           line 38
#
# The first is the worse one. It printed FOUR `ok` arms and then died, so its
# output read as a run. The arm it never reached -- "every pgrep command
# substitution is guarded" -- is a live assertion over install.sh, and it had
# never once executed on macOS.
#
# THE SECOND DEATH, WHICH FIXING THE FIRST WOULD HAVE EXPOSED
#
# On bash 3.2 with `set -u`, expanding an EMPTY array as "${a[@]}" is an
# unbound-variable error. Replacing `mapfile` with a read loop and leaving the
# expansion alone swaps one 3.2 death for another. Both files needed
# ${a[@]+"${a[@]}"}.
#
# WHY A GREP COUNT IS NOT THE MEASUREMENT
#
# Matching `mapfile` as a word finds 8 files; matching it loosely finds 23;
# the union of all bash-4 constructs finds 18. Five of the eight carry the
# word in a COMMENT and run fine. Only running them decides, which is what
# found 2 rather than 15. This test therefore looks for mapfile/readarray in a
# COMMAND POSITION and ignores comments.
#
# WHAT THIS TEST ASSERTS
#
#   A  No tests/*.sh or scripts/*.sh invokes mapfile, readarray, `declare -A`
#      or `local -A` as a command.
#   B  NEGATIVE CONTROL, MUST FIRE. A synthetic file that does invoke mapfile
#      is detected, so a pass means the scan works rather than that it found
#      nothing.
#   B2 The same for `declare -A`, because one control proves one predicate.
#      B passing says nothing about whether the widened pattern works.
#   C  The shell this runs under really is bash 3.x. On bash 4+ every arm
#      above would pass for the wrong reason, so it is recorded, not assumed.
#   D  MUST-MISS, MUST STAY QUIET. `grep -q 'declare -A' file` is a search
#      string, not an invocation, and the file carrying it runs clean on 3.2.
#      A scan that cannot stay quiet on a safe shape is red on a healthy tree,
#      and a gate that is red on day one is a gate people route around.
#
# MEASURED, NOT ASSUMED: `/bin/bash -n` accepts ALL FIVE of these constructs
# on 3.2.57. A parse sweep returns uniform zeros and reads as a clean tree, so
# there is no cheap syntactic shortcut here. Worse, `mapfile` alone exits
# rc=0 -- the diagnostic goes to stderr and the script carries on -- so an
# rc-only detector misses it too. Only stderr, or this scan, decides.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
fatal(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# The bash 4 constructs, in COMMAND position: start of line, or after ; | & (
# or `do`/`then`. Comment lines are dropped first.
#
# COMMAND POSITION IS NOT FUSSINESS, IT IS THE DIFFERENCE BETWEEN A GATE AND A
# NUISANCE. tests/test_a_gate_that_exits_zero_after_dying_is_not_a_pass.sh:74
# contains the text `declare -A` inside a quoted search string:
#
#     && grep -q 'declare -A' "$SPEC" 2>/dev/null; then
#
# That file runs clean under 3.2 (verified: rc=0, no diagnostic on stderr). A
# looser pattern flags it, the guard is red on a healthy tree from the day it
# lands, and this repo already has the scar for what happens next -- see the
# non-retroactive PR-age rule in gui/Makefile check-pr-age. There `grep` holds
# command position, not `declare`, so the anchor below skips it. Arm D proves
# that rather than trusting it.
scan() {
    local dir="$1"
    grep -rnE '^[^#]*(^|[;|&(]|[[:space:]](do|then)[[:space:]])[[:space:]]*(mapfile|readarray|declare[[:space:]]+-A|local[[:space:]]+-A)[[:space:]]' \
        "$dir" --include='*.sh' 2>/dev/null || true
}

HITS="$(scan "${REPO}/tests"; scan "${REPO}/scripts")"
N_HITS="$(printf '%s' "$HITS" | grep -c . || true)"

# THE SHIPPED SHELL. install.sh and lib/*.sh are the files that actually run
# on a customer's Mac under /bin/bash 3.2.57, so they matter more than any
# test here. Two of them already carry the line
#
#     # file stays bash-3.2 clean: no associative arrays, no mapfile, no ${x^^}
#
# which means somebody established this invariant deliberately and wrote it
# down. NOTHING CHECKED IT. A discipline that lives only in a comment is one
# distracted afternoon from being untrue, and the 17 ubuntu-only workflows
# that EXECUTE installer shell would not notice: ubuntu's bash is 5.x, where
# every one of these constructs works.
SHIPPED=""
for _f in "${REPO}/install.sh" "${REPO}"/lib/*.sh "${REPO}/assistant-agent/INSTALL_SNIPPET.sh"; do
    [ -f "$_f" ] || continue
    SHIPPED="${SHIPPED} ${_f}"
done
SHIP_HITS=""
for _f in $SHIPPED; do
    _h="$(grep -nE '^[^#]*(^|[;|&(]|[[:space:]](do|then)[[:space:]])[[:space:]]*(mapfile|readarray|declare[[:space:]]+-A|local[[:space:]]+-A)[[:space:]]' "$_f" 2>/dev/null | sed "s|^|${_f}:|" || true)"
    [ -n "$_h" ] && SHIP_HITS="${SHIP_HITS}${_h}
"
    # ${x^^} / ${x,,} are bash 4 case-modifying expansions. On 3.2 they are a
    # runtime "bad substitution", NOT a parse error -- `bash -n` accepts them
    # -- so only a scan or an execution finds them. `^[^#]*` drops the two
    # comment lines that name the construct while forbidding it.
    _c="$(grep -nE '^[^#]*\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)' "$_f" 2>/dev/null | sed "s|^|${_f}:|" || true)"
    [ -n "$_c" ] && SHIP_HITS="${SHIP_HITS}${_c}
"
done
N_SHIP="$(printf '%s' "$SHIP_HITS" | grep -c . || true)"

# --- C: record the shell, because it changes what these arms mean ----------
BV="${BASH_VERSINFO[0]:-0}"
if [ "$BV" -ge 4 ]; then
    ok "C  running under bash ${BV}.x, which HAS mapfile -- arm A below is a source scan, not a runtime claim"
else
    ok "C  running under bash ${BV}.x (no mapfile builtin), the shell the product ships to"
fi

# --- B first: the scan must be able to find one ----------------------------
TMP="$(mktemp -d)" || fatal "no temp dir"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/tests"
printf '#!/bin/bash\nmapfile -t x < <(echo hi)\n' > "${TMP}/tests/synthetic_offender.sh"
printf '#!/bin/bash\ndeclare -A m\n'              > "${TMP}/tests/synthetic_offender_assoc.sh"
# The MUST-MISS. Real shape, lifted from
# test_a_gate_that_exits_zero_after_dying_is_not_a_pass.sh:74.
printf '#!/bin/bash\nif grep -q %sdeclare -A%s "$1"; then :; fi\n' "'" "'" \
    > "${TMP}/tests/must_miss_quoted.sh"
CTL="$(scan "${TMP}/tests")"
# `printf ... | grep -q` is the short-circuiting-consumer inversion, and
# tests/test_pipefail_shortcircuit_inversion.sh caught it here on the first
# run. `grep -q` exits on the first match and SIGPIPEs the producer, so under
# `pipefail` the pipeline can report FAILURE on a needle that IS present.
# That would invert THIS arm specifically -- the negative control -- and an
# inverted control means a blind scan reads as a clean tree, which is the
# exact failure this file exists to prevent. `grep -c` must read to EOF, and
# unlike the herestring remedy it is POSIX rather than a bashism.
if [ "$(printf '%s' "$CTL" | grep -c 'synthetic_offender\.sh')" -gt 0 ]; then
    ok "B  negative control: a synthetic mapfile caller IS detected"
else
    fatal "the scan did not detect a file that calls mapfile on line 2. It cannot find anything, so arm A would pass by being blind."
fi

if [ "$(printf '%s' "$CTL" | grep -c 'synthetic_offender_assoc')" -gt 0 ]; then
    ok "B2 negative control: a synthetic 'declare -A' caller IS detected"
else
    fatal "the scan missed a file whose line 2 is 'declare -A'. The widened pattern does not work, so arm A says nothing about associative arrays."
fi

# THE MUST-MISS. A control that only ever fires proves the scan is loud, not
# that it is right. This one proves it can stay quiet on the shape that is
# genuinely safe, which is what stops the guard being red on a clean tree.
if [ "$(printf '%s' "$CTL" | grep -c 'must_miss_quoted')" -eq 0 ]; then
    ok "D  must-miss: 'grep -q \"declare -A\" file' is NOT flagged (a quoted search string is not an invocation)"
else
    bad "D  the scan flagged a quoted search string. It would be red on a healthy tree, and a gate that cries wolf gets routed around."
fi

# --- A: the real tree -------------------------------------------------------
if [ "$N_HITS" -eq 0 ]; then
    ok "A  no tests/*.sh or scripts/*.sh calls mapfile, readarray or declare -A"
else
    bad "A  ${N_HITS} call site(s) use a bash 4 construct and will die on macOS:"
    printf '%s\n' "$HITS" | sed 's|^|        |' | head -10
fi

# --- E: the shipped shell ---------------------------------------------------
_n_ship_files="$(printf '%s' "$SHIPPED" | wc -w | tr -d ' ')"
if [ "$_n_ship_files" -lt 3 ]; then
    fatal "only ${_n_ship_files} shipped shell file(s) resolved. install.sh and lib/*.sh must be there; a glob that matched nothing would make arm E pass by scanning an empty set."
fi
if [ "$N_SHIP" -eq 0 ]; then
    ok "E  the SHIPPED shell (${_n_ship_files} files: install.sh, lib/*.sh, INSTALL_SNIPPET.sh) uses no bash 4 construct"
else
    bad "E  ${N_SHIP} bash 4 construct(s) in the shell that runs on the customer's Mac:"
    printf '%s\n' "$SHIP_HITS" | grep -v '^$' | sed 's|^|        |' | head -10
fi

# --- E2: control for arm E, on the same predicates -------------------------
printf '#!/bin/bash\ndeclare -A m\nx=abc; echo "${x^^}"\n' > "${TMP}/seeded_shipped.sh"
_e2a="$(grep -cE '^[^#]*(^|[;|&(]|[[:space:]](do|then)[[:space:]])[[:space:]]*(mapfile|readarray|declare[[:space:]]+-A|local[[:space:]]+-A)[[:space:]]' "${TMP}/seeded_shipped.sh" || true)"
_e2b="$(grep -cE '^[^#]*\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)' "${TMP}/seeded_shipped.sh" || true)"
if [ "$_e2a" -ge 1 ] && [ "$_e2b" -ge 1 ]; then
    ok "E2 control: both shipped-shell predicates fire on a seeded file (builtin=${_e2a}, case-expansion=${_e2b})"
else
    fatal "arm E's predicates did not fire on a file containing both constructs (builtin=${_e2a}, case-expansion=${_e2b}). Arm E's zero would mean nothing."
fi

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
