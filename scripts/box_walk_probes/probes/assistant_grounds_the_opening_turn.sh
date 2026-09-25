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
PROBE_QUESTION="does this box ground the FIRST turn of a fresh session, ten times over, on the model it is actually running?"
OPENINGS="${OSTLER_OPENING_TURNS:-10}"
MIN_OPENINGS=10

# ── THE CLIENT TAKES FIVE POSITIONAL ARGUMENTS AND WAS HANDED NONE ──────────
#
# 🔴 _ws_client_py reads sys.argv[1..5]: port, token path, question, deadline,
# expected fact. This probe used to invoke it as a bare `python3 -` with the
# question and the fact EXPORTED as OSTLER_Q and OSTLER_EXPECT, names the
# client has never read, and it declared no gateway, no token path and no
# timeout at all. `int(sys.argv[1])` therefore raised IndexError on line 1 of
# the client body, every opening, on every box. Reproduced 2026-09-23 by
# extracting the function and running it with no argv:
#   IndexError: list index out of range
#
# The traceback went to `2>/dev/null`, so the probe saw an empty string and
# recorded ten rows of "NO FRAMES (transport, not a model result)" -- a CAUSE
# it had no instrument to see, for a crash that was its own. It then met the
# denominator gate at 0 of 10 and exited CANNOT-RUN. So even with the
# dispatcher defect below repaired, this probe could never have produced a
# verdict about the assistant.
#
# The three knobs and their defaults are assistant_answers_grounded's, because
# the client IS that probe's client and takes that probe's arguments.
CHAT_TIMEOUT="${OSTLER_PROBE_CHAT_TIMEOUT:-420}"
GATEWAY="${OSTLER_PROBE_GATEWAY:-http://127.0.0.1:8000}"
# TILDE, NOT $HOME. python's os.path.expanduser expands `~` and leaves `$VAR`
# verbatim, so a $HOME here comes back PROBE_FATAL no_token.
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}"

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
# 🔴 AND IT READ A FILE NO INSTALL HAS EVER WRITTEN. This used to read
# $HOME/.ostler/config/ai.env. Measured 2026-09-23 on origin/main: the string
# "ai.env" occurs in exactly ONE file in this repository, this one. install.sh
# writes the model with
#     printf 'AI_MODEL=%s\n' "${AI_MODEL:-qwen3.5:9b}" >> "$OSTLER_ENV_FILE"
# (install.sh:14516) and OSTLER_ENV_FILE is "${OSTLER_DIR}/.env"
# (install.sh:14421), i.e. $HOME/.ostler/.env.
#
# Measured on the walk box after a real install: that file carries exactly one
# AI_MODEL line and its value is gemma4:e2b; $HOME/.ostler/config/ holds only
# .env, with zero AI_MODEL lines; $HOME/.ostler/config/ai.env does not exist.
# CONTROL, the same reader against an invented key name on the same file,
# returns 0, so those zeros are real absences and not a broken predicate.
#
# So precondition 2 was UNSATISFIABLE on any real box, and the refusal it
# produced -- "could not read AI_MODEL from the live config on the box" --
# asserted a cause it had no instrument to see: it could not tell "the config
# does not carry the model" from "I read the wrong file". The reader is now
# THREE-VALUED and the refusal quotes the state and NAMES THE FILE, so the
# next reader is told what was looked at rather than what was concluded.
#
# _read_model_state -> "nofile" | "nokey" | "ok <tag>"
_read_model_state() {
    box_run '_f="$HOME/.ostler/.env"
if [ ! -f "$_f" ]; then echo nofile; exit 0; fi
_v="$(sed -n "s/^AI_MODEL=//p" "$_f" | tr -d "\"'"'"'" | head -1)"
if [ -z "$_v" ]; then echo nokey; else printf "ok %s\n" "$_v"; fi'
}
MODEL_ENV_FILE='$HOME/.ostler/.env'

