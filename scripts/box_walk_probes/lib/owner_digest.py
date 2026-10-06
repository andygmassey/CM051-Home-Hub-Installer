#!/usr/bin/env python3
"""Does the assistant's always-on digest know its owner? (v1.0.107 #10)

The digest is CONTEXT.md, written by context-refresh/bin/generate_pwg_context.py
into ~/.ostler/assistant-config/workspace/ and injected into every chat prompt.
Three assertions, each graded from COUNTS and yes/no facts only:

  (a) it has a non-empty "## About you" section whose "- Work:" line names at
      least one organisation, and non-empty top-people and preferences sections;
  (b) no section is declared "nothing stored" while the store it reads from
      holds data. Every store count is MEASURED on the box, never assumed; a
      "nothing stored" line for a section with no store measure is CANNOT-RUN;
  (c) asked "Where have I worked?", the chat names the seed organisation
      (imported through the customer's own LinkedIn-export path).

Two halves, kept apart so the judge can be mutation-tested without a box:

  box  -- runs ON the box (staged by the probe). Reads CONTEXT.md, measures
          the stores, asks the chat. Prints ONE JSON line of counts and
          booleans. Never prints digest text, store contents or reply prose:
          they are the owner's personal data.
  judge(facts) -> rows    pure.

Usage:
  owner_digest.py --self-test
  owner_digest.py judge FACTS.json
  owner_digest.py box --seed-org ORG [--seed-state STATE]   (on the box)
"""
import json
import os
import re
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

# The generator's contract for the owner section (Aesop, 2026-10-07): exactly
# this heading, with a line starting "- Work:" listing organisations,
# comma-separated, current one first.
ABOUT_YOU = "About you"
TOP_PEOPLE = "People you interact with most"
PREFERENCES = "Preferences and things to keep in mind"
WORK_LINE = re.compile(r"^-\s*Work:\s*(.*)$", re.M)
GAP_LINE = re.compile(r"^-\s*(.+?):\s*nothing stored\.?\s*$", re.M | re.I)

# Which measured store backs each digest section. A section absent from this
# map has no store measure: a "nothing stored" line for it is CANNOT-RUN, never
# a pass and never a fail.
SECTION_STORE = {
    ABOUT_YOU: "owner_facts",
    TOP_PEOPLE: "people",
    PREFERENCES: "preferences",
    "Key organisations": "people_with_org",
    "Confirmed by you": "user_asserted_facts",
    "Recent meetings (last 7 days)": "meetings_7d",
}

DECLARED = [
    "digest: About you names at least one organisation, and top people and preferences are non-empty",
    "digest: no section says nothing stored while its store holds data",
    "chat: 'Where have I worked?' names the seed organisation",
]


def sections(text):
    """{heading: [non-empty body lines]} for every '## ' section."""
    out, cur = {}, None
    for line in (text or "").splitlines():
        if line.startswith("## "):
            cur = line[3:].strip()
            out[cur] = []
        elif cur is not None and line.strip():
            out[cur].append(line.rstrip())
    return out


def work_orgs(section_lines):
    for line in section_lines or []:
        m = WORK_LINE.match(line.strip())
        if m:
            return [o.strip() for o in m.group(1).split(",") if o.strip()]
    return None


def digest_facts(text):
    """Counts only, derived from the digest text (runs on the box)."""
    secs = sections(text)
    orgs = work_orgs(secs.get(ABOUT_YOU))
    gaps = [g.strip() for g in GAP_LINE.findall(text or "")]
    return {
        "present": bool(text),
        "about_you_lines": len(secs[ABOUT_YOU]) if ABOUT_YOU in secs else None,
        "work_line": orgs is not None,
        "work_orgs": len(orgs or []),
        "top_people_lines": len(secs.get(TOP_PEOPLE) or []),
        "preferences_lines": len(secs.get(PREFERENCES) or []),
        "nothing_stored": gaps,
    }


# ---------------------------------------------------------------------------
# judge: pure
# ---------------------------------------------------------------------------

