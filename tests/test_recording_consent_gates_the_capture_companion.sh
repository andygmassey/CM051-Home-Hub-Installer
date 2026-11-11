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
# WHAT THE CUSTOMER GETS, PER ANSWER (updated 2026-11-11, Andy)
# ============================================================================
#
# Every answer stages the app. What the answer controls is WHERE the LaunchAgent
# plist lands, and so whether anything starts at login:
#
#   accepted   staged, LaunchAgent live in ~/Library/LaunchAgents, bootstrapped
#   declined   staged, plist DISABLED beside the app, nothing live, told it stays off
#   unknown    staged, plist DISABLED beside the app, nothing live, told it is waiting
#
# The earlier version of this file asserted that a declined answer fetches
# nothing. That was the complaint: a customer who said "not now" had no app, and
# turning transcription on later said "run the installer again". Those
# assertions encode the defect and have been replaced, not weakened.
#
# WHY THIS TEST EXECUTES THE PHASE AND DOES NOT PATTERN-MATCH IT. Both trees
# contain the consent screen, the record and the phase; only what the phase
# DOES with each answer differs. So this extracts the real phase, runs it with
# every external command stubbed, and asserts on what lands on disk and what
# launchctl is told.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
[ -f "$STRINGS" ] || { echo "CANNOT-RUN: no string catalogue at ${STRINGS}" >&2; exit 2; }
# The assertions below compare against the catalogue's own words, so load it here too.
. "$STRINGS"
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
# Echoes, pipe-separated:
#   rc | fetched | app-staged | live-plist | staged-plist | booted-out | loaded | stdout digest
_run_arm() {
    local subject="$1" state="$2" prior="${3:-}" body r="${WORK}/arm"
    rm -rf "$r"; mkdir -p "$r/box/Library/LaunchAgents" "$r/box/Library/Application Support/Ostler RemoteCapture" "$r/apps" "$r/logs"
    body="$(_extract_phase "$subject")" || { printf 'NOPHASE|||||||'; return; }
    [ -n "$body" ] || { printf 'NOPHASE|||||||'; return; }
    # The phase hard-codes /Applications (its apps dir, tar -C, the relocate
    # and mv of legacy bundles). Re-root EVERY such path into this arm's sandbox,
    # so a test run can never write to or move anything in the real /Applications.
    # (Measured 2026-11-11: an unsandboxed run created /Applications/Ostler.)
    body="${body//\/Applications/${r}/apps}"

    local live="${r}/box/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist"
    if [ "$prior" = prior ]; then
        printf '%s\n' "<plist>left by an earlier run</plist>" > "$live"
    fi

    {
        printf '%s\n' 'set -Eeuo pipefail'
        # The REAL catalogue. A message the fix forgot to add would be an
        # unbound variable here, not a blank line on a customer's screen.
        printf 'source %q\n' "$STRINGS"
        printf 'HOME=%q\n' "${r}/box"
        printf 'LOGS_DIR=%q\n' "${r}/logs"
        printf 'OSTLER_APPS_DIR=%q\n' "${r}/apps/Ostler"
        printf 'OSTLER_CODESIGN_REQ=%q\n' 'anchor apple generic'
        printf 'OSTLER_REMOTECAPTURE_VERSION=%q\n' '0.1.10'
        # Pin the one digest the stub produces, so the real verify runs.
        printf 'OSTLER_REMOTECAPTURE_SHA256=%q\n' 'deadbeef'
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
_ostler_launchagent_load_verified() { printf 'LOADED %s\n' "$1"; touch "${MARKER_DIR}/loaded"; return 0; }
# Externals. The download succeeds and writes what the real one would: an
# archive and a sidecar that agrees with the pin. The archive then extracts to
# a bundle, so the install is measured as far as the LaunchAgent decision.
curl() {
    : > "${MARKER_DIR}/curl-called"
    local a prev=""
    for a in "$@"; do
        if [ "$prev" = "-o" ]; then
            case "$a" in
                *.sha256) printf 'deadbeef  x\n' > "$a" ;;
                *)        printf 'archive\n' > "$a" ;;
            esac
        fi
        prev="$a"
    done
    return 0
}
tar() {
    # The real command extracts into /Applications; the stub writes the bundle
    # into this arm's apps folder instead.
    mkdir -p "${OSTLER_APPS_DIR}/Ostler RemoteCapture.app/Contents/MacOS"
    : > "${OSTLER_APPS_DIR}/Ostler RemoteCapture.app/Contents/MacOS/RemoteCapture"
    return 0
}
launchctl() { printf '%s\n' "$*" >> "${MARKER_DIR}/launchctl-calls"; return 0; }
codesign() { return 0; }
spctl() { return 0; }
xattr() { return 0; }
shasum() { printf 'deadbeef  %s\n' "${2:-x}"; }
sudo() { return 1; }
# uname must still answer honestly for the architecture branch; on a non-arm64
# runner the arm would take the Apple Silicon skip and prove nothing.
uname() { printf 'arm64\n'; }
STUBS
        printf '%s\n' "$body"
    } > "${r}/run.sh"

    local out rc
    out="$(bash "${r}/run.sh" 2>&1)"; rc=$?
    local fetched=no app=no livep=no stagedp=no booted=no loaded=no appstaged=no
    [ -f "${r}/curl-called" ] && fetched=yes
    [ -f "${r}/apps/Ostler/Ostler RemoteCapture.app/Contents/MacOS/RemoteCapture" ] && app=yes
    [ -f "${r}/box/Library/Application Support/Ostler/staged/Ostler RemoteCapture.app/Contents/MacOS/RemoteCapture" ] && appstaged=yes
    [ -f "$live" ] && livep=yes
    [ -f "${r}/box/Library/Application Support/Ostler RemoteCapture/com.creativemachines.ostler-remotecapture.plist.staged" ] && stagedp=yes
    if [ -f "${r}/launchctl-calls" ] && /usr/bin/grep -q 'bootout' "${r}/launchctl-calls"; then booted=yes; fi
    [ -f "${r}/loaded" ] && loaded=yes
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' "$rc" "$fetched" "$app" "$livep" "$stagedp" "$booted" "$loaded" "$appstaged" "$(printf '%s' "$out" | tr '\n' ';')"
}
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
digest() { printf '%s' "$1" | cut -d'|' -f9-; }

