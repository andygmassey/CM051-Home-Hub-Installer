#!/usr/bin/env bash
# =============================================================================
# osascript sites must be bounded by a shell-side deadline.
#
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# An Apple Event holds its caller for the whole of the target application's
# response time. If the target shows a modal, or is TCC-gated with nobody at the
# keyboard to dismiss the consent sheet, the send NEVER RETURNS. macOS has no
# timeout(1), and AppleScript's own `with timeout` bounds Apple EVENTS, not the
# local work -- so neither of the two obvious remedies is a remedy.
#
# The only thing that bounds it is a shell-side deadline that kills the process.
# install.sh already ships one: _ostler_run_with_deadline.
#
# 🔴 THIS TEST IS A RATCHET, NOT A COMPLETENESS CLAIM.
# It prints the DENOMINATOR every run. A green here means "no site regressed",
# NOT "every site is bounded". At the time of writing 5 of 15 are bounded and
# the other 10 can still wedge an install. Read the number, not the colour.
#
# THE PROSE TRAP, WHICH BIT TWICE BEFORE THIS FILE EXISTED
# -----------------------------------------------------------------------------
# `echo "... skips osascript and uses"` is not an invocation. Two independent
# sweeps of this file both scored echoes as code and both reported 17 before
# filtering and 15 after. The filter below is load-bearing; arm (D) proves it
# is by feeding it a line that is prose and asserting it is NOT counted.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
cannot(){ printf '\n🔴 CANNOT-RUN: %s\n' "$*"; printf 'This is neither a pass nor a failure. Refusing.\n'; exit 2; }

[ -f "${INSTALL_SH}" ] || cannot "install.sh not found at ${INSTALL_SH}"

# -----------------------------------------------------------------------------
# The counter. Kept in one place so the test and the ratchet cannot disagree.
# -----------------------------------------------------------------------------
count_sites() {
    python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
total = dialogs = machine_ok = dialog_ok = mismatched = 0
for i, l in enumerate(lines):
    s = l.strip()
    if s.startswith('#'):
        continue
    if 'osascript' not in l:
        continue
    # PROSE FILTER: an invocation begins a command. `echo "...osascript..."`,
    # `printf`, and help text do not. Require osascript at a command position.
    if not re.search(r'(^|[\s;&|(=`$])osascript\b', l):
        continue
    if re.match(r'\s*(echo|printf|dbg|log|warn|ok|info)\b', s):
        continue
    total += 1
    # A site is INTERACTIVE if the invocation (which may span continuation
    # lines) contains `display dialog`. Those block on a HUMAN by design.
    block = '\n'.join(lines[i-1:i+6])
    interactive = 'display dialog' in block
    prev = lines[i-1] if i > 0 else ''
    ctx = prev + '\n' + l
    # 🔴 SCORE THE BEHAVIOUR (is there a deadline wrapper?), NOT A VARIABLE
    # NAME. An earlier version of this counter required the literal
    # OSTLER_OSASCRIPT_TIMEOUT_S and therefore scored the two Messages
    # Automation probes UNBOUNDED -- they are bounded, with their own
    # purpose-specific OSTLER_IMESSAGE_PROBE_TIMEOUT_S from CM051 #891.
    # A false negative in the instrument, from pinning a spelling instead of
    # the property. Any deadline counts; only the DIALOG class needs its own.
    has_deadline         = '_ostler_run_with_deadline' in ctx
    has_dialog_deadline  = 'OSTLER_OSASCRIPT_DIALOG_TIMEOUT_S' in ctx
    has_machine_deadline = has_deadline and not has_dialog_deadline
    if interactive:
        dialogs += 1
        if has_dialog_deadline:
            dialog_ok += 1
        elif has_machine_deadline:
            # 🔴 THE REGRESSION THIS ARM EXISTS FOR: a 20 s deadline on a
            # dialog kills it under a customer who is still reading.
            mismatched += 1
    else:
        if has_machine_deadline:
            machine_ok += 1
        elif has_dialog_deadline:
            # A 15-minute deadline on a machine event is not a bound at all.
            mismatched += 1
print(f"{total} {dialogs} {machine_ok} {dialog_ok} {mismatched}")
PY
}

echo "=== ARM A: denominator, classification, and ratchet ==="
read -r TOTAL DIALOGS MACHINE_OK DIALOG_OK MISMATCH <<<"$(count_sites "${INSTALL_SH}")"
MACHINE=$((TOTAL - DIALOGS))
WRAPPED=$((MACHINE_OK + DIALOG_OK))
printf '  osascript invocations : %s   (DENOMINATOR)\n' "${TOTAL}"
printf '    machine-to-machine  : %s   bounded %s  (20s -- nothing human in the loop)\n' \
       "${MACHINE}" "${MACHINE_OK}"
