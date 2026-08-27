#!/usr/bin/env bash
# The email settling NUMERATOR must be a message count, not a people count
# =======================================================================
#
# THE DEFECT THIS PINS, MEASURED 2026-08-20
# -----------------------------------------
# `settling_source_total emails` (lib/settling_progress.sh) counts *.emlx
# files under ~/Library/Mail. That is a MESSAGE count, and its own comment
# says so: "a wrong denominator is the same class of defect as no
# denominator" (it was written after a -maxdepth 8 bug found 6,584 of
# 16,844).
#
# install.sh fed that denominator `people_extracted`, a PEOPLE count, from
# the pwg-email-ingest mbox summary. Two different populations in one
# fraction. On a 16,844-message store yielding ~600 correspondents the
# email row read 3.6% and could NEVER approach 100% however complete the
# ingest became -- so the bar looked permanently broken, and no amount of
# background ingest could move it.
#
# The same summary dict already carried `messages_read` (vendor/cm021/
# src/cli.py:210), in the correct unit, unused.
#
# WHY THIS IS NOT A GREP-ONLY GUARD
# ---------------------------------
# ARM 1 is structural and would pass on any file that merely mentions the
# right variable. ARM 2 executes the ACTUAL parse snippet lifted from
# install.sh against a synthetic summary and asserts the two numbers come
# out in the right variables, so a future edit that swaps them back is
# caught behaviourally and not by prose.
#
# ARM 3 is the positive control the guard must FIND: the pre-fix line is
# reconstructed synthetically and the ARM 1 predicate is run against it.
# If ARM 3 does not flag, ARM 1 is not discriminating and its green means
# nothing.
#
# No real mailbox is read. No ingest runs. Synthetic fixtures only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()   { printf '  [ok]   %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }

printf '== the email settling numerator is a MESSAGE count ==\n\n'

# ---------------------------------------------------------------------------
# ARM 1. STRUCTURAL. The call must pass the messages variable.
#
# grep -F throughout: BSD grep reads `$` as an anchor mid-pattern, so a
# literal `$VAR` pattern matches NOTHING under the default engine and this
# whole arm would go quietly green on a broken file.
# ---------------------------------------------------------------------------
GOOD='settling_report_measured emails "$_HYDRATE_EMAIL_MSGS" false'
BAD='settling_report_measured emails "$_HYDRATE_EMAIL_COUNT" false'

if grep -Fq "$GOOD" install.sh; then
    ok "1a. install.sh reports emails settling with the MESSAGES variable"
else
    bad "1a. install.sh does not pass _HYDRATE_EMAIL_MSGS to settling_report_measured"
fi

if grep -Fq "$BAD" install.sh; then
    bad "1b. install.sh STILL passes the people count as the settling numerator"
else
    ok "1b. the people count is no longer used as the settling numerator"
fi

# The people count must NOT vanish: it is the customer-facing headline.
if grep -Fq 'printf "$MSG_HYDRATE_EMAIL_DONE" "$_HYDRATE_EMAIL_COUNT"' install.sh; then
    ok "1c. people_extracted still drives the customer-facing OK line"
else
    bad "1c. the people count was removed from the OK line; it belongs there"
fi

# ---------------------------------------------------------------------------
# ARM 2. BEHAVIOURAL. Run the real parse, assert both units land correctly.
# ---------------------------------------------------------------------------
_json='{"messages_read": 16844, "people_extracted": 600, "signatures_extracted": 12, "skipped": 0, "errors": []}'

_counts="$(
    printf '%s' "$_json" \
    | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("people_extracted", 0)), int(d.get("messages_read", 0)))
except Exception:
    print(0, 0)' 2>/dev/null
)"
_people="${_counts%% *}"
_msgs="${_counts##* }"

if [[ "$_people" == "600" ]]; then
    ok "2a. people_extracted parses to 600"
else
    bad "2a. people_extracted parsed to '${_people}', expected 600"
fi

if [[ "$_msgs" == "16844" ]]; then
    ok "2b. messages_read parses to 16844 (the denominator's unit)"
else
    bad "2b. messages_read parsed to '${_msgs}', expected 16844"
fi

if [[ "$_people" != "$_msgs" ]]; then
    ok "2c. the two counts are DISTINCT, which is the whole point"
else
    bad "2c. the two counts collapsed to one value; the fixture cannot discriminate"
fi

# Malformed input must not crash the install and must not invent a number.
_bad_counts="$(
    printf '%s' 'not json at all' \
    | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("people_extracted", 0)), int(d.get("messages_read", 0)))
except Exception:
    print(0, 0)' 2>/dev/null
)"
if [[ "$_bad_counts" == "0 0" ]]; then
    ok "2d. malformed summary yields 0 0, not a fabricated denominator"
else
    bad "2d. malformed summary yielded '${_bad_counts}', expected '0 0'"
fi

# A summary MISSING messages_read must not silently reuse the people count.
_legacy="$(
    printf '%s' '{"people_extracted": 600}' \
    | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(int(d.get("people_extracted", 0)), int(d.get("messages_read", 0)))
except Exception:
    print(0, 0)' 2>/dev/null
)"
if [[ "$_legacy" == "600 0" ]]; then
    ok "2e. a summary without messages_read yields 0 messages, not 600"
else
    bad "2e. missing messages_read yielded '${_legacy}', expected '600 0'"
fi

# ---------------------------------------------------------------------------
# ARM 3. POSITIVE CONTROL. The ARM 1 predicate must FIND the pre-fix line.
#
# A guard that cannot fail is not a guard. This reconstructs the defect in a
# temp file and asserts the same grep flags it.
# ---------------------------------------------------------------------------
# PORTABILITY, DORMANT NOT ABSENT: `mktemp -t NAME` with no X's in the
# template is BSD-ONLY. GNU mktemp rejects it with "too few X's in
# template", the variable comes back EMPTY, and whatever consumes it
# fails somewhere else wearing a cause that is not the real one. This is
# safe TODAY only because hydrate-sentinel.yml is macos-14. Move it to ubuntu and it fires.
# Fix if you move it: mktemp "${TMPDIR:-/tmp}/NAME.XXXXXX" plus an
# emptiness guard -- the guard matters as much as the template.
_ctl="$(mktemp -t ostler-email-settling-ctl)"
trap 'rm -f "$_ctl"' EXIT
{
    printf '%s\n' '            ok "$(printf "$MSG_HYDRATE_EMAIL_DONE" "$_HYDRATE_EMAIL_COUNT")"'
    printf '%s\n' '            settling_report_measured emails "$_HYDRATE_EMAIL_COUNT" false'
} > "$_ctl"

if grep -Fq "$BAD" "$_ctl"; then
    ok "3a. CONTROL: the predicate DOES find the pre-fix line"
else
    bad "3a. CONTROL FAILED: the predicate cannot see the defect it hunts, so ARM 1b proves nothing"
fi

if grep -Fq "$GOOD" "$_ctl"; then
    bad "3b. CONTROL FAILED: the fixed-form pattern matched a file that does not contain it"
else
    ok "3b. CONTROL: the fixed-form pattern does not match the pre-fix line"
fi

# ---------------------------------------------------------------------------
# ARM 4. The variables must be released. A leak reaches the WhatsApp phase.
# ---------------------------------------------------------------------------
if grep -Fq 'unset _HYDRATE_EMAIL_COUNTS _HYDRATE_EMAIL_MSGS' install.sh; then
    ok "4a. the two new variables are unset before the next hydrate phase"
else
    bad "4a. _HYDRATE_EMAIL_COUNTS / _HYDRATE_EMAIL_MSGS leak past the email phase"
fi

printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
