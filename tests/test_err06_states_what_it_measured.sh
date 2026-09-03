#!/usr/bin/env bash
#
# tests/test_err06_states_what_it_measured.sh
#
# #566 -- ERR-06-STORE-AUTH-LEAK ASSERTS A CAUSE IT CANNOT ESTABLISH.
#
# THE FACTS, measured on origin/main a83dc112 before this test was written:
#
#   the probe   curl "${_OSTLER_STORE_CURL_ARGS[@]...}" -sf -m 5 .../collections
#   its comment "the shipped client fleet is keyless, so an AUTH-REQUIRING
#                Qdrant endpoint MUST answer WITHOUT a credential here"
#   its message "...which means a store credential from an earlier setup was
#                left active. Re-run the installer..."
#
# THE COMMENT REASONS ABOUT A BARE PROBE. THE CODE SENDS THE CREDENTIAL.
# That was true in v1.0.10, when the shipped fleet really was keyless and a 401
# really did mean a leak. CM051 #1222 flipped store-auth enforcement to default
# ON, so the fleet is no longer keyless and the probe now carries a credential.
# The premise inverted underneath the guard and the guard kept its old meaning.
#
# WHAT THE PROBE ACTUALLY KNOWS when it fails: an AUTHENTICATED request did not
# succeed. That has several causes -- a leaked credential is ONE of them. The
# message picks that one, states it as fact, and prescribes clearing a
# credential that Archie MEASURED on the failing box to be correct and
# complete (both header names present, /collections 200 when replayed with the
# very same -K file).
#
# WHY THAT IS WORSE THAN A BARE FAILURE: re-running often succeeds, so the
# false diagnosis is CONFIRMED by the remedy. A wrong explanation that appears
# to work is very hard to dislodge, and we never hear about it.
#
# ⚠️ THIS TEST DOES NOT GUARD THE ABORT ITSELF. Fresh installs still fail.
# Two further fixes are HELD pending a cold-first-create measurement: moving
# the credentialed probe into the readiness loop, and making this path no more
# fatal than the warn-and-continue branch that already exists one line below
# for "the store never became ready at all". Neither is in scope here.
#
# WHAT THIS ASSERTS, AND WHY IT IS SHAPED THIS WAY
# ------------------------------------------------
# A test that PINS PROSE rots on the first copy edit and teaches people to
# edit tests to match code. So this does the opposite:
#
#   1 STRUCTURAL   the ERR-06 probe CARRIES the credential array. This is the
#                  fact that makes the old comment false, and it is the
#                  premise the other arms rest on. If someone later makes the
#                  probe bare, this arm fails and tells them the reasoning
#                  above it has to change too.
#   2 CONTRADICTION  IF the probe is credentialed THEN its comment must not
#                  claim the endpoint answers WITHOUT a credential. This is a
#                  consistency check between two things in the same file, not
#                  a spelling test -- the #563 class, caught structurally.
#   3 FORBID THE LIE  the message must not reassert the specific false cause
#                  that shipped. It FORBIDS THE OLD SENTENCE rather than
#                  pinning a new one: reword freely, just never reintroduce
#                  the claim that a stale credential is the known cause.
#   4 MUTATION     the PINNED pre-fix message must FAIL arm 3, or arm 3 is
#                  not measuring anything.
#
# EXIT CODES -- A HARNESS PROBLEM IS NOT A PRODUCT DEFECT
#   0  every arm held
#   1  the guard misbehaved                       (evidence of badness)
#   2  the harness could not run: anchors missing (absence of evidence)
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
cannot_run() {
    printf '\n[err06-harness] CANNOT-RUN: %s\n' "$1" >&2
    cat >&2 <<'MSG'

  This is a HARNESS failure, not a product defect. Nothing about the ERR-06
  guard has been measured -- do not read this as the guard being correct, and
  do not go and debug install.sh on the strength of this line.
MSG
    exit 2
}

echo
echo "=== #566: ERR-06 must state what it measured, not a cause it cannot establish ==="
echo

[[ -r "$INSTALL_SCRIPT" ]] || cannot_run "install.sh is not readable at ${INSTALL_SCRIPT}"
[[ -r "$STRINGS" ]]        || cannot_run "the en-GB string catalogue is not readable at ${STRINGS}"

