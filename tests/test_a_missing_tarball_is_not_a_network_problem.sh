#!/usr/bin/env bash
# A missing installer tarball must not be reported as a flaky network.
#
# ============================================================================
# WHY, MEASURED. CM051 #1625.
# ============================================================================
# The curl|bash bootstrap fetches an installer tarball that has not been
# published since v0.3.0. The fetch loop retried that 404 three times with
# backoff and then printed:
#
#     ERROR: Could not download the installer tarball after 3 attempts.
#
# which is true of a missing asset AND of a broken network, names neither, and
# points the reader at their own connection either way. The reachability
# preflight immediately above has already proved github.com answers, so that
# wording contradicts a check the same script just ran.
#
# A 4xx is DEFINITIVE -- the server answered, and its answer was "no such
# thing". Retrying cannot change it.
#
# ============================================================================
# WHY THE HARNESS STUBS curl RATHER THAN SERVING A PORT
# ============================================================================
# A fixture listening on a port impersonates a service for everything else on
# a shared machine, and this project has already had one of mine become
# somebody else's unexplained responder. Nothing here binds anything: the
# extracted loop is executed with a `curl` FUNCTION that returns a chosen
# status. That also makes the arms deterministic, which a real 404 over the
# network is not.
#
# THE NEGATIVE CONTROL IS THE POINT. Every arm is run against the PRE-FIX
# blob from origin/main as well, and the pre-fix tree must FAIL the arms this
# change adds. Without that, a harness that silently measured nothing would
# report the same green.
#
# 0 pass  1 fail  2 cannot-run
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${1:-${HERE}/install.sh}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
cant() { printf '  [CANNOT-RUN] %s\n' "$1" >&2; echo "== ${PASS} pass / ${FAIL} fail / 1 cannot-run =="; exit 2; }

[ -f "$SUBJECT" ] || cant "no install.sh at ${SUBJECT}"
WORK="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "$WORK"' EXIT

# ── Extract the fetch loop and the failure block, by anchor, from whichever
#    tree we were handed. Both anchors are asserted: an extractor that
#    silently returns nothing would make every arm pass by running an empty
#    script, which is the zero-denominator failure this repo keeps finding.
_extract() { # _extract <file> -> the bootstrap fetch+report region
    awk '/^    fetch_ok=0$/{f=1} f{print} f && /^    fi$/ && seen {exit} f && /^    if \[\[ \$fetch_ok -eq 0 \]\]; then$/{seen=1}' "$1"
}

_drive() { # _drive <file> <http_code> -> the output the customer would see
    local file="$1" code="$2" body
    body="$(_extract "$file")"
    [ -n "$body" ] || { printf 'EXTRACT_FAILED'; return; }
    {
        printf '%s\n' 'BOOTSTRAP_TMPDIR="$(mktemp -d)"'
        printf '%s\n' 'INSTALLER_TARBALL_URL="https://example.invalid/install.tar.gz"'
        printf '%s\n' 'sleep() { :; }          # never actually wait in a test'
        printf '%s\n' 'exit() { printf "EXIT:%s\n" "${1:-0}"; return 0; }'
        # The stub records each invocation so an arm can count ATTEMPTS, which
        # is the property that distinguishes "did not retry" from "retried and
        # happened to stop".
        printf 'curl() { echo x >> "%s/attempts"; printf %s "%s"; return 22; }\n' "$WORK" '%s' "$code"
        printf '%s\n' "$body"
    } > "${WORK}/drive.sh"
    : > "${WORK}/attempts"
    bash "${WORK}/drive.sh" 2>&1
}

_attempts() { wc -l < "${WORK}/attempts" | tr -d ' '; }

echo "── subject: ${SUBJECT} ──"

# ── arm 1: a 404 is not retried ─────────────────────────────────────────────
out="$(_drive "$SUBJECT" 404)"
case "$out" in
    EXTRACT_FAILED) cant "could not extract the bootstrap fetch region from ${SUBJECT}; refusing to report on an empty script" ;;
esac
n="$(_attempts)"
if [ "$n" -eq 1 ]; then ok "a 404 is fetched ONCE, not retried (attempts=${n})"
else bad "a 404 was attempted ${n} time(s). A definitive answer must not be retried."; fi

# ── arm 2: the message names a missing asset, not a network problem ─────────
case "$out" in
    *"no installer tarball at that URL"*) ok "the 404 message leads with the asset being absent" ;;
    *) bad "the 404 message does not say the asset is absent. It said: $(printf '%s' "$out" | grep -m1 '^ERROR' || echo '(no ERROR line)')" ;;
esac
case "$out" in
    *"after 3 attempts"*) bad "the 404 message still blames 3 failed attempts, which is the wording #1625 is about" ;;
    *) ok "the 404 message does NOT claim three failed attempts" ;;
esac
case "$out" in
    *"Your network is fine"*) ok "the 404 message explicitly clears the reader's network" ;;
    *) bad "the 404 message does not clear the reader's network, so it still reads as a connectivity fault" ;;
esac

# ── arm 3: a 5xx IS still retried. The fix must narrow, not disable. ────────
out5="$(_drive "$SUBJECT" 503)"
n5="$(_attempts)"
if [ "$n5" -eq 3 ]; then ok "CONTROL: a 503 is still retried 3 times, so the change narrowed the behaviour rather than removing it"
else bad "a 503 was attempted ${n5} time(s), expected 3. Transient failures must still retry."; fi
case "$out5" in
    *"after 3 attempts"*) ok "CONTROL: a 5xx still gets the transient-failure wording" ;;
    *) bad "a 5xx no longer reports as a transient failure" ;;
esac

# ── arm 4: NEGATIVE CONTROL against the pre-fix tree ────────────────────────
# Pinned to origin/main's blob at the time this test was written, NOT to a
# branch: a control that reads a moving ref inverts the moment this merges.
echo "── negative control: the pre-fix blob ──"
CTL="${WORK}/pre.sh"
if ! git -C "$HERE" show "${OSTLER_PREFIX_REF:-origin/main}:install.sh" > "$CTL" 2>/dev/null; then
    cant "could not read the pre-fix install.sh blob; a control that scanned nothing must not read as a pass"
fi
if grep -q 'no installer tarball at that URL' "$CTL"; then
    cant "the 'pre-fix' blob ALREADY carries this fix, so it cannot discriminate. Re-point OSTLER_PREFIX_REF at a tree that predates it."
fi
octl="$(_drive "$CTL" 404)"
nctl="$(_attempts)"
case "$octl" in
    EXTRACT_FAILED) cant "could not extract the fetch region from the control blob" ;;
esac
if [ "$nctl" -eq 3 ]; then ok "CONTROL: the pre-fix tree retries a 404 three times -- the defect reproduces"
else bad "the pre-fix tree attempted a 404 ${nctl} time(s), expected 3. This harness is not measuring the change."; fi
case "$octl" in
    *"after 3 attempts"*) ok "CONTROL: the pre-fix tree blames 3 attempts for a missing asset -- the wording #1625 reported" ;;
    *) bad "the pre-fix tree did not produce the wording this fix replaces; the control proves nothing" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / 0 cannot-run =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
