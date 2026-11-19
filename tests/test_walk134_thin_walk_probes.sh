#!/usr/bin/env bash
# tests/test_walk134_thin_walk_probes.sh
# ============================================================================
# CI for the four 134 thin-walk probes and the ical-server pin passthrough.
#
#   1. the judge module (lib/walk134_judges.py) passes its own cases, every
#      negative control red and every positive control green
#   2. each probe's --self-test exits 1 with its negative control caught
#   3. each probe, pointed at an unreachable box, exits 78 (CANNOT-RUN), never 0
#   4. the ical pin: resolves a file that imports pwg_privacy_readers, REFUSES
#      one that does not, leaves the pin unset for a missing ref, and an explicit
#      operator pin wins
#   5. the runner and post_walk_qa actually call the pin export, before phase 1
#
# Exit 0 all held, 1 a check failed, 2 a prerequisite is missing.
# ============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
P="${REPO}/scripts/box_walk_probes/probes"
L="${REPO}/scripts/box_walk_probes/lib"
J="${L}/walk134_judges.py"
PROBES="enrichment_reaches_clients enrichment_decline_survives_upgrade derived_themes_still_learning proxy_reads_are_owner_own_brief enrichment_switch_off_reaches_clients enrichment_switch_on_reaches_clients"

fails=0
pass() { printf '  held   %s\n' "$1"; }
bad()  { printf '  FAILED %s\n' "$1"; fails=$((fails + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 missing"; exit 2; }
[ -f "$J" ] || { echo "CANNOT-RUN: judge module missing"; exit 2; }

echo "1. judge module self-test"
out="$(python3 "$J" --self-test 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'negative controls behaved'; then
    pass "judge cases: $(printf '%s' "$out" | sed -n 's/^self-test: //p' | head -1)"
else
    bad "judge self-test rc=$rc"; printf '%s\n' "$out" | sed 's/^/      /'
fi

echo "2. each probe's self-test goes red on its known-bad input"
for n in $PROBES; do
    f="${P}/${n}.sh"
    bash -n "$f" || { bad "$n does not parse"; continue; }
    out="$(env -u OSTLER_BOX_HOST bash "$f" --self-test 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'VERDICT: FAIL -- negative control'; then
        pass "$n --self-test rc=1, negative control FAIL"
    else
        bad "$n --self-test rc=$rc"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    fi
done

echo "3. unreachable box is CANNOT-RUN (78), never a pass"
for n in $PROBES; do
    OSTLER_BOX_HOST="nobody@unreachable.invalid" OSTLER_SSH_TIMEOUT=2 bash "${P}/${n}.sh" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 78 ]; then pass "$n unreachable rc=78"; else bad "$n unreachable rc=$rc (want 78)"; fi
done

echo "4. ical pin resolution"
# shellcheck source=/dev/null
. "${L}/ical_pin.sh"
T="$(mktemp -d)"
git -C "$T" init -q && git -C "$T" config user.email t@example.com && git -C "$T" config user.name t
mkdir -p "$T/vendor/cm041/assistant_api"
printf 'import pwg_privacy_readers\nprint("134")\n' > "$T/vendor/cm041/assistant_api/ical-server.py"
git -C "$T" add -A && git -C "$T" commit -qm good && git -C "$T" branch cut/v9.9.9
printf 'print("no readers here")\n' > "$T/vendor/cm041/assistant_api/ical-server.py"
git -C "$T" commit -qam bad && git -C "$T" branch cut/v9.9.8
want="$(git -C "$T" show cut/v9.9.9:vendor/cm041/assistant_api/ical-server.py | shasum -a 256 | awk '{print $1}')"
got="$(ical_pin_resolve "$T" cut/v9.9.9 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then pass "pin from cut/v9.9.9 equals sha256 of that file"; else bad "pin rc=$rc got='${got}'"; fi
ical_pin_resolve "$T" cut/v9.9.8 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 78 ]; then pass "file without pwg_privacy_readers refused (rc 78)"; else bad "file without readers rc=$rc (want 78)"; fi
ical_pin_resolve "$T" cut/v0.0.0 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 78 ]; then pass "missing ref refused (rc 78)"; else bad "missing ref rc=$rc"; fi
(
    unset EXPECTED_ICAL_SHA256; OSTLER_CUT_VERSION=v9.9.9 ical_pin_export "$T" 2>/dev/null
    [ "${EXPECTED_ICAL_SHA256:-}" = "$want" ] && exit 0 || exit 1
) && pass "ical_pin_export sets EXPECTED_ICAL_SHA256 from OSTLER_CUT_VERSION" || bad "ical_pin_export did not export the cut pin"
(
    unset EXPECTED_ICAL_SHA256; OSTLER_CUT_VERSION=v0.0.0 ical_pin_export "$T" 2>/dev/null
    [ -z "${EXPECTED_ICAL_SHA256:-}" ] && exit 0 || exit 1
) && pass "missing cut leaves the pin unset (probe reports CANNOT-RUN)" || bad "missing cut still exported a pin"
(
    EXPECTED_ICAL_SHA256="$(printf 'a%.0s' $(seq 64))"; export EXPECTED_ICAL_SHA256
    OSTLER_CUT_VERSION=v9.9.9 ical_pin_export "$T" 2>/dev/null
    [ "${EXPECTED_ICAL_SHA256:0:1}" = "a" ] && exit 0 || exit 1
) && pass "an explicit operator pin is kept, not overwritten" || bad "explicit pin was overwritten"
rm -rf "$T"

echo "5. the runner and post_walk_qa wire the export"
if grep -q 'ical_pin_export "$(cd "$HERE/../.." && pwd)"' "${REPO}/scripts/box_walk_probes/run_box_walk.sh"; then
    pass "run_box_walk.sh calls ical_pin_export"
else bad "run_box_walk.sh does not call ical_pin_export"; fi
ln_pin=$(grep -n 'ical_pin_export' "${REPO}/scripts/box_walk_probes/run_box_walk.sh" | head -1 | cut -d: -f1)
ln_p1=$(grep -n 'PHASE 1 -- negative controls' "${REPO}/scripts/box_walk_probes/run_box_walk.sh" | head -1 | cut -d: -f1)
if [ -n "$ln_pin" ] && [ -n "$ln_p1" ] && [ "$ln_pin" -lt "$ln_p1" ]; then
    pass "the pin is exported before phase 1 (line $ln_pin < $ln_p1)"
else bad "pin export is not before phase 1 (pin=$ln_pin phase1=$ln_p1)"; fi
if grep -q 'export OSTLER_CUT_VERSION="${CUT_VERSION}"' "${REPO}/scripts/post_walk_qa.sh"; then
    pass "post_walk_qa.sh exports OSTLER_CUT_VERSION to the runner"
else bad "post_walk_qa.sh does not export OSTLER_CUT_VERSION"; fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: walk134 thin-walk probes, $(echo $PROBES | wc -w | tr -d ' ') probes, all checks held"; exit 0; fi
echo "FAIL: $fails check(s) failed"; exit 1
