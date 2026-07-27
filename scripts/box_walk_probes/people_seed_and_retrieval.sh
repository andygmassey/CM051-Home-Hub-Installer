#!/usr/bin/env bash
# scripts/box_walk_probes/people_seed_and_retrieval.sh
# ============================================================================
# STUB — not-yet-implemented.
#
# Intended behaviour (full-probe scope, shipped alongside the Studio matrix
# runbook, NOT this PR):
#   1. Seed a Person "Sofia Testperson" into the running graph on
#      $OSTLER_BOX_HOST.
#   2. Ask the daemon via the iMessage tool-call path a question that requires
#      retrieving the seeded person.
#   3. Assert the reply CONTAINS "Sofia Testperson" AND does NOT contain the
#      "I don't have any information" confabulation-tell.
#   4. Cleanly delete the seeded person on the way out.
#
# TODO(archie): full probe implementation lives in STUDIO_MATRIX_RUNBOOK.
# The stub here exits 0 so the primitive wiring can land now; the full body
# lands when Andy + TNM cut the Studio matrix session.
# ============================================================================

set -uo pipefail

echo "people_seed_and_retrieval: STUB — full probe deferred to Studio matrix runbook"
exit 0