# ── the harness must be able to tell the outcomes apart ─────────────────────
echo "── the mechanism, so the predicate is not taken on trust ──"
_probe="$(_run_arm "$SUBJECT" accepted)"
case "$_probe" in
    NOPHASE*) echo "CANNOT-RUN: the RemoteCapture phase was not found in ${SUBJECT}." >&2
              echo "  Its boundary lines have moved or been renamed. NOTHING was measured." >&2
              exit 2 ;;
esac
if [ "$(field "$_probe" 3)" = yes ]; then
    ok "the harness can observe a staged app (accepted installs the bundle)"
else
    echo "CANNOT-RUN: the accepted arm did not stage the bundle, so this harness cannot" >&2
    echo "  tell an install that ran from one that refused. Every verdict below would be unearned." >&2
    echo "  rc=$(field "$_probe" 1) out=$(digest "$_probe")" >&2
    exit 2
fi

echo "── consumer-side: what each answer actually does ──"

# ACCEPTED: the customer asked for this. Live agent, loaded.
_r="$(_run_arm "$SUBJECT" accepted)"
if [ "$(field "$_r" 4)" = yes ] && [ "$(field "$_r" 7)" = yes ] && [ "$(field "$_r" 3)" = yes ] && [ "$(field "$_r" 8)" = no ]; then
    ok "accepted: the app is in /Applications, the LaunchAgent is live in LaunchAgents and loaded, as the customer asked"
else
    bad "accepted: the agent was not made live (live=$(field "$_r" 4) loaded=$(field "$_r" 7)). A yes that does nothing is a closed hole."
fi

# DECLINED: the app is PARKED outside /Applications; nothing is live; the customer is told it stays off.
_r="$(_run_arm "$SUBJECT" declined)"
if [ "$(field "$_r" 3)" = no ] && [ "$(field "$_r" 8)" = yes ]; then
    ok "declined: the app is parked in staged/, NOT in /Applications, and enable can bring it back with no reinstall"
else
    bad "declined: app in /Applications=$(field "$_r" 3) parked=$(field "$_r" 8). A declined app must not sit where a customer can open it."
fi
if [ "$(field "$_r" 4)" = no ] && [ "$(field "$_r" 7)" = no ]; then
    ok "declined: nothing is live in LaunchAgents and nothing is loaded, so nothing captures or starts at login"
else
    bad "declined: an agent is live or loaded (live=$(field "$_r" 4) loaded=$(field "$_r" 7)). Transcription was declined."
fi
if [ "$(field "$_r" 5)" = yes ]; then
    ok "declined: the disabled plist is staged beside the app, ready for an in-place enable"
else
    bad "declined: no staged plist, so there is nothing to enable later"
