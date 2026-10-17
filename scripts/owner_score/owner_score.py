#!/usr/bin/env python3
"""Owner-knowledge score: ask the real Hub chat path N questions, grade, report.

Driven by scripts/owner_score.sh. Stdlib only (the installed Hub may carry a
3.9 system python; the DMG bundles 3.11). Nothing is uploaded: the only socket
this opens is to the loopback gateway, and a non-loopback --gateway is refused.

THE CHECK IS IMMUTABLE TO THE TUNING LOOP. Every run recomputes the sha256 of
the question files, grading.py and this runner, prints it, and refuses to score if it does
not equal CHECKSUM.lock. A custom questions file (the owner's real data) is
locked on first use in <file>.lock and verified on every later run.

EVIDENCE. Every live run keeps each reply VERBATIM and the tool calls behind it
(tool name, arguments, size of the result; never the result text) in an
evidence directory ON THE BOX (default ~/.ostler/state/owner-score-evidence/
<utc>, 0700, files 0600). That directory can hold real graph content, so it is
handled like walk evidence: it is never written inside a git checkout (the
runner refuses), never printed, and never goes into a repo or a PR. stdout
carries scores and ids only, unless --print-replies is passed.

HELD-BACK QUESTIONS. questions_heldout.jsonl is never read unless --set
heldout|all is passed. A tuning loop runs the default (--set visible). When the
held-back set is scored, only ids and the aggregate are printed for it, never
its questions, gold answers or the assistant's replies, so a loop that reads
this program's output learns nothing it could overfit to.
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import grading  # noqa: E402

CHECKED = ["questions_visible.jsonl", "questions_heldout.jsonl", "grading.py", "grading_legacy.py", "owner_score.py"]
LOCK = os.path.join(HERE, "CHECKSUM.lock")
TARGET = 70.0   # the agreed v1.0.108 "so what" target; see README for enforcement
EX_USAGE, EX_TAMPERED, EX_CANNOT_RUN, EX_BELOW = 2, 3, 78, 1


# ---------------------------------------------------------------- checksum --
def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def compute_lock(paths):
    rows = ["%s  %s" % (sha256_file(p), os.path.basename(p)) for p in paths]
    combined = hashlib.sha256(("\n".join(rows) + "\n").encode()).hexdigest()
    return rows, combined


def read_lock(path):
    rows, combined = [], None
    for line in open(path).read().splitlines():
        if line.startswith("COMBINED "):
            combined = line.split()[1]
        elif line.strip() and not line.startswith("#"):
            rows.append(line)
    return rows, combined


def write_lock(path, rows, combined):
    with open(path, "w") as f:
        f.write("# Owner-knowledge check lock. Regenerate only with `owner_score.sh --relock`\n"
                "# and say why in the commit. A tuning loop must never edit this file.\n")
        f.write("\n".join(rows) + "\n")
        f.write("COMBINED %s\n" % combined)


def verify_checksum(paths, lock_path, first_use_locks=False):
    """Returns (ok, combined, message)."""
    rows, combined = compute_lock(paths)
    if not os.path.exists(lock_path):
        if first_use_locks:
            write_lock(lock_path, rows, combined)
            return True, combined, "FIRST USE: locked %s" % lock_path
        return False, combined, "no lock file at %s" % lock_path
    lrows, lcombined = read_lock(lock_path)
    if lrows != rows or lcombined != combined:
        diff = sorted(set(rows) ^ set(lrows))
        return False, combined, "CHECK CHANGED, refusing to score. Differs: %s" % "; ".join(diff)
    return True, combined, "matches %s" % os.path.basename(lock_path)


# --------------------------------------------------------------- questions --
def load_questions(path):
    out = []
    for n, line in enumerate(open(path), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        q = json.loads(line)
        for k in ("id", "category", "question", "kind"):
            if k not in q:
                raise ValueError("%s:%d missing %r" % (path, n, k))
        if q["kind"] == "fact" and not q.get("require"):
            raise ValueError("%s:%d fact question with no require groups" % (path, n))
        out.append(q)
    return out


# -------------------------------------------------------------- chat client --
def _is_loopback(host):
    return host in ("127.0.0.1", "localhost", "::1")


def ask(host, port, token, question, deadline_s):
    """The reply text only. See ask_traced for the tool calls behind it."""
    return ask_traced(host, port, token, question, deadline_s)[0]


def ask_traced(host, port, token, question, deadline_s):
    """-> (reply text, trace). trace = {"tools": [{"name", "args", "origin",
    "result_chars"}], "end": done|error|closed|timeout, "error": str|None,
    "elapsed_s": float}. The trace keeps which tools ran, with what arguments,
    and how big each result was; it never keeps a result's text.

    One question over /ws/chat, a fresh session each time. Returns the reply
    text the customer reads: done.full_response when the key is present (the
    gateway sends chunk_reset then done{full_response}; ostler-assistant
    crates/zeroclaw-gateway/src/ws.rs), else the accumulated chunks. Same
    handshake and frames as scripts/box_walk_probes/probes/assistant_answers_grounded.sh
    (the embedded client, GET /ws/chat + Bearer + Sec-WebSocket-Protocol zeroclaw.v1)."""
    t0 = time.time()
    deadline = t0 + deadline_s
    trace = {"tools": [], "end": "timeout", "error": None}
    s = socket.create_connection((host, port), timeout=20)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n"
               "Authorization: Bearer %s\r\n\r\n" % (host, port, key, token)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(4096)
        if not c:
            raise ConnectionError("handshake_eof")
        buf += c
    head, rest = buf.split(b"\r\n\r\n", 1)
    status = head.split(b"\r\n")[0].decode(errors="replace")
    if " 101 " not in status + " ":
        raise ConnectionError("handshake: " + status)
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
        op, n = b0 & 0x0F, b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", rd(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", rd(8))[0]
        return op, rd(n)

    d = json.dumps({"type": "message", "content": question}).encode()
    m = os.urandom(4)
    mk = bytes(b ^ m[i % 4] for i, b in enumerate(d))
    if len(d) < 126:
        h = struct.pack("!BB", 0x81, 0x80 | len(d))
    elif len(d) < 65536:
        h = struct.pack("!BBH", 0x81, 0x80 | 126, len(d))
    else:
        h = struct.pack("!BBQ", 0x81, 0x80 | 127, len(d))
    s.sendall(h + m + mk)
    text = ""
    try:
        while time.time() < deadline:
            try:
                op, pay = frame()
            except (EOFError, socket.timeout, OSError):
                break
            if op == 8:
                trace["end"] = "closed"
                break
            if op != 1:
                continue
            try:
                ev = json.loads(pay)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "chunk":
                text += ev.get("content") or ""
            elif t == "chunk_reset":
                text = ""
            elif t == "tool_call":
                trace["tools"].append({"name": ev.get("name"), "args": ev.get("args"),
                                       "origin": ev.get("origin"), "result_chars": None})
            elif t == "tool_result":
                out = ev.get("output")
                size = len(out) if isinstance(out, str) else len(json.dumps(out, default=str))
                for tc in reversed(trace["tools"]):
                    if tc["name"] == ev.get("name") and tc["result_chars"] is None:
                        tc["result_chars"] = size
                        break
                else:
                    trace["tools"].append({"name": ev.get("name"), "args": None,
                                           "origin": ev.get("origin"), "result_chars": size})
            elif t == "done":
                trace["end"] = "done"
                trace["elapsed_s"] = round(time.time() - t0, 1)
                if "full_response" in ev:
                    return ev.get("full_response") or "", trace
                return text, trace
            elif t == "error":
                trace["end"] = "error"
                trace["error"] = str(ev.get("message") or ev.get("content") or ev)[:300]
                trace["elapsed_s"] = round(time.time() - t0, 1)
                return "", trace
    finally:
        s.close()
    trace["elapsed_s"] = round(time.time() - t0, 1)
    return text, trace


# ---------------------------------------------------------------- evidence --
def default_evidence_dir():
    env = os.environ.get("OSTLER_OWNER_SCORE_EVIDENCE_DIR")
    if env:
        return os.path.expanduser(env)
    return os.path.join(os.path.expanduser("~/.ostler/state/owner-score-evidence"),
                        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))


def inside_git_checkout(path):
    """True when path, or any parent that exists, holds a .git entry. Replies
    and traces can carry real graph content, so they are never written into a
    repository."""
    d = os.path.abspath(os.path.expanduser(path))
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def write_evidence(dirpath, records, held_ids, meta):
    """records: [{id, question, reply, score, why, part, trace, ...}].
    Visible replies go to replies.jsonl; held-back replies to
    replies_heldout.jsonl (a tuning loop must never read that file)."""
    os.makedirs(dirpath, mode=0o700, exist_ok=True)
    os.chmod(dirpath, 0o700)
    for name, want_held in (("replies.jsonl", False), ("replies_heldout.jsonl", True)):
        rows = [r for r in records if (r["id"] in held_ids) == want_held]
        if not rows:
            continue
        path = os.path.join(dirpath, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
    fd = os.open(os.path.join(dirpath, "meta.json"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(meta, f, indent=1, sort_keys=True)


def part_summary(questions, per_q, parts):
    """-> {"context": (score_sum, n), "retrieval": (score_sum, n)}"""
    out = {"context": [0.0, 0], "retrieval": [0.0, 0]}
    for q in questions:
        c = out[parts[q["id"]]]
        c[0] += per_q[q["id"]][0]
        c[1] += 1
    return out


# ------------------------------------------------------------------ report --
def report(questions, answers, per_q, cats, overall, show_verbatim_for, target, enforce, withheld=(),
           parts=None, parts_source=""):
    pct = overall * 100
    print("SCORE  %.1f%%  (%d questions)" % (pct, len(questions)))
    print("TARGET %.0f%%  %s" % (target, "ENFORCED" if enforce else "NOT ENFORCED (advisory)"))
    print("PER-CATEGORY")
    for c in grading.CATEGORIES:
        if c in cats:
            n = sum(1 for q in questions if q["category"] == c)
            print("  %-14s %5.1f%%  (%d)" % (c, cats[c] * 100, n))
    for c in sorted(set(cats) - set(grading.CATEGORIES)):
        print("  %-14s %5.1f%%" % (c, cats[c] * 100))
    if parts is not None:
        ps = part_summary(questions, per_q, parts)
        print("PARTS  (which of the two a question needs is read from %s)" % parts_source)
        for key, label, note in (("context", "SCORE-CONTEXT-ONLY",
                                  "answerable from CONTEXT.md alone"),
                                 ("retrieval", "SCORE-NEEDS-RETRIEVAL",
                                  "need the graph or the conversation store")):
            tot, n = ps[key]
            if n:
                print("%s  %.1f%%  (%d questions; %s)" % (label, tot / n * 100, n, note))
            else:
                print("%s  n/a  (0 questions; none in this run %s)" % (label, "is " + note if key == "context" else "needs" + note[4:]))
    worst = sorted(questions, key=lambda q: (per_q[q["id"]][0], q["id"]))
    worst = [q for q in worst if per_q[q["id"]][0] < 1.0][:10]
    print("WORST %d" % len(worst))
    for q in worst:
        s, why = per_q[q["id"]]
        if q["id"] in show_verbatim_for:
            print("  [%s] score=%.2f why=%s part=%s" % (q["id"], s, why, (parts or {}).get(q["id"], "?")))
            print("    Q: %s" % q["question"])
            if q.get("gold"):
                print("    EXPECTED: %s" % q["gold"])
            print("    A: %s" % (answers.get(q["id"]) or "<blank>").replace("\n", "\n       "))
        else:
            print("  [%s] score=%.2f why=%s part=%s  (%s)" % (q["id"], s, why, (parts or {}).get(q["id"], "?"),
                  "held back: text withheld" if q["id"] in withheld else "text not shown"))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="owner_score")
    ap.add_argument("--set", choices=("visible", "heldout", "all"), default="visible")
    ap.add_argument("--questions", help="custom questions file (e.g. the owner's real data); locked on first use")
    ap.add_argument("--limit", type=int, default=0, help="stratified sample: this many questions, round-robin across categories")
    ap.add_argument("--gateway", default=os.environ.get("OSTLER_PROBE_GATEWAY", "http://127.0.0.1:8000"))
    ap.add_argument("--token-path", default=os.environ.get("OSTLER_PROBE_TOKEN_PATH", "~/.ostler/secrets/zeroclaw_admin_token"))
    ap.add_argument("--timeout", type=float, default=float(os.environ.get("OSTLER_PROBE_CHAT_TIMEOUT", "420")))
    ap.add_argument("--answers", help="grade a JSON file {id: answer} instead of asking the Hub (self-tests, replays)")
    ap.add_argument("--print-replies", action="store_true",
                    help="also print the assistant's replies to stdout under WORST 10 (visible questions only). Off by "
                         "default: stdout lands in walk records and support bundles; replies are kept in the evidence directory")
    ap.add_argument("--no-verbatim", action="store_true",
                    help="DEPRECATED, accepted and ignored: stdout no longer prints replies unless --print-replies is given")
    ap.add_argument("--evidence-dir", help="where replies and tool traces are kept (default: a new directory under "
                    "~/.ostler/state/owner-score-evidence/ on a live run; with --answers nothing is written unless this is given). "
                    "Refused inside a git checkout.")
    ap.add_argument("--context-source", help="one line saying how CONTEXT.md was made (printed and kept in the evidence), "
                    "e.g. 'context: product generator ...' or 'context: FALLBACK trim, reason ...'")
    ap.add_argument("--context-file", help="the CONTEXT.md the run is answered from, used to tag each question as answerable "
                    "from it alone or needing retrieval (default: the box's workspace CONTEXT.md, else the shipped digest)")
    ap.add_argument("--target", type=float, default=TARGET)
    ap.add_argument("--enforce", action="store_true", help="exit 1 when below --target (the release gate)")
    ap.add_argument("--out", help="also write a local JSON result file (never uploaded)")
    ap.add_argument("--print-checksum", action="store_true")
    ap.add_argument("--relock", action="store_true", help="rewrite CHECKSUM.lock after a deliberate change")
    a = ap.parse_args(argv)

    built_in = [os.path.join(HERE, f) for f in CHECKED]
    if a.relock:
        rows, combined = compute_lock(built_in)
        write_lock(LOCK, rows, combined)
        print("relocked: %s" % combined)
        return 0
    ok, combined, msg = verify_checksum(built_in, LOCK)
    print("CHECK  built-in sha256 %s" % combined)
    print("CHECK  runner owner_score.py sha256 %s" % sha256_file(os.path.join(HERE, "owner_score.py")))
    print("CHECK  %s" % msg)
    if not ok:
        return EX_TAMPERED
    if a.print_checksum:
        return 0

    if a.questions:
        cq = os.path.abspath(a.questions)
        ok2, c2, msg2 = verify_checksum([cq], cq + ".lock", first_use_locks=True)
        print("CHECK  custom %s sha256 %s" % (os.path.basename(cq), c2))
        print("CHECK  %s" % msg2)
        if not ok2:
            return EX_TAMPERED
        questions = load_questions(cq)
        withheld = set()
    else:
        questions = []
        if a.set in ("visible", "all"):
            questions += load_questions(os.path.join(HERE, "questions_visible.jsonl"))
        held = []
        if a.set in ("heldout", "all"):
            held = load_questions(os.path.join(HERE, "questions_heldout.jsonl"))
            print("NOTE   held-back set scored: its text, gold answers and replies are withheld from this output")
        withheld = {q["id"] for q in held}
        questions += held
    if a.limit and a.limit < len(questions):
        by = {}
        for q in questions:
            by.setdefault(q["category"], []).append(q)
        order, i = [], 0
        while len(order) < a.limit:
            progressed = False
            for c in grading.CATEGORIES + sorted(set(by) - set(grading.CATEGORIES)):
                if c in by and i < len(by[c]) and len(order) < a.limit:
                    order.append(by[c][i])
                    progressed = True
            if not progressed:
                break
            i += 1
        questions = order
        print("NOTE   SAMPLE of %d questions (stratified); this is NOT the full score" % len(questions))
    if not questions:
        print("no questions to ask")
        return EX_USAGE

    # Which part of the score each question belongs to: read from the CONTEXT.md
    # the assistant will actually be answering from.
    ctx_candidates = [a.context_file] if a.context_file else []
    if not a.answers and not a.context_file:
        ctx_candidates.append(os.path.join(os.environ.get("OSTLER_WORKSPACE_DIR") or
                              os.path.expanduser("~/.ostler/assistant-config/workspace"), "CONTEXT.md"))
    ctx_candidates.append(os.path.join(HERE, "CONTEXT.persona.md"))
    ctx_text, parts_source = "", ""
    for cand in ctx_candidates:
        try:
            ctx_text = open(os.path.expanduser(cand), encoding="utf-8").read()
            parts_source = os.path.basename(os.path.dirname(os.path.abspath(os.path.expanduser(cand)))) + "/" + os.path.basename(cand)
            break
        except OSError:
            continue
    parts = {q["id"]: grading.classify_part(q, ctx_text) for q in questions}
    if a.context_source:
        print("CONTEXT-SOURCE  %s" % a.context_source.replace("\n", " ")[:300])

    evidence_dir = a.evidence_dir or (None if a.answers else default_evidence_dir())
    if evidence_dir and inside_git_checkout(evidence_dir):
        print("REFUSED: evidence directory %s is inside a git checkout. Replies and tool traces can carry real "
              "graph content and never go into a repository." % evidence_dir)
        return EX_USAGE

    traces = {}
    answers = {}
    if a.answers:
        answers = json.load(open(a.answers))
    else:
        gw = a.gateway.split("://", 1)[-1].rstrip("/")
        host, _, port = gw.rpartition(":")
        if not _is_loopback(host):
            print("REFUSED: gateway host %r is not loopback. This tool never sends the owner's questions off the machine." % host)
            return EX_USAGE
        try:
            token = open(os.path.expanduser(a.token_path)).read().strip()
        except OSError as e:
            print("CANNOT-RUN: no token at %s (%s)" % (a.token_path, e))
            return EX_CANNOT_RUN
        for i, q in enumerate(questions, 1):
            try:
                answers[q["id"]], traces[q["id"]] = ask_traced(host, int(port), token, q["question"], a.timeout)
            except Exception as e:  # a transport failure is not a wrong answer
                if i == 1:
                    print("CANNOT-RUN: first question could not reach %s:%s (%s)" % (host, port, e))
                    return EX_CANNOT_RUN
                answers[q["id"]] = ""
                traces[q["id"]] = {"tools": [], "end": "transport_error", "error": type(e).__name__}
            print("ASKED  %d/%d  %s" % (i, len(questions), q["id"]), file=sys.stderr)

    overall, cats, per_q = grading.score_set(questions, answers)
    verbatim = ({q["id"] for q in questions} - withheld) if a.print_replies else set()
    report(questions, answers, per_q, cats, overall, verbatim, a.target, a.enforce, withheld,
           parts=parts, parts_source=parts_source)
    if evidence_dir:
        records = [{"id": q["id"], "category": q["category"], "kind": q["kind"], "part": parts[q["id"]],
                    "question": q["question"], "reply": answers.get(q["id"]),
                    "score": per_q[q["id"]][0], "why": per_q[q["id"]][1],
                    "trace": traces.get(q["id"])} for q in questions]
        ps = part_summary(questions, per_q, parts)
        write_evidence(evidence_dir, records, withheld,
                       {"checksum": combined, "set": "custom" if a.questions else a.set,
                        "asked": len(questions), "context_source": parts_source, "context_made_by": a.context_source,
                        "score": overall, "parts": {k: {"n": v[1], "score": (v[0] / v[1] if v[1] else None)}
                                                    for k, v in ps.items()},
                        "written": datetime.now(timezone.utc).isoformat()})
        print("EVIDENCE  %d replies with tool traces kept on this machine at %s (not printed; never copy into a repo or PR)"
              % (len(records), evidence_dir))
    if a.out:
        ps = part_summary(questions, per_q, parts)
        json.dump({"score": overall, "categories": cats, "checksum": combined,
                   "per_question": {k: v[0] for k, v in per_q.items()},
                   "per_question_part": parts,
                   "parts": {k: {"n": v[1], "score": (v[0] / v[1] if v[1] else None)} for k, v in ps.items()}},
                  open(a.out, "w"), indent=1)
    if a.enforce and overall * 100 < a.target:
        return EX_BELOW
    return 0


if __name__ == "__main__":
    sys.exit(main())