# ── LOCATE BY ANCHOR, NEVER BY LINE NUMBER ──────────────────────────────────
#
# 🔴 THE ORIGINAL ANCHOR WAS `fail_with_code "ERR-06-STORE-AUTH-LEAK"` AND THIS
# PR DELETES IT ON PURPOSE. The self-termination is the defect being fixed, so
# anchoring on it made the harness permanently CANNOT-RUN the moment the fix
# landed -- a guard that can never obtain a verdict is a dark guard, and it
# refused correctly rather than passing, which is #1239's rule working.
#
# The ERR-06 estate did not disappear; it changed shape. It is now bounded by
# the readiness state variable at the top and the tidy-up `unset` at the
# bottom, and it still contains the probe, the comment block and the
# diagnostic. Both bounds are asserted unique below, so a rename cannot let
# this file silently measure the wrong region.
START_ANCHOR='_qdrant_ready=false'
END_ANCHOR='unset _qdrant_url _qdrant_ready'

n_start="$(grep -cF -- "$START_ANCHOR" "$INSTALL_SCRIPT")"
[[ "$n_start" -eq 1 ]] || cannot_run "the ERR-06 region START anchor matched ${n_start} times, expected exactly 1"
n_end="$(grep -cF -- "$END_ANCHOR" "$INSTALL_SCRIPT")"
[[ "$n_end" -eq 1 ]] || cannot_run "the ERR-06 region END anchor matched ${n_end} times, expected exactly 1"

START_LINE="$(grep -nF -- "$START_ANCHOR" "$INSTALL_SCRIPT" | cut -d: -f1)"
END_LINE="$(grep -nF -- "$END_ANCHOR" "$INSTALL_SCRIPT" | cut -d: -f1)"
[[ "$START_LINE" -lt "$END_LINE" ]] \
    || cannot_run "the ERR-06 region bounds are inverted (start ${START_LINE}, end ${END_LINE}); the region cannot be extracted"

n_msg="$(grep -cE '^MSG_FAIL_STORE_AUTH_LEAK=' "$STRINGS")"
[[ "$n_msg" -eq 1 ]] || cannot_run "MSG_FAIL_STORE_AUTH_LEAK is defined ${n_msg} times in the catalogue, expected exactly 1"

REGION="$(awk -v s="$START_LINE" -v e="$END_LINE" 'NR>=s && NR<=e' "$INSTALL_SCRIPT")"

# Three independent facts must be inside the region, or it is the wrong one.
# Any single one of these could be true of a neighbouring block; all three
# together can only be the ERR-06 estate.
[[ "$(printf '%s\n' "$REGION" | grep -cF '/collections')" -gt 0 ]] \
    || cannot_run "the extracted region does not mention /collections; wrong region"
[[ "$(printf '%s\n' "$REGION" | grep -cF 'ERR-06-STORE-AUTH-LEAK')" -gt 0 ]] \
    || cannot_run "the extracted region does not mention ERR-06-STORE-AUTH-LEAK; wrong region, or the greppable support token has been deleted"
[[ "$(printf '%s\n' "$REGION" | grep -cF '_OSTLER_STORE_CURL_ARGS')" -gt 0 ]] \
    || cannot_run "the extracted region contains no credentialed curl at all; wrong region"
ok "CANNOT-RUN checks: both ERR-06 region bounds are unique, the message key is unique, region is the right one"

# ── ARM 1: STRUCTURAL. The READINESS probe carries the credential. ──────────
# Everything below rests on this. It is also the fact that inverted the
# premise: a credentialed probe's 401 is not evidence of a leak.
#
# 🔴 TWO TRAPS HERE, BOTH LIVE, AND THE FIRST ONE WOULD HAVE PASSED SILENTLY.
#
#  (a) SCOPE. The region now also contains the collection-CREATION curls in
#      the ready branch, and those carry the credential too. A predicate that
#      searched the whole region would have gone green while measuring the
#      wrong statement entirely: the readiness probe could go bare and this
#      arm would never notice. So arm 1 is scoped to the READINESS LOOP BODY,
#      not the region.
#
#  (b) LINE WRAPPING. The probe is now a `\`-continued statement: `curl` and
#      `_OSTLER_STORE_CURL_ARGS` sit on one line, the `/collections` URL on
#      the next. The old line-oriented `grep -F /collections | grep -F curl`
#      scored ZERO on it -- the same defect arm 2 already documents for the
#      comment, arriving from the other direction. Continuations are joined
#      first, and the join is PROVED by a control below.
LOOP_START="$(printf '%s\n' "$REGION" | grep -nF 'for _qdrant_attempt in' | cut -d: -f1)"
LOOP_END="$(printf '%s\n' "$REGION" | grep -nxF 'done' | head -1 | cut -d: -f1)"
if [[ -z "$LOOP_START" || -z "$LOOP_END" || "$LOOP_START" -ge "$LOOP_END" ]]; then
    cannot_run "could not bound the readiness loop inside the region (start '${LOOP_START}', end '${LOOP_END}'). Arm 1 has no subject."
