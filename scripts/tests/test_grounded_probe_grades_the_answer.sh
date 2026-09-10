#!/usr/bin/env bash
# scripts/tests/test_grounded_probe_grades_the_answer.sh
#
# The grounded probe's frame parser used to compute reply_fact from the chunk
# accumulator, the DRAFT the gateway tells every client to discard on
# chunk_reset. The authoritative reply is the done frame's full_response, and
# the 0.4.79 omission guard puts a corrected reply ONLY there, so a corrected
# turn scored fact_missing exactly like an uncorrected one (found 2026-09-10,
# TNM, reading ws.rs beside the probe). The parser now grades full_response
# when the daemon sent the key, an EMPTY one as a real empty answer, and the
# chunks only when the key is absent.
#
# Drives the probe's own python, extracted from its heredoc, in its fixture
# mode (OSTLER_GROUNDED_FRAMES): four recorded streams, then a mutant control.
#
# THREE STATES. 0 every arm held, 1 an arm failed, 2 a prerequisite is absent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PROBE="${REPO}/scripts/box_walk_probes/probes/assistant_answers_grounded.sh"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || cant "no python3"
[ -r "${PROBE}" ] || cant "no probe at ${PROBE}"
WORK="$(mktemp -d)" || cant "no scratch dir"; trap 'rm -rf "${WORK}"' EXIT
awk '/cat <<'"'"'PYEOF'"'"'/{on=1; next} /^PYEOF$/{on=0} on{print}' "${PROBE}" > "${WORK}/probe.py"
[ -s "${WORK}/probe.py" ] || cant "could not extract the python heredoc from the probe"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${WORK}/probe.py" || cant "the extracted python does not parse"
printf 'fixture-token\n' > "${WORK}/token"
FACT="cable engineer at example.com"
# run <fixture file> -> prints the FRAME lines
run() { OSTLER_GROUNDED_FRAMES="$1" python3 "${WORK}/probe.py" 8000 "${WORK}/token" "what do you know about the seeded person" 5 "${FACT}" 2>&1; }
reply_fact() { printf '%s\n' "$1" | /usr/bin/grep -E '^FRAME reply_fact ' | tail -1 | awk '{print $3}'; }
reply_source() { printf '%s\n' "$1" | /usr/bin/grep -E '^FRAME reply_source ' | tail -1 | cut -d' ' -f3-; }
mk() { # name, then the event lines
  local f="${WORK}/$1"; shift; printf '%s\n' "$@" > "${f}"; printf '%s' "${f}"; }

echo "== 1. chunks omit the fact, full_response carries it: the guard's corrected turn reads YES =="
f=$(mk corrected '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"Jane is a cable engineer at example.com"}' '{"type":"chunk","content":"Jane is someone you know."}' '{"type":"chunk_reset"}' '{"type":"done","full_response":"Jane is a cable engineer at example.com, from your own records."}')
o="$(run "${f}")"; [ "$(reply_fact "${o}")" = YES ] && [ "$(reply_source "${o}")" = full_response ] && ok "corrected turn graded YES from full_response" || bad "corrected turn read '$(reply_fact "${o}")' from '$(reply_source "${o}")': $(printf '%s' "${o}" | tr '\n' '|' | cut -c1-200)"

echo "== 2. full_response omits the fact: NO, whatever the draft said =="
f=$(mk omitted '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"Jane is a cable engineer at example.com"}' '{"type":"chunk","content":"Jane is a cable engineer at example.com"}' '{"type":"chunk_reset"}' '{"type":"done","full_response":"Jane is someone you know."}')
o="$(run "${f}")"; [ "$(reply_fact "${o}")" = NO ] && ok "chunks carried the fact, full_response did not: NO (the draft is not the graded surface)" || bad "arm 2 read '$(reply_fact "${o}")'"

echo "== 3. no full_response key at all (pre-full_response daemon): the chunks are graded =="
f=$(mk oldshape '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"x"}' '{"type":"chunk","content":"Jane is a cable engineer at example.com"}' '{"type":"done"}')
o="$(run "${f}")"; [ "$(reply_fact "${o}")" = YES ] && [ "$(reply_source "${o}")" = chunks ] && ok "absent key falls back to the chunks and reads YES" || bad "arm 3 read '$(reply_fact "${o}")' from '$(reply_source "${o}")'"

echo "== 4. EMPTY full_response is a real empty answer: NO, never a silent read of the draft =="
f=$(mk emptyfinal '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"x"}' '{"type":"chunk","content":"Jane is a cable engineer at example.com"}' '{"type":"chunk_reset"}' '{"type":"done","full_response":""}')
o="$(run "${f}")"; [ "$(reply_fact "${o}")" = NO ] && [ "$(reply_source "${o}")" = "full_response EMPTY" ] && ok "empty full_response graded NO and named EMPTY" || bad "arm 4 read '$(reply_fact "${o}")' from '$(reply_source "${o}")'"

echo "== 5. chunk_reset clears the draft: fact in the chunks, reset, chunks without it, done with NO key =="
f=$(mk resetclears '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"x"}' '{"type":"chunk","content":"Jane is a cable engineer at example.com."}' '{"type":"chunk_reset"}' '{"type":"chunk","content":"Jane is someone you know."}' '{"type":"done"}')
o="$(run "${f}")"; [ "$(reply_fact "${o}")" = NO ] && [ "$(reply_source "${o}")" = chunks ] && ok "the fact written before chunk_reset is discarded; only the post-reset chunks are graded: NO" || bad "arm 5 read '$(reply_fact "${o}")' from '$(reply_source "${o}")': without the clearing this reads YES"

