#!/usr/bin/env python3
"""The pre-meeting brief the customer is actually SENT, graded on its text.
(ostler-ai/ostler-assistant#471, definition of done item 4)

WHAT THIS GATES, AND WHAT IT DOES NOT
=====================================
A probe that asserted "a brief was sent" would have passed on the old sender,
which sent a confident brief that turned "no meetings logged" into "this is your
first face-to-face meeting". It would also have passed on a sender that crashed:
the pre-change sender died reading its own stdin on every tick (see
install.sh), so the thing worth measuring is the TEXT that leaves the box.

This probe runs the sender that is installed on the box, unmodified, against the
box's own Hub and the box's own assistant binary (the composer). Only the two
edges are replaced so nothing real is messaged:

  * the calendar edge: a walk box has no meeting in the next 20 minutes, so a
    loopback shim answers GET /api/v1/meeting/upcoming with three meetings whose
    attendees are three FICTIONAL people seeded into the box's graph. The
    attendee records carry the person's name, wiki_url and outstanding_todos in
    the shape the Hub returns (vendor/cm041/meeting_syncer/brief.py). Every
    other request is forwarded to the REAL Hub, so the composer reads the real
    people/context and person timeline handlers over the real graph.
  * the delivery edge: the same shim records POST /announce instead of
    WhatsApp-ing anyone.

THREE CONTACTS, ONE BEHAVIOUR EACH (graded on the sent text)
  Alexandra Patel   rich     names the LAST TOPIC (a logged meeting summary) and an
                          OPEN PROMISE (a todo the owner owes). The Hub supplies
                          no mutual-contact field, so no "people in common" line
                          may appear: a claim the Hub cannot back is a defect.
  Philip Coe  none     a contact with NO logged meetings. The text must say
                          "no meetings logged" and must never say "first
                          meeting" or any inference from absence.
  Catherine Stewart  thin     a name and an address only. The text must be short and
                          say there is little on file, with no padding.
  ALL                     no banned phrase, no em or en dash, no generic advice,
                          none of the old shape's "With:/Wiki:/Open:" lines,
                          every message within the word budget, exactly one
                          announce per meeting.

CANNOT-RUN, NEVER PASS: the sender is not installed (it is feature-flagged OFF
by default, INSTALL_MEETING_BRIEF_LAUNCHAGENT), the composer binary lacks the
`meeting-brief` command, the seed did not land and read back, or the Hub is
unreachable. A seed that did not work is a harness failure and must not read as
a product defect, so the seed is PROVEN READABLE through the Hub before the
sender runs.

Modes:
  --self-test       run the judge on a good fixture and on mutants (exit 0 means
                    every mutant went red and the control went green)
  judge FILE        grade a captured JSON file (exit 0 pass, 1 fail, 78 cannot)
  box               run on the box and print the captured JSON on stdout
"""
import json
import os
import re
import sys

BANNED = (
    "first meeting", "first face", "first in-person", "first time you", "never met",
    "haven't met", "have not met", "not met before", "new contact", "warm welcome",
    "good impression", "be sure to", "make sure to", "would be appropriate",
    "complete stranger", "people in common", "you also know", "mutual",
    "no previous interaction",
)
OLD_SHAPE = re.compile(r"^(With|Wiki|Last chat|Open|Location):", re.M)
MAX_WORDS = 150
EX_CANNOT_RUN = 78

# The three seeded meetings, by uid. Names mirror lib/meeting_brief_seed.py.
EXPECT = {
    "walk-fixture-brief-0": "rich",
    "walk-fixture-brief-1": "none",
    "walk-fixture-brief-2": "thin",
}


def words(s):
    return len(s.split())


