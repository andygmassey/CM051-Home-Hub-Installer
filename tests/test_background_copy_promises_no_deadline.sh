#!/usr/bin/env bash
# ============================================================================
# test_background_copy_promises_no_deadline.sh -- the installer must not tell a
# customer WHEN background loading will finish, because it does not know.
#
# THE DEFECT (#782, re-scoped 2026-08-19)
#
# Five hydrate messages said "your wiki will fill in over the next hour" and
# three said "shortly". Measured on a real box the same day (#789):
#
#     email conversations on disk   4,444
#     ingested after 25.7 hours       154   =  3.5%
#     drain rate                     ~6.0 / hour
#     time to clear the backlog      ~30 DAYS, and mail keeps arriving
#
# An hour is wrong by roughly two orders of magnitude. This is not a tone
# problem: it is a false statement made to a paying customer at the exact
# moment they are deciding whether the product works.
#
# ============================================================================
# THE PREMISE OF #782 WAS RE-MEASURED AND HALF OF IT WAS WRONG
# ============================================================================
#
# #782 originally said background work does not continue AT ALL. That was
# measured before #784. It is now false in the customer's favour and stating
# it would be its own error:
#
#   - the four bundle ticks recur under the daemon's source scheduler and
#     dispatch to CM048 (email 14 dispatch refs, whatsapp/spoken/imessage 13
#     each), and .224 shows them actively processing
#   - #784 (CM051 #864) fixed the FDA half, which really was install-only
#
# So "still loading in the background" is TRUE and stays. What was false, and
# what this gate protects, is the DEADLINE attached to it. Fixing the wrong
# half would have deleted an accurate reassurance and left the lie.
#
# ============================================================================
# WHY THE SCOPE IS THE BACKGROUND-CONTINUES CLASS, NOT THE WHOLE CATALOGUE
# ============================================================================
#
# A catalogue-wide ban on time words would be wrong and would rot. The
# installer legitimately says things like "ingest will pick them up on the next
# hourly tick" -- that is a statement about a SCHEDULE we control and it is
# true. The defect is specific: a message that says work is CONTINUING must not
# also say when it will be DONE.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
# ============================================================================
set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

PASS=0
FAIL=0

cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$STRINGS" ]] || cannot_run "strings catalogue not found at $STRINGS"

# The class under test. Extracted from the shipping catalogue, never listed by
# hand: a hardcoded key list silently stops covering the message added tomorrow,
# which is the shape that let this ship in the first place.
CLASS="$(grep -E '^MSG_[A-Z0-9_]*BACKGROUND_CONTINUES=' "$STRINGS" || true)"

[[ -n "$CLASS" ]] || cannot_run \
    "no *BACKGROUND_CONTINUES keys found in the catalogue. Either they were renamed -- in which case this gate now guards nothing and must be repointed -- or the file moved. Refusing rather than reporting clean."

COUNT="$(printf '%s\n' "$CLASS" | wc -l | tr -d ' ')"

# A floor, so that deleting the messages is not a way to pass. #782 was about
# eight of them; fewer than eight means someone removed coverage rather than
# corrected copy, and that deserves a look.
FLOOR=8

echo "background-continues copy (catalogue: $STRINGS)"
echo "  examined ${COUNT} message(s)"

# (1) THE DEFECT. No message in this class may state a completion time.
#     Deliberately case-insensitive and listing the whole family rather than
#     just the phrase that shipped: "over the next hour" was the instance,
#     "we know when this finishes" is the class.
c1() {
    local hits
    hits="$(printf '%s\n' "$CLASS" | grep -inE \
        'next hour|an hour|in [0-9]+ (minute|hour|day)|within (an?|[0-9]+) |a few (minutes|hours)|shortly|any (minute|moment)|momentarily' || true)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" | sed 's/^/         /' >&2
        return 1
    fi
    return 0
}

# (2) FLOOR. Coverage cannot shrink to nothing and still report clean.
c2() { [[ "$COUNT" -ge "$FLOOR" ]]; }

# (3) The reassurance itself must SURVIVE. Deleting "work continues in the
#     background" would pass (1) trivially while making the product look
#     broken -- and it is TRUE, per the re-measurement in the header. A gate
#     that can be satisfied by removing accurate information is a bad gate.
#
#     🔴 THE PREDICATE IS "in the background", NOT a list of opening verbs.
#     The first version matched `still (loading|being indexed)` and went RED
#     against origin/main on the PEOPLE line -- which reads "Still indexing
#     your people in the background" and carries the reassurance perfectly
#     well. That is a control failing on SPELLING while the property holds:
#     red-while-fixed, the mirror of the green-while-blind failures this suite
#     exists to stop. The property is the phrase that tells a customer the work
#     is ongoing, and every message in the class carries it.
c3() {
    local n
    n="$(printf '%s\n' "$CLASS" | grep -ci 'in the background' || true)"
    [[ "$n" -eq "$COUNT" ]]
}

# (4) ANTI-VACUITY. Prove control (1) can actually fire, using the exact string
#     that shipped. Without this, (1) passing tells you nothing about whether
#     it is capable of failing.
c4() {
    local probe
    probe='MSG_HYDRATE_FAKE_BACKGROUND_CONTINUES="Email is still loading in the background – your wiki will fill in over the next hour."'
    printf '%s\n' "$probe" | grep -qiE \
        'next hour|an hour|in [0-9]+ (minute|hour|day)|within (an?|[0-9]+) |a few (minutes|hours)|shortly|any (minute|moment)|momentarily'
}

if c1; then pass "no message states a completion time"
       else failure "a message in this class promises WHEN background work finishes. Measured reality (#789): email is 3.5% done after 26 hours and needs ~30 days. The lines above are the offenders."; fi
if c2; then pass "coverage floor holds (${COUNT} >= ${FLOOR})"
       else failure "only ${COUNT} message(s) in this class, floor is ${FLOOR}. Copy was deleted rather than corrected; this gate now guards less than it did."; fi
if c3; then pass "every message still says work is CONTINUING (the true half)"
       else failure "a message dropped the 'still loading' reassurance. That half is TRUE -- the bundle ticks do recur -- and removing it is not the fix."; fi
if c4; then pass "ANTI-VACUITY: the predicate fires on the exact string that shipped"
       else failure "the deadline predicate does NOT match the string this gate exists to ban. It is measuring nothing."; fi

echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} of $((PASS + FAIL)) controls"
    exit 1
fi
echo "PASSED: ${PASS} of ${PASS} controls"
exit 0
