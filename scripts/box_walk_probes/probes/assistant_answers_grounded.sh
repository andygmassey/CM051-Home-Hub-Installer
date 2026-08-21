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

CHAT_TIMEOUT="${OSTLER_PROBE_CHAT_TIMEOUT:-240}"
GATEWAY="${OSTLER_PROBE_GATEWAY:-http://127.0.0.1:8000}"
# TILDE, NOT $HOME. Python's os.path.expanduser expands `~` and leaves `$VAR`
# untouched -- `expanduser("$HOME/x")` returns "$HOME/x" verbatim. The first
# version of this line used $HOME, the client could not find the token, and
# every turn came back PROBE_FATAL no_token. Measured, not reasoned about.
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}"

# ── The WebSocket client, embedded ──────────────────────────────────────────
# Dependency-free: raw socket + the RFC 6455 handshake and framing. It is
# embedded rather than shipped alongside so the probe cannot half-exist on a
# box, and base64'd so it survives being passed as a single shell command to
# either `sh -c` locally or ssh remotely.
_ws_client_py() {
    cat <<'PYEOF'
import base64, json, os, socket, struct, sys, time
host, port = "127.0.0.1", int(sys.argv[1])
token_path, question, deadline_s = sys.argv[2], sys.argv[3], float(sys.argv[4])
try:
    token = open(os.path.expanduser(token_path)).read().strip()
except Exception as e:
    print("PROBE_FATAL no_token %s" % e); sys.exit(3)
deadline = time.time() + deadline_s
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
# operator's personal data and this transcript lands in support bundles.
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
    elif t in ("done", "session_start", "error", "chunk_reset"):
        print("FRAME %s" % t)
        if t in ("done", "error"): break
PYEOF
}

# ── THE ADJUDICATOR ─────────────────────────────────────────────────────────
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

adjudicate_turn() {
    _t="$1"
    grep -q '^PROBE_FATAL' "$_t" && { echo "fatal"; return; }
    grep -q '^FRAME done$' "$_t" || { echo "incomplete"; return; }
    grep -q '^FRAME tool_call ' "$_t" || { echo "no_tool_call"; return; }
    # A tool ran, but was it one that reads the customer's own graph?
    grep -qE "$_GRAPH_TOOL_RE" "$_t" || { echo "memory_only"; return; }
    grep -q '^FRAME tool_result pwg_.* ERR$' "$_t" && { echo "tool_error"; return; }
    # A graph tool answered without erroring. NOTE: a truthful "no such person"
    # also lands here -- see tool_found_nothing in the client, which marks a
    # result whose body announces an empty set. Success-shaped emptiness is the
    # #810 shape and must not read as retrieval.
    grep -q '^FRAME tool_result pwg_.* EMPTY$' "$_t" && { echo "tool_found_nothing"; return; }
    echo "grounded"
}

# The battery. Each SHOULD reach the graph on a populated box. Deliberately
# phrased the way a new customer phrases them, not the way the tools are shaped
# -- that mismatch IS #854, and a probe written to suit the tools would hide it.
_questions() {
    cat <<'QEOF'
What do you know about me?
What are my interests?
Who have I been in contact with recently?
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
    _declared="$(grep -c . "$_qfile")"

    _asked=0; _failed=0; _detail=""
    _tmp="$(mktemp)"
    exec 3< "$_qfile"
    while IFS= read -r _q <&3; do
        [ -n "$_q" ] || continue
        _asked=$(( _asked + 1 ))
        box_run "python3 ${_remote_py} ${_port} '${TOKEN_PATH}' \"\$(printf %s '${_q}')\" ${CHAT_TIMEOUT}" > "$_tmp" 2>&1
        _v="$(adjudicate_turn "$_tmp")"
        if [ "$_v" = "grounded" ]; then
            :
        else
            _failed=$(( _failed + 1 ))
            _detail="${_detail} [${_v}]"
            # Surface WHY a fatal was fatal, or the next person debugs blind.
            if [ "$_v" = "fatal" ]; then
                _detail="${_detail}$(sed -n 's/^PROBE_FATAL /(/p' "$_tmp" | head -1 | sed 's/$/)/')"
            fi
        fi
        probe_note "asked #${_asked}: ${_v}"
    done
    exec 3<&-
    rm -f "$_tmp" "$_qfile"
    box_run "rm -f ${_remote_py}" >/dev/null 2>&1

    # The denominator, always. "0 of 0 grounded" must never read as success.
    probe_examined "$_asked" "questions asked over /ws/chat (battery declares ${_declared})"

    [ "$_asked" -eq 0 ] && probe_cannot_run "no questions were asked; the battery is empty"

    # ANTI-VACUITY: asked must equal declared. A loop that quietly stops early
    # reduces coverage while every remaining verdict still reads green.
    [ "$_asked" -ne "$_declared" ] && probe_fail \
        "asked ${_asked} of ${_declared} declared questions -- the battery was truncated mid-run, so a pass here would understate coverage"

    [ "$_failed" -gt 0 ] && probe_fail \
        "${_failed} of ${_asked} questions did not reach the customer's own data:${_detail} (verdicts are frame-stream states, not answer text)"

    probe_pass "all ${_asked} questions produced a tool-backed answer over /ws/chat at ${GATEWAY}"
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

    _ok=1
    [ "$(adjudicate_turn "$_d/good")"       = "grounded" ]           || _ok=0
    [ "$(adjudicate_turn "$_d/toolerr")"    = "tool_error" ]         || _ok=0
    [ "$(adjudicate_turn "$_d/notool")"     = "no_tool_call" ]       || _ok=0
    [ "$(adjudicate_turn "$_d/incomplete")" = "incomplete" ]         || _ok=0
    [ "$(adjudicate_turn "$_d/memonly")"    = "memory_only" ]        || _ok=0
    [ "$(adjudicate_turn "$_d/empty")"      = "tool_found_nothing" ] || _ok=0
    rm -rf "$_d"

    probe_examined 6 "planted transcript fixtures"
    if [ "$_ok" -eq 1 ]; then
        # The control FIRED: five known-bad shapes each produced their own
        # non-grounded verdict, and the healthy one did not.
        probe_fail "control fired: tool_error, no_tool_call, incomplete, memory_only and tool_found_nothing are each detected, and the healthy fixture is not misread as broken"
    fi
    # Reaching here means the adjudicator could NOT tell a broken turn from a
    # healthy one. Passing is how this suite spells BROKEN.
    probe_pass "CONTROL DID NOT FIRE -- adjudicate_turn failed to classify the planted fixtures, so a green from this probe would prove nothing"
}

probe_main "$@"
