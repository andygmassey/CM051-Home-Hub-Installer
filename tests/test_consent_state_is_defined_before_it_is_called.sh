#!/usr/bin/env bash
# A shell function must be DEFINED before the line that calls it runs.
#
# WHY THIS EXISTS. MEASURED 2026-09-04, walk 10 of v1.0.65 on a cold account,
# the first walk ever to reach step 21 of 40:
#
#     #OSTLER STEP_END id=email_ingest status=error elapsed_s=5 rc=127
#     Install aborted unexpectedly at line 21445 (step email_ingest):
#         _OSTLER_CONSENT_TP_EMAIL="$(_ostler_consent_state ...)"
#     #OSTLER DONE status=fail code=ERR-99-INSTALL-ABORT-L21445
#
# rc=127 is "command not found". install.sh is a LINEAR script: its step
# bodies are top-level statements executed in file order. The assignment sat
# at 21445 and the function it calls was defined at 21494, 49 lines further
# down, so the call ran against a name bash had not yet bound.
#
# THE INTENT BEHIND THE HOIST WAS CORRECT. The comment above the assignment
# explains it: the TOTAL_STEPS decrement and the guard below it must read ONE
# value computed ONCE, or the denominator shrinks mid-run (v1061-D005). The
# assignment was moved up to achieve that and overshot the definition. The fix
# keeps the single computation and moves the DEFINITION up instead.
#
# WHO HITS IT: every customer. The assignment is unconditional top-level code
# on the ordinary install path. It shipped in v1.0.65 and was never reached by
# a walk before, because earlier walks all died at steps 6, 10 and 21.
#
# THE TEST IS AN EXECUTION AND HAS TO BE. The defect is an EXIT STATUS
# produced by name resolution order. Both the broken and the fixed tree
# contain exactly the same definition and exactly the same call; only their
# ORDER differs, and no pattern over either statement can tell them apart.
# So this extracts the two statements IN FILE ORDER and runs them.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Emit the definition block and the first call statement IN THE ORDER THEY
# APPEAR IN THE FILE. Preserving that order is the entire point: reordering
# them here would destroy the property under test.
# Prints nothing and exits 3 if either statement is absent.
_extract_in_file_order() {
    python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read().split('\n')
ds = de = call = None
for i, l in enumerate(src):
    if ds is None and re.match(r'^_ostler_consent_state\(\)\s*\{', l):
        ds = i
        for j in range(i, len(src)):
            if src[j] == '}':
                de = j
                break
    if call is None and '$(_ostler_consent_state ' in l and not l.lstrip().startswith('#'):
        call = i
if ds is None or de is None or call is None:
    sys.exit(3)
defblock = '\n'.join(src[ds:de+1])
callstmt = src[call]
print(defblock + '\n' + callstmt if ds < call else callstmt + '\n' + defblock)
PY
}

# Runs the extracted pair under the SHIPPED shell options. install.sh uses
# `set -Eeuo pipefail`; without it, a 127 would not abort and the defect is
# invisible. Echoes "<exit>|<value>".
_run() {
    local file="$1" decision="$2" body r="${WORK}/r"
    rm -rf "$r"; mkdir -p "$r"
    body="$(_extract_in_file_order "$file")" || { printf 'NOSTMT|'; return; }
    [ -n "$body" ] || { printf 'NOSTMT|'; return; }
    {
        printf '%s\n' 'set -Eeuo pipefail'
        # Only what the two statements read. OSTLER_PYTHON deliberately unset:
        # the durable-registry probe must not run, so `unknown` is reachable
        # without inventing a consent record anywhere on this machine.
        printf 'OSTLER_CONSENT_THIRD_PARTY_DECISION=%s\n' "$(printf '%q' "$decision")"
        printf '%s\n' "$body"
        printf '%s\n' 'printf "%s" "$_OSTLER_CONSENT_TP_EMAIL"'
    } > "${r}/run.sh"
    local out rc
    out="$(bash "${r}/run.sh" 2>/dev/null)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "── the mechanism itself, so the predicate is not taken on trust ──"
# Without this, a harness that silently failed to reproduce ordering would
# report the subject green for the wrong reason.
cat > "${WORK}/mech_bad.sh" <<'EOS'
set -Eeuo pipefail
V="$(_m arg)"
_m() { printf 'x'; }
EOS
cat > "${WORK}/mech_ok.sh" <<'EOS'
set -Eeuo pipefail
_m() { printf 'x'; }
V="$(_m arg)"
EOS
bash "${WORK}/mech_bad.sh" >/dev/null 2>&1; _mb=$?
bash "${WORK}/mech_ok.sh"  >/dev/null 2>&1; _mo=$?
if [ "$_mb" = 127 ] && [ "$_mo" = 0 ]; then
    ok "bash exits 127 when a call precedes its definition and 0 when it follows"
else
    echo "CANNOT-RUN: this shell gave ${_mb}/${_mo} for the call-before-def and" >&2
    echo "  def-before-call reductions, expected 127/0. The predicate this test" >&2
    echo "  relies on does not hold here, so its verdicts would be meaningless." >&2
    exit 2
fi

echo "── subject: this tree ──"

_r="$(_run "$SUBJECT" accepted)"
case "$_r" in
    NOSTMT*)      echo "CANNOT-RUN: the definition or the call was not found in ${SUBJECT}." >&2; exit 2 ;;
    "0|accepted") ok "the call resolves and returns the in-memory decision, so the install continues" ;;
    127\|*)       bad "the call still exits 127. The definition is below the line that calls it. This is the measured abort." ;;
    0\|*)         bad "the call resolved but returned '${_r#0|}', expected 'accepted'" ;;
    *)            bad "the call exits ${_r%%|*} -- the install aborts here" ;;