fi
LOOP_BODY="$(printf '%s\n' "$REGION" | awk -v s="$LOOP_START" -v e="$LOOP_END" 'NR>=s && NR<=e')"

join_continuations() {
    awk '{
        line = $0
        while (line ~ /\\$/) {
            sub(/\\$/, "", line)
            if ((getline nxt) <= 0) break
            sub(/^[[:space:]]*/, "", nxt)
            line = line " " nxt
        }
        print line
    }'
}
LOOP_JOINED="$(printf '%s\n' "$LOOP_BODY" | join_continuations)"

# CONTROL FOR THE JOIN -- SYNTHETIC, NOT DERIVED FROM install.sh.
#
# ⚠️ MY FIRST CONTROL HERE WAS WRONG AND I CAUGHT IT BEFORE PUSHING. It asserted
# the probe was NOT findable without joining -- i.e. that the join was
# NECESSARY. But necessity is a property of how install.sh happens to be
# formatted today: un-wrap that curl onto one line, a perfectly good edit, and
# the harness would have refused with CANNOT-RUN over a change that broke
# nothing. A control must prove the MECHANISM works, not that the subject still
# needs it.
#
# So the join is proved against a fixture this file builds itself. It holds in
# every direction and no edit to install.sh can invalidate it.
_JOIN_FIXTURE="$(printf 'curl --arg \\\n    "http://x/collections" 2>/dev/null\nunrelated\n')"
_join_probe_raw="$(printf '%s\n' "$_JOIN_FIXTURE" | grep -F 'curl' | grep -cF '/collections')"
_join_probe_out="$(printf '%s\n' "$_JOIN_FIXTURE" | join_continuations | grep -F 'curl' | grep -cF '/collections')"
if [[ "$_join_probe_raw" -ne 0 ]]; then
    cannot_run "the synthetic join fixture is findable line-by-line BEFORE joining, so it cannot prove the join does anything. Arm 1 is unproven."
fi
if [[ "$_join_probe_out" -ne 1 ]]; then
    cannot_run "join_continuations did NOT join the synthetic fixture (${_join_probe_out} single-line matches, expected 1). The line-continuation join is broken, so arm 1 could report a bare probe on a credentialed one. No verdict."
fi

# ...and, separately, arm 1 must actually have a subject to measure.
n_joined_probe="$(printf '%s\n' "$LOOP_JOINED" | grep -F 'curl' | grep -cF '/collections')"
if [[ "$n_joined_probe" -lt 1 ]]; then
    cannot_run "the readiness loop holds no curl to /collections even after joining continuations. The probe has moved; arm 1 has nothing to measure."
fi

PROBE_LINES="$(printf '%s\n' "$LOOP_JOINED" | grep -F '/collections' | grep -F 'curl')"
n_probe_cred="$(printf '%s\n' "$PROBE_LINES" | grep -cF '_OSTLER_STORE_CURL_ARGS')"
n_probe_total="$(printf '%s\n' "$PROBE_LINES" | grep -cF 'curl')"
if [[ "$n_probe_total" -ge 1 && "$n_probe_cred" -ge 1 ]]; then
    ok "ARM 1 the READINESS probe CARRIES the credential (${n_probe_cred} of ${n_probe_total} /collections curls in the loop body, continuations joined)"
else
    bad "ARM 1 the READINESS probe does NOT carry the credential (${n_probe_cred} of ${n_probe_total}).
      If that is deliberate, the comment and the message both have to change
      with it: a BARE probe's 401 means something different from a
      CREDENTIALED probe's 401, and this guard's whole reasoning turns on
      which one it is."
fi

# ── ARM 2: CONTRADICTION. Code and comment must agree on the probe. ─────────
# Not a spelling test. The predicate is conditional: it only fires when the
# probe IS credentialed, which is exactly when the claim below is false.
#
# 🔴 THE COMMENT IS LINE-WRAPPED AND MY FIRST PREDICATE COULD NEVER HAVE FIRED.
# install.sh has "...MUST answer WITHOUT a" ending one line and "credential
# here." starting the next, so a line-oriented `grep -F 'WITHOUT a credential'`
# scores ZERO across the WHOLE FILE and arm 2 reported a vacuous green against
# the unfixed tree. A zero from a predicate that cannot return non-zero is not
# evidence. So the region is FLATTENED -- comment markers stripped, newlines
# collapsed to spaces -- before it is searched, and the flattening itself is
# proved by a control below.
REGION_FLAT="$(printf '%s\n' "$REGION" \
    | sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' \
    | tr '\n' ' ' | tr -s ' ')"

