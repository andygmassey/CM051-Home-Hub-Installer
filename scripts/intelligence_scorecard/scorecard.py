#!/usr/bin/env python3
"""scorecard.py -- the Ostler intelligence scorecard runner (stdlib only, Python 3.9+).

QUESTION: is the assistant up to the bar on the things a tester felt it failed
at (keeping an instruction, knowing the current state, not repeating itself,
recalling what is on file, refusing to invent, not re-importing, multi-step)?
Answered with a number per scenario, not a feeling.

    python3 scorecard.py --self-test                       stub Hub, every mode, no box
    python3 scorecard.py --driver stub:correct             one stub mode, printed
    python3 scorecard.py --driver live --model qwen3.5:9b  a real Hub (ON THE BOX ONLY)
    python3 scorecard.py --list                            the scenario table

VERDICTS (CANNOT-RUN is never PASS)
  PASS    every hard check ran and held, and every control held.
  FAIL    a hard check ran and the Hub did not do the thing.
  CANNOT  a precondition could not be made or read back (no seed writer, no
          token, no import dir, model mismatch, transport), a control did not
          hold (so the predicate proves nothing), or no check was examined.

PRIVACY. On the live box the replies can carry real graph content. stdout
carries verdicts, check ids, tool names and lengths only. Verbatim replies go to
an owner-only evidence directory outside any git checkout, as the owner-score
probe does. A live run refuses to start unless the box is declared synthetic
(~/.ostler/state/synthetic-box) and the gateway is loopback.

Reuses (not reinvented): scripts/box_walk_probes/lib/wow_moments.py for the Hub
and store helpers, the one-shot morning-brief job and the secrets reader;
scripts/box_walk_probes/lib/assistant_chat.py for config and the model name;
the seed routes documented in OS003 gates/seed/README.md.
"""
import argparse
import base64
import datetime
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "box_walk_probes", "lib"))
import scenarios as SC  # noqa: E402

PASS, FAIL, CANNOT = "PASS", "FAIL", "CANNOT"
EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
TAGS = ("PLUMBING", "REASONING")


class Cannot(Exception):
    """A precondition or a transport failure: the scenario did not run."""


# ---------------------------------------------------------------------------
# Transcript and checks
# ---------------------------------------------------------------------------

def new_transcript():
    return {"turn": {}, "brief": {}, "read": {}, "import": {}}


def _hits(text, words):
    low = (text or "").lower()
    return [i for i, w in enumerate(words) if w.lower() in low]


def _rec(T, bucket, key):
    if key not in T[bucket]:
        raise Cannot("step %r did not run, so its check cannot be graded" % key)
    return T[bucket][key]


def _line_near(text, needle, words):
    """(needle_lines, near_lines): lines carrying the needle, and those that also carry a word."""
    lines = [ln for ln in (text or "").splitlines() if needle.lower() in ln.lower()]
    near = [ln for ln in lines if _hits(ln, words)]
    return lines, near