fi
case "$(digest "$_r")" in
    *"$(printf '%s' "${MSG_INFO_CM042_STAGED_TRANSCRIPTION_OFF:-__unset__}" | cut -c1-40)"*)
        ok "declined: the customer is told it stays off, in the catalogue's own words" ;;
    *)  bad "declined: the phase went quiet. Silence and 'it does not exist' look identical to a customer." ;;
esac

# UNKNOWN: nobody was asked, or the answer was lost. Same placement as declined,
# but the customer is told it is waiting, not refused.
_r="$(_run_arm "$SUBJECT" unknown)"
if [ "$(field "$_r" 4)" = no ] && [ "$(field "$_r" 7)" = no ] && [ "$(field "$_r" 5)" = yes ] && [ "$(field "$_r" 3)" = no ] && [ "$(field "$_r" 8)" = yes ]; then
    ok "unknown: parked outside /Applications, staged plist disabled, nothing live (off is the safe posture for an unanswered recording question)"
else
    bad "unknown: not staged disabled with nothing live (staged=$(field "$_r" 5) live=$(field "$_r" 4) loaded=$(field "$_r" 7))"
fi
case "$(digest "$_r")" in
    *WARN-UNKNOWN*spoken_capture_recording_consent*)
        ok "unknown: it SAYS the step is waiting for an answer, not that consent was refused" ;;
    *)  bad "unknown was treated as declined in silence. Those are different facts with different next actions." ;;
esac

# A PRIOR RUN'S AGENT. Answering yes once and no later must not leave the
# companion starting at every login.
_r="$(_run_arm "$SUBJECT" declined prior)"
if [ "$(field "$_r" 4)" = no ] && [ "$(field "$_r" 6)" = yes ] && [ "$(field "$_r" 5)" = yes ]; then
    ok "declined after a previous yes: the live agent is booted out and removed, and the staged copy stays"
else
    bad "declined after a previous yes: not cleaned up (live=$(field "$_r" 4) booted=$(field "$_r" 6) staged=$(field "$_r" 5))"
fi

# ── MUTATION A: put the defect back ─────────────────────────────────────────
# Place the plist LIVE regardless of the answer. A declined customer's agent
# then starts at every login. The live-plist assertion must catch it.
echo "── mutation A: placement ignores the answer ──"
_mut="${WORK}/mutantA.sh"
python3 - "$SUBJECT" > "$_mut" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '[[ "$_OSTLER_CONSENT_SPOKEN_CAPTURE" == "accepted" ]] && REMOTECAPTURE_PLIST_TARGET="$REMOTECAPTURE_LAUNCHAGENT_PLIST"'
if src.count(needle) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(needle, 'REMOTECAPTURE_PLIST_TARGET="$REMOTECAPTURE_LAUNCHAGENT_PLIST"', 1))
PY
if [ ! -s "$_mut" ]; then
    echo "CANNOT-RUN: could not build mutant A -- the placement line did not match." >&2
    echo "  A mutation that did not apply looks exactly like one that was not caught." >&2
    exit 2
fi
if ! bash -n "$_mut" 2>/dev/null; then
    echo "CANNOT-RUN: mutant A does not parse, so it is not the pre-fix tree." >&2
    exit 2
fi
_r="$(_run_arm "$_mut" declined)"
if [ "$(field "$_r" 4)" = yes ]; then
    ok "MUTATION A: a declined answer places a live agent -- the guard fires"
else
    bad "MUTATION A: the mutant ALSO kept the declined agent off. This test is not measuring the placement."
fi

# ── MUTATION C: never park the app, so a declined app stays in /Applications ─
echo "── mutation C: the verified app is never parked ──"
_mutc="${WORK}/mutantC.sh"
python3 - "$SUBJECT" > "$_mutc" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'REMOTECAPTURE_INSTALLED=true; _ostler_remotecapture_park'
if src.count(needle) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(needle, 'REMOTECAPTURE_INSTALLED=true', 1))
PY
if [ ! -s "$_mutc" ] || ! bash -n "$_mutc" 2>/dev/null; then
    echo "CANNOT-RUN: mutant C did not build or parse; nothing was measured." >&2
    exit 2
fi
_r="$(_run_arm "$_mutc" declined)"
if [ "$(field "$_r" 3)" = yes ]; then
    ok "MUTATION C: without the park, a declined app sits in /Applications -- the placement guard fires"
else
    bad "MUTATION C: the mutant ALSO kept the declined app out of /Applications. The placement assertion is not measuring the park."
fi

# ── MUTATION B: blind the scanner ───────────────────────────────────────────
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
