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
#   A  No tests/*.sh or scripts/*.sh invokes mapfile or readarray as a command.
#   B  NEGATIVE CONTROL, MUST FIRE. A synthetic file that does invoke one is
#      detected, so a pass means the scan works rather than that it found
#      nothing.
#   C  The shell this runs under really is bash 3.x. On bash 4+ every arm
#      above would pass for the wrong reason, so it is recorded, not assumed.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
fatal(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# mapfile/readarray in COMMAND position: start of line, or after ; | & ( or
# `do`/`then`. Comment lines are dropped first.
scan() {
    local dir="$1"
    grep -rnE '^[^#]*(^|[;|&(]|[[:space:]](do|then)[[:space:]])[[:space:]]*(mapfile|readarray)[[:space:]]' \
        "$dir" --include='*.sh' 2>/dev/null || true
}

HITS="$(scan "${REPO}/tests"; scan "${REPO}/scripts")"
N_HITS="$(printf '%s' "$HITS" | grep -c . || true)"

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
CTL="$(scan "${TMP}/tests")"
# `printf ... | grep -q` is the short-circuiting-consumer inversion, and
# tests/test_pipefail_shortcircuit_inversion.sh caught it here on the first
# run. `grep -q` exits on the first match and SIGPIPEs the producer, so under
# `pipefail` the pipeline can report FAILURE on a needle that IS present.
# That would invert THIS arm specifically -- the negative control -- and an
# inverted control means a blind scan reads as a clean tree, which is the
# exact failure this file exists to prevent. `grep -c` must read to EOF, and
# unlike the herestring remedy it is POSIX rather than a bashism.
if [ "$(printf '%s' "$CTL" | grep -c 'synthetic_offender')" -gt 0 ]; then
    ok "B  negative control: a synthetic mapfile caller IS detected"
else
    fatal "the scan did not detect a file that calls mapfile on line 2. It cannot find anything, so arm A would pass by being blind."
fi

# --- A: the real tree -------------------------------------------------------
if [ "$N_HITS" -eq 0 ]; then
    ok "A  no tests/*.sh or scripts/*.sh calls mapfile or readarray"
else
    bad "A  ${N_HITS} call site(s) use a bash 4 builtin and will die on macOS:"
    printf '%s\n' "$HITS" | sed 's|^|        |' | head -10
fi

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
