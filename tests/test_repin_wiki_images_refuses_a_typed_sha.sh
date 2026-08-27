#!/usr/bin/env bash
# tests/test_repin_wiki_images_refuses_a_typed_sha.sh
#
# The self-test of scripts/repin_wiki_images.sh, given a home under tests/ so
# that scripts/verify_test_wiring.sh can SEE it. The wiring regenerator globs
# tests/test_*.sh and tests/test_*.py and nothing else, so a self-test invoked
# only from a workflow step is invisible to the manifest: remove the step and
# the ledger still reads WIRED. That is the same shape as every other defect
# this repo has spent the month finding, so the wrapper is cheap insurance.
#
# What the suite underneath refuses, and why it exists, is in the header of
# scripts/repin_wiki_images.sh. Short version: on 2026-08-23 a provenance sha
# was written by taking a real 12-character short sha and inventing the other
# 28, it resolved to nothing, and its prefix matched -- so the hold_ack
# contract, which matches on an 8+ character prefix, would have accepted it.
#
# EXIT: 0 the suite passed. 1 it did not. 2 the script is missing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/repin_wiki_images.sh"

[ -f "$SCRIPT" ] || { echo "CANNOT-RUN: no script at $SCRIPT" >&2; exit 2; }

bash "$SCRIPT" --self-test
