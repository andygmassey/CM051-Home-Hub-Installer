#!/usr/bin/env bash
# derived_preferences_not_others -- is another person's stated like kept OUT of the owner's preferences?
# (smart-prefs, v1.0.118, BLOCKING. OS003 docs/SMART_PREFERENCES_SPEC.md "Done means PROVEN".)
#
# WALK_READ_ONLY: GETs /api/v1/preferences/derived and reads the stores to confirm the fixture is present.
# Judged by lib/smart_prefs.py from counts and yes/no facts only; no real
# preference label, digest line or brief sentence leaves the box. The fixture is
# synthetic and is seeded by lib/smart_prefs_seed.sh before phase 2. Nothing it
# could not measure is a pass: CANNOT-RUN names the missing prerequisite.
# Carries a control: the owner's own stated like must DERIVE, or an engine that derives nothing would pass.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/smart_prefs_seed.sh"

PROBE_NAME="derived_preferences_not_others"
PROBE_QUESTION="does a seeded message where ANOTHER participant states a like yield no owner item, while the owner's own stated like (the control) does derive?"

self_test() {
    smart_prefs_self_test
}

run_probe() {
    smart_prefs_run "derived_preferences_not_others" "box-served" "cm019"
}

probe_main "$@"
