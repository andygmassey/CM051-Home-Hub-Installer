#!/usr/bin/env bash
# The walk record must say WHICH probes failed, not only how many.
#
# THE DEFECT. run_box_walk.sh already prints the failing probe names, under
# "FAILED:", "NOT MEASURED" and "BROKEN". post_walk_qa.sh ran it into
#
#     PROBE_LOG="$(mktemp)"
#     trap 'rm -f "$PROBE_LOG"' EXIT
#
# lifted only the four counts into walks/<version>.tsv, and deleted the log.
#
# So the record that GATES THE CUSTOMER DOWNLOAD said `fail 5` and nothing that
# could say which five. Measured 2026-08-26: walks/v1.0.44.tsv is the only walk
# record that has ever existed, it records fail=5 verdict=FAILED, and two days
# after that walk `fail 5` is the whole of what survives it. A finding with no
# name is not actionable, including by its own author a week later.
#
# WHAT THIS TEST DOES. It lifts section_names() out of post_walk_qa.sh and runs
# it against a synthetic log in run_box_walk.sh's exact shape, then checks the
# two ways the fix could rot:
#
#   - the parser silently stops matching (a header reworded, an indent changed)
#     and the record quietly returns to counts-with-no-names. That is the
#     original blindness, and it would look like a walk with nothing to report.
#     The record carries failed_probe_names_recorded "<n> of <count>" so the
#     mismatch is visible IN THE FILE.
#   - a line that is not a bare probe name gets published. A probe's stdout
#     carries paths and hostnames and this repo is PUBLIC, which is why box_fp
#     is a hash. Names only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="$REPO_ROOT/scripts/post_walk_qa.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

[[ -f "$QA" ]] || { echo "FAIL [qa-missing]: $QA not found -- nothing checked. NOT a pass." >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- lift section_names() out of the script under test --------------------
A=$(grep -n 'section_names() {' "$QA" | head -1 | cut -d: -f1)
if [[ -z "$A" ]]; then
    echo "FAIL [no-extractor]: post_walk_qa.sh has no section_names(); it is not recording probe names at all. NOT a pass." >&2
    exit 1
fi
B=$(awk -v a="$A" 'NR>a && /^    }$/{print NR; exit}' "$QA")
[[ -n "$B" ]] || { echo "FAIL [unterminated]: section_names() never closes." >&2; exit 2; }
{ echo 'PROBE_LOG="$1"'; sed -n "${A},${B}p" "$QA"; } > "$WORK/sn.sh"
bash -n "$WORK/sn.sh" || { echo "FAIL [extract-syntax]: lifted section_names does not parse." >&2; exit 2; }
pass "lifted section_names() from post_walk_qa.sh and it parses"

names() { bash -c 'source "$0" "$1"; section_names "$2"' "$WORK/sn.sh" "$1" "$2" | tr '\n' ' ' | sed 's/ *$//'; }

# ---- fixture in run_box_walk.sh's exact output shape ----------------------
cat > "$WORK/probe.log" <<'EOF'
============================================================
RESULT
  PASS        5
  FAIL        3
  CANNOT-RUN  2
  BROKEN      0
============================================================

FAILED:
  daemon_is_listening.sh
  people_count_agreement.sh
  no_unexpected_egress.sh

NOT MEASURED (prerequisite absent -- this is coverage lost, not a pass):
  fda_tick_can_import.sh
  ingest_coverage.sh

BROKEN (probe could not demonstrate a FAIL, so its result is not trusted):
  pair_state_agreement.sh
EOF

got="$(names "$WORK/probe.log" 'FAILED:')"
if [[ "$got" == "daemon_is_listening.sh people_count_agreement.sh no_unexpected_egress.sh" ]]; then
    pass "the three FAILED probe names are recovered, in order"
else
    fail "failed-names" "expected the three FAILED names, got '$got'"
fi

got="$(names "$WORK/probe.log" 'NOT MEASURED')"
if [[ "$got" == "fda_tick_can_import.sh ingest_coverage.sh" ]]; then
    pass "NOT MEASURED names are recovered (coverage lost is not coverage passed)"
else
    fail "notmeasured-names" "expected the two NOT MEASURED names, got '$got'"
fi

got="$(names "$WORK/probe.log" 'BROKEN (')"
if [[ "$got" == "pair_state_agreement.sh" ]]; then
    pass "BROKEN names are recovered"
else
    fail "broken-names" "expected the BROKEN name, got '$got'"
fi

# ---- a header that no longer matches must yield NOTHING -------------------
# It must not silently match something adjacent and report a wrong set.
got="$(names "$WORK/probe.log" 'FAILURES:')"
if [[ -z "$got" ]]; then
    pass "a header that does not exist yields nothing, so the count line exposes it"
else
    fail "phantom-section" "a non-existent header returned '$got'; the parser is matching something it should not"
fi

# ---- PUBLIC REPO: a line that is not a bare probe name must be dropped ----
cat > "$WORK/leak.log" <<'EOF'

FAILED:
  daemon_is_listening.sh
  ssh operator@198.51.100.7 refused the connection
EOF
got="$(names "$WORK/leak.log" 'FAILED:')"
if [[ "$got" == "daemon_is_listening.sh" ]]; then
    pass "a line carrying a host is dropped, not written into a public record"
elif [[ "$got" == *"@"* ]]; then
    fail "leak" "a host-bearing line reached the record: '$got'. walks/ is committed to a PUBLIC repo."
else
    fail "over-filter" "expected just the probe name, got '$got'"
fi

# ---- the record must actually carry the rows and the reconciliation -------
for k in 'failed_probe\\t' 'not_measured_probe\\t' 'broken_probe\\t' 'failed_probe_names_recorded\\t'; do
    if grep -q "$k" "$QA"; then
        pass "the record emits ${k%\\\\t}"
    else
        fail "row-missing" "post_walk_qa.sh never writes ${k%\\\\t}; names are parsed and then dropped"
    fi
done

[[ "$FAILED" -ne 0 ]] && exit 1
echo
echo "ALL WALK RECORD PROBE-NAME TESTS PASSED"