printf '    display dialog      : %s   bounded %s  (15min -- blocks on a HUMAN by design)\n' \
       "${DIALOGS}" "${DIALOG_OK}"
printf '  bounded, correct kind : %s\n' "${WRAPPED}"
printf '  STILL UNBOUNDED       : %s   <-- these can wedge an install\n' "$((TOTAL - WRAPPED))"

# 🔴 THE ARM THAT STOPS THE FIX FROM BECOMING THE DEFECT.
# A dialog carrying the 20-second machine deadline reads as "bounded" to any
# count, and would kill the FDA pre-warn dialog under a customer still reading
# it. Over-approximating a hazard does not fail safe.
if [ "${MISMATCH}" -eq 0 ]; then
    ok "every site carries the deadline for ITS KIND (0 mismatched)"
else
    bad "${MISMATCH} site(s) carry the WRONG deadline -- a dialog on the 20s bound is killed mid-read"
fi

# ANTI-VACUITY. "0 of 0 wrapped" is what a broken read prints, and it would
# satisfy any floor. Refuse to believe a count over a denominator this small.
if [ "${TOTAL}" -lt 10 ]; then
    cannot "only ${TOTAL} osascript sites found; the counter is broken, not the file"
fi

# RATCHETS, one per class. Raise as sites are bounded; never lower.
#
# ⚠️ LOWERED ONCE, 9 -> 8, 2026-09-02 (WALK-361). READ THIS BEFORE LOWERING IT
# AGAIN -- the answer is almost always "no".
#
# THE RATCHET CANNOT SEE THE DIFFERENCE BETWEEN THE TWO WAYS A COUNT DROPS:
#   (a) a site LOST its wrapper           -> a real hazard, the reason this exists
#   (b) the SITE ITSELF WAS DELETED       -> no hazard; there is nothing to bound
# Both print as "bounded N < floor". This edit is case (b) and only case (b).
#
# What was deleted: the single `tell application "Finder" to close windows`
# Apple Event in install.sh's iMessage-FDA assist block. It WAS correctly
# wrapped in _ostler_run_with_deadline, so it counted toward this floor. It
# was removed because sending ANY Apple Event to Finder makes macOS raise a
# TCC consent dialog reading "control Finder ... access to documents and data",
# stamped with our single NSAppleEventsUsageDescription, which talks about the
# administrator password. Andy hit that on the v1.0.57 launch walk, having
# reported it once before. A cosmetic window tidy-up was buying a permanent,
# frightening permission grant, and the copy could not be fixed -- macOS allows
# exactly ONE usage string per app, so it cannot be worded per target.
#
# The deletion is guarded in the other direction by
# tests/test_no_finder_appleevent.sh, which FAILS if an Apple Event to Finder ever
# returns. So this floor going down by one is paired with a new gate that makes
# the count going back UP a failure. Both were mutation-tested against the real
# pre-fix tree at origin/main.
#
# ANYONE LOWERING THIS AGAIN: prove case (b). Name the deleted site, show it is
# absent from install.sh, and say what stops it coming back. A floor lowered
# without that is indistinguishable from a wrapper quietly going missing.
FLOOR_MACHINE=8
FLOOR_DIALOG=6
if [ "${MACHINE_OK}" -ge "${FLOOR_MACHINE}" ]; then
    ok "machine sites bounded ${MACHINE_OK} >= floor ${FLOOR_MACHINE}"
else
    bad "machine sites bounded ${MACHINE_OK} < floor ${FLOOR_MACHINE} -- a site LOST its deadline"
fi
if [ "${DIALOG_OK}" -ge "${FLOOR_DIALOG}" ]; then
    ok "dialog sites bounded ${DIALOG_OK} >= floor ${FLOOR_DIALOG}"
else
    bad "dialog sites bounded ${DIALOG_OK} < floor ${FLOOR_DIALOG} -- a dialog can hang an unattended install forever"
fi

echo
echo "=== ARM B: the deadline helper is present and is the shipped one ==="
if /usr/bin/grep -q '^_ostler_run_with_deadline()' "${INSTALL_SH}"; then
    ok "_ostler_run_with_deadline is defined in install.sh"
else
    bad "_ostler_run_with_deadline is MISSING -- every wrap above is inert"
