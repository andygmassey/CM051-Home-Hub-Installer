#!/usr/bin/env bash
# scripts/box_walk_probes/lib/conversation_seed.sh
# ============================================================================
# THE CONVERSATION SEED. Put ONE fictional voice note through the SHIPPED
# conversation pipeline on the box, with a real model call, before the probes
# read the stores it writes to.
#
# WHY THIS FILE EXISTS, MEASURED (analysis 2026-09-09 against the v1.0.82 tree
# at efd03fcc; every claim below carries the file and line it was read from)
#
# The vendored tree vendor/cm048_pipeline has no watcher, no inbox and no
# queue. Its only entry point is the console script pwg-convo = src.cli:main
# (pyproject.toml:19-20). The installer stages it, builds its venv and symlinks
# /usr/local/bin/pwg-convo (install.sh:19074-19086, :19141), and then checks it
# with --help plus an import (:19178-19180). NOTHING IS PROCESSED AT INSTALL
# TIME. So on a cold box:
#
#   - the conversations Qdrant collection is pre-created EMPTY (install.sh
#     :18448) and ingest_coverage reads its points_count as 0, which it scores
#     EMPTY (ingest_coverage.sh:284);
#   - not one pwg:ConversationTopic exists in the default graph, because the
#     only writer of that node is topic_writer.py at step 09 of this pipeline
#     (processor.py:2082-2092), so /api/v1/topics answers with an empty array
#     (ical-server.py:3996-4059) and pwg_topics renders "No conversation topics
#     were found in the graph." (pwg_topics.rs:148);
#   - nothing has ever written a cm048- row to the usage journal.
#
# Three probes therefore measure an EMPTY BOX and cannot tell that from a
# BROKEN one. That is the same fault the person seed and the preference seed
# each closed on their own write route: an absence and a failure printing the
# same thing.
#
# WHY THE DIRECT CLI AND NOT THE TRANSCRIPTS FEED. The installer does create
# ~/Documents/Ostler/Transcripts and the spoken feed is ON by default on a
# fresh single-user box (install.sh:23186), so dropping a file there looks like
# the honest route. It is not usable as a WALK step, for four measured reasons:
#
#   1. privacy_level in transcript front matter is DISCARDED. build_metadata
#      honours only L3 (spoken_source/renderer.py:240-241). Through the feed
#      our L2 note arrives with no explicit level, which hands the decision to
#      the classifier, and a "sensitive" verdict escalates it to L3
#      (privacy.py:118-130) where topic_writer refuses to write anything
#      (topic_writer.py:368-372). A seed whose read-back depends on a model's
#      mood is not an instrument. Through a hand-written metadata.json an
#      explicit privacy_level is the HIGHEST-precedence input
#      (privacy.py:113-116), so L2 is stated and the escalation is foreclosed.
#   2. The tick clamps --since-days to 2 outside 23:00-07:00 (tick.sh:150-185).
#   3. The tick yields on live chat and on loadavg (tick.sh:61-76, :96-109) and
#      takes the shared Ollama lock (:215-265), so WHEN it runs is not ours.
#   4. ~/Documents is TCC-protected and a walk is frequently driven over ssh.
#
# So the transcript and the metadata are written into a box-side mktemp -d and
# handed straight to `pwg-convo process` (cli.py:148-166), which is the same
# binary the feed shells out to per session (spoken_source/pipeline.py:243).
#
# WHAT IT ASSERTS, AND IN HOW MANY PIECES. THREE READ-BACKS, THREE VERDICT
# WORDS, never one:
#
#   conversations   Qdrant points_count on the collection ingest_coverage
#                   reads, with the install's own -K credential config exactly
#                   as that probe presents it (ingest_coverage.sh:75, 157, 211,
#                   227). One point passes; that point is the step-07
#                   conversation summary (ingest.py:362-398).
#   topics          BOTH GET :8090/api/v1/topics (the endpoint pwg_topics
#                   actually calls) AND a direct SPARQL COUNT of
#                   pwg:ConversationTopic on :7878. Two instruments because
#                   they can disagree: the endpoint filters on a substring of
#                   label-or-slug (ical-server.py:4048), and on 2026-09-09 it
#                   returned 35 topics unfiltered while pwg_topics reported
#                   nothing, because the model had passed a whole question as
#                   q. A count from the graph cannot be filtered away.
#   usage journal   rows whose session_id starts cm048-. This one CANNOT PASS
#                   YET and says so: the VENDORED cm048_pipeline has no
#                   usage-journal writer at all (grep for costs.jsonl,
#                   usage_journal, record_usage, prompt_tokens, OSTLER_USAGE:
#                   zero hits; the only cm048- strings are
#                   record_posture("cm048-ingest") at ingest.py:52,59, a
#                   security-posture marker). So a 0 here is a FINDING NAMING
#                   THE ABSENT PRODUCER, never a CANNOT-RUN of this seed and
#                   never a silent pass. Per the launch directive item 5,
#                   usage_journal_producers is NOT blocking for v1.0, so this
#                   arm does not decide the step's exit code.
#
# THE THIRD RISK THE ANALYSIS NAMES, AND WHY THE TWO ARMS ARE REPORTED APART.
# Step 09 is the LAST of six sequential model calls (processor.py:2082), each
# measured around 100 s on a shipped box (cuts/DEFECTS_ROLLFORWARD.md:243). A
# budget exhaustion (processor.py:406-437) or a timeout yields a conversations
# point and NO topics. Collapsing the two into one verdict would report that as
# a topics defect. They are printed separately, and the state is sinks-refused,
# which is a finding about what landed and not a claim about why.
#
# THE RULE THIS FILE OBEYS, THE SAME ONE grounding_seed.sh AND
# preference_seed.sh OBEY: A SEED THAT DID NOT WORK MUST NOT LOOK LIKE A
# PRODUCT DEFECT. Every return-1 path prints a line beginning CANNOT-RUN or
# FINDING, so a reader never has to infer which of the two it was.
#
# WHAT A GREEN HERE DOES AND DOES NOT MEAN. It means one conversation reaches
# Qdrant and the topic graph through the binary the product uses. IT DOES NOT
# MEAN THE FEED WORKS: nothing here runs the LaunchAgent, the tick or the
# watermark, so nothing here says whether a customer's own voice note is ever
# picked up.
#
# ENV
#   OSTLER_CONVO_SEED_SKIP=1   do not seed at all. Prints that it is not a pass.
#   OSTLER_CONVO_SEED_KEEP=1   leave everything on the box afterwards.
#   OSTLER_CONVO_SEED_CLI      the pipeline entry point. Default
#                              /usr/local/bin/pwg-convo, the installer's symlink.
#   OSTLER_CONVO_SEED_SETTINGS ~/.ostler/settings.yaml by default; read for
#                              user_id, which names the graph the ingest writes.
#   OSTLER_CONVO_SEED_BUDGET_S wall-clock bound on the CLI. Default 900.
#   OSTLER_CONVO_SEED_CURL     absolute curl. A variable ONLY so the read-backs
#                              are testable against a stub, the same reason
#                              preference_seed.sh makes its /Volumes root one.
#   OSTLER_QDRANT_URL, OSTLER_OXIGRAPH_URL, OSTLER_PROBE_API_BASE,
#   OSTLER_PROBE_STORE_CURL_CONF, OSTLER_USAGE_JOURNAL   as the probes use them.
#   OSTLER_BOX_HOST            unset means this machine, per the suite contract.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile.
# ============================================================================

