#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_conversation.sh
# ============================================================================
# grounding_seed.sh puts a PERSON in the graph before the grounded probe asks
# about one. preference_seed.sh puts a PREFERENCE PAIR there before the
# interest profile is read. Nothing had ever put a CONVERSATION through the
# conversation pipeline, so on a cold box three probes measured an empty store
# and could not tell that from a broken one:
#
#   ingest_coverage            conversations points_count is 0 because the
#                              installer pre-creates the collection empty and
#                              nothing processes a conversation at install time
#   assistant_answers_grounded pwg_topics renders "No conversation topics were
#                              found in the graph" because the only writer of a
#                              pwg:ConversationTopic is step 09 of that pipeline
#   usage_journal_producers    no cm048- row has ever been written
#
# scripts/box_walk_probes/lib/conversation_seed.sh closes that. This test pins
# the six things that make it worth having:
#
#   1. IT IS WIRED, AND IN THE RIGHT ORDER. Sourced and called between phase 1
#      and phase 2, AFTER the preference seed, with the forget below the loop.
#      A seed called after the measurements seeds nothing.
#   2. THE FIXTURE HAS NO PERSON IN IT. CM051 is a PUBLIC repo. The must-fail
#      arm plants a name-shaped token in the fixture and this suite has to
#      refuse it; the control is that the shipped fixture passes the same four
#      checks.
#   3. WHAT WE COULD NOT LOOK AT IS NOT A FAIL. An absent pwg-convo is a named
#      CANNOT-RUN, never a product defect.
#   4. THE READ-BACKS ARE SEPARATE. A conversations point with no topic is the
#      measured shape of a step-09 timeout, so the two are reported as two
#      verdicts and never collapsed into one.
#   5. A ZERO JOURNAL IS A FINDING, NOT A CANNOT-RUN. The producer is vendored
#      since CM051 #1881 (CM048 #78 at 53fcdf0b), so a zero names
#      cm048_conversation_extract as a PRESENT producer that did not write.
#   6. THE FORGET IS DETERMINISTIC. Every delete is keyed on the conversation
#      id or on sha1(id)[:8], never on a timestamp or a wildcard.
#
# The box is stubbed: a fake pwg-convo, a fake curl answering from files, a
# fake settings.yaml and a redirected HOME. This test is about the WIRING, the
# three-outcome discipline and the delete keys. Whether the real pipeline can
# talk to a real Ollama is what the walk itself measures.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/conversation_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"

PASS=0
FAIL=0
CANNOT=0
arm() { # $1 = label, $2 = condition already evaluated (0/1), $3 = detail on failure
    if [ "$2" -eq 0 ]; then
        printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$1"; printf '%s\n' "$3" | sed 's/^/         /'; FAIL=$((FAIL + 1))
    fi
}
# ITS OWN COLUMN, NOT A PASS AND NOT A FAIL. An arm that could not run has not
# passed, and printing it as either would make this suite report a coverage
# number it did not earn. The summary carries all three.
cannot() { # $1 = label, $2 = the missing prerequisite
    printf '  [CANNOT-RUN] %s\n' "$1"; printf '         missing: %s\n' "$2"
    CANNOT=$((CANNOT + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$LIB" ] || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -f "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] || { printf 'CANNOT-RUN: no python3 on PATH\n'; exit 78; }

SEED_ID="ostler-walk-seed-0001"
SEED_SHORT="ce3939c1"

# The vocabulary the fixture is allowed to capitalise. A LITERAL here rather
# than something derived from the fixture, because a check computed from its
# own subject cannot fail: if a future edit adds a name it must add the name to
# this list too, and be seen doing it in review.
#
# T and Z are the ISO-8601 date/time separators out of the front-matter
# timestamp and L is the first character of L2; GB is the language tag. Each is
# listed by itself rather than the predicate being loosened to "single capital
# letters", because a loosened predicate stops catching an initial, and an
# initial is exactly the shape a person leaks in as.
ALLOWED_CAPS="Also GB L Note Reminder Self T The To USER Voice You Z"

# THE PERSON CHECK. Four shapes, and each one has cost somebody a leak
# somewhere: a name, an address, a phone number, a private IP. Returns 0 when
# the text is clean, 1 when it is not, and prints what it found.
person_check() { # $1 = file to check
    local f="$1" bad=0 tok
    local caps="$WORK/caps.$$"
    LC_ALL=C /usr/bin/grep -oE '[A-Z][A-Za-z]*' "$f" 2>/dev/null | sort -u > "$caps"
    while read -r tok; do
        [ -n "$tok" ] || continue
        case " $ALLOWED_CAPS " in
            *" $tok "*) ;;
            *) printf 'NAME-SHAPED TOKEN: %s\n' "$tok"; bad=1 ;;
        esac
    done < "$caps"
    rm -f "$caps"
    if LC_ALL=C /usr/bin/grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+' "$f"; then
        printf 'EMAIL-SHAPED TOKEN\n'; bad=1
    fi
    # 7+ consecutive digits, or a leading +. A date (2026-09-09) and a duration
    # (90) are neither; a phone number is one or the other.
    if LC_ALL=C /usr/bin/grep -qE '([0-9]{7,}|\+[0-9]{2,})' "$f"; then
        printf 'PHONE-SHAPED TOKEN\n'; bad=1
    fi
    if LC_ALL=C /usr/bin/grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$f"; then
        printf 'ADDRESS-SHAPED TOKEN\n'; bad=1
    fi
    return $bad
}

