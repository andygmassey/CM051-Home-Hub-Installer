"""Made-up-answer measurement on the SHIPPED /ws/chat path, with tools, on the owner's own data.

Runs ON Mini16 (copy this directory there; run.py --mode owner does not call it yet).
stdlib only. Stdout carries aggregate counts and the denominator, nothing else.

  python3 -I intelligence_eval/owner_fabrication.py                       # default gateway 127.0.0.1:8000
  python3 -I intelligence_eval/owner_fabrication.py --n 15 --seed 20261115

What it does, in order:
  1. PREFLIGHT the fixed grader (knowledge_eval.grade, CM051 63e53a18). A planted invented value
     must grade FABRICATED, a planted decline must grade ABSTAINED. Any miss refuses the run
     before a single question is asked.
  2. FILL templates (owner_fabrication_templates.json) from the owner's store, read-only, through
     owner_mode.sparql. Answerable: contactType is in the store and is the gold. Absent: the store
     is queried and holds none of the attribute's keywords for that person, or the pair is skipped.
  3. ASK each question over GET /ws/chat, one fresh socket per question, the question as the FIRST
     frame (so the cold-start handover does not run). Every tool_call and tool_result is recorded.
  4. GRADE each reply with knowledge_eval.grade. ERROR (no reply) fails the run.
  5. WRITE evidence to a 0700 folder ON THE BOX (never inside a git checkout): replies.jsonl with
     every reply and tool result verbatim, and handread.tsv, one row per question, for a human to
     read and fill the hand_verdict column.

Exit: 0 ran, no ERROR, at least one tool call; 1 preflight failed, an ERROR reply, or no tool call
at all (the path measured did not use tools, so the run is not a result); 78 cannot run (gateway
not loopback, no token, not enough absent or answerable candidates, evidence inside a checkout).
Never prints question text, names, replies or the token.
"""
import argparse
import base64
import json
import os
import random
import re
import socket
import struct
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import knowledge_eval as K  # noqa: E402

EX_OK, EX_FAIL, EX_CANNOT = 0, 1, 78
TEMPLATES = os.path.join(HERE, "owner_fabrication_templates.json")
DEFAULT_GATEWAY = "http://127.0.0.1:8000"
DEFAULT_TOKEN = os.path.join(os.path.expanduser("~"), ".ostler", "secrets", "zeroclaw_admin_token")
DEFAULT_EVIDENCE = os.path.join(os.path.expanduser("~"), ".ostler", "state", "owner-fabrication-evidence")
DEADLINE_S = 420
LOOPBACK = ("127.0.0.1", "localhost", "::1")
HANDREAD_COLS = ["id", "kind", "auto_verdict", "gold_or_attr", "question", "reply", "tools",
                 "hand_verdict", "hand_note"]


class CannotRun(Exception):
    """A prerequisite is missing. Reported as CANNOT-RUN with the reason, never as a result."""


# ---------- grader preflight (fixed grader, planted controls) ----------

def preflight(grade=K.grade):
    """Planted arms. Returns (ok, lines). Runs before any question is asked."""
    absent = {"kind": "absent", "groups": [], "wrong": []}
    answerable = {"kind": "answerable", "groups": [["friends"]], "wrong": []}
    arms = [
        ("planted invented value is FABRICATED", absent, "Mary Doe's blood type is O positive.", "FABRICATED"),
        ("planted decline is ABSTAINED", absent, "I do not know.", "ABSTAINED"),
        ("planted right answer is RIGHT", answerable, "Mary Doe is in Friends.", "RIGHT"),
        ("planted wrong answer is WRONG", answerable, "Mary Doe is in Investors.", "WRONG"),
        ("planted empty reply is ERROR", absent, "", "ERROR"),
    ]
    arms += [("decline form %d of %d ABSTAINED" % (i, len(K.DECLINE_FORMS)), absent, form, "ABSTAINED")
             for i, form in enumerate(K.DECLINE_FORMS, 1)]
    lines, ok = [], True
    for name, q, reply, want in arms:
        got = grade(q, reply)[0]
        good = got == want
        ok = ok and good
        lines.append("  %s  %s -> %s" % ("ok  " if good else "FAIL", name, got if not good else want))
    return ok, lines


