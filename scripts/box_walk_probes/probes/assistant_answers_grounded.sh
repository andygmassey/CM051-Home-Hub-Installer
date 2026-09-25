#!/usr/bin/env bash
# probes/assistant_answers_grounded.sh
# ============================================================================
# QUESTION: can a person ask Ostler a question and get an answer grounded in
#           their own data -- not just a reply, but one that reached the graph?
#
# THIS IS THE PROBE THAT WOULD HAVE CAUGHT v1.0.38.
#
# On the walked v1.0.38 box, every other signal was green. Artefact 10/10.
# Daemon up, 25 of 26 LaunchAgents clean. Wiki serving 18k+ populated pages.
# Oxigraph holding 6,848 Person nodes and ~4,022 meetings. Qdrant holding
# 9,879 preferences, 8,761 browsing rows, 377 conversations.
#
# And the assistant answered all four of a new customer's opening questions
# with some form of "I don't know":
#
#   "What do you know about me?"        -> NO tool call at all; recited its own
#                                          previous non-answer back as the one
#                                          fact it held about the customer
#   "Who have I been in contact with?"  -> pwg_person_timeline("most recent
#                                          contact") -- a non-person string
#                                          jammed into a person-scoped tool
#   "Summarise my recent meetings."     -> pwg_person_timeline -> resolved to a
#                                          component supplier in the people graph
#   "Search my PWG, what does it hold?" -> pwg_topics -> "no topics found",
#                                          over 377 conversations
#
# Three independent defects stacked to produce that, each alone sufficient:
# an artefact nothing emitted (#853), no aggregate tool for the opening
# question (#854), and a daemon-side call that filters to nothing and then
# fails to deserialise the reply (#855).
#
# ---------------------------------------------------------------------------
# WHY NO EXISTING PROBE CAUGHT IT, WHICH IS THE POINT OF THIS FILE
#
# Every probe in this suite measures ONE layer and stops there. Stores hold
# data. Services answer. Agents are loaded. Every one of those was true and
# stayed true while the product was broken, because the breaks were in the
# JOINS between layers -- a writer and a reader disagreeing on a path, a tool
# and an API disagreeing on a filter value.
#
# Nothing crossed from "the store has data" to "a human gets an answer". This
# probe is the only one that spans the whole chain, so it is the only one that
# can fail when the joins are wrong and every layer is individually healthy.
#
# ---------------------------------------------------------------------------
# WHAT IT ASSERTS, AND WHY NOT THE ANSWER TEXT
#
# It adjudicates the FRAME STREAM, never the prose:
#
#   grounded      >=1 tool_call, no tool_result carried an error, turn completed
#   no_tool_call  the model never attempted retrieval          <- Q1's shape
#   tool_error    retrieval was attempted and failed           <- #855's shape
#   incomplete    no `done` frame: timed out or died mid-turn
#
# Asserting on answer TEXT would be flaky (the model rephrases) and would print
# the operator's personal data into a log that lands in support bundles. The
# structural signal is the one that was actually wrong, and it is deterministic.
#
# This is `[[feedback_assert_the_defect_not_its_formatting]]`: a predicate
# pinned to a rendering goes green-while-blind AND red-while-fixed.
#
# ---------------------------------------------------------------------------
# RUNTIME -- READ THIS BEFORE ADDING QUESTIONS
#
# Each question is a full LLM turn against local Ollama. On a Mac mini under
# first-run ingest load that measured 2-5 MINUTES per turn. The default battery
# of 3 is therefore up to ~15 minutes, far and away the slowest probe here.
# That is the honest price of testing the product instead of the plumbing.
# OSTLER_PROBE_CHAT_TIMEOUT tunes the per-turn ceiling.
#
# ---------------------------------------------------------------------------
# THE ROUTE, because I got this wrong for an entire session
#
# The chat endpoint is a WEBSOCKET at /ws/chat on the gateway (:8000), NOT an
# HTTP POST. `/api/chat` belongs to the vendored Ollama provider crate
# (zeroclaw-providers/src/ollama.rs) and is not our route at all -- every 405
# I reported against it was me knocking on a fixture's door.
#
# Auth is a PAIRING token (zeroclaw-config/src/pairing.rs::is_authenticated).
# The admin token satisfies it, which is what this probe uses. ⚠️ A REAL
# CUSTOMER REACHES THIS ONLY THROUGH iOS PAIRING, so a green here means
# "answerable", NOT "reachable by a customer" -- see #637-#641.
#
# Runs under bash 3.2. No associative arrays, no mapfile.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="assistant_answers_grounded"
PROBE_QUESTION="can a person ask Ostler a question and get an answer that reached their own data?"

# 🔴 THE DEFAULT STRADDLED THE DOCUMENTED NORMAL RANGE. This file's own runtime
# note, forty lines above, records "2-5 MINUTES per turn" on a Mac mini under
# first-run ingest load. The ceiling was 240s -- FOUR minutes -- so a turn inside
# the measured normal range could exceed it, and every turn that did was reported
# as the assistant failing to reach the customer's data. Raised to seven minutes,
# which is above the top of the range this file itself measured.
CHAT_TIMEOUT="${OSTLER_PROBE_CHAT_TIMEOUT:-420}"
GATEWAY="${OSTLER_PROBE_GATEWAY:-http://127.0.0.1:8000}"
# TILDE, NOT $HOME. Python's os.path.expanduser expands `~` and leaves `$VAR`
# untouched -- `expanduser("$HOME/x")` returns "$HOME/x" verbatim. The first
# version of this line used $HOME, the client could not find the token, and
# every turn came back PROBE_FATAL no_token. Measured, not reasoned about.
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}"

# ── THE CONTENT ASSERTION (Aesop, 2026-09-07) ───────────────────────────────
#
# This probe adjudicated on FRAME SHAPES ONLY: a pwg_ tool fired, returned
# OK, the turn completed -> grounded. The defect that shape passes was
# measured AD HOC on a v1.0.74 box and is recorded in ostler-assistant
# b4118b45's commit message (2026-09-07): a person seeded through
# POST /api/v1/memory/assert with her employer in the fact text; both
# /people/context and /people/{slug}/enrichment served that sentence; the
# assistant called pwg_people, got OK, and answered that it "does not
# explicitly state where she works". The shape this probe scored GREEN.
#
# PROVENANCE, corrected 2026-09-08. Until then this header called that "the
# v1.0.74 seeded walk". No such walk exists: the v1.0.74 walk log ran the
# three unseeded questions and FAILED [no_tool_call] [tool_found_nothing].
# The measurement is the commit message's, not a walk record's, and that
# commit capped its own claim: "Item 9 word: MERGED on merge. It is not
# PROVEN until a walk seeds ..." So this header did not merely write "walk"
# for "run"; it asserted a walk where its source had written MERGED, which
# is the item 9 failure mode, not a typo. A blocking probe that passes a
# wrong answer is worse than none, and a header that upgrades its source's
# word is the same disease one layer up.
#
# THE FIRST SEEDED WALK TURN: v1.0.75, 2026-09-08, Archie on the cold box.
# OS003 gates/seed/load_seed.py (memory/assert -> PersonFact ->
# /people/context) printed SEED-LOAD OK with 5 facts asserted and 5 read
# back, the fixture fact present. The seeded fourth question ran with
# OSTLER_GATE_KNOWN_PERSON / OSTLER_GATE_EXPECT_FACT set for the first time;
# its verdict: grounded, i.e. FRAME reply_fact YES. The reply CARRIED
# "cable engineer at example.com", a fact that reached the model only by
# memory/assert -> PersonFact -> /people/context facts[] -> pwg_people. Run
# 04:31:45Z to 04:36:00Z uncapped, 4 of 4 questions asked (the battery
# declares 4). That is b4118b45 PROVEN at the reply hop, on the published
# v1.0.75 artefact, by the run its own author asked for.
#
# THE PROBE'S VERDICT ON THAT WALK WAS STILL FAIL, and the good half does not
# bury it: unseeded question 1 [no_tool_call], unseeded question 2
# [tool_found_nothing:pwg_preferences], "2 of 4 questions COMPLETED without
# reaching the customer's own data". Neither is the facts projection. The fix
# is proven; the probe is not green; assistant_answers_grounded stays FAIL on
# walks/v1.0.75.tsv. The synthetic person was removed afterwards
# (load_seed.py --forget, rc=0, bare, no pipe).
#
# So the SEEDED turn asserts CONTENT: the reply must CARRY the fixture fact.
# The mechanism mirrors OS003 gates/verify_behavioural_acceptance.sh check 1
# (OSTLER_GATE_EXPECT_FACT, case-insensitive fixed-string containment) rather
# than inventing one. The frame-shape checks stay as the FIRST gate -- no tool
# call is still a fail -- and the fact-carried assertion is the verdict.
#
# PRIVACY IS KEPT. The reply prose is still never printed: the containment
# is computed ON THE BOX by the client and only the boolean crosses the wire
# as `FRAME reply_fact YES|NO`. Unseeded questions emit no such frame and are
# adjudicated exactly as before.
#
# Set OSTLER_GATE_EXPECT_FACT (and OSTLER_GATE_KNOWN_PERSON) to add the seeded
# turn; the seed oracle in OS003 gates/seed/ is where those values come from.
EXPECT_FACT="${OSTLER_GATE_EXPECT_FACT:-}"
KNOWN_PERSON="${OSTLER_GATE_KNOWN_PERSON:-}"
SEEDED_QUESTION="${OSTLER_GATE_QUESTION:-Who is ${KNOWN_PERSON} and where do they work?}"