# `ollama` IS NOT ON THE PATH box_run GETS. box_run's remote arm is a plain
# ssh, not a login shell. Measured on the walk box: that PATH is
# /usr/bin:/bin:/usr/sbin:/sbin and `ollama ps` answers "command not found";
# CONTROL, the same command with /opt/homebrew/bin prefixed, prints the ps
# header. So every thermal label was UNKNOWN and BOTH TTFT aggregates were
# empty -- the timing instrumentation this probe was extended for could never
# have produced a number. PREFIXED, never replaced: the box's own PATH still
# wins for everything else.
_read_ollama_ps() {
    box_run 'PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"; ollama ps 2>/dev/null'
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
# THE ROUTE THIS USED TO READ DOES NOT EXIST. It asked
# /api/v1/memory/search, unauthenticated, through curl -f. The daemon has no
# such route (measured on the v1.0.102 walk-4 box: 404 "unknown endpoint", with
# or without the admin token), so the reading was empty on every box and this
# probe was CANNOT-RUN on every walk it has ever been in, reported as "could
# not read daemon memory" and never as "the instrument asks a route nobody
# serves". The daemon's memory API is GET /api/memory?query= (recall, top 50)
# and DELETE /api/memory/{key}, both behind the admin bearer token
# (ostler-assistant crates/zeroclaw-gateway/src/lib.rs, the /api/memory
# routes). python on the box, not curl, so the token never rides on a command
# line and a refused read names its HTTP status instead of printing nothing.
read -r -d '' MEMORY_PY <<'PYMEMORY'
import json, os, sys, urllib.error, urllib.parse, urllib.request
gw, tok_path, person, action = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
try:
    tok = open(os.path.expanduser(tok_path), encoding="utf-8").read().strip()
except Exception as exc:
    print("UNREADABLE token " + type(exc).__name__); sys.exit(0)
H = {"Authorization": "Bearer " + tok}
def call(method, path):
    req = urllib.request.Request(gw + path, headers=H, method=method)
    return urllib.request.urlopen(req, timeout=15)
try:
    if action == "read":
        d = json.load(call("GET", "/api/memory?query=" + urllib.parse.quote(person)))
        entries = d.get("entries") if isinstance(d, dict) else None
        if not isinstance(entries, list):
            print("UNREADABLE shape " + type(d).__name__); sys.exit(0)
        hits = [e.get("key", "") for e in entries
                if person.lower() in str(e.get("content") or "").lower()]
        print("READ %d %d" % (len(entries), len(hits)))
        for k in hits:
            print("KEY " + k)
    else:
        ok = bad = 0
        for k in sys.argv[5:]:
            try:
                call("DELETE", "/api/memory/" + urllib.parse.quote(k, safe=""))
                ok += 1
            except Exception:
                bad += 1
        print("FORGOT %d %d" % (ok, bad))
except urllib.error.HTTPError as exc:
    print("UNREADABLE http %d" % exc.code)
except Exception as exc:
    print("UNREADABLE " + type(exc).__name__)
PYMEMORY

_memory_mentions_person() {
    # ${GATEWAY}, not a second hard-coded 127.0.0.1:8000. The refusal this
    # feeds NAMES the URL it could not read, and a message that names one
    # address while the reader used another is the shape that makes a probe's
    # reason untrustworthy even when its verdict is right.
    box_run "python3 - '${GATEWAY}' '${TOKEN_PATH}' '${KNOWN_PERSON}' read <<'PYMEMORY'
${MEMORY_PY}
PYMEMORY"
}

_memory_forget_keys() {
    box_run "python3 - '${GATEWAY}' '${TOKEN_PATH}' '${KNOWN_PERSON}' forget $* <<'PYMEMORY'
${MEMORY_PY}
PYMEMORY"
}

# _read_memory_answer <reader output> -> UNREADABLE | ABSENT | PRESENT
# One copy, driven by run_probe and by the self-test.
_read_memory_answer() {
    case "$1" in
        "READ "*)
            local n
            n="$(printf '%s\n' "$1" | awk 'NR==1 {print $3}')"
            case "$n" in ''|*[!0-9]*) printf 'UNREADABLE'; return ;; esac
            if [ "$n" -gt 0 ]; then printf 'PRESENT'; else printf 'ABSENT'; fi ;;
        *) printf 'UNREADABLE' ;;
    esac
}

# ── THE DECISIONS, ONE COPY EACH, DRIVEN BY run_probe AND self_test ─────────
#
# Split out so the negative control adjudicates the SAME code the walk does. A
# self-test that drives a second copy of the reading proves the copy.
#
# COUNTED GREP ONLY, NEVER `| grep -q`: that construct SIGPIPEs its producer
# and under `set -o pipefail` reports failure for a pattern it found. And
# never `grep -c ... || echo 0`: grep -c prints 0 AND exits 1 on no match, so
# the `||` fires and emits "0\n0", on which every later numeric test exits 2
# with "integer expected" -- SKIPPING the comparison rather than failing it
# (tests/test_grep_c_arith_safety.sh; it cost four release tags).

# _classify_opening <frames-file>
#   -> no_tool_call | tool_found_nothing | fact_missing_in_reply | grounded
_classify_opening() {
    _co_f="$1"
    _co_tool="$(grep -E '^FRAME tool_call ' "$_co_f" | grep -cE 'pwg_')"
    _co_toolfact="$(grep -c '^FRAME tool_fact YES' "$_co_f")"
    _co_replyfact="$(grep -c '^FRAME reply_fact YES' "$_co_f")"
    if [ "$_co_tool" -eq 0 ];     then printf 'no_tool_call'; return; fi
    if [ "$_co_toolfact" -eq 0 ]; then printf 'tool_found_nothing'; return; fi
    if [ "$_co_replyfact" -eq 0 ]; then printf 'fact_missing_in_reply'; return; fi
    printf 'grounded'
}