# ---------------------------------------------------------------------------
# The stub box. A HOME, a settings.yaml, a pwg-convo and a curl.
# ---------------------------------------------------------------------------
make_box() { # $1 = box root, $2 = cli exit code, $3 = write bundle? yes|no
    local root="$1" clirc="$2" bundle="$3"
    mkdir -p "$root/.ostler" "$root/.ostler/secrets" "$root/bin" "$root/stub"
    printf 'user_id: walkbox\nollama_url: http://127.0.0.1:11434\n' > "$root/.ostler/settings.yaml"
    # THE STORE CREDENTIAL EXISTS ON A REAL BOX, so it exists here. Before the
    # NO-CONF fix these tests passed with no config at all, because an absent
    # credential silently produced an empty -K and the stub answered anyway.
    # That is precisely the defect, and a fixture that omits the file cannot
    # tell a credentialled read from a credential-less one.
    printf 'header = "authorization: Bearer stub-store-token"\n' \
        > "$root/.ostler/secrets/store-curl.conf"
    chmod 600 "$root/.ostler/secrets/store-curl.conf"

    cat > "$root/bin/pwg-convo" <<STUB
#!/bin/bash
# stub pwg-convo. Records its argv so the test can prove the CLI was handed
# the two files, then behaves like a run that did or did not complete.
printf '%s\n' "\$*" >> "$root/stub/cli.log"
cp "\$2" "$root/stub/transcript.md" 2>/dev/null
cp "\$3" "$root/stub/metadata.json" 2>/dev/null
if [ "$bundle" = yes ]; then
    mkdir -p "\$HOME/.ostler/processing/$SEED_ID"
    printf '{"topics": [{"slug": "loft-insulation"}]}\n' > "\$HOME/.ostler/processing/$SEED_ID/09_bundle.json"
fi
printf 'stub pipeline says rc=%s\n' "$clirc"
exit $clirc
STUB
    chmod +x "$root/bin/pwg-convo"

    cat > "$root/bin/curl" <<STUB
#!/bin/bash
# stub curl. Answers the four surfaces the seed reads from files under
# $root/stub, and RECORDS every request so the forget's delete keys can be
# read back out rather than assumed.
printf '%s\n' "\$*" >> "$root/stub/curl.log"
url=""; data=""; prev=""
for a in "\$@"; do
    case "\$a" in http://*) url="\$a" ;; esac
    case "\$prev" in --data|--data-binary) data="\$a" ;; esac
    prev="\$a"
done
printf '%s\n' "\$data" >> "$root/stub/data.log"
case "\$url" in
    */collections/conversations) cat "$root/stub/qdrant_collection.json" ;;
    */points/count)              cat "$root/stub/qdrant_count.json" ;;
    */points/delete*)            printf '{"status":"ok"}\n' ;;
    */api/v1/topics)             cat "$root/stub/topics_api.json" ;;
    */update)                    printf '' ;;
    */query)                     cat "$root/stub/sparql_count.json" ;;
esac
exit 0
STUB
    chmod +x "$root/bin/curl"
}

set_counts() { # $1 = box root, $2 = collection points, $3 = our points, $4 = topics api, $5 = topics sparql
    printf '{"result": {"points_count": %s}, "status": "ok"}\n' "$2" > "$1/stub/qdrant_collection.json"
    printf '{"result": {"count": %s}, "status": "ok"}\n' "$3" > "$1/stub/qdrant_count.json"
    printf '{"topics": [], "count": %s}\n' "$4" > "$1/stub/topics_api.json"
    printf '{"results": {"bindings": [{"n": {"value": "%s"}}]}}\n' "$5" > "$1/stub/sparql_count.json"
}

# Source the lib in a child shell with the stub box wired in, call the step,
# report what it decided. Nothing here reaches a real box: OSTLER_BOX_HOST is
# empty, which the suite contract reads as "this machine".
run_apply() { # $1 = lib, $2 = box root, rest = extra env assignments
    local lib="$1" root="$2"; shift 2
    env -u OSTLER_CONVO_SEED_SKIP -u OSTLER_CONVO_SEED_KEEP \
        HOME="$root" OSTLER_BOX_HOST= \
        OSTLER_CONVO_SEED_CLI="$root/bin/pwg-convo" \
        OSTLER_CONVO_SEED_SETTINGS="$root/.ostler/settings.yaml" \
        OSTLER_CONVO_SEED_CURL="$root/bin/curl" \
        OSTLER_CONVO_SEED_BUDGET_S=30 \
        OSTLER_PROBE_STORE_CURL_CONF="$root/.ostler/secrets/store-curl.conf" \
        OSTLER_USAGE_JOURNAL="$root/stub/costs.jsonl" \
        "$@" \
        bash -c '
            . "$1"
            conversation_seed_apply
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${CONVERSATION_SEED_STATE}"
        ' _ "$lib" 2>&1
}

printf 'THE WALK SEEDS ONE CONVERSATION\n\n'

# ---------------------------------------------------------------------------
printf -- '-- 1. it is wired into the runner, in the right order --\n'
# ---------------------------------------------------------------------------
src_line="$(grep -n 'lib/conversation_seed.sh' "$RUNNER" | head -1 | cut -d: -f1)"
apply_line="$(grep -n '^conversation_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
forget_line="$(grep -n '^conversation_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)"
pref_line="$(grep -n '^preference_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$apply_line" ]
arm "the runner sources the lib and calls conversation_seed_apply" $? \
    "source line='$src_line' apply line='$apply_line'"

[ -n "$loop_line" ] && [ -n "$apply_line" ] && [ "$apply_line" -lt "$loop_line" ]
arm "the seed runs BEFORE the phase-2 probe loop (a seed after it seeds nothing)" $? \
    "apply at $apply_line, probe loop at $loop_line"

[ -n "$pref_line" ] && [ -n "$apply_line" ] && [ "$apply_line" -gt "$pref_line" ]
arm "it runs AFTER preference_seed_apply, so the seeds keep one declared order" $? \
    "conversation apply at $apply_line, preference apply at $pref_line"