# ── The WebSocket client, embedded ──────────────────────────────────────────
# Dependency-free: raw socket + the RFC 6455 handshake and framing. It is
# embedded rather than shipped alongside so the probe cannot half-exist on a
# box, and base64'd so it survives being passed as a single shell command to
# either `sh -c` locally or ssh remotely.
_ws_client_py() {
    cat <<'PYEOF'
import base64, json, os, re, socket, struct, sys, time
# THE CONTENT PREDICATE, TWO READINGS, BOTH PRINTED.
#
# Until 2026-09-10 the only reading was the fixture phrase as a fixed string,
# case-insensitive, anywhere in the reply (the OS003 check 1 mirror). That is a
# test of PHRASING, not of grounding: on the v1.0.89 walk the box answered
# "<person> is a submarine cable engineer who works at example.com" and the
# probe read NO, because four words sit between the halves of "cable engineer
# at example.com". Five captured turns that night carried every component of
# the fact and scored NO on all five; the record read FAILED on a correct
# answer.
#
# carries() is now order-free over the fact's distinctive components: every
# word of the fixture phrase that is not a function word must appear in the
# reply. A reply that omits the employer still reads NO; a reply that
# paraphrases reads YES. carries_phrase() keeps the exact-substring reading and
# is printed beside it (FRAME reply_fact_phrase, FRAME tool_fact_phrase) as
# evidence, so a record shows both and a reader can see which one moved.
# --self-check drives the SAME predicate the walk does; --self-check-phrase
# drives the old one.
#
# Each component must match as a whole token (alphanumeric boundaries), so
# "cables engineered at example.common" does not satisfy cable, engineer,
# example.com (TNM, #1916 review; measured). Boundaries rather than a length
# floor, because a real component can be a three-letter role or an initialism.
#
# A PROPERTY TO KNOW, NOT FIXED HERE: order-freedom means a reply that DENIES
# the fact while echoing its words ("I could not find a cable engineer at
# example.com in your data") grades YES. The exact-phrase reading has the same
# hole whenever the denial quotes the phrase. A negation check would be a
# phrase list that fails OPEN on this surface (a missed phrasing grades a
# wrong answer PASS), so it is not added; the trade taken is a measured false
# FAIL on every correct paraphrase (five for five, 2026-09-10) against a
# hypothetical false PASS on a denial no captured turn has produced.
_FUNCTION_WORDS = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "is",
                   "of", "on", "or", "the", "to", "with"}
def components(fact):
    return [w for w in re.split(r"[^a-z0-9.@'-]+", fact.lower())
            if w and w not in _FUNCTION_WORDS]
def carries_phrase(text, fact):
    return fact.lower() in text.lower()
def carries(text, fact):
    cs = components(fact)
    t = text.lower()
    return bool(cs) and all(
        re.search(r"(?<![a-z0-9])" + re.escape(c) + r"(?![a-z0-9])", t) for c in cs)
if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
    print("YES" if carries(sys.stdin.read(), sys.argv[2]) else "NO"); sys.exit(0)
if len(sys.argv) > 1 and sys.argv[1] == "--self-check-phrase":
    print("YES" if carries_phrase(sys.stdin.read(), sys.argv[2]) else "NO"); sys.exit(0)
host, port = "127.0.0.1", int(sys.argv[1])
token_path, question, deadline_s = sys.argv[2], sys.argv[3], float(sys.argv[4])
expect_fact = sys.argv[5] if len(sys.argv) > 5 else ""
try:
    token = open(os.path.expanduser(token_path)).read().strip()
except Exception as e:
    print("PROBE_FATAL no_token %s" % e); sys.exit(3)
deadline = time.time() + deadline_s
# FIXTURE MODE, for the parser's own tests: OSTLER_GROUNDED_FRAMES names a file
# of one JSON event per line, read in place of the websocket. Nothing else
# changes, so the arms below grade a recorded stream exactly as a live one.
_frames_file = os.environ.get("OSTLER_GROUNDED_FRAMES")
if _frames_file:
    _fx = open(_frames_file, "rb").read().split(b"\n")
    _fx = [l for l in _fx if l.strip()]
    def frame():
        if not _fx: return 8, b""
        return 1, _fx.pop(0)
    def send(p): pass
else:
  try:
    s = socket.create_connection((host, port), timeout=20)
  except Exception as e:
    print("PROBE_FATAL no_connect %s" % e); sys.exit(3)
  key = base64.b64encode(os.urandom(16)).decode()
  s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
             "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
             "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n"
             "Authorization: Bearer %s\r\n\r\n" % (host, port, key, token)).encode())
  buf = b""
  while b"\r\n\r\n" not in buf:
      c = s.recv(4096)
      if not c:
          print("PROBE_FATAL handshake_eof"); sys.exit(3)
      buf += c
  head, rest = buf.split(b"\r\n\r\n", 1)
  status = head.split(b"\r\n")[0].decode(errors="replace")
  if "101" not in status:
      print("PROBE_FATAL handshake %s" % status); sys.exit(3)
  def send(p):
      d = p.encode(); m = os.urandom(4)
      mk = bytes(b ^ m[i % 4] for i, b in enumerate(d)); n = len(d)
      if n < 126:      h = struct.pack("!BB", 0x81, 0x80 | n)
      elif n < 65536:  h = struct.pack("!BBH", 0x81, 0x80 | 126, n)
      else:            h = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
      s.sendall(h + m + mk)
      _t_sent = time.time()   # TTFT clock starts at the LAST byte of the request
  def rd(n):
      global rest
      o = b""
      while len(o) < n:
          if rest:
              t = rest[: n - len(o)]; o += t; rest = rest[len(t):]
          else:
              s.settimeout(max(1, deadline - time.time()))
              c = s.recv(65536)
              if not c: raise EOFError
              rest = c
      return o
  def frame():
      b0, b1 = rd(2); op = b0 & 0x0F; n = b1 & 0x7F
      if n == 126:   n = struct.unpack("!H", rd(2))[0]
      elif n == 127: n = struct.unpack("!Q", rd(8))[0]
      return op, rd(n)
send(json.dumps({"type": "message", "content": question}))
# Emit ONLY frame types and tool outcomes. Never the answer prose: it is the
# operator's personal data and this transcript lands in support bundles. The
# prose is ACCUMULATED here only so the seeded turn can answer one yes/no
# question about it on the box; it is never written out.
# ── TIMING, PER TNM 2026-09-17. Emitted as frames, never averaged here.
# TTFT is measured from the last byte of the request to the FIRST token that
# carries content -- not to the first frame of any kind, because tool_call and
# status frames arrive earlier and would flatter the number.
# tok/s is over the WHOLE response: tokens counted / (end - first token).
# COLD vs WARM is NOT decided here: this process cannot see whether the model
# was resident before it connected. The probe reads `ollama ps` on the box
# BEFORE each opening and labels the row. Blending the two is what makes a
# TTFT figure useless, and they differ by an order of magnitude.
# _t_sent IS INITIALISED HERE TOO, NOT ONLY AT THE SEND. FIXTURE MODE
# (OSTLER_GROUNDED_FRAMES) never calls sendall, so a _t_sent that exists only
# on the live path is UNDEFINED under the parser's own tests -- and a NameError
# in this loop reads downstream as an EMPTY answer, which is how it presented:
# five arms reporting "read ''" rather than anything mentioning time.
_t_sent = None
_t_first = None
_t_last = None
_tok = 0
text = ""
while time.time() < deadline:
    try: op, pay = frame()
    except Exception: print("FRAME timeout"); break
    if op == 8: print("FRAME close"); break
    if op != 1: continue
    try: ev = json.loads(pay)
    except Exception: print("FRAME unparseable"); continue
    t = ev.get("type", "?")
    if t == "tool_call":
        print("FRAME tool_call %s" % ev.get("name", "?"))
        # WAS THE CALL FILTERED, AND BY HOW MUCH TEXT.
        #
        # The frame stream records tool NAMES and nothing else, so a tool that
        # asked the wrong question and a tool whose origin had nothing produce
        # identical records. Measured 2026-09-09: /api/v1/topics returns 35
        # topics unfiltered, and pwg_topics reported finding nothing on the
        # same box. The tool sends /api/v1/topics?q=<text> when the model
        # supplies a query, and the origin applies q as a case-insensitive
        # SUBSTRING of the label or slug, so a question passed as a filter
        # matches nothing. Whether that happened is not recorded anywhere.
        #
        # KEYS AND LENGTHS, NEVER VALUES. These lines are probe STDOUT, not the
        # committed record: measured, zero FRAME lines appear in any of the 15
        # files under walks/, and neither run_box_walk.sh nor post_walk_qa.sh
        # references FRAME at all. But stdout is routinely pasted into public
        # PRs, issues and channel posts, so values never go in either. A tool
        # argument can carry a person's name or a search term about them; the
        # key names and a length answer "did it filter, and with roughly what"
        # without carrying the content.
        #
        # THE REASON MATTERS AS MUCH AS THE RULE. An earlier draft of this
        # comment justified the discipline with "this record is committed to a
        # public repo", which is false of FRAME lines. A caution with a wrong
        # justification is fragile in a specific way: the next reader checks
        # whether FRAME lines reach the record, finds they do not, and concludes
        # the caution is unnecessary. State the true reason or the rule dies of
        # its own footnote.
        _a = ev.get("arguments")
        if isinstance(_a, str):
            try: _a = json.loads(_a)
            except Exception: _a = None
        if isinstance(_a, dict):
            _parts = []
            for _k in sorted(_a.keys()):
                _v = _a.get(_k)
                _parts.append("%s=%s" % (_k, ("len%d" % len(_v)) if isinstance(_v, str) else "nonstr"))
            print("FRAME tool_args %s %s" % (ev.get("name", "?"), ",".join(_parts) if _parts else "none"))
        else:
            print("FRAME tool_args %s unreadable" % ev.get("name", "?"))
    elif t == "tool_result":
        out = str(ev.get("output", "")); low = out.lstrip().lower()
        # THREE outcomes, not two. A tool that succeeds and announces an empty
        # set is not retrieval -- "No person matching X was found" carries no
        # error prefix and would otherwise score as a clean hit. That is the
        # #810 shape (success-shaped emptiness) and it gets its own marker.
        if low.startswith("error"):
            mark = "ERR"
        elif ("no " in low[:40] and (" found" in low or " were found" in low)) \
                or "there are no " in low or low.startswith("none"):
            mark = "EMPTY"
        else:
            mark = "OK"
        print("FRAME tool_result %s %s" % (ev.get("name", "?"), mark))
        # DID THE TOOL RESULT ITSELF CARRY THE SEEDED FACT?
        #
        # Without this, a fact_missing verdict is un-diagnosable from the
        # record. OK means "not an error and not success-shaped emptiness"; it
        # does NOT mean the output contained what was asked for. So a tool that
        # returned a person with no employer in it and a model that was handed
        # the employer and ignored it produce the SAME verdict and the same
        # frames, and they are different defects with different owners.
        #
        # Measured 2026-09-09 on the v1.0.81 walk: one fact_missing, and
        # nothing in the record could say which of the two it was. The daemon
        # plumbing was cleared separately and offline (ostler-assistant, a
        # fixture driving the real turn loop and reading what the provider was
        # handed), which left exactly these two, and neither is visible here.
        if expect_fact:
            print("FRAME tool_fact %s" % ("YES" if carries(out, expect_fact) else "NO"))
            print("FRAME tool_fact_phrase %s" % ("YES" if carries_phrase(out, expect_fact) else "NO"))
    elif t == "chunk":
        _c = ev.get("content") or ""
        if _c:
            # FIRST CONTENT token, not first frame. Set once.
            if _t_first is None: _t_first = time.time()
            _t_last = time.time()
            # Token count approximated by whitespace-delimited words. The
            # gateway does not report token counts on this stream, so this is
            # a WORD rate wearing a token name if reported as tokens. It is
            # emitted as tok_per_s because that is the figure asked for, and
            # the approximation is stated here rather than hidden: for English
            # prose it runs ~0.75 of the true token count, consistently, so it
            # is comparable BETWEEN runs even though it is not exact.
            _tok += len(_c.split())
        text += _c
    elif t in ("done", "session_start", "error", "chunk_reset"):
        # THE CLIENT DISCARDS THE DRAFT ON chunk_reset AND SHOWS full_response.
        # The gateway sends chunk_reset then done{full_response} on every turn
        # (ws.rs), and the 0.4.79 omission guard puts a corrected reply ONLY
        # in full_response. Until 2026-09-10 this parser graded the chunk
        # accumulator, so a turn the guard corrected scored fact_missing
        # exactly like one it did not. Grade what the customer reads:
        # full_response when the daemon sent the key (an EMPTY one is a real
        # empty answer, graded NO, never a silent fall back to the draft);
        # the chunks only when the key is absent, the pre-full_response shape.
        if t == "chunk_reset":
            text = ""
        if t == "done" and expect_fact:
            if "full_response" in ev:
                graded = ev.get("full_response") or ""
                print("FRAME reply_source full_response%s" % ("" if graded.strip() else " EMPTY"))
            else:
                graded = text
                print("FRAME reply_source chunks")
            if _t_first is not None and _t_sent is not None:
                print("FRAME ttft_s %.3f" % (_t_first - _t_sent))
                _span = (_t_last - _t_first) if (_t_last and _t_last > _t_first) else 0.0
                # A zero span with tokens is a single-frame reply, not an
                # infinite rate. Report NOT-MEASURED rather than divide.
                if _span > 0:
                    print("FRAME tok_per_s %.2f" % (_tok / _span))
                else:
                    print("FRAME tok_per_s NOT-MEASURED single-frame-reply")
                print("FRAME tokens %d" % _tok)
            else:
                print("FRAME ttft_s NOT-MEASURED no-content-token-arrived")
            print("FRAME reply_fact %s" % ("YES" if carries(graded, expect_fact) else "NO"))
            print("FRAME reply_fact_phrase %s" % ("YES" if carries_phrase(graded, expect_fact) else "NO"))
        print("FRAME %s" % t)
        if t in ("done", "error"): break
