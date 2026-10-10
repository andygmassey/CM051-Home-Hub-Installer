#!/usr/bin/env python3
"""reconnect_nudge_reaches_the_owner: driver and judge (wow gate item 3, v1.0.108).

  box           run ON the walk box: drive the INSTALLED weekly reconnect nudge
                sender against a SYNTHETIC chat.db, a loopback stub Hub and a
                loopback /announce shim, twice, and print the capture as JSON.
                Nobody is messaged; the real chat.db and the real nudge state
                are never touched.
  judge FILE    grade a capture. Exit 0 PASS, 1 FAIL, 78 CANNOT-RUN.
  --self-test   prove the judge goes red on known-bad captures.

What is measured, in order:
  1. the sender, its LaunchAgent plist and the installed assistant's
     `reconnect-nudge` command are all present (the three halves that must ship
     together, or the nudge is built and connected to nothing);
  2. the box is on Ostler Pro (else CANNOT-RUN: nothing is measurable);
  3. the real Hub serves the People-list screen the composer fails closed on;
  4. run 1 delivers exactly one message of kind reconnect_nudge on a brief
     channel, naming the synthetic drifted contact, with a draft, saying
     nothing was sent;
  5. run 2, straight after, delivers nothing (the delivery was recorded, so the
     weekly budget and the repeat guard hold) and the recorded key exists.

CANNOT-RUN is never a PASS and a FAIL is never softened into one.
"""
import json
import os
import subprocess
import sys

SYNTH_NAME = "Jane Doe"
SYNTH_HANDLE = "+447700900001"
APPLE_EPOCH = 978307200


def judge(f):
    """Return (lines, rc). Every line starts '  ok ', '  FAIL ' or '  CANNOT '."""
    out, bad, cannot = [], 0, 0

    def ok(m):
        out.append("  ok " + m)

    def fail(m):
        nonlocal bad
        bad += 1
        out.append("  FAIL " + m)

    def cant(m):
        nonlocal cannot
        cannot += 1
        out.append("  CANNOT " + m)

    if not f.get("sender_installed"):
        fail("the weekly nudge sender (~/.ostler/bin/ostler-reconnect-nudge-sender) is not installed")
    else:
        ok("the nudge sender is installed")
    if not f.get("plist_present"):
        fail("the com.ostler.reconnect-nudge-sender LaunchAgent plist is not installed")
    else:
        ok("the nudge LaunchAgent plist is installed")
    if f.get("composer_has_command") is not True:
        fail("the installed assistant has no `reconnect-nudge` command, so the sender has nothing to deliver "
             "(the daemon pin and the sender must ship in the same cut)")
    else:
        ok("the installed assistant has the reconnect-nudge command")
    if bad:
        return out, 1

    pro = f.get("pro")
    if pro != "active":
        cant("this box is not on Ostler Pro (%s), so the nudge is correctly paused and nothing can be measured" % pro)
        return out, 78
    ok("the box is on Ostler Pro")

    if f.get("hub_people_screen") is False:
        fail("the real Hub's People-list screen (/api/v1/people/stale) is unreadable or degraded; the composer fails "
             "closed on it, so no real nudge could ever be composed")
    elif f.get("hub_people_screen") is None:
        cant("could not read the real Hub's People-list screen (no service token)")
    else:
        ok("the real Hub serves the People-list screen")

    r1 = f.get("run1") or {}
    posts = r1.get("posts") or []
    if r1.get("rc") != 0:
        fail("run 1 of the installed sender exited %s, not 0 (stderr tail: %s)" % (r1.get("rc"), (r1.get("stderr") or "")[-160:]))
    elif len(posts) != 1:
        fail("run 1 posted %d message(s) to /announce, expected exactly 1" % len(posts))
    else:
        p = posts[0]
        msg = p.get("message") or ""
        if p.get("kind") != "reconnect_nudge":
            fail("the announce kind is %r, expected 'reconnect_nudge'" % p.get("kind"))
        else:
            ok("run 1 posted one message of kind reconnect_nudge")
        if not (p.get("channel") or "").strip():
            fail("the announce carries no brief channel")
        else:
            ok("it went out on the owner's own brief channel (%s)" % p.get("channel"))
        if SYNTH_NAME not in msg:
            fail("the nudge does not name the drifted contact")
        else:
            ok("it names the drifted contact")
        if "Draft:" not in msg:
            fail("the nudge carries no draft hello")
        else:
            ok("it carries a draft hello")
        if "Nothing has been sent" not in msg:
            fail("the nudge does not say nothing was sent to that person")
        else:
            ok("it says nothing was sent")
        if "—" in msg or "–" in msg:
            fail("the nudge text contains a dash character")

    r2 = f.get("run2") or {}
    if r2.get("rc") != 0:
        fail("run 2 exited %s, not 0" % r2.get("rc"))
    elif (r2.get("posts") or []):
        fail("run 2 posted %d message(s) straight after run 1: the delivery was not recorded, so the weekly "
             "budget and the repeat guard do not hold" % len(r2.get("posts")))
    else:
        ok("run 2 delivered nothing (the first delivery was recorded)")
    if not f.get("state_keys"):
        fail("no delivered person was recorded in the nudge state file")
    else:
        ok("the delivered person was recorded (%d key(s))" % len(f["state_keys"]))

    if bad:
        return out, 1
    if cannot:
        return out, 78
    return out, 0


