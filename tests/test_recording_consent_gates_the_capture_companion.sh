#!/usr/bin/env bash
# A RECORDING CONSENT THAT REFUSES NOTHING IS NOT A CONSENT (HR015 #940).
#
# ============================================================================
# WHAT WAS MEASURED, ON CM051 origin/main e0fb21bf, 2026-09-16
# ============================================================================
#
# The spoken-capture recording consent was built end to end EXCEPT the half
# that matters. /usr/bin/grep over the whole tree, binary files excluded:
#
#   spoken_capture_recording_consent
#     wording      vendor/legal/consent_strings.py:226
#     screen       install.sh 10893-10932   (default seeded "n", opt-in)
#     recorded     install.sh 15746-15755   (consent_cli record)
#     REFUSED      0 sites, anywhere in the repo
#
# The only reader of a durable consent record in install.sh is
# _ostler_consent_state, and BOTH its call sites named
# third_party_data_personal_records. CONTROL, same shape, same predicate:
# that tickbox returns 2 call sites, so the search can find one and the zero
# is a real absence rather than a broken pattern. (The call sites pass the
# tickbox UNQUOTED. A pattern that expects a quote after the function name
# finds nothing and would have reported a false absence for BOTH.)
#
# So a customer who answered "no" -- or clicked straight through, which is the
# same answer, since the default is "n" -- was told "Spoken transcription will
# stay off" and then had the call/meeting transcription companion downloaded,
# staged into /Applications, quarantine-cleared, and bootstrapped as a
# LaunchAgent with RunAtLoad and KeepAlive both true. They were also
# pre-prompted to grant macOS Screen Recording and Microphone permission.
#
# HR015 #940 prices its own priority on the premise that "transcription is OFF
# BY DEFAULT and opt-in ... a user who clicks straight through records
# nobody". That premise did not hold on this tree.
#
# ============================================================================
# WHY THIS TEST EXECUTES THE PHASE AND DOES NOT PATTERN-MATCH IT
# ============================================================================
#
# The defect is not a missing string. Both the broken and the fixed tree
# contain the consent screen, the record, and the whole RemoteCapture phase;
# only whether the phase RUNS differs. No pattern over either half can tell
# them apart, and a test asserting "the gate is present" would pass against a
# gate wired to a variable nothing sets.
#
# So this extracts the real phase out of install.sh, runs it with every
# external command stubbed, and asserts on the EFFECTS a customer would get:
#
#   did the installer try to fetch the bundle   (curl called)
#   did a LaunchAgent plist get written         (file on disk)
#   did a prior run's LaunchAgent get removed   (file gone + bootout called)
#
# The stubs return failure where the real commands would touch the network,
# which is why the accepted arm asserts "it tried", not "it succeeded". Trying
# is the whole difference: on the declined arm it must not try at all.
#
# ============================================================================
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
[ -f "$STRINGS" ] || { echo "CANNOT-RUN: no string catalogue at ${STRINGS}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── extract the phase ───────────────────────────────────────────────────────
# From the phase's own `progress` line to the line that closes the Apple
# Silicon guard, so the extracted region carries the version/path variables
# the body reads as well as the gate itself. Prints nothing and exits 3 if
# either boundary is absent, so a renamed anchor becomes CANNOT-RUN and never
# a silent pass.
_extract_phase() {
    python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
start = end = None
for i, l in enumerate(lines):
    if start is None and l.startswith('progress "Setting up Ostler RemoteCapture'):
        start = i
    if start is not None and l.startswith('fi  # end RemoteCapture Apple Silicon guard'):
        end = i
        break
if start is None or end is None:
    sys.exit(3)
print('\n'.join(lines[start:end + 1]))
PY
}

# ── run one arm ─────────────────────────────────────────────────────────────
# $1 subject file, $2 the consent state the spine will report,
# $3 "prior" to pre-create a LaunchAgent plist from an earlier run.
# Echoes "<rc>|<curl-called>|<plist-present>|<bootout-called>|<stdout digest>".
_run_arm() {
    local subject="$1" state="$2" prior="${3:-}" body r="${WORK}/arm"
    rm -rf "$r"; mkdir -p "$r/box/Library/LaunchAgents" "$r/apps" "$r/logs"
    body="$(_extract_phase "$subject")" || { printf 'NOPHASE||||'; return; }
    [ -n "$body" ] || { printf 'NOPHASE||||'; return; }

    local plist="${r}/box/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist"
    if [ "$prior" = prior ]; then
        printf '%s\n' "<plist>left by an earlier run</plist>" > "$plist"
    fi

    {
        printf '%s\n' 'set -Eeuo pipefail'
        # The REAL catalogue. A message the fix forgot to add would be an
        # unbound variable here, not a blank line on a customer's screen.
        printf 'source %q\n' "$STRINGS"
        printf 'HOME=%q\n' "${r}/box"
        printf 'LOGS_DIR=%q\n' "${r}/logs"
        printf 'OSTLER_CODESIGN_REQ=%q\n' 'anchor apple generic'
        printf 'OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION=""\n'
        printf 'REMOTECAPTURE_INSTALLED=false\n'
        printf '_STATE=%q\n' "$state"
        printf 'MARKER_DIR=%q\n' "$r"
        cat <<'STUBS'
# The spine, stubbed to the state under test. The real function is exercised
# by tests/test_consent_state_is_defined_before_it_is_called.sh; what THIS
# file measures is what the phase does with each of its three answers.
_ostler_consent_state() { printf '%s' "$_STATE"; }
_ostler_warn_consent_unknown() { printf 'WARN-UNKNOWN %s %s\n' "$1" "$2"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
err()  { printf 'ERR %s\n' "$*"; }
ok()   { printf 'OK %s\n' "$*"; }
progress() { printf 'PROGRESS %s\n' "$2"; }
fail_with_code() { printf 'FAILCODE %s\n' "$1"; exit 9; }
_ostler_launchagent_load_verified() { printf 'LOADED %s\n' "$1"; return 0; }
# Externals. curl is the discriminator: reaching it means the installer set
# out to stage the capture companion.
curl() { : > "${MARKER_DIR}/curl-called"; return 22; }
launchctl() { printf '%s\n' "$*" >> "${MARKER_DIR}/launchctl-calls"; return 0; }
tar() { return 1; }
codesign() { return 1; }
spctl() { return 1; }
xattr() { return 0; }
shasum() { printf 'deadbeef  x\n'; }
sudo() { return 1; }
# uname must still answer honestly for the architecture branch; on a non-arm64
# runner the accepted arm would take the Apple Silicon skip and prove nothing,
# so force the branch the customer Macs take.
uname() { printf 'arm64\n'; }
STUBS
        printf '%s\n' "$body"
    } > "${r}/run.sh"

    local out rc
    out="$(bash "${r}/run.sh" 2>&1)"; rc=$?
    local curled=no plistp=no booted=no
    [ -f "${r}/curl-called" ] && curled=yes
    [ -f "$plist" ] && plistp=yes
    if [ -f "${r}/launchctl-calls" ] && /usr/bin/grep -q 'bootout' "${r}/launchctl-calls"; then
        booted=yes
    fi
    printf '%s|%s|%s|%s|%s' "$rc" "$curled" "$plistp" "$booted" "$(printf '%s' "$out" | tr '\n' ';')"
}

# ── the harness must be able to tell the two outcomes apart ─────────────────
# Without this, a stub that never fired would report every arm as "did not
# stage" and the whole file would read green for the wrong reason.
echo "── the mechanism, so the predicate is not taken on trust ──"
_probe="$(_run_arm "$SUBJECT" accepted)"
case "$_probe" in
    NOPHASE*) echo "CANNOT-RUN: the RemoteCapture phase was not found in ${SUBJECT}." >&2
              echo "  Its boundary lines have moved or been renamed. NOTHING was measured." >&2
              exit 2 ;;
esac
if [ "$(printf '%s' "$_probe" | cut -d'|' -f2)" = yes ]; then
    ok "the harness can observe a staging attempt (accepted reaches curl)"
else
    echo "CANNOT-RUN: the accepted arm did not reach curl, so this harness cannot" >&2
    echo "  distinguish a phase that ran from one that refused. Every 'did not" >&2
    echo "  stage' verdict below would be unearned." >&2
    exit 2
fi

echo "── consumer-side: what each answer actually does ──"

# ACCEPTED: the customer asked for this. It must proceed.
_r="$(_run_arm "$SUBJECT" accepted)"
if [ "$(printf '%s' "$_r" | cut -d'|' -f2)" = yes ]; then
    ok "accepted: the capture companion is staged, as the customer asked"
else
    bad "accepted: the phase refused a customer who said yes. That is a closed hole, not a feature."
fi

# DECLINED: the screen promised transcription would stay off.
_r="$(_run_arm "$SUBJECT" declined)"
_curl="$(printf '%s' "$_r" | cut -d'|' -f2)"
_plist="$(printf '%s' "$_r" | cut -d'|' -f3)"
_out="$(printf '%s' "$_r" | cut -d'|' -f5-)"
if [ "$_curl" = no ]; then
    ok "declined: nothing is fetched, so no capture companion is staged"
else
    bad "declined: the installer still fetched the capture companion. The screen said transcription would stay off."
fi
if [ "$_plist" = no ]; then
    ok "declined: no LaunchAgent is written, so nothing starts at login"
else
    bad "declined: a RunAtLoad LaunchAgent was written anyway"
fi
case "$_out" in
    *"$(printf '%s' "${MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF:-__unset__}" | cut -c1-40)"*|*"not installed"*)
        ok "declined: the customer is told why, in their own answer's terms" ;;
    *)  bad "declined: the phase went quiet. Silence and 'it does not exist' look identical to a customer." ;;