def judge(f):
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    if not f.get("hydrated"):
        reason = "NOT MEASURED: the box has not finished hydrating ({}); this probe runs after hydration".format(
            f.get("hydration_state", "unknown"))
        for d in DECLARED:
            add(d, None, reason)
        return out

    d = f.get("digest") or {}
    if not d.get("present"):
        add(DECLARED[0], False, "CONTEXT.md is missing or empty")
        add(DECLARED[1], False, "CONTEXT.md is missing or empty")
    else:
        miss = []
        if d.get("about_you_lines") is None:
            miss.append("no '## About you' section")
        elif not d.get("about_you_lines"):
            miss.append("'## About you' is empty")
        elif not d.get("work_line"):
            miss.append("'## About you' has no '- Work:' line")
        elif d.get("work_orgs", 0) < 1:
            miss.append("the '- Work:' line names no organisation")
        if not d.get("top_people_lines"):
            miss.append("'## {}' is empty or absent".format(TOP_PEOPLE))
        if not d.get("preferences_lines"):
            miss.append("'## {}' is empty or absent".format(PREFERENCES))
        add(DECLARED[0], not miss, "; ".join(miss) if miss else "About you {} line(s), {} organisation(s); people {} line(s); preferences {} line(s)".format(
            d.get("about_you_lines"), d.get("work_orgs"), d.get("top_people_lines"), d.get("preferences_lines")))

        stores = f.get("stores") or {}
        lies, unmeasured = [], []
        for heading in d.get("nothing_stored") or []:
            key = SECTION_STORE.get(heading)
            n = stores.get(key) if key else None
            if key is None or n is None:
                unmeasured.append(heading)
            elif n > 0:
                lies.append("{} says nothing stored, store holds {}".format(heading, n))
        if lies:
            add(DECLARED[1], False, "; ".join(lies))
        elif unmeasured:
            add(DECLARED[1], None, "NOT MEASURED: no store measure for: " + ", ".join(unmeasured))
        else:
            add(DECLARED[1], True, "{} nothing-stored line(s), each with an empty store".format(len(d.get("nothing_stored") or [])))

    chat = f.get("chat") or {}
    if f.get("seed_state") != "seeded":
        add(DECLARED[2], None, "NOT MEASURED: the owner employer was not seeded (seed state {})".format(f.get("seed_state", "unrun")))
    elif chat.get("answered") is not True:
        add(DECLARED[2], None, "NOT MEASURED: the chat gave no complete answer ({})".format(chat.get("error", "no reply")))
    else:
        add(DECLARED[2], chat.get("names_seed_org") is True,
            "reply {} the seed organisation (reply text withheld)".format("names" if chat.get("names_seed_org") else "does NOT name"))

    names = [n for n, _, _ in out]
    missing = [x for x in DECLARED if x not in names]
    add("owner digest: every declared assertion produced a row", not missing, ", ".join(missing))
    return out


# ---------------------------------------------------------------------------
# box half: runs on the box, prints counts and booleans only
# ---------------------------------------------------------------------------

def _store_headers():
    hdrs = {}
    try:
        for line in open(os.path.expanduser("~/.ostler/secrets/store-curl.conf")):
            m = re.match(r'\s*header\s*=\s*"?([^:"]+):\s*([^"]*)"?\s*$', line)
            if m:
                hdrs[m.group(1).strip()] = m.group(2).strip()
    except IOError:
        pass
    return hdrs


def _http(url, data=None, headers=None, timeout=30):
    import urllib.request
    req = urllib.request.Request(url, data=data, headers=headers or {})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as r:
        return json.loads(r.read().decode() or "null")


def measure_stores():
    """Each store's count, or None when it could not be read. Never assumed."""
    h = _store_headers()
    q = "http://127.0.0.1:6333"
    out = {}

    def qd(name, body=None):
        try:
            if body is None:
                return int(_http(q + "/collections/" + name, headers=h)["result"]["points_count"] or 0)
            hh = dict(h, **{"Content-Type": "application/json"})
            return int(_http(q + "/collections/%s/points/count" % name, json.dumps(body).encode(), hh)["result"]["count"])
        except Exception:
            return None

    out["people"] = qd("people")
    out["preferences"] = qd("preferences")
    out["people_with_org"] = qd("people", {"exact": True, "filter": {"must_not": [{"is_empty": {"key": "organization"}}]}})

    def sparql_count(where):
        try:
            hh = dict(h, **{"Content-Type": "application/sparql-query", "Accept": "application/sparql-results+json"})
            q_ = "PREFIX pwg: <https://schema.ostler.ai/ontology#>\nSELECT (COUNT(*) AS ?n) WHERE { %s }" % where
            res = _http("http://127.0.0.1:7878/query", q_.encode(), hh)
            return int(res["results"]["bindings"][0]["n"]["value"])
        except Exception:
            return None

    out["user_asserted_facts"] = sparql_count('?f a pwg:PersonFact ; pwg:factSource "user_asserted" .')
    import datetime
    since = (datetime.date.today() - datetime.timedelta(days=7)).isoformat()
    today = datetime.date.today().isoformat()
    out["meetings_7d"] = sparql_count('?m a pwg:Meeting ; pwg:meetingDate ?d . FILTER(SUBSTR(STR(?d),1,10) >= "%s" && SUBSTR(STR(?d),1,10) <= "%s")' % (since, today))
    uid = ""
    try:
        for line in open(os.path.expanduser("~/.ostler/config/.env")):
            if line.startswith("USER_ID="):
                uid = line.split("=", 1)[1].strip().strip('"')
    except IOError:
        pass
    out["owner_facts"] = sparql_count('?f a pwg:PersonFact ; pwg:aboutPerson <https://schema.ostler.ai/ontology#user_%s> .' % uid) if uid else None
    return out


