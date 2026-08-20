#!/usr/bin/env bash
# ============================================================================
# A STEP THAT RAN AND PRODUCED NOTHING MUST NOT RECORD status=ok (#2, #441)
#
# THE MECHANISM, read from install.sh rather than assumed:
#
#   _hydrate_sentinel_fresh requires a POSITIVE `^status=ok` and then treats
#   the source as done for SEVEN DAYS (604800s).
#
# So `status=ok payload=people=0` did three things at once: it claimed success,
# it was indistinguishable on disk from a step that delivered, and it
# suppressed its own retry for a week.
#
# MEASURED on the live v1.0.37 box 2026-08-20:
#   imessage          status=ok  people=0
#   ai_conversations  status=ok  written=0
# Nothing anywhere said "this produced nothing". The marker, the STEP_END line
# and Doctor all read as success -- the same green as "6,719 people indexed".
#
# WHY THIS TEST DRIVES THE REAL FUNCTION
#
# The tempting check is a grep over the ten call sites. That measures the
# CALLERS, and the rule lives in the RECORDER -- one place, so it cannot drift
# across ten. A call-site grep would also have to be re-taught every time a
# source is added, which is precisely how #681's two dark sources survived.
#
# So this sources install.sh's recorder functions into a harness and exercises
# them against a temp sentinel dir, then reads what actually landed on disk.
#
# THE RULE, in three states:
#   payload has a non-zero counter   -> status=ok
#   all counters zero + reason given -> status=no_data detail=<reason>
#   all counters zero, no reason     -> status=no_data detail=zero_payload_undeclared
#
# no_data and NOT error, deliberately: the step did not fail, it completed and
# found nothing, which for a customer with no WhatsApp is correct. Recording
# error would paint a healthy install red, and permanent false reds teach
# people that red means nothing.
#
# Non-zero = BLOCK THE CUT. A source that silently reports success while
# delivering nothing is the failure this whole area exists to remove.
#
# Exit: 0 rule holds | 1 rule broken | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"