GOOD = {
    "sender_installed": True, "plist_present": True, "composer_has_command": True, "pro": "active",
    "hub_people_screen": True,
    "run1": {"rc": 0, "stderr": "", "posts": [{
        "kind": "reconnect_nudge", "channel": "imessage",
        "message": "Worth saying hello this week\nJane Doe: quiet for 5 months.\nDraft: hi Jane\nNothing has been sent."}]},
    "run2": {"rc": 0, "stderr": "", "posts": []},
    "state_keys": ["k1"],
}


def _mut(**kw):
    import copy
    f = copy.deepcopy(GOOD)
    for k, v in kw.items():
        if "." in k:
            a, b = k.split(".", 1)
            f[a][b] = v
        else:
            f[k] = v
    return f


def self_test():
    rc, lines = 0, []
    _, g = judge(GOOD)
    if g != 0:
        lines.append("FAIL the good capture did not PASS"); rc = 1
    bads = {
        "sender missing": _mut(sender_installed=False),
        "plist missing": _mut(plist_present=False),
        "daemon without the command": _mut(composer_has_command=False),
        "no post": _mut(**{"run1.posts": []}),
        "wrong kind": _mut(**{"run1.posts": [dict(GOOD["run1"]["posts"][0], kind="meeting_brief")]}),
        "contact not named": _mut(**{"run1.posts": [dict(GOOD["run1"]["posts"][0], message="Draft: hi\nNothing has been sent.")]}),
        "no draft": _mut(**{"run1.posts": [dict(GOOD["run1"]["posts"][0], message="Jane Doe is quiet.\nNothing has been sent.")]}),
        "does not say nothing was sent": _mut(**{"run1.posts": [dict(GOOD["run1"]["posts"][0], message="Jane Doe\nDraft: hi")]}),
        "dash in the text": _mut(**{"run1.posts": [dict(GOOD["run1"]["posts"][0], message=GOOD["run1"]["posts"][0]["message"] + " — x")]}),
        "run 1 failed": _mut(**{"run1.rc": 75}),
        "run 2 reposted": _mut(**{"run2.posts": GOOD["run1"]["posts"]}),
        "nothing recorded": _mut(state_keys=[]),
        "hub screen degraded": _mut(hub_people_screen=False),
    }
    for name, cap in bads.items():
        _, r = judge(cap)
        if r != 1:
            lines.append("FAIL known-bad capture '%s' was not FAIL (rc=%s)" % (name, r)); rc = 1
    _, r = judge(_mut(pro="paused"))
    if r != 78:
        lines.append("FAIL a box off Pro was not CANNOT-RUN"); rc = 1
    _, r = judge(_mut(hub_people_screen=None))
    if r != 78:
        lines.append("FAIL an unreadable Hub screen was not CANNOT-RUN"); rc = 1
    for l in lines:
        print(l)
    return rc