PYEOF
}

# ── THE ADJUDICATOR ─────────────────────────────────────────────────────────
# WHICH SIDE LOST THE SEEDED FACT: the retrieval or the model.
#
# A fact_missing verdict names a wrong answer and says nothing about whose
# fault it was, and the two have different owners. `FRAME tool_result X OK`
# means "not an error and not success-shaped emptiness"; it does NOT mean the
# output contained what was asked for. So a tool that returned a person with no
# employer in it, and a model that was handed the employer and ignored it,
# produce the same verdict and the same frames.
#
# Measured 2026-09-09 on the v1.0.81 walk: one fact_missing, and nothing in the
# record could say which. The daemon plumbing was cleared separately and offline
# (a fixture driving the real turn loop and reading what the provider was
# handed), which leaves exactly these two and neither was visible here.
#
# A named function over a TRANSCRIPT FILE so the self-test drives the same code
# the walk runs. grep -c, never `| grep -q`: this file runs under pipefail.
_fact_missing_side() {   # _fact_missing_side <transcript>
    if [ "$(grep -c '^FRAME tool_fact YES$' "$1")" -gt 0 ]; then
        echo "ignored"
    else
        echo "not_retrieved"
    fi
}

# A named function over a TRANSCRIPT FILE. The self-test drives this exact
# function over planted fixtures, so the control exercises the real judgement
# and not a re-implementation of it. Echoes one verdict word.
# ⚠️ THE PREDICATE MUST NAME THE *GRAPH* TOOLS, NOT ANY TOOL.
#
# v1 of this function scored "any successful tool call" as grounded, and the
# very first live run showed why that is worthless. Asked "who have I been in
# contact with recently?", the assistant called `memory_recall` -- the CHAT's
# own history -- and got back:
#
#   "Found 5 memories:
#    - [daily] daily_2026-08-21_...: The user asked for a summary of their
#      recent meetings, and the assistant reported that no recent meetings
#      were found.
#    - [conversation] user_msg: Who have I been in contact with r..."
#
# It retrieved its own previous non-answer and the user's own question. A
# structural success and the exact opposite of grounding. v1 scored it GREEN.
#
# So `grounded` now requires a call to a PWG tool -- the ones that read the
# customer's graph -- and `memory_only` is its own verdict rather than a pass.
# This is the probe's own instance of "instrument and defect on different
# surfaces": my first predicate watched the wrong object.
_GRAPH_TOOL_RE='^FRAME tool_call pwg_'

# ── ROW 1125: A pwg_ PREFIX IS STILL NOT AN ANSWER ───────────────────────────
#
# The paragraph above closed the any-tool hole: `memory_recall` no longer
# scores as grounding. It did NOT close the hole one level up, and #1125
# measured it. Studio, same system prompt, same six tool descriptions lifted
# from the running daemon, n=10 per cell, quantisation the only variable:
#
#   "What are my interests?"
#     gemma4:e2b         Q4_K_M  ->  pwg_overview 9/10 · pwg_preferences 1/10
#     gemma4:e2b-it-q8_0 Q8_0    ->  pwg_preferences 10/10
#
# THE PROBE SCORED BOTH ROWS 10/10 GROUNDED. They are not the same product
# behaviour. `pwg_overview` returns "how many people, meetings, conversations
# and compiled preferences your graph contains" -- an INVENTORY COUNT. A
# customer who asks what their interests are and is told their graph holds
# 9,879 preferences has not been told their interests. The probe reported the
# same verdict for both, so every `grounded` it has emitted is weaker than it
# reads.
#
# WHAT IS ENFORCED, AND WHY IT IS A TRANSCRIPTION RATHER THAN A JUDGEMENT.
#
# #1125's own thread warned that "enforcing one expected tool per question
# makes the probe brittle, because several pwg tools can legitimately answer
# the same question", and that picking the tool is "a judgement about what a
# good answer is". It would be, if the mapping had no source. It has one: the
# ROUTING GUIDANCE THE PRODUCT ITSELF SHIPS, which the sibling probe
# assistant_prompt_names_every_pwg_tool already pins clause by clause:
#
#   "For a BROAD opener about the user, call `pwg_overview` FIRST. For a
#    person call `pwg_people`; history `pwg_person_timeline`. Tastes -- what
#    they are interested in, enjoy, are into -- `pwg_preferences`. Notes
#    `pwg_knowledge_search`. Decisions `pwg_decisions`; topics `pwg_topics`;
#    owed `pwg_commitments`."
#
# Each battery question matches exactly ONE of those clauses, and its store
# set is that clause's tools, copied. So the mapping is not an opinion about
# good answers; it moves when the shipped guidance moves, and the self-test
# refuses if it ever names a tool the runtime does not register.
#
# THE BROAD OPENER IS DELIBERATELY UNCONSTRAINED, and that is not an oversight
# to be tightened later. The shipped guidance places NO store restriction on a
# broad opener -- it says call overview first, not only overview -- so a probe
# that restricted it would go red on a model following the product's own
# instruction. That is the #1597 disease (the fix and the gate fighting each
# other) and it is not being reintroduced here to make a number look better.
# The self-test's anti-vacuity arm requires at least one question to declare a
# PROPER SUBSET, so an all-8 row cannot quietly spread to the whole battery.
#
# Every pwg_* tool the runtime registers. They sit behind one `pwg_people.enabled`
# gate and move as a set; the self-test cross-reads the sibling probe's
# REQUIRED_TOOLS and refuses if the two disagree, because a battery naming a
# tool the runtime never registers is a gate that can never be satisfied, and
# one silently missing a tool narrows what counts as an answer.
_TOOL_REGISTRY='pwg_overview pwg_people pwg_person_timeline pwg_preferences pwg_knowledge_search pwg_decisions pwg_topics pwg_commitments'

# Did any tool in the set carry this result mark? A named function over a
# TRANSCRIPT FILE, so the self-test drives the same code the walk runs.
# `if grep -q`, never a bare trailing grep: this file runs under pipefail and
# a function whose last command is a failed grep returns non-zero to callers
# that are reading its ECHO, not its status.
_result_mark() {   # _result_mark <transcript> <OK|ERR|EMPTY> <space-separated tools>
    _rm_t="$1"; _rm_m="$2"
    # shellcheck disable=SC2086  # $3 is a tool SET and must word-split
    for _rm_x in $3; do
        if grep -q "^FRAME tool_result ${_rm_x} ${_rm_m}\$" "$_rm_t"; then return 0; fi
    done
    return 1
}