[ -n "$forget_line" ] && [ -n "$loop_line" ] && [ "$forget_line" -gt "$loop_line" ]
arm "the forget step runs AFTER the loop, so it cannot change a verdict" $? \
    "forget at $forget_line, probe loop at $loop_line"

# The three line citations at the top of the runner must survive this wiring.
[ "$(sed -n '42p' "$RUNNER")" = 'PROBE_DIR="$HERE/probes"' ] \
    && [ "$(sed -n '44p' "$RUNNER")" = 'EX_CANNOT_RUN=78' ] \
    && [ "$(sed -n '83p' "$RUNNER")" = 'for f in "$PROBE_DIR"/*.sh; do' ]
arm "the runner's three cited lines (:42 :44 :83) still say what is cited" $? \
    "42=[$(sed -n '42p' "$RUNNER")] 44=[$(sed -n '44p' "$RUNNER")] 83=[$(sed -n '83p' "$RUNNER")]"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. the fixture carries no person, and the check can say so --\n'
# ---------------------------------------------------------------------------
FIXT="$WORK/fixture.txt"
bash -c '. "$1"; conversation_seed_fixture_transcript; conversation_seed_fixture_metadata' _ "$LIB" > "$FIXT" 2>&1
[ -s "$FIXT" ]
arm "the lib prints its fixture, so the bytes the box gets are the bytes checked" $? \
    "empty fixture output"

pc_out="$(person_check "$FIXT")"
pc_rc=$?
arm "CONTROL: the shipped fixture has no name, email, phone or address in it" "$pc_rc" \
    "$pc_out"

grep -q 'privacy_level' "$FIXT" && grep -q 'L2' "$FIXT"
arm "and it states privacy_level L2 explicitly, which forecloses the L3 escalation" $? \
    "$(cat "$FIXT")"

# MUST-FAIL. A name-shaped token planted in the fixture has to be REFUSED. If
# this arm passes, the check above is decoration.
#
# THE PLANT IS A FABRICATED WORD, NOT A COMMON FIRST NAME. This repo is PUBLIC
# and the plant is committed to it, so a negative-control token has to be
# provably fictional rather than merely unlikely. Nothing is lost: the
# predicate keys on the SHAPE -- a capitalised word outside the fixture's
# declared vocabulary -- and has no opinion about whether the word is a real
# name, so a fabricated one exercises exactly the same branch a real one would.
PLANT="$WORK/planted.sh"
PLANT_TOKEN="Wibblesworth"
sed "s/^\*\*You\*\* \[00:04\]: Reminder to self/**You** [00:04]: ${PLANT_TOKEN} said to remind myself/" "$LIB" > "$PLANT"
grep -q "$PLANT_TOKEN" "$PLANT"
arm "the planted-name mutant really carries the token (the injection landed)" $? \
    "no ${PLANT_TOKEN} in the mutant"
PFIXT="$WORK/planted.txt"
bash -c '. "$1"; conversation_seed_fixture_transcript; conversation_seed_fixture_metadata' _ "$PLANT" > "$PFIXT" 2>&1
plant_out="$(person_check "$PFIXT")"
if [ $? -ne 0 ]; then plant_rc=0; else plant_rc=1; fi
arm "MUST-FAIL: a planted name is REFUSED by the same check the fixture passes" "$plant_rc" \
    "the check accepted a fixture containing a person: $plant_out"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. the pipeline entry point is missing --\n'
# ---------------------------------------------------------------------------
B_NOCLI="$WORK/nocli"; make_box "$B_NOCLI" 0 yes; set_counts "$B_NOCLI" 1 1 2 2
rm -f "$B_NOCLI/bin/pwg-convo"
out3="$(run_apply "$LIB" "$B_NOCLI")"
grep -q 'STATE=absent' <<< "$out3" && grep -q 'CANNOT-RUN' <<< "$out3" && grep -q 'NO-CLI' <<< "$out3"
arm "an absent pwg-convo is a named CANNOT-RUN, not a product FAIL" $? "$out3"
[ ! -f "$B_NOCLI/stub/cli.log" ]
arm "and nothing was processed" $? "the stub CLI ran anyway"

B_NOUID="$WORK/nouid"; make_box "$B_NOUID" 0 yes; set_counts "$B_NOUID" 1 1 2 2
printf 'ollama_url: http://127.0.0.1:11434\n' > "$B_NOUID/.ostler/settings.yaml"
out3b="$(run_apply "$LIB" "$B_NOUID")"
grep -q 'STATE=absent' <<< "$out3b" && grep -q 'NO-USER-ID' <<< "$out3b"
arm "settings.yaml with no user_id is CANNOT-RUN (Settings raises at construction)" $? "$out3b"

# ---------------------------------------------------------------------------
printf -- '\n-- 4. a processed conversation with points and topics is SEEDED --\n'
# ---------------------------------------------------------------------------
B_OK="$WORK/ok"; make_box "$B_OK" 0 yes; set_counts "$B_OK" 1 1 3 3
printf '{"session_id": "cm048-abc", "usage": {"purpose": "conversation_enrich"}}\n' > "$B_OK/stub/costs.jsonl"
out4="$(run_apply "$LIB" "$B_OK")"
grep -q 'RC=0' <<< "$out4" && grep -q 'STATE=seeded' <<< "$out4"
arm "points_count > 0 and topics > 0 on both instruments is a pass" $? "$out4"

[ -f "$B_OK/stub/cli.log" ] && grep -q 'process ' "$B_OK/stub/cli.log"
arm "the CLI was actually invoked, with the process subcommand" $? \
    "cli.log: $(cat "$B_OK/stub/cli.log" 2>/dev/null)"

