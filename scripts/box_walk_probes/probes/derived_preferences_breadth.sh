#!/usr/bin/env bash
# derived_preferences_breadth -- does Smart Preferences cover all of life, not one domain?
# (smart-prefs, v1.0.118, BLOCKING. OS003 docs/SMART_PREFERENCES_SPEC.md "Done means PROVEN".)
#
# WALK_READ_ONLY: GETs /api/v1/preferences/derived and reads the stores to confirm the fixture is present.
# Judged by lib/smart_prefs.py from counts and yes/no facts only; no real
# preference label, digest line or brief sentence leaves the box. The fixture is
# synthetic and is seeded by lib/smart_prefs_seed.sh before phase 2. Nothing it
# could not measure is a pass: CANNOT-RUN names the missing prerequisite.
# RED today (v1.0.116 shape): films only, so one category.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/smart_prefs_seed.sh"

PROBE_NAME="derived_preferences_breadth"
PROBE_QUESTION="on the seed fixture, does GET /api/v1/preferences/derived return items from at least 6 broad categories?"

self_test() {
    smart_prefs_self_test
}

run_probe() {
    smart_prefs_run "derived_preferences_breadth" "box-served" "cm019"
}

probe_main "$@"