# _classify_client_run <raw-file>
#   -> frames | client_fault | client_refused | silent | unreadable
#
# 🔴 THE DEFECT THIS EXISTS TO CLOSE, AND IT IS THE ONE WORTH MORE THAN THE
# DISPATCHER. The old loop read one variable, found it empty, and wrote
#   "opening N: NO FRAMES (transport, not a model result)"
# It held no instrument that could see transport. The actual cause was a
# python traceback it had just sent to /dev/null. That is the same category as
# doctor_page_renders_for_a_customer announcing "the Doctor is not serving:
# /api/v1/sources answered 000" while the Doctor served 200 -- a probe naming
# a CAUSE from a reading that cannot distinguish it.
#
# So the arms are separated by what is actually on the surface, and the only
# one that may be called transport is the one where the client said NOTHING.
# An output that is none of these is `unreadable`, never folded into a
# neighbour: a fifth shape nobody predicted must not be dressed as one of the
# four that were.
_classify_client_run() {
    _cc_f="$1"
    if [ "$(grep -c '^FRAME ' "$_cc_f")" -gt 0 ]; then printf 'frames'; return; fi
    if [ "$(grep -cE '^Traceback \(most recent call last\):|^[A-Za-z_]*(Error|Exception): ' "$_cc_f")" -gt 0 ]; then
        printf 'client_fault'; return
    fi
    if [ "$(grep -c '^PROBE_FATAL ' "$_cc_f")" -gt 0 ]; then printf 'client_refused'; return; fi
    if [ "$(wc -c < "$_cc_f" | tr -d ' ')" -eq 0 ]; then printf 'silent'; return; fi
    printf 'unreadable'
}

# _read_the_battery <done> <grounded> <no_tool> <tool_no_fact> <reply_no_fact> <min>
#   -> CANNOT-RUN-DENOMINATOR | PASS | FAIL-COLD-START | FAIL-CEILING
#
# THE DENOMINATOR IS TESTED FIRST, and it is tested before the "all grounded"
# arm ON PURPOSE: with done=0 and grounded=0 the equality arm is TRUE, and a
# zero denominator reading as a clean pass is the exact failure this suite was
# built around.
_read_the_battery() {
    _rb_d="$1"; _rb_g="$2"; _rb_nt="$3"; _rb_tnf="$4"; _rb_rnf="$5"; _rb_min="$6"
    if [ "$_rb_d" -lt "$_rb_min" ]; then printf 'CANNOT-RUN-DENOMINATOR'; return; fi
    if [ "$_rb_g" -eq "$_rb_d" ]; then printf 'PASS'; return; fi
    if [ "$_rb_nt" -gt 0 ] && [ "$((_rb_tnf + _rb_rnf))" -eq 0 ]; then printf 'FAIL-COLD-START'; return; fi
    printf 'FAIL-CEILING'
}