def judge(facts):
    """Return (results, cannot). results = [(ok, label)]."""
    res = []

    def check(label, ok):
        res.append((bool(ok), label))

    if facts.get("cannot"):
        return res, facts["cannot"]
    ann = facts.get("announces")
    if not isinstance(ann, list):
        return res, "the capture holds no announce list; nothing was measured"
    by_uid = {a.get("meeting_uid"): a for a in ann}
    check("exactly three announces, one per seeded meeting (a sender that sent nothing is a FAIL)",
          len(ann) == 3 and set(by_uid) == set(EXPECT))
    check("every announce is kind=meeting_brief",
          bool(ann) and all(a.get("kind") == "meeting_brief" for a in ann))
    for a in ann:
        m = a.get("message") or ""
        low = m.lower()
        who = EXPECT.get(a.get("meeting_uid"), "unknown")
        hits = [b for b in BANNED if b in low]
        check(f"[{who}] no banned claim or generic advice in the SENT text {hits}", not hits)
        check(f"[{who}] no em or en dash", "\u2014" not in m and "\u2013" not in m)
        check(f"[{who}] none of the old shape's With:/Wiki:/Open: lines", not OLD_SHAPE.search(m))
        check(f"[{who}] within {MAX_WORDS} words ({words(m)})", 0 < words(m) <= MAX_WORDS)
    rich = (by_uid.get("walk-fixture-brief-0") or {}).get("message", "")
    none = (by_uid.get("walk-fixture-brief-1") or {}).get("message", "")
    thin = (by_uid.get("walk-fixture-brief-2") or {}).get("message", "")
    check("[rich] names the last topic: 'Lisbon workshop budget review'",
          "lisbon workshop budget review" in rich.lower())
    check("[rich] names the open promise the owner owes: 'Share the workshop deck with Alexandra'",
          "share the workshop deck with alexandra" in rich.lower() and "you owe" in rich.lower())
    check("[rich] says who she is: Acme Corp", "acme corp" in rich.lower())
    check("[none] says 'no meetings logged', the truth, and not an inference",
          "no meetings logged" in none.lower())
    check("[none] says who they are: Globex Corp", "globex corp" in none.lower())
    check("[thin] says there is little on file", "little else on file" in thin.lower()
          or "little on file" in thin.lower())
    # The thin contact's own part of the message is the text after the header.
    thin_body = "\n".join(thin.splitlines()[1:]) if thin else ""
    check(f"[thin] the contact's part is short ({words(thin_body)} words)", 0 < words(thin_body) < 40)
    return res, None


def report(facts):
    res, cannot = judge(facts)
    if cannot:
        print(f"  CANNOT {cannot}")
        return EX_CANNOT_RUN
    bad = 0
    for ok, label in res:
        print(("  ok     " if ok else "  FAIL   ") + label)
        bad += 0 if ok else 1
    return 1 if bad else 0


# --------------------------------------------------------------------------
# self-test: a good capture must pass; every mutant must go red by its own arm
# --------------------------------------------------------------------------

GOOD = {
    "announces": [
        {"meeting_uid": "walk-fixture-brief-0", "kind": "meeting_brief", "message":
         "Meeting: Catch up with Alexandra at 10:00.\n\n"
         "Alexandra Patel, Head of Design at Acme Corp: former client, met via a design conference, 2 meetings logged.\n"
         "Last contact 18 Jun 2026 (conversation).\nLast meeting 21 May 2026: Lisbon workshop budget review.\n"
         "You owe: Share the workshop deck with Alexandra (due 2030-01-31).\n"
         "On file: Moved to Acme Corp in January.\n"
         "Worth raising: the open item (Share the workshop deck with Alexandra); follow up on Lisbon workshop budget review."},
        {"meeting_uid": "walk-fixture-brief-1", "kind": "meeting_brief", "message":
         "Meeting: Catch up with Philip at 10:00.\n\n"
         "Philip Coe, at Globex Corp: client, no meetings logged.\nLast contact 31 May 2026 (whatsapp)."},
        {"meeting_uid": "walk-fixture-brief-2", "kind": "meeting_brief", "message":
         "Meeting: Catch up with Catherine at 10:00.\n\n"
         "Catherine Stewart.\nLittle else on file, so nothing more to add."},
    ]
}


def _mut(fn):
    import copy
    f = copy.deepcopy(GOOD)
    fn(f["announces"])
    return f


def _set(i, text):
    def go(a):
        a[i]["message"] = text
    return go


