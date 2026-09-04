#!/usr/bin/env bash
# A cancellation THIS HARNESS caused is CANNOT-RUN, not a verdict on the build.
#
# WHY THIS EXISTS. MEASURED 2026-09-04, walk 3 of v1.0.65 on a cold account.
# The run ended:
#
#     #OSTLER  DONE  status=cancelled
#     WALK FAIL: install.sh terminated with status=cancelled (rc=0)
#
# Nothing about the build was wrong. The driver's answer table falls open to
# the installer's own default on any prompt it does not recognise, and one of
# those defaults CANCELS: the third-party consent ships "[n]", where n means
# "I do not consent" and removes the installer. So a stale table produces a
# clean, correct, customer-facing cancellation, which this driver then
# reported as a product failure.
#
# THE DEFAULT ITSELF IS RIGHT AND IS NOT WHAT THIS FIXES. Consent must be
# affirmative; a default of yes would manufacture consent nobody gave. The
# defect is entirely in the adjudication.
#
# THE DISCRIMINATOR IS WHETHER WE ANSWERED EVERYTHING WE WERE ASKED:
#
#   every prompt matched, still cancelled  -> the product's own decision, FAIL
#   any prompt unmatched                   -> we cannot attribute it, CANNOT-RUN
#
# walk_drive.py's own docstring already states the principle for the
# marker-channel case -- "Calling this FAIL would accuse the product of our
# own blindness" -- and simply did not apply it here.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="${REPO}/scripts/walk_drive.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$DRIVER" ] || { echo "CANNOT-RUN: no walk_drive.py at ${DRIVER}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── Drive adjudicate() directly, with HOME pointed at a fixture ──────────
# HOME is read at import time, so each case gets its own home and its own
# Q&A record. Executed, not grepped: the property is an exit CODE, and 1 and
# 2 are indistinguishable to any pattern over the source.
#
# Args: <marker line> <qa mode: none|clean|unmatched|unreadable>
# Echoes: "<code>|<headline>"
_adjudicate() {
    local marker="$1" qamode="$2" h="${WORK}/h"; rm -rf "$h"; mkdir -p "$h"
    printf '%s\n' "$marker" > "${h}/pty.log"
    case "$qamode" in
        clean)
            printf 'utc\tprompt\tanswer\n' > "${h}/.walk-qa.tsv"
            printf '2026-09-04T00:00:00Z\tUse this timezone?:\ty\n' >> "${h}/.walk-qa.tsv"
            ;;
        unmatched)
            printf 'utc\tprompt\tanswer\n' > "${h}/.walk-qa.tsv"
            printf '2026-09-04T00:00:00Z\tUse this timezone?:\ty\n' >> "${h}/.walk-qa.tsv"
            printf '2026-09-04T00:00:01Z\tOne last thing: how third-party data works [n]:\t<ENTER (UNMATCHED, took installer default)>\n' >> "${h}/.walk-qa.tsv"
            ;;
        unreadable)
            # A DIRECTORY where the record should be: open() raises IOError,
            # which is the "could not look" arm and must not read as "none".
            mkdir -p "${h}/.walk-qa.tsv"
            ;;
        none) : ;;
    esac
    HOME="$h" python3 - "$DRIVER" "${h}/pty.log" <<'PY' 2>/dev/null
import sys, importlib.util
spec = importlib.util.spec_from_file_location("wd", sys.argv[1])
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)
code, headline, _detail = wd.adjudicate(sys.argv[2], 0, True)
print("%d|%s" % (code, headline))
PY
}

echo "── the cancel arm ──"

_r="$(_adjudicate '#OSTLER	DONE	status=cancelled' unmatched)"
case "$_r" in
    2\|*) ok "cancelled WITH an unmatched prompt -> CANNOT-RUN (${_r%%|*}), so a harness gap is not a build verdict" ;;
    1\|*) bad "cancelled with an unmatched prompt still reports FAIL. That is the measured defect: it accuses the product of our own stale table." ;;
    *)    bad "unexpected result for cancelled+unmatched: ${_r}" ;;
esac

_r="$(_adjudicate '#OSTLER	DONE	status=cancelled' clean)"
case "$_r" in
    1\|*) ok "cancelled with EVERY prompt matched -> FAIL (${_r%%|*}), because then it IS the product's own decision" ;;
    2\|*) bad "cancelled with every prompt matched reports CANNOT-RUN. The guard is too wide: a real cancellation would now be unreportable." ;;
    *)    bad "unexpected result for cancelled+clean: ${_r}" ;;
esac

_r="$(_adjudicate '#OSTLER	DONE	status=cancelled' unreadable)"
case "$_r" in
    2\|*) ok "cancelled with an UNREADABLE Q&A record -> CANNOT-RUN, because not knowing is not a failure" ;;
    *)    bad "an unreadable Q&A record gave ${_r}. 'Could not look' and 'there were none' are different findings." ;;
esac

echo "── CONTROLS: the other verdicts must be unchanged ──"

# Without these, a change that returned CANNOT-RUN for EVERYTHING would pass
# every limb above. This is what makes them measurements.
_r="$(_adjudicate '#OSTLER	DONE	status=fail	failed_steps=1' unmatched)"
case "$_r" in
    1\|*) ok "CONTROL: status=fail is still FAIL even with unmatched prompts, so only the cancel arm changed" ;;
    *)    bad "CONTROL FAILED: status=fail now gives ${_r}. A real failure has been softened into a harness excuse." ;;
esac

_r="$(_adjudicate '#OSTLER	DONE	status=ok	failed_steps=0	errors=0' clean)"
case "$_r" in
    0\|*) ok "CONTROL: a clean completion is still PASS" ;;
    *)    bad "CONTROL FAILED: a clean completion now gives ${_r}" ;;
esac

echo "── the table entry that made this run cancel ──"

# The fix is only half done if the driver still cannot answer the prompt. The
# needle must be a SUBSTRING OF THE REAL TITLE, so this compares against the
# shipped string rather than against itself.
_title="$(/usr/bin/grep -oE 'MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="[^"]*"' "${REPO}/install.sh.strings.en-GB.sh" 2>/dev/null | head -1)"
_needle='how third-party data works'
if /usr/bin/grep -qF "$_needle" "$DRIVER"; then
    ok "the driver carries a needle for the third-party consent prompt"
else
    bad "the driver has no needle for the third-party consent prompt; the next walk cancels again"
fi
if [ -n "$_title" ]; then
    case "$_title" in
        *"$_needle"*) ok "and the needle is a substring of the SHIPPED prompt title, not of itself" ;;
        *)            bad "the needle '${_needle}' does not appear in the shipped title. It would never match." ;;
    esac
else
    echo "CANNOT-RUN: could not read the third-party prompt title from the strings file." >&2
    echo "  The needle cannot be checked against the string it has to match." >&2
    exit 2
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
