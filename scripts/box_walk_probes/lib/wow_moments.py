"""v1.0.108 wow-moment walk checks: reply debt in chat, and the morning brief
that catches the owner up (launch/WOW_MOMENTS_GATE.md, moments 1 and 7).

Two halves, as every probe here:
  BOX side (`reply-debt-box`, `morning-box`) runs ON the box. It talks to the
  installed Hub and daemon only over loopback, grades the customer-visible
  text THERE, and prints ONE JSON line of counts and yes/no answers. Names,
  facts and the answer prose never leave the box: they are the owner's data
  and the walk record lands in support bundles.
  JUDGE side (`judge-reply-debt FILE`, `judge-morning FILE`) turns that JSON
  into ok/FAIL/CANNOT lines and an exit code: 0 pass, 1 fail, 78 cannot-run.

`--self-test` drives both judges over a good capture and one mutant per
defect; it must report every mutant red.

Python 3.9 compatible (the box's /usr/bin/python3); tomllib used when present.
"""
import base64
import json
import os
import re
import socket
import struct
import sys
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
HOME = os.path.expanduser("~")
OSTLER = os.path.join(HOME, ".ostler")
SECRETS = os.environ.get("OSTLER_SECRETS_DIR", os.path.join(OSTLER, "secrets"))
HUB = os.environ.get("OSTLER_HUB_HOST", "http://127.0.0.1:8090").rstrip("/")
GATEWAY = os.environ.get("OSTLER_PROBE_GATEWAY", "http://127.0.0.1:8000").rstrip("/")
STORE = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878/query").replace("/query", "")
GRADED_MAX = 3
NONE_WORDS = re.compile(r"\b(nobody|no one|no-one|none|not waiting|no replies|nothing)\b", re.I)


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _secret(name, env=None):
    return ((os.environ.get(env) if env else "") or _read(os.path.join(SECRETS, name))).strip()


def _http(method, url, body=None, headers=None, timeout=30):
    """-> (status, parsed-json-or-None). Never raises for an HTTP status."""
    import urllib.request
    import urllib.error
    data = body if body is None or isinstance(body, bytes) else json.dumps(body).encode()
    h = dict(headers or {})
    if data is not None and "Content-Type" not in h:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            raw = r.read()
            code = r.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    try:
        return code, json.loads(raw) if raw else None
    except ValueError:
        return code, None


def _hub(path):
    tok = _secret("service_token", "PWG_SERVICE_TOKEN")
    return _http("GET", HUB + path, headers={"Authorization": "Bearer " + tok} if tok else {})


def _store_update(sparql):
    tok = _secret("oxigraph_token", "OXIGRAPH_TOKEN")
    h = {"Content-Type": "application/sparql-update"}
    if tok:
        h["Authorization"] = "Bearer " + tok
    return _http("POST", STORE + "/update", body=sparql.encode(), headers=h)[0]


def _withheld(level):
    return (level or "").strip().lower() in ("l3", "private")


