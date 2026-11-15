#!/usr/bin/env bash
# dislike_respected_in_brief -- does the brief built on the seed leave out the disliked thing, and use the likes?
# (smart-prefs, v1.0.118, BLOCKING. OS003 docs/SMART_PREFERENCES_SPEC.md "Done means PROVEN".)
#
# WALK_WRITES: adds and deletes a one-shot, undelivered copy of the morning-brief cron job (POST/DELETE /api/cron).
# Judged by lib/smart_prefs.py from counts and yes/no facts only; no real
# preference label, digest line or brief sentence leaves the box. The fixture is
# synthetic and is seeded by lib/smart_prefs_seed.sh before phase 2. Nothing it
# could not measure is a pass: CANNOT-RUN names the missing prerequisite.
# RED today (v1.0.116 shape): no dislike is derived, so there is nothing for the brief to respect; and the brief names no liked item.
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/smart_prefs_seed.sh"

PROBE_NAME="dislike_respected_in_brief"
PROBE_QUESTION="run the installed morning-brief job (an undelivered copy) on the seed fixture: is the disliked thing absent from the brief, and does the brief name at least one served liked item?"

self_test() {
    smart_prefs_self_test
}

run_probe() {
    smart_prefs_run "dislike_respected_in_brief" "box-brief" "hub"
}

probe_main "$@"
