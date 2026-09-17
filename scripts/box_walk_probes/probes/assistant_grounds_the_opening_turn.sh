#!/usr/bin/env bash
# scripts/box_walk_probes/probes/assistant_grounds_the_opening_turn.sh
# ============================================================================
# THE OPENING TURN IS THE ONLY TURN THAT EVER FAILED, AND IT IS THE ONLY ONE
# THIS PROBE ASKS.
#
# assistant_answers_grounded asks a battery and adjudicates the whole thing.
# This probe asks ONE question, FIRST, in a FRESH session, TEN TIMES. That is
# the experiment, and it is here rather than in an experiments/ directory
# because a side experiment is attributable to nothing and we have now been
# unable to attribute the same result twice.
#
# WHY THIS SHAPE. ostler-assistant d791de5f measured 40 runs of the grounded
# battery: 4 openings answered with NO tool call, roughly one in ten, and
# EVERY SINGLE FAILURE WAS ON QUESTION ONE. Questions two and three grounded
# in all 40. Run twice, 20 with the Ollama slot contended and 20 free, 10%
# both times, so contention is not the cause. It is a cold start: on turn one
# nothing in the conversation establishes that looking things up is what
# happens here. Asking the seeded question SECOND proves nothing, because
# questions two and three already ground 40 out of 40.
#
# WHAT THIS PROBE CANNOT DO, said here so nobody reads more into a pass.
# It cannot tell you that a small model tool-calls in general. It tells you
# whether THIS box, running THE MODEL IT RECORDS, grounds the opening turn at
# a rate distinguishable from one-in-ten. That is the question that is open,
# and it is open because no record has ever carried the model tag.
#
# ── THE FOUR PRECONDITIONS. All four, or the result is unattributable. ──────
#
#   1. NO PRIOR DAEMON MEMORY OF THE SEEDED PERSON. This is the confound that
#      made an earlier five-of-five meaningless: the daemon could answer from
#      memory of a previous run and never call a tool, and that reads as a
#      grounded pass. CHECKED, not assumed, and CANNOT-RUN if present.
#
#   2. THE MODEL IS READ FROM THE LIVE CONFIG ON THE BOX, never inferred from
#      lib/ostler-model-fit.sh. The fit table says what SHOULD be picked; the
#      config says what IS running, and a probe that infers its own independent
#      variable is measuring its own assumption. Recorded VERBATIM.
#
#   3. THE RAM IS READ FROM THE BOX. With the fit table it cross-checks the
#      model: if the pair disagree, the box is not in the state we think.
#
#   4. THE QUESTION IS FIRST IN A FRESH SESSION, ten times over.
#
# ── THE DENOMINATOR, FIXED IN ADVANCE ──────────────────────────────────────
#
# TEN openings minimum. The rate under test is roughly one in ten, so fewer
# than ten cannot separate "fixed" from "got lucky". A clean 3 of 3 is NOT an
# answer and this probe REFUSES to report one: under ten completed openings it
# exits CANNOT-RUN, which is neither a pass nor a fail.
#
# ── THE READING, AGREED IN ADVANCE SO IT IS NOT NEGOTIATED AFTERWARDS ──────
#
#   10/10 grounded, handover present  -> the fix works on the model recorded.
#                                        If that model is the floor model, the
#                                        16GB spec question is SETTLED, and the
#                                        closure row says so WITH the tag and
#                                        the RAM in the sentence.
#   ~1 in 10 failing AT THE OPENING   -> the handover did not take. That is a
#                                        defect against ostler-assistant #404,
#                                        NOT a spec question.
#   failures BEYOND the opening turn  -> the capability ceiling nobody has yet
#                                        observed. That is a SPEC DECISION for
#                                        Andy, not a daemon fix, and this probe
#                                        says so rather than guessing.
#
# ── WHAT IS RECORDED PER OPENING, all of which the frame stream already
#    carries and the walk record has until now dropped ────────────────────────
#   was a pwg_ tool called, and WHICH one
#   did the TOOL OUTPUT carry the seeded fact
#   did the REPLY carry the seeded fact
#   plus model_tag, ram_gb, version and box_fp, once per run
#
# NO PIPE INTO grep -q ANYWHERE: that construct SIGPIPEs its producer and under
# `set -o pipefail` reports failure for a pattern it found. Counted form only.
#
# THE WS CLIENT BELOW IS A DELIBERATE COPY of the one in
# assistant_answers_grounded.sh, which embeds it rather than shipping it
# alongside "so the probe cannot half-exist on a box". That reason still holds
# for this probe. The copy is GUARDED: tests/test_the_two_ws_clients_are_identical.sh
# fails the build the moment the two diverge, the same pattern install.sh uses
# for its embedded copy of lib/ostler-resource-tier.sh. Extracting both to a
# shared lib is the right end state and is deliberately NOT done here, because
# CM051 #2018 is open against that file and this would collide with it.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/../lib/probe.sh"