adjudicate_turn() {
    _t="$1"
    # THE STORE SET FOR THIS QUESTION (#1125). An EMPTY set is a REFUSAL, never
    # a pass. A question with no declared store set has not been adjudicated,
    # and a gate that grades an unmapped question is grading nothing -- the
    # zero-denominator shape this whole file exists to refuse.
    _accept="${2:-}"
    grep -q '^PROBE_FATAL' "$_t" && { echo "fatal"; return; }
    grep -q '^FRAME done$' "$_t" || { echo "incomplete"; return; }
    grep -q '^FRAME tool_call ' "$_t" || { echo "no_tool_call"; return; }
    # A tool ran, but was it one that reads the customer's own graph?
    grep -qE "$_GRAPH_TOOL_RE" "$_t" || { echo "memory_only"; return; }
    # THE CONTENT ASSERTION, ahead of every frame-shape pass. A seeded turn
    # whose reply did not carry the fixture fact is a wrong answer whatever
    # its tool results said -- this is the exact shape that scored green on
    # a v1.0.74 box (pwg_people OK, then "no explicit information"; recorded
    # in ostler-assistant b4118b45's commit message, not a walk). It
    # sits after the frame gates on purpose: no tool call is still no_tool_call.
    grep -q '^FRAME reply_fact NO$' "$_t" && { echo "fact_missing"; return; }
    # ── A RECOVERED TURN IS NOT A FAILED ONE ────────────────────────────────
    #
    # This used to ask "did anything ever go wrong", by grepping the WHOLE
    # transcript for an ERR. The question the probe exists to answer is "did
    # the customer get an answer that reached their own data", and those are
    # different questions on any turn that errored and then recovered.
    #
    # AND THE PRODUCT IS BUILT TO RECOVER. person_query::not_a_name_error is
    # DELIBERATELY worded to make the model retry -- call pwg_overview first,
    # then call the person tool again. That was the #854 fix. So every turn
    # where the model first reaches for a person tool with a non-name argument
    # emits one ERR, recovers, and answers correctly -- and this BLOCKING probe
    # scored it as a product failure. The fix and the gate worked against each
    # other, and the gate would hold a promote on a turn that behaved exactly
    # as designed.
    #
    # So: a SUCCESSFUL graph read anywhere in the turn is the thing being
    # measured, and it outranks an error that the model recovered from. An
    # error only decides the verdict when nothing succeeded.
    #
    # ⚠️ AMENDED BY #1125, AND THE AMENDMENT IS THE POINT OF BOTH ROWS. "A
    # successful graph read" is now "a successful read OF A STORE THAT COULD
    # HOLD THE ANSWER". The probe's own `recovered` fixture was itself an
    # instance of #1125's blindness: pwg_person_timeline ERR then pwg_overview
    # OK, on a question about the customer's CONTACTS, scored grounded because
    # some pwg tool returned OK. The model consulted the index and never went
    # back for the data, which is HALF the recovery person_query's error text
    # asks for -- its wording is "call pwg_overview first and then call the
    # person tool AGAIN". The full recovery still scores grounded and is
    # fixture-pinned below; the half one now scores tool_error, because the
    # person store was tried, failed, and nothing ever read it successfully.
    [ -n "$_accept" ] || { echo "no_expected_tools"; return; }
    _result_mark "$_t" OK "$_accept" && { echo "grounded"; return; }
    # The right store was TRIED and broke, or was tried and was empty. Both are
    # more specific and more actionable than "some other store answered", so
    # they outrank wrong_store.
    _result_mark "$_t" ERR "$_accept" && { echo "tool_error"; return; }
    # A truthful "no such person" lands here -- see the client's EMPTY mark,
    # which flags a result whose body announces an empty set. Success-shaped
    # emptiness is the #810 shape and must not read as retrieval.
    _result_mark "$_t" EMPTY "$_accept" && { echo "tool_found_nothing"; return; }
    # #1125's measured shape: a graph tool succeeded and its store cannot hold
    # what was asked for. Retrieval happened; it read the wrong shelf. Not a
    # FAIL of retrieval, so it keeps its own word rather than borrowing
    # tool_error's, exactly as memory_only does one gate above.
    grep -q '^FRAME tool_result pwg_.* OK$' "$_t" && { echo "wrong_store"; return; }
    grep -q '^FRAME tool_result pwg_.* ERR$' "$_t" && { echo "tool_error"; return; }
    grep -q '^FRAME tool_result pwg_.* EMPTY$' "$_t" && { echo "tool_found_nothing"; return; }
    # ── #1597 / ZERO DENOMINATOR: NOTHING WAS OBSERVED, SO NOTHING PASSED ────
    #
    # 🔴 THIS LINE USED TO READ `echo "grounded"`. Measured on origin/main
    # e0fb21bf, three transcripts in which NO pwg tool_result frame was ever
    # seen -- a pwg tool CALLED and no result frame at all, a result frame the
    # client could not parse (`FRAME unparseable`), and a pwg call whose only
    # result came from a non-pwg tool -- each adjudicated `grounded`. Zero
    # successful reads, zero errors, zero empties, and the probe reported the
    # customer's data had been reached. A negative control on the same function
    # returned tool_error and memory_only, so the reader was alive and the
    # uniform answer was the defect.
    #
    # A graph call whose outcome was never observed is not a pass and not a
    # fail: it is lost coverage on that turn, and it routes to UNMEASURED so
    # the probe reports CANNOT-RUN rather than a clean sheet.
    echo "no_tool_result"
}

# ── NAME THE TOOL, NOT ONLY THE SHAPE ───────────────────────────────────────
#
# `tool_error` says retrieval was attempted and failed. It does not say WHICH
# tool failed, and the transcript line it was decided from carries the name:
#
#     FRAME tool_result pwg_topics ERR
#
# So the operator reads "[tool_error]" and has to go back to the raw transcript
# to learn anything actionable. Traced end to end, an ERR frame means the tool
# returned success=false and the runtime wrapped it as `Error: {reason}`
# (agent/tool_execution.rs), so the tool name is the first real lead there is.
#
# The ADJUDICATOR'S WORD IS DELIBERATELY UNCHANGED. Its eight-fixture self-test
# pins those words exactly, and widening the vocabulary would either break that
# control or force it to accept a looser match. The name is appended to the
# DETAIL only, which is the same thing line ~318 already does for `fatal`.
#
# The name is one of OUR OWN tool identifiers, never customer data.
_offending_tool() {
    case "$2" in
        tool_error)
            sed -n 's/^FRAME tool_result \(pwg_[A-Za-z0-9_]*\) ERR$/\1/p' "$1" | head -1 ;;
        tool_found_nothing)
            sed -n 's/^FRAME tool_result \(pwg_[A-Za-z0-9_]*\) EMPTY$/\1/p' "$1" | head -1 ;;
        # #1125. wrong_store's only actionable fact is WHICH store answered:
        # "[wrong_store]" alone reads as a routing mystery, "[wrong_store:
        # pwg_overview]" names the inventory tool that answered a content
        # question and is the whole finding. Capped at the first with head -1,
        # the same cap the two arms above use.
        wrong_store)
            sed -n 's/^FRAME tool_result \(pwg_[A-Za-z0-9_]*\) OK$/\1/p' "$1" | head -1 ;;
    esac
}

# WHICH VERDICTS ARE A PRODUCT DEFECT, AND WHICH ARE SIMPLY NOT A MEASUREMENT.
#
# 🔴 EVERY NON-`grounded` VERDICT USED TO BE A FAIL, INCLUDING A TIMEOUT. So a
# turn that never finished was reported as "did not reach the customer's own
# data" -- a claim about the SHIPPED ARTEFACT, asserted on a clock. On a blocking
# probe whose subject is the product's core promise.
#
# This is the same class as the pairing probe's non-answer, fixed hours earlier
# in this same suite: a refusal and a non-answer are different findings, and only
# one of them is about the product.
#
#   defect     the turn COMPLETED and the answer did not reach the graph
#   unmeasured the turn never completed, or the client never started
#
# An unrecognised verdict is UNMEASURED, not a defect. Claiming a product failure
# on a token the classifier does not recognise is the very error being fixed.
# ── DECLARED REPHRASING PAIRS (#1162) ───────────────────────────────────────
# Two battery members a customer would consider the same question. Until this
# existed the battery held three DISTINCT questions, so the strongest thing a
# walk record could say was "1 of 3 failed". That reads as a RATE, and a rate
# is neither reproducible nor actionable. What was actually measured on the
# walk box (ostler-hub, hub-v0.4.64, gemma4:e2b, 2026-08-27, three separate
# runs, surviving an interposed unrelated turn) was not a rate:
#
#   "What subjects am I most drawn to?"  -> tool_call pwg_preferences, OK
#   "What are my interests?"             -> no tool_call at all
#
# ONE EXACT STRING fails every time while a semantically identical rephrasing
# grounds. That is a defect with a repro case, and seeing it requires two
# questions that mean the same thing.
#
# Both members carry the SAME store set in the battery above, deliberately:
# they are the same question, so a routing map that treated them differently
# would make an asymmetry here unreadable.
_rephrasing_pairs() {
    printf '%s\t%s\n' 'What are my interests?' 'What subjects am I most drawn to?'
}

# Per-question verdicts are recorded as three TAB-separated fields:
#     <question>\t<verdict token>\t<class from classify_verdict>
# No battery question contains a tab, which is what makes field 1 a safe key.
_verdict_of() {  # _verdict_of <records-file> <question> -> verdict token or ''
    awk -F'\t' -v q="$2" '$1 == q { print $2; exit }' "$1"
}
_class_of() {    # _class_of   <records-file> <question> -> ok|defect|unmeasured or ''
    awk -F'\t' -v q="$2" '$1 == q { print $3; exit }' "$1"
}

# THE ASYMMETRY READER. A named function over a RECORDS FILE, so the self-test
# drives the same code the walk runs rather than a re-implementation of it.
# Prints one line per pair where ONE member completed without reaching the
# graph and the OTHER completed and did reach it, and NOTHING otherwise. It
# changes no count and can move no verdict: a member that failed is already in
# _failed. It says which WAY the pair fell, which is the diagnosis the ship
# decision never needed and the next engineer always did.
_phrasing_asymmetry() {  # _phrasing_asymmetry <records-file>
    _pa_file="$1"
    while IFS="$(printf '\t')" read -r _pa_left _pa_right; do
        [ -n "$_pa_left" ] || continue
        [ -n "$_pa_right" ] || continue
        _pa_lc="$(_class_of "$_pa_file" "$_pa_left")"
        _pa_rc="$(_class_of "$_pa_file" "$_pa_right")"
        [ -n "$_pa_lc" ] && [ -n "$_pa_rc" ] || continue
        if [ "$_pa_lc" = "defect" ] && [ "$_pa_rc" = "ok" ]; then
            printf 'PHRASING ASYMMETRY: "%s" COMPLETED without reaching the graph (%s) while its rephrasing "%s" grounded in the same walk. One exact string, not one question in N.\n' \
                "$_pa_left" "$(_verdict_of "$_pa_file" "$_pa_left")" "$_pa_right"
        elif [ "$_pa_rc" = "defect" ] && [ "$_pa_lc" = "ok" ]; then
            printf 'PHRASING ASYMMETRY: "%s" COMPLETED without reaching the graph (%s) while its rephrasing "%s" grounded in the same walk. One exact string, not one question in N.\n' \
                "$_pa_right" "$(_verdict_of "$_pa_file" "$_pa_right")" "$_pa_left"
        fi
    done <<EOF
$(_rephrasing_pairs)
EOF
}

classify_verdict() {
    # classify_verdict <turn verdict> -> defect | unmeasured | ok
    case "$1" in
        grounded)                                     printf 'ok' ;;
        # wrong_store (#1125) is a DEFECT and not lost coverage: the turn
        # completed, retrieval succeeded, and the customer was handed a count
        # where they asked for content. That is a product behaviour, observed.
        no_tool_call|memory_only|tool_error|tool_found_nothing|fact_missing|wrong_store)
                                                      printf 'defect' ;;
        # no_tool_result and no_expected_tools are UNMEASURED, and calling
        # either a defect would be the error this function was written to fix.
        # no_tool_result: a graph call whose outcome never arrived says nothing
        # about whether the assistant can reach the customer's data (#1597).
        # no_expected_tools: the battery failed to declare a store set, which
        # is a fault in the INSTRUMENT, and an instrument fault must never be
        # announced as a product failure -- nor swallowed as a pass.
        incomplete|fatal|no_tool_result|no_expected_tools)
                                                      printf 'unmeasured' ;;
        *)                                            printf 'unmeasured' ;;
    esac
}