echo "== 7. a PARAPHRASE that carries every component of the fact reads YES; the exact-phrase reading beside it reads NO =="
f=$(mk paraphrase '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"Works as a submarine cable engineer at example.com."}' '{"type":"chunk","content":"x"}' '{"type":"chunk_reset"}' '{"type":"done","full_response":"Based on the memory I have, the seeded person is a submarine cable engineer who works at example.com in Riverside."}')
o="$(run "${f}")"
rp="$(printf '%s\n' "${o}" | /usr/bin/grep -E '^FRAME reply_fact_phrase ' | tail -1 | awk '{print $3}')"
[ "$(reply_fact "${o}")" = YES ] && [ "${rp}" = NO ] && ok "paraphrase (the v1.0.89 reply shape) reads YES on components, NO on the exact phrase, both printed" || bad "arm 7 read reply_fact='$(reply_fact "${o}")' phrase='${rp}'"

echo "== 8. a reply that OMITS the employer reads NO on both readings =="
f=$(mk omitemployer '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"Works as a submarine cable engineer at example.com."}' '{"type":"chunk_reset"}' '{"type":"done","full_response":"The seeded person is a submarine cable engineer in Riverside."}')
o="$(run "${f}")"
rp="$(printf '%s\n' "${o}" | /usr/bin/grep -E '^FRAME reply_fact_phrase ' | tail -1 | awk '{print $3}')"
[ "$(reply_fact "${o}")" = NO ] && [ "${rp}" = NO ] && ok "employer omitted: NO on components and NO on the phrase" || bad "arm 8 read reply_fact='$(reply_fact "${o}")' phrase='${rp}'"

echo "== 9. a reply that OMITS the role reads NO: components are all-or-nothing, not any =="
f=$(mk omitrole '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"Works as a submarine cable engineer at example.com."}' '{"type":"chunk_reset"}' '{"type":"done","full_response":"The seeded person works at example.com."}')
o="$(run "${f}")"
[ "$(reply_fact "${o}")" = NO ] && ok "role omitted: NO" || bad "arm 9 read '$(reply_fact "${o}")'"

echo "== 9b. components match whole tokens: a reply with the components buried inside longer words reads NO =="
f=$(mk longerwords '{"type":"session_start"}' '{"type":"tool_call","name":"pwg_people"}' '{"type":"tool_result","name":"pwg_people","output":"Works as a submarine cable engineer at example.com."}' '{"type":"chunk_reset"}' '{"type":"done","full_response":"The seeded person has cables engineered at example.common."}')
o="$(run "${f}")"
[ "$(reply_fact "${o}")" = NO ] && ok "components inside longer words do not count (TNM, #1916 review)" || bad "arm 9b read '$(reply_fact "${o}")'"

echo "== 10. CONTROL: a mutant whose carries() is the exact-phrase reading flips arm 7 back to NO =="
sed -e 's/^    cs = components(fact)$/    return carries_phrase(text, fact)/' "${WORK}/probe.py" > "${WORK}/mutant3.py"
[ "$(diff "${WORK}/probe.py" "${WORK}/mutant3.py" | /usr/bin/grep -c '^<')" -eq 1 ] || cant "mutant 3 did not land"
m3="$(OSTLER_GROUNDED_FRAMES="${WORK}/paraphrase" python3 "${WORK}/mutant3.py" 8000 "${WORK}/token" "q" 5 "${FACT}" 2>&1)"
[ "$(reply_fact "${m3}")" = NO ] && ok "MUST-FAIL: the phrase-only mutant reads NO on the paraphrase, so arm 7 measures the component reading" || bad "mutant 3 still read '$(reply_fact "${m3}")'"

echo "== 6. CONTROL: a mutant that grades the chunks again flips arm 1 =="
sed -e 's/            if "full_response" in ev:/            if False:/' "${WORK}/probe.py" > "${WORK}/mutant.py"
[ "$(diff "${WORK}/probe.py" "${WORK}/mutant.py" | /usr/bin/grep -c '^<')" -eq 1 ] || cant "the mutant did not land"
mo="$(OSTLER_GROUNDED_FRAMES="${WORK}/corrected" python3 "${WORK}/mutant.py" 8000 "${WORK}/token" "q" 5 "${FACT}" 2>&1)"
[ "$(reply_fact "${mo}")" = NO ] && ok "CONTROL: the mutant grades the draft and reads NO on the corrected turn, so arm 1 measures the fix" || bad "CONTROL: the mutant still read '$(reply_fact "${mo}")'; arm 1 proves nothing"

echo "== 7. CONTROL: a mutant without the chunk_reset clearing flips arm 5 =="
sed -e '/^        if t == "chunk_reset":$/,/^            text = ""$/d' "${WORK}/probe.py" > "${WORK}/mutant2.py"
[ "$(diff "${WORK}/probe.py" "${WORK}/mutant2.py" | /usr/bin/grep -c '^<')" -eq 2 ] || cant "the clearing mutant did not land"
m2="$(OSTLER_GROUNDED_FRAMES="${WORK}/resetclears" python3 "${WORK}/mutant2.py" 8000 "${WORK}/token" "q" 5 "${FACT}" 2>&1)"
[ "$(reply_fact "${m2}")" = YES ] && ok "CONTROL: without the clearing the pre-reset fact survives and arm 5 reads YES, so arm 5 measures the clearing" || bad "CONTROL: the clearing mutant read '$(reply_fact "${m2}")'; arm 5 proves nothing"

echo; echo "== ${pass} pass / ${fail} fail / $((pass+fail)) total =="; [ "${fail}" -eq 0 ]