def evaluate(check, T):
    """-> (status, detail). status is "ok", "fail" or "cannot". Never reads a reply aloud."""
    k = check["kind"]
    if k in ("reply_has", "reply_has_at_least", "reply_lacks", "reply_lacks_regex",
             "reply_no_question", "reply_is_question", "tool_used", "tool_unused"):
        rec = _rec(T, "turn", check["turn"])
        if rec.get("error") == "transport":
            raise Cannot("the turn %r never reached the assistant" % check["turn"])
        text = rec.get("text") or ""
        if k == "reply_has":
            h = _hits(text, check["any"])
            return ("ok", "needle#%d" % (h[0] + 1)) if h else ("fail", "no expected wording (%s)" % (
                "empty reply" if not text.strip() else "reply %d chars" % len(text)))
        if k == "reply_has_at_least":
            h = _hits(text, check["any"])
            return ("ok" if len(h) >= check["n"] else "fail", "%d of %d needles" % (len(h), check["n"]))
        if k == "reply_lacks":
            h = _hits(text, check["none"])
            return ("fail", "forbidden wording needle#%d" % (h[0] + 1)) if h else ("ok", "none present")
        if k == "reply_lacks_regex":
            m = re.search(check["pattern"], text, re.I)
            return ("fail", "forbidden pattern matched at offset %d" % m.start()) if m else ("ok", "no match")
        if k == "reply_no_question":
            asks = "?" in text or re.search(r"\b(which|what do you want|what would you like|do you want|should i)\b",
                                            text, re.I)
            if not text.strip():
                return ("fail", "empty reply")
            return ("fail", "asked a clarifying question") if asks else ("ok", "no question")
        if k == "reply_is_question":
            asks = "?" in text or re.search(r"\bwhich\b", text, re.I)
            return ("ok", "asked which one") if asks else ("fail", "did not ask which one")
        names = [str(t).lower() for t in (rec.get("tools") or [])]
        hit = [s for s in check["any"] if any(s.lower() in n for n in names)]
        if k == "tool_used":
            return ("ok", "tool %d call(s) matched" % len(hit)) if hit else (
                "fail", "no matching tool (ran: %s)" % (", ".join(sorted(set(names))) or "none"))
        return ("fail", "forbidden tool ran") if hit else ("ok", "no forbidden tool")
    if k in ("brief_has", "brief_lacks", "brief_lacks_near", "brief_has_near", "brief_min_chars",
             "brief_count_max"):
        text = _rec(T, "brief", check["brief"])
        if k == "brief_has":
            h = _hits(text, check["any"])
            return ("ok", "needle#%d" % (h[0] + 1)) if h else ("fail", "expected item absent")
        if k == "brief_lacks":
            h = _hits(text, check["none"])
            return ("fail", "forbidden item needle#%d" % (h[0] + 1)) if h else ("ok", "none present")
        if k == "brief_min_chars":
            n = len((text or "").strip())
            return ("ok" if n >= check["n"] else "fail", "%d chars" % n)
        if k == "brief_count_max":
            n = (text or "").lower().count(check["needle"].lower())
            return ("ok" if n <= check["n"] else "fail", "%d occurrence(s), allowed %d" % (n, check["n"]))
        lines, near = _line_near(text, check["needle"], check["words"])
        if k == "brief_lacks_near":
            return ("fail", "a line names it with a request word") if near else (
                "ok", "%d line(s) name it, none asks" % len(lines))
        return ("ok", "a line names it with a request word") if near else ("fail", "no line names it as a request")
    if k in ("read_has", "read_lacks", "read_rows_min", "read_rows_equal"):
        if k == "read_rows_equal":
            a, b = _rec(T, "read", check["a"]), _rec(T, "read", check["b"])
            for r in (a, b):
                if not r.get("ok") or r.get("rows") is None:
                    raise Cannot("read route did not answer (status %s)" % r.get("status"))
            return ("ok" if a["rows"] == b["rows"] else "fail", "rows %s then %s" % (a["rows"], b["rows"]))
        r = _rec(T, "read", check["read"])
        if not r.get("ok"):
            raise Cannot("read route did not answer (status %s)" % r.get("status"))
        if k == "read_rows_min":
            return ("ok" if (r.get("rows") or 0) >= check["n"] else "fail", "%s rows" % r.get("rows"))
        if k == "read_has":
            h = _hits(r.get("text"), check["any"])
            return ("ok", "needle#%d" % (h[0] + 1)) if h else ("fail", "expected entry absent")
        h = _hits(r.get("text"), check["none"])
        return ("fail", "forbidden entry needle#%d" % (h[0] + 1)) if h else ("ok", "none present")
    raise ValueError("unknown check kind %r" % k)


def verdict(scenario, T, results):
    """results: list of (check, status, detail, cannot_reason_or_None). Pure: no I/O."""
    hard_fail = [c for c, st, _d, _r in results if st == "fail" and not c.get("control")]
    cannot = [(c, r) for c, st, _d, r in results if st == "cannot"]
    ctrl_fail = [c for c, st, _d, _r in results if st == "fail" and c.get("control")]
    examined = sum(1 for _c, st, _d, _r in results if st in ("ok", "fail"))
    if hard_fail:
        return FAIL, "failed: " + ", ".join(c["id"] for c in hard_fail)
    if cannot:
        return CANNOT, cannot[0][1]
    if ctrl_fail:
        return CANNOT, ("control %s did not hold, so the predicate proves nothing"
                        % ", ".join(c["id"] for c in ctrl_fail))
    if examined == 0:
        return CANNOT, "no check was examined (no denominator, so no verdict)"
    return PASS, "%d of %d checks examined and held" % (examined, len(results))