# The battery. Each SHOULD reach the graph on a populated box. Deliberately
# phrased the way a new customer phrases them, not the way the tools are shaped
# -- that mismatch IS #854, and a probe written to suit the tools would hide it.
#
# ⚠️ THE QUESTIONS THEMSELVES ARE LOAD-BEARING AND ARE NOT TO BE REWORDED.
# #1113 measured question 2 grounding 3 times in 10 while 1 and 3 grounded 10
# of 10, and the first instinct there was to reword it. That instinct was
# withdrawn in the same thread and the withdrawal is the rule: question 2 is
# phrased as a customer phrases it, its 70% miss rate IS the finding, and
# rewording it until it passes would delete the finding and leave the customer
# experience exactly as broken.
#
# COLUMN 2 IS THE STORE SET (#1125), TAB-SEPARATED, one clause of the shipped
# routing guidance each. See _TOOL_REGISTRY above for the source and for why
# the broad opener is unconstrained.
#
#   "What do you know about me?"        BROAD OPENER clause. No store
#                                       restriction: the guidance says call
#                                       overview FIRST, not overview only, and
#                                       any store can legitimately answer it.
#   "What are my interests?"            "Tastes -- what they are interested in,
#                                       enjoy, are into -- pwg_preferences".
#                                       pwg_overview is deliberately ABSENT:
#                                       that is the #1125 measurement, an
#                                       inventory count answering a question
#                                       about content. Widening this row needs
#                                       the shipped guidance to widen first.
#   "Who have I been in contact ..."    "For a person call pwg_people; history
#                                       pwg_person_timeline".
_questions() {
    cat <<QEOF
What do you know about me?	${_TOOL_REGISTRY}
What are my interests?	pwg_preferences
Who have I been in contact with recently?	pwg_people pwg_person_timeline
What subjects am I most drawn to?	pwg_preferences
QEOF
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the assistant was never asked anything"

    box_run "test -f ${TOKEN_PATH}" >/dev/null 2>&1 \
        || probe_cannot_run "no admin token at ${TOKEN_PATH}; cannot authenticate to /ws/chat (coverage lost, NOT a pass)"

    _port="${GATEWAY##*:}"
    _b64="$(_ws_client_py | base64 | tr -d '\n')"
    _remote_py="/tmp/ostler-probe-ws-$$.py"
    box_run "printf %s '${_b64}' | base64 -d > ${_remote_py}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the WebSocket client on the box"

    # ── READ THE BATTERY ON FD 3, NOT STDIN ─────────────────────────────
    # box_run's ssh has no -n, so it CONSUMES stdin. Feeding this loop from a
    # heredoc on stdin meant the first ssh swallowed the rest of the battery
    # and the loop ended after ONE question -- silent coverage loss that still
    # printed a confident verdict. Measured: "asked #1" and nothing further.
    # A dedicated fd is immune, and the declared-vs-asked limb below turns any
    # recurrence into a FAIL instead of a quieter denominator.
    _qfile="$(mktemp)"
    _questions > "$_qfile"
    # The seeded turn, only when the seed oracle named a fact to expect. It
    # is asked LAST so the three unseeded questions keep their positions in
    # every prior walk record. Its store set is the person clause, the same
    # one question 3 carries: it asks who someone is and where they work.
    [ -n "$EXPECT_FACT" ] && printf '%s\t%s\n' "$SEEDED_QUESTION" "pwg_people pwg_person_timeline" >> "$_qfile"
    _declared="$(grep -c . "$_qfile")"

    # ── A DECLARED PAIR THAT IS NEVER ASKED IS AN UNMEASURABLE CLAIM ────────
    # #1039's lesson applied BEFORE the walk rather than after it: the reader
    # above can be perfectly right about an asymmetry while the questions it
    # compares were never put to the assistant, and a test of the reader alone
    # would be green for ever. So the attachment is pinned structurally, here,
    # where the battery actually exists on disk. Refusing is CANNOT-RUN and not
    # FAIL: a pair declared against a battery that does not carry it is a
    # defect in THIS FILE, not evidence about the product.
    #
    # Matched on FIELD 1, never the whole line. The battery rows carry a store
    # set in field 2, so a whole-line comparison would miss every member and
    # refuse the probe on every run.
    _pairs=0
    while IFS="$(printf '\t')" read -r _p_left _p_right; do
        [ -n "$_p_left" ] || continue
        _pairs=$(( _pairs + 1 ))
        cut -f1 "$_qfile" | grep -Fxq -- "$_p_left" || probe_cannot_run \
            "declared rephrasing pair member is not in the battery: '${_p_left}'. The pair would never be asked, so its asymmetry could never be observed and a green here would prove nothing"
        cut -f1 "$_qfile" | grep -Fxq -- "$_p_right" || probe_cannot_run \
            "declared rephrasing pair member is not in the battery: '${_p_right}'. The pair would never be asked, so its asymmetry could never be observed and a green here would prove nothing"
    done <<EOF
$(_rephrasing_pairs)
EOF
    [ "$_pairs" -eq 0 ] && probe_cannot_run \
        "no rephrasing pair is declared, so this probe cannot tell 'one exact string fails every time' from 'one question in N fails'. #1162 is exactly that distinction and a battery with no pair in it cannot make it"

    # ── THE MAPPING IS CHECKED BEFORE A SINGLE QUESTION IS ASKED (#1125) ─────
    #
    # Two ways a store set can be worthless, and both are silent at run time:
    # EMPTY, which would make every turn no_expected_tools and the whole probe
    # CANNOT-RUN after fifteen minutes of LLM calls; and naming a tool the
    # runtime does not register, which is a gate NOTHING can ever satisfy. The
    # second is the dangerous one, because it looks like a product failure.
    # Both are caught here, up front, and reported as an instrument fault.
    _bad_map=""
    while IFS="$(printf '\t')" read -r _mq _mt; do
        [ -n "$_mq" ] || continue
        if [ -z "$_mt" ]; then
            _bad_map="${_bad_map} [\"${_mq}\" declares NO store set]"
            continue
        fi
        for _mx in $_mt; do
            case " ${_TOOL_REGISTRY} " in
                *" ${_mx} "*) : ;;
                *) _bad_map="${_bad_map} [\"${_mq}\" names ${_mx}, which the runtime does not register]" ;;
            esac
        done
    done < "$_qfile"
    [ -n "$_bad_map" ] && probe_cannot_run "the battery's store map is unusable, so no verdict here would mean anything:${_bad_map}. That is a fault in THIS PROBE, not in the product, and it is reported as one rather than as the assistant failing to reach the customer's data."

    _asked=0; _failed=0; _unmeasured=0; _detail=""; _unmeasured_detail=""
    # ROW 1113. How many turns produced ANY tool call at all. See the
    # discriminator below: without this count a no_tool_call verdict cannot
    # distinguish a model that declined the tools it held from a model that
    # was never offered any.
    _turns_with_tool_call=0
    # <question>TAB<verdict>TAB<class>, one row per turn. Read only by the
    # asymmetry limb; the pass/fail arithmetic is untouched by it.
    _vrec="$(mktemp)"
    _tmp="$(mktemp)"
    exec 3< "$_qfile"
    while IFS="$(printf '\t')" read -r _q _accept_tools <&3; do
        [ -n "$_q" ] || continue
        _asked=$(( _asked + 1 ))
        # The fact travels to the client ONLY for the seeded question, as a
        # fifth argument; every other turn gets an empty one and emits no
        # reply_fact frame, so it is adjudicated exactly as before.
        _fact=""
        [ -n "$EXPECT_FACT" ] && [ "$_q" = "$SEEDED_QUESTION" ] && _fact="$EXPECT_FACT"
        box_run "python3 ${_remote_py} ${_port} '${TOKEN_PATH}' \"\$(printf %s '${_q}')\" ${CHAT_TIMEOUT} \"\$(printf %s '${_fact}')\"" > "$_tmp" 2>&1
        # ROW 1113, counted BEFORE adjudication and independent of its verdict:
        # a turn that emitted any tool_call frame is direct evidence, from this
        # box in this run, that the model was offered tools.
        if grep -q '^FRAME tool_call ' "$_tmp"; then
            _turns_with_tool_call=$(( _turns_with_tool_call + 1 ))
        fi
        _v="$(adjudicate_turn "$_tmp" "$_accept_tools")"
        _cls="$(classify_verdict "$_v")"
        printf '%s\t%s\t%s\n' "$_q" "$_v" "$_cls" >> "$_vrec"
        case "$_cls" in
            ok) : ;;
            defect)
                _failed=$(( _failed + 1 ))
                _tname="$(_offending_tool "$_tmp" "$_v")"
                if [ "$_v" = "fact_missing" ]; then
                    # WHICH SIDE LOST THE FACT. The verdict token is unchanged,
                    # so every consumer of it keeps working; the reason gains
                    # the discriminator, which is the thing a reader needs and
                    # could not get. grep -c, never `| grep -q`: this file runs
                    # under `set -o pipefail`.
                    if [ "$(_fact_missing_side "$_tmp")" = "ignored" ]; then
                        _detail="${_detail} [fact_missing: a pwg_ tool RETURNED '${EXPECT_FACT}' and the reply did not carry every component of it (order-free; exact-phrase reading $(grep -q '^FRAME reply_fact_phrase YES$' "$_tmp" && echo YES || echo NO)) -- the model had it and did not use it]"
                    else
                        _detail="${_detail} [fact_missing: a pwg_ tool answered, NO tool result carried '${EXPECT_FACT}', and neither did the reply -- retrieval did not deliver it]"
                    fi
                elif [ "$_v" = "wrong_store" ]; then
                    # #1125. Name BOTH sides or the reader cannot tell a
                    # routing defect from a wrong map: the tool that answered,
                    # and the stores whose data could have held the answer.
                    # Our own tool identifiers, never customer data.
                    _detail="${_detail} [wrong_store: ${_tname:-a pwg_ tool} answered, and the answer to this question lives in ${_accept_tools}]"
                else
                    _detail="${_detail} [${_v}${_tname:+:${_tname}}]"
                fi ;;
            *)
                _unmeasured=$(( _unmeasured + 1 ))
                _unmeasured_detail="${_unmeasured_detail} [${_v}]"
                # Surface WHY a fatal was fatal, or the next person debugs blind.
                if [ "$_v" = "fatal" ]; then
                    _unmeasured_detail="${_unmeasured_detail}$(sed -n 's/^PROBE_FATAL /(/p' "$_tmp" | head -1 | sed 's/$/)/')"
                fi ;;
        esac
        probe_note "asked #${_asked}: ${_v}"
    done
    exec 3<&-
    rm -f "$_tmp" "$_qfile"
    box_run "rm -f ${_remote_py}" >/dev/null 2>&1

    # ── ROW 1113: WAS THE MODEL EVER OFFERED TOOLS ON THIS BOX? ─────────────
    #
    # #1113 opened on a walk that read "2 of 3 questions did not reach the
    # customer's own data: [no_tool_call] [no_tool_call]", and the daemon's own
    # telemetry for those turns said:
    #
    #   outcome="ok" ... llm_calls=2 tool_calls=0 iterations=1 tools=
    #
    # `tools=` EMPTY. No tools were offered, so tool_calls=0 was not the model
    # declining -- it never had any. The probe printed the same verdict token
    # for that as for a model that held eight graph tools and reached for none,
    # and those are different defects with different owners: one is tool
    # availability, the other is routing. The probe could not see the daemon's
    # telemetry line and still cannot; it is not read here and nothing in this
    # file pretends to.
    #
    # WHAT IT CAN SEE, IN BAND, WITH NO NEW FRAME AND NO NEW FILE: the battery
    # asks three questions against the same daemon in the same run. If ANY turn
    # produced a tool_call frame, tools were demonstrably offered on this box.
    # That is precisely the reasoning that killed #1113's own MCP root cause --
    # "three pwg_* tool calls happened while MCP was disabled, so MCP being off
    # does not prevent grounding" -- turned from a one-off argument into a
    # standing discriminator.
    #
    # ⚠️ IT DOES NOT CHANGE THE VERDICT, AND MUST NOT. Zero tools offered is a
    # worse product failure, not a lesser one: a customer whose assistant holds
    # no graph tools cannot be answered from their own data at all. The FAIL
    # stands. Only the attribution changes, which is the same discipline
    # _fact_missing_side already applies one screen above -- the verdict token
    # is left alone so every consumer keeps working, and the detail gains the
    # discriminator the reader could not otherwise get.
    if [ "$_turns_with_tool_call" -eq 0 ]; then
        _offer_note=" NO turn in this battery produced a tool call at all, so it is NOT established that the model was offered any tools (#1113 measured tools= EMPTY in the daemon's own telemetry on exactly this shape). Read this as tool availability unproven, NOT as the model declining tools it held."
    else
        _offer_note=" Tools WERE offered on this box: ${_turns_with_tool_call} of ${_asked} turns produced at least one tool call, so a no_tool_call turn here is the model declining tools it held (routing), not an empty tool list."
    fi

    # The denominator, always. "0 of 0 grounded" must never read as success.
    # Computed BEFORE the verdict lines so it can ride in the FAIL detail.
    _asym="$(_phrasing_asymmetry "$_vrec")"
    _asym_n="$(printf '%s\n' "$_asym" | grep -c . || true)"
    rm -f "$_vrec"
    if [ "${_asym_n:-0}" -gt 0 ]; then
        probe_note "phrasing asymmetry observed on ${_asym_n} of ${_pairs} declared pair(s)"
        _detail="${_detail} [$(printf '%s' "$_asym" | tr '\n' ';')]"
    fi

    probe_examined "$_asked" "questions asked over /ws/chat (battery declares ${_declared}, of which ${_pairs} declared rephrasing pair(s) were asked and ${_asym_n:-0} showed an asymmetry; ${_failed} answered without reaching the graph, ${_unmeasured} never completed or were never observed, ${_turns_with_tool_call} produced at least one tool call)"

    [ "$_asked" -eq 0 ] && probe_cannot_run "no questions were asked; the battery is empty"

    # ANTI-VACUITY: asked must equal declared. A loop that quietly stops early
    # reduces coverage while every remaining verdict still reads green.
    [ "$_asked" -ne "$_declared" ] && probe_fail \
        "asked ${_asked} of ${_declared} declared questions -- the battery was truncated mid-run, so a pass here would understate coverage"

    # PRECEDENCE, STRICTEST FIRST. A proven defect outranks lost coverage: if one
    # turn completed and did not reach the graph, that is a finding whether or not
    # another timed out. Lost coverage outranks a pass, because a battery that
    # only half ran has not established the promise.
    [ "$_failed" -gt 0 ] && probe_fail \
        "${_failed} of ${_asked} questions COMPLETED without reaching the customer's own data:${_detail} (verdicts are frame-stream states, plus the seeded turn's fact-carried assertion computed on the box; answer text is never read here).${_offer_note}"

    [ "$_unmeasured" -gt 0 ] && probe_cannot_run \
        "${_unmeasured} of ${_asked} turns never completed or had their retrieval outcome never observed:${_unmeasured_detail}. That is a clock, a client or a dropped result frame, NOT evidence that the assistant cannot answer. The per-turn ceiling is ${CHAT_TIMEOUT}s and this file own runtime note records 2-5 MINUTES per turn on a Mac mini under first-run ingest load. Raise OSTLER_PROBE_CHAT_TIMEOUT and re-walk, or walk a box that has finished ingesting. A no_tool_result turn means a graph tool was CALLED and no result frame for it was ever seen, which is an unobserved turn and not a grounded one (#1597). Not a pass."

    probe_pass "all ${_asked} questions produced a tool-backed answer over /ws/chat at ${GATEWAY}${EXPECT_FACT:+, and the seeded reply carried the expected fact}"
}