def ws_chat(question, deadline_s=420):
    """Ask the installed assistant one question over /ws/chat. -> (tools, text,
    error). The same handshake and framing the grounded probe uses."""
    token = _secret("zeroclaw_admin_token")
    if not token:
        return [], "", "no admin token at ~/.ostler/secrets/zeroclaw_admin_token"
    port = int(GATEWAY.rsplit(":", 1)[1])
    deadline = time.time() + deadline_s
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=20)
    except OSError as e:
        return [], "", "no_connect %s" % e
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
               "Sec-WebSocket-Protocol: zeroclaw.v1\r\nAuthorization: Bearer %s\r\n\r\n"
               % (port, key, token)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(4096)
        if not c:
            return [], "", "handshake_eof"
        buf += c
    head, rest = buf.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n")[0] + b" ":
        return [], "", "handshake %s" % head.split(b"\r\n")[0].decode(errors="replace")
    state = {"rest": rest}

    def rd(n):
        o = b""
        while len(o) < n:
            if state["rest"]:
                t = state["rest"][: n - len(o)]
                o += t
                state["rest"] = state["rest"][len(t):]
            else:
                s.settimeout(max(1, deadline - time.time()))
                c = s.recv(65536)
                if not c:
                    raise EOFError
                state["rest"] = c
        return o

    def frame():
        b0, b1 = rd(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", rd(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", rd(8))[0]
        return b0 & 0x0F, rd(n)

    d = json.dumps({"type": "message", "content": question}).encode()
    m = os.urandom(4)
    mk = bytes(b ^ m[i % 4] for i, b in enumerate(d))
    n = len(d)
    hdr = struct.pack("!BB", 0x81, 0x80 | n) if n < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, n)
    s.sendall(hdr + m + mk)
    tools, text, final = [], "", None
    while time.time() < deadline:
        try:
            op, pay = frame()
        except Exception:
            return tools, final if final is not None else text, "timeout"
        if op == 8:
            break
        if op != 1:
            continue
        try:
            ev = json.loads(pay)
        except ValueError:
            continue
        t = ev.get("type")
        if t == "tool_call":
            tools.append(ev.get("name", "?"))
        elif t == "chunk":
            text += ev.get("content") or ""
        elif t == "chunk_reset":
            text = ""
        elif t == "done":
            final = ev.get("full_response") if "full_response" in ev else text
            break
        elif t == "error":
            return tools, text, "error frame"
    s.close()
    return tools, final if final is not None else text, None


def _named(text, name):
    """Every distinctive word of a name appears as a whole word in the text."""
    words = [w for w in re.split(r"[^\w'-]+", name.lower()) if len(w) > 1]
    t = text.lower()
    return bool(words) and all(re.search(r"(?<![\w])" + re.escape(w) + r"(?![\w])", t) for w in words)


# --------------------------------------------------------------------------
# moment 1: "who do I owe a reply to?"
# --------------------------------------------------------------------------

def box_reply_debt():
    code, body = _hub("/api/v1/reply-debt")
    out = {"endpoint": code}
    if code in (401, 403):
        out["cannot"] = "the Hub refused the service token (HTTP %d); reply debt was not measured" % code
        return out
    if code != 200 or not isinstance(body, dict):
        out["endpoint_error"] = "HTTP %s, %s" % (code, "unparseable" if body is None else "not an object")
        return out
    out["degraded"] = bool(body.get("degraded"))
    out["reason"] = (body.get("reason") or "")[:120]
    debts = [d for d in (body.get("debts") or []) if isinstance(d, dict)]
    names = [d.get("person_name") for d in debts
             if d.get("person_name") and not _withheld(d.get("privacy_level"))][:GRADED_MAX]
    l3 = [d.get("person_name") for d in debts if d.get("person_name") and _withheld(d.get("privacy_level"))]
    out["count"] = len(debts)
    out["fields_ok"] = all("person_name" in d and "waiting_hours" in d for d in debts)
    if out["degraded"]:
        return out
    tools, text, err = ws_chat("Who do I owe a reply to?")
    if err and not text:
        out["chat_cannot"] = err
        return out
    out["tools"] = sorted(set(tools))
    out["graded"] = len(names)
    out["named"] = [_named(text, n) for n in names]
    out["l3_named"] = sum(1 for n in l3 if _named(text, n))
    out["says_none"] = bool(NONE_WORDS.search(text)) if not debts else None
    out["answered"] = bool(text.strip())
    return out