# 🔴 THE PROBE USED TO DEFINE ITS BODY AS `probe_main`, WHICH IS THE NAME OF
# THE LIBRARY DISPATCHER IT HAD JUST SOURCED (lib/probe.sh:338). The later
# definition won, so the final `probe_main "$@"` never dispatched: `--self-test`
# and `--describe` both ran the real measurement. In phase 1 the gate variables
# are unset by design, so the first guard below called probe_cannot_run and the
# process exited 78 = PROBE_EX_CANNOT_RUN (EX_CONFIG). run_box_walk.sh:178 read
# that as "self-test returned 78, expected 1", marked the probe BROKEN, and
# :445-451 then SKIPPED its phase 2 -- so this probe has never once run on a
# walk. 78 was a real exit code, not a count that leaked into one and not a $?
# read through a pipe.
#
# The body is `run_probe` now, which is the contract, and
# tests/test_no_probe_shadows_the_dispatcher.sh fails the build if any probe
# in this directory takes the dispatcher's name again.
run_probe() {
    [ -n "$KNOWN_PERSON" ] || { probe_cannot_run "OSTLER_GATE_KNOWN_PERSON is unset -- the seed oracle did not run, so there is no seeded person to ask about. Nothing was measured."; return; }
    [ -n "$EXPECT_FACT" ]  || { probe_cannot_run "OSTLER_GATE_EXPECT_FACT is unset -- without the expected fact a 'grounded' verdict would be unfalsifiable. Nothing was measured."; return; }
    box_reachable          || { probe_cannot_run "the box is not reachable, so no opening turn was asked. This is NOT a model result."; return; }

    _mstate="$(_read_model_state | tr -d '\r')"
    RAM_GB="$(_read_ram_gb | tr -d '\r')"
    case "$_mstate" in
        ok\ *)   MODEL_TAG="${_mstate#ok }" ;;
        nofile)  probe_cannot_run "${MODEL_ENV_FILE} does not exist on ${OSTLER_BOX_HOST:-this machine}, so the model this box is running was not read. That FILE is named here on purpose: the model is the INDEPENDENT VARIABLE of this experiment, and 'I read the wrong path' and 'the box has no model configured' are different facts. NOT INSTRUMENTED, not 'unknown model'."; return ;;
        nokey)   probe_cannot_run "${MODEL_ENV_FILE} exists on ${OSTLER_BOX_HOST:-this machine} and carries no AI_MODEL= line, so the model this box is running was not read. install.sh writes that line to that file; a file without it is an install that did not finish or a path that moved. NOT INSTRUMENTED, not 'unknown model'."; return ;;
        *)       probe_cannot_run "the reader for ${MODEL_ENV_FILE} answered '${_mstate:-<nothing>}', which is none of nofile / nokey / 'ok <tag>'. An answer outside its own vocabulary establishes nothing, and is not read as a model."; return ;;
    esac
    probe_note "model_tag=${MODEL_TAG} (read from ${MODEL_ENV_FILE}, the file install.sh writes, NOT inferred from the fit table)"
    probe_note "ram_gb=${RAM_GB:-unread}"

    # The fit-table cross-check. A DISAGREEMENT is reported and does not stop
    # the run: what is running is what is running, and the probe records it.
    if [ -n "$RAM_GB" ] && [ "$RAM_GB" -le 23 ] 2>/dev/null && [ "$MODEL_TAG" != "gemma4:e2b" ]; then
        probe_note "NOTE: ${RAM_GB}GB should give gemma4:e2b by the fit table, and the live config says ${MODEL_TAG}. Recorded as measured; the table is not the authority here."
    fi

    _mem="$(_memory_mentions_person)"
    _memstate="$(_read_memory_answer "$_mem")"
    if [ "$_memstate" = "UNREADABLE" ]; then
        probe_cannot_run "could not read daemon memory for the seeded person at ${GATEWAY}/api/memory (answer: $(printf '%s' "${_mem:-<nothing>}" | head -1)), so precondition 1 is UNESTABLISHED. 'Could not look' is not 'absent', and an opening turn run against unknown memory state is exactly the confound that voided the previous result."
        return
    fi
    if [ "$_memstate" = "PRESENT" ]; then
        _hits="$(printf '%s\n' "$_mem" | awk 'NR==1 {print $3}')"
        # THE WALK POISONS ITS OWN PRECONDITION. assistant_answers_grounded runs
        # before this probe and asks about the same seeded person, and the
        # daemon files that conversation in memory. So on every walk the
        # person is "remembered" by the time this probe looks. When the person
        # is the walk's SYNTHETIC seed (OSTLER_SEED_PERSON_IS_SYNTHETIC=1, set only
        # by grounding_seed_apply after it seeded), every memory naming them was
        # made by the walk, and removing exactly those entries restores the
        # precondition. When the operator keyed a REAL contact, customer memory
        # is never touched and the old refusal stands.
        if [ "${OSTLER_SEED_PERSON_IS_SYNTHETIC:-0}" = "1" ]; then
            _keys="$(printf '%s\n' "$_mem" | sed -n 's/^KEY //p' | tr '\n' ' ')"
            _forgot="$(_memory_forget_keys ${_keys})"
            _mem="$(_memory_mentions_person)"
            _memstate="$(_read_memory_answer "$_mem")"
            if [ "$_memstate" = "ABSENT" ]; then
                probe_note "precondition 1 RESTORED: removed ${_hits} memory entr(y/ies) the walk itself created about the synthetic seed person (${_forgot:-no forget answer}); re-read shows none"
            else
                probe_cannot_run "the daemon remembers the synthetic seed person ${KNOWN_PERSON} from earlier in this walk, and removing those entries did not take (${_forgot:-no forget answer}; re-read: ${_memstate}). It could answer from memory without calling a tool. Nothing about the model was learned."
                return
            fi
        else
            probe_cannot_run "the daemon ALREADY remembers ${KNOWN_PERSON} (${_hits} match(es) before the first question), and this is not the walk's synthetic seed person, so its memory is not the walk's to remove. It can answer from memory without calling a tool, which renders as a grounded pass. The box needs a fresh install for this measurement. Nothing about the model was learned."
            return
        fi
    fi
    probe_note "precondition 1 OK: the seeded person is absent from daemon memory before the first question"

    # ── STAGE THE CLIENT AND CHECK WHAT IT NEEDS, BEFORE ASKING ANYTHING ─────
    _port="${GATEWAY##*:}"
    box_run "test -f ${TOKEN_PATH}" >/dev/null 2>&1 \
        || { probe_cannot_run "no admin token at ${TOKEN_PATH} on ${OSTLER_BOX_HOST:-this machine}, so /ws/chat cannot be authenticated and no opening turn was asked. Coverage lost, NOT a pass."; return; }
    _remote_py="/tmp/ostler-probe-opening-$$.py"
    _b64="$(_ws_client_py | base64 | tr -d '\n')"
    box_run "printf %s '${_b64}' | base64 -d > ${_remote_py}" >/dev/null 2>&1 \
        || { probe_cannot_run "could not stage the WebSocket client at ${_remote_py} on ${OSTLER_BOX_HOST:-this machine}. Nothing was asked."; return; }

    # ── THE BATTERY: N fresh sessions, the seeded question FIRST in each ─────
    _grounded=0; _no_tool=0; _tool_no_fact=0; _reply_no_fact=0; _done=0
    _client_fault=0; _client_refused=0; _silent=0; _unreadable=0
    _first_fault=""; _first_refusal=""; _sessions_announced=0
    _cold_n=0; _warm_n=0; _unk_n=0; _cold_ttft=""; _warm_ttft=""
    _raw="$(mktemp)" || { probe_cannot_run "could not create a temp file to hold the client's output on this machine. Nothing was asked."; return; }
    _i=0
    while [ "$_i" -lt "$OPENINGS" ]; do
        _i=$((_i + 1))
        # COLD or WARM, READ BEFORE THE REQUEST. `ollama ps` lists models
        # currently resident. If the model under test is absent, this opening
        # pays a cold load; if present, it does not. TTFT differs between the
        # two by an order of magnitude, so a blended figure is not a number
        # anyone can use, and this label is what keeps them separable.
        # THREE STATES, not two: if `ollama ps` cannot be read at all, the row
        # is UNKNOWN and is excluded from BOTH aggregates rather than being
        # guessed into one of them.
        _ps="$(_read_ollama_ps)"
        if [ -z "$_ps" ]; then
            _thermal="UNKNOWN"
        elif [ "$(printf '%s\n' "$_ps" | grep -c -F -- "${MODEL_TAG%%:*}")" -gt 0 ]; then
            _thermal="WARM"
        else
            _thermal="COLD"
        fi

        # A FRESH SESSION EVERY TIME. Reusing one would put the question
        # second, which is the position that already grounds 40/40. Freshness
        # comes from a NEW PROCESS AND A NEW /ws/chat CONNECTION per opening,
        # which is what this loop does. It used to also export OSTLER_SESSION
        # with a unique value, and the client has never read that name, so the
        # variable asserted a property nothing implemented. What CAN be seen is
        # the gateway's own session_start frame, so that is counted instead of
        # claimed.
        #
        # STDERR IS KEPT. box_run discards it, which is how a traceback became
        # "transport" above; box_run_v is the same transport with stderr left
        # alone, and the classifier below reads it.
        box_run_v "python3 ${_remote_py} ${_port} '${TOKEN_PATH}' \"\$(printf %s '${SEEDED_QUESTION}')\" ${CHAT_TIMEOUT} \"\$(printf %s '${EXPECT_FACT}')\"" > "$_raw" 2>&1
        _shape="$(_classify_client_run "$_raw")"
        case "$_shape" in
            frames) : ;;
            client_fault)
                _client_fault=$((_client_fault + 1))
                [ -n "$_first_fault" ] || _first_fault="$(grep -E '^[A-Za-z_]*(Error|Exception): ' "$_raw" | head -1)"
                probe_note "opening ${_i}: CLIENT FAULT -- the probe's own client did not run (${_first_fault:-see stderr}). This is an INSTRUMENT defect, not a model result, and not transport."
                continue ;;
            client_refused)
                _client_refused=$((_client_refused + 1))
                [ -n "$_first_refusal" ] || _first_refusal="$(grep '^PROBE_FATAL ' "$_raw" | head -1)"
                probe_note "opening ${_i}: CLIENT REFUSED -- ${_first_refusal:-PROBE_FATAL}. The client NAMED why it could not ask; that is a prerequisite, not a model result."
                continue ;;
            silent)
                _silent=$((_silent + 1))
                probe_note "opening ${_i}: NO OUTPUT AT ALL from \`python3 ${_remote_py} ...\` on ${OSTLER_BOX_HOST:-this machine}. NOT INSTRUMENTED: nothing here can say whether that was the transport, the box or the client. Excluded from the denominator."
                continue ;;
            *)
                _unreadable=$((_unreadable + 1))
                probe_note "opening ${_i}: the client produced output that is neither frames, nor a python error, nor PROBE_FATAL. Excluded from the denominator rather than guessed into one of them."
                continue ;;
        esac

        _done=$((_done + 1))
        [ "$(grep -c '^FRAME session_start$' "$_raw")" -gt 0 ] && _sessions_announced=$((_sessions_announced + 1))
        # HOISTED, NOT INLINED IN THE NOTE BELOW. `[ "$(grep -c X f)" -gt 0 ]
        # && echo yes || echo no` reads as the `grep -c ... || echo` idiom to
        # tests/test_grep_c_arith_safety.sh, which is scoped to these probes
        # precisely because that idiom cost four release tags. One read, one
        # variable, no argument with the gate.
        _replyfact="$(grep -c '^FRAME reply_fact YES' "$_raw")"
        _toolname="$(sed -n 's/^FRAME tool_call \(pwg_[a-z_]*\).*/\1/p' "$_raw" | head -1)"
        _ttft="$(sed -n 's/^FRAME ttft_s //p' "$_raw" | head -1)"
        _tps="$(sed -n 's/^FRAME tok_per_s //p' "$_raw" | head -1)"
        _ntok="$(sed -n 's/^FRAME tokens //p' "$_raw" | head -1)"
        probe_note "opening ${_i}: thermal=${_thermal} ttft_s=${_ttft:-NOT-MEASURED} tok_per_s=${_tps:-NOT-MEASURED} tokens=${_ntok:-0} model=${MODEL_TAG} ram_gb=${RAM_GB:-unread}"
        case "$_thermal" in
            COLD) _cold_n=$((_cold_n+1)); [ -n "$_ttft" ] && _cold_ttft="$_cold_ttft $_ttft" ;;
            WARM) _warm_n=$((_warm_n+1)); [ -n "$_ttft" ] && _warm_ttft="$_warm_ttft $_ttft" ;;
            *)    _unk_n=$((_unk_n+1)) ;;
        esac

        _verdict="$(_classify_opening "$_raw")"
        case "$_verdict" in
            no_tool_call)
                _no_tool=$((_no_tool + 1))
                probe_note "opening ${_i}: no_tool_call            tool=-            tool_fact=no  reply_fact=$( [ "$_replyfact" -gt 0 ] && echo yes || echo no )" ;;
            tool_found_nothing)
                _tool_no_fact=$((_tool_no_fact + 1))
                probe_note "opening ${_i}: tool_found_nothing      tool=${_toolname:-pwg_?}  tool_fact=no  reply_fact=$( [ "$_replyfact" -gt 0 ] && echo yes || echo no )" ;;
            fact_missing_in_reply)
                _reply_no_fact=$((_reply_no_fact + 1))
                probe_note "opening ${_i}: fact_missing_in_reply   tool=${_toolname:-pwg_?}  tool_fact=yes reply_fact=no" ;;
            *)
                _grounded=$((_grounded + 1))
                probe_note "opening ${_i}: grounded                tool=${_toolname:-pwg_?}  tool_fact=yes reply_fact=yes" ;;
        esac
    done
    rm -f "$_raw"
    box_run "rm -f ${_remote_py}" >/dev/null 2>&1

    # COLD AND WARM ARE REPORTED SEPARATELY AND NEVER BLENDED. A mean over both
    # populations is not a number anyone can act on: they differ by an order of
    # magnitude, so the blend just tells you the mix, not the machine.
    _mean() { [ -z "$1" ] && { printf 'NOT-MEASURED'; return; }; printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | awk '{s+=$1;n++} END{ if(n>0) printf "%.3f (n=%d)", s/n, n; else printf "NOT-MEASURED" }'; }
    probe_note "TTFT COLD: $(_mean "$_cold_ttft")   TTFT WARM: $(_mean "$_warm_ttft")   unknown-thermal openings: ${_unk_n} (excluded from BOTH)"
    probe_note "sessions the gateway announced with a session_start frame: ${_sessions_announced} of ${_done} measured openings"
    # THE UNIT IS NOT OPTIONAL. probe_examined() is `printf '...%s %s' "$1" "$2"`
    # and this file runs under `set -u`, so the one-argument call that used to
    # be here died at lib/probe.sh:73 with "$2: unbound variable" and exited 1
    # -- which run_box_walk.sh reads as FAIL. A probe that cannot reach its own
    # verdict must not be able to emit one by falling over.
    probe_examined "$_done" "opening turns completed on ${MODEL_TAG} (of ${OPENINGS} attempted)"
    probe_note "model_tag=${MODEL_TAG} ram_gb=${RAM_GB:-unread} openings_completed=${_done} grounded=${_grounded} no_tool_call=${_no_tool} tool_found_nothing=${_tool_no_fact} fact_missing_in_reply=${_reply_no_fact} client_fault=${_client_fault} client_refused=${_client_refused} silent=${_silent} unreadable=${_unreadable}"

    # ── THE READING ─────────────────────────────────────────────────────────
    case "$(_read_the_battery "$_done" "$_grounded" "$_no_tool" "$_tool_no_fact" "$_reply_no_fact" "$MIN_OPENINGS")" in
        CANNOT-RUN-DENOMINATOR)
            # THE EXCLUDED OPENINGS ARE NAMED BY SHAPE. A denominator that fell
            # short for four different reasons must not report one of them.
            probe_cannot_run "only ${_done} of ${OPENINGS} opening(s) completed, and the reading requires ${MIN_OPENINGS}. The rate under test is about one in ten, so fewer cannot separate 'fixed' from 'got lucky'. A clean run at this denominator is NOT an answer and is not reported as one. Excluded: ${_client_fault} client fault(s)${_first_fault:+ (${_first_fault})}, ${_client_refused} client refusal(s)${_first_refusal:+ (${_first_refusal})}, ${_silent} with no output at all (NOT INSTRUMENTED: \`python3 ${_remote_py} ${_port} ...\` on ${OSTLER_BOX_HOST:-this machine} is the command that would settle it), ${_unreadable} unreadable." ;;
        PASS)
            probe_pass "${_done}/${_done} openings grounded on ${MODEL_TAG} at ${RAM_GB:-unread}GB. Every opening called a pwg_ tool, the tool output carried the seeded fact, and the reply carried it." ;;
        FAIL-COLD-START)
            probe_fail "${_no_tool}/${_done} openings called NO tool on ${MODEL_TAG} at ${RAM_GB:-unread}GB. Every failure is at the opening and none is beyond it, which is the cold-start shape: the handover did not take. This is a DEFECT AGAINST ostler-assistant #404, not a question about the model's capability." ;;
        *)
            probe_fail "${_done} openings on ${MODEL_TAG} at ${RAM_GB:-unread}GB: grounded=${_grounded} no_tool_call=${_no_tool} tool_found_nothing=${_tool_no_fact} fact_missing_in_reply=${_reply_no_fact}. Failures occur BEYOND the no-tool-call shape, which is the capability ceiling nobody has observed before. That is a SPEC DECISION about the minimum supported machine, for Andy, and NOT a daemon fix." ;;
    esac
}