MUTANTS = {
    "the OLD brief: first face-to-face meeting inferred from absence (rich)":
        _set(0, "Meeting: Catch up with Alexandra at 10:00.\nWith: Alexandra Patel.\nPlease remember this is your first face-to-face meeting. A warm welcome would be appropriate."),
    "none says 'first meeting' instead of 'no meetings logged'":
        _set(1, "Meeting: Catch up with Philip at 10:00.\n\nPhilip Coe, at Globex Corp: this is your first meeting with Philip."),
    "none drops the 'no meetings logged' truth":
        _set(1, "Meeting: Catch up with Philip at 10:00.\n\nPhilip Coe, at Globex Corp: client."),
    "rich loses the last topic":
        _set(0, GOOD["announces"][0]["message"].replace("Lisbon workshop budget review", "a recent catch-up")),
    "rich loses the open promise":
        _set(0, GOOD["announces"][0]["message"].replace("You owe: Share the workshop deck with Alexandra (due 2030-01-31).\n", "")),
    "rich invents a mutual contact the Hub cannot supply":
        _set(0, GOOD["announces"][0]["message"] + "\nPeople in common: Raj Brown."),
    "thin is padded with generic advice":
        _set(2, "Meeting: Catch up with Catherine at 10:00.\n\nCatherine Stewart.\nLittle else on file. Be sure to make a good impression and ask about their weekend."),
    "thin does not say it is thin":
        _set(2, "Meeting: Catch up with Catherine at 10:00.\n\nCatherine Stewart."),
    "an em dash in the sent text":
        _set(1, GOOD["announces"][1]["message"].replace("no meetings logged", "no meetings logged \u2014 noted")),
    "the old With:/Wiki: shape":
        _set(2, "Meeting: Catch up with Catherine at 10:00.\nWith: Catherine Stewart.\nWiki: http://x/People/catherine/\nLittle else on file."),
    "a message over the word budget":
        _set(2, GOOD["announces"][2]["message"] + " filler" * 200),
}


def self_test():
    ok = True
    print("-- control: the good capture must pass --")
    res, cannot = judge(GOOD)
    good_bad = [l for k, l in res if not k]
    print(f"  {'ok     ' if not good_bad and not cannot else 'FAIL   '}good capture passes {good_bad or ''}")
    ok &= not good_bad and not cannot
    print("-- mutants: each must be rejected --")
    for name, fn in MUTANTS.items():
        res, cannot = judge(_mut(fn))
        rejected = bool([1 for k, _ in res if not k])
        print(f"  {'ok     ' if rejected else 'FAIL   '}rejected: {name}")
        ok &= rejected
    nothing = {"announces": []}
    res, _ = judge(nothing)
    rejected = bool([1 for k, _ in res if not k])
    print(f"  {'ok     ' if rejected else 'FAIL   '}rejected: the sender sent nothing")
    ok &= rejected
    two = _mut(lambda a: a.pop())
    res, _ = judge(two)
    rejected = bool([1 for k, _ in res if not k])
    print(f"  {'ok     ' if rejected else 'FAIL   '}rejected: only two of three meetings were announced")
    ok &= rejected
    res, cannot = judge({"cannot": "no sender installed"})
    print(f"  {'ok     ' if cannot else 'FAIL   '}a missing prerequisite is CANNOT-RUN, not a pass or a fail")
    ok &= bool(cannot)
    print(f"\n{len(MUTANTS) + 2} mutants; {'every one went red' if ok else 'SELF-TEST BROKEN'}")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# box mode
# --------------------------------------------------------------------------

def store_auth_headers():
    """The Oxigraph store credential, resolved EXACTLY as the product writers
    resolve it (lib/ostler_store_auth.py, route for :7878): the OXIGRAPH_TOKEN
    env var first, then the 0600 file ~/.ostler/secrets/oxigraph_token (or
    $OSTLER_SECRETS_DIR). Sent as `Authorization: Bearer <token>`, which is what
    the :7878 store proxy checks (install.sh writes `if ($http_authorization !=
    "Bearer ${OXIGRAPH_TOKEN}") { return 401; }`).

    Walk #16: the seed write sent no credential and got HTTP 401, so wow #4
    could not be measured. No token found -> no header (an older open store
    still works; a protected one answers 401, reported as CANNOT-RUN).
    """
    tok = (os.environ.get("OXIGRAPH_TOKEN") or "").strip()
    if not tok:
        d = os.environ.get("OSTLER_SECRETS_DIR", os.path.expanduser("~/.ostler/secrets"))
        try:
            with open(os.path.join(d, "oxigraph_token"), encoding="utf-8") as fh:
                tok = fh.read().strip()
        except OSError:
            tok = ""
    return {"Authorization": "Bearer " + tok} if tok else {}