# POSITIVE CONTROL FOR THE FLATTENING, DERIVED AT RUNTIME AND NOT NAMED.
#
# 🔴 MY FIRST CONTROL HERE WAS A FIXED PHRASE FROM THE COMMENT ITSELF
# ('AUTH-REQUIRING'), AND THE FIX DELETED IT. The control lived inside the very
# text it was guarding, so rewriting the comment turned a working arm into
# CANNOT-RUN. A control an edit can destroy is not a control.
#
# So it is SYNTHESISED from whatever the region currently holds: take the last
# word of some line and the first word of the next, join them with a space, and
# require that the joined phrase is findable ONLY after flattening. That is
# exactly the capability arm 2 depends on -- seeing a claim that spans a line
# break -- and no rewording can delete it, because it is rebuilt from the text
# that is actually there.
FLATTEN_CONTROL="$(printf '%s\n' "$REGION" \
    | sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' \
    | awk 'NF>=2 {if (prev != "") {print prev, $1; exit} prev=$NF}')"
if [[ -z "$FLATTEN_CONTROL" ]]; then
    cannot_run "could not synthesise a line-spanning control from the ERR-06 region. Arm 2's flattening is unproven, so no verdict on the comment is available."
fi
if [[ "$(printf '%s\n' "$REGION_FLAT" | grep -cF -- "$FLATTEN_CONTROL")" -eq 0 ]]; then
    cannot_run "the synthesised line-spanning control is NOT findable in the flattened region. The flattening is broken, so arm 2 cannot discriminate and no verdict on the comment is available."
fi
# ...and the same phrase must NOT be findable line-by-line, or the "control"
# proves nothing about flattening -- it would pass on an unflattened region too.
if [[ "$(printf '%s\n' "$REGION" | grep -cF -- "$FLATTEN_CONTROL")" -gt 0 ]]; then
    cannot_run "the synthesised control is findable WITHOUT flattening, so it does not prove the flattening works. Arm 2 is unproven."
fi

CONTRADICTION='WITHOUT a credential'
n_contra="$(printf '%s\n' "$REGION_FLAT" | grep -cF -- "$CONTRADICTION")"
if [[ "$n_probe_cred" -ge 1 && "$n_contra" -ge 1 ]]; then
    bad "ARM 2 THE CODE CONTRADICTS ITS OWN COMMENT. The probe sends the
      credential, and the comment above it still says the endpoint 'MUST answer
      ${CONTRADICTION} here'. A reader who trusts the comment never checks what
      the probe actually sends -- which is how this survived #1222 flipping
      enforcement ON underneath it. This is the #563 shape."
else
    ok "ARM 2 no contradiction: the comment does not claim a credential-free probe (${n_contra} hits)"
fi

# ── ARM 3: FORBID THE LIE, DO NOT PIN THE REPLACEMENT ───────────────────────
# Each fragment is a CLAIM the probe cannot establish, not a turn of phrase.
# Reword the message however you like; you may not reassert these.
MSG_VALUE="$(grep -E '^MSG_FAIL_STORE_AUTH_LEAK=' "$STRINGS" | cut -d= -f2-)"
forbidden_hits=0
while IFS= read -r frag; do
    [[ -z "$frag" ]] && continue
    if [[ "$(printf '%s\n' "$MSG_VALUE" | grep -cF -- "$frag")" -gt 0 ]]; then
        bad "ARM 3 the message still asserts a cause it cannot establish: \"${frag}\".
      What the probe knows is that an AUTHENTICATED request did not succeed.
      A stale credential is ONE cause. Archie measured the credential on the
      failing box to be correct and complete, and this fired anyway."
        forbidden_hits=$((forbidden_hits+1))
    fi
done <<'FORBIDDEN'
which means a store credential from an earlier setup was left active
it now clears any stale store credentials automatically
FORBIDDEN
[[ "$forbidden_hits" -eq 0 ]] && ok "ARM 3 the message asserts no cause the probe cannot establish (0 of 2 forbidden claims)"

# ── ARM 4: MUTATION -- the pinned pre-fix message must FAIL arm 3 ───────────
# PINNED, NOT DERIVED. A baseline computed from the file under test moves when
# the file moves and then proves nothing.
read -r -d '' PRE_FIX_MSG <<'PINNED' || true
The knowledge-graph database is refusing unauthenticated connections, which means a store credential from an earlier setup was left active. Re-run the installer; it now clears any stale store credentials automatically before starting the databases.
PINNED
mutation_caught=0
while IFS= read -r frag; do
    [[ -z "$frag" ]] && continue
    if [[ "$(printf '%s\n' "$PRE_FIX_MSG" | grep -cF -- "$frag")" -gt 0 ]]; then
        mutation_caught=$((mutation_caught+1))
    fi
