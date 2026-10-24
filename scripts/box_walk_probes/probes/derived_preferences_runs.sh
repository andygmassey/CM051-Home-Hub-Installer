#!/usr/bin/env bash
# derived_preferences_runs -- can the derive engine run on this box, and has it?
# (smart-prefs, v1.0.118, BLOCKING. OS003 docs/SMART_PREFERENCES_SPEC.md "Done means PROVEN".)
#
# WALK_READ_ONLY: imports in the cm019 venv, reads the status file, the log and the LaunchAgent plist.
# Judged by lib/smart_prefs.py from counts and yes/no facts only; no real
# preference label, digest line or brief sentence leaves the box. The fixture is
# synthetic and is seeded by lib/smart_prefs_seed.sh before phase 2. Nothing it
# could not measure is a pass: CANNOT-RUN names the missing prerequisite.
# RED today (v1.0.116 shape): no pyyaml / no derive tree in the cm019 venv, or no completed pass.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/smart_prefs_seed.sh"

PROBE_NAME="derived_preferences_runs"
PROBE_QUESTION="in the cm019 venv python can yaml, services.enrich.src.derive and pyshacl be imported, is the derive LaunchAgent scheduled, and has the tick recorded a completed pass (state/derived-preferences.json, outcome written or empty)?"

self_test() {
    smart_prefs_self_test
}

run_probe() {
    smart_prefs_run "derived_preferences_runs" "box-runs" "cm019"
}

probe_main "$@"
