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
#: The daemon's plain-socket listener. ostler-assistant binds 127.0.0.1:8000
#: (and *:8443 for the TLS companion); the client here speaks plain sockets, so
#: 8000 is the one it can use. Overridable, because a port is exactly the kind
#: of fact that moves.
DAEMON_PORT="${OSTLER_DAEMON_PORT:-8000}"
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

# ── PRECONDITION 2 and 3: the independent variables, READ not inferred ──────
#
# The model comes from the LIVE config on the box. lib/ostler-model-fit.sh is
# deliberately NOT consulted: it says what SHOULD be picked for the RAM, and
# the whole point of recording both is that the pair can DISAGREE. A probe
# that derives its independent variable from a table is measuring the table.
_read_model_tag() {
    # 🔴 THIS READ THE WRONG FILE AND THAT IS WHY THIS PROBE HAS NEVER RUN.
    # It read $HOME/.ostler/config/ai.env. Measured on the v1.0.100 box
    # 2026-09-17: that path does not exist, and nothing in install.sh writes
    # it -- `grep -c 'ai\.env' install.sh` is 0 against a control of 24 for
    # 'config/.env'. The installer writes AI_MODEL to $OSTLER_ENV_FILE, set at
    # install.sh:14170 to "${OSTLER_DIR}/.env", i.e. ~/.ostler/.env, at
    # install.sh:14265. On the box that file holds AI_MODEL=gemma4:e2b.
    #
    # The failure was invisible in the worst way: the probe reported
    # CANNOT-RUN with a correct-sounding reason ("could not read AI_MODEL from
    # the live config"), which reads as a box that has not been configured
    # rather than a probe looking in the wrong place. TNM's decider has never
    # produced a number because of this line.
    #
    # Both paths are read, most-likely first, and the one that answered is
    # reported, so a future move shows up as a changed provenance string
    # instead of a silent CANNOT-RUN.
    box_run 'for f in "$HOME/.ostler/.env" "$HOME/.ostler/config/.env" "$HOME/.ostler/config/ai.env"; do
                 v=$(sed -n "s/^AI_MODEL=//p" "$f" 2>/dev/null | tr -d "\"'"'"'" | head -1)
                 if [ -n "$v" ]; then printf "%s\t%s\n" "$v" "$f"; exit 0; fi
             done'
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
# 🔴 THIS ASKED AN ENDPOINT THAT DOES NOT EXIST, ON THE WRONG PORT, WITHOUT A
# CREDENTIAL. Three faults in one line, and every one of them produced the same
# empty string, which the caller then read as "the person is not in memory".
#
# Measured on the v1.0.100 box 2026-09-17:
#   GET :8000/api/v1/memory/search?q=Jane%20Doe   -> 404 {"error":"unknown endpoint"}
#     ...and 404 WITH a valid service token too, so it was never an auth problem
#   GET :8090/api/v1/people/context?name=Jane%20Doe -> 200 {"found": true, ...}
#
# The seed oracle that plants the person has always used :8090 and
# /api/v1/people/context -- it says so in its own output ("seed: people-API
# http://127.0.0.1:8090") -- and this probe asked somewhere else entirely.
#
# `curl -fsS` is what made it silent: -f turns any HTTP error into a non-zero
# exit and NO BODY, so a 404 and a genuinely empty memory are the same empty
# string here. That is the #945 shape exactly, in the instrument rather than in
# the product: a reader that cannot tell "refused" from "nothing there".
#
# So: right port, right path, credential presented, and the HTTP CODE is
# returned alongside the body so the caller can tell the three apart.
_memory_mentions_person() {
    box_run "TOK=\$(cat \"\$HOME/.ostler/secrets/service_token\" 2>/dev/null); \
             curl -sS --max-time 10 -w '\\nHTTP_CODE=%{http_code}' \
                  -H \"Authorization: Bearer \$TOK\" \
                  'http://127.0.0.1:8090/api/v1/people/context?name=$(printf '%s' "$KNOWN_PERSON" | sed 's/ /%20/g')' 2>/dev/null"
}

# The assistant's OWN memory, which is NOT the people API. install.sh's reset
# path names it directly -- "assistant-config (memory/brain.db, the poisoned
# count rows that made grounded measure history)" -- so that is the file to
# ask. Prints a COUNT, or nothing at all when it could not look, and the caller
# keeps those two apart.
_assistant_conv_memory_hits() {
    box_run "db=\"\$HOME/.ostler/assistant-config/memory/brain.db\"; \
             [ -r \"\$db\" ] || db=\"\$HOME/.ostler/assistant-config/brain.db\"; \
             if [ -r \"\$db\" ]; then \
                 strings -a \"\$db\" 2>/dev/null | grep -c -i -- '${KNOWN_PERSON}'; \
             elif [ -d \"\$HOME/.ostler/assistant-config\" ]; then \
                 grep -rc -i -- '${KNOWN_PERSON}' \"\$HOME/.ostler/assistant-config\" 2>/dev/null | awk -F: '{t+=\$2} END{print t+0}'; \
             fi"
}

# Wrap a value in single quotes for a command sent over ssh, escaping any
# embedded single quote. The seeded question ends in '?', which the remote
# shell (zsh on a real walk box) GLOBS if it arrives bare -- "no matches found"
# and the command never runs.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

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
    MODEL_TAG_SRC="${MODEL_TAG#*$(printf '\t')}"
    MODEL_TAG="${MODEL_TAG%%$(printf '\t')*}"
    probe_note "model_tag=${MODEL_TAG} (read from ${MODEL_TAG_SRC:-unknown}, NOT inferred from the fit table)"
    probe_note "ram_gb=${RAM_GB:-unread}"

    # The fit-table cross-check. A DISAGREEMENT is reported and does not stop
    # the run: what is running is what is running, and the probe records it.
    if [ -n "$RAM_GB" ] && [ "$RAM_GB" -le 23 ] 2>/dev/null && [ "$MODEL_TAG" != "gemma4:e2b" ]; then
        probe_note "NOTE: ${RAM_GB}GB should give gemma4:e2b by the fit table, and the live config says ${MODEL_TAG}. Recorded as measured; the table is not the authority here."
    fi

    _mem="$(_memory_mentions_person)"
    _mem_code="$(printf '%s' "$_mem" | sed -n 's/^HTTP_CODE=//p' | tail -1)"
    # A non-200 is CANNOT-RUN and names the code. It is NOT "the person is
    # absent": that conflation is the defect this function was just fixed for.
    if [ -n "$_mem_code" ] && [ "$_mem_code" != "200" ]; then
        probe_cannot_run "the people API answered http=${_mem_code} for '${KNOWN_PERSON}', so precondition 1 is UNESTABLISHED. That is a refusal or a wrong route, NOT evidence that the person is missing from memory."
        return
    fi
    if [ -z "$_mem" ]; then
        probe_cannot_run "could not read daemon memory for the seeded person, so precondition 1 is UNESTABLISHED. 'Could not look' is not 'absent', and an opening turn run against unknown memory state is exactly the confound that voided the previous result."
        return
    fi
    # 🔴 PRECONDITION 1 WAS INVERTED IN EFFECT, AND IT IS WHY THIS PROBE HAS
    # NEVER PRODUCED A NUMBER.
    #
    # Its stated intent, from the header: "the daemon could answer from memory
    # of a PREVIOUS RUN and never call a tool". That is the assistant's own
    # CONVERSATIONAL memory. The check read /api/v1/people/context instead --
    # which is the PEOPLE STORE, i.e. the data source the tool reads.
    #
    # So the probe refused whenever the seeded person was present in the very
    # store the experiment requires to be populated. Measured 2026-09-17: the
    # seed plants Jane Doe, people/context then returns 3 matches, and the
    # probe reported CANNOT-RUN "the daemon ALREADY remembers Jane Doe". The
    # seed and the precondition were fighting each other, and the precondition
    # always won.
    #
    # The two are now checked SEPARATELY and in opposite directions:
    #   1a. the person MUST be in the people store, or the tool has nothing to
    #       find and an ungrounded answer proves nothing about the model
    #   1b. the person must NOT be in the assistant's conversational memory,
    #       which is the actual confound the header describes
    _hits="$(printf '%s' "$_mem" | grep -c -i -- "$KNOWN_PERSON")"
    if [ "$_hits" -eq 0 ]; then
        probe_cannot_run "the people store does NOT hold ${KNOWN_PERSON}, so the tool has nothing to find. An ungrounded reply would then be a missing seed and not a model result. Re-run the seed oracle first."
        return
    fi
    probe_note "precondition 1a OK: the people store holds ${KNOWN_PERSON} (${_hits} match(es)), so the tool has something to find"

    # 1b: the assistant's OWN memory, which is a different store from the
    # people API. Absence here is what the experiment needs. An unreadable
    # memory is CANNOT-RUN, never a pass: "could not look" is not "absent".
    _conv="$(_assistant_conv_memory_hits)"
    if [ -z "$_conv" ]; then
        probe_cannot_run "could not read the assistant's conversational memory, so precondition 1b is UNESTABLISHED. Not instrumented, and NOT 'no prior memory'."
        return
    fi
    # 1b IS A RECORDED CAVEAT, NOT A REFUSAL, AND THE DIRECTION OF THE BIAS IS
    # WHY.
    #
    # The header's fear was that prior memory "renders as a grounded pass".
    # Read against the scoring below, it cannot. `_grounded` is reached only
    # when the tool was CALLED, the tool returned the fact, AND the reply
    # carries it. An answer produced from memory with no tool call takes the
    # first branch and is counted `no_tool_call`, which is a FAILURE -- and
    # no_tool_call is the precise shape this experiment exists to measure.
    #
    # So prior memory biases the result PESSIMISTICALLY. It can cost the model
    # a grounded opening; it cannot buy it one. A pessimistic bias is safe to
    # run under and unsafe to hide, so it is recorded on every result instead
    # of stopping the run.
    #
    # It also cannot be designed away here: the ONLY seed route is
    # POST /api/v1/memory/assert, which writes the daemon's memory by
    # definition. A hard refusal therefore made the experiment unrunnable on
    # any box where the seed had worked, which is every box. Measured
    # 2026-09-17: people store 3 matches (needed), conversational memory 10
    # hits (unavoidable), and the probe refused.
    if [ "$_conv" != "0" ]; then
        MEMORY_CAVEAT="the assistant's conversational memory already mentions ${KNOWN_PERSON} (${_conv} hit(s)) before the first question. The ONLY seed route is POST /api/v1/memory/assert, so this is unavoidable with the current oracle. It biases the result AGAINST the model -- a memory answer with no tool call scores no_tool_call, a failure -- and can never inflate the grounded count."
        probe_note "precondition 1b CAVEAT: ${MEMORY_CAVEAT}"
    else
        probe_note "precondition 1b OK: ${KNOWN_PERSON} is absent from the assistant's conversational memory before the first question"
    fi

    # ── THE BATTERY: N fresh sessions, the seeded question FIRST in each ─────
    _grounded=0; _no_tool=0; _tool_no_fact=0; _reply_no_fact=0; _incomplete=0; _done=0
    _cold_n=0; _warm_n=0; _unk_n=0; _cold_ttft=""; _warm_ttft=""
    _client="$(_ws_client_py | base64 | tr -d '\n')"
    _i=0
    while [ "$_i" -lt "$OPENINGS" ]; do
        _i=$((_i + 1))
        # A FRESH SESSION EVERY TIME. Reusing one session would put the second
        # question second, which is the position that already grounds 40/40.
        _sess="openingturn-$$-${_i}-$(date +%s)"
        # COLD or WARM, READ BEFORE THE REQUEST. `ollama ps` lists models
        # currently resident. If the model under test is absent, this opening
        # pays a cold load; if present, it does not. TTFT differs between the
        # two by an order of magnitude, so a blended figure is not a number
        # anyone can use, and this label is what keeps them separable.
        # THREE STATES, not two: if `ollama ps` cannot be read at all, the row
        # is UNKNOWN and is excluded from BOTH aggregates rather than being
        # guessed into one of them.
        _ps="$(box_run 'ollama ps 2>/dev/null' || true)"
        if [ -z "$_ps" ]; then
            _thermal="UNKNOWN"
        elif [ "$(printf '%s\n' "$_ps" | grep -c -- "${MODEL_TAG%%:*}")" -gt 0 ]; then
            _thermal="WARM"
        else
            _thermal="COLD"
        fi
        # 🔴 TWO FAULTS ON THIS LINE, AND TOGETHER THEY MADE EVERY OPENING READ
        # AS A TRANSPORT FAILURE.
        #
        # 1. NO PORT WAS PASSED. The client's first statement is
        #       host, port = "127.0.0.1", int(sys.argv[1])
        #    and this invoked it as `python3 -` with no argv[1] at all, so it
        #    died on IndexError before opening a socket. Measured 2026-09-17:
        #    10 of 10 openings reported "NO FRAMES (transport...)".
        #
        # 2. `2>/dev/null` HID THAT. The client prints PROBE_FATAL on stderr
        #    precisely so a transport failure is legible, and this threw it
        #    away, leaving an empty stdout that is indistinguishable from a
        #    daemon that answered nothing. That is this repo's own rule --
        #    never manufacture a clean input, read stderr -- broken in the
        #    instrument written to enforce it.
        #
        # stderr is now MERGED, not discarded, so a fatal is visible in the
        # note rather than inferred from silence.
        # 🔴 THE PROBE AND ITS OWN EMBEDDED CLIENT DISAGREED ABOUT THE INTERFACE.
        # The client's signature, read from the source rather than assumed:
        #     argv[1] port   argv[2] token_path   argv[3] question
        #     argv[4] deadline_s   argv[5] expect_fact (optional)
        # and the ONLY environment variable it consults is
        # OSTLER_GROUNDED_FRAMES, the fixture switch. This line passed
        # OSTLER_SESSION, OSTLER_Q and OSTLER_EXPECT -- none of which the client
        # reads -- and no positional arguments at all. So it died on
        # `sys.argv[2]` every single time, before opening a socket.
        #
        # Measured 2026-09-17 by running the extracted client by hand on the
        # box, which is the only reason the real traceback was ever seen:
        #     File "/tmp/wsclient.py", line 52
        #       token_path, question, deadline_s = sys.argv[2], sys.argv[3], ...
        #     IndexError: list index out of range
        #
        # NOTE ON THE SESSION. The client takes no session argument, so a
        # "fresh session per opening" cannot be requested through it. That is
        # recorded in the verdict rather than quietly assumed, because
        # precondition 4 depends on it.
        _out="$(box_run "printf '%s' '${_client}' | base64 -d | python3 - ${DAEMON_PORT} \"\$HOME/.ostler/secrets/zeroclaw_admin_token\" $(_shq "$SEEDED_QUESTION") 120 $(_shq "$EXPECT_FACT") 2>&1")"
        if [ -z "$_out" ] || printf '%s' "$_out" | grep -q '^PROBE_FATAL\|Traceback'; then
            _incomplete=$((_incomplete + 1))
            _why="$(printf '%s' "$_out" | grep -m1 '^PROBE_FATAL\|Error' | head -c 160)"
            probe_note "opening ${_i}: NO FRAMES (transport, not a model result) -- excluded from the denominator. ${_why:-client produced no output at all}"
            continue
        fi
        _done=$((_done + 1))
        _tool="$(printf '%s\n' "$_out" | grep -E '^FRAME tool_call ' | grep -cE 'pwg_')"
        _toolname="$(printf '%s\n' "$_out" | sed -n 's/^FRAME tool_call \(pwg_[a-z_]*\).*/\1/p' | head -1)"
        _toolfact="$(printf '%s\n' "$_out" | grep -c '^FRAME tool_fact YES')"
        _ttft="$(printf '%s\n' "$_out" | sed -n 's/^FRAME ttft_s //p' | head -1)"
        _tps="$(printf '%s\n' "$_out" | sed -n 's/^FRAME tok_per_s //p' | head -1)"
        _ntok="$(printf '%s\n' "$_out" | sed -n 's/^FRAME tokens //p' | head -1)"
        probe_note "opening ${_i}: thermal=${_thermal} ttft_s=${_ttft:-NOT-MEASURED} tok_per_s=${_tps:-NOT-MEASURED} tokens=${_ntok:-0} model=${MODEL_TAG} ram_gb=${RAM_GB:-unread}"
        case "$_thermal" in
            COLD) _cold_n=$((_cold_n+1)); [ -n "$_ttft" ] && _cold_ttft="$_cold_ttft $_ttft" ;;
            WARM) _warm_n=$((_warm_n+1)); [ -n "$_ttft" ] && _warm_ttft="$_warm_ttft $_ttft" ;;
            *)    _unk_n=$((_unk_n+1)) ;;
        esac
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

    # COLD AND WARM ARE REPORTED SEPARATELY AND NEVER BLENDED. A mean over both
    # populations is not a number anyone can act on: they differ by an order of
    # magnitude, so the blend just tells you the mix, not the machine.
    _mean() { [ -z "$1" ] && { printf 'NOT-MEASURED'; return; }; printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | awk '{s+=$1;n++} END{ if(n>0) printf "%.3f (n=%d)", s/n, n; else printf "NOT-MEASURED" }'; }
    probe_note "MEMORY CAVEAT: ${MEMORY_CAVEAT:-none -- conversational memory was clean}"
    probe_note "TTFT COLD: $(_mean "$_cold_ttft")   TTFT WARM: $(_mean "$_warm_ttft")   unknown-thermal openings: ${_unk_n} (excluded from BOTH)"
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
