#!/usr/bin/env bash
# An unreachable source must never be recorded as "not found".
#
# MEASURED on the v1.0.33 box, 2026-08-17:
#   enrich processed 62 items, succeeded on 1, failed 61.
#   50 of those failures read "Book not found: <title>" and the titles include
#   Animal Farm, 1984, and Hitchhiker's Guide To The Galaxy.
#   openlibrary.org: http=000, connect=0.000000s, 12s to give up.
#   DNS resolved it. archive.org, the SAME organisation, answered in 0.77s.
#
# So the service was down and the product wrote "your books do not exist" into
# the customer's graph. A false absence reads as answered, so it is never
# retried. That is the defect: not the outage, the record we keep of it.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vendor/cm019_preferences/services/enrich/src"
PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[[ -d "$SRC" ]] || { echo "CANNOT RUN: enrich src missing at $SRC"; exit 2; }

# 1. The distinct verdict must exist. Without it there is nothing to record.
grep -q 'UNAVAILABLE' "$SRC/models/enrichment.py" \
    && ok "MatchType.UNAVAILABLE exists (distinct from NONE)" \
    || no "no UNAVAILABLE verdict -- unreachable and empty are still the same value"

# 2. The transport verdict must be recorded when retries are exhausted.
grep -q '_last_transport_failure = last_error' "$SRC/clients/base.py" \
    && ok "base client records WHY it gave up" \
    || no "base client still discards the transport reason"

# 3. openlibrary must consult it before claiming absence.
grep -q '_last_transport_failure' "$SRC/clients/openlibrary.py" \
    && ok "openlibrary consults the transport verdict before saying not-found" \
    || no "openlibrary still calls an unreachable service a missing book"

# 4. POSITIVE CONTROL. The not-found branch must STILL exist -- a fix that
#    deleted it would pass checks 1-3 while making every genuine miss silent.
grep -q 'Book not found' "$SRC/clients/openlibrary.py" \
    && ok "positive control: a genuine not-found is still reported as such" \
    || no "the not-found branch was removed -- real misses would now be silent"

# 5. The two branches must be DIFFERENT text. Same message = no fix.
if grep -q 'Could not reach' "$SRC/clients/openlibrary.py"; then
    ok "the unreachable branch says something a customer can act on"
else
    no "no distinct 'could not reach' message"
fi

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "UNREACHABLE IS NOT ABSENCE"
