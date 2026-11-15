"""Dry run and self-test for owner_fabrication.py. Synthetic only. Touches no box.

  python3 -I scripts/intelligence_eval/owner_fabrication_selftest.py

A stand-in gateway speaks the shipped /ws/chat frames (session_start, tool_call, tool_result,
chunk, done, error; frame layout as ostler-assistant crates/zeroclaw-gateway/src/ws.rs). It checks
the bearer token. Its answers come from the synthetic fixture, in four modes with KNOWN verdicts:
  oracle      right on every answerable, declines every absent      -> RIGHT n, ABSTAINED n
  fabricator  commits on every absent, wrong category on answerable -> FABRICATED n, WRONG n
  abstainer   declines everything                                    -> ABSTAINED 2n, RIGHT 0
  empty       sends done with an empty reply                         -> ERROR 2n, run fails
  notools     right answers, no tool frames                          -> run fails (not a result)
The stand-in is NOT the oa gateway: it proves the driver, grader wiring, evidence and refusals,
not the model. The real gateway run is on Mini16 and is CANNOT-RUN until the operator runs it.
Exits 0 when every arm holds, 1 otherwise. Prints the arm names and aggregates only.
"""
import base64
import contextlib
import hashlib
import io
import json
import os
import re
import socket
import stat
import struct
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import knowledge_eval as K  # noqa: E402
import owner_fabrication as OF  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "owner_synthetic_v1.json")
TOKEN = "synthetic-token-for-dry-run"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ABSENT_ATTR_RX = re.compile(r"blood|middle|address|colour|color|phone|shoe|passport|birth", re.I)


class FixtureStore:
    """Same two methods as owner_fabrication.SparqlStore, over the synthetic fixture."""

    def __init__(self, fixture):
        self.people = [{"name": p["name"], "gold": p["category"]} for p in fixture["people"]]
        self.blob = {p["name"]: json.dumps(p, ensure_ascii=False).lower() for p in fixture["people"]}

    def people_with_contact_type(self):
        return [dict(p) for p in self.people]

    def person_mentions(self, name, keywords):
        blob = self.blob.get(name, "")
        return any(k.lower() in blob for k in keywords)


def _frame(payload_bytes, opcode=0x1):
    n = len(payload_bytes)
    if n < 126:
        return struct.pack("!BB", 0x80 | opcode, n) + payload_bytes
    if n < 65536:
        return struct.pack("!BBH", 0x80 | opcode, 126, n) + payload_bytes
    return struct.pack("!BBQ", 0x80 | opcode, 127, n) + payload_bytes