# ---------------------------------------------------------------------------
# Scenario execution (driver-agnostic)
# ---------------------------------------------------------------------------

def run_scenario(sc, driver):
    T = new_transcript()
    driver.begin(sc["id"])
    try:
        for step in sc["steps"]:
            op = step["op"]
            if op == "seed":
                ok, why = driver.seed(step["name"], SC.SEEDS[step["name"]])
                if not ok:
                    raise Cannot("seed %s: %s" % (step["name"], why))
            elif op == "say":
                r = driver.say(step["key"], step["session"], step["text"])
                T["turn"][step["key"]] = r
            elif op == "tick":
                driver.tick(step["kind"])
            elif op == "brief":
                r = driver.brief(step["key"])
                T["brief"][step["key"]] = r.get("text") or ""
            elif op == "read":
                T["read"][step["key"]] = driver.read(step["key"], step["path"])
            elif op == "import_file":
                ok, why = driver.import_file(step["key"])
                if not ok:
                    raise Cannot("import: %s" % why)
                T["import"][step["key"]] = True
            else:
                raise ValueError("unknown step op %r" % op)
    except (Cannot, OSError) as e:
        # OSError is a transport failure that reached the driver unwrapped: still no reply, so CANNOT.
        return {"id": sc["id"], "tag": sc["tag"], "group": sc["group"], "title": sc["title"],
                "verdict": CANNOT, "why": str(e), "checks": []}
    except Exception as e:  # a harness bug must not crash the suite, and must never read as PASS
        return {"id": sc["id"], "tag": sc["tag"], "group": sc["group"], "title": sc["title"],
                "verdict": CANNOT, "why": "harness error (%s): %s" % (type(e).__name__, str(e)[:120]),
                "checks": []}
    # An assistant that gave NOTHING is a product failure, whatever the checks say.
    # Only a transport failure is a harness fault, and that never reaches here.
    empty = sorted(k for k, r in T["turn"].items() if not (r.get("text") or "").strip()
                   and r.get("error") != "transport")
    empty += sorted("brief:" + k for k, t in T["brief"].items() if not (t or "").strip())
    results = []
    for c in sc["checks"]:
        try:
            st, detail = evaluate(c, T)
            results.append((c, st, detail, None))
        except Cannot as e:
            results.append((c, "cannot", str(e), str(e)))
    v, why = verdict(sc, T, results)
    if empty:
        v, why = FAIL, "empty answer from: " + ", ".join(empty)
    return {"id": sc["id"], "tag": sc["tag"], "group": sc["group"], "title": sc["title"], "verdict": v,
            "why": why,
            "checks": [{"id": c["id"], "kind": c["kind"], "control": bool(c.get("control")),
                        "status": st, "detail": d} for c, st, d, _r in results],
            "transcript": T}


def run_suite(driver, only=None):
    out = []
    for sc in SC.SCENARIOS:
        if only and sc["id"] not in only:
            continue
        out.append(run_scenario(sc, driver))
    return out


def totals(results):
    t = {tag: {PASS: 0, FAIL: 0, CANNOT: 0} for tag in TAGS}
    t["ALL"] = {PASS: 0, FAIL: 0, CANNOT: 0}
    for r in results:
        t[r["tag"]][r["verdict"]] += 1
        t["ALL"][r["verdict"]] += 1
    return t