[ -f "$B_OK/stub/metadata.json" ] && grep -q '"channel": "spoken"' "$B_OK/stub/metadata.json" \
    && grep -q '"privacy_level": "L2"' "$B_OK/stub/metadata.json" \
    && grep -q "\"conversation_id\": \"$SEED_ID\"" "$B_OK/stub/metadata.json"
arm "and it was handed metadata with channel spoken, an explicit L2 and the seed id" $? \
    "metadata: $(cat "$B_OK/stub/metadata.json" 2>/dev/null)"

grep -q 'READ-BACK conversations  POPULATED' <<< "$out4" \
    && grep -q 'READ-BACK topics         POPULATED' <<< "$out4" \
    && grep -q 'READ-BACK usage journal  POPULATED' <<< "$out4"
arm "three read-backs print three separate verdict words" $? "$out4"

grep -q 'DOES NOT SAY THE FEED WORKS' <<< "$out4"
arm "and a pass says in words what it does not cover" $? "$out4"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. points without topics is TWO verdicts, not one --\n'
# ---------------------------------------------------------------------------
# The measured shape of a step-09 timeout: the step-07 summary point landed and
# the last of the six model calls never wrote a topic. Collapsing the two would
# report a timing fact as a topics defect.
B_NOTOP="$WORK/notopics"; make_box "$B_NOTOP" 0 yes; set_counts "$B_NOTOP" 1 1 0 0
printf '{"session_id": "cm048-abc", "usage": {"purpose": "conversation_enrich"}}\n' > "$B_NOTOP/stub/costs.jsonl"
out5="$(run_apply "$LIB" "$B_NOTOP")"
grep -q 'STATE=sinks-refused' <<< "$out5"
arm "a completed run with an empty topic graph is sinks-refused, not seeded" $? "$out5"
grep -q 'READ-BACK conversations  POPULATED' <<< "$out5" && grep -q 'READ-BACK topics         EMPTY' <<< "$out5"
arm "and the two arms are reported separately: conversations POPULATED, topics EMPTY" $? "$out5"
grep -q 'FINDING' <<< "$out5" && grep -q 'step 09 is the LAST of six model calls' <<< "$out5"
arm "the FINDING names step 09 rather than blaming the writer it cannot see" $? "$out5"

# A store that did not answer is UNREADABLE, and must never print as a zero.
B_UNRD="$WORK/unreadable"; make_box "$B_UNRD" 0 yes; set_counts "$B_UNRD" 1 1 2 2
printf 'not json\n' > "$B_UNRD/stub/sparql_count.json"
out5b="$(run_apply "$LIB" "$B_UNRD")"
grep -q 'READ-BACK topics         UNREADABLE' <<< "$out5b" && grep -q 'CANNOT-RUN' <<< "$out5b"
arm "a store that did not answer is UNREADABLE and CANNOT-RUN, never a count of zero" $? "$out5b"

# ---------------------------------------------------------------------------
printf -- '\n-- 6. a zero usage journal is a FINDING, never a CANNOT-RUN --\n'
# ---------------------------------------------------------------------------
B_NOJ="$WORK/nojournal"; make_box "$B_NOJ" 0 yes; set_counts "$B_NOJ" 1 1 3 3
printf '{"session_id": "zeroclaw-1", "usage": {"purpose": "chat"}}\n' > "$B_NOJ/stub/costs.jsonl"
out6="$(run_apply "$LIB" "$B_NOJ")"
grep -q 'READ-BACK usage journal  EMPTY' <<< "$out6"
arm "a journal with no cm048- row reads EMPTY" $? "$out6"
grep -q 'FINDING: the pipeline completed and wrote NO usage-journal row' <<< "$out6"
arm "which is reported as a FINDING naming the vendored producer that stayed quiet" $? "$out6"
grep -q 'STATE=seeded' <<< "$out6" && grep -q 'RC=0' <<< "$out6"
arm "and it does NOT decide the exit code: the roster row is non-blocking for v1.0" $? "$out6"

# An absent journal FILE is not a count of zero either.
B_ABSJ="$WORK/absentjournal"; make_box "$B_ABSJ" 0 yes; set_counts "$B_ABSJ" 1 1 3 3
out6b="$(run_apply "$LIB" "$B_ABSJ")"
grep -q 'READ-BACK usage journal  UNREADABLE' <<< "$out6b"
arm "an absent journal file is UNREADABLE, not a producer that wrote nothing" $? "$out6b"

# ---------------------------------------------------------------------------
printf -- '\n-- 7. a run that did not complete asserts NOTHING --\n'
# ---------------------------------------------------------------------------
B_RC1="$WORK/rc1"; make_box "$B_RC1" 1 no; set_counts "$B_RC1" 1 1 3 3
out7="$(run_apply "$LIB" "$B_RC1")"
grep -q 'STATE=failed' <<< "$out7" && grep -q 'FINDING' <<< "$out7"
arm "a non-zero CLI exit with no step-09 bundle is a FINDING and asserts nothing" $? "$out7"
grep -q 'READ-BACK conversations' <<< "$out7"
if [ $? -eq 0 ]; then rb_rc=1; else rb_rc=0; fi
arm "and no read-back is even attempted, so no count can be mistaken for evidence" "$rb_rc" "$out7"