self_test() {
    # Drive adjudicate_turn -- the SAME function run_probe uses -- over planted
    # fixtures. Each mirrors a shape measured on the v1.0.38 box.
    _d="$(mktemp -d)"

    # (a) healthy
    printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences OK\nFRAME done\n' > "$_d/good"
    # (b) #855: retrieval attempted, tool errored
    printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences ERR\nFRAME done\n' > "$_d/toolerr"
    # (c) #854 Q1: answered without ever attempting retrieval
    printf 'FRAME session_start\nFRAME chunk_reset\nFRAME done\n' > "$_d/notool"
    # (d) turn never completed
    printf 'FRAME session_start\nFRAME tool_call pwg_topics\nFRAME timeout\n' > "$_d/incomplete"
    # (e) MEASURED ON .228: the assistant recalled its OWN previous non-answer
    #     via memory_recall and never touched the graph. v1 of the adjudicator
    #     scored this GREEN, which is why this fixture exists.
    printf 'FRAME session_start\nFRAME tool_call memory_recall\nFRAME tool_result memory_recall OK\nFRAME done\n' > "$_d/memonly"
    # (f) success-shaped emptiness: the graph tool ran and truthfully found
    #     nothing. Not an error, and not retrieval either.
    printf 'FRAME session_start\nFRAME tool_call pwg_person_timeline\nFRAME tool_result pwg_person_timeline EMPTY\nFRAME done\n' > "$_d/empty"

    # The three store sets the battery declares, named once so every fixture
    # below is adjudicated against a set a REAL question actually carries. A
    # set invented for the self-test would make these arms prove nothing about
    # the walk.
    _ALL="$_TOOL_REGISTRY"
    _PERSON='pwg_people pwg_person_timeline'
    _TASTES='pwg_preferences'

    _ok=1
    [ "$(adjudicate_turn "$_d/good" "$_TASTES")"       = "grounded" ]           || _ok=0
    [ "$(adjudicate_turn "$_d/toolerr" "$_TASTES")"    = "tool_error" ]         || _ok=0
    [ "$(adjudicate_turn "$_d/notool" "$_ALL")"        = "no_tool_call" ]       || _ok=0
    [ "$(adjudicate_turn "$_d/incomplete" "$_ALL")"    = "incomplete" ]         || _ok=0
    [ "$(adjudicate_turn "$_d/memonly" "$_ALL")"       = "memory_only" ]        || _ok=0
    [ "$(adjudicate_turn "$_d/empty" "$_PERSON")"      = "tool_found_nothing" ] || _ok=0

    # ── A RECOVERED TURN IS NOT A FAILED ONE (#1597) ─────────────────────────
    # The product is BUILT to recover: person_query's error text tells the model
    # to call pwg_overview and try again. Those turns must not read as defects.
    # THE FULL RECOVERY the error text asks for: call pwg_overview, then call
    # the person tool AGAIN. The person store is read successfully in the end,
    # so the customer got their contacts and the turn is grounded.
    printf 'FRAME session_start\nFRAME tool_call pwg_person_timeline\nFRAME tool_result pwg_person_timeline ERR\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME tool_call pwg_person_timeline\nFRAME tool_result pwg_person_timeline OK\nFRAME done\n' > "$_d/recovered"
    [ "$(adjudicate_turn "$_d/recovered" "$_PERSON")"  = "grounded" ]  || _ok=0
    # ⚠️ THE HALF RECOVERY, AND IT CHANGED VERDICT IN THE #1125 LIFT. This was
    # the `recovered` fixture, asserted `grounded`, because SOME pwg tool
    # returned OK. On a question about the customer's contacts the model
    # consulted the INDEX and never went back for the data, so the customer got
    # counts. That fixture was itself an instance of the blindness #1125
    # reports, sitting inside the control that was meant to prove the probe
    # could see. It is tool_error now: the person store was tried, it failed,
    # and nothing ever read it successfully.
    printf 'FRAME session_start\nFRAME tool_call pwg_person_timeline\nFRAME tool_result pwg_person_timeline ERR\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME done\n' > "$_d/recovered_half"
    [ "$(adjudicate_turn "$_d/recovered_half" "$_PERSON")" = "tool_error" ] || _ok=0
    # MUST-MISS: an error the model NEVER recovered from is still a defect.
    # Without this arm the reorder would have made the probe unable to fail.
    [ "$(adjudicate_turn "$_d/toolerr" "$_TASTES")"    = "tool_error" ]         || _ok=0
    # MUST-MISS: a turn that only ever found nothing is still not retrieval,
    # even though EMPTY is not an error.
    [ "$(adjudicate_turn "$_d/empty" "$_PERSON")"      = "tool_found_nothing" ] || _ok=0
    # CONTROL: recovery is decided by a SUCCESSFUL read, not merely by a second
    # tool call. Two failures in a row must still be tool_error.
    printf 'FRAME session_start\nFRAME tool_call pwg_person_timeline\nFRAME tool_result pwg_person_timeline ERR\nFRAME tool_call pwg_topics\nFRAME tool_result pwg_topics ERR\nFRAME done\n' > "$_d/twoerrs"
    [ "$(adjudicate_turn "$_d/twoerrs" "$_PERSON")"    = "tool_error" ]         || _ok=0

    # ── #1125: THE WRONG STORE IS NOT GROUNDING ─────────────────────────────
    # The measured shape. "What are my interests?" answered by pwg_overview,
    # which returns a count of how many preferences the graph holds. Scored
    # grounded by every adjudicator this file has had until now, identically
    # to the Q8 cell that called pwg_preferences 10 times out of 10.
    printf 'FRAME session_start\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME done\n' > "$_d/wrongstore"
    [ "$(adjudicate_turn "$_d/wrongstore" "$_TASTES")" = "wrong_store" ]        || _ok=0
    # MUST-MISS, AND IT IS THE WHOLE POINT: the SAME frames on the BROAD
    # OPENER, whose clause places no store restriction, are grounded. A probe
    # that called pwg_overview wrong everywhere would fight the routing
    # guidance the product ships.
    [ "$(adjudicate_turn "$_d/wrongstore" "$_ALL")"    = "grounded" ]           || _ok=0
    # MUST-MISS: the RIGHT store on the same question is still grounded, so the
    # new arm narrows the verdict rather than reddening the question.
    [ "$(adjudicate_turn "$_d/good" "$_TASTES")"       = "grounded" ]           || _ok=0
    # CONTROL: a wrong-store hit does not mask the right store ERRORING. The
    # tool that broke is the actionable fact and outranks the one that answered.
    printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences ERR\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME done\n' > "$_d/rightbroke"
    [ "$(adjudicate_turn "$_d/rightbroke" "$_TASTES")" = "tool_error" ]         || _ok=0

    # ── #1597 / ZERO DENOMINATOR: AN UNOBSERVED TURN IS NOT A GROUNDED ONE ──
    # All three were MEASURED as `grounded` on origin/main e0fb21bf. Each has a
    # pwg tool CALLED and not one pwg tool_result frame anywhere: no success,
    # no error, no empty. The probe reported the customer's data reached.
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME done\n' > "$_d/noresult"
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME unparseable\nFRAME done\n' > "$_d/unparseable"
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result memory_recall OK\nFRAME done\n' > "$_d/nonpwg_result"
    [ "$(adjudicate_turn "$_d/noresult" "$_PERSON")"      = "no_tool_result" ]  || _ok=0
    [ "$(adjudicate_turn "$_d/unparseable" "$_PERSON")"   = "no_tool_result" ]  || _ok=0
    [ "$(adjudicate_turn "$_d/nonpwg_result" "$_PERSON")" = "no_tool_result" ]  || _ok=0
    # MUST-MISS: the same call WITH its result frame is grounded, so the new
    # arm fires on the missing observation and not on the call.
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME done\n' > "$_d/withresult"
    [ "$(adjudicate_turn "$_d/withresult" "$_PERSON")"    = "grounded" ]        || _ok=0

    # ── THE INSTRUMENT REFUSES RATHER THAN GRADES ───────────────────────────
    # An empty store set is a fault in this probe. It must not grade the turn
    # in either direction, and its class must be unmeasured, not defect.
    [ "$(adjudicate_turn "$_d/good" "")"               = "no_expected_tools" ]  || _ok=0
    [ "$(adjudicate_turn "$_d/good")"                  = "no_expected_tools" ]  || _ok=0

    # ── THE CONTENT ASSERTION (2026-09-07) ──────────────────────────────────
    # (g) MEASURED ad hoc on a v1.0.74 box (ostler-assistant b4118b45's commit
    #     message; NOT a walk, the v1.0.74 walk ran unseeded), the minimal
    #     variant: one pwg_ tool, OK, and a reply that said the workplace was
    #     not recorded while the graph served it. The pre-fix adjudicator
    #     returned `grounded` on exactly this file. It is the must-FAIL.
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME chunk_reset\nFRAME reply_fact NO\nFRAME done\n' > "$_d/factmissing"
    # (h) CONSTRUCTED, not captured: no real passing transcript exists while
    #     the daemon drops the facts (ostler-assistant #386 in flight). The
    #     same frames with the fact carried. It is the must-PASS.
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME chunk_reset\nFRAME reply_fact YES\nFRAME done\n' > "$_d/factcarried"
    # (i) MEASURED, the full turn-1 stream: pwg_people OK, pwg_topics EMPTY,
    #     memory_recall OK. The OK line used to win; the missing fact must.
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME tool_call pwg_topics\nFRAME tool_result pwg_topics EMPTY\nFRAME tool_call memory_recall\nFRAME tool_result memory_recall OK\nFRAME chunk_reset\nFRAME reply_fact NO\nFRAME done\n' > "$_d/factmissing_full"
    # (j) THE FRAME GATE STAYS FIRST: a reply that carries the fact without
    #     any tool call is still no_tool_call -- the fact came from nowhere.
    printf 'FRAME session_start\nFRAME chunk_reset\nFRAME reply_fact YES\nFRAME done\n' > "$_d/notool_fact"
    [ "$(adjudicate_turn "$_d/factmissing" "$_PERSON")"      = "fact_missing" ]  || _ok=0
    [ "$(adjudicate_turn "$_d/factcarried" "$_PERSON")"      = "grounded" ]      || _ok=0
    [ "$(adjudicate_turn "$_d/factmissing_full" "$_PERSON")" = "fact_missing" ]  || _ok=0
    [ "$(adjudicate_turn "$_d/notool_fact" "$_PERSON")"      = "no_tool_call" ]  || _ok=0

    # (l) WHICH SIDE LOST IT. Same verdict, two different owners, and until
    #     2026-09-09 the record could not tell them apart. The verdict token is
    #     deliberately unchanged on both, so every consumer of it keeps working.
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME tool_fact YES\nFRAME chunk_reset\nFRAME reply_fact NO\nFRAME done\n' > "$_d/fact_ignored"
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME tool_fact NO\nFRAME chunk_reset\nFRAME reply_fact NO\nFRAME done\n' > "$_d/fact_not_retrieved"
    [ "$(adjudicate_turn "$_d/fact_ignored" "$_PERSON")"       = "fact_missing" ]   || _ok=0
    [ "$(adjudicate_turn "$_d/fact_not_retrieved" "$_PERSON")" = "fact_missing" ]   || _ok=0
    [ "$(_fact_missing_side "$_d/fact_ignored")"       = "ignored" ]       || _ok=0
    [ "$(_fact_missing_side "$_d/fact_not_retrieved")" = "not_retrieved" ] || _ok=0
    # MUST-MISS: a transcript with NO tool_fact frame at all is the pre-change
    # shape, and it must read not_retrieved rather than crash or claim ignored.
    [ "$(_fact_missing_side "$_d/factmissing")"        = "not_retrieved" ] || _ok=0
    # (k) UNSEEDED turns carry no reply_fact frame and are unchanged.
    [ "$(adjudicate_turn "$_d/good" "$_TASTES")"             = "grounded" ]      || _ok=0

    # THE PREDICATE ITSELF, driven through the client's --self-check so the
    # self-test exercises the code the walk runs, not a re-implementation.
    # Archie's verbatim reply must read NO; a constructed reply carrying the
    # fact must read YES; case must not matter (OS003 check 1 lower-cases).
    _ws_client_py > "$_d/client.py"
    _fact='cable engineer at example.com'
    _reply_no='I found some information about Jane Doe in the Personal World Graph, but it does not explicitly state where she works.'
    _reply_yes='Jane Doe is a submarine cable engineer at example.com, the seed fixture employer.'
    _reply_case='jane doe is a submarine CABLE ENGINEER AT EXAMPLE.COM.'
    [ "$(printf '%s' "$_reply_no"   | python3 "$_d/client.py" --self-check "$_fact")" = "NO" ]  || _ok=0
    [ "$(printf '%s' "$_reply_yes"  | python3 "$_d/client.py" --self-check "$_fact")" = "YES" ] || _ok=0
    [ "$(printf '%s' "$_reply_case" | python3 "$_d/client.py" --self-check "$_fact")" = "YES" ] || _ok=0

    # THE NAME, over the SAME fixtures the verdicts were decided from. A
    # tool_error that names no tool sends the operator back to the raw
    # transcript for the only actionable fact in it.
    _name_ok=1
    [ "$(_offending_tool "$_d/toolerr" tool_error)" = "pwg_preferences" ]    || _name_ok=0
    [ "$(_offending_tool "$_d/empty" tool_found_nothing)" = "pwg_person_timeline" ] || _name_ok=0
    # MUST-MISS: a verdict that names no tool must yield nothing, or the detail
    # would carry a name for turns where no tool result decided the verdict.
    [ -z "$(_offending_tool "$_d/notool" no_tool_call)" ]                    || _name_ok=0
    [ -z "$(_offending_tool "$_d/memonly" memory_only)" ]                    || _name_ok=0
    # CONTROL: the extractor must not match a NON-pwg tool, or memory_recall
    # would be reported as the failing graph tool.
    printf 'FRAME session_start\nFRAME tool_call memory_recall\nFRAME tool_result memory_recall ERR\nFRAME done\n' > "$_d/nonpwg"
    [ -z "$(_offending_tool "$_d/nonpwg" tool_error)" ]                      || _name_ok=0
    # #1125. wrong_store's name is its only actionable fact: WHICH store
    # answered. Without it the detail reads as a routing mystery.
    [ "$(_offending_tool "$_d/wrongstore" wrong_store)" = "pwg_overview" ]   || _name_ok=0
    [ "$_name_ok" -eq 1 ] || _ok=0

    # ── THE BATTERY'S OWN STORE MAP, CHECKED AGAINST THE RUNTIME (#1125) ────
    #
    # 🔴 THE TRAP THIS ARM EXISTS FOR: a store set naming a tool the runtime
    # does not register is a gate NOTHING can satisfy, and it fails looking
    # exactly like a product defect -- every turn on that question would score
    # wrong_store forever. The map is checked against the SAME registry the
    # sibling probe assistant_prompt_names_every_pwg_tool pins, read from that
    # file rather than copied, so the two cannot drift apart silently.
    _sibling="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assistant_prompt_names_every_pwg_tool.sh"
    _map_ok=1
    if [ ! -f "$_sibling" ]; then
        printf '  store-map control: CANNOT-RUN, no sibling probe at %s\n' "$_sibling"
        _map_ok=0
    else
        _sib_tools="$(sed -n 's/^REQUIRED_TOOLS="\(.*\)"$/\1/p' "$_sibling" | head -1)"
        # THE READER IS PROVED BEFORE ITS ANSWER IS BELIEVED. An empty read
        # here would make every membership test below vacuously fail, which is
        # a different bug wearing this one's face.
        if [ -z "$_sib_tools" ]; then
            printf '  store-map control: CANNOT-RUN, could not read REQUIRED_TOOLS from the sibling probe\n'
            _map_ok=0
        else
            for _t8 in $_TOOL_REGISTRY; do
                case " ${_sib_tools} " in
                    *" ${_t8} "*) : ;;
                    *) printf '  store-map control: %s is in this battery and NOT in the runtime registry\n' "$_t8"; _map_ok=0 ;;
                esac
            done
            for _t8 in $_sib_tools; do
                case " ${_TOOL_REGISTRY} " in
                    *" ${_t8} "*) : ;;
                    *) printf '  store-map control: %s is registered by the runtime and missing from this battery\n' "$_t8"; _map_ok=0 ;;
                esac
            done
        fi
    fi
    # ANTI-VACUITY. The broad opener declares all 8 on purpose, and that arm
    # can never return wrong_store. If EVERY row did that the mechanism would
    # be decoration that still reported a verdict, which is this week's defect
    # class exactly. At least one question must declare a PROPER SUBSET.
    _subset_rows=0
    while IFS="$(printf '\t')" read -r _sq _st; do
        [ -n "$_sq" ] || continue
        [ -n "$_st" ] || continue
        [ "$_st" = "$_TOOL_REGISTRY" ] || _subset_rows=$(( _subset_rows + 1 ))
    done <<QSUB