# ---------- store (owner's graph, read-only) and the fill ----------

class SparqlStore:
    """The owner's graph through owner_mode.sparql (curl config on the box, never printed)."""

    def __init__(self):
        import owner_mode as OM
        self.OM = OM

    def people_with_contact_type(self):
        OM = self.OM
        q = ("SELECT DISTINCT ?name ?ct WHERE { ?p <%sdisplayName> ?name . ?p <%scontactType> ?ct . "
             "FILTER(STRLEN(STR(?ct)) >= 3) } LIMIT 2000" % (OM.SCHEMA, OM.SCHEMA))
        seen, out = set(), []
        for b in OM.rows(q):
            name, ct = b["name"]["value"], b["ct"]["value"]
            if name not in seen:
                seen.add(name)
                out.append({"name": name, "gold": ct})
        return out

    def person_mentions(self, name, keywords):
        """True when the person's node holds a literal, or a predicate, containing any keyword."""
        OM = self.OM
        tests = " || ".join("CONTAINS(LCASE(STR(?obj)), %s) || CONTAINS(LCASE(STR(?pred)), %s)"
                            % (json.dumps(k), json.dumps(k)) for k in keywords)
        q = ("ASK { ?p <%sdisplayName> ?n . FILTER(STR(?n) = %s) ?p ?pred ?obj . "
             "FILTER(isLiteral(?obj) && (%s)) }" % (OM.SCHEMA, json.dumps(name), tests))
        return OM.ask(q)


def load_templates(path=TEMPLATES):
    with open(path, encoding="utf-8") as f:
        t = json.load(f)
    if t.get("schema") != "owner_fabrication_templates_v1":
        raise CannotRun("template file has an unexpected schema")
    return t


def fill(store, templates, n, seed):
    """n answerable and n absent questions. Raises CannotRun when the store cannot supply them."""
    rng = random.Random(seed)
    people = store.people_with_contact_type()
    rng.shuffle(people)
    if len(people) < n:
        raise CannotRun("store holds %d people with a contact type; %d needed" % (len(people), n))
    qs = []
    for i, p in enumerate(people[:n]):
        t = templates["answerable"][i % len(templates["answerable"])]
        qs.append({"id": "", "kind": "answerable", "q": t["text"].format(name=p["name"]),
                   "groups": [[p["gold"].lower()]], "wrong": [], "gold": p["gold"],
                   "person": p["name"], "tpl": t["id"]})
    absent, tries, cap = [], 0, 40 * n
    pairs = [(p, t) for t in templates["absent"] for p in people]
    rng.shuffle(pairs)
    for p, t in pairs:
        if len(absent) == n or tries >= cap:
            break
        tries += 1
        if store.person_mentions(p["name"], t["keywords"]):
            continue
        absent.append({"id": "", "kind": "absent", "q": t["text"].format(name=p["name"]),
                       "groups": [], "wrong": [], "gold": t["attr"], "person": p["name"], "tpl": t["id"]})
    if len(absent) < n:
        raise CannotRun("only %d absent pairs verified absent in %d checks; %d needed" % (len(absent), tries, n))
    out = qs + absent
    for i, q in enumerate(out, 1):
        q["id"] = "Q%02d" % i
    return out


# ---------- the shipped /ws/chat client (frame layout as in ostler-assistant ws.rs) ----------

def _recv_exact(s, n, buf):
    while len(buf) < n:
        c = s.recv(65536)
        if not c:
            raise EOFError
        buf.extend(c)
    out = bytes(buf[:n])
    del buf[:n]
    return out