# ---------------------------------------------------------------------------
printf -- '\n-- 8. skipping seeds nothing and says it is not a pass --\n'
# ---------------------------------------------------------------------------
B_SKIP="$WORK/skip"; make_box "$B_SKIP" 0 yes; set_counts "$B_SKIP" 1 1 3 3
out8="$(run_apply "$LIB" "$B_SKIP" OSTLER_CONVO_SEED_SKIP=1)"
grep -q 'STATE=skipped' <<< "$out8" && grep -q 'not a pass' <<< "$out8"
arm "OSTLER_CONVO_SEED_SKIP=1 processes nothing and says it is not a pass" $? "$out8"
[ ! -f "$B_SKIP/stub/cli.log" ]
arm "and the CLI never ran" $? "the stub CLI ran anyway"
grep -q 'CANNOT-RUN' <<< "$out8"
arm "a skip is a NAMED CANNOT-RUN, so all five exits classify themselves" $? "$out8"

# THE WHOLE CONTRACT, IN ONE ARM. Every path that returns 1 has to print
# CANNOT-RUN or FINDING. The five outputs collected above are every such path
# this suite can reach, and a sixth added later without a word on it will fail
# here rather than land as a bare red on a walk record.
bad_paths=""
for _o in "$out3" "$out3b" "$out5b" "$out7" "$out8"; do
    if ! grep -q 'CANNOT-RUN\|FINDING' <<< "$_o"; then
        bad_paths="${bad_paths}
$(printf '%s' "$_o" | grep '^STATE=')"
    fi
done
[ -z "$bad_paths" ]
arm "EVERY return-1 path names itself CANNOT-RUN or FINDING, never a bare red" $? \
    "these states printed neither word:$bad_paths"

# ---------------------------------------------------------------------------
printf -- '\n-- 9. the forget removes by the deterministic ids --\n'
# ---------------------------------------------------------------------------
B_F="$WORK/forget"; make_box "$B_F" 0 yes; set_counts "$B_F" 1 1 3 3
printf '{"session_id": "cm048-abc", "usage": {"purpose": "conversation_enrich"}}\n' > "$B_F/stub/costs.jsonl"
# The four artefacts a completed run leaves on disk, in the shapes the writers
# use: the processing dir, the flat markdown, the bundle folder named by
# sha1(id)[:8], and a decoy bundle whose short id is somebody else's.
mkdir -p "$B_F/Documents/Ostler/Conversations/2026-09-09/note-to-self-$SEED_SHORT"
printf 'x\n' > "$B_F/Documents/Ostler/Conversations/2026-09-09/note-to-self-$SEED_SHORT/summary.md"
mkdir -p "$B_F/Documents/Ostler/Conversations/2026-09-09/someone-else-deadbeef"
printf 'x\n' > "$B_F/Documents/Ostler/Conversations/2026-09-09/someone-else-deadbeef/summary.md"
printf 'x\n' > "$B_F/Documents/Ostler/Conversations/$SEED_ID.md"
COACH="$B_F/.ostler/coach/observations.db"
mkdir -p "$(dirname "$COACH")"
SQLITE="$(command -v sqlite3 || true)"
if [ -n "$SQLITE" ]; then
    "$SQLITE" "$COACH" "CREATE TABLE observations (observation_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL);
        INSERT INTO observations VALUES ('o1', '$SEED_ID');
        INSERT INTO observations VALUES ('o2', 'somebody-elses-conversation');" >/dev/null 2>&1
fi

fout="$(env -u OSTLER_CONVO_SEED_KEEP HOME="$B_F" OSTLER_BOX_HOST= \
    OSTLER_CONVO_SEED_CLI="$B_F/bin/pwg-convo" \
    OSTLER_CONVO_SEED_SETTINGS="$B_F/.ostler/settings.yaml" \
    OSTLER_CONVO_SEED_CURL="$B_F/bin/curl" \
    OSTLER_CONVO_SEED_BUDGET_S=30 \
    OSTLER_PROBE_STORE_CURL_CONF="$B_F/.ostler/secrets/store-curl.conf" \
    OSTLER_USAGE_JOURNAL="$B_F/stub/costs.jsonl" \
    bash -c '
        . "$1"
        conversation_seed_apply >/dev/null 2>&1
        printf "STATE=%s\n" "${CONVERSATION_SEED_STATE}"
        conversation_seed_forget
        printf "FORGET_RC=%s\n" "$?"
    ' _ "$LIB" 2>&1)"

grep -q 'STATE=seeded' <<< "$fout" && grep -q 'FORGET_RC=0' <<< "$fout"
arm "the forget always returns 0, so a tidy-up cannot fail a walk" $? "$fout"

[ ! -d "$B_F/.ostler/processing/$SEED_ID" ]
arm "the processing directory is gone" $? "still at $B_F/.ostler/processing/$SEED_ID"

[ ! -f "$B_F/Documents/Ostler/Conversations/$SEED_ID.md" ]
arm "the flat Conversations markdown is gone" $? "still there"

[ ! -d "$B_F/Documents/Ostler/Conversations/2026-09-09/note-to-self-$SEED_SHORT" ]
arm "the bundle folder named by sha1(id)[:8] is gone" $? "still there"

[ -d "$B_F/Documents/Ostler/Conversations/2026-09-09/someone-else-deadbeef" ]
arm "THE DECOY SURVIVES: a bundle with a different short id is left alone" $? \
    "the forget deleted somebody else's conversation"

grep -q "conversation_id.*$SEED_ID" "$B_F/stub/data.log"
arm "the Qdrant delete is filtered on payload.conversation_id, by value" $? \
    "data.log: $(cat "$B_F/stub/data.log" 2>/dev/null | head -20)"

grep -q "urn:ostler:conversation/$SEED_ID" "$B_F/stub/data.log"
arm "the SPARQL deletes name urn:ostler:conversation/<id>, never a wildcard" $? \
    "data.log: $(cat "$B_F/stub/data.log" 2>/dev/null | head -20)"

grep -q 'urn:ostler:user/walkbox' "$B_F/stub/data.log"
arm "and the named-graph delete is scoped to the user_id read off the box" $? \
    "data.log: $(cat "$B_F/stub/data.log" 2>/dev/null | head -20)"