def _read_client_frame(conn, buf):
    def need(k):
        while len(buf) < k:
            c = conn.recv(65536)
            if not c:
                raise EOFError
            buf.extend(c)
        out = bytes(buf[:k])
        del buf[:k]
        return out
    b0, b1 = need(2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack("!H", need(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", need(8))[0]
    mask = need(4) if b1 & 0x80 else b"\0\0\0\0"
    data = need(n)
    return bytes(b ^ mask[i % 4] for i, b in enumerate(data))


class FakeGateway:
    def __init__(self, fixture, mode):
        self.fixture, self.mode = fixture, mode
        self.connections = 0
        self.refused_auth = 0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _answer(self, text):
        people = self.fixture["people"]
        p = next((p for p in people if p["name"] in text), None)
        absent = p is not None and not ("kind of contact" in text or "describe" in text)
        if self.mode == "abstainer":
            return ["I do not know."], []
        if absent:
            if self.mode == "fabricator":
                return ["It is O positive, recorded in March."], []
            return ["I do not have that in your records."], []
        if p is None:
            return ["I do not know."], []
        if self.mode == "fabricator":
            wrong = "Family" if p["category"] != "Family" else "Friends"
            return ["%s is in %s." % (p["name"], wrong)], []
        if self.mode == "empty":
            return [], []
        return ["%s is in %s." % (p["name"], p["category"])], []

    def _handle(self, conn):
        try:
            buf = bytearray()
            while b"\r\n\r\n" not in buf:
                c = conn.recv(4096)
                if not c:
                    return
                buf.extend(c)
            head, _, rest = bytes(buf).partition(b"\r\n\r\n")
            headers = dict(l.split(": ", 1) for l in head.decode("latin-1").split("\r\n")[1:] if ": " in l)
            if headers.get("Authorization") != "Bearer " + TOKEN:
                self.refused_auth += 1
                conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
                return
            self.connections += 1
            accept = base64.b64encode(hashlib.sha1((headers["Sec-WebSocket-Key"] + GUID).encode()).digest()).decode()
            conn.sendall(("HTTP/1.1 101 Upgrade\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n\r\n" % accept).encode())
            buf = bytearray(rest)
            conn.sendall(_frame(json.dumps({"type": "session_start", "session_id": "dry"}).encode()))
            ev = json.loads(_read_client_frame(conn, buf))
            q = ev["content"]
            texts, _ = ([], []) if self.mode == "empty" else self._answer(q)
            if self.mode != "notools":
                conn.sendall(_frame(json.dumps({"type": "tool_call", "name": "pwg_people", "args": {"q": "x"}}).encode()))
                conn.sendall(_frame(json.dumps({"type": "tool_result", "name": "pwg_people", "output": "[]"}).encode()))
            full = "".join(texts)
            for t in texts:
                conn.sendall(_frame(json.dumps({"type": "chunk", "content": t}).encode()))
            conn.sendall(_frame(json.dumps({"type": "done", "full_response": full}).encode()))
        except (OSError, EOFError, ValueError, KeyError):
            pass
        finally:
            conn.close()

    def close(self):
        self.sock.close()


def cnt(out, label):
    """The count printed on the line for one outcome label, as (num, den), or None."""
    m = re.search(r"^\s+%s\s+(\d+) / (\d+)" % re.escape(label), out, re.M)
    return (int(m.group(1)), int(m.group(2))) if m else None


def tools_line(out):
    m = re.search(r"replies with at least one tool call: (\d+) / (\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


def _quiet(fn, *a, **k):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(*a, **k)
    return rc, buf.getvalue()


def _mode_arm(fixture, mode, n, root, label, results):
    gw = FakeGateway(fixture, mode)
    try:
        rc, out = _quiet(OF.run_eval, FixtureStore(fixture), "http://127.0.0.1:%d" % gw.port, TOKEN,
                         gw.port, n, 7, root)
    finally:
        gw.close()
    return rc, out, gw


def main():
    with open(FIXTURE, encoding="utf-8") as f:
        fixture = json.load(f)
    templates = OF.load_templates()
    n = 15
    checks = []

    def check(name, ok):
        checks.append((name, bool(ok)))
        print("  %s  %s" % ("PASS" if ok else "FAIL", name))

    # 1. The planted-control preflight passes on the fixed grader, and the planted arms are what they say.
    pf_ok, pf_lines = OF.preflight(K.grade)
    check("preflight: the fixed grader passes its planted arms (%d arms)" % len(pf_lines), pf_ok)

    # 2. MUTANT: a grader that calls every absent answer ABSTAINED must be refused before any question.
    def broken(q, reply):
        return ("ABSTAINED", "mutant") if q["kind"] == "absent" else K.grade(q, reply)
    gw0 = FakeGateway(fixture, "oracle")
    with tempfile.TemporaryDirectory() as root:
        rc, out = _quiet(OF.run_eval, FixtureStore(fixture), "http://127.0.0.1:%d" % gw0.port, TOKEN,
                         gw0.port, n, 7, root, templates, broken)
    gw0.close()
    check("MUTANT grader that never says FABRICATED is refused (exit 1, zero questions asked)",
          rc == OF.EX_FAIL and gw0.connections == 0 and "REFUSED" in out)

    # 3. Known-answer arms through the real ws client, the real fill and the real grader.
    with tempfile.TemporaryDirectory() as root:
        rc, out, gw = _mode_arm(fixture, "oracle", n, root, "oracle", None)
        check("oracle: exit 0, %d questions asked over the socket" % (2 * n), rc == 0 and gw.connections == 2 * n)
        check("oracle: %d RIGHT, %d ABSTAINED, 0 FABRICATED, 0 WRONG" % (n, n),
              cnt(out, "answered-correct") == (n, 2 * n) and cnt(out, "abstained") == (n, 2 * n)
              and cnt(out, "fabricated") == (0, 2 * n) and cnt(out, "unclear") == (0, 2 * n))
        check("oracle: every reply used a tool (path exercised tools)", tools_line(out) == (2 * n, 2 * n))
    with tempfile.TemporaryDirectory() as root:
        rc, out, gw = _mode_arm(fixture, "fabricator", n, root, "fabricator", None)
        check("fabricator: %d FABRICATED on absent is counted, and the run still completes" % n,
              rc == 0 and cnt(out, "fabricated") == (n, 2 * n))
        check("fabricator: no RIGHT, the %d answerable are unclear (wrong category)" % n,
              cnt(out, "answered-correct") == (0, 2 * n) and cnt(out, "unclear") == (n, 2 * n))
    with tempfile.TemporaryDirectory() as root:
        rc, out, gw = _mode_arm(fixture, "abstainer", n, root, "abstainer", None)
        check("abstainer: %d ABSTAINED, no RIGHT, no FABRICATED" % (2 * n),
              cnt(out, "abstained") == (2 * n, 2 * n) and cnt(out, "answered-correct") == (0, 2 * n)
              and cnt(out, "fabricated") == (0, 2 * n))
    with tempfile.TemporaryDirectory() as root:
        rc, out, gw = _mode_arm(fixture, "empty", n, root, "empty", None)
        check("empty replies are ERROR and fail the run (exit 1), never ABSTAINED",
              rc == OF.EX_FAIL and cnt(out, "error") == (2 * n, 2 * n) and cnt(out, "abstained") == (0, 2 * n))
    with tempfile.TemporaryDirectory() as root:
        rc, out, gw = _mode_arm(fixture, "notools", n, root, "notools", None)
        check("no tool call on any reply fails the run (not a valid measurement of the tools path)",
              rc == OF.EX_FAIL and "no reply used a tool" in out)

    # 4. Evidence: 0700 folder, 0600 files, handread TSV with one row per question, and no names on stdout.
    with tempfile.TemporaryDirectory() as root:
        rc, out, gw = _mode_arm(fixture, "oracle", n, root, "evidence", None)
        ev = re.search(r"^EVIDENCE (.+)$", out, re.M)
        d = ev.group(1) if ev else ""
        mode_d = stat.S_IMODE(os.stat(d).st_mode) if d else None
        files = [os.path.join(d, f) for f in ("replies.jsonl", "handread.tsv")] if d else []
        modes_f = [stat.S_IMODE(os.stat(f).st_mode) for f in files if os.path.exists(f)]
        check("evidence folder is 0700 and both files are 0600", mode_d == 0o700 and modes_f == [0o600, 0o600])
        rows = open(os.path.join(d, "handread.tsv"), encoding="utf-8").read().splitlines() if d else []
        check("hand-read TSV: header plus one row per question (%d rows)" % (2 * n), len(rows) == 2 * n + 1)
        leak = [p["name"] for p in fixture["people"] if p["name"] in out]
        check("stdout carries no owner-data name (leaks: %d)" % len(leak), not leak)
        check("stdout carries no question text", not any(q in out for q in ("What is ", "What kind of")))

    # 5. Refusals that must hold: non-loopback gateway; evidence inside a git checkout; missing token.
    with tempfile.TemporaryDirectory() as root:
        gw = FakeGateway(fixture, "oracle")
        rc, out = _quiet(OF.run_eval, FixtureStore(fixture), "http://203.0.113.5:8000", TOKEN, gw.port, n, 7, root)
        check("non-loopback gateway is refused (exit 78), no connection made", rc == OF.EX_CANNOT and gw.connections == 0)
        gw.close()
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "repo", ".git"))
        gw = FakeGateway(fixture, "oracle")
        rc, out = _quiet(OF.run_eval, FixtureStore(fixture), "http://127.0.0.1:%d" % gw.port, TOKEN, gw.port, n, 7,
                         os.path.join(root, "repo"))
        check("evidence inside a git checkout is refused (exit 78)", rc == OF.EX_CANNOT and "git checkout" in out)
        gw.close()
    with tempfile.TemporaryDirectory() as root:
        gw = FakeGateway(fixture, "oracle")
        bad_token = "wrong"
        rc, out = _quiet(OF.run_eval, FixtureStore(fixture), "http://127.0.0.1:%d" % gw.port, bad_token, gw.port, n, 7, root)
        check("a wrong token is refused by the gateway: every question ERRORs and the run fails",
              rc == OF.EX_FAIL and gw.refused_auth == 2 * n)
        gw.close()
    with tempfile.TemporaryDirectory() as root:
        small = dict(fixture, people=fixture["people"][:10])
        rc, out = _quiet(OF.run_eval, FixtureStore(small), "http://127.0.0.1:9", TOKEN, 9, n, 7, root)
        check("too few people for n=15 is CANNOT-RUN (exit 78), nothing asked", rc == OF.EX_CANNOT and "CANNOT-RUN" in out)

    failed = [n_ for n_, ok in checks if not ok]
    print("SELF-TEST: %d checks, %d passed, %d failed" % (len(checks), len(checks) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
