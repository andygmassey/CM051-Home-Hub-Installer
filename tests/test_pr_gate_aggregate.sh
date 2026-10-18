#!/usr/bin/env bash
# tests/test_pr_gate_aggregate.sh
#
# The self-test of scripts/verify_pr_gate_aggregate.sh, given a home under
# tests/ so scripts/verify_test_wiring.sh can SEE it: that regenerator globs
# tests/test_*.sh and nothing else, so a self-test invoked only from a
# workflow step is invisible to the manifest and removing the step would leave
# the ledger still reading WIRED.
#
# What it guards is in that script's header: the required check must not be
# able to pass having examined nothing, or having missed a failure, or having
# sampled once instead of waiting. Short version -- this repository had no
# branch protection at all, and the one obvious fix (require a job literally
# named `gate`) is itself broken, because that name belongs to a job inside
# path-filtered workflows rather than an aggregate.
#
# EXIT: 0 the suite passed. 1 it did not. 2 the script is missing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/verify_pr_gate_aggregate.sh"

[ -f "$SCRIPT" ] || { echo "CANNOT-RUN: no script at $SCRIPT" >&2; exit 2; }

bash "$SCRIPT" --self-test