$(_questions)
QSUB
    if [ "$_subset_rows" -lt 1 ]; then
        printf '  store-map control: NO battery row declares a proper subset, so wrong_store can never fire\n'
        _map_ok=0
    fi
    # 🔴 AND THE HOLE THE ARM ABOVE LEFT, FOUND BY MUTATING THIS FILE RATHER
    # THAN BY READING IT. "At least one proper subset" is satisfied by question
    # 3 alone, so widening question 2 back to the whole registry -- undoing the
    # #1125 fix on the exact question #1125 measured -- left every control
    # green. A battery-wide floor cannot guard a per-row property.
    #
    # THE PROPERTY, stated positively: pwg_overview is the ONLY tool in the
    # registry that returns metadata about the graph instead of data from it,
    # so it may appear in exactly one set, the unconstrained broad opener.
    # Two arms, because widening a row to `preferences overview` and widening
    # it to the full registry are different mutations and each escapes the
    # other's arm.
    _full_rows=0; _overview_rows=0
    while IFS="$(printf '\t')" read -r _sq _st; do
        [ -n "$_sq" ] || continue
        [ -n "$_st" ] || continue
        if [ "$_st" = "$_TOOL_REGISTRY" ]; then
            _full_rows=$(( _full_rows + 1 ))
        else
            case " ${_st} " in
                *" pwg_overview "*) _overview_rows=$(( _overview_rows + 1 )) ;;
            esac
        fi
    done <<QOVW