grep -q 'FILTER NOT EXISTS' "$B_F/stub/data.log"
arm "a topic another conversation also mentions is protected by FILTER NOT EXISTS" $? \
    "data.log: $(cat "$B_F/stub/data.log" 2>/dev/null | head -20)"

if [ -n "$SQLITE" ]; then
    left="$("$SQLITE" "$COACH" "SELECT COUNT(*) FROM observations WHERE conversation_id = '$SEED_ID';" 2>/dev/null)"
    other="$("$SQLITE" "$COACH" "SELECT COUNT(*) FROM observations WHERE conversation_id = 'somebody-elses-conversation';" 2>/dev/null)"
    [ "$left" = "0" ] && [ "$other" = "1" ]
    arm "the coach row keyed on this conversation is gone and the other row is not" $? \
        "ours=$left theirs=$other"
else
    printf '  [CANNOT-RUN] no sqlite3 on this host, so the coach row arm was not measured\n'
fi

# The forget must not run at all from a state where nothing was seeded: on a
# failed run the half-written rows are the evidence.
B_FF="$WORK/forget-failed"; make_box "$B_FF" 1 no; set_counts "$B_FF" 1 1 3 3
ffout="$(env -u OSTLER_CONVO_SEED_KEEP HOME="$B_FF" OSTLER_BOX_HOST= \
    OSTLER_CONVO_SEED_CLI="$B_FF/bin/pwg-convo" \
    OSTLER_CONVO_SEED_SETTINGS="$B_FF/.ostler/settings.yaml" \
    OSTLER_CONVO_SEED_CURL="$B_FF/bin/curl" \
    OSTLER_PROBE_STORE_CURL_CONF="$B_FF/.ostler/secrets/store-curl.conf" \
    bash -c '. "$1"; conversation_seed_apply >/dev/null 2>&1; conversation_seed_forget; printf "FORGET_RC=%s\n" "$?"' \
    _ "$LIB" 2>&1)"
grep -q 'removing the seeded conversation' <<< "$ffout"
if [ $? -eq 0 ]; then ff_rc=1; else ff_rc=0; fi
arm "nothing is deleted from a failed state: the half-written rows are evidence" "$ff_rc" "$ffout"

B_FK="$WORK/forget-keep"; make_box "$B_FK" 0 yes; set_counts "$B_FK" 1 1 3 3
fkout="$(HOME="$B_FK" OSTLER_BOX_HOST= \
    OSTLER_CONVO_SEED_CLI="$B_FK/bin/pwg-convo" \
    OSTLER_CONVO_SEED_SETTINGS="$B_FK/.ostler/settings.yaml" \
    OSTLER_CONVO_SEED_CURL="$B_FK/bin/curl" \
    OSTLER_PROBE_STORE_CURL_CONF="$B_FK/.ostler/secrets/store-curl.conf" \
    OSTLER_CONVO_SEED_KEEP=1 \
    bash -c '. "$1"; conversation_seed_apply >/dev/null 2>&1; conversation_seed_forget' _ "$LIB" 2>&1)"
grep -q 'OSTLER_CONVO_SEED_KEEP=1' <<< "$fkout" && [ -d "$B_FK/.ostler/processing/$SEED_ID" ]
arm "OSTLER_CONVO_SEED_KEEP=1 leaves everything and says so" $? "$fkout"

# ---------------------------------------------------------------------------
printf -- '\n-- 10. MUTATION: with the topics read-back disabled, arm 5 must fail --\n'
# ---------------------------------------------------------------------------
# The topics arm is the one a future edit is most likely to drop, because it is
# the one that fails on a slow box: five of the six model calls can succeed and
# the sixth still write nothing. Softening it would make every run green and
# make assistant_answers_grounded unmeasurable again.
MUT="$WORK/mutant.sh"
sed 's/^    elif \[ "${CONVERSATION_SEED_TOPICS_API}" -gt 0 \] 2>\/dev\/null \&\& \[ "${CONVERSATION_SEED_TOPICS_SPARQL}" -gt 0 \] 2>\/dev\/null; then$/    elif true; then/' "$LIB" > "$MUT"
mut_left="$(grep -c 'CONVERSATION_SEED_TOPICS_API}" -gt 0' "$MUT" || true)"
[ "$mut_left" = "0" ]
arm "the mutant really has the topics assertion disabled (the injection landed)" $? \
    "still present: $mut_left line(s)"

B_MUT="$WORK/mutbox"; make_box "$B_MUT" 0 yes; set_counts "$B_MUT" 1 1 0 0
outm="$(run_apply "$MUT" "$B_MUT")"
grep -q 'STATE=seeded' <<< "$outm"
if [ $? -eq 0 ]; then mut_rc=0; else mut_rc=1; fi
arm "MUST-FAIL: the mutant calls topics=0 a pass, so arm 5 is a real assertion" "$mut_rc" \
    "the mutant did not pass topics=0: $outm"

# ---------------------------------------------------------------------------
printf -- '\n-- 11. $HOME is expanded ON THE BOX, not single-quoted into oblivion --\n'
# ---------------------------------------------------------------------------
# THE v1.0.82 QA DEFECT, both instances. The walk printed
#   CANNOT-RUN: the box cannot run the conversation pipeline.
#     NO-SETTINGS $HOME/.ostler/settings.yaml
# with the literal characters $HOME, on a box where the file was present and
# 213 bytes. Both defaults are the STRING "$HOME/..." and every call site put
# them through _cs_q, which SINGLE-QUOTES, so the remote shell never expanded
# them. `[ ! -f ]` on a path containing a literal dollar is always true.
#
# The arms below run the REAL preflight with the REAL default, with only HOME
# redirected. Each is paired with a mutant that restores the old form and MUST
# fail, because an arm that passes on both forms tests nothing.