def print_report(results, meta, out=sys.stdout):
    w = out.write
    w("intelligence scorecard  model=%s  size=%s  driver=%s  scenarios=%d\n"
      % (meta["model"], meta["size"], meta["driver"], len(results)))
    for r in results:
        w("%-6s %-4s [%s] %s\n" % (r["verdict"], r["id"], r["tag"], r["title"]))
        if r["verdict"] == CANNOT and not r["checks"]:
            w("         reason: %s\n" % r["why"])
        for c in r["checks"]:
            w("         %-6s %s%s: %s\n" % ({"ok": "ok", "fail": "FAIL", "cannot": "CANNOT"}[c["status"]],
                                             c["id"], " (control)" if c["control"] else "", c["detail"]))
        if r["verdict"] != PASS and r["checks"]:
            w("         why: %s\n" % r["why"])
    t = totals(results)
    w("\nTOTALS  (PASS / FAIL / CANNOT-RUN)\n")
    for tag in ("PLUMBING", "REASONING", "ALL"):
        w("  %-10s %3d / %3d / %3d\n" % (tag, t[tag][PASS], t[tag][FAIL], t[tag][CANNOT]))
    w("  PLUMBING = state, memory or context bug class. REASONING = model capability.\n")
    return t


# ---------------------------------------------------------------------------
# Live driver: runs ON THE BOX, against the installed Hub
# ---------------------------------------------------------------------------

class WsSession:
    """One /ws/chat session that keeps its context across messages. Framing is the
    same handshake and frame reader as scripts/owner_score/owner_score.py ask_traced,
    extended to hold the socket open for a conversation."""

    def __init__(self, gateway, token):
        port = int(gateway.rsplit(":", 1)[1])
        self.port, self.token, self.sock, self.rest = port, token, None, b""

    def open(self):
        self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET /ws/chat HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
                           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
                           "Sec-WebSocket-Protocol: zeroclaw.v1\r\nAuthorization: Bearer %s\r\n\r\n"
                           % (self.port, key, self.token)).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            c = self.sock.recv(4096)
            if not c:
                raise Cannot("websocket handshake closed")
            buf += c
        head, self.rest = buf.split(b"\r\n\r\n", 1)
        if b" 101" not in head.split(b"\r\n")[0]:
            raise Cannot("websocket handshake refused: %s" % head.split(b"\r\n")[0][:60].decode(errors="replace"))

    def _rd(self, n, deadline):
        o = b""
        while len(o) < n:
            if self.rest:
                t = self.rest[: n - len(o)]
                o, self.rest = o + t, self.rest[len(t):]
            else:
                self.sock.settimeout(max(1, deadline - time.time()))
                c = self.sock.recv(65536)
                if not c:
                    raise EOFError
                self.rest = c
        return o

    def _frame(self, deadline):
        b0, b1 = self._rd(2, deadline)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", self._rd(2, deadline))[0]
        elif n == 127:
            n = struct.unpack("!Q", self._rd(8, deadline))[0]
        return b0 & 0x0F, self._rd(n, deadline)

    def send(self, text, deadline_s=420):
        deadline = time.time() + deadline_s
        d = json.dumps({"type": "message", "content": text}).encode()
        m = os.urandom(4)
        mk = bytes(b ^ m[i % 4] for i, b in enumerate(d))
        hdr = struct.pack("!BB", 0x81, 0x80 | len(d)) if len(d) < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, len(d))
        self.sock.sendall(hdr + m + mk)
        text_out, tools, err = "", [], None
        while time.time() < deadline:
            try:
                op, pay = self._frame(deadline)
            except Exception:
                err = "timeout"
                break
            if op == 8:
                err = "closed"
                break
            if op != 1:
                continue
            try:
                ev = json.loads(pay)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "chunk":
                text_out += ev.get("content") or ""
            elif t == "chunk_reset":
                text_out = ""
            elif t == "tool_call":
                tools.append(ev.get("name") or "")
            elif t == "done":
                if "full_response" in ev:
                    text_out = ev.get("full_response") or ""
                break
            elif t == "error":
                err = "error frame"
                break
        return {"text": text_out, "tools": tools, "error": err}

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


