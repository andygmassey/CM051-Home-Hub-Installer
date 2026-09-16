#!/usr/bin/env bash
# Every OSTLER_CONSENT_*_DECISION that the installer SETS must also be RECORDED.
#
# WHY THIS EXISTS, three times over. install.sh has now grown the same defect
# three separate times: an answer the customer gives is assigned to a shell
# variable, a comment says it is recorded so the Doctor can report it, and
# nothing records it. The variable dies with the installer process.
#
#   1. OSTLER_CONSENT_ENRICHMENT_DECISION (#794) -- an `export` under a comment
#      claiming the Doctor and a support bundle could state what was chosen.
#   2. OSTLER_CONSENT_PERSONAL_USE_DECISION -- a LICENCE TERM, acknowledged by
#      the customer, with exactly one use in the whole file: its own assignment.
#   3. the shape generally, which is this week's defect class across the estate:
#      a producer built with no consumer.
#
# A reviewer cannot catch this by reading a diff, because the assignment looks
# complete on its own. Only counting the uses shows it. So this counts them.
#
# THE RULE: if a decision variable is assigned a non-empty literal anywhere,
# its tickbox must appear in a _consent_cli_record call. Hoisted empty defaults
# (VAR="") are declarations, not answers, and do not trigger the requirement.
set -euo pipefail
cd "$(dirname "$0")/.."
F=install.sh
FAIL=0; PASS=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# Decision variables that are given a real answer, not just declared empty.
answered=$(/usr/bin/grep -oE 'OSTLER_CONSENT_[A-Z0-9_]+_DECISION="[a-z]+"' "$F" \
           | /usr/bin/grep -v '=""' | sed 's/=.*//' | sort -u)

if [ -z "$answered" ]; then
  echo "  [CANNOT-RUN] no answered consent decision variables found in $F."
  echo "               Either the file moved or this pattern stopped matching."
  echo "               A zero here is NOT a pass: it is the predicate failing."
  exit 2
fi
echo "  denominator: $(printf '%s\n' "$answered" | /usr/bin/grep -c .) answered decision variable(s)"

for v in $answered; do
  uses=$(/usr/bin/grep -c "$v" "$F")
  # The record site reads the variable inside a _consent_cli_record call, which
  # is always within a few lines of the tickbox name. Read the whole file and
  # ask whether this variable is ever passed to that recorder.
  if awk -v v="$v" '
        /_consent_cli_record/ { win = 8 }
        win > 0 { buf = buf $0 "\n"; win-- }
        END { exit (index(buf, v) ? 0 : 1) }' "$F"; then
    ok "$v is recorded ($uses uses in the file)"
  else
    bad "$v is SET and NEVER RECORDED ($uses use(s) in the file, and none of
         them is a _consent_cli_record call). The customer answers, the answer
         dies with the process, and the Doctor reports nothing. This is the
         exact shape of #794."
  fi
done

# POSITIVE CONTROL. The check must be able to fail, or a passing run means
# nothing. Run the same predicate against a variable that is deliberately
# never recorded, and require a FAIL.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{ cat "$F"; echo 'OSTLER_CONSENT_CONTROL_NEVER_RECORDED_DECISION="accepted"'; } > "$tmp"
if awk -v v="OSTLER_CONSENT_CONTROL_NEVER_RECORDED_DECISION" '
      /_consent_cli_record/ { win = 8 }
      win > 0 { buf = buf $0 "\n"; win-- }
      END { exit (index(buf, v) ? 0 : 1) }' "$tmp"; then
  bad "CONTROL FAILED: a variable that is set and never recorded was reported
       as recorded, so every PASS above is meaningless."
else
  ok "CONTROL: a set-but-never-recorded variable is correctly caught"
fi

printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
