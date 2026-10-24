#!/usr/bin/env python3
"""A STAND-IN for `ostler-assistant daemon`, for tests/test_send_safety_probes.sh.

It speaks the same surfaces the probe drives: it reads $ZEROCLAW_CONFIG_DIR/config.toml,
polls $HOME/Library/Messages/chat.db, asks the Ollama-shaped model at the configured
base_url, sends through `osascript` found on PATH, serves /health and /api/cron on
the gateway port, and logs in the daemon's wording. OSTLER_STUB_MODE picks the build:

  v117             pre-#626: every tool call runs, nothing is gated or logged
  intended         #626 + #627 as merged
  stranger_prompted   intended, but a stranger is shown an approval prompt
  tainted_sends       intended, but a tainted owner turn is not held
  no_prompt_body      intended, but the owner prompt omits recipient and body
  release_twice       intended, but a yes does not consume the proposal
  prompt_via_model    intended, but the Held result repeats the request to the model
  cron_sends          intended, but a scheduled run is treated as the owner's
  cron_announce       intended, but the job reads back delivery mode announce

THIS IS NOT THE DAEMON. That the real binary logs these lines and honours these
rules is the probe, run on a walk box; this stub only proves the probe can tell the
two shapes apart.
"""
import http.server
import json
import os
import re
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request

MODE = os.environ.get("OSTLER_STUB_MODE", "intended")
HOME = os.environ["HOME"]
CFG = os.environ["ZEROCLAW_CONFIG_DIR"]
cfg = open(os.path.join(CFG, "config.toml")).read()
MODEL = re.search(r'base_url = "(http://[^"]+)"', cfg).group(1)
GW = int(re.search(r"(?m)^port = (\d+)", cfg).group(1))
ALLOWED = re.search(r"allowed_contacts = \[(.*?)\]", cfg).group(1)
ALLOWED = re.findall(r'"([^"]+)"', ALLOWED)
EXACT = [a for a in ALLOWED if a != "*"]
CRON = re.search(r'prompt = "([^"]+)"', cfg)
PENDING = {}
TURN = [0]
LOCK = threading.Lock()


def log(level, msg):
    sys.stderr.write("2026-10-23T00:00:00Z  %s zeroclaw: %s\n" % (level, msg))
    sys.stderr.flush()


def osa(to, body):
    esc = body.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    script = 'tell application "Messages"\n set targetBuddy to participant "%s" of targetService\n send "%s" to targetBuddy\nend tell' % (to, esc)
    subprocess.run(["osascript", "-e", script], capture_output=True)


def chat(messages, tools):
    req = urllib.request.Request(MODEL + "/api/chat", data=json.dumps({
        "model": "probe-model", "stream": False, "messages": messages,
        "tools": [{"type": "function", "function": {"name": t}} for t in tools]}).encode(), method="POST")
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=30) as r:
        return json.loads(r.read().decode())["message"]


def run_poll(args):
    osa(args["recipient"], args["question"] + "\n1. " + "\n2. ".join(args["options"]))
    return "Poll sent."


def describe(args):
    return "Action: poll\nTo: %s\nquestion: %s" % (args["recipient"], args["question"])


def gate(args, kind, owner_text, owner):
    """kind: owner_clean | owner_tainted | not_owner | cron. -> (run?, result text)"""
    if MODE == "v117":
        return True, None
    if kind == "cron" and MODE == "cron_sends":
        kind = "owner_clean"
    if kind in ("not_owner", "cron"):
        reason = "no_turn_provenance" if kind == "cron" else "not_owner_turn"
        log("WARN", 'turn_provenance: outbound send refused tool="poll" reason="%s"' % reason)
        if kind == "not_owner" and MODE == "stranger_prompted":
            osa(owner[1], "I need your OK before I do this. Nothing has been sent.\n\n" + describe(args))
        return False, "Denied: `poll` would send something to another person, and only the owner's own chat message can ask for that. Do not retry."
    if kind == "owner_tainted" and MODE == "tainted_sends":
        return True, None
    asks = kind == "owner_tainted" or args["recipient"] not in EXACT
    if not asks:
        return True, None
    key = json.dumps(args, sort_keys=True)
    with LOCK:
        held = PENDING.get(key)
        if held is not None and held != TURN[0] and re.fullmatch(r"\s*yes[.!]?\s*", owner_text, re.I):
            if MODE != "release_twice":
                PENDING.pop(key, None)
            log("INFO", 'action_confirm: owner confirmed; releasing the call tool="poll"')
            return True, None
        PENDING[key] = TURN[0]
    log("WARN", 'action_confirm: owner confirmation required tool="poll" what="send"')
    body = describe(args)
    if MODE == "no_prompt_body":
        body = "Action: poll"
    osa(owner[1], "I need your OK before I do this. Nothing has been sent or changed.\n\n%s\n\nReply yes to go ahead. Anything else cancels it." % body)
    extra = (" " + describe(args)) if MODE == "prompt_via_model" else ""
    return False, "Held: `poll` needs the owner's explicit yes. The SYSTEM has already shown the owner the exact request.%s" % extra


def agent(user_text, sender, kind, tools):
    TURN[0] += 1
    msgs = [{"role": "system", "content": "stub"}, {"role": "user", "content": user_text}]
    tainted = False
    for _ in range(4):
        m = chat(msgs, tools)
        calls = m.get("tool_calls") or []
        if not calls:
            return m.get("content") or ""
        msgs.append(m)
        for c in calls:
            name, args = c["function"]["name"], c["function"]["arguments"]
            if name == "memory_recall":
                tainted = True
                msgs.append({"role": "tool", "content": "nothing found"})
            elif name == "poll":
                k = "owner_tainted" if (kind == "owner_clean" and tainted) else kind
                run, res = gate(args, k, user_text, ("owner", sender))
                msgs.append({"role": "tool", "content": run_poll(args) if run else res})
    return ""


def poll_loop():
    db = os.path.join(HOME, "Library", "Messages", "chat.db")
    c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    last = c.execute("SELECT MAX(ROWID) FROM message WHERE is_from_me = 0").fetchone()[0] or 0
    while True:
        time.sleep(1)
        rows = c.execute("SELECT m.ROWID, h.id, m.text FROM message m JOIN handle h ON m.handle_id = h.ROWID "
                         "WHERE m.ROWID > ? AND m.is_from_me = 0 ORDER BY m.ROWID", (last,)).fetchall()
        for rowid, sender, text in rows:
            last = max(last, rowid)
            if "*" not in ALLOWED and sender not in ALLOWED:
                continue
            kind = "owner_clean" if sender in EXACT else "not_owner"
            reply = agent(text, sender, kind, ["poll", "memory_recall"])
            if reply:
                osa(sender, reply)


def cron_loop():
    if not CRON:
        return
    time.sleep(4)
    agent(CRON.group(1), "", "cron", ["poll"])


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/api/cron":
            mode = "announce" if MODE == "cron_announce" else "none"
            b = json.dumps({"jobs": [{"id": "sendsafety-probe", "name": "sendsafety-probe", "delivery": {"mode": mode}}]}).encode()
        else:
            b = b"{}"
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


if __name__ == "__main__":
    if sys.argv[1:] != ["daemon"]:
        sys.exit(2)
    threading.Thread(target=poll_loop, daemon=True).start()
    threading.Thread(target=cron_loop, daemon=True).start()
    http.server.ThreadingHTTPServer(("127.0.0.1", GW), H).serve_forever()