# The validator first: a whitelist has to say yes to the ordinary case, or the
# refusals below prove only that it refuses everything (which is what the first
# version of it did).
# A QUOTED HEREDOC, NOT AN INLINE LIST. The first version of this probe put the
# candidates in a double-quoted context, so the OUTER shell expanded them before
# _cs_path_is_safe ever saw them: $HOME became the driver's home, $OTHER became empty,
# and the backtick candidate EXECUTED `id` and pasted the account's uid, gid and
# group list into the test output. The probe was measuring the outer shell.
# 'VAL' is quoted so nothing here expands, which is the whole point: the
# validator must be handed the literal characters an operator would set.
cat > "$WORK/val_probe.sh" <<'VAL'
. "$1"
while IFS= read -r v; do
    if _cs_path_is_safe "$v"; then printf 'SAFE %s\n' "$v"; else printf 'REFUSED %s\n' "$v"; fi
done <<'CANDIDATES'
$HOME/x
${HOME}/x
/tmp/plain
~/x
$HOME/x;id
$HOME/x`id`
$OTHER/x
/tmp/a b
/tmp/a*b
CANDIDATES
# The empty string, which a here-doc line cannot carry.
if _cs_path_is_safe ""; then printf 'SAFE <empty>\n'; else printf 'REFUSED <empty>\n'; fi
VAL
val_out="$(bash "$WORK/val_probe.sh" "$LIB" 2>&1)"
[ "$(grep -c '^SAFE ' <<< "$val_out")" = "3" ]
arm "CONTROL: the path validator accepts \$HOME, \${HOME} and a plain path" $? "$val_out"
[ "$(grep -c '^REFUSED ' <<< "$val_out")" = "7" ]
arm "and refuses a tilde, a separator, a backtick, a second variable, a space, a glob and empty" $? "$val_out"

CS_HOME="$WORK/boxhome"; mkdir -p "$CS_HOME/.ostler/secrets"
printf 'user_id: walkbox\n' > "$CS_HOME/.ostler/settings.yaml"
printf 'header = "authorization: Bearer stub"\n' > "$CS_HOME/.ostler/secrets/store-curl.conf"

# Runs _cs_preflight with the SHIPPED default for the settings path, nothing
# overridden but HOME. $1 = lib to source, $2 = shell to run remote text under.
preflight_default() {
    env -u OSTLER_CONVO_SEED_SETTINGS -u OSTLER_BOX_HOST HOME="$CS_HOME" \
        OSTLER_CONVO_SEED_LOCAL_SH="${2:-/bin/sh}" \
        bash -c '
            . "$1"
            _CS_CLI="/bin/sh"
            _CS_SETTINGS="${OSTLER_CONVO_SEED_SETTINGS:-\$HOME/.ostler/settings.yaml}"
            _CS_SETTINGS_PATH="$(_cs_resolve_on_box "${_CS_SETTINGS}")"
            _cs_preflight
            printf "RC=%s\nOUT=%s\n" "$?" "${_cs_pre_out}"
        ' _ "$1" 2>&1
}

out11="$(preflight_default "$LIB")"
grep -q 'USER-ID walkbox' <<< "$out11" && grep -q 'RC=0' <<< "$out11"
arm "preflight finds settings.yaml through the default \$HOME path and reads user_id" $? "$out11"

grep -q '[$]HOME' <<< "$out11"
if [ $? -ne 0 ]; then lit_rc=0; else lit_rc=1; fi
arm "and no literal dollar-HOME survives into the report" "$lit_rc" "$out11"

# MUST-FAIL ON THE OLD FORM, instance 1. Restore the single-quoted value and
# the same arm has to break, with the exact string the QA printed.
MUT_S="$WORK/mutant-settings.sh"
sed 's/^S=\$(_cs_q "\${_CS_SETTINGS_PATH}")$/S=$(_cs_q "${_CS_SETTINGS}")/' "$LIB" > "$MUT_S"
grep -q 'S=$(_cs_q "${_CS_SETTINGS}")' "$MUT_S"
arm "the old-form mutant really restores the single-quoted settings value" $? \
    "injection did not land"
outm11="$(preflight_default "$MUT_S")"
grep -q 'NO-SETTINGS [$]HOME/.ostler/settings.yaml' <<< "$outm11"
if [ $? -eq 0 ]; then m11_rc=0; else m11_rc=1; fi
arm "MUST-FAIL: the old form prints the QA's exact 'NO-SETTINGS \$HOME/...' line" "$m11_rc" \
    "the old form did not reproduce the v1.0.82 failure: $outm11"

# ---------------------------------------------------------------------------
printf -- '\n-- 12. an unreadable store credential is NO-CONF, never a keyless request --\n'
# ---------------------------------------------------------------------------
# THE SECOND INSTANCE, AND THE ONE THAT FAILS SILENTLY. _CS_STORE_CONF had the
# same escaped default and reached three sites shaped
#     K=''; [ -r "$CONF" ] && K="-K $CONF"
# with no refusal branch, so an unreadable path left K EMPTY and the request
# went to an auth-gated store with no credential. The read-back then reports
# the conversation ABSENT while it is present, and the forget deletes nothing
# while reporting success.
B_NC="$WORK/noconf"; make_box "$B_NC" 0 yes; set_counts "$B_NC" 1 1 3 3
rm -f "$B_NC/.ostler/secrets/store-curl.conf"
out12="$(run_apply "$LIB" "$B_NC")"

grep -q 'CANNOT-RUN: NO-CONF' <<< "$out12"
arm "a missing store credential is a NAMED CANNOT-RUN, not an empty count" $? "$out12"

