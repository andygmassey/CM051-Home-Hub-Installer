#!/usr/bin/env bash
# verify_pr_age.sh must read `review_by: 2026-10-24  # note` as 2026-10-24.
#
# Measured 2026-10-18 on the CM051#1818 row: the parser kept the comment in
# the value. BSD `date -j -f` then warned and read the leading date (valid);
# GNU `date -d` refused the whole string (undated). One row, two verdicts,
# depending on the host. This test pins the parsed VALUE, so it is host-free.
#
# Arm 1: a synthetic deferrals file with the inline-comment shape.
# Arm 2: every NON-EMPTY review_by in the real cut-deferrals.yaml parses to a
#        bare YYYY-MM-DD (denominator printed, and must be non-zero). Empty
#        values are rows of later sections the parser also reads (it scans to
#        EOF) and the gate already grades a missing date as "undated".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="${GATE:-${ROOT}/scripts/verify_pr_age.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fn="$(sed -n '/^exempt_entries()/,/^}/p' "$GATE")"
[[ -n "$fn" ]] || { echo "CANNOT-RUN: exempt_entries() not found in $GATE"; exit 2; }

parse() { DEFERRALS="$1" bash -c "$fn"$'\n'"exempt_entries"; }

cat > "${TMP}/d.yaml" <<'YAML'
pr_exemptions:
  - ref: "Repo#1"
    reason: "plain"
    review_by: 2026-10-24
  - ref: "Repo#2"
    reason: "inline comment"
    review_by: 2026-10-25  # re-dated, see note
  - ref: "Repo#3"
    reason: "quoted with comment"
    review_by: "2026-10-26"   # quoted
YAML

got="$(parse "${TMP}/d.yaml")"
want=$'Repo#1\t2026-10-24\nRepo#2\t2026-10-25\nRepo#3\t2026-10-26'
if [[ "$got" != "$want" ]]; then
    echo "FAIL arm 1: parsed exemptions differ"
    echo "--- want"; printf '%s\n' "$want"
    echo "--- got";  printf '%s\n' "$got"
    exit 1
fi
echo "PASS arm 1: 3 of 3 synthetic review_by values parsed to a bare date"

real="$(parse "${ROOT}/cut-deferrals.yaml")"
total=0; bad=0
while IFS=$'\t' read -r ref rev; do
    [[ -n "$ref" && -n "$rev" ]] || continue
    total=$((total + 1))
    if ! [[ "$rev" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        bad=$((bad + 1)); echo "  bad: ${ref} -> '${rev}'"
    fi
done <<< "$real"
[[ "$total" -gt 0 ]] || { echo "CANNOT-RUN arm 2: 0 dated exemptions parsed from cut-deferrals.yaml"; exit 2; }
if [[ "$bad" -gt 0 ]]; then
    echo "FAIL arm 2: ${bad} of ${total} dated review_by values are not a bare date"
    exit 1
fi
echo "PASS arm 2: ${total} of ${total} dated review_by values are a bare date"