# ── THE NEGATIVE CONTROL ────────────────────────────────────────────────────
#
# NO BOX, NO NETWORK, NO CLOCK. It drives the three decision functions
# run_probe adjudicates with, over fixtures written here, so a mutation to the
# reading breaks the control in the same commit.
#
# THE INVERSION IS DELIBERATE AND IS THE CONTRACT: an arm that BEHAVED means
# this file must exit 1 (probe_fail), because run_box_walk.sh:175-181 awards
# "ok (goes red on known-bad input)" only to rc 1. An arm that MISBEHAVED must
# therefore exit 0 (probe_pass), which the runner reads as BROKEN. Reading that
# the wrong way round is how a probe certifies itself.
self_test() {
    fails=0
    firstbad=""
    _d="$(mktemp -d)" || { probe_examined 0 "self-test arms (no temp dir on this machine)"; probe_pass "SELF-TEST BROKEN: could not create a temp directory, so no arm ran. A control that could not be taken is not a control."; }
    # A self-test that cannot clean up hangs the walk it is meant to protect.
    trap 'rm -rf "$_d"' EXIT

    _n=0
    _arm() { # _arm <label> <got> <want>
        _n=$((_n + 1))
        if [ "$2" = "$3" ]; then
            printf '  arm OK: %s -> %s\n' "$1" "$2"
        else
            printf '  arm BROKEN: %s -> %s, wanted %s\n' "$1" "$2" "$3"
            fails=$((fails + 1))
            [ -n "$firstbad" ] || firstbad="$1"
        fi
    }

    # ── _classify_opening: the four outcomes, plus the one that must not be
    #    mistaken for grounded. A NON-pwg tool is not the customer's own data.
    printf 'FRAME session_start\nFRAME done\n' > "$_d/o_notool"
    printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people EMPTY\nFRAME tool_fact NO\nFRAME reply_fact NO\nFRAME done\n' > "$_d/o_nothing"
    printf 'FRAME tool_call pwg_people\nFRAME tool_fact YES\nFRAME reply_fact NO\nFRAME done\n' > "$_d/o_ignored"
    printf 'FRAME tool_call pwg_people\nFRAME tool_fact YES\nFRAME reply_fact YES\nFRAME done\n' > "$_d/o_grounded"
    printf 'FRAME tool_call web_search\nFRAME tool_fact YES\nFRAME reply_fact YES\nFRAME done\n' > "$_d/o_offgraph"
    _arm "classify_opening/no tool at all"        "$(_classify_opening "$_d/o_notool")"   no_tool_call
    _arm "classify_opening/pwg_ tool, no fact"    "$(_classify_opening "$_d/o_nothing")"  tool_found_nothing
    _arm "classify_opening/fact held, not used"   "$(_classify_opening "$_d/o_ignored")"  fact_missing_in_reply
    _arm "classify_opening/grounded"              "$(_classify_opening "$_d/o_grounded")" grounded
    _arm "classify_opening/non-pwg tool is not grounded" "$(_classify_opening "$_d/o_offgraph")" no_tool_call

    # ── _classify_client_run. ARM 2 IS THE ORIGINAL CRASHING INPUT: the exact
    #    traceback the old bare `python3 -` invocation produced on every
    #    opening. It must read client_fault. If it ever reads silent again,
    #    this probe is back to calling its own bug "transport".
    printf 'FRAME session_start\nFRAME done\n' > "$_d/c_frames"
    printf 'Traceback (most recent call last):\n  File "<stdin>", line 51, in <module>\nIndexError: list index out of range\n' > "$_d/c_fault"
    printf 'PROBE_FATAL no_connect [Errno 61] Connection refused\n' > "$_d/c_refused"
    : > "$_d/c_silent"
    printf 'ssh: connect to host box port 22: Operation timed out\n' > "$_d/c_noise"
    _arm "classify_client_run/frames"                       "$(_classify_client_run "$_d/c_frames")"  frames
    _arm "classify_client_run/THE ORIGINAL IndexError"      "$(_classify_client_run "$_d/c_fault")"   client_fault
    _arm "classify_client_run/client named its refusal"     "$(_classify_client_run "$_d/c_refused")" client_refused
    _arm "classify_client_run/nothing at all"               "$(_classify_client_run "$_d/c_silent")"  silent
    _arm "classify_client_run/unpredicted output"           "$(_classify_client_run "$_d/c_noise")"   unreadable

    # ── _read_the_battery. THE ZERO-DENOMINATOR ARM IS FIRST: 0 grounded of 0
    #    done satisfies "all grounded" and must still refuse.
    _arm "read_the_battery/0 of 0 is not a pass" "$(_read_the_battery 0 0 0 0 0 10)"  CANNOT-RUN-DENOMINATOR
    _arm "read_the_battery/a clean 9 is not an answer" "$(_read_the_battery 9 9 0 0 0 10)" CANNOT-RUN-DENOMINATOR
    _arm "read_the_battery/10 of 10 grounded"    "$(_read_the_battery 10 10 0 0 0 10)" PASS
    _arm "read_the_battery/one opening, no tool" "$(_read_the_battery 10 9 1 0 0 10)"  FAIL-COLD-START
    _arm "read_the_battery/a failure beyond the opening" "$(_read_the_battery 10 8 1 1 0 10)" FAIL-CEILING
    _arm "read_the_battery/fact held and not used" "$(_read_the_battery 10 9 0 0 1 10)" FAIL-CEILING

    # The memory reader. The first arm is the shape every walk before v1.0.102
    # candidate 5 actually got: a 404 from a route the daemon does not serve.
    _arm "read_memory_answer/the route refused (404)" "$(_read_memory_answer 'UNREADABLE http 404')" UNREADABLE
    _arm "read_memory_answer/nothing at all"          "$(_read_memory_answer '')"                    UNREADABLE
    _arm "read_memory_answer/count not a number"      "$(_read_memory_answer 'READ x y')"            UNREADABLE
    _arm "read_memory_answer/read, no mention"        "$(_read_memory_answer 'READ 50 0')"           ABSENT
    _arm "read_memory_answer/read, mentioned twice"   "$(_read_memory_answer "$(printf 'READ 50 2\nKEY a\nKEY b')")" PRESENT

    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} of ${_n} arms returned the wrong outcome (first: ${firstbad}). This probe cannot be trusted to tell PASS from FAIL from CANNOT-RUN, so its verdicts mean nothing."
    fi
    probe_examined "$_n" "self-test arms, counted as they ran (5 opening classifications, 5 client-output shapes including the IndexError that used to be reported as transport, 6 readings including a zero denominator, 5 memory-reader answers including the 404 every earlier walk got)"
    probe_fail "negative control behaved on all ${_n} arms: a turn with no pwg_ tool FAILs, a non-pwg tool does not count as grounded, the client's own traceback reads client_fault and NOT transport, an empty client output is the only shape called silent, and 0 of 0 refuses instead of passing"
}

probe_main "$@"
