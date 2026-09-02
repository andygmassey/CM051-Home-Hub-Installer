#!/usr/bin/env bash
#
# B2 (cuts/v1.0.60/SCOPE.md): the spoken/voice feed is presence-gated on
# ~/Documents/Ostler/Transcripts, and that directory is created ONCE under a
# sentinel that deliberately never recreates it. So there are two ways to reach
# the skip branch and they are NOT the same fact:
#
#   fresh Mac        no sentinel, no Transcripts  -> nothing was ever recorded
#   removed          sentinel PRESENT, no Transcripts -> it existed and is gone
#
# Before this test, both printed "there are no recordings to read", which is
# FALSE in the second case and hides a feed the customer used to have. This is
# the same class as a false zero: absence of data and absence of the place data
# lives print identically unless something discriminates them.
#
# WHY THIS TEST EXECUTES RATHER THAN GREPS. A grep for the new string passes the
# moment the string exists anywhere, including in a branch that never runs. That
# is presence, not behaviour. This test EXTRACTS the real else-block out of the
# shipping install.sh, stubs `warn`/`info`, and RUNS it under both states, so a
# fix that adds the message without wiring the condition still fails here.
#
# Exit codes: 0 pass, 1 RED (defect present), 2 CANNOT-RUN (a prerequisite is
# missing, which is NOT a pass and must not be read as one).

set -uo pipefail

# NO `... | grep -q` ANYWHERE IN THIS FILE, DELIBERATELY. grep -q exits on its
# first match and SIGPIPEs the producer, which under `pipefail` can invert the
# verdict of the very assertion being made -- the pipe decides, not the test.
# This file runs under a bash shebang we control, so the herestring remedy is
# available and is used throughout: `grep -q PAT <<< "$var"` has no pipe, so
# there is nothing to SIGPIPE. (If this ever has to run under `sh -c`, ssh or a
# login shell we do not choose, herestrings are a bashism -- switch to
# `[ "$(... | grep -c PAT)" -gt 0 ]`, because grep -c must read to EOF.)

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"

fail=0
red()  { printf 'RED   %s\n' "$1"; fail=1; }
okay() { printf 'ok    %s\n' "$1"; }

# ── CANNOT-RUN gate ───────────────────────────────────────────────────────
for f in "$INSTALL_SH" "$STRINGS"; do
    if [[ ! -f "$f" ]]; then
        printf 'CANNOT-RUN: missing prerequisite %s\n' "$f"
        printf 'This is not a pass.\n'
        exit 2
    fi
done

# ── Extract the branch under test, by its own anchors ─────────────────────
# Anchored on the progress marker above it and the next feed below it, so a
# rename of either end makes this CANNOT-RUN rather than silently testing an
# empty string (a zero-length subject would "pass" every assertion).
BLOCK="$(awk '
    /^if \[\[ -d "\$\{USER_FACING_ROOT\}\/Transcripts" \]\]; then$/ { grab=1 }
    grab { print }
    grab && /^fi$/ { exit }
' "$INSTALL_SH")"

if [[ -z "$BLOCK" ]]; then
    printf 'CANNOT-RUN: could not extract the Transcripts branch from install.sh.\n'
    printf 'The anchor moved. Refusing to report a pass on an empty subject.\n'
    exit 2
fi

# Positive control on the extraction itself: the block must contain the call
# that actually runs the feed. If it does not, we grabbed the wrong region.
if ! grep -q '_install_conversation_feed spoken' <<< "$BLOCK"; then
    printf 'CANNOT-RUN: extracted block does not contain the spoken feed call.\n'
    exit 2
fi

# ── Harness ───────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
run_case() {
    # $1 = sentinel present (yes/no); prints everything the block emitted.
    local sentinel_present="$1"
    local tmp; tmp="$(mktemp -d)"
    (
        set +u
        # shellcheck disable=SC1090
        . "$STRINGS"
        USER_FACING_ROOT="${tmp}/Documents/Ostler"
        mkdir -p "$USER_FACING_ROOT"
        # Transcripts deliberately NOT created: this is the skip branch.
        USER_TREE_SENTINEL="${tmp}/.installer-tree-created"
        [[ "$sentinel_present" == "yes" ]] && : > "$USER_TREE_SENTINEL"
        TOTAL_STEPS=10
        progress() { :; }
        _install_conversation_feed() { echo "FEED_RAN"; }
        warn() { echo "WARN: $*"; }
        info() { echo "INFO: $*"; }
        eval "$BLOCK"
    )
    rm -rf "$tmp"
}

fresh_out="$(run_case no)"
removed_out="$(run_case yes)"

# ── Assertions ────────────────────────────────────────────────────────────

# 1. Neither case may run the feed (Transcripts is absent in both).
if grep -q 'FEED_RAN' <<< "${fresh_out}${removed_out}"; then
    red "the feed ran with Transcripts absent -- the gate is not gating"
else
    okay "feed does not run when Transcripts is absent (both states)"
fi

# 2. THE DEFECT. The two states must not produce identical output.
if [[ "$fresh_out" == "$removed_out" ]]; then
    red "fresh-Mac and removed-directory are INDISTINGUISHABLE -- both print:"
    printf '      %s\n' "$fresh_out"
else
    okay "fresh-Mac and removed-directory produce different output"
fi

# 3. The removed case must WARN, not merely inform. A removal is a capability
#    that was present and is now gone; the warn line is where a program
#    confesses, and an info line lets it read as ordinary onboarding.
if grep -q '^WARN:' <<< "$removed_out"; then
    okay "removed-directory case raises a warning"
else
    red "removed-directory case does not warn; it only info's"
fi

# 4. The removed case must NOT claim the fresh-Mac cause. This is the false
#    statement the row is about.
if grep -qi 'no recordings to read' <<< "$removed_out"; then
    red "removed case still claims 'no recordings to read' -- states a false cause"
else
    okay "removed case does not claim the fresh-Mac cause"
fi

# 5. The fresh case must be UNCHANGED -- onboarding copy still reaches a
#    customer who has genuinely never recorded anything. A fix that made every
#    fresh install warn would be a regression, so this is the control that must
#    fail if the condition is inverted.
if grep -qi 'no recordings to read' <<< "$fresh_out"; then
    okay "fresh-Mac case keeps its onboarding message"
else
    red "fresh-Mac case lost its onboarding message (condition inverted?)"
fi

if [[ "$fail" -eq 0 ]]; then
    printf '\nPASS: 5 assertions, 2 executed states (fresh / removed)\n'
    exit 0
fi
printf '\nFAIL: see RED lines above\n'
exit 1