pass=0; fail=0
ok()     { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note()   { printf '        %s\n' "$1"; }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

[ -r "$INSTALL" ] || cannot "install.sh not readable at ${INSTALL}"

echo "== #2: status=ok with a zero payload is not ok =="

WORK=""
cleanup() { [ -n "${WORK}" ] && rm -rf "${WORK}"; return 0; }
trap cleanup EXIT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-zeropayload-XXXXXX")" || cannot "could not create a work directory"

# ── EXTRACT THE RECORDER, do not reimplement it. ────────────────────────
# A reimplementation would test this file's idea of the rule, not the shipped
# one -- and would pass forever after install.sh diverged.
awk '
    /^_hydrate_payload_is_all_zero\(\) \{/ { grab = 1 }
    /^_hydrate_sentinel_record\(\) \{/     { grab = 1 }
    grab { print }
    grab && /^\}/                          { grab = 0 }
' "$INSTALL" > "${WORK}/recorder.sh"

_fn_count="$(grep -c '^_hydrate_[a-z_]*() {' "${WORK}/recorder.sh" || true)"
if [ "${_fn_count:-0}" -ne 2 ]; then
    cannot "extracted ${_fn_count:-0} recorder function(s), expected 2 (_hydrate_payload_is_all_zero + _hydrate_sentinel_record). They moved or were renamed, and every verdict below would be about the wrong code."
fi
note "extracted 2 recorder functions from install.sh"

# ── PREMISE: the freshness gate really does lock out on status=ok. ──────
# If it stopped doing that, the defect would no longer be a week-long outage
# and this test's stated stakes would be wrong.
if grep -q "grep -q '\^status=ok'" "$INSTALL" && grep -q '604800' "$INSTALL"; then
    ok "premise: _hydrate_sentinel_fresh still gates on ^status=ok with a 604800s window"
else
    bad "PREMISE GONE: install.sh no longer gates freshness on ^status=ok and/or the 7-day window moved. Re-read the mechanism before trusting anything below."
    finish
fi

mkdir -p "${WORK}/state"
cat > "${WORK}/harness.sh" <<HARNESS
set -uo pipefail
_HYDRATE_SENTINEL_DIR="${WORK}/state"
. "${WORK}/recorder.sh"
HARNESS

# record <source> <payload> [reason]  -> echoes the resulting file
_record() {
    local src="$1" payload="$2" reason="${3:-}"
    ( . "${WORK}/harness.sh"
      _hydrate_sentinel_record "$src" "$payload" "$reason" ) >/dev/null 2>&1
    cat "${WORK}/state/${src}.done" 2>/dev/null
}
_field() { grep -m1 "^$2=" <<< "$1" | cut -d= -f2-; }

# ── 1. A REAL DELIVERY IS STILL ok. ────────────────────────────────────
# First, because a rule that reds a healthy install is worse than the defect.
out="$(_record delivered "people=6719")"
if [ "$(_field "$out" status)" = "ok" ]; then
    ok "a non-zero payload still records status=ok (people=6719)"
else
    bad "REGRESSION: a real delivery no longer records ok -- got status=$(_field "$out" status). This rule would red every healthy install."
fi

# ── 2. THE DEFECT: all-zero must NOT be ok. ────────────────────────────
out="$(_record undeclared "people=0")"
st="$(_field "$out" status)"
if [ "$st" = "ok" ]; then
    bad "THE DEFECT IS PRESENT: 'people=0' recorded status=ok. The source is now suppressed for 7 days and every diagnostic reads as success."
elif [ "$st" = "no_data" ]; then
    ok "all-zero payload records status=no_data, not ok (people=0)"
else
    bad "all-zero payload recorded an unexpected status '${st}' -- expected no_data"
fi

if [ "$(_field "$out" detail)" = "zero_payload_undeclared" ]; then
    ok "an UNDECLARED zero is marked as such (detail=zero_payload_undeclared)"
else
    bad "an undeclared zero did not carry detail=zero_payload_undeclared, got '$(_field "$out" detail)'. Undeclared and declared zeros would print identically, which is the defect one layer up."
fi

# The payload must survive: the count is the evidence.
if [ "$(_field "$out" payload)" = "people=0" ]; then
    ok "the zero payload is retained on disk as evidence"
else
    bad "the payload was dropped from the no_data record, so nothing on disk says WHAT was zero"
fi

# ── 3. A DECLARED zero is distinguishable from an undeclared one. ──────
out="$(_record declared "written=0" "drain_completed_no_conversations")"
if [ "$(_field "$out" status)" = "no_data" ] && [ "$(_field "$out" detail)" = "drain_completed_no_conversations" ]; then
    ok "a DECLARED zero carries its stated reason (detail=drain_completed_no_conversations)"
else
    bad "a declared zero did not carry its reason: status=$(_field "$out" status) detail=$(_field "$out" detail)"
fi

# ── 4. A SUCCESSFUL NO-OP IS NOT AN EMPTY ONE. ────────────────────────
# sent=0,skipped=500 means the input WAS examined and 500 rows were already
# present. Treating that as no_data would retry a completed job forever.
out="$(_record noop "sent=0,skipped=500")"
if [ "$(_field "$out" status)" = "ok" ]; then
    ok "a mixed payload with one non-zero counter stays ok (sent=0,skipped=500)"
else
    bad "OVER-FIRED: 'sent=0,skipped=500' recorded status=$(_field "$out" status). A successful no-op would retry forever."
fi

# ran=1,rc=0 -- the places/privacy_backfill shape. ran=1 is real evidence.
out="$(_record ran "ran=1,rc=0")"
if [ "$(_field "$out" status)" = "ok" ]; then
    ok "the ran=1,rc=0 shape stays ok (places / privacy_backfill)"
else
    bad "OVER-FIRED on 'ran=1,rc=0' -> status=$(_field "$out" status). places and privacy_backfill would retry every run."
fi

# ── 5. NON-NUMERIC PAYLOADS ARE NOT GUESSED ABOUT. ────────────────────
# The predicate reads counters. Given none, it must not invent a verdict.
out="$(_record nonnumeric "status=no_app")"
if [ "$(_field "$out" status)" = "ok" ]; then
    ok "a payload with no numeric counters is left alone (status=no_app -> ok)"
else
    bad "the predicate guessed about a payload it cannot read: 'status=no_app' -> status=$(_field "$out" status)"
fi

# ── 6. AND THE RESULT MUST ACTUALLY BE STALE TO THE FRESHNESS GATE. ───
# This is the limb that makes the fix mean something. A no_data record that
# still satisfied `^status=ok` would change the words on disk and nothing else.
out="$(_record staleness "people=0")"
if grep -q '^status=ok' <<< "$out"; then
    bad "THE FIX IS COSMETIC: the no_data record still matches ^status=ok, so _hydrate_sentinel_fresh will treat it as done and suppress the retry for 7 days anyway."
else
    ok "the no_data record does NOT match ^status=ok, so the freshness gate treats it as stale and the source retries"
fi

# ── 7. ANTI-VACUITY: prove the harness can observe the defect. ────────
# Drive the SAME harness with a pre-fix recorder. If the old one also reads as
# compliant, this file is measuring nothing.
cat > "${WORK}/old_recorder.sh" <<'OLD'
_hydrate_sentinel_record() {
    local source="$1"
    local payload="${2:-}"
    local sentinel="${_HYDRATE_SENTINEL_DIR}/${source}.done"
    {
        printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'source=%s\n' "$source"
        printf 'status=ok\n'
        if [[ -n "$payload" ]]; then
            printf 'payload=%s\n' "$payload"
        fi
    } > "$sentinel"
}
OLD
( set -uo pipefail
  _HYDRATE_SENTINEL_DIR="${WORK}/state"
  . "${WORK}/old_recorder.sh"
  _hydrate_sentinel_record oldshape "people=0" ) >/dev/null 2>&1
if grep -q '^status=ok' "${WORK}/state/oldshape.done" 2>/dev/null; then
    ok "anti-vacuity: the pre-fix recorder DOES write status=ok for people=0, so this harness can see the defect"
else
    bad "ANTI-VACUITY FAILED: the pre-fix recorder did not produce status=ok in this harness. The passes above prove nothing -- the harness is not exercising what it claims to."
fi

finish