PROBE_NAME="assistant_grounds_the_opening_turn"
OPENINGS="${OSTLER_OPENING_TURNS:-10}"
MIN_OPENINGS=10

EXPECT_FACT="${OSTLER_GATE_EXPECT_FACT:-}"
KNOWN_PERSON="${OSTLER_GATE_KNOWN_PERSON:-}"
SEEDED_QUESTION="${OSTLER_GATE_QUESTION:-Who is ${KNOWN_PERSON} and where do they work?}"

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
        text += ev.get("content") or ""
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
            print("FRAME reply_fact %s" % ("YES" if carries(graded, expect_fact) else "NO"))
            print("FRAME reply_fact_phrase %s" % ("YES" if carries_phrase(graded, expect_fact) else "NO"))
        print("FRAME %s" % t)
        if t in ("done", "error"): break
PYEOF
}

# ── PRECONDITION 2 and 3: the independent variables, READ not inferred ──────
#
# The model comes from the LIVE config on the box. lib/ostler-model-fit.sh is
# deliberately NOT consulted: it says what SHOULD be picked for the RAM, and
# the whole point of recording both is that the pair can DISAGREE. A probe
# that derives its independent variable from a table is measuring the table.
_read_model_tag() {
    box_run 'cat "$HOME/.ostler/config/ai.env" 2>/dev/null | sed -n "s/^AI_MODEL=//p" | tr -d "\"'"'"'" | head -1'
}
_read_ram_gb() {
    box_run 'if [ "$(uname)" = "Darwin" ]; then echo $(( $(sysctl -n hw.memsize) / 1073741824 )); else awk "/MemTotal/{print int(\$2/1048576)}" /proc/meminfo; fi'
}

# ── PRECONDITION 1: the seeded person must be ABSENT from daemon memory ─────
#
# THIS IS THE CONFOUND THAT VOIDED AN EARLIER RESULT. If the daemon already
# remembers this person, it can answer correctly having called nothing, and
# that renders as a grounded pass. The check is on the DAEMON's memory, not on
# the graph: the graph is supposed to hold the person, that is the point of
# seeding them.
#
# THREE OUTCOMES. Present -> CANNOT-RUN (not a fail: the box is in the wrong
# state, nothing about the model was learned). Unreadable -> CANNOT-RUN, and
# NOT "absent", because "could not look" and "found nothing" print identically
# and only one of them is evidence.
_memory_mentions_person() {
    box_run "curl -fsS --max-time 10 'http://127.0.0.1:8000/api/v1/memory/search?q=$(printf '%s' "$KNOWN_PERSON" | sed 's/ /%20/g')' 2>/dev/null"
}