class LiveDriver:
    def __init__(self, model, evidence_dir, daemon_label):
        import wow_moments as wm  # reused: Hub/store HTTP, secrets, one-shot morning brief job
        import assistant_chat as ac  # reused: config.toml reader (model, names)
        self.wm, self.ac = wm, ac
        self.model = model
        self.daemon_label = daemon_label
        self.evidence = os.path.join(evidence_dir, "replies.jsonl")
        self.sessions = {}
        self.uid = os.getuid()
        self.import_dir = os.environ.get("OSTLER_SCORECARD_IMPORT_DIR", "")
        self.scenario = None
        host = wm.GATEWAY.split("://", 1)[-1].split(":")[0]
        if host not in ("127.0.0.1", "localhost", "::1"):
            raise Cannot("gateway %r is not loopback; this runner never leaves the box" % host)
        cfg = ac._config() or {}
        if model and cfg.get("model") != model:
            raise Cannot("the box runs %r, not %r: refusing to score a model it is not running"
                         % (cfg.get("model"), model))
        self.token = open(ac.TOKEN_PATH).read().strip() if os.path.exists(ac.TOKEN_PATH) else ""
        if not self.token:
            raise Cannot("no admin token at the probe token path")

    def begin(self, sid):
        self.scenario = sid
        for s in self.sessions.values():
            s.close()
        self.sessions = {}

    def _log(self, key, rec):
        with open(self.evidence, "a", encoding="utf-8") as f:
            f.write(json.dumps({"scenario": self.scenario, "key": key, "rec": rec}) + "\n")

    def say(self, key, session, text):
        if session not in self.sessions:
            s = WsSession(self.wm.GATEWAY, self.token)
            try:
                s.open()
            except (OSError, Cannot) as e:
                raise Cannot("assistant unreachable: %s" % type(e).__name__)
            self.sessions[session] = s
        try:
            rec = self.sessions[session].send(text)
        except OSError:
            rec = {"text": "", "tools": [], "error": "transport"}
        self._log(key, rec)
        return rec

    def tick(self, kind):
        if kind not in ("restart", "day_boundary"):
            raise Cannot("unknown tick %r" % kind)
        for s in self.sessions.values():
            s.close()
        self.sessions = {}
        r = subprocess.run(["launchctl", "kickstart", "-k", "gui/%d/%s" % (self.uid, self.daemon_label)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise Cannot("launchctl kickstart failed: %s" % (r.stderr.strip()[:120] or r.returncode))
        deadline = time.time() + 180
        while time.time() < deadline:
            time.sleep(5)
            code, _b = self.wm._hub("/api/v1/commitments?owner=user&status=open")
            if code == 200:
                return
        raise Cannot("the Hub did not answer within 180 s of the restart")

    def brief(self, key):
        prompt = self.wm._morning_prompt()
        if not prompt:
            raise Cannot("no morning-brief job in config.toml")
        admin = self.wm._secret("zeroclaw_admin_token")
        auth = {"Authorization": "Bearer " + admin} if admin else {}
        t = time.localtime(time.time() + 90)
        expr = "%d %d %d %d *" % (t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon)
        code, body = self.wm._http("POST", self.wm.GATEWAY + "/api/cron", body={
            "name": "scorecard-brief", "schedule": expr, "job_type": "agent", "prompt": prompt,
            "session_target": "isolated", "delete_after_run": False}, headers=auth)
        job = ((body or {}).get("job") or {}).get("id")
        if code != 200 or not job:
            raise Cannot("could not add a one-shot copy of the brief job (HTTP %s)" % code)
        try:
            deadline = time.time() + 600
            while time.time() < deadline:
                time.sleep(10)
                _c, runs = self.wm._http("GET", self.wm.GATEWAY + "/api/cron/%s/runs" % job, headers=auth)
                rows = runs if isinstance(runs, list) else (runs or {}).get("runs") or []
                if rows:
                    text = rows[0].get("output") or ""
                    self._log(key, {"brief_chars": len(text)})
                    return {"text": text}
            raise Cannot("the brief did not run within 600 s")
        finally:
            self.wm._http("DELETE", self.wm.GATEWAY + "/api/cron/%s" % job, headers=auth)

    def read(self, key, path):
        code, body = self.wm._hub(path)
        rows = None
        if isinstance(body, list):
            rows = len(body)
        elif isinstance(body, dict):
            for k in ("commitments", "facts", "people", "preferences", "items", "rows"):
                if isinstance(body.get(k), list):
                    rows = len(body[k])
                    break
        text = json.dumps(body, default=str) if body is not None else ""
        return {"ok": code == 200, "status": code, "rows": rows, "text": text}

    def seed(self, name, spec):
        kind = spec["kind"]
        if kind == "person_fact" or kind == "person_fact_many":
            facts = spec.get("facts") or [spec["fact"]]
            tok = self.wm._secret("service_token", "PWG_SERVICE_TOKEN")
            if not tok:
                return False, "no service token: harness, not product"
            h = {"Authorization": "Bearer " + tok}
            for f in facts:
                code, _b = self.wm._http("POST", self.wm.HUB + "/api/v1/memory/assert", body={
                    "subject": spec["subject"], "fact_text": f, "asserted_via": "scorecard_seed"}, headers=h)
                if code not in (200, 201):
                    return False, "memory/assert answered %s" % code
            code, body = self.wm._http("GET", self.wm.HUB + "/api/v1/people/context?name=%s"
                                       % quote(spec["subject"]), headers=h)
            got = json.dumps(body or {}, default=str)
            missing = [f for f in facts if f not in got]
            return (not missing), ("readable" if not missing else "%d fact(s) not readable back" % len(missing))
        if kind == "todo":
            sparql = ('INSERT DATA { <urn:ostler-scorecard-seed:%s> a <urn:ostler:OutstandingTodo> ; '
                      '<urn:ostler:todoText> "%s" ; <urn:ostler:owner> "user" ; <urn:ostler:status> "open" ; '
                      '<urn:ostler:todoCreatedAt> "2030-01-01T09:00:00Z" . }' % (name, spec["text"]))
            if self.wm._store_update(sparql) not in (200, 204):
                return False, "store update refused"
            code, body = self.wm._hub("/api/v1/commitments?owner=user&status=open")
            ok = code == 200 and spec["text"] in json.dumps(body or {}, default=str)
            return ok, ("readable" if ok else "todo not readable on /api/v1/commitments")
        # No writer in this runner for these yet. Said plainly, never a pass.
        return False, ("no %s seed writer exists in this runner; NOT INSTRUMENTED (product gap or missing "
                       "seed, not a verdict on the assistant)" % kind)

    def import_file(self, key):
        if not self.import_dir or not os.path.isdir(self.import_dir):
            return False, "OSTLER_SCORECARD_IMPORT_DIR is not set to a directory on the box"
        path = os.path.join(self.import_dir, "Connections.csv")
        with open(path, "w", encoding="utf-8") as f:
            f.write("First Name,Last Name,URL,Email Address,Company,Position,Connected On\n"
                    "Jane,Sample,https://www.linkedin.com/in/jane-sample-fixture,jane@example.com,"
                    "harbour survey ltd,Surveyor,01 Jan 2030\n")
        self._log(key, {"wrote": "Connections.csv"})
        return True, ""

    def model_info(self):
        # Read the size from Ollama's HTTP API, never by calling an ollama binary:
        # check_no_bare_ollama.py forbids reaching Ollama by name on PATH.
        size = "NOT INSTRUMENTED"
        code, body = self.wm._http("GET", "http://127.0.0.1:11434/api/tags", timeout=10)
        for m in (body or {}).get("models") or []:
            if m.get("name") == self.model and isinstance(m.get("size"), int):
                size = "%.1f GB" % (m["size"] / 1e9)
        if code != 200:
            size = "NOT INSTRUMENTED (ollama /api/tags answered %s)" % code
        return {"model": self.model or "unknown", "size": size, "driver": "live"}

    def close(self):
        for s in self.sessions.values():
            s.close()
        # Remove the todo seeds this run wrote (one prefix, nothing else). Person
        # facts written through memory/assert have no removal route here: a box
        # that ran this is a throwaway, as the synthetic-box declaration says.
        try:
            self.wm._store_update('DELETE { ?s ?p ?o } WHERE { ?s ?p ?o . FILTER(STRSTARTS(STR(?s), '
                                  '"urn:ostler-scorecard-seed:")) }')
        except Exception as e:  # said aloud: a leftover seed is a defect in the next walk, not silence
            sys.stderr.write("WARNING: todo-seed cleanup did not run (%s); remove urn:ostler-scorecard-seed rows\n"
                             % type(e).__name__)


def live_preflight():
    home = os.path.expanduser("~")
    if not os.path.exists(os.path.join(home, ".ostler", "state", "synthetic-box")):
        raise Cannot("box is not declared synthetic (~/.ostler/state/synthetic-box); refusing to seed and score it")


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def make_driver(spec, args):
    if spec == "live":
        if not args.model:
            raise Cannot("a live run needs --model: the score is labelled with the model it was taken on")
        live_preflight()
        ev = args.evidence_dir or os.path.join(os.path.expanduser("~"), ".ostler", "state",
                                               "intelligence-scorecard", datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ"))
        if "/.git/" in ev or os.path.exists(os.path.join(ev, ".git")):
            raise Cannot("evidence directory is inside a git checkout")
        os.makedirs(ev, mode=0o700, exist_ok=True)
        print("EVIDENCE directory (verbatim replies, owner-only): %s" % ev)
        return LiveDriver(args.model or os.environ.get("OSTLER_SCORECARD_MODEL", ""), ev,
                          args.daemon_label), ev
    if spec.startswith("stub:"):
        import stub_hub
        return stub_hub.StubDriver(spec.split(":", 1)[1]), None
    raise Cannot("unknown driver %r" % spec)


def self_test():
    """Every stub mode, scored by the same engine. The suite must go red where it should."""
    import stub_hub
    ok = True
    problems = stub_hub.coverage_problems()
    print("  %s  every scenario step has a canned answer in every mode (%d problems)"
          % ("ok    " if not problems else "FAIL  ", len(problems)))
    for p in problems[:5]:
        print("          " + p)
    ok &= not problems

    ids = [s["id"] for s in SC.SCENARIOS]
    print("  %s  %d scenarios, unique ids, tags PLUMBING or REASONING only"
          % ("ok    " if len(ids) == len(set(ids)) and all(s["tag"] in TAGS for s in SC.SCENARIOS) else "FAIL  ",
             len(ids)))
    ok &= len(ids) == len(set(ids)) and all(s["tag"] in TAGS for s in SC.SCENARIOS)

    expect = {
        "correct": lambda t: t[PASS] == len(SC.SCENARIOS),
        "dumb": lambda t: t[FAIL] >= 3,
        "cold": lambda t: t[CANNOT] >= 5 and t[PASS] < len(SC.SCENARIOS),
        "silent": lambda t: t[PASS] == 0,
        "transport": lambda t: t[PASS] == 0 and t[FAIL] == 0 and t[CANNOT] == len(SC.SCENARIOS),
    }
    counts = {}
    for mode, check in expect.items():
        res = run_suite(stub_hub.StubDriver(mode))
        t = totals(res)
        counts[mode] = t["ALL"]
        good = check(t["ALL"])
        ok &= good
        print("  %s  stub:%-9s PASS %2d  FAIL %2d  CANNOT %2d  (%s)"
              % ("ok    " if good else "FAIL  ", mode, t["ALL"][PASS], t["ALL"][FAIL], t["ALL"][CANNOT],
                 {"correct": "scripted-correct must be all green",
                  "dumb": "dumb stub must go red on at least 3",
                  "cold": "no seed writer: seeded scenarios CANNOT, never PASS",
                  "silent": "an empty assistant must never PASS",
                  "transport": "no reach: everything CANNOT, nothing FAIL or PASS"}[mode]))

    # Scorer units: each rule that makes a CANNOT or a FAIL must be able to fire.
    T = new_transcript()
    T["turn"]["a"] = {"text": "Plymouth", "tools": ["pwg_people"], "error": None}
    T["turn"]["b"] = {"text": "", "tools": [], "error": "transport"}
    units = [
        (evaluate({"kind": "reply_has", "turn": "a", "any": ["plymouth"]}, T)[0] == "ok", "reply_has matches"),
        (evaluate({"kind": "reply_has", "turn": "a", "any": ["derby"]}, T)[0] == "fail", "reply_has misses"),
        (evaluate({"kind": "tool_used", "turn": "a", "any": ["pwg_people"]}, T)[0] == "ok", "tool_used matches"),
        (evaluate({"kind": "reply_no_question", "turn": "a"}, T)[0] == "ok", "a flat reply is no question"),
    ]
    try:
        evaluate({"kind": "reply_has", "turn": "b", "any": ["x"]}, T)
        units.append((False, "transport turn must be CANNOT"))
    except Cannot:
        units.append((True, "transport turn is CANNOT, not FAIL"))
    try:
        evaluate({"kind": "brief_has", "brief": "never_ran", "any": ["x"]}, T)
        units.append((False, "a missing step must be CANNOT"))
    except Cannot:
        units.append((True, "a step that never ran is CANNOT"))
    ctrl = {"id": "c", "kind": "brief_has", "control": True}
    units.append((verdict({}, T, [(ctrl, "fail", "x", None)])[0] == CANNOT, "a failed control is CANNOT, not FAIL"))
    units.append((verdict({}, T, [({"id": "h", "kind": "reply_has"}, "ok", "x", None)])[0] == PASS,
                  "all-ok is PASS"))
    units.append((verdict({}, T, [])[0] == CANNOT, "zero examined checks is CANNOT"))
    units.append((verdict({}, T, [({"id": "h", "kind": "reply_has"}, "fail", "x", None)])[0] == FAIL,
                  "a hard fail is FAIL"))
    for good, label in units:
        print("  %s  scorer: %s" % ("ok    " if good else "FAIL  ", label))
        ok &= good

    print("SELF-TEST GREEN: the scorer goes red on the dumb stub and green on the scripted-correct one"
          if ok else "SELF-TEST RED: the scorer cannot tell the difference, do not trust a live number")
    return EX_PASS if ok else EX_FAIL


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--self-test", action="store_true", help="score the stub modes and check the scorer")
    ap.add_argument("--driver", default="stub:correct", help="live | stub:<correct|dumb|cold|silent|transport>")
    ap.add_argument("--model", default="", help="the model the box must be running (refused on mismatch)")
    ap.add_argument("--only", default="", help="comma-separated scenario ids")
    ap.add_argument("--json", default="", help="also write the scorecard as JSON to this path")
    ap.add_argument("--evidence-dir", default="", help="live: owner-only directory for verbatim replies")
    ap.add_argument("--daemon-label", default=os.environ.get("OSTLER_SCORECARD_DAEMON_LABEL", "ai.ostler.assistant"))
    ap.add_argument("--list", action="store_true", help="print the scenario table and exit")
    args = ap.parse_args(argv[1:])
    if args.list:
        for s in SC.SCENARIOS:
            print("%-4s %-10s %-14s %s" % (s["id"], s["tag"], s["group"], s["title"]))
        return EX_PASS
    if args.self_test:
        return self_test()
    only = set(x.strip() for x in args.only.split(",") if x.strip())
    try:
        driver, ev = make_driver(args.driver, args)
    except Cannot as e:
        print("CANNOT-RUN: %s" % e)
        return EX_CANNOT
    try:
        meta = driver.model_info()
        results = run_suite(driver, only or None)
    except Cannot as e:
        print("CANNOT-RUN: %s" % e)
        return EX_CANNOT
    finally:
        if hasattr(driver, "close"):
            driver.close()
    t = print_report(results, meta)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"meta": meta, "totals": t,
                       "scenarios": [{k: v for k, v in r.items() if k != "transcript"} for r in results]},
                      f, indent=2)
    if t["ALL"][FAIL]:
        return EX_FAIL
    if t["ALL"][CANNOT]:
        return EX_CANNOT
    return EX_PASS


if __name__ == "__main__":
    sys.exit(main(sys.argv))