def judge_reply_debt(c):
    lines, fail, cannot = [], False, None

    def check(label, ok):
        nonlocal fail
        lines.append(("  ok     " if ok else "  FAIL   ") + label)
        fail |= not ok

    if c.get("cannot"):
        return ["  CANNOT " + c["cannot"]], EX_CANNOT
    if c.get("endpoint_error"):
        check("GET /api/v1/reply-debt answers 200 JSON (%s)" % c["endpoint_error"], False)
        return lines, EX_FAIL
    check("GET /api/v1/reply-debt answers 200 JSON", True)
    check("reply debt is not degraded (the detector can read Messages)%s"
          % (": " + c.get("reason", "") if c.get("degraded") else ""), not c.get("degraded"))
    check("every debt carries person_name and waiting_hours", c.get("fields_ok", False))
    if c.get("degraded"):
        return lines, EX_FAIL
    if c.get("chat_cannot"):
        return lines + ["  CANNOT the assistant could not be asked: %s" % c["chat_cannot"]], EX_CANNOT
    check("the assistant answered", c.get("answered", False))
    check("chat called pwg_reply_debt (tools: %s)" % (",".join(c.get("tools") or []) or "none"),
          "pwg_reply_debt" in (c.get("tools") or []))
    named = c.get("named") or []
    if c.get("count", 0) > 0:
        check("the answer names the %d people the Hub says are waiting (%d of %d)"
              % (c.get("graded", 0), sum(named), len(named)), bool(named) and all(named))
    else:
        check("with nobody waiting, the answer says so rather than inventing someone",
              bool(c.get("says_none")))
    check("no L3 (private) person is named", c.get("l3_named", 0) == 0)
    return lines, EX_FAIL if fail else EX_PASS


# --------------------------------------------------------------------------
# moment 7: "catch me up" morning brief
# --------------------------------------------------------------------------

OWNER_PROMISE = "Post the walk-probe budget sheet to Philip Coe"
OTHER_PROMISE = "Thomas will share the walk-probe venue list"
SEED_NS = "urn:ostler-walk-fixture:wow7"


def seed_sparql():
    return ("INSERT DATA {\n"
            "<%s/todo-owner> a <urn:ostler:OutstandingTodo> ; <urn:ostler:todoText> \"%s\" ;"
            " <urn:ostler:owner> \"user\" ; <urn:ostler:status> \"open\" ; <urn:ostler:deadline> \"2030-01-31\" ;"
            " <urn:ostler:todoCreatedAt> \"2030-01-01T09:00:00Z\" .\n"
            "<%s/todo-other> a <urn:ostler:OutstandingTodo> ; <urn:ostler:todoText> \"%s\" ;"
            " <urn:ostler:owner> \"other\" ; <urn:ostler:status> \"open\" ;"
            " <urn:ostler:todoCreatedAt> \"2030-01-01T09:00:00Z\" .\n}"
            % (SEED_NS, OWNER_PROMISE, SEED_NS, OTHER_PROMISE))


def forget_sparql():
    return ('DELETE { ?s ?p ?o } WHERE { ?s ?p ?o . FILTER(STRSTARTS(STR(?s), "%s")) }' % SEED_NS)


def _morning_prompt():
    path = os.path.join(OSTLER, "assistant-config", "config.toml")
    raw = _read(path)
    if not raw:
        return None
    try:
        import tomllib
        data = tomllib.loads(raw)
        for j in (data.get("cron") or {}).get("jobs") or []:
            if isinstance(j, dict) and j.get("id") == "morning-brief":
                return j.get("prompt")
        return None
    except ImportError:
        m = re.search(r'id\s*=\s*"morning-brief".*?prompt\s*=\s*"((?:[^"\\]|\\.)*)"', raw, re.S)
        return json.loads('"%s"' % m.group(1)) if m else None
    except Exception:
        return None


