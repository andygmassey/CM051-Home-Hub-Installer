#!/usr/bin/env bash
#
# test_wiki_baseline_background.sh
#
# Byte-walking regression test for the v1.0.1 background-summaries split
# (change A). Refuses the exact failure shapes that would either bring
# back the 30-60 min install freeze or let a background failure sink the
# install.
#
# What the failure looked like (PRE-FIX, must never recur):
#   1. the FIRST compile ran with summaries ON and blocked the install
#      for 30-60 min while the installer read 100%
#   2. the background full compile is missing, so summaries never land
#   3. the background job's exit code gates the install (a slow-model
#      404 or a crash 30 min later fails an install that already
#      succeeded on the baseline wiki)
#   4. the baseline compile's REAL exit code is not checked (a failed
#      baseline is treated as success because `| tail` returns 0)
#
# All axes per locked memory feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS_SH="$REPO_ROOT/install.sh.strings.en-GB.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
    echo "test_wiki_baseline_background: FAILED" >&2
    exit 1
fi

# Axis 1: the FIRST compile must run in baseline mode (OSTLER_WIKI_SKIP_LLM=1)
# so it skips the LLM summaries and finishes fast. The baseline injects the
# skip env into the wiki-compiler run.
if ! grep -q -- '-e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler' "$INSTALL_SH"; then
    failure "first compile does not pass OSTLER_WIKI_SKIP_LLM=1 -- the install would block on summaries again"
fi
if ! grep -q 'run --rm -T' "$INSTALL_SH"; then
    failure "compile does not use -T (the compose run --rm exit-hang cure)"
fi

# Axis 2: the baseline compile's REAL exit code must gate (PIPESTATUS,
# not the tail pipe), so a failed baseline is not mistaken for success.
if ! grep -q 'WIKI_BASELINE_RC=${PIPESTATUS\[0\]' "$INSTALL_SH"; then
    failure "baseline compile exit code is not captured from PIPESTATUS -- a failed compile reads as success"
fi
if ! grep -Eq 'if \[ "\$WIKI_BASELINE_RC" -eq 0 \]' "$INSTALL_SH"; then
    failure "install does not gate on the baseline compile exit code"
fi

# Axis 3: a FULL summary compile must be kicked in the BACKGROUND (full
# mode -- no skip flag) and detached so it survives install.sh.
#
# v1018-D675: these assertions demanded ONE SPELLING of the invocation --
# `nohup docker compose ... wiki-compiler` on a single line, and the exact
# byte sequence `</dev/null >"$WIKI_BG_LOG" 2>&1 &`. Both stopped matching
# when the v1.0.0 chat-saturation fix wrapped the compile in
# `nohup bash -c '<slot-lock acquire>; docker compose ...' ... &`, which
# moved `</dev/null` inside the wrapper (onto the compose run) and left the
# outer line as `' _ "$_wiki_slot" "$OSTLER_DIR" >"$WIKI_BG_LOG" 2>&1 &`.
# Every property this axis exists to protect was still true; the test had
# never run, so the phantom went unseen.
#
# The first note on this row also called the whole design SUPERSEDED, from
# the comment at install.sh:9883 ("wiki-compiler is profile-gated so it
# never starts at all here") -- but that comment scopes the DATA-SERVICES
# phase, and the same sentence points forward to Phase 3.16, which is where
# the baseline + background split actually lives. Evidence adjacent to the
# claim, not the mechanism.
#
# Assert the PROPERTIES on the block itself, delimited by CONTAINMENT (the
# WIKI_BG_LOG assignment through the disown that releases the job) rather
# than by proximity, so a wrapper growing another few lines cannot silently
# push the compile out of a fixed-size window. Comment lines are stripped:
# line 18363 is a comment that names nohup/</dev/null/disown, and reading it
# as code would let all three vanish from the real block while this stays
# green.
BG_BLOCK="$(awk '/WIKI_BG_LOG=/{inblk=1} inblk{print} inblk && /disown/{exit}' \
    "$INSTALL_SH" | sed 's/^[[:space:]]*//' | grep -v '^#')"

if [[ -z "$BG_BLOCK" ]]; then
    failure "no WIKI_BG_LOG..disown block found -- the detached background compile is gone, or the mechanism moved. If it moved, retarget this axis; do not assume the compile is still detached."
else
    if ! grep -q 'nohup' <<<"$BG_BLOCK"; then
        failure "background compile block has no nohup -- it would die with install.sh's terminal"
    fi
    # Deliberately NOT pinned to `--rm -T wiki-compiler` adjacency: adding a
    # legitimate `-e FOO=1` between them would break a literal match and
    # report the compile as missing when it is right there. Assert the two
    # facts that matter -- the compile profile, and the service -- on the
    # same line, independent of what sits between them.
    if ! grep -Eq 'docker compose .*--profile compile run .*wiki-compiler' <<<"$BG_BLOCK"; then
        failure "background compile block never runs wiki-compiler -- summaries would never land"
    fi
    # It is the FULL pass: the skip flag must not appear anywhere in it.
    if grep -q 'OSTLER_WIKI_SKIP_LLM' <<<"$BG_BLOCK"; then
        failure "the background compile carries OSTLER_WIKI_SKIP_LLM -- it would skip the very summaries it exists to generate"
    fi
    # Backgrounded with & and its output sent to the log, so install.sh
    # neither waits on it nor loses its diagnostics.
    if ! grep -Eq '>"\$WIKI_BG_LOG" 2>&1[[:space:]]*&[[:space:]]*$' <<<"$BG_BLOCK"; then
        failure "background compile is not backgrounded into \$WIKI_BG_LOG with '>\"\$WIKI_BG_LOG\" 2>&1 &' -- install would wait on it, or its output would be lost"
    fi
    # stdin detached: `compose run --rm` without it is the exit-hang.
    if ! grep -q '</dev/null' <<<"$BG_BLOCK"; then
        failure "background compile does not detach stdin (</dev/null) -- compose run --rm can hang on exit"
    fi
    if ! grep -q 'disown' <<<"$BG_BLOCK"; then
        failure "background compile is not disowned -- its lifecycle is tied to the shell"
    fi
fi

# Axis 4: the background job must NOT be wrapped in an exit-code gate. The
# only RC check in this block is WIKI_BASELINE_RC; there must be no
# WIKI_BG_RC / wait-on-background-pid that could fail the install.
if grep -Eq 'WIKI_BG_RC|wait .*WIKI_BG|WIKI_BACKGROUND_RC' "$INSTALL_SH"; then
    failure "the background compile's exit code is captured/gated -- a late background failure could sink a completed install"
fi

# Axis 5: customer-facing string for the background-start info line.
if [[ -f "$STRINGS_SH" ]]; then
    if ! grep -q 'MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED=' "$STRINGS_SH"; then
        failure "MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED string is missing"
    fi
else
    failure "install.sh.strings.en-GB.sh missing"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_wiki_baseline_background: FAILED" >&2
    exit 1
fi
echo "test_wiki_baseline_background: baseline gates + detached full compile never does (skip-flag baseline + PIPESTATUS gate + nohup/disown background + no bg rc gate + string)"