fi
if /usr/bin/grep -q 'OSTLER_OSASCRIPT_TIMEOUT_S' "${INSTALL_SH}"; then
    ok "OSTLER_OSASCRIPT_TIMEOUT_S tunable present"
else
    bad "OSTLER_OSASCRIPT_TIMEOUT_S absent -- the wraps have no deadline to read"
fi

echo
echo "=== ARM C: the Contacts read reports its THIRD state ==="
# A deadline kill writes NOTHING to stderr, so the -1743 and -600 diagnoses
# both miss it. Without a dedicated branch the customer gets an empty name
# field and no explanation at all. Assert the branch exists AND that the rc
# crosses the command-substitution subshell by FILE (a variable cannot).
if /usr/bin/grep -q 'CARD_RC_FILE' "${INSTALL_SH}"; then
    ok "the read's rc crosses the subshell by file, not by variable"
else
    bad "CARD_RC_FILE absent -- _READ_MY_CARD_RC would read 0 at every call site"
fi
if /usr/bin/grep -q '_READ_MY_CARD_RC" -eq 124' "${INSTALL_SH}"; then
    ok "a timed-out card read takes its own branch and warns"
else
    bad "no rc=124 branch -- a timed-out read falls through both diagnoses SILENTLY"
fi

echo
echo "=== ARM D (CONTROL): the prose filter actually filters ==="
# If this arm cannot go red, arm A's number is decoration. Feed the counter a
# file whose ONLY osascript mentions are prose, and demand zero.
TMPD="$(mktemp -d)"; trap 'rm -rf "${TMPD}"' EXIT
{
  printf 'echo "the probe skips osascript and uses something else"\n'
  printf '# osascript -e (commented out)\n'
  printf 'printf "Probe: osascript tell application\\n"\n'
} > "${TMPD}/prose.sh"
read -r P_TOT P_D P_M P_DO P_MM <<<"$(count_sites "${TMPD}/prose.sh")"
if [ "${P_TOT}" -eq 0 ]; then
    ok "prose-only file counts 0 invocations (filter is live)"
else
    bad "prose-only file counted ${P_TOT} -- the filter is inert, arm A is noise"
fi

# And the inverse: a real invocation MUST be counted, or the filter eats everything.
printf 'osascript -e %s\n' "'tell application \"Finder\" to close windows'" > "${TMPD}/real.sh"
read -r R_TOT R_D R_M R_DO R_MM <<<"$(count_sites "${TMPD}/real.sh")"
if [ "${R_TOT}" -eq 1 ]; then
    ok "a real invocation counts 1 (filter is not over-broad)"
else
    bad "a real invocation counted ${R_TOT} -- the filter eats real code"
fi

echo
echo "=== ARM E (MUTATION): removing a wrap must turn arm A red ==="
MUT="${TMPD}/install.mutated.sh"
# Delete the wrap line preceding the Contacts read. If the count does not drop,
# the counter is not measuring what arm A claims it measures.
python3 - "${INSTALL_SH}" "${MUT}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8', errors='replace').read().split('\n')
out, removed = [], 0
for i, l in enumerate(lines):
    nxt = lines[i+1] if i+1 < len(lines) else ''
    if removed == 0 and '_ostler_run_with_deadline' in l and 'osascript' in nxt:
        removed += 1
        continue            # drop the wrap, keep the osascript
    out.append(l)
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
print(f"mutations applied: {removed}", file=sys.stderr)
PY
read -r M_TOT M_D M_MO M_DO M_MM <<<"$(count_sites "${MUT}")"
M_WRAP=$((M_MO + M_DO))
if [ "${M_TOT}" -ne "${TOTAL}" ]; then
    bad "mutation changed the DENOMINATOR ${TOTAL} -> ${M_TOT}; it deleted a site, not a wrap"
elif [ "${M_WRAP}" -eq "$((WRAPPED - 1))" ]; then
    ok "removing one wrap drops bounded ${WRAPPED} -> ${M_WRAP} (counter is live)"
else
    bad "removing a wrap left bounded at ${M_WRAP} (expected $((WRAPPED - 1))) -- MUTATION INERT, this test proves nothing"
fi

echo
printf 'PASS %s   FAIL %s\n' "${PASS}" "${FAIL}"
printf '%s of %s osascript sites bounded (%s machine @20s, %s dialog @15min).\n' \
       "${WRAPPED}" "${TOTAL}" "${MACHINE_OK}" "${DIALOG_OK}"
printf '🔴 Green means every site carries the deadline for ITS KIND. It does NOT\n'
printf '   mean anyone has watched a dialog survive 15 minutes on a real box.\n'
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