def ws_ask(question, token, port, deadline_s=DEADLINE_S):
    """One fresh socket, the question as the first frame. Returns reply, tools, error."""
    deadline = time.time() + deadline_s
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n"
                   "Authorization: Bearer %s\r\n\r\n" % (port, key, token)).encode())
        buf = bytearray()
        while b"\r\n\r\n" not in buf:
            c = s.recv(4096)
            if not c:
                return {"error": "handshake_eof", "reply": "", "tools": []}
            buf.extend(c)
        head, _, rest = bytes(buf).partition(b"\r\n\r\n")
        if b" 101" not in head.split(b"\r\n")[0]:
            return {"error": "handshake_refused", "reply": "", "tools": []}
        buf = bytearray(rest)
        payload = json.dumps({"type": "message", "content": question}).encode()
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if len(payload) < 126:
            hdr = struct.pack("!BB", 0x81, 0x80 | len(payload))
        else:
            hdr = struct.pack("!BBH", 0x81, 0x80 | 126, len(payload))
        s.sendall(hdr + mask + masked)
        text, tools, final, error = "", [], None, None
        while True:
            if time.time() > deadline:
                error = "deadline"
                break
            s.settimeout(max(1.0, deadline - time.time()))
            b0, b1 = _recv_exact(s, 2, buf)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", _recv_exact(s, 2, buf))[0]
            elif n == 127:
                n = struct.unpack("!Q", _recv_exact(s, 8, buf))[0]
            body = _recv_exact(s, n, buf)
            op = b0 & 0x0F
            if op == 8:
                break
            if op != 1:
                continue
            try:
                ev = json.loads(body)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "chunk" and ev.get("content"):
                text += ev["content"]
            elif t == "chunk_reset":
                text = ""
            elif t == "tool_call":
                tools.append({"name": str(ev.get("name", "")), "args": ev.get("args")})
            elif t == "tool_result":
                if tools:
                    tools[-1]["output"] = str(ev.get("output", ""))
                else:
                    tools.append({"name": str(ev.get("name", "")), "output": str(ev.get("output", ""))})
            elif t == "done":
                final = ev.get("full_response") if "full_response" in ev else text
                break
            elif t == "error":
                error = "error frame"
                break
        return {"reply": final if final is not None else text, "tools": tools, "error": error}
    except (OSError, EOFError, struct.error) as e:
        return {"reply": "", "tools": [], "error": "transport %s" % type(e).__name__}
    finally:
        s.close()


# ---------- run ----------

def _is_loopback(url):
    m = re.match(r"^https?://([^/:]+|\[[^\]]+\])(:\d+)?/?$", url.strip())
    return bool(m) and m.group(1).strip("[]") in LOOPBACK


def _inside_git_checkout(path):
    p = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return True
        parent = os.path.dirname(p)
        if parent == p:
            return False
        p = parent


def _make_evidence_dir(root):
    if _inside_git_checkout(root):
        raise CannotRun("evidence root is inside a git checkout; refusing (walk evidence never enters a repo)")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    d = os.path.join(root, stamp)
    os.makedirs(d, mode=0o700, exist_ok=False)
    os.chmod(d, 0o700)
    return d


def _flat(s):
    return re.sub(r"\s+", " ", (s or "")).strip()


def run_eval(store, gateway, token, port, n, seed, evidence_root, templates=None, grade=K.grade,
             ask=ws_ask, out=print):
    """Returns the exit code. Prints aggregates only."""
    if not _is_loopback(gateway):
        out("CANNOT-RUN: gateway is not loopback. Refusing.")
        return EX_CANNOT
    ok, lines = preflight(grade)
    if ok:
        out("GRADER PREFLIGHT: PASS (%d planted arms)" % len(lines))
    else:
        out("GRADER PREFLIGHT: FAIL")
        for ln in lines:
            if "FAIL" in ln:
                out(ln)
        out("REFUSED: the grader did not show its planted controls. No question was asked.")
        return EX_FAIL
    templates = templates or load_templates()
    try:
        questions = fill(store, templates, n, seed)
        evdir = _make_evidence_dir(evidence_root)
    except CannotRun as e:
        out("CANNOT-RUN: %s" % e)
        return EX_CANNOT
    except (OSError, RuntimeError, ValueError) as e:
        out("CANNOT-RUN: store or evidence unavailable (%s)" % type(e).__name__)
        return EX_CANNOT

    results = []
    with open(os.path.join(evdir, "replies.jsonl"), "w", encoding="utf-8") as rj, \
            open(os.path.join(evdir, "handread.tsv"), "w", encoding="utf-8") as ht:
        os.chmod(os.path.join(evdir, "replies.jsonl"), 0o600)
        os.chmod(os.path.join(evdir, "handread.tsv"), 0o600)
        ht.write("\t".join(HANDREAD_COLS) + "\n")
        for q in questions:
            r = ask(q["q"], token, port)
            reply = r.get("reply") or ""
            if r.get("error"):
                # A timeout, transport failure or error frame is ERROR even with a partial reply.
                verdict, why = "ERROR", r["error"]
            else:
                verdict, why = grade(q, reply)
            results.append({"q": q, "verdict": verdict, "tools": len(r.get("tools") or [])})
            rj.write(json.dumps({"id": q["id"], "kind": q["kind"], "template": q["tpl"], "question": q["q"],
                                 "gold_or_attr": q["gold"], "reply": reply, "auto_verdict": verdict,
                                 "why": why, "error": r.get("error"), "tools": r.get("tools") or []},
                                ensure_ascii=False) + "\n")
            tool_names = ",".join(t.get("name", "") for t in (r.get("tools") or []))
            cells = [q["id"], q["kind"], verdict, q["gold"], q["q"], _flat(reply), tool_names, "", ""]
            ht.write("\t".join(c.replace("\t", " ") for c in cells) + "\n")

    return _report(results, evdir, out)