$(_questions)
QOVW
    if [ "$_full_rows" -ne 1 ]; then
        printf '  store-map control: %s battery rows declare the WHOLE registry, expected exactly 1 (the broad opener). An unconstrained row can never return wrong_store.\n' "$_full_rows"
        _map_ok=0
    fi
    if [ "$_overview_rows" -ne 0 ]; then
        printf '  store-map control: %s constrained row(s) accept pwg_overview, which returns a COUNT of the graph rather than anything in it. That is the #1125 shape being readmitted.\n' "$_overview_rows"
        _map_ok=0
    fi
    # EVERY row must declare a set at all, or that question is ungraded.
    _unmapped_rows=0
    while IFS="$(printf '\t')" read -r _sq _st; do
        [ -n "$_sq" ] || continue
        [ -n "$_st" ] || _unmapped_rows=$(( _unmapped_rows + 1 ))
    done <<QMAP
$(_questions)
QMAP
    if [ "$_unmapped_rows" -ne 0 ]; then
        printf '  store-map control: %s battery row(s) declare no store set\n' "$_unmapped_rows"
        _map_ok=0
    fi
    [ "$_map_ok" -eq 1 ] || _ok=0
    rm -rf "$_d"

    # ── AND THE ROUTING, WHICH IS WHAT DECIDES THE PROBE'"'"'S VERDICT ────────
    #
    # adjudicate_turn classifies a TURN. classify_verdict decides whether that
    # classification is a statement about the PRODUCT or about the CLOCK. Getting
    # the second one wrong is how a timeout became "the assistant cannot reach
    # the customer's data" on a blocking probe. Driven through the real function.
    #
    # Cases 6 and 7 are the fix. Case 8 is the trap the fix could have set: a
    # verdict the classifier does not recognise must not be announced as a
    # product defect either.
    _rt() {  # _rt <verdict> <expected class>
        _got="$(classify_verdict "$1")"
        [ "$_got" = "$2" ] && return 0
        printf '  routing control: %s classified as %s, expected %s\n' "$1" "$_got" "$2"
        _ok=0
    }
    _rt grounded            ok
    _rt no_tool_call        defect
    _rt memory_only         defect
    _rt tool_error          defect
    _rt tool_found_nothing  defect
    _rt fact_missing        defect
    # #1125. An observed product behaviour, so a DEFECT: the turn completed,
    # retrieval succeeded, and the wrong shelf was read.
    _rt wrong_store         defect
    _rt incomplete          unmeasured
    _rt fatal               unmeasured
    # #1597. Nothing was observed, so nothing passed and nothing failed. If
    # either of these ever routes to `ok` the probe is back to reporting a
    # clean sheet on a zero denominator, and if either routes to `defect` it
    # blames the product for the instrument's blindness.
    _rt no_tool_result      unmeasured
    _rt no_expected_tools   unmeasured
    _rt some_future_verdict unmeasured

    # ── #1162: THE ASYMMETRY READER, DRIVEN ON RECORDS FILES ────────────────
    # The walk runs this exact function, so these arms exercise the shipped
    # code rather than a re-implementation of it. SIX arms, and FOUR of them
    # assert SILENCE: a reader that prints on every input says nothing, and
    # the two firing arms alone could not tell the two apart.
    _pair_l='What are my interests?'
    _pair_r='What subjects am I most drawn to?'
    # 🔴 ITS OWN FILE, NOT $_d. These arms sit AFTER `rm -rf "$_d"` at the end
    # of the fixture section, and the first version of them wrote into that
    # deleted directory. The records file then never existed, _class_of read
    # nothing, the reader printed nothing, and the two arms that must FIRE
    # read 0. They failed, which is the only reason this was found: an arm
    # asserting SILENCE would have passed on a missing file and pinned
    # nothing at all. Same shape as every other finding tonight, in the arm
    # written to catch that shape.
    _rec="$(mktemp)"
    _mkrec() {
        : > "$_rec"
        while [ "$#" -ge 3 ]; do
            printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$_rec"
            shift 3
        done
        printf '%s' "$_rec"
    }
    _asym_n_of() { printf '%s\n' "$(_phrasing_asymmetry "$1")" | grep -c . || true; }

    # FIRES: one member completed without reaching the graph, the other
    # grounded. Both orderings, because the reader reads the pair both ways.
    [ "$(_asym_n_of "$(_mkrec "$_pair_l" no_tool_call defect "$_pair_r" grounded ok)")" -eq 1 ] || _ok=0
    [ "$(_asym_n_of "$(_mkrec "$_pair_l" grounded ok "$_pair_r" no_tool_call defect)")" -eq 1 ] || _ok=0
    # SILENT: both grounded. Nothing asymmetric happened.
    [ "$(_asym_n_of "$(_mkrec "$_pair_l" grounded ok "$_pair_r" grounded ok)")" -eq 0 ] || _ok=0
    # SILENT: both failed. That is a question that does not work, which is a
    # different and already-counted finding, not a phrasing asymmetry.
    [ "$(_asym_n_of "$(_mkrec "$_pair_l" no_tool_call defect "$_pair_r" no_tool_call defect)")" -eq 0 ] || _ok=0
    # SILENT: one never completed. An unmeasured turn cannot be compared with
    # a measured one, and saying it could is how a zero denominator reads as
    # a result.
    [ "$(_asym_n_of "$(_mkrec "$_pair_l" no_tool_call defect "$_pair_r" incomplete unmeasured)")" -eq 0 ] || _ok=0
    # SILENT: the other member is absent from the records entirely.
    [ "$(_asym_n_of "$(_mkrec "$_pair_l" no_tool_call defect)")" -eq 0 ] || _ok=0
    # AND A CONTROL ON THE HARNESS ITSELF: the records file these arms read
    # must exist and be non-empty, or every silence arm above is vacuous.
    [ -s "$_rec" ] || _ok=0
    rm -f "$_rec"

    # 68 = 42 adjudicator, predicate and asymmetry arms (the 44 `|| _ok=0`
    # lines less the two roll-ups) + 6 tool-name arms + 8 store-map control
    # sites + 12 routing cases. COUNTED, not estimated, and counted by code SITE rather than by
    # execution: two of the map sites sit inside per-tool loops. scripts/tests/
    # test_grounded_probe_names_the_store_and_refuses_a_blind_turn.sh recounts
    # them from this file with the same definition and goes red if the number
    # and the arms drift apart. Without that recount a declared denominator is
    # just a number, which is the shape this probe exists to refuse.
    probe_examined 68 "planted transcript fixtures, predicate checks, store-map controls, asymmetry-reader arms and verdict-routing cases"
    if [ "$_ok" -eq 1 ]; then
        # The control FIRED: six known-bad shapes each produced their own
        # non-grounded verdict, and the healthy ones did not.
        probe_fail "control fired: tool_error, no_tool_call, incomplete, memory_only, tool_found_nothing and fact_missing (the seeded turn whose reply did not carry the fact, measured on a v1.0.74 box, ostler-assistant b4118b45) are each detected; wrong_store fires on the #1125 shape -- an inventory tool answering a question about content -- while the same frames on the broad opener stay grounded; no_tool_result fires on all three #1597 shapes in which a graph tool was called and no result for it was ever observed, each of which read grounded on origin/main e0fb21bf; an empty store set refuses instead of grading; the battery's store map agrees with the runtime registry and at least one row is a proper subset so wrong_store can fire at all; the healthy fixtures are not misread as broken; and 12 of 12 verdicts route correctly -- a completed turn that missed the graph is a DEFECT, a turn that never completed or was never observed is UNMEASURED, and an unrecognised verdict is unmeasured rather than announced as a product failure"
    fi
    # Reaching here means the adjudicator could NOT tell a broken turn from a
    # healthy one. Passing is how this suite spells BROKEN.
    probe_pass "CONTROL DID NOT FIRE -- adjudicate_turn failed to classify the planted fixtures, so a green from this probe would prove nothing"
}

probe_main "$@"