CONVERSATION_SEED_STATE="unrun"   # unrun|skipped|absent|failed|sinks-refused|seeded
CONVERSATION_SEED_USER_ID=""
CONVERSATION_SEED_POINTS=""       # collection points_count, or x
CONVERSATION_SEED_MINE=""         # points carrying our conversation_id, or x
CONVERSATION_SEED_TOPICS_API=""   # /api/v1/topics count, or x
CONVERSATION_SEED_TOPICS_SPARQL=""
CONVERSATION_SEED_JOURNAL=""      # cm048- rows, or x when the file is absent

# THE ONE IDENTIFIER EVERYTHING IS KEYED ON. The Qdrant payload
# (ingest.py:355), the conversation node urn:ostler:conversation/<id>, the
# topic mention's inConversation, the processing directory, the flat
# Conversations markdown and the coach row's UNIQUE(conversation_id) all derive
# from it, which is what makes the forget deterministic rather than a sweep.
CONVERSATION_SEED_ID="ostler-walk-seed-0001"

# The bundle folder is <date>/<slug>-<short id>/ where the short id is
# sha1(conversation_id)[:8] (conversation_writer.py:380-411). The slug is built
# from the participant list and is not ours to predict, so the forget matches
# on the short id, which is.
CONVERSATION_SEED_SHORTID="ce3939c1"

# The reader's namespace. topic_writer.py builds explicit
# https://schema.ostler.ai/ontology# IRIs precisely because CM048's own nodes
# live under urn:ostler: and the reader resolves pwg: to this one
# (topic_writer.py:29-48; ical-server.py:444). Getting this wrong produces a
# 200 with an empty array, which is the exact symptom of the bug it fixes.
_CS_PWG_NS="https://schema.ostler.ai/ontology#"

_cs_box_exec() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

_cs_box_exec_stdin() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# Single-quote a value for the remote command line. The values here are ids,
# URLs and paths we control, so a stray single quote is dropped rather than
# escaped -- the same call preference_seed.sh makes for its bundle label, and
# for the same reason: an unbalanced quote would close the quoting and the rest
# of the value would be read as shell.
_cs_q() {
    printf "'%s'" "$(printf '%s' "$1" | tr -d "'")"
}

# ---------------------------------------------------------------------------
# THE FIXTURE. A voice note to self with NO PERSON IN IT.
#
# CM051 IS A PUBLIC REPO. Rule zero of PRODUCTISATION_CHECKLIST forbids a
# fixture carrying real-person data, and the safest reading of that on a public
# tree is a fixture carrying NO person at all -- not an invented one, which
# still has to be argued about, but a note the customer records to themselves.
# source voice_note with only the USER speaker makes is_voice_note true
# (spoken_source/reader.py:119-136) and the title falls back to
# "Note To Self (Voice Note)" (renderer.py:95-97), so the shape is one the
# pipeline already handles rather than one invented for a test.
#
# It is also chosen to have TOPICS IN IT. Step 09 has to find something to
# write or the topics read-back is empty for a reason that is not a defect;
# loft insulation and joist spacing are two nouns a topic extractor can hold on
# to, and neither is about anybody.
#
# EXPOSED AS FUNCTIONS so the test can read exactly the bytes the box gets.
# tests/test_the_walk_seeds_the_conversation.sh runs a person check over both
# of these and refuses on a name-shaped, email-shaped, phone-shaped or
# address-shaped token.
# ---------------------------------------------------------------------------
conversation_seed_fixture_transcript() {
    cat <<'FIXTURE'
---
title: Note To Self (Voice Note)
call_id: ostler-walk-seed-0001
timestamp: 2026-09-09T09:15:00Z
duration_seconds: 90
source: voice_note
context: note to self
privacy_level: L2
language: en-GB
diarization_method: manual
tags:
  - ostler-walk-seed
participants:
  - speaker_label: USER
    display_name: You
---

**You** [00:04]: Reminder to self about the loft insulation, before the weather turns.

**You** [00:31]: The joist spacing up there is wider than the batts, so they need cutting down, or a wider roll instead.

**You** [01:12]: Also the loft hatch seal. The draught comes through the edge, and the insulation will not fix that on its own.
FIXTURE
}

conversation_seed_fixture_metadata() {
    cat <<'FIXTURE'
{
  "conversation_id": "ostler-walk-seed-0001",
  "date": "2026-09-09",
  "channel": "spoken",
  "source": "voice_note",
  "source_session_id": "ostler-walk-seed-0001",
  "capture_source": "cm042_mac",
  "privacy_level": "L2",
  "title": "Note To Self (Voice Note)",
  "participants": [
    {"id": "user", "display": "You", "role": "user"}
  ]
}
FIXTURE
}