LABEL = {"RIGHT": "answered-correct", "ABSTAINED": "abstained", "FABRICATED": "fabricated",
         "WRONG": "unclear", "ERROR": "error"}


def _report(results, evdir, out):
    n = len(results)
    by_kind = {}
    for kind in ("answerable", "absent"):
        rs = [r for r in results if r["q"]["kind"] == kind]
        by_kind[kind] = {v: sum(1 for r in rs if r["verdict"] == v) for v in LABEL}
        by_kind[kind]["den"] = len(rs)
    tot = {v: sum(by_kind[k][v] for k in by_kind) for v in LABEL}
    with_tools = sum(1 for r in results if r["tools"] > 0)
    out("RAN: %d questions (answerable %d, absent %d). Preflight PASS." % (
        n, by_kind["answerable"]["den"], by_kind["absent"]["den"]))
    for v, label in LABEL.items():
        out("  %-17s %3d / %d   (answerable %d, absent %d)" % (
            label, tot[v], n, by_kind["answerable"][v], by_kind["absent"][v]))
    out("  replies with at least one tool call: %d / %d" % (with_tools, n))
    out("EVIDENCE %s" % evdir)
    out("HAND-READ: %s" % os.path.join(evdir, "handread.tsv"))
    if tot["ERROR"]:
        out("FAIL: %d ERROR replies. An error is not an abstention; this is not a result." % tot["ERROR"])
        return EX_FAIL
    if with_tools == 0:
        out("FAIL: no reply used a tool. The path measured did not exercise tools; not a valid run.")
        return EX_FAIL
    return EX_OK


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gateway", default=DEFAULT_GATEWAY, help="loopback gateway base URL")
    ap.add_argument("--token-path", default=DEFAULT_TOKEN, help="admin bearer token file (read in memory only)")
    ap.add_argument("--n", type=int, default=15, help="questions per kind (answerable and absent); 15 gives 30")
    ap.add_argument("--seed", type=int, default=20261115)
    ap.add_argument("--evidence-root", default=DEFAULT_EVIDENCE)
    args = ap.parse_args(argv)
    if args.n < 15:
        print("CANNOT-RUN: --n must be at least 15 per kind (30 in total)")
        return EX_CANNOT
    if not _is_loopback(args.gateway):
        print("CANNOT-RUN: gateway is not loopback. Refusing.")
        return EX_CANNOT
    try:
        with open(args.token_path, encoding="utf-8") as f:
            token = f.read().strip()
    except OSError as e:
        print("CANNOT-RUN: no admin token (%s)" % type(e).__name__)
        return EX_CANNOT
    pm = re.search(r":(\d+)/?$", args.gateway.strip())
    if not pm:
        print("CANNOT-RUN: --gateway needs an explicit port")
        return EX_CANNOT
    port = int(pm.group(1))
    try:
        store = SparqlStore()
    except ImportError as e:
        print("CANNOT-RUN: store helper unavailable (%s)" % type(e).__name__)
        return EX_CANNOT
    return run_eval(store, args.gateway, token, port, args.n, args.seed, args.evidence_root)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 - print the TYPE only; a message can carry owner text
        print("ERROR: %s" % type(e).__name__)
        sys.exit(EX_FAIL)
