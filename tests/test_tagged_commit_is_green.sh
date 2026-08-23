#!/usr/bin/env bash
# tests/test_tagged_commit_is_green.sh
#
# The self-test of scripts/verify_tagged_commit_is_green.sh, given a home under
# tests/ so scripts/verify_test_wiring.sh can SEE it: that regenerator globs
# tests/test_*.sh and nothing else, so a self-test invoked only from a workflow
# step is invisible to the manifest and removing the step leaves the ledger
# still reading WIRED.
#
# What it guards is in that script's header. Short version: on 2026-08-23 a
# thirty-second ubuntu job went RED on main at 10:32:44Z, a tag was pushed at
# the same commit thirty seconds later, and the cut spent a macOS build, a
# Developer ID signing and an Apple notarisation round trip to rediscover the
# identical defect.
#
# EXIT: 0 the suite passed. 1 it did not. 2 the script is missing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/verify_tagged_commit_is_green.sh"

[ -f "$SCRIPT" ] || { echo "CANNOT-RUN: no script at $SCRIPT" >&2; exit 2; }

bash "$SCRIPT" --self-test
