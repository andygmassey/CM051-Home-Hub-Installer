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
# Shape assertions updated 2026-07-07: the original `nohup docker
# compose ... &` one-liner was SUPERSEDED by the v1.0.0 chat-saturation
# fix. The full compile now runs inside `nohup bash -c '...'` which
# first acquires the shared background-LLM slot lock
# (${OSTLER_INGEST_LOCK}, PID-liveness reclaim) so background Ollama
# concurrency stays at 1 and live chat always has a free decode slot
# (measured 277s replies vs 1.5s without the lock on the .149 box).
# The detachment guarantees (nohup + & + disown + no skip flag + no rc
# gate) are unchanged and still asserted here.
if ! grep -q "nohup bash -c '" "$INSTALL_SH"; then
    failure "no detached background compile wrapper (nohup bash -c slot-lock block) -- summaries would never land"
fi
# Extract the nohup'd slot-lock block (from the nohup line to the
# closing quote line) for the inner assertions.
BG_BLOCK=$(awk "/nohup bash -c '/{f=1} f{print} f && /^        ' /{exit}" "$INSTALL_SH")
if ! printf '%s\n' "$BG_BLOCK" | grep -q 'docker compose --profile compile run --rm -T wiki-compiler'; then
    failure "the nohup'd block does not run the full wiki-compiler pass -- summaries would never land"
fi
# The background invocation must NOT carry the skip flag (it is the FULL
# pass).
if printf '%s\n' "$BG_BLOCK" | grep 'wiki-compiler' | grep -q 'OSTLER_WIKI_SKIP_LLM'; then
    failure "the background compile carries OSTLER_WIKI_SKIP_LLM -- it would skip the very summaries it exists to generate"
fi
# The block must take the shared background-LLM slot lock before the
# compile (chat-saturation fix) and free it on exit.
if ! printf '%s\n' "$BG_BLOCK" | grep -q 'mkdir "\$_slot"'; then
    failure "background compile does not acquire the shared background-LLM slot lock -- live chat would starve behind the compile"
fi
if ! printf '%s\n' "$BG_BLOCK" | grep -q 'trap "rm -rf'; then
    failure "background compile does not release the slot lock on exit -- conversation feeds would deadlock behind a dead PID"
fi
# It must be backgrounded (&) and disowned so its exit code can't gate.
if ! grep -Eq '>"\$WIKI_BG_LOG" 2>&1 &$' "$INSTALL_SH"; then
    failure "background compile is not detached with & -- install would wait on it"
fi
if ! grep -q 'disown' "$INSTALL_SH"; then
    failure "background compile is not disowned -- its lifecycle is tied to the shell"
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
