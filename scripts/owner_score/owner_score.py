#!/usr/bin/env python3
"""Owner-knowledge score: ask the real Hub chat path N questions, grade, report.

Driven by scripts/owner_score.sh. Stdlib only (the installed Hub may carry a
3.9 system python; the DMG bundles 3.11). Nothing is uploaded: the only socket
this opens is to the loopback gateway, and a non-loopback --gateway is refused.

THE CHECK IS IMMUTABLE TO THE TUNING LOOP. Every run recomputes the sha256 of
the question files, grading.py and this runner, prints it, and refuses to score if it does
not equal CHECKSUM.lock. A custom questions file (the owner's real data) is
locked on first use in <file>.lock and verified on every later run.

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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import grading  # noqa: E402

CHECKED = ["questions_visible.jsonl", "questions_heldout.jsonl", "grading.py", "owner_score.py"]
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
    """One question over /ws/chat, a fresh session each time. Returns the reply
    text the customer reads: done.full_response when the key is present (the
    gateway sends chunk_reset then done{full_response}; ostler-assistant
    crates/zeroclaw-gateway/src/ws.rs), else the accumulated chunks. Same
    handshake and frames as scripts/box_walk_probes/probes/assistant_answers_grounded.sh
    (the embedded client, GET /ws/chat + Bearer + Sec-WebSocket-Protocol zeroclaw.v1)."""
    deadline = time.time() + deadline_s
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
            elif t == "done":
                if "full_response" in ev:
                    return ev.get("full_response") or ""
                return text
            elif t == "error":
                return ""
    finally:
        s.close()
    return text


# ------------------------------------------------------------------ report --
def report(questions, answers, per_q, cats, overall, show_verbatim_for, target, enforce, withheld=()):
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
    worst = sorted(questions, key=lambda q: (per_q[q["id"]][0], q["id"]))
    worst = [q for q in worst if per_q[q["id"]][0] < 1.0][:10]
    print("WORST %d" % len(worst))
    for q in worst:
        s, why = per_q[q["id"]]
        if q["id"] in show_verbatim_for:
            print("  [%s] score=%.2f why=%s" % (q["id"], s, why))
            print("    Q: %s" % q["question"])
            if q.get("gold"):
                print("    EXPECTED: %s" % q["gold"])
            print("    A: %s" % (answers.get(q["id"]) or "<blank>").replace("\n", "\n       "))
        else:
            print("  [%s] score=%.2f why=%s  (%s)" % (q["id"], s, why,
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
    ap.add_argument("--no-verbatim", action="store_true", help="never print answer text (walk records, support bundles)")
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
                answers[q["id"]] = ask(host, int(port), token, q["question"], a.timeout)
            except Exception as e:  # a transport failure is not a wrong answer
                if i == 1:
                    print("CANNOT-RUN: first question could not reach %s:%s (%s)" % (host, port, e))
                    return EX_CANNOT_RUN
                answers[q["id"]] = ""
            print("ASKED  %d/%d  %s" % (i, len(questions), q["id"]), file=sys.stderr)

    overall, cats, per_q = grading.score_set(questions, answers)
    verbatim = set() if a.no_verbatim else {q["id"] for q in questions} - withheld
    report(questions, answers, per_q, cats, overall, verbatim, a.target, a.enforce, withheld)
    if a.out:
        json.dump({"score": overall, "categories": cats, "checksum": combined,
                   "per_question": {k: v[0] for k, v in per_q.items()}}, open(a.out, "w"), indent=1)
    if a.enforce and overall * 100 < a.target:
        return EX_BELOW
    return 0


if __name__ == "__main__":
    sys.exit(main())