def box_morning(wait_s=600):
    out = {}
    prompt = _morning_prompt()
    if not prompt:
        out["cannot"] = "no morning-brief job in ~/.ostler/assistant-config/config.toml (no brief channel was set up)"
        return out
    out["prompt_covers_today"] = "today" in prompt.lower() and "promise" in prompt.lower()
    st = _store_update(forget_sparql())
    st = _store_update(seed_sparql())
    if st not in (200, 204):
        out["cannot"] = "the synthetic promises could not be seeded into the store (HTTP %s)" % st
        return out
    admin = _secret("zeroclaw_admin_token")
    auth = {"Authorization": "Bearer " + admin} if admin else {}
    job_id = None
    try:
        code, body = _hub("/api/v1/commitments?owner=user&status=open")
        seeded_visible = code == 200 and any(OWNER_PROMISE == (c.get("action") or "")
                                             for c in (body or {}).get("commitments") or [])
        if not seeded_visible:
            out["cannot"] = "the seeded promise is not served by /api/v1/commitments (HTTP %s); harness, not product" % code
            return out
        rcode, rbody = _hub("/api/v1/reply-debt")
        rd = rbody if rcode == 200 and isinstance(rbody, dict) and not rbody.get("degraded") else None
        reply_names = [d.get("person_name") for d in (rd or {}).get("debts") or []
                       if d.get("person_name") and not _withheld(d.get("privacy_level"))][:GRADED_MAX]
        ccode, cbody = _hub("/api/v1/calendar/today")
        meetings = [(e.get("title") or e.get("summary") or "").strip()
                    for e in ((cbody or {}).get("events") or []) if ccode == 200
                    and not _withheld(e.get("privacy_level") or e.get("level"))]
        meetings = [m for m in meetings if m][:GRADED_MAX]
        # One-shot copy of the job, no delivery, a minute or two out in the
        # box's local time (a tz-less cron expr is local in the daemon).
        t = time.localtime(time.time() + 90)
        expr = "%d %d %d %d *" % (t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon)
        code, body = _http("POST", GATEWAY + "/api/cron", body={
            "name": "morning-brief-walk-probe", "schedule": expr, "job_type": "agent",
            "prompt": prompt, "session_target": "isolated", "delete_after_run": False}, headers=auth)
        job_id = ((body or {}).get("job") or {}).get("id")
        if code != 200 or not job_id:
            out["cannot"] = "could not add the probe's copy of the morning brief job (HTTP %s)" % code
            return out
        text, deadline = None, time.time() + wait_s
        while time.time() < deadline:
            time.sleep(10)
            code, runs = _http("GET", GATEWAY + "/api/cron/%s/runs" % job_id, headers=auth)
            rows = runs if isinstance(runs, list) else (runs or {}).get("runs") or []
            if rows:
                text = rows[0].get("output") or ""
                out["run_status"] = rows[0].get("status")
                break
        if text is None:
            out["cannot"] = "the probe's morning brief did not run within %ds" % wait_s
            return out
        out["answered"] = bool(text.strip())
        out["owner_promise"] = "walk-probe budget sheet" in text.lower()
        out["other_promise"] = "walk-probe venue list" in text.lower()
        out["reply_graded"] = len(reply_names)
        out["reply_named"] = [_named(text, n) for n in reply_names]
        out["reply_source"] = "ok" if rd is not None else "unavailable"
        out["meetings_graded"] = len(meetings)
        out["meetings_named"] = [all(w in text.lower() for w in re.findall(r"[\w']{3,}", m.lower())[:4])
                                 for m in meetings]
    finally:
        if job_id:
            _http("DELETE", GATEWAY + "/api/cron/%s" % job_id, headers=auth)
        _store_update(forget_sparql())
    return out


