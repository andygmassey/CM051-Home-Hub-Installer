#!/usr/bin/env bash
# derived_preferences_dislike -- is a stated dislike derived as a NEGATIVE preference?
# (smart-prefs, v1.0.118, BLOCKING. OS003 docs/SMART_PREFERENCES_SPEC.md "Done means PROVEN".)
#
# WALK_READ_ONLY: GETs /api/v1/preferences/derived and reads the stores to confirm the fixture is present.
# Judged by lib/smart_prefs.py from counts and yes/no facts only; no real
# preference label, digest line or brief sentence leaves the box. The fixture is
# synthetic and is seeded by lib/smart_prefs_seed.sh before phase 2. Nothing it
# could not measure is a pass: CANNOT-RUN names the missing prerequisite.
# RED today (v1.0.116 shape): no stated-preference reader, so no negative item.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/smart_prefs_seed.sh"

PROBE_NAME="derived_preferences_dislike"
PROBE_QUESTION="does a seeded owner message stating a dislike (said in three conversations) yield a negative-strength item in its dimension (food.ingredient) on the served route?"

self_test() {
    smart_prefs_self_test
}

run_probe() {
    smart_prefs_run "derived_preferences_dislike" "box-served" "cm019"
}

probe_main "$@"