# --------------------------------------------------------------------------- box
def box():
    import http.server
    import socketserver
    import sqlite3
    import tempfile
    import threading
    import time
    import urllib.request

    home = os.path.expanduser("~")
    ostler = os.path.join(home, ".ostler")
    sender = os.path.join(ostler, "bin", "ostler-reconnect-nudge-sender")
    plist = os.path.join(home, "Library", "LaunchAgents", "com.ostler.reconnect-nudge-sender.plist")
    composer = os.path.join(ostler, "OstlerAssistant.app", "Contents", "MacOS", "ostler-assistant")
    facts = {
        "sender_installed": os.access(sender, os.X_OK),
        "plist_present": os.path.exists(plist),
        "composer_has_command": None,
        "pro": "unknown",
        "hub_people_screen": None,
    }
    if os.access(composer, os.X_OK):
        try:
            r = subprocess.run([composer, "reconnect-nudge", "--help"], capture_output=True, text=True, timeout=30)
            facts["composer_has_command"] = (r.returncode == 0)
        except Exception:
            facts["composer_has_command"] = False
    else:
        facts["composer_has_command"] = False

    gate = os.path.join(ostler, "services", "ical-server", "subscription_gate.py")
    py = os.path.join(ostler, ".venv", "bin", "python3")
    if not os.access(py, os.X_OK):
        py = "python3"
    if os.path.exists(gate):
        try:
            r = subprocess.run([py, gate, "--check"], capture_output=True, text=True, timeout=30)
            facts["pro"] = "paused" if r.returncode == 3 else "active"
        except Exception:
            facts["pro"] = "unknown"
    else:
        facts["pro"] = "unknown"

    token = ""
    try:
        token = open(os.path.join(ostler, "secrets", "service_token")).read().strip()
    except Exception:
        pass
    if token:
        try:
            req = urllib.request.Request("http://127.0.0.1:8090/api/v1/people/stale",
                                         headers={"Authorization": "Bearer " + token})
            body = json.load(urllib.request.urlopen(req, timeout=15))
            facts["hub_people_screen"] = (not body.get("degraded")) and isinstance(body.get("contacts"), list)
        except Exception:
            facts["hub_people_screen"] = False

    if not (facts["sender_installed"] and facts["plist_present"] and facts["composer_has_command"] and facts["pro"] == "active"):
        print(json.dumps(facts))
        return 0

    work = tempfile.mkdtemp(prefix="ostler-probe-rn-")
    # A synthetic chat.db: a two-way fortnightly rhythm that ended ~150 days ago.
    db = os.path.join(work, "chat.db")
    c = sqlite3.connect(db)
    c.executescript(
        "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);"
        "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER);"
        "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);"
        "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER,"
        " date INTEGER, cache_has_attachments INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);"
        "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);"
        "INSERT INTO handle VALUES (1, '%s'); INSERT INTO chat VALUES (1, 45); INSERT INTO chat_handle_join VALUES (1, 1);"
        % SYNTH_HANDLE)
    end = time.time() - 150 * 86400
    t, n, mid = end - 180 * 86400, 0, 0
    while t < end:
        for i, (txt, me) in enumerate((("how was your week", n % 2), ("pretty good, you?", (n + 1) % 2))):
            mid += 1
            ns = int((t + i * 240 - APPLE_EPOCH) * 1e9)
            c.execute("INSERT INTO message (ROWID, text, is_from_me, date) VALUES (?,?,?,?)", (mid, txt, me, ns))
            c.execute("INSERT INTO chat_message_join VALUES (1, ?)", (mid,))
        t += 14 * 86400
        n += 1
    c.commit()
    c.close()

    posts = []

    class Announce(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            ln = int(self.headers.get("Content-Length") or 0)
            try:
                posts.append(json.loads(self.rfile.read(ln)))
            except Exception:
                posts.append({"kind": "unparseable"})
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *a):
            pass

    class StubHub(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/api/v1/people/stale"):
                body = {"contacts": [{"name": SYNTH_NAME}]}
            elif self.path.startswith("/api/v1/people/resolve"):
                body = {"resolved": {SYNTH_HANDLE: {"name": SYNTH_NAME, "slug": "jane-doe"}}, "count": 1}
            else:
                body = {}
            raw = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *a):
            pass

    servers = []
    for handler in (Announce, StubHub):
        s = socketserver.TCPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=s.serve_forever, daemon=True).start()
        servers.append(s)
    announce_url = "http://127.0.0.1:%d" % servers[0].server_address[1]
    hub_url = "http://127.0.0.1:%d" % servers[1].server_address[1]
    state = os.path.join(work, "reconnect_nudges.json")
    env = dict(os.environ,
               OSTLER_ASSISTANT_URL=announce_url, OSTLER_ICAL_BASE_URL=hub_url,
               OSTLER_RECONNECT_CHAT_DB=db, OSTLER_RECONNECT_NUDGE_STATE=state,
               OSTLER_BRIEF_QUIET_START="25", OSTLER_BRIEF_QUIET_END="0")

    def run():
        before = len(posts)
        r = subprocess.run([sender], env=env, capture_output=True, text=True, timeout=240)
        time.sleep(0.3)
        return {"rc": r.returncode, "stderr": (r.stderr or "")[-400:], "posts": posts[before:]}

    facts["run1"] = run()
    facts["run2"] = run()
    keys = []
    try:
        keys = [r["key"] for r in json.load(open(state)).get("sent", [])]
    except Exception:
        pass
    facts["state_keys"] = keys
    for s in servers:
        s.shutdown()
    subprocess.run(["rm", "-rf", work])
    print(json.dumps(facts))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 2 and argv[1] == "box":
        return box()
    if len(argv) >= 3 and argv[1] == "judge":
        with open(argv[2]) as fh:
            lines, rc = judge(json.load(fh))
        print("\n".join(lines))
        return rc
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