def judge_morning(c):
    lines, fail = [], False

    def check(label, ok):
        nonlocal fail
        lines.append(("  ok     " if ok else "  FAIL   ") + label)
        fail |= not ok

    if c.get("cannot"):
        return ["  CANNOT " + c["cannot"]], EX_CANNOT
    check("the shipped morning-brief prompt covers today and promises", c.get("prompt_covers_today", False))
    check("the brief was written (run status %s)" % c.get("run_status"), c.get("answered", False))
    check("the brief names the owner's open promise", c.get("owner_promise", False))
    check("the brief does NOT present a promise someone else owes as the owner's", not c.get("other_promise", True))
    rn = c.get("reply_named") or []
    if c.get("reply_graded", 0):
        check("the brief names who is waiting on a reply (%d of %d)" % (sum(rn), len(rn)), all(rn))
    else:
        lines.append("  note   no reply debt on this box to grade (source %s)" % c.get("reply_source"))
    mn = c.get("meetings_named") or []
    if c.get("meetings_graded", 0):
        check("the brief names today's meetings (%d of %d)" % (sum(mn), len(mn)), all(mn))
    else:
        lines.append("  note   no meetings today on this box to grade")
    return lines, EX_FAIL if fail else EX_PASS


# --------------------------------------------------------------------------

def self_test():
    ok = True
    rd_good = {"endpoint": 200, "degraded": False, "count": 2, "fields_ok": True, "tools": ["pwg_reply_debt"],
               "graded": 2, "named": [True, True], "l3_named": 0, "says_none": None, "answered": True}
    rd_mut = {
        "detector degraded (no Messages access)": dict(rd_good, degraded=True, reason="reply_debt_detector_unavailable"),
        "chat never called pwg_reply_debt": dict(rd_good, tools=["pwg_people"]),
        "chat left out someone who is waiting": dict(rd_good, named=[True, False]),
        "an L3 person was named": dict(rd_good, l3_named=1),
        "nobody waiting, chat invented someone": dict(rd_good, count=0, graded=0, named=[], says_none=False),
        "endpoint 500": {"endpoint": 500, "endpoint_error": "HTTP 500, unparseable"},
    }
    mb_good = {"prompt_covers_today": True, "answered": True, "run_status": "ok", "owner_promise": True,
               "other_promise": False, "reply_graded": 1, "reply_named": [True], "reply_source": "ok",
               "meetings_graded": 1, "meetings_named": [True]}
    mb_mut = {
        "prompt still only about yesterday": dict(mb_good, prompt_covers_today=False),
        "owner's promise missing": dict(mb_good, owner_promise=False),
        "someone else's promise presented as the owner's": dict(mb_good, other_promise=True),
        "a reply owed left out": dict(mb_good, reply_named=[False]),
        "today's meeting left out": dict(mb_good, meetings_named=[False]),
        "empty brief": dict(mb_good, answered=False),
    }
    for name, judge, good, muts in (("reply debt", judge_reply_debt, rd_good, rd_mut),
                                    ("morning brief", judge_morning, mb_good, mb_mut)):
        _, rc = judge(good)
        print("  %s  %s: the good capture passes" % ("ok   " if rc == EX_PASS else "FAIL ", name))
        ok &= rc == EX_PASS
        for mname, m in muts.items():
            _, rc = judge(m)
            print("  %s  %s mutant rejected: %s" % ("ok   " if rc == EX_FAIL else "FAIL ", name, mname))
            ok &= rc == EX_FAIL
        _, rc = judge({"cannot": "no box"})
        print("  %s  %s: a missing prerequisite is CANNOT-RUN" % ("ok   " if rc == EX_CANNOT else "FAIL ", name))
        ok &= rc == EX_CANNOT
    print("%s" % ("every mutant went red" if ok else "SELF-TEST BROKEN"))
    return 0 if ok else 1


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 2 and argv[1] == "reply-debt-box":
        print(json.dumps(box_reply_debt()))
        return 0
    if len(argv) >= 2 and argv[1] == "morning-box":
        print(json.dumps(box_morning()))
        return 0
    if len(argv) >= 3 and argv[1] in ("judge-reply-debt", "judge-morning"):
        c = json.load(open(argv[2]))
        lines, rc = (judge_reply_debt if argv[1] == "judge-reply-debt" else judge_morning)(c)
        print("\n".join(lines))
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