done <<'FORBIDDEN'
which means a store credential from an earlier setup was left active
it now clears any stale store credentials automatically
FORBIDDEN
if [[ "$mutation_caught" -ge 1 ]]; then
    ok "ARM 4 MUTATION -> the pinned pre-fix message trips ${mutation_caught} of 2 forbidden claims (arm 3 discriminates)"
else
    bad "ARM 4 MUTATION -> the PINNED PRE-FIX message trips NONE of the forbidden
      claims. Arm 3 therefore proves nothing: either the pinned fixture has
      drifted from the message that actually shipped, or the fragments no
      longer match it. Treat every other result in this file as unproven."
fi

# ── ARM 5: THE DIAGNOSTIC MAY NOT LEAD WITH THE CODE (#612) ────────────────
# Arms 1-4 govern the FATAL message. This governs the NON-FATAL diagnostic the
# customer reads on the not-ready path, and it is a different failure: not a
# false claim, an alarming ORDER.
#
# Seen live on the v1.0.60 walk. #566 made the message honest and deliberately
# KEPT the code token, which is correct: it is support-greppable and appears in
# logs customers have already sent. But the line still OPENED with it, so the
# first thing a customer read about a condition measured to be a readiness
# timeout was the word LEAK, in a product whose entire proposition is that
# their data stays put. The leak hypothesis was refuted by measurement.
#
# The rule is about POSITION, not vocabulary. The token must still be present
# (arm 3 of the sibling readiness test enforces that it survives at all); it
# simply may not be the opening of a customer-facing sentence.
DIAG_LINE="$(grep -F 'ERR-06-STORE-AUTH-LEAK diagnostic' "$INSTALL_SCRIPT" || printf '')"
n_diag="$(printf '%s\n' "$DIAG_LINE" | grep -c 'ERR-06' || printf '0')"
if [[ -z "$DIAG_LINE" ]]; then
    cannot_run "the ERR-06 diagnostic line is not present in install.sh at all; wrong file, or the greppable anchor has been deleted"
elif [[ "$n_diag" -ne 1 ]]; then
    # A grep -F anchor that matches a COMMENT as well as its statement has
    # silently doubled its match set, and every assertion below would then be
    # measuring an accidental union of two lines.
    cannot_run "the anchor matches ${n_diag} lines, expected exactly 1; a comment or a second emit site has joined the match set"
else
    DIAG_MSG="$(printf '%s\n' "$DIAG_LINE" | sed -E 's/^[[:space:]]*warn "//; s/"$//')"
    # grep -c, NOT the quiet flag, and deliberately so. A quiet grep on the
    # right of a pipe exits at the first match and SIGPIPEs its producer, which
    # under `set -o pipefail` can invert this very verdict. Counting forces a
    # read to EOF, so it cannot. The pipefail-shortcircuit ratchet caught my
    # first draft of this arm, in this file, on this PR.
    if [ "$(printf '%s' "$DIAG_MSG" | grep -cE '^ERR-|^[A-Z0-9-]*LEAK')" -gt 0 ]; then
        bad "ARM 5 the non-fatal diagnostic still OPENS with the error code:
      \"$(printf '%s' "$DIAG_MSG" | cut -c1-70)\"
      The customer's first words about a measured readiness timeout must not be
      a security-sounding code. Keep the token, move it: a trailing support
      reference is greppable and reads as a reference, not an accusation."
    else
        ok "ARM 5 the non-fatal diagnostic opens with the observation, not the code (#612)"
    fi

    # MUTATION. The pre-fix opening, pinned here, must trip the predicate.
    # Without this the arm above passes for any string that merely fails to
    # start with ERR-, including an empty one.
    PRE_FIX_DIAG='ERR-06-STORE-AUTH-LEAK diagnostic (non-fatal): status=none'
    if [ "$(printf '%s' "$PRE_FIX_DIAG" | grep -cE '^ERR-|^[A-Z0-9-]*LEAK')" -gt 0 ]; then
        ok "ARM 5 MUTATION -> the pinned pre-fix opening trips the predicate (arm 5 discriminates)"
    else
        bad "ARM 5 MUTATION -> the pinned PRE-FIX opening does NOT trip the predicate.
      Arm 5 therefore proves nothing and would pass over the original defect."
    fi
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