esac

# UNKNOWN: nobody was ever asked, or the answer was lost. Not the same fact as
# a refusal, and the installer's own doctrine says it may not be treated as
# one in silence.
_r="$(_run_arm "$SUBJECT" unknown)"
if [ "$(printf '%s' "$_r" | cut -d'|' -f2)" = no ]; then
    ok "unknown: nothing is staged (off is the safe posture for an unanswered recording question)"
else
    bad "unknown: the installer staged the capture companion against an answer nobody gave"
fi
case "$(printf '%s' "$_r" | cut -d'|' -f5-)" in
    *WARN-UNKNOWN*spoken_capture_recording_consent*)
        ok "unknown: it SAYS the step was skipped for want of an answer, not for want of consent" ;;
    *)  bad "unknown was treated as declined in silence. Those are different facts with different next actions." ;;
esac

# A PRIOR RUN'S AGENT. Answering yes once and no later must not leave the
# companion starting at every login.
_r="$(_run_arm "$SUBJECT" declined prior)"
if [ "$(printf '%s' "$_r" | cut -d'|' -f3)" = no ] && [ "$(printf '%s' "$_r" | cut -d'|' -f4)" = yes ]; then
    ok "declined after a previous yes: the old LaunchAgent is booted out and removed"
else
    bad "declined after a previous yes: the old LaunchAgent survives (plist=$(printf '%s' "$_r" | cut -d'|' -f3) bootout=$(printf '%s' "$_r" | cut -d'|' -f4))"
