#!/usr/bin/env bash
#
# tests/test_app_binary_agents_bootstrap.sh
#
# EVERY agent that runs the daemon binary must get the bootstrap treatment,
# not just the one the fault was first reported on.
#
# THE FAULT (v1018-D019)
#
#   An agent whose ProgramArguments[0] lives inside OstlerAssistant.app,
#   bootstrapped before the .app is staged, makes launchd fail to exec. It
#   records last-exit-code=78 (EX_CONFIG) and writes zero-byte .log/.err --
#   because nothing ever ran, so nothing ever wrote. The zero bytes are the
#   evidence, not a mystery.
#
#   EX_CONFIG IS NOT A RETRY. launchd reads it as "misconfigured" and parks
#   the job. The 78 survives reboots and reinstalls until something calls
#   `launchctl kickstart -k`. So it never self-heals.
#
# WHY THIS TEST IS ABOUT COVERAGE, NOT ABOUT ONE AGENT
#
#   HR015 #217 diagnosed this correctly and fixed it for com.ostler.export-scan.
#   Measured on 2026-08-12: 10 agents have the app binary as
#   ProgramArguments[0]; `grep -n "_ostler_ensure_.*_bootstrap()"` returned
#   exactly ONE hit, hard-coded to that one label. The other nine -- including
#   whatsapp-bundle, which is D019 -- had the race and no clearing kickstart.
#
#   A guard that has only ever seen one label is green by construction for
#   every label it has not seen. So this test does not check "is
#   whatsapp-bundle covered". It DERIVES the set of agents from the shipped
#   plists and asserts the sweep covers all of them, which is the only form
#   that catches agent number eleven.
#
# THE NEGATIVE CONTROL, which is the point of the exercise
#
#   Assertions 1-3 would all pass against a sweep table that happened to list
#   every agent by luck. Assertion 4 removes one label from the table and
#   REQUIRES the coverage check to fail, then restores it and requires green
#   again. Without it, this file cannot tell a working guard from a guard
#   that never fires.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

FAILED=0
pass() { echo "PASS: $*"; }
failure() { echo "FAIL: $*" >&2; FAILED=1; }

[[ -f "$INSTALL_SH" ]] || { echo "FAIL: install.sh missing" >&2; exit 1; }

# ── Derive the agent set from what the installer actually ships ───────
# Vendored plists carry the OSTLER_ASSISTANT_BINARY placeholder; heredoc
# plists in install.sh interpolate the app-bundle path directly. Both shapes
# mean "ProgramArguments[0] is the late-staged daemon binary".
_derive_labels() {
    # Vendored plist files.
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        awk '/<key>Label<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$p"
    done < <(grep -rl "OSTLER_ASSISTANT_BINARY" "$REPO_ROOT" --include="*.plist" 2>/dev/null | grep -v "/\.git/")
    # Heredoc plists inside install.sh: find the app-binary line, then walk
    # back to the nearest Label above it.
    while IFS= read -r ln; do
        awk -v n="$ln" 'NR<=n && /<key>Label<\/key>/{cand=NR} END{}
             NR==0{}' /dev/null 2>/dev/null || true
        awk -v n="$ln" 'NR<n && /<key>Label<\/key>/{l=NR}
                        END{print l}' "$INSTALL_SH" | while read -r lab; do
            [[ -n "$lab" ]] || continue
            sed -n "$((lab+1))p" "$INSTALL_SH" \
                | sed 's/.*<string>\(.*\)<\/string>.*/\1/' | tr -d ' \t'
        done
    done < <(grep -n '^\s*<string>\${OSTLER_DIR}/OstlerAssistant\.app/Contents/MacOS/ostler-assistant</string>' "$INSTALL_SH" | cut -d: -f1)
}

DERIVED="$(_derive_labels | grep -E '^com\.' | sort -u)"
DERIVED_N="$(printf '%s\n' "$DERIVED" | grep -c . || true)"

if [[ "$DERIVED_N" -lt 2 ]]; then
    failure "derived only $DERIVED_N agent label(s) from the tree. This test's
 denominator is broken, and a coverage test with a broken denominator passes
 by finding nothing. Expected the whatsapp/email/spoken/imessage bundle agents
 plus the heredoc ones."
else
    pass "derived $DERIVED_N agent labels whose ProgramArguments[0] is the daemon binary"
fi

# ── 1. the sweep exists and runs on the daemon-staged success path ────
if grep -q '^_ostler_ensure_app_binary_agents_bootstrap() {' "$INSTALL_SH"; then
    pass "_ostler_ensure_app_binary_agents_bootstrap() is defined"
else
    failure "_ostler_ensure_app_binary_agents_bootstrap() is not defined"
fi