grep -q 'STATE=sinks-refused' <<< "$out12"
arm "and the state says the sinks were not read, not that they were empty" $? "$out12"

# THE ASSERTION THAT MATTERS: no request was issued at all.
if [ -f "$B_NC/stub/curl.log" ]; then
    nk="$(grep -c 'collections/conversations' "$B_NC/stub/curl.log" || true)"
else
    nk=0
fi
[ "$nk" = "0" ]
arm "NOT ONE store request was made without a credential" $? \
    "curl.log shows $nk store call(s): $(cat "$B_NC/stub/curl.log" 2>/dev/null | head -5)"

# MUST-FAIL ON THE OLD FORM, instance 2: restore the keyless build and the
# request goes out with an empty -K.
MUT_K="$WORK/mutant-keyless.sh"
python3 - "$LIB" "$MUT_K" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
guard = "if [ -z \\\"\\$CONF\\\" ] || [ ! -r \\\"\\$CONF\\\" ]; then printf 'NO-CONF %s\\n' \\\"\\$CONF\\\"; exit 4; fi\nK=\\\"-K \\$CONF\\\"\n"
old   = "K=''\n[ -r \\\"\\$CONF\\\" ] && K=\\\"-K \\$CONF\\\"\n"
n = s.count(guard)
s = s.replace(guard, old)
open(dst, 'w', encoding='utf-8').write(s)
print("reverted %d read-back guard(s)" % n)
PY
grep -q "K=''" "$MUT_K"
arm "the keyless mutant really restores the old K='' build" $? "injection did not land"

B_NCM="$WORK/noconf-mut"; make_box "$B_NCM" 0 yes; set_counts "$B_NCM" 1 1 3 3
rm -f "$B_NCM/.ostler/secrets/store-curl.conf"
outm12="$(run_apply "$MUT_K" "$B_NCM")"
km="$(grep -c 'collections/conversations' "$B_NCM/stub/curl.log" 2>/dev/null || true)"
[ "$km" != "0" ] && ! grep -q 'CANNOT-RUN: NO-CONF' <<< "$outm12"
if [ $? -eq 0 ]; then m12_rc=0; else m12_rc=1; fi
arm "MUST-FAIL: the old form sends $km credential-less store request(s) and never says NO-CONF" "$m12_rc" \
    "the old form refused as the fixed one does, so this arm proves nothing: $outm12"

# The forget half: no credential means the store deletes are NOT attempted, and
# the report says the rows are still there rather than claiming success.
B_NCF="$WORK/noconf-forget"; make_box "$B_NCF" 0 yes; set_counts "$B_NCF" 1 1 3 3
fnc="$(env -u OSTLER_CONVO_SEED_KEEP HOME="$B_NCF" OSTLER_BOX_HOST= \
    OSTLER_CONVO_SEED_CLI="$B_NCF/bin/pwg-convo" \
    OSTLER_CONVO_SEED_SETTINGS="$B_NCF/.ostler/settings.yaml" \
    OSTLER_CONVO_SEED_CURL="$B_NCF/bin/curl" \
    OSTLER_PROBE_STORE_CURL_CONF="$B_NCF/.ostler/secrets/store-curl.conf" \
    bash -c '
        . "$1"
        conversation_seed_apply >/dev/null 2>&1
        rm -f "$2"
        conversation_seed_forget
        printf "FORGET_RC=%s\n" "$?"
    ' _ "$LIB" "$B_NCF/.ostler/secrets/store-curl.conf" 2>&1)"
grep -q 'STORE_DELETES skipped' <<< "$fnc" && grep -q 'STILL ON THE BOX' <<< "$fnc"
arm "forget refuses the store deletes and SAYS the seeded rows remain" $? "$fnc"
grep -q 'FORGET_RC=0' <<< "$fnc"
arm "and still returns 0, because a tidy-up must never fail a walk" $? "$fnc"
[ ! -d "$B_NCF/.ostler/processing/$SEED_ID" ]
arm "the credential-free disk deletes still ran, so NO-CONF leaves less behind, not more" $? \
    "the processing dir survived: $fnc"

# ---------------------------------------------------------------------------
printf -- '\n-- 13. the remote text runs under zsh, which is what ssh hands it to --\n'
# ---------------------------------------------------------------------------
# `ssh host "cmd"` runs the text under the REMOTE ACCOUNT'S LOGIN SHELL, which
# on this estate is zsh, while local mode runs /bin/sh. Nothing had ever
# executed these programs under zsh, so a zsh-only quoting fault would have
# been seen first on a walk. zsh does not word-split unquoted parameters, which
# is exactly the kind of difference that changes what a remote program does.
ZSH_BIN="$(command -v zsh || true)"
if [ -z "$ZSH_BIN" ]; then
    cannot "the preflight text under zsh" \
        "no zsh on this host; the walk-record-gate workflow installs it so CI measures this"
else
    out13="$(preflight_default "$LIB" "$ZSH_BIN")"
    grep -q 'USER-ID walkbox' <<< "$out13" && grep -q 'RC=0' <<< "$out13"
    arm "the preflight program yields the same USER-ID under zsh as under sh" $? \
        "zsh=$ZSH_BIN: $out13"
    outm13="$(preflight_default "$MUT_S" "$ZSH_BIN")"
    grep -q 'NO-SETTINGS [$]HOME' <<< "$outm13"
    if [ $? -eq 0 ]; then z_rc=0; else z_rc=1; fi
    arm "MUST-FAIL: the old form is broken under zsh too, so this arm can fail" "$z_rc" \
        "$outm13"
fi

printf '\n== %s pass / %s fail / %s cannot-run / %s total ==\n' \
    "$PASS" "$FAIL" "$CANNOT" "$((PASS + FAIL + CANNOT))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