esac

# CONTROLS ON THE FUNCTION'S ANSWER. Without these, a change that replaced the
# body with `printf accepted` would pass the limb above. Three states, and the
# third is the one the file exists to protect: unknown is NOT declined.
_r="$(_run "$SUBJECT" declined)"
case "$_r" in
    "0|declined") ok "CONTROL: a declined decision is reported as declined" ;;
    *)            bad "CONTROL: declined gave ${_r}, expected 0|declined" ;;
esac

_r="$(_run "$SUBJECT" "")"
case "$_r" in
    "0|unknown")  ok "CONTROL: an empty decision with no durable registry reads as unknown, never as declined" ;;
    "0|declined") bad "CONTROL: an empty decision now reads as DECLINED. That silently switches consent-gated features off." ;;
    *)            bad "CONTROL: an empty decision gave ${_r}, expected 0|unknown" ;;
esac

# THE SECOND CALL SITE. It is below the definition today and is easy to move.
_defline="$(/usr/bin/grep -n '^_ostler_consent_state() {' "$SUBJECT" | head -1 | cut -d: -f1)"
_firstcall="$(/usr/bin/grep -n '\$(_ostler_consent_state ' "$SUBJECT" | head -1 | cut -d: -f1)"
_lastcall="$(/usr/bin/grep -n '\$(_ostler_consent_state ' "$SUBJECT" | tail -1 | cut -d: -f1)"
if [ -z "$_defline" ] || [ -z "$_firstcall" ]; then
    echo "CANNOT-RUN: could not locate the definition and its call sites by line." >&2
    exit 2
fi
if [ "$_defline" -lt "$_firstcall" ] && [ "$_defline" -lt "$_lastcall" ]; then
    ok "every call site (${_firstcall}, ${_lastcall}) sits below the definition (${_defline})"
else
    bad "a call site precedes the definition at line ${_defline}: first=${_firstcall} last=${_lastcall}"
fi

# ── NEGATIVE CONTROL, pinned to the cut whose walk measured the abort ────
# 7b2130ac is v1.0.65, the artefact that produced the rc=127 quoted above.
# Pinned to a fixed sha and never a branch: a control that read origin/main
# would invert the moment this fix merges and would then prove nothing.
_CONTROL_SHA="7b2130ac"
echo "── negative control: ${_CONTROL_SHA} (the cut whose walk aborted) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi

_r="$(_run "$_ctl" accepted)"
case "$_r" in
    NOSTMT*) echo "CANNOT-RUN: the statements were not found in the control blob." >&2; exit 2 ;;
    127\|*)  ok "control ${_CONTROL_SHA}: exits 127, reproducing the abort that ended walk 10 at step 21" ;;
    0\|*)    bad "control ${_CONTROL_SHA}: exits 0 there too. That tree DID abort on a real box, so this harness is not measuring the defect." ;;
    *)       bad "control ${_CONTROL_SHA}: exits ${_r%%|*}, expected 127" ;;
esac

# CONTROL ON THE CONTROL. The 127 above must be caused by ORDER and nothing
# else. Re-emit the SAME two statements from the SAME blob with the definition
# first; if that runs clean, order is the only difference between the trees.
_reordered="${WORK}/reordered.sh"
python3 - "$_ctl" > "$_reordered" <<'PY'
import re, sys
src = open(sys.argv[1]).read().split('\n')
ds = de = call = None
for i, l in enumerate(src):
    if ds is None and re.match(r'^_ostler_consent_state\(\)\s*\{', l):
        ds = i
        for j in range(i, len(src)):
            if src[j] == '}':
                de = j
                break
    if call is None and '$(_ostler_consent_state ' in l and not l.lstrip().startswith('#'):
        call = i
if ds is None or de is None or call is None:
    sys.exit(3)
print('\n'.join(src[ds:de+1]))   # definition first, deliberately
print(src[call])
PY
if [ ! -s "$_reordered" ]; then
    echo "CANNOT-RUN: could not re-emit the control's statements in the other order." >&2
    exit 2
fi
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'OSTLER_CONSENT_THIRD_PARTY_DECISION=accepted'
    cat "$_reordered"
    printf '%s\n' 'printf "%s" "$_OSTLER_CONSENT_TP_EMAIL"'
} > "${WORK}/reordered_run.sh"
_out="$(bash "${WORK}/reordered_run.sh" 2>/dev/null)"; _rc=$?
if [ "$_rc" = 0 ] && [ "$_out" = accepted ]; then
    ok "control ${_CONTROL_SHA} with the SAME statements reordered runs clean, so ORDER is the discriminator"
else
    bad "reordering the control's own statements still gives rc=${_rc} out='${_out}'. The 127 is not purely an ordering fault, so the fix may be incomplete."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