def store_update(oxi_update_url, sparql, timeout=30):
    """POST one SPARQL UPDATE to the store, with the store credential."""
    import urllib.request
    headers = {"Content-Type": "application/sparql-update"}
    headers.update(store_auth_headers())
    req = urllib.request.Request(oxi_update_url, data=sparql.encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def box():
    import subprocess
    import threading
    import urllib.request
    import urllib.error
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    home = os.path.expanduser("~")
    ostler = os.path.join(home, ".ostler")
    sender = os.path.join(ostler, "bin", "ostler-meeting-brief-sender")
    composer = os.environ.get("OSTLER_BRIEF_COMPOSER") or os.path.join(
        ostler, "OstlerAssistant.app", "Contents", "MacOS", "ostler-assistant")
    token_file = os.path.join(ostler, "secrets", "service_token")

    def cannot(msg):
        print(json.dumps({"cannot": msg}))
        return 0

    if not os.path.isfile(sender):
        return cannot("the sender is not installed at " + sender + " (INSTALL_MEETING_BRIEF_LAUNCHAGENT defaults to true from cut #16, so this install either opted out or predates the flip)")
    if not os.access(composer, os.X_OK):
        return cannot("the assistant binary is not executable at " + composer)
    probe = subprocess.run([composer, "meeting-brief", "--help"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        return cannot("the installed assistant binary has no `meeting-brief` command (rc=%d); this DMG predates the composer" % probe.returncode)
    token = (os.environ.get("PWG_SERVICE_TOKEN") or "").strip()
    if not token and os.path.isfile(token_file):
        token = open(token_file).read().strip()
    if not token:
        return cannot("no service token (PWG_SERVICE_TOKEN or " + token_file + "); the Hub answers 401 without it")

    def open_url(url, data=None, headers=None, method=None, timeout=15):
        req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
        return urllib.request.urlopen(req, timeout=timeout)

    hub = os.environ.get("OSTLER_HUB_HOST", "").rstrip("/")
    candidates = [hub] if hub else ["http://127.0.0.1:8090", "http://127.0.0.1:8089"]
    hub = ""
    for c in candidates:
        try:
            open_url(c + "/health", timeout=5)
            hub = c
            break
        except Exception:
            continue
    if not hub:
        return cannot("no Hub answered /health on " + ", ".join(candidates))
    auth = {"Authorization": "Bearer " + token}

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import meeting_brief_seed as seed
    oxi = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878/query").replace("/query", "/update")

    def sparql_update(q):
        store_update(oxi, q)

    default, _named = seed.sparql(with_named_graph=False)
    try:
        sparql_update(seed.forget_sparql())
        sparql_update(default)
    except Exception as exc:
        return cannot("the seed could not be written to the graph at %s: %s" % (oxi, exc))
    out = {"announces": []}
    state_db = os.path.join(ostler, "state", "sent_briefs.db")
    try:
        # PROVE the seed reads back through the Hub before grading anything.
        from urllib.parse import quote
        try:
            ctx = json.loads(open_url(hub + "/api/v1/people/context?name=" + quote(seed.RICH["name"]), headers=auth).read())
        except Exception as exc:
            return cannot("the seeded person could not be read through the Hub: %s" % exc)
        if not ctx.get("found"):
            return cannot("the seed was written but the Hub does not find %s; this is a harness failure, not a product verdict" % seed.RICH["name"])

        todos = [{"text": "Share the workshop deck with Alexandra", "owner": "user", "owner_display": "Sam",
                  "deadline": "2030-01-31", "priority": "", "source_conversation_date": ""}]

        def meeting(i, person, att_todos):
            return {"meeting": "Catch up with " + person["name"].split()[0], "start": "10:00",
                    "start_iso": "2099-01-01T10:00:0%d+00:00" % i, "uid": "walk-fixture-brief-%d" % i,
                    "location": "Riverside Town",
                    "attendees": [{"name": person["name"], "email": person["email"],
                                   "wiki_url": "http://wiki.invalid/People/%s/" % person["slug"],
                                   "outstanding_todos": att_todos}]}

        meetings = [meeting(0, seed.RICH, todos), meeting(1, seed.NONE, []), meeting(2, seed.THIN, [])]

        class Shim(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body):
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.startswith("/api/v1/meeting/upcoming"):
                    return self._send(200, json.dumps({"meetings": meetings, "within_minutes": 20, "count": 3}).encode())
                try:
                    r = open_url(hub + self.path, headers=auth)
                    return self._send(r.status, r.read())
                except urllib.error.HTTPError as e:
                    return self._send(e.code, e.read())
                except Exception as e:
                    return self._send(502, json.dumps({"error": str(e)}).encode())

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                if self.path == "/announce":
                    out["announces"].append(json.loads(body))
                    return self._send(200, b"{}")
                return self._send(404, b"{}")

        srv = ThreadingHTTPServer(("127.0.0.1", 0), Shim)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:%d" % srv.server_address[1]
        env = dict(os.environ)
        env.update({"OSTLER_HUB_HOST": base, "OSTLER_ASSISTANT_URL": base,
                    "OSTLER_BRIEF_QUIET_START": "24", "OSTLER_BRIEF_QUIET_END": "0",
                    "OSTLER_BRIEF_COMPOSER": composer, "OSTLER_BRIEF_OWNER_NAME": "Sam",
                    "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"})
        log = os.path.join(ostler, "logs", "meeting-brief-sender.log")
        log_start = os.path.getsize(log) if os.path.isfile(log) else 0

        def run_sender():
            r = subprocess.run(["bash", sender], env=env, capture_output=True, text=True, timeout=240)
            tail = ""
            if os.path.isfile(log):
                with open(log) as fh:
                    fh.seek(log_start)
                    tail = fh.read()[-1500:]
            return r.returncode, tail

        rc, tail = run_sender()
        out["channel_source"] = "the box's own brief channel"
        if rc == 78 and not out["announces"]:
            # The sender read the box's config.toml and found no brief channel
            # (a walk box often has none enabled). That is the sender reporting
            # correctly, and it is not what this probe grades. Re-run with a
            # FICTIONAL announce job: /announce is the shim above, so nobody is
            # messaged, and the TEXT is graded exactly as before.
            import tempfile
            cfg = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False)
            cfg.write('[[cron.jobs]]\nid = "morning-brief"\n'
                      'delivery = { mode = "announce", channel = "whatsapp", to = "+447700900123" }\n')
            cfg.close()
            env["OSTLER_BRIEF_CONFIG"] = cfg.name
            out["channel_source"] = "fixture (the box has no brief channel; the sender exited 78 CANNOT-DELIVER, as designed)"
            rc, tail = run_sender()
            os.unlink(cfg.name)
        out["sender_rc"] = rc
        out["log_tail"] = tail
        srv.shutdown()
        if not out["announces"] and "Ostler Pro is not active" in tail:
            return cannot("Ostler Pro is not active on this box, so the sender paused by design and sent nothing to grade")
    finally:
        try:
            sparql_update(seed.forget_sparql())
        except Exception:
            pass
        try:
            import sqlite3
            if os.path.isfile(state_db):
                c = sqlite3.connect(state_db)
                c.execute("DELETE FROM sent_briefs WHERE meeting_uid LIKE 'walk-fixture-brief-%'")
                c.commit()
                c.close()
        except Exception:
            pass
    print(json.dumps(out))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 3 and argv[1] == "judge":
        return report(json.load(open(argv[2])))
    if len(argv) >= 2 and argv[1] == "box":
        return box()
    print(__doc__)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