probe_main() {
    [ -n "$KNOWN_PERSON" ] || { probe_cannot_run "OSTLER_GATE_KNOWN_PERSON is unset -- the seed oracle did not run, so there is no seeded person to ask about. Nothing was measured."; return; }
    [ -n "$EXPECT_FACT" ]  || { probe_cannot_run "OSTLER_GATE_EXPECT_FACT is unset -- without the expected fact a 'grounded' verdict would be unfalsifiable. Nothing was measured."; return; }
    box_reachable          || { probe_cannot_run "the box is not reachable, so no opening turn was asked. This is NOT a model result."; return; }

    MODEL_TAG="$(_read_model_tag | tr -d '\r')"
    RAM_GB="$(_read_ram_gb | tr -d '\r')"
    if [ -z "$MODEL_TAG" ]; then
        probe_cannot_run "could not read AI_MODEL from the live config on the box. The model is the INDEPENDENT VARIABLE of this experiment; without it the run answers nothing and must not be attributed to a model later. NOT INSTRUMENTED, not 'unknown model'."
        return
    fi
    probe_note "model_tag=${MODEL_TAG} (read from the live config, NOT inferred from the fit table)"
    probe_note "ram_gb=${RAM_GB:-unread}"

    # The fit-table cross-check. A DISAGREEMENT is reported and does not stop
    # the run: what is running is what is running, and the probe records it.
    if [ -n "$RAM_GB" ] && [ "$RAM_GB" -le 23 ] 2>/dev/null && [ "$MODEL_TAG" != "gemma4:e2b" ]; then
        probe_note "NOTE: ${RAM_GB}GB should give gemma4:e2b by the fit table, and the live config says ${MODEL_TAG}. Recorded as measured; the table is not the authority here."
    fi

    _mem="$(_memory_mentions_person)"
    if [ -z "$_mem" ]; then
        probe_cannot_run "could not read daemon memory for the seeded person, so precondition 1 is UNESTABLISHED. 'Could not look' is not 'absent', and an opening turn run against unknown memory state is exactly the confound that voided the previous result."
        return
    fi
    _hits="$(printf '%s' "$_mem" | grep -c -i -- "$KNOWN_PERSON")"
    if [ "$_hits" -gt 0 ]; then
        probe_cannot_run "the daemon ALREADY remembers ${KNOWN_PERSON} (${_hits} match(es) before the first question). It can answer from memory without calling a tool, which renders as a grounded pass. The box needs a fresh install for this measurement. Nothing about the model was learned."
        return
    fi
    probe_note "precondition 1 OK: the seeded person is absent from daemon memory before the first question"

    # ── THE BATTERY: N fresh sessions, the seeded question FIRST in each ─────
    _grounded=0; _no_tool=0; _tool_no_fact=0; _reply_no_fact=0; _incomplete=0; _done=0
    _client="$(_ws_client_py | base64 | tr -d '\n')"
    _i=0
    while [ "$_i" -lt "$OPENINGS" ]; do
        _i=$((_i + 1))
        # A FRESH SESSION EVERY TIME. Reusing one session would put the second
        # question second, which is the position that already grounds 40/40.
        _sess="openingturn-$$-${_i}-$(date +%s)"
        _out="$(box_run "printf '%s' '${_client}' | base64 -d | OSTLER_SESSION='${_sess}' OSTLER_Q='${SEEDED_QUESTION}' OSTLER_EXPECT='${EXPECT_FACT}' python3 - 2>/dev/null")"
        if [ -z "$_out" ]; then
            _incomplete=$((_incomplete + 1))
            probe_note "opening ${_i}: NO FRAMES (transport, not a model result) -- excluded from the denominator"
            continue
        fi
        _done=$((_done + 1))
        _tool="$(printf '%s\n' "$_out" | grep -E '^FRAME tool_call ' | grep -cE 'pwg_')"
        _toolname="$(printf '%s\n' "$_out" | sed -n 's/^FRAME tool_call \(pwg_[a-z_]*\).*/\1/p' | head -1)"
        _toolfact="$(printf '%s\n' "$_out" | grep -c '^FRAME tool_fact YES')"
        _replyfact="$(printf '%s\n' "$_out" | grep -c '^FRAME reply_fact YES')"
        if [ "$_tool" -eq 0 ]; then
            _no_tool=$((_no_tool + 1))
            probe_note "opening ${_i}: no_tool_call            tool=-            tool_fact=no  reply_fact=$( [ "$_replyfact" -gt 0 ] && echo yes || echo no )"
        elif [ "$_toolfact" -eq 0 ]; then
            _tool_no_fact=$((_tool_no_fact + 1))
            probe_note "opening ${_i}: tool_found_nothing      tool=${_toolname:-pwg_?}  tool_fact=no  reply_fact=$( [ "$_replyfact" -gt 0 ] && echo yes || echo no )"
        elif [ "$_replyfact" -eq 0 ]; then
            _reply_no_fact=$((_reply_no_fact + 1))
            probe_note "opening ${_i}: fact_missing_in_reply   tool=${_toolname:-pwg_?}  tool_fact=yes reply_fact=no"
        else
            _grounded=$((_grounded + 1))
            probe_note "opening ${_i}: grounded                tool=${_toolname:-pwg_?}  tool_fact=yes reply_fact=yes"
        fi
    done

    probe_examined "$_done"
    probe_note "model_tag=${MODEL_TAG} ram_gb=${RAM_GB:-unread} openings_completed=${_done} grounded=${_grounded} no_tool_call=${_no_tool} tool_found_nothing=${_tool_no_fact} fact_missing_in_reply=${_reply_no_fact} transport_excluded=${_incomplete}"

    # ── THE DENOMINATOR GATE, fixed in advance ──────────────────────────────
    if [ "$_done" -lt "$MIN_OPENINGS" ]; then
        probe_cannot_run "only ${_done} opening(s) completed, and the reading requires ${MIN_OPENINGS}. The rate under test is about one in ten, so fewer cannot separate 'fixed' from 'got lucky'. A clean run at this denominator is NOT an answer and is not reported as one."
        return
    fi

    # ── THE READING ─────────────────────────────────────────────────────────
    if [ "$_grounded" -eq "$_done" ]; then
        probe_pass "${_done}/${_done} openings grounded on ${MODEL_TAG} at ${RAM_GB:-unread}GB. Every opening called a pwg_ tool, the tool output carried the seeded fact, and the reply carried it."
        return
    fi
    if [ "$_no_tool" -gt 0 ] && [ "$((_tool_no_fact + _reply_no_fact))" -eq 0 ]; then
        probe_fail "${_no_tool}/${_done} openings called NO tool on ${MODEL_TAG} at ${RAM_GB:-unread}GB. Every failure is at the opening and none is beyond it, which is the cold-start shape: the handover did not take. This is a DEFECT AGAINST ostler-assistant #404, not a question about the model's capability."
        return
    fi
    probe_fail "${_done} openings on ${MODEL_TAG} at ${RAM_GB:-unread}GB: grounded=${_grounded} no_tool_call=${_no_tool} tool_found_nothing=${_tool_no_fact} fact_missing_in_reply=${_reply_no_fact}. Failures occur BEYOND the no-tool-call shape, which is the capability ceiling nobody has observed before. That is a SPEC DECISION about the minimum supported machine, for Andy, and NOT a daemon fix."
}

probe_main "$@"