FIN_START=$(awk '/^_finalise_daemon_staging\(\) \{/{print NR; exit}' "$INSTALL_SH")
FIN_END=$(awk -v s="$FIN_START" 'NR>s && /^\}/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$FIN_START" || -z "$FIN_END" ]]; then
    failure "could not locate _finalise_daemon_staging() bounds"
else
    if awk -v s="$FIN_START" -v e="$FIN_END" \
        'NR>=s && NR<=e && /_ostler_ensure_app_binary_agents_bootstrap/{f=1} END{exit !f}' "$INSTALL_SH"; then
        pass "sweep is called from _finalise_daemon_staging"
    else
        failure "the sweep is never called from _finalise_daemon_staging -- it would never fire"
    fi
fi

# ── 2. the sweep clears a PARKED result, not just an unloaded job ─────
# Without kickstart -k an already-loaded job keeps its stale EX_CONFIG(78)
# forever, which is the half of the fault that makes it permanent.
SWEEP_BODY="$(awk '/^_ostler_ensure_app_binary_agents_bootstrap\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL_SH")"
_sweep_ok=1
grep -Eq 'kickstart -k|_ks_bounded "[^"]*" -k' <<<"$SWEEP_BODY" \
    || { failure "sweep body has no 'launchctl kickstart -k' -- a parked EX_CONFIG(78) on an already-loaded job would never clear"; _sweep_ok=0; }
grep -q 'ostler-assistant' <<<"$SWEEP_BODY" \
    || { failure "sweep body does not check the daemon binary exists"; _sweep_ok=0; }
[[ "$_sweep_ok" -eq 1 ]] && pass "sweep both bootstraps and kickstart -k's, and checks the binary"

# ── 3. COVERAGE: every derived agent appears in the sweep table ───────
TABLE="$(awk '/^_OSTLER_APP_BINARY_AGENTS="/{f=1} f{print} f&&/"$/&&!/^_OSTLER_APP_BINARY_AGENTS="\\$/{exit}' "$INSTALL_SH")"
_check_coverage() {
    local table="$1" missing=0 lab
    while IFS= read -r lab; do
        [[ -n "$lab" ]] || continue
        grep -qF "$lab" <<<"$table" || { echo "  uncovered: $lab"; missing=$((missing+1)); }
    done <<< "$DERIVED"
    return "$missing"
}
if _check_coverage "$TABLE"; then
    pass "all $DERIVED_N agents are covered by the sweep table"
else
    failure "agents above ship a plist running the daemon binary but are NOT in
 the sweep table. On a fresh install each records EX_CONFIG(78) with zero-byte
 logs and, because launchd does not retry EX_CONFIG, stays parked forever."
fi

# ── 4. NEGATIVE CONTROL: drop one label, the check MUST fail ──────────
# This is the assertion that distinguishes a guard from a guard-shaped no-op.
VICTIM="$(printf '%s\n' "$DERIVED" | head -1)"
MUTATED="$(grep -vF "$VICTIM" <<<"$TABLE")"
if _check_coverage "$MUTATED" >/dev/null 2>&1; then
    failure "CONTROL FAILED: removing '$VICTIM' from the table still reports full
 coverage. The coverage check does not discriminate, so its green above means
 nothing and this whole file is decorative."
else
    pass "CONTROL -- removing '$VICTIM' makes the coverage check fail, so it discriminates"
fi
# Restore is implicit: the mutation was on a shell variable, never on disk.
git -C "$REPO_ROOT" diff --quiet -- install.sh 2>/dev/null \
    || true   # install.sh may legitimately carry this PR's edits; not a mutation leak.

# ── 5. the conversation-feed renderer gates its own bootstrap ─────────
# Belt to the sweep's braces: gating stops the 78 ever being recorded,
# the sweep clears one already recorded. D019 needed both.
FEED_BODY="$(awk '/^_install_conversation_feed\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL_SH")"
if [[ -n "$FEED_BODY" ]]; then
    if grep -Eq '\[\[ +! +-x +"\$_assistant_bin" +\]\]|\[\[ +-x +"\$_assistant_bin" +\]\]' <<<"$FEED_BODY"; then
        pass "_install_conversation_feed gates its bootstrap on the daemon binary"
    else
        failure "_install_conversation_feed bootstraps without checking the daemon binary exists -- every fresh install re-records EX_CONFIG(78) on all four bundle feeds"
    fi
else
    failure "could not locate _install_conversation_feed() (renderer moved?)"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "ALL APP-BINARY AGENT BOOTSTRAP TESTS PASSED ($DERIVED_N agents covered)"
else
    echo "APP-BINARY AGENT BOOTSTRAP TESTS FAILED" >&2
fi
exit "$FAILED"