def hydration():
    try:
        d = _http("http://127.0.0.1:8089/api/v1/hydration/status", timeout=10)
        state = d.get("overall_state")
        return (state in ("complete", "done", "settled") or d.get("complete") is True), state
    except Exception as exc:
        return False, "unreadable ({})".format(str(exc)[:60])


def ask_chat(question, seed_org, deadline_s=300):
    """Ask over /ws/chat and return {answered, names_seed_org}; never the prose."""
    import base64
    import socket
    import struct
    import time
    try:
        token = open(os.path.expanduser("~/.ostler/secrets/zeroclaw_admin_token")).read().strip()
        s = socket.create_connection(("127.0.0.1", 8000), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: 127.0.0.1:8000\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n"
                   "Authorization: Bearer %s\r\n\r\n" % (key, token)).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            c = s.recv(4096)
            if not c:
                return {"answered": False, "error": "handshake eof"}
            buf += c
        head, rest = buf.split(b"\r\n\r\n", 1)
        if b" 101" not in head.split(b"\r\n")[0]:
            return {"answered": False, "error": "handshake refused"}
        d = json.dumps({"type": "message", "content": question}).encode()
        m = os.urandom(4)
        mk = bytes(b ^ m[i % 4] for i, b in enumerate(d))
        n = len(d)
        hdr = struct.pack("!BB", 0x81, 0x80 | n) if n < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, n)
        s.sendall(hdr + m + mk)
        deadline = time.time() + deadline_s
        state = {"rest": rest}

        def rd(k):
            o = b""
            while len(o) < k:
                if state["rest"]:
                    t = state["rest"][: k - len(o)]
                    o += t
                    state["rest"] = state["rest"][len(t):]
                else:
                    s.settimeout(max(1, deadline - time.time()))
                    c = s.recv(65536)
                    if not c:
                        raise EOFError
                    state["rest"] = c
            return o
        text = ""
        while time.time() < deadline:
            b0, b1 = rd(2)
            op, k = b0 & 0x0F, b1 & 0x7F
            if k == 126:
                k = struct.unpack("!H", rd(2))[0]
            elif k == 127:
                k = struct.unpack("!Q", rd(8))[0]
            pay = rd(k)
            if op == 8:
                break
            if op != 1:
                continue
            ev = json.loads(pay)
            t = ev.get("type")
            if t == "chunk":
                text += ev.get("content") or ""
            elif t == "chunk_reset":
                text = ""
            elif t == "done":
                reply = ev.get("full_response") if "full_response" in ev else text
                return {"answered": True, "names_seed_org": seed_org.lower() in (reply or "").lower()}
            elif t == "error":
                return {"answered": False, "error": "chat error frame"}
        return {"answered": False, "error": "no done frame before the deadline"}
    except Exception as exc:
        return {"answered": False, "error": str(exc)[:80]}


def box_main(argv):
    a = dict(zip(argv[0::2], argv[1::2]))
    seed_org = a.get("--seed-org", "")
    facts = {"seed_state": a.get("--seed-state", "unrun")}
    facts["hydrated"], facts["hydration_state"] = hydration()
    try:
        text = open(os.path.expanduser("~/.ostler/assistant-config/workspace/CONTEXT.md")).read()
    except IOError:
        text = ""
    facts["digest"] = digest_facts(text)
    facts["stores"] = measure_stores()
    if facts["seed_state"] == "seeded" and facts["hydrated"] and seed_org:
        facts["chat"] = ask_chat("Where have I worked?", seed_org)
    print(json.dumps(facts))
    return 0


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

GOOD_DIGEST = """# Personal Context

## About you

- Work: ExampleCo, ExampleWorks
- Based in Riverside.

## People you interact with most

- Jane Doe (ExampleWorks)

## Preferences and things to keep in mind

- Likes jazz.

## Key organisations

- ExampleCo
"""


def _good():
    return {"hydrated": True, "hydration_state": "complete", "seed_state": "seeded",
            "digest": digest_facts(GOOD_DIGEST),
            "stores": {"people": 10, "preferences": 5, "people_with_org": 3, "user_asserted_facts": 0,
                       "meetings_7d": 0, "owner_facts": 2},
            "chat": {"answered": True, "names_seed_org": True}}