fi

# ── MUTATION A: put the defect back ─────────────────────────────────────────
# Collapse the gate to the pre-fix shape -- the architecture test alone -- and
# the declined arm must stage again. A guard nobody has watched fail proves
# nothing.
echo "── mutation A: the defect reintroduced ──"
_mut="${WORK}/mutant.sh"
python3 - "$SUBJECT" > "$_mut" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
gate = re.search(
    r'_OSTLER_CONSENT_SPOKEN_CAPTURE="\$\(_ostler_consent_state.*?\nelif \[\[ "\$REMOTECAPTURE_ARCH_DETECTED"',
    src, re.S)
if gate is None:
    sys.exit(3)
src = src.replace(gate.group(0), 'if [[ "$REMOTECAPTURE_ARCH_DETECTED"', 1)
sys.stdout.write(src)
PY
if [ ! -s "$_mut" ]; then
    echo "CANNOT-RUN: could not build the mutant -- the gate's shape did not match." >&2
    echo "  A mutation that did not apply looks exactly like one that was not caught." >&2
    exit 2
fi
if ! bash -n "$_mut" 2>/dev/null; then
    echo "CANNOT-RUN: the mutant does not parse, so it is not the pre-fix tree." >&2
    exit 2
fi
_r="$(_run_arm "$_mut" declined)"
if [ "$(printf '%s' "$_r" | cut -d'|' -f2)" = yes ]; then
    ok "MUTATION A: without the gate, a declined customer is staged the companion -- the guard fires"
else
    bad "MUTATION A: the mutant ALSO refused. This test is not measuring the gate."
fi

# ── MUTATION B: blind the scanner ───────────────────────────────────────────
# Hand the extractor a file with no phase in it. It must report CANNOT-RUN,
# never a pass: scanning nothing is not evidence of anything.
echo "── mutation B: the scanner blinded ──"
printf '%s\n' '# a file with no RemoteCapture phase at all' > "${WORK}/blind.sh"
_r="$(_run_arm "${WORK}/blind.sh" declined)"
case "$_r" in
    NOPHASE*) ok "MUTATION B: an unreadable subject reports NOPHASE, which the harness turns into CANNOT-RUN" ;;
    *)        bad "MUTATION B: a subject with no phase in it produced a verdict (${_r}). A zero denominator read as success." ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
