#!/usr/bin/env bash
#
# tests/test_vendored_ical_people_clickthrough.sh
#
# People click-through + person-card guard for the VENDORED ical-server
# (B4 + B5, v1.0.0 LAST-CUT audit).
#
# Meta-risk this guards (divergent-twin / "in the repo != in the
# artifact"): the ical-server that actually ships is the vendored copy at
# vendor/cm041/assistant_api/ical-server.py (the .app postBuildScript
# bundles it; install.sh deploys it to ~/.ostler/services/ical-server).
# It has diverged from the CM041 source: the vendored copy grew
# people_list() (the Hub dashboard People source) but lacked the slug /
# wiki_url per row (B4) and the person_enrichment() route (B5), so People
# rows rendered but could not be clicked through and the person card 404'd.
# The CM041 source has person_enrichment but no people_list -- so neither
# copy alone is correct, and re-vendoring from CM041 would REGRESS B4.
#
# This test asserts, on the SHIPPING vendored copy, that:
#   1. people_list() emits slug + wiki_url per row (B4),
#   2. person_enrichment() is defined (B5),
#   3. the GET /api/v1/people/{slug}/enrichment dispatch branch exists,
#   4. its helper _LAST_CONTACT_SOURCES is present,
#   5. the file still parses.
# A future re-vendor that drops any of these trips this in CI.
#
# Network-free, dependency-free.

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$REPO_ROOT/vendor/cm041/assistant_api/ical-server.py"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$V" ] || fail_test "vendored ical-server not found at $V"

python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$V" \
    || fail_test "vendored ical-server.py does not parse"
echo "PASS: vendored ical-server.py parses"

# Narrow to the people_list() body (def people_list -> next top-level def).
PL_START="$(grep -n '^def people_list' "$V" | head -1 | cut -d: -f1)"
[ -n "$PL_START" ] || fail_test "people_list() not found in vendored copy"
PL_END="$(awk -v s="$PL_START" 'NR>s && /^def /{print NR; exit}' "$V")"
[ -n "$PL_END" ] || fail_test "could not bound people_list()"
pl_body() { sed -n "${PL_START},${PL_END}p" "$V"; }

# B4: every people_list row must carry slug + wiki_url.
grep -q 'row\["slug"\]' <<<"$(pl_body)" \
    || fail_test "B4 regressed: people_list() does not set row['slug'] (People rows can't click through)"
grep -q 'row\["wiki_url"\]' <<<"$(pl_body)" \
    || fail_test "B4 regressed: people_list() does not set row['wiki_url']"
echo "PASS: B4 -- people_list() emits slug + wiki_url per row"

# B5: person_enrichment() defined + dispatched + its helper present.
grep -q '^def person_enrichment' "$V" \
    || fail_test "B5 regressed: person_enrichment() missing from vendored copy (person card 404s)"
echo "PASS: B5 -- person_enrichment() defined"

grep -Eq 'parsed\.path\.endswith\("/enrichment"\)' "$V" \
    || fail_test "B5 regressed: no GET /api/v1/people/{slug}/enrichment dispatch branch"
echo "PASS: B5 -- enrichment route dispatched"

grep -q '^_LAST_CONTACT_SOURCES *=' "$V" \
    || fail_test "B5 regressed: _LAST_CONTACT_SOURCES helper missing (person_enrichment would NameError)"
echo "PASS: B5 -- _LAST_CONTACT_SOURCES helper present"

echo "ALL PASS: test_vendored_ical_people_clickthrough.sh"
