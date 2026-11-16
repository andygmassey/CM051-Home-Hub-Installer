#!/usr/bin/env bash
# probes/people_circles_tiers_no_l3.sh
# ============================================================================
# QUESTION: with OSTLER_INNER_CIRCLE on and synthetic people seeded, does
#           GET /api/v1/people/circles return only known tiers, the seeded L2
#           person present, and NO L3 person?
#
# ADVISORY (walk_promote_scope.tsv). Its verdict is a measurement either way.
#
# SYNTHETIC ONLY. Seed ids are placeholders from the approved cast. Nothing
# here prints a member's name, only counts and the seeded ids.
#
# CANNOT-RUN when the box, the admin token or the payload is missing. A missing
# prerequisite is never a pass.
# ============================================================================
PROBE_NAME="people_circles_tiers_no_l3"
PROBE_QUESTION="with the People Circles flag on and synthetic people seeded, does GET /api/v1/people/circles return only known tiers, the seeded L2 person present, and no L3 person?"

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/probe.sh
. "${_here}/lib/probe.sh"

GATEWAY_PORT="${OSTLER_GATEWAY_PORT:-8000}"
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}"
SEED_L2_ID="${OSTLER_CIRCLES_SEED_L2:-person_l2_synthetic}"
SEED_L3_ID="${OSTLER_CIRCLES_SEED_L3:-person_l3_synthetic}"
KNOWN_TIERS="inner close work ask wider"

# Reads the payload from stdin and prints one summary line per fact.
# Never prints a member name.
_summarise() {
    OSTLER_KNOWN_TIERS="$KNOWN_TIERS" SEED_L2="$SEED_L2_ID" SEED_L3="$SEED_L3_ID" python3 -I -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("BAD_JSON " + type(e).__name__); sys.exit(0)
if not isinstance(d, dict) or "members" not in d or not isinstance(d["members"], list):
    print("NO_MEMBERS_KEY"); sys.exit(0)
known = set(os.environ["OSTLER_KNOWN_TIERS"].split())
m = d["members"]
ids = {x.get("person_id"): x for x in m}
print("EXAMINED %d" % len(m))
print("L3_PRESENT %d" % sum(1 for x in m if (x.get("privacy_level") or "") == "L3"))
print("UNKNOWN_TIERS %d" % sum(1 for x in m if x.get("tier") is not None and str(x["tier"]) not in known))
print("L2_SEED_PRESENT %d" % (1 if os.environ["SEED_L2"] in ids else 0))
print("L3_SEED_PRESENT %d" % (1 if os.environ["SEED_L3"] in ids else 0))
'
}

run_probe() {
    local body summary
    body="$(box_run "curl -sS --noproxy '*' -m 15 -H \"Authorization: Bearer \$(cat ${TOKEN_PATH})\" 'http://127.0.0.1:${GATEWAY_PORT}/api/v1/people/circles'" 2>&1)" \
        || probe_cannot_run "could not reach GET /api/v1/people/circles on :${GATEWAY_PORT}; nothing was measured"
    [ -n "$body" ] || probe_cannot_run "the circles route answered with an empty body; that is not an empty circle"
    summary="$(printf '%s' "$body" | _summarise)"
    case "$summary" in
        BAD_JSON*|NO_MEMBERS_KEY*) probe_cannot_run "the route did not return a circles payload (${summary}); nothing was measured" ;;
    esac
    local examined l3 unknown l2 l3seed
    examined="$(printf '%s\n' "$summary" | awk '/^EXAMINED/{print $2}')"
    l3="$(printf '%s\n' "$summary" | awk '/^L3_PRESENT/{print $2}')"
    unknown="$(printf '%s\n' "$summary" | awk '/^UNKNOWN_TIERS/{print $2}')"
    l2="$(printf '%s\n' "$summary" | awk '/^L2_SEED_PRESENT/{print $2}')"
    l3seed="$(printf '%s\n' "$summary" | awk '/^L3_SEED_PRESENT/{print $2}')"
    probe_examined "${examined:-0}" "circle members returned by the route"
    if [ "${l3:-0}" != "0" ] || [ "${l3seed:-0}" != "0" ]; then
        probe_fail_or_advisory "an L3 person is in the circles response (L3 rows ${l3}, seeded L3 id present ${l3seed})"
    fi
    if [ "${unknown:-0}" != "0" ]; then
        probe_fail_or_advisory "${unknown} member(s) carry a tier outside: ${KNOWN_TIERS}"
    fi
    if [ "${l2:-0}" != "1" ]; then
        probe_fail_or_advisory "the seeded L2 person is absent from the circles response; a visible-to-owner person was dropped"
    fi
    probe_pass "circles response: ${examined} members, 0 L3, all tiers known, seeded L2 present"
}

self_test() {
    # Negative controls: an L3 row and an unknown tier must each be counted.
    local sample='{"members":[{"person_id":"x","tier":"inner","privacy_level":"L3"},{"person_id":"y","tier":"bogus","privacy_level":"L2"}]}'
    probe_examined 2 "synthetic control rows (no box read)"
    local out
    out="$(printf '%s' "$sample" | _summarise)"
    printf '%s\n' "$out" | grep -q '^L3_PRESENT 1$' || probe_fail "NEGATIVE CONTROL DID NOT FIRE: an L3 row was not counted"
    printf '%s\n' "$out" | grep -q '^UNKNOWN_TIERS 1$' || probe_fail "NEGATIVE CONTROL DID NOT FIRE: an unknown tier was not counted"
    probe_pass "NEGATIVE CONTROLS FIRED: an L3 row and an unknown tier are each counted"
}

probe_main "$@"