# ---------------------------------------------------------------------------
# PREFLIGHT. Two facts, both read ON THE BOX.
#
# The CLI has to EXIST AND BE EXECUTABLE: install.sh symlinks it out of the
# venv (:19074-19076), and a venv that was never built leaves a dangling
# symlink, which `[ -e ]` alone would not catch on some shells and `[ -x ]`
# does.
#
# settings.yaml has to carry a user_id: Settings.__post_init__ RAISES on an
# empty one (settings.py:106-121), so without it the CLI dies at construction
# and the walk would read that as a pipeline failure rather than a
# configuration one. The value is also the named graph the ingest writes into
# (ingest.py:540-548), so the forget needs it too.
# ---------------------------------------------------------------------------
_cs_preflight() {
    _cs_pre_out="$(_cs_box_exec "
CLI=$(_cs_q "${_CS_CLI}")
S=$(_cs_q "${_CS_SETTINGS}")
case \"\$S\" in \"~/\"*) S=\"\$HOME/\${S#~/}\" ;; esac
if [ ! -e \"\$CLI\" ]; then printf 'NO-CLI %s\n' \"\$CLI\"; exit 3; fi
if [ ! -x \"\$CLI\" ]; then printf 'CLI-NOT-EXECUTABLE %s\n' \"\$CLI\"; exit 3; fi
if [ ! -f \"\$S\" ]; then printf 'NO-SETTINGS %s\n' \"\$S\"; exit 3; fi
uid=\$(sed -n 's/^[[:space:]]*user_id:[[:space:]]*//p' \"\$S\" | head -1 | tr -d '\"' | sed \"s/'//g;s/[[:space:]]*\$//\")
if [ -z \"\$uid\" ]; then printf 'NO-USER-ID %s\n' \"\$S\"; exit 3; fi
printf 'USER-ID %s\n' \"\$uid\"
" 2>&1)"
    _cs_pre_rc=$?
    return ${_cs_pre_rc}
}

# ---------------------------------------------------------------------------
# THE TRIGGER. One synchronous `pwg-convo process`, bounded.
#
# BOUNDED BY A WATCHDOG AND NOT BY timeout(1), WHICH MACOS DOES NOT HAVE. The
# CLI runs in the background, a sleeper kills it at the budget, and the exit
# code comes back from `wait`. A kill shows up as an exit code above 128, which
# is how a timed-out run is told from a failed one.
#
# THE COMPLETION MARKER IS NOT THE EXIT CODE ALONE. cmd_process returns 0 only
# when state.failed_step is None (cli.py:166), but a run that dies inside the
# watchdog window has no exit code worth reading either way, so the presence of
# ~/.ostler/processing/<id>/09_bundle.json -- the cached output of step 09,
# which is the step that writes the topics -- is reported alongside it. Both,
# never one.
#
# The two fixture files travel as ONE base64 JSON blob on stdin, for the reason
# grounding_seed.sh gives: no second credential path, and no dependence on
# whether this box's base64 spells its decode flag -d or -D.
# ---------------------------------------------------------------------------
_cs_run_cli() {
    _cs_payload="$(python3 - <<PY
import base64, json, sys
files = {
    "transcript.md": $(conversation_seed_fixture_transcript | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
    "metadata.json": $(conversation_seed_fixture_metadata | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
}
print(base64.b64encode(json.dumps(files).encode("utf-8")).decode("ascii"))
PY
)" || return 2

    printf '%s' "${_cs_payload}" | _cs_box_exec_stdin "
d=\$(mktemp -d) || exit 90
python3 -c \"
import base64, json, os, sys
files = json.loads(base64.b64decode(sys.stdin.read()))
for name, body in files.items():
    with open(os.path.join(sys.argv[1], name), 'w', encoding='utf-8') as fh:
        fh.write(body)
\" \"\$d\" || { rm -rf \"\$d\"; exit 90; }
CLI=$(_cs_q "${_CS_CLI}")
LOG=\"\$d/cli.log\"
\"\$CLI\" process \"\$d/transcript.md\" \"\$d/metadata.json\" >\"\$LOG\" 2>&1 &
cpid=\$!
# THE WATCHDOG'S OUTPUT IS CLOSED, NOT MERELY QUIET. The caller reads this
# program through a command substitution, which does not return until the LAST
# holder of the write end of that pipe lets go. A backgrounded sleeper that
# inherited stdout holds it for the whole budget even after the shell exits, so
# without this redirect the seed would take its full budget on EVERY run,
# including the ones that finish in a second. Measured while writing this file:
# a 30 s budget made a stubbed run take 30 s.
( sleep ${_CS_BUDGET}; kill -TERM \$cpid 2>/dev/null ) >/dev/null 2>&1 &
wpid=\$!
wait \$cpid
rc=\$?
kill \$wpid 2>/dev/null
B=\"\$HOME/.ostler/processing/$(printf '%s' "${CONVERSATION_SEED_ID}")/09_bundle.json\"
if [ -f \"\$B\" ]; then bundle=present; else bundle=absent; fi
printf 'CLI_RC %s\n' \"\$rc\"
printf 'BUNDLE %s\n' \"\$bundle\"
printf 'CLI_LOG_TAIL\n'
tail -n 40 \"\$LOG\" 2>/dev/null
rm -rf \"\$d\"
"
}

# ---------------------------------------------------------------------------
# READ-BACK 1. The conversations collection, read the way ingest_coverage reads
# it: the install's own -K config, --noproxy '*', and points_count off
# /collections/conversations. A local proxy answering for every host is a
# measured hazard on this estate, so the flag is not optional.
#
# TWO NUMBERS: the collection count, which is the number the probe scores, and
# a filtered count of OUR conversation_id, which is the number that says the
# seed is what put it there. A collection count that moved for some other
# reason would otherwise read as a successful seed.
# ---------------------------------------------------------------------------
_cs_read_conversations() {
    _cs_box_exec "
CONF=$(_cs_q "${_CS_STORE_CONF}")
case \"\$CONF\" in \"~/\"*) CONF=\"\$HOME/\${CONF#~/}\" ;; esac
K=''
[ -r \"\$CONF\" ] && K=\"-K \$CONF\"
Q=$(_cs_q "${_CS_QDRANT}")
p=\$($(_cs_q "${_CS_CURL}") -sS --noproxy '*' -m 20 \$K \"\$Q/collections/conversations\" 2>/dev/null \\
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"result\"][\"points_count\"])
except Exception:
    print(\"x\")' 2>/dev/null)
m=\$($(_cs_q "${_CS_CURL}") -sS --noproxy '*' -m 20 \$K -X POST \\
  -H 'Content-Type: application/json' \\
  --data '{\"exact\": true, \"filter\": {\"must\": [{\"key\": \"conversation_id\", \"match\": {\"value\": \"${CONVERSATION_SEED_ID}\"}}]}}' \\
  \"\$Q/collections/conversations/points/count\" 2>/dev/null \\
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"result\"][\"count\"])
except Exception:
    print(\"x\")' 2>/dev/null)
printf 'POINTS %s MINE %s\n' \"\${p:-x}\" \"\${m:-x}\"
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# READ-BACK 2. Topics, on BOTH surfaces.
#
# The API is the surface pwg_topics actually calls (pwg_topics.rs:90-95), and
# it is called WITHOUT q here on purpose: with a q the endpoint filters on a
# substring of label-or-slug (ical-server.py:4048), and a caller who passes a
# whole question as q gets an empty array from a populated graph. That
# happened, measured 2026-09-09: 35 topics unfiltered, nothing through
# pwg_topics.
#
# The SPARQL COUNT is the control the API cannot be. It runs against the
# DEFAULT graph with no GRAPH clause, because that is where topic_writer puts
# the triples and where the reader looks (topic_writer.py:277-281). The two
# disagreeing is itself the finding, which is why both are printed.
# ---------------------------------------------------------------------------
_cs_read_topics() {
    _cs_box_exec "
CONF=$(_cs_q "${_CS_STORE_CONF}")
case \"\$CONF\" in \"~/\"*) CONF=\"\$HOME/\${CONF#~/}\" ;; esac
K=''
[ -r \"\$CONF\" ] && K=\"-K \$CONF\"
a=\$($(_cs_q "${_CS_CURL}") -sS --noproxy '*' -m 20 \"$(printf '%s' "${_CS_API}")/api/v1/topics\" 2>/dev/null \\
  | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d[\"count\"] if isinstance(d.get(\"count\"), int) else len(d[\"topics\"]))
except Exception:
    print(\"x\")' 2>/dev/null)
q='SELECT (COUNT(?t) AS ?n) WHERE { ?t a <${_CS_PWG_NS}ConversationTopic> }'
s=\$($(_cs_q "${_CS_CURL}") -sS --noproxy '*' -m 20 \$K \\
  -H 'Content-Type: application/sparql-query' \\
  -H 'Accept: application/sparql-results+json' \\
  --data-binary \"\$q\" $(_cs_q "${_CS_OXIGRAPH}") 2>/dev/null \\
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"results\"][\"bindings\"][0][\"n\"][\"value\"])
except Exception:
    print(\"x\")' 2>/dev/null)
printf 'TOPICS_API %s TOPICS_SPARQL %s\n' \"\${a:-x}\" \"\${s:-x}\"
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# READ-BACK 3. The usage journal.
#
# A ZERO HERE MUST NOT BE MANUFACTURED. usage_journal_producers.sh owns the
# full workspace resolver; these are its same branches in the order it applies
# them, and the whole reason the file's ABSENCE is reported as x rather than as
# 0 is that a resolver disagreement would otherwise print as "the producer
# wrote nothing", which is a different claim entirely and the one nobody could
# check.
#
# The gate wants a top-level session_id with the cm048- prefix AND a
# usage.purpose (verify_usage_journal_producers.py:284-305). The prefix alone
# is counted here and the purpose is reported beside it, because this seed's
# job is to say whether the producer FIRED, not to re-adjudicate the roster.
# ---------------------------------------------------------------------------
_cs_read_journal() {
    _cs_box_exec "
J=$(_cs_q "${_CS_JOURNAL}")
if [ -z \"\$J\" ]; then
  if [ -n \"\${ZEROCLAW_CONFIG_DIR:-}\" ]; then
    J=\"\${ZEROCLAW_CONFIG_DIR}/workspace/state/costs.jsonl\"
  else
    cfg=\"\$HOME/.ostler\"
    raw=''
    if [ -f \"\$cfg/active_workspace.toml\" ]; then
      raw=\$(sed -n 's/^[[:space:]]*config_dir[[:space:]]*=[[:space:]]*//p' \"\$cfg/active_workspace.toml\" | head -1 | tr -d '\"' | sed \"s/'//g;s/[[:space:]]*\$//\")
    fi
    case \"\$raw\" in
      '')   J=\"\$cfg/workspace/state/costs.jsonl\" ;;
      '~/'*) J=\"\$HOME/\${raw#~/}/workspace/state/costs.jsonl\" ;;
      /*)   J=\"\$raw/workspace/state/costs.jsonl\" ;;
      *)    J=\"\$cfg/\$raw/workspace/state/costs.jsonl\" ;;
    esac
  fi
fi
if [ ! -f \"\$J\" ]; then printf 'JOURNAL x PATH %s ABSENT\n' \"\$J\"; exit 0; fi
python3 - \"\$J\" <<'PY'
import json, sys
rows = purposed = total = 0
with open(sys.argv[1], encoding='utf-8', errors='replace') as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        total += 1
        try:
            rec = json.loads(line)
        except Exception:
            continue
        sid = rec.get('session_id')
        if isinstance(sid, str) and sid.startswith('cm048-'):
            rows += 1
            usage = rec.get('usage')
            if isinstance(usage, dict) and usage.get('purpose'):
                purposed += 1
print('JOURNAL %d PURPOSED %d OF %d' % (rows, purposed, total))
PY
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# THE STEP. Sourced and called by run_box_walk.sh in the caller's own shell,
# beside the other two seeds, for the same reason: this is the last moment
# before anything is measured, and ttywalk.sh does not invoke this runner at
# all, so a seed wired there would never reach it.
#
# Returns 0 only when the state is seeded. Every return-1 path prints a line
# beginning CANNOT-RUN or FINDING.
# ---------------------------------------------------------------------------
conversation_seed_apply() {
    printf -- '--- CONVERSATION SEED: one fictional voice note, through the shipped pipeline ---\n'

    _CS_CLI="${OSTLER_CONVO_SEED_CLI:-/usr/local/bin/pwg-convo}"
    _CS_SETTINGS="${OSTLER_CONVO_SEED_SETTINGS:-\$HOME/.ostler/settings.yaml}"
    _CS_BUDGET="${OSTLER_CONVO_SEED_BUDGET_S:-900}"
    _CS_CURL="${OSTLER_CONVO_SEED_CURL:-/usr/bin/curl}"
    _CS_QDRANT="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
    _CS_OXIGRAPH="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
    _CS_API="${OSTLER_PROBE_API_BASE:-http://127.0.0.1:8090}"
    _CS_STORE_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
    _CS_JOURNAL="${OSTLER_USAGE_JOURNAL:-}"

    if [ "${OSTLER_CONVO_SEED_SKIP:-0}" = "1" ]; then
        CONVERSATION_SEED_STATE="skipped"
        # A NAMED CANNOT-RUN, not a bare "skipped". The header of this file
        # promises that every return-1 path says which of the two it is, and a
        # skip is the purest case of "we did not look": the operator asked for
        # it, and the missing prerequisite is the request itself. Printing it
        # any other way leaves one exit out of five that a reader has to
        # classify for themselves.
        printf '  CANNOT-RUN: skipped by OSTLER_CONVO_SEED_SKIP=1. No conversation was\n'
        printf '  processed, so ingest_coverage reads the conversations collection the\n'
        printf '  installer pre-created empty and assistant_answers_grounded asks a box\n'
        printf '  with no topics in it. That is not a pass.\n\n'
        return 1
    fi

    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        printf '  target: this machine (OSTLER_BOX_HOST unset)\n'
    else
        printf '  target: %s\n' "${OSTLER_BOX_HOST}"
    fi
    printf '  entry point:     %s\n' "${_CS_CLI}"
    printf '  conversation_id: %s\n' "${CONVERSATION_SEED_ID}"

    if ! _cs_preflight; then
        CONVERSATION_SEED_STATE="absent"
        printf '  CANNOT-RUN: the box cannot run the conversation pipeline.\n'
        printf '%s\n' "${_cs_pre_out}" | sed 's/^/    /'
        printf '  NO-CLI or CLI-NOT-EXECUTABLE means /usr/local/bin/pwg-convo is not\n'
        printf '  the symlink install.sh makes into the cm048 venv, so nothing on this\n'
        printf '  box can process a conversation at all. NO-SETTINGS or NO-USER-ID\n'
        printf '  means Settings would raise at construction (settings.py:106-121) and\n'
        printf '  the run would die before the first model call.\n'
        printf '  NOT a product FAIL by this step: it is the prerequisite this seed\n'
        printf '  needs, named so it can be fixed rather than guessed at. Nothing was\n'
        printf '  seeded and no conversation assertion was made.\n\n'
        return 1
    fi
    CONVERSATION_SEED_USER_ID="$(printf '%s\n' "${_cs_pre_out}" | sed -n 's/^USER-ID //p' | head -1)"
    printf '  user_id:         %s (names the graph urn:ostler:user/%s)\n' \
        "${CONVERSATION_SEED_USER_ID}" "${CONVERSATION_SEED_USER_ID}"
    printf '  budget:          %s s for six sequential model calls\n' "${_CS_BUDGET}"

    _cs_out="$(_cs_run_cli 2>&1)"
    _cs_rc=$?
    printf '%s\n' "${_cs_out}" | sed 's/^/    /'

    _cs_cli_rc="$(printf '%s\n' "${_cs_out}" | sed -n 's/^CLI_RC //p' | head -1)"
    _cs_bundle="$(printf '%s\n' "${_cs_out}" | sed -n 's/^BUNDLE //p' | head -1)"

    if [ -z "${_cs_cli_rc}" ]; then
        CONVERSATION_SEED_STATE="absent"
        printf '  CANNOT-RUN: the run printed no CLI_RC line, so the transport failed\n'
        printf '  before the pipeline was reached (transport exit %s). Nothing was\n' "${_cs_rc}"
        printf '  seeded and no conversation assertion was made.\n\n'
        return 1
    fi

    if [ "${_cs_cli_rc}" != "0" ] || [ "${_cs_bundle}" != "present" ]; then
        CONVERSATION_SEED_STATE="failed"
        if [ "${_cs_cli_rc}" -gt 128 ] 2>/dev/null; then
            printf '  CANNOT-RUN: the pipeline was KILLED at the %s s budget (exit %s).\n' \
                "${_CS_BUDGET}" "${_cs_cli_rc}"
            printf '  Six sequential model calls at roughly 100 s each is the measured\n'
            printf '  shape, so a box under Ollama contention can exceed this without\n'
            printf '  anything being wrong with the pipeline. Raise\n'
            printf '  OSTLER_CONVO_SEED_BUDGET_S and walk again before calling it a\n'
            printf '  defect.\n'
        else
            printf '  FINDING: the pipeline ran and did not complete (exit %s, step-09\n' "${_cs_cli_rc}"
            printf '  bundle %s). cmd_process returns non-zero only when a step failed\n' "${_cs_bundle}"
            printf '  (cli.py:166), and the tail above is what it said. A conversation\n'
            printf '  the SHIPPED binary cannot process on a fresh box is a finding\n'
            printf '  about the product, not about this seed.\n'
        fi
        printf '  Rows written before the failing step may remain. Remove them with\n'
        printf '  OSTLER_CONVO_SEED_KEEP=0 and a forget by hand; this step will not do\n'
        printf '  it automatically from a failed state, because a tidy-up over a\n'
        printf '  half-written conversation would destroy the evidence.\n'
        printf '  No conversation assertion was made.\n\n'
        return 1
    fi

    printf '  the pipeline completed: exit 0 and the step-09 bundle is present\n'

    # ---- READ BACK, THREE TIMES, THREE WORDS ------------------------------
    _cs_c="$(_cs_read_conversations)"
    CONVERSATION_SEED_POINTS="$(printf '%s\n' "${_cs_c}" | sed -n 's/^POINTS \([^ ]*\) MINE .*/\1/p' | head -1)"
    CONVERSATION_SEED_MINE="$(printf '%s\n' "${_cs_c}" | sed -n 's/^POINTS [^ ]* MINE \([^ ]*\).*/\1/p' | head -1)"
    [ -n "${CONVERSATION_SEED_POINTS}" ] || CONVERSATION_SEED_POINTS="x"
    [ -n "${CONVERSATION_SEED_MINE}" ] || CONVERSATION_SEED_MINE="x"

    _cs_t="$(_cs_read_topics)"
    CONVERSATION_SEED_TOPICS_API="$(printf '%s\n' "${_cs_t}" | sed -n 's/^TOPICS_API \([^ ]*\) TOPICS_SPARQL .*/\1/p' | head -1)"
    CONVERSATION_SEED_TOPICS_SPARQL="$(printf '%s\n' "${_cs_t}" | sed -n 's/^TOPICS_API [^ ]* TOPICS_SPARQL \([^ ]*\).*/\1/p' | head -1)"
    [ -n "${CONVERSATION_SEED_TOPICS_API}" ] || CONVERSATION_SEED_TOPICS_API="x"
    [ -n "${CONVERSATION_SEED_TOPICS_SPARQL}" ] || CONVERSATION_SEED_TOPICS_SPARQL="x"

    _cs_j="$(_cs_read_journal)"
    CONVERSATION_SEED_JOURNAL="$(printf '%s\n' "${_cs_j}" | sed -n 's/^JOURNAL \([^ ]*\).*/\1/p' | head -1)"
    [ -n "${CONVERSATION_SEED_JOURNAL}" ] || CONVERSATION_SEED_JOURNAL="x"

    # POPULATED / EMPTY / UNREADABLE. Three states and three words, never two:
    # a store we could not read has not answered 0, and the walk record has
    # been misled by exactly that collapse before.
    _cs_verdict() {
        case "$1" in
            x|'') printf 'UNREADABLE' ;;
            0)    printf 'EMPTY' ;;
            *)    printf 'POPULATED' ;;
        esac
    }
    _cs_v_conv="$(_cs_verdict "${CONVERSATION_SEED_POINTS}")"
    if [ "${CONVERSATION_SEED_TOPICS_API}" = "x" ] || [ "${CONVERSATION_SEED_TOPICS_SPARQL}" = "x" ]; then
        _cs_v_top="UNREADABLE"
    elif [ "${CONVERSATION_SEED_TOPICS_API}" -gt 0 ] 2>/dev/null && [ "${CONVERSATION_SEED_TOPICS_SPARQL}" -gt 0 ] 2>/dev/null; then
        _cs_v_top="POPULATED"
    else
        _cs_v_top="EMPTY"
    fi
    _cs_v_jrn="$(_cs_verdict "${CONVERSATION_SEED_JOURNAL}")"

    printf '  READ-BACK conversations  %-10s points_count=%s of which conversation_id=%s is %s\n' \
        "${_cs_v_conv}" "${CONVERSATION_SEED_POINTS}" "${CONVERSATION_SEED_ID}" "${CONVERSATION_SEED_MINE}"
    printf '  READ-BACK topics         %-10s api=%s sparql=%s\n' \
        "${_cs_v_top}" "${CONVERSATION_SEED_TOPICS_API}" "${CONVERSATION_SEED_TOPICS_SPARQL}"
    printf '  READ-BACK usage journal  %-10s rows with session_id cm048-: %s\n' \
        "${_cs_v_jrn}" "${CONVERSATION_SEED_JOURNAL}"

    # THE JOURNAL ARM, WHICH CANNOT PASS YET AND MUST NOT PRETEND TO. It is
    # reported and it does not decide the exit code: the launch directive makes
    # usage_journal_producers non-blocking for v1.0, and the producer this row
    # needs is a code change in CM048 that has not reached the vendored tree.
    if [ "${_cs_v_jrn}" = "EMPTY" ]; then
        printf '  FINDING: the pipeline completed and wrote NO usage-journal row. The\n'
        printf '  VENDORED vendor/cm048_pipeline carries no usage-journal writer at all\n'
        printf '  -- no costs.jsonl, no record_usage, no prompt_tokens, no OSTLER_USAGE\n'
        printf '  anywhere in it -- so the producer is ABSENT rather than silent, and\n'
        printf '  this is a vendoring gap, not a box defect. It does not change the\n'
        printf '  verdict below: usage_journal_producers is non-blocking for v1.0.\n'
    elif [ "${_cs_v_jrn}" = "UNREADABLE" ]; then
        printf '  The journal file itself was not found, so this is NOT a count of\n'
        printf '  zero and must not be read as one. The resolved path is printed above.\n'
    fi

    if [ "${_cs_v_conv}" = "POPULATED" ] && [ "${_cs_v_top}" = "POPULATED" ]; then
        CONVERSATION_SEED_STATE="seeded"
        printf '  SEEDED AND ASSERTED: one fictional voice note reached the\n'
        printf '  conversations collection and the topic graph through the same binary\n'
        printf '  the product uses, with a real model call.\n'
        printf '  THIS DOES NOT SAY THE FEED WORKS: nothing here ran the LaunchAgent,\n'
        printf '  the tick or the watermark, so nothing here says whether a customer own\n'
        printf '  voice note is ever picked up.\n\n'
        return 0
    fi

    CONVERSATION_SEED_STATE="sinks-refused"
    if [ "${_cs_v_conv}" = "UNREADABLE" ] || [ "${_cs_v_top}" = "UNREADABLE" ]; then
        printf '  CANNOT-RUN: a store did not answer, so the seed cannot say what\n'
        printf '  landed. An UNREADABLE above is a store we could not ask -- a missing\n'
        printf '  credential config, a 401, or a transport failure -- and it is NOT a\n'
        printf '  count of zero. The rows may be there.\n'
    else
        printf '  FINDING: the pipeline completed and a sink is empty.\n'
        if [ "${_cs_v_conv}" = "EMPTY" ]; then
            printf '    conversations EMPTY: step 07 writes the summary point\n'
            printf '    (ingest.py:362-398) and nothing arrived.\n'
        fi
        if [ "${_cs_v_top}" = "EMPTY" ]; then
            printf '    topics EMPTY: step 09 is the LAST of six model calls\n'
            printf '    (processor.py:2082), and it also REFUSES to write on an L3 or a\n'
            printf '    non_relational verdict (topic_writer.py:368-378). The metadata\n'
            printf '    states privacy_level L2 explicitly, which forecloses the L3\n'
            printf '    escalation, so a refusal here is the non_relational arm or a\n'
            printf '    budget exhaustion, not a privacy one.\n'
        fi
        if [ "${CONVERSATION_SEED_TOPICS_API}" != "${CONVERSATION_SEED_TOPICS_SPARQL}" ]; then
            printf '    the two topic instruments DISAGREE (api=%s sparql=%s). The graph\n' \
                "${CONVERSATION_SEED_TOPICS_API}" "${CONVERSATION_SEED_TOPICS_SPARQL}"
            printf '    count is the one that cannot be filtered away; a lower API count\n'
            printf '    is a reader fault, not a writer one.\n'
        fi
    fi
    printf '\n'
    return 1
}

# ---------------------------------------------------------------------------
# FORGET. Remove the seeded conversation once the probes have finished.
#
# ITS OWN IMPLEMENTATION, unlike the other two seeds, which delegate to an OS003
# loader. There is no loader for this one: the pipeline is a product component
# with no --forget, so the deletes are written here against the SAME
# identifiers the writers derive from the conversation id.
#
# DETERMINISTIC, NOT A SWEEP. Every delete is keyed on
# urn:ostler:conversation/<id>, on payload.conversation_id, or on
# sha1(<id>)[:8]. Nothing matches on "recent", on a timestamp or on a wildcard,
# because a walk box is not necessarily empty and a tidy-up that guessed would
# be a data-loss bug wearing the clothes of housekeeping.
#
# THE ONE JUDGEMENT CALL, WRITTEN DOWN. A topic node is keyed by SLUG and is
# SHARED between conversations (topic_writer.py:197-200). Deleting it because
# our conversation mentioned it would remove a topic another conversation still
# points at. So the topic delete carries FILTER NOT EXISTS over mentions from
# any OTHER conversation: a topic only ours goes, a topic anyone else also
# mentions stays. The mention nodes themselves are ours alone and go
# unconditionally.
#
# NEVER FAILS THE WALK. Every measurement is already taken by the time this
# runs, so a tidy-up that could change a verdict would be worse than leaving
# the rows. It returns 0 on every path and says what it removed.
# ---------------------------------------------------------------------------
conversation_seed_forget() {
    case "${CONVERSATION_SEED_STATE}" in
        seeded|sinks-refused) : ;;
        *) return 0 ;;
    esac
    if [ "${OSTLER_CONVO_SEED_KEEP:-0}" = "1" ]; then
        printf -- '--- CONVERSATION SEED: kept on the box (OSTLER_CONVO_SEED_KEEP=1) ---\n\n'
        return 0
    fi
    printf -- '--- CONVERSATION SEED: removing the seeded conversation ---\n'

    _cs_fout="$(_cs_box_exec "
ID=$(_cs_q "${CONVERSATION_SEED_ID}")
SHORT=$(_cs_q "${CONVERSATION_SEED_SHORTID}")
UID_=$(_cs_q "${CONVERSATION_SEED_USER_ID}")
CONF=$(_cs_q "${_CS_STORE_CONF}")
case \"\$CONF\" in \"~/\"*) CONF=\"\$HOME/\${CONF#~/}\" ;; esac
K=''
[ -r \"\$CONF\" ] && K=\"-K \$CONF\"
CURL=$(_cs_q "${_CS_CURL}")
Q=$(_cs_q "${_CS_QDRANT}")
OXI=$(_cs_q "${_CS_OXIGRAPH}")
UPD=\"\${OXI%/query}/update\"
NS=$(_cs_q "${_CS_PWG_NS}")

# 1. Qdrant, filtered on the payload key the ingest writes (ingest.py:355).
#    Counted BEFORE the delete, because a delete endpoint that reports
#    'acknowledged' says nothing about how many rows it touched.
before=\$(\$CURL -sS --noproxy '*' -m 20 \$K -X POST -H 'Content-Type: application/json' \\
  --data '{\"exact\": true, \"filter\": {\"must\": [{\"key\": \"conversation_id\", \"match\": {\"value\": \"${CONVERSATION_SEED_ID}\"}}]}}' \\
  \"\$Q/collections/conversations/points/count\" 2>/dev/null \\
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"result\"][\"count\"])
except Exception:
    print(\"x\")' 2>/dev/null)
\$CURL -sS --noproxy '*' -m 30 \$K -X POST -H 'Content-Type: application/json' \\
  --data '{\"filter\": {\"must\": [{\"key\": \"conversation_id\", \"match\": {\"value\": \"${CONVERSATION_SEED_ID}\"}}]}}' \\
  \"\$Q/collections/conversations/points/delete?wait=true\" >/dev/null 2>&1
qrc=\$?
printf 'QDRANT_POINTS %s rc=%s\n' \"\${before:-x}\" \"\$qrc\"

# 2. The DEFAULT graph: the topic nodes only this conversation mentions, then
#    the mention nodes themselves. In that order: the second delete removes the
#    triples the first one needs to find the topics.
u1=\"DELETE { ?t ?p ?o } WHERE { ?m <\${NS}inConversation> <urn:ostler:conversation/\$ID> ; <\${NS}mentionsTopic> ?t . ?t ?p ?o . FILTER NOT EXISTS { ?m2 <\${NS}mentionsTopic> ?t ; <\${NS}inConversation> ?c2 . FILTER(?c2 != <urn:ostler:conversation/\$ID>) } }\"
u2=\"DELETE { ?m ?p ?o } WHERE { ?m <\${NS}inConversation> <urn:ostler:conversation/\$ID> ; ?p ?o }\"
for u in \"\$u1\" \"\$u2\"; do
  \$CURL -sS --noproxy '*' -m 30 \$K -H 'Content-Type: application/sparql-update' \\
    --data-binary \"\$u\" \"\$UPD\" >/dev/null 2>&1
  printf 'DEFAULT_GRAPH_UPDATE rc=%s\n' \"\$?\"
done
left=\$(\$CURL -sS --noproxy '*' -m 20 \$K -H 'Content-Type: application/sparql-query' \\
  -H 'Accept: application/sparql-results+json' \\
  --data-binary \"SELECT (COUNT(?m) AS ?n) WHERE { ?m <\${NS}inConversation> <urn:ostler:conversation/\$ID> }\" \\
  \"\$OXI\" 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[\"results\"][\"bindings\"][0][\"n\"][\"value\"])
except Exception:
    print(\"x\")' 2>/dev/null)
printf 'MENTIONS_LEFT %s\n' \"\${left:-x}\"

# 3. The NAMED graph urn:ostler:user/<user_id>, where the ingest puts the
#    conversation node and everything that points back at it (ingest.py:540-548:
#    facts and todos via urn:ostler:fromConversation, signals via the
#    conversation URI). Deleting every subject that REFERENCES the conversation
#    catches all three without naming them one at a time.
G=\"urn:ostler:user/\$UID_\"
u3=\"DELETE { GRAPH <\$G> { <urn:ostler:conversation/\$ID> ?p ?o } } WHERE { GRAPH <\$G> { <urn:ostler:conversation/\$ID> ?p ?o } }\"
u4=\"DELETE { GRAPH <\$G> { ?s ?p2 ?o2 } } WHERE { GRAPH <\$G> { ?s ?p <urn:ostler:conversation/\$ID> ; ?p2 ?o2 } }\"
for u in \"\$u3\" \"\$u4\"; do
  \$CURL -sS --noproxy '*' -m 30 \$K -H 'Content-Type: application/sparql-update' \\
    --data-binary \"\$u\" \"\$UPD\" >/dev/null 2>&1
  printf 'NAMED_GRAPH_UPDATE rc=%s\n' \"\$?\"
done

# 4. Disk. The processing state dir, the flat Conversations markdown
#    (ingest.py:288-304) and the four-artefact bundle folder, which is
#    <date>/<slug>-<short id>/ (conversation_writer.py:392-411). The slug is
#    not ours to predict; the short id is sha1(id)[:8] and is.
P=\"\$HOME/.ostler/processing/\$ID\"
if [ -d \"\$P\" ]; then rm -rf \"\$P\"; printf 'PROCESSING_DIR removed %s\n' \"\$P\"; else printf 'PROCESSING_DIR absent\n'; fi
C=\"\$HOME/Documents/Ostler/Conversations\"
if [ -f \"\$C/\$ID.md\" ]; then rm -f \"\$C/\$ID.md\"; printf 'CONVERSATION_MD removed %s\n' \"\$C/\$ID.md\"; else printf 'CONVERSATION_MD absent\n'; fi
if [ ! -d \"\$C\" ]; then
  printf 'BUNDLE_DIRS no Conversations directory\n'
else
  blist=\$(find \"\$C\" -maxdepth 2 -type d -name \"*-\$SHORT\")
  frc=\$?
  if [ \"\$frc\" -ne 0 ]; then
    # An exit code from find is NOT an empty result. Saying 'removed 0' here
    # would be a manufactured zero over a directory we could not read.
    printf 'BUNDLE_DIRS unreadable (find exit %s), nothing removed\n' \"\$frc\"
  else
    nb=0
    # Split on newline only: a bundle path carries a date and a slug, but the
    # home directory above it can carry a space, and default IFS would tear it.
    OIFS=\$IFS
    IFS='
'
    for b in \$blist; do
      [ -n \"\$b\" ] || continue
      rm -rf \"\$b\" && nb=\$((nb + 1))
    done
    IFS=\$OIFS
    printf 'BUNDLE_DIRS removed %s\n' \"\$nb\"
  fi
fi

# 5. The coach row, keyed UNIQUE(conversation_id) (ingest.py:1031-1051). The
#    database may be ENCRYPTED (ingest.py:1022-1027 picks _secure_connect when
#    a key is set), in which case sqlite3 cannot open it and the row is
#    reported LEFT with the reason, never as removed.
DB=\"\$HOME/.ostler/coach/observations.db\"
if [ ! -f \"\$DB\" ]; then
  printf 'COACH_ROW no database\n'
elif ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'COACH_ROW left: no sqlite3 on the box\n'
else
  n=\$(sqlite3 \"\$DB\" \"SELECT COUNT(*) FROM observations WHERE conversation_id = '\$ID';\" 2>/dev/null)
  if [ -z \"\$n\" ]; then
    printf 'COACH_ROW left: the database did not answer (it is encrypted when a key is set, and sqlite3 cannot read that)\n'
  else
    sqlite3 \"\$DB\" \"DELETE FROM observations WHERE conversation_id = '\$ID';\" >/dev/null 2>&1
    printf 'COACH_ROW removed %s\n' \"\$n\"
  fi
fi
" 2>&1)"
    printf '%s\n' "${_cs_fout}" | sed 's/^/    /'
    printf '  Every delete above is keyed on the conversation id, on\n'
    printf '  payload.conversation_id or on sha1(id)[:8]. A topic another\n'
    printf '  conversation also mentions is deliberately left in place.\n'
    printf '\n'
    return 0
}