def self_test():
    import copy
    fails = []

    def row(f, i):
        return [ok for n, ok, _ in judge(f) if n == DECLARED[i]]

    g = _good()
    if any(ok is not True for _, ok, _ in judge(g)):
        print("SELF-TEST BROKEN: the good fixture fails: {}".format([(n, d) for n, ok, d in judge(g) if ok is not True]))
        return EX_FAIL
    print("  ok    good fixture: every assertion passes")

    # The empty digest the generator writes when its sources answer nothing,
    # while the stores hold data: FAILS (a) and (b).
    empty = copy.deepcopy(g)
    empty["digest"] = digest_facts("# Personal Context\n\n## What is not in this digest\n\n"
                                   "- People you interact with most: nothing stored.\n"
                                   "- Preferences and things to keep in mind: nothing stored.\n"
                                   "- Key organisations: nothing stored.\n\n## Looking something up\n\n- use the tools\n")
    if row(empty, 0) != [False] or row(empty, 1) != [False]:
        fails.append("empty digest: (a) {} (b) {} (want False, False)".format(row(empty, 0), row(empty, 1)))
    else:
        print("  ok    an empty digest over full stores FAILS (a) and (b)")

    # A digest without the organisation, and a chat that cannot name it: FAILS (c).
    no_org = copy.deepcopy(g)
    no_org["digest"] = digest_facts(GOOD_DIGEST.replace("- Work: ExampleCo, ExampleWorks\n", ""))
    no_org["chat"] = {"answered": True, "names_seed_org": False}
    if row(no_org, 2) != [False] or row(no_org, 0) != [False]:
        fails.append("digest without the organisation: (c) {} (a) {} (want False, False)".format(row(no_org, 2), row(no_org, 0)))
    else:
        print("  ok    a digest without the organisation FAILS (a), and the chat that cannot name it FAILS (c)")

    # Mutants, each caught by its own assertion.
    mutants = [
        ("no About you section", 0, lambda f: f.update(digest=digest_facts(GOOD_DIGEST.replace("## About you", "## About me")))),
        ("Work line with no organisation", 0, lambda f: f.update(digest=digest_facts(GOOD_DIGEST.replace("ExampleCo, ExampleWorks", "")))),
        ("top people empty", 0, lambda f: f["digest"].update(top_people_lines=0)),
        ("preferences empty", 0, lambda f: f["digest"].update(preferences_lines=0)),
        ("nothing stored over a full people store", 1, lambda f: f["digest"]["nothing_stored"].append(TOP_PEOPLE)),
        ("nothing stored over full owner facts", 1, lambda f: f["digest"]["nothing_stored"].append(ABOUT_YOU)),
        ("chat does not name the seed organisation", 2, lambda f: f["chat"].update(names_seed_org=False)),
    ]
    for name, i, mutate in mutants:
        f = copy.deepcopy(g)
        mutate(f)
        if row(f, i) != [False]:
            fails.append("{} not caught by its own assertion ({})".format(name, row(f, i)))
        else:
            print("  ok    mutant caught: {}".format(name))

    # Honest gaps: a "nothing stored" line over an EMPTY store passes; one with
    # no store measure is CANNOT-RUN; an unseeded walk, an unhydrated box and an
    # unanswered chat are CANNOT-RUN, never a pass.
    honest = copy.deepcopy(g); honest["digest"]["nothing_stored"].append("Confirmed by you")
    unmeasured = copy.deepcopy(g); unmeasured["digest"]["nothing_stored"].append("Calendar events by owner")
    unseeded = copy.deepcopy(g); unseeded["seed_state"] = "skipped"
    dry = copy.deepcopy(g); dry["hydrated"] = False
    silent = copy.deepcopy(g); silent["chat"] = {"answered": False, "error": "timeout"}
    checks = [(row(honest, 1), [True], "nothing stored over an empty store PASSES"),
              (row(unmeasured, 1), [None], "nothing stored with no store measure is CANNOT-RUN"),
              (row(unseeded, 2), [None], "an unseeded walk is CANNOT-RUN for (c)"),
              (row(dry, 0), [None], "an unhydrated box is CANNOT-RUN"),
              (row(silent, 2), [None], "a chat that never answers is CANNOT-RUN")]
    for got, want, label in checks:
        if got != want:
            fails.append("{}: got {}".format(label, got))
        else:
            print("  ok    " + label)
    if [ok for n, ok, _ in judge({}) if ok is True]:
        fails.append("an empty collection reads as a pass")
    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, {} mutants caught by their own assertion".format(len(mutants)))
    return EX_PASS


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} owner-digest assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    if argv[:1] == ["box"]:
        return box_main(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
