#!/usr/bin/env python3
"""email_channel_round_trip -- loopback driver and judge. (v1.0.107 #10)

WHAT THIS MEASURES. The assistant's email channel, end to end, against a
loopback mail server and the INSTALLED daemon binary:

  (a) 5 unread messages already in the mailbox when the daemon first connects
      get NO reply (the watermark);
  (b) a message from the owner's address gets exactly ONE reply, threaded:
      "Re: <subject>", In-Reply-To = the inbound Message-ID, References
      carrying it;
  (c) a message from an address that is not on the allowlist gets none;
  (d) an owner message marked Auto-Submitted gets none;
  (e) an owner message whose provider says dmarc=fail (a spoof) gets none;
  (f) after a restart in which every old message is flipped back to UNSEEN, the
      old mail is not re-answered, and one NEW message that arrived while the
      daemon was down IS answered.

Everything is synthetic (example.test addresses) and loopback only. Nothing
touches the customer's mailbox, config or state: the daemon runs with HOME,
OSTLER_HOME and ZEROCLAW_CONFIG_DIR pointed at a throwaway directory, and every
server and the daemon are stopped before this exits.

LOAD. One asyncio loop, one tiny HTTP thread, IMAP polled at 1 s. Callers run
this under `nice -n 19`. No Java, no VM.

MODES
  run --daemon BIN [--facts FILE]   drive the daemon, print facts JSON
  judge FACTS.json                  grade facts; exit 0 PASS / 1 FAIL / 78 CANNOT
  --self-test                       the judge must go red on every mutant
  --server-test                     the mock IMAP/SMTP servers vs imaplib/smtplib

Exit codes follow the probe contract: 0 PASS, 1 FAIL, 78 CANNOT-RUN.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import copy
import email
import email.utils
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

OWNER = "owner@example.test"
STRANGER = "stranger@example.test"
ASSISTANT = "assistant@example.test"
PASSWORD = "loopback-only-password"  # synthetic; the mock accepts it
N_PRE = 5
UIDVALIDITY = 4242


# ---------------------------------------------------------------- mailbox
class Mailbox:
    def __init__(self) -> None:
        self.msgs: list[dict] = []  # {uid, raw, seen}
        self.next_uid = 1
        self.logins = 0
        self.searches = 0

    def add(self, raw: bytes, seen: bool = False) -> int:
        uid = self.next_uid
        self.next_uid += 1
        self.msgs.append({"uid": uid, "raw": raw, "seen": seen})
        return uid

    def get(self, uid: int) -> dict | None:
        for m in self.msgs:
            if m["uid"] == uid:
                return m
        return None

    def mark_all_unseen(self) -> None:
        for m in self.msgs:
            m["seen"] = False


def make_mail(sender: str, subject: str, msgid: str, extra: str = "", body: str = "hello") -> bytes:
    hdr = (
        f"From: <{sender}>\r\nTo: <{ASSISTANT}>\r\nSubject: {subject}\r\n"
        f"Message-ID: {msgid}\r\nDate: Wed, 07 Oct 2026 10:00:00 +0000\r\n"
        f"MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n{extra}"
    )
    return (hdr + "\r\n" + body + "\r\n").encode()


# ------------------------------------------------------------------ IMAP
def _parse_seqset(spec: str, max_uid: int) -> tuple[int, int]:
    a, _, b = spec.partition(":")
    lo = int(a)
    hi = max_uid if b in ("*", "") else int(b)
    return lo, hi


class ImapServer:
    """Just enough IMAP4rev1 for async-imap and imaplib. No IDLE (so the daemon
    takes its polling path), no TLS."""

    def __init__(self, box: Mailbox) -> None:
        self.box = box

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        def send(s: str) -> None:
            writer.write(s.encode() + b"\r\n")

        send("* OK [CAPABILITY IMAP4rev1] loopback ready")
        await writer.drain()
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                text = line.decode(errors="replace").rstrip("\r\n")
                tag, _, rest = text.partition(" ")
                cmd, _, args = rest.partition(" ")
                cmd = cmd.upper()
                if cmd == "CAPABILITY":
                    send("* CAPABILITY IMAP4rev1")
                    send(f"{tag} OK CAPABILITY completed")
                elif cmd == "LOGIN":
                    self.box.logins += 1
                    send(f"{tag} OK LOGIN completed")
                elif cmd in ("SELECT", "EXAMINE"):
                    n = len(self.box.msgs)
                    send(f"* {n} EXISTS")
                    send("* 0 RECENT")
                    send("* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)")
                    send(f"* OK [UIDVALIDITY {UIDVALIDITY}] UIDs valid")
                    send(f"* OK [UIDNEXT {self.box.next_uid}] Predicted next UID")
                    send("* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] ok")
                    send(f"{tag} OK [READ-WRITE] {cmd} completed")
                elif cmd == "NOOP":
                    send(f"{tag} OK NOOP completed")
                elif cmd == "UID":
                    sub, _, subargs = args.partition(" ")
                    sub = sub.upper()
                    max_uid = max((m["uid"] for m in self.box.msgs), default=0)
                    if sub == "SEARCH":
                        self.box.searches += 1
                        toks = subargs.upper().split()
                        lo, hi = 1, max_uid
                        if "UID" in toks:
                            lo, hi = _parse_seqset(subargs.split()[toks.index("UID") + 1], max_uid)
                        unseen = "UNSEEN" in toks
                        hits = [
                            m["uid"] for m in self.box.msgs
                            if lo <= m["uid"] <= max(hi, lo)
                            and (not unseen or not m["seen"])
                        ]
                        # RFC 3501: `n:*` always includes the highest UID, even
                        # when it is below n. Reproduce it, the daemon must cope.
                        if "UID" in toks and subargs.split()[toks.index("UID") + 1].endswith(":*"):
                            top = self.box.get(max_uid)
                            if top and max_uid < lo and (not unseen or not top["seen"]):
                                hits = [max_uid]
                        send("* SEARCH" + "".join(f" {u}" for u in sorted(hits)))
                        send(f"{tag} OK UID SEARCH completed")
                    elif sub == "FETCH":
                        spec = subargs.split()[0]
                        ids: list[int] = []
                        for part in spec.split(","):
                            if ":" in part:
                                a, b = _parse_seqset(part, max_uid)
                                ids += [m["uid"] for m in self.box.msgs if a <= m["uid"] <= b]
                            elif part.isdigit():
                                ids.append(int(part))
                        for u in ids:
                            m = self.box.get(u)
                            if not m:
                                continue
                            seq = self.box.msgs.index(m) + 1
                            m["seen"] = True  # RFC822 fetch sets \Seen, as a real server does
                            raw = m["raw"]
                            writer.write(
                                f"* {seq} FETCH (UID {u} RFC822 {{{len(raw)}}}\r\n".encode()
                                + raw + b")\r\n"
                            )
                        send(f"{tag} OK UID FETCH completed")
                    elif sub == "STORE":
                        spec = subargs.split()[0]
                        for part in spec.split(","):
                            for m in list(self.box.msgs):
                                if part.isdigit() and m["uid"] == int(part):
                                    if "\\SEEN" in subargs.upper():
                                        m["seen"] = True
                                    seq = self.box.msgs.index(m) + 1
                                    send(f"* {seq} FETCH (UID {m['uid']} FLAGS (\\Seen))")
                        send(f"{tag} OK UID STORE completed")
                    else:
                        send(f"{tag} BAD unsupported UID {sub}")
                elif cmd == "CLOSE":
                    send(f"{tag} OK CLOSE completed")
                elif cmd == "LOGOUT":
                    send("* BYE bye")
                    send(f"{tag} OK LOGOUT completed")
                    await writer.drain()
                    break
                else:
                    send(f"{tag} BAD unsupported {cmd}")
                await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()


# ------------------------------------------------------------------ SMTP
class SmtpSink:
    def __init__(self) -> None:
        self.sent: list[dict] = []  # {rcpt, msg}
        self.phase = "start"

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        def send(s: str) -> None:
            writer.write(s.encode() + b"\r\n")

        send("220 loopback ESMTP")
        await writer.drain()
        rcpts: list[str] = []
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                t = line.decode(errors="replace").rstrip("\r\n")
                up = t.upper()
                if up.startswith(("EHLO", "HELO")):
                    send("250-loopback")
                    send("250-AUTH PLAIN LOGIN")
                    send("250 8BITMIME")
                elif up.startswith("AUTH PLAIN"):
                    send("235 2.7.0 ok")
                elif up.startswith("AUTH LOGIN"):
                    send("334 VXNlcm5hbWU6")
                    await writer.drain()
                    await reader.readline()
                    send("334 UGFzc3dvcmQ6")
                    await writer.drain()
                    await reader.readline()
                    send("235 2.7.0 ok")
                elif up.startswith("MAIL FROM"):
                    rcpts = []
                    send("250 ok")
                elif up.startswith("RCPT TO"):
                    rcpts.append(t[t.find("<") + 1 : t.rfind(">")].lower())
                    send("250 ok")
                elif up == "DATA":
                    send("354 go")
                    await writer.drain()
                    buf = b""
                    while True:
                        l2 = await reader.readline()
                        if l2 in (b".\r\n", b""):
                            break
                        buf += l2[1:] if l2.startswith(b"..") else l2
                    msg = email.message_from_bytes(buf)
                    self.sent.append({"rcpt": list(rcpts), "msg": msg, "phase": self.phase})
                    send("250 queued")
                elif up in ("RSET", "NOOP"):
                    send("250 ok")
                elif up == "QUIT":
                    send("221 bye")
                    await writer.drain()
                    break
                else:
                    send("250 ok")
                await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()


# ------------------------------------------------------- stub model (Ollama)
class _Ollama(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a) -> None:  # silent
        pass

    def _json(self, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        self._json({"models": [{"name": "stub", "model": "stub"}]})

    def do_POST(self) -> None:
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        msg = {"role": "assistant", "content": "Synthetic reply from the loopback model."}
        base = {"model": req.get("model", "stub"), "created_at": "2026-10-07T00:00:00Z"}
        if req.get("stream", True) and self.path.endswith("/api/chat"):
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            self.wfile.write((json.dumps({**base, "message": msg, "done": False}) + "\n").encode())
            self.wfile.write((json.dumps({
                **base, "message": {"role": "assistant", "content": ""}, "done": True,
                "done_reason": "stop", "total_duration": 1, "prompt_eval_count": 1, "eval_count": 1,
            }) + "\n").encode())
            return
        self._json({**base, "message": msg, "done": True, "done_reason": "stop",
                    "prompt_eval_count": 1, "eval_count": 1})


# ----------------------------------------------------------------- driver
def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def write_config(cfg_dir: str, imap: int, smtp: int, llm: int, allowed: list[str]) -> None:
    os.makedirs(os.path.join(cfg_dir, "workspace"), exist_ok=True)
    allowed_toml = ", ".join(f'"{a}"' for a in allowed)
    text = f'''schema_version = 2

[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://127.0.0.1:{llm}"
model = "stub"
timeout_secs = 30

[channels.email]
enabled = true
imap_host = "127.0.0.1"
imap_port = {imap}
imap_tls = false
imap_folder = "INBOX"
smtp_host = "127.0.0.1"
smtp_port = {smtp}
smtp_tls = false
username = "{ASSISTANT}"
password = "{PASSWORD}"
from_address = "{ASSISTANT}"
poll_interval_secs = 1
allowed_senders = [{allowed_toml}]
'''
    p = os.path.join(cfg_dir, "config.toml")
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, 0o600)


class Daemon:
    def __init__(self, binary: str, root: str, log_name: str) -> None:
        self.binary, self.root, self.proc, self.log_name = binary, root, None, log_name

    def start(self) -> None:
        env = dict(os.environ)
        env.update({
            "HOME": os.path.join(self.root, "home"),
            "OSTLER_HOME": os.path.join(self.root, "home", ".ostler"),
            "ZEROCLAW_CONFIG_DIR": os.path.join(self.root, "cfg"),
            "ZEROCLAW_WORKSPACE": os.path.join(self.root, "cfg", "workspace"),
            "RUST_LOG": "warn,zeroclaw_channels::email_channel=info",
            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
        })
        for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
            env.pop(k, None)
        os.makedirs(env["HOME"], exist_ok=True)
        log = open(os.path.join(self.root, self.log_name), "ab")
        self.proc = subprocess.Popen(
            ["nice", "-n", "19", self.binary, "channel", "start"],
            env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
            start_new_session=True,
        )

    def stop(self) -> None:
        if not self.proc:
            return
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=8)
        except Exception:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except Exception:
                pass
        self.proc = None

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None


async def _wait(pred, timeout: float, step: float = 0.25) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        await asyncio.sleep(step)
    return pred()


async def drive(binary: str, keep: str | None) -> dict:
    root = tempfile.mkdtemp(prefix="ostler-email-probe-")
    box, sink = Mailbox(), SmtpSink()
    imap_port, smtp_port, llm_port = _free_port(), _free_port(), _free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", llm_port), _Ollama)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    imap_srv = await asyncio.start_server(ImapServer(box).handle, "127.0.0.1", imap_port)
    smtp_srv = await asyncio.start_server(sink.handle, "127.0.0.1", smtp_port)
    write_config(os.path.join(root, "cfg"), imap_port, smtp_port, llm_port, [OWNER])
    d = Daemon(binary, root, "daemon.log")
    facts: dict = {"pre_existing": N_PRE, "daemon_started": False}
    try:
        for i in range(N_PRE):
            box.add(make_mail(OWNER, f"Old unread {i}", f"<old-{i}@example.test>"))
        sink.phase = "start"
        d.start()
        facts["daemon_started"] = True
        ok = await _wait(lambda: box.logins >= 1 and box.searches >= 4, 60)
        facts["connected"] = ok

        # (b) owner mail -> one threaded reply
        sink.phase = "owner"
        facts["owner_msgid"], facts["owner_subject"] = "<owner-1@example.test>", "Lunch plans"
        uid = box.add(make_mail(OWNER, facts["owner_subject"], facts["owner_msgid"]))
        await _wait(lambda: any(s["phase"] == "owner" for s in sink.sent), 60)
        await asyncio.sleep(2)

        # (c) stranger (even with a clean DMARC pass)
        sink.phase = "stranger"
        s_uid = box.add(make_mail(STRANGER, "Hello", "<stranger-1@example.test>",
                                  "Authentication-Results: mx.example.test; dmarc=pass\r\n"))
        await _wait(lambda: box.get(s_uid)["seen"], 30)
        await asyncio.sleep(4)

        # (d) automated mail from the owner's own address
        sink.phase = "auto"
        a_uid = box.add(make_mail(OWNER, "Out of office", "<auto-1@example.test>",
                                  "Auto-Submitted: auto-replied\r\n"))
        await _wait(lambda: box.get(a_uid)["seen"], 30)
        await asyncio.sleep(4)

        # (e) spoofed owner: the provider says DMARC failed
        sink.phase = "spoof"
        p_uid = box.add(make_mail(OWNER, "Spoofed", "<spoof-1@example.test>",
                                  "Authentication-Results: mx.example.test; dmarc=fail\r\n"))
        await _wait(lambda: box.get(p_uid)["seen"], 30)
        await asyncio.sleep(4)

        # (f) restart: old mail flipped back to UNSEEN, one new mail while down
        d.stop()
        facts["logins_before_restart"] = box.logins
        box.mark_all_unseen()
        sink.phase = "restart"
        facts["new_while_down_msgid"] = "<while-down-1@example.test>"
        box.add(make_mail(OWNER, "While you were out", facts["new_while_down_msgid"]))
        d.start()
        await _wait(lambda: any(s["phase"] == "restart" for s in sink.sent), 60)
        await asyncio.sleep(5)
        facts["logins_after_restart"] = box.logins
        facts["searches"] = box.searches
        facts["replies"] = [{
            "phase": s["phase"],
            "to": ",".join(s["rcpt"]),
            "subject": s["msg"].get("Subject", ""),
            "in_reply_to": s["msg"].get("In-Reply-To", ""),
            "references": s["msg"].get("References", ""),
            "message_id": s["msg"].get("Message-ID", ""),
        } for s in sink.sent]
    finally:
        d.stop()
        imap_srv.close()
        smtp_srv.close()
        httpd.shutdown()
        if keep:
            shutil.copy(os.path.join(root, "daemon.log"), keep) if os.path.exists(os.path.join(root, "daemon.log")) else None
        shutil.rmtree(root, ignore_errors=True)
    return facts


# ------------------------------------------------------------------ judge
def judge(f: dict) -> int:
    lines: list[tuple[str, str, str]] = []
    reps = f.get("replies", [])

    def ph(p: str) -> list[dict]:
        return [r for r in reps if r.get("phase") == p]

    alive = bool(f.get("daemon_started")) and bool(f.get("connected")) and f.get("logins_after_restart", 0) >= 2
    if not f.get("daemon_started"):
        lines.append(("CANNOT", "channel_alive", "the daemon could not be started, so nothing was measured"))
    elif not alive:
        # The daemon ran and never logged in: a shipped binary whose email channel
        # does not start (feature not compiled in, config refused). That is a
        # product FAIL, and a silent channel and a dead one print the same zero.
        lines.append(("FAIL", "channel_alive", "the daemon ran but never logged in to the loopback "
                      "mailbox (email channel not started, or it did not survive a restart)"))
    # (a)
    n = len(ph("start"))
    lines.append(("ok" if n == 0 else "FAIL", "pre_existing_unread_not_answered",
                  f"{f.get('pre_existing', 0)} unread messages present at first connect, {n} replies"))
    # (b)
    o = ph("owner")
    subj = f.get("owner_subject", "")
    mid = f.get("owner_msgid", "")
    good = (len(o) == 1 and o[0].get("to") == OWNER and o[0].get("subject") == f"Re: {subj}"
            and o[0].get("in_reply_to") == mid and mid in o[0].get("references", "").split())
    lines.append(("ok" if good else "FAIL", "owner_gets_one_threaded_reply",
                  f"{len(o)} replies; " + (f"subject={o[0].get('subject')!r} in_reply_to={o[0].get('in_reply_to')!r} "
                  f"references={o[0].get('references')!r}" if o else "none")))
    # (c)
    sr = [r for r in reps if STRANGER in r.get("to", "")]
    lines.append(("ok" if not sr else "FAIL", "non_allowed_sender_not_answered", f"{len(sr)} replies to the stranger"))
    # (d)
    au = ph("auto")
    lines.append(("ok" if not au else "FAIL", "auto_submitted_not_answered", f"{len(au)} replies to an Auto-Submitted message"))
    # (e)
    sp = ph("spoof")
    lines.append(("ok" if not sp else "FAIL", "failed_dmarc_owner_not_answered", f"{len(sp)} replies to a dmarc=fail message"))
    # (f)
    rs = ph("restart")
    wd = f.get("new_while_down_msgid", "")
    only_new = len(rs) == 1 and rs[0].get("in_reply_to") == wd
    lines.append(("ok" if only_new else "FAIL", "restart_answers_only_the_new_mail",
                  f"{len(rs)} replies after restart with 6 old messages flipped to unread and 1 new; "
                  f"in_reply_to={[r.get('in_reply_to') for r in rs]}"))
    # the positive control is what makes every zero above mean something
    if good is False and alive:
        lines.append(("FAIL", "positive_control", "the owner never got a reply, so the zeros above prove nothing"))

    for status, name, detail in lines:
        print(f"  {status} {name} -- {detail}")
    if any(s == "FAIL" for s, _, _ in lines):
        return 1
    if any(s == "CANNOT" for s, _, _ in lines):
        return 78
    return 0


def _good_facts() -> dict:
    mid = "<owner-1@example.test>"
    return {
        "pre_existing": N_PRE, "daemon_started": True, "connected": True,
        "logins_before_restart": 1, "logins_after_restart": 2, "searches": 30,
        "owner_msgid": mid, "owner_subject": "Lunch plans",
        "new_while_down_msgid": "<while-down-1@example.test>",
        "replies": [
            {"phase": "owner", "to": OWNER, "subject": "Re: Lunch plans", "in_reply_to": mid, "references": mid},
            {"phase": "restart", "to": OWNER, "subject": "Re: While you were out",
             "in_reply_to": "<while-down-1@example.test>", "references": "<while-down-1@example.test>"},
        ],
    }


def self_test() -> int:
    """The judge must pass the good facts and go red, by its OWN assertion, on
    every mutant. Exit 1 (FAIL) is the expected, correct outcome of a
    self-test whose known-bad input was caught; exit 0 means a mutant slipped."""
    import io
    import contextlib

    def run(f: dict) -> tuple[int, str]:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = judge(f)
        return rc, buf.getvalue()

    rc, out = run(_good_facts())
    if rc != 0:
        print("SELF-TEST BROKEN: the good fixture did not PASS")
        print(out)
        return 0
    mutants: list[tuple[str, callable, str, int]] = []

    def m(name, fn, expect, code=1):
        mutants.append((name, fn, expect, code))

    def a(f):
        f["replies"].insert(0, {"phase": "start", "to": OWNER, "subject": "Re: Old", "in_reply_to": "", "references": ""})
    m("a pre-existing message was answered", a, "pre_existing_unread_not_answered")

    def b1(f):
        f["replies"][0]["subject"] = "ZeroClaw Message"
    m("reply carries the default subject, not Re:", b1, "owner_gets_one_threaded_reply")

    def b2(f):
        f["replies"][0]["in_reply_to"] = ""
        f["replies"][0]["references"] = ""
    m("reply carries no In-Reply-To or References", b2, "owner_gets_one_threaded_reply")

    def b3(f):
        f["replies"][0:1] = []
    m("the owner got no reply at all", b3, "owner_gets_one_threaded_reply")

    def b4(f):
        f["replies"].insert(1, dict(f["replies"][0]))
    m("the owner got two replies", b4, "owner_gets_one_threaded_reply")

    def c(f):
        f["replies"].append({"phase": "stranger", "to": STRANGER, "subject": "Re: Hello", "in_reply_to": "", "references": ""})
    m("a non-allowed sender was answered", c, "non_allowed_sender_not_answered")

    def d(f):
        f["replies"].append({"phase": "auto", "to": OWNER, "subject": "Re: OOO", "in_reply_to": "", "references": ""})
    m("an Auto-Submitted message was answered", d, "auto_submitted_not_answered")

    def e(f):
        f["replies"].append({"phase": "spoof", "to": OWNER, "subject": "Re: Spoofed", "in_reply_to": "", "references": ""})
    m("a dmarc=fail spoof was answered", e, "failed_dmarc_owner_not_answered")

    def g1(f):
        f["replies"].append({"phase": "restart", "to": OWNER, "subject": "Re: Old unread 0",
                             "in_reply_to": "<old-0@example.test>", "references": ""})
    m("restart re-answered an old message", g1, "restart_answers_only_the_new_mail")

    def g2(f):
        f["replies"] = [r for r in f["replies"] if r["phase"] != "restart"]
    m("restart did not answer the new message", g2, "restart_answers_only_the_new_mail")

    def h(f):
        f["connected"] = False
    m("the channel never connected (zero replies would read as clean)", h, "channel_alive", 1)

    def h2(f):
        f["daemon_started"] = False
    m("the daemon could not be started (nothing measured)", h2, "channel_alive", 78)

    caught = 0
    for name, fn, expect, code in mutants:
        f = copy.deepcopy(_good_facts())
        fn(f)
        rc, out = run(f)
        named = any(l.strip().startswith(("FAIL", "CANNOT")) and expect in l for l in out.splitlines())
        if rc == code and named:
            caught += 1
        else:
            print(f"SELF-TEST BROKEN: mutant not caught by its own assertion: {name} (rc={rc}, expected {code}/{expect})")
            print(out)
            return 0
    print(f"EXAMINED: {len(mutants)} mutated email-channel fact sets")
    print(f"negative control behaved: good facts PASS, {caught} of {len(mutants)} mutants went red by their own assertion")
    return 1


# ------------------------------------------------------------ server test
def server_test() -> int:
    """The mock IMAP and SMTP servers against stdlib clients. A mock that
    cannot be spoken to would make every probe verdict meaningless."""
    import imaplib
    import smtplib

    async def main() -> int:
        box, sink = Mailbox(), SmtpSink()
        for i in range(3):
            box.add(make_mail(OWNER, f"m{i}", f"<m{i}@example.test>"))
        ip, sp = _free_port(), _free_port()
        isrv = await asyncio.start_server(ImapServer(box).handle, "127.0.0.1", ip)
        ssrv = await asyncio.start_server(sink.handle, "127.0.0.1", sp)
        loop = asyncio.get_running_loop()

        def client() -> list[str]:
            out: list[str] = []
            c = imaplib.IMAP4("127.0.0.1", ip)
            out.append("login:" + c.login(ASSISTANT, PASSWORD)[0])
            typ, _ = c.select("INBOX")
            out.append("select:" + typ)
            typ, d = c.uid("SEARCH", None, "UID 2:* UNSEEN")
            out.append("search:" + d[0].decode())
            typ, d = c.uid("SEARCH", None, "UID 9:* UNSEEN")
            out.append("high:" + d[0].decode())
            typ, d = c.uid("FETCH", "2", "(RFC822)")
            out.append("fetch:" + ("m1" if b"Subject: m1" in d[0][1] else "bad"))
            typ, d = c.uid("SEARCH", None, "UID 1:* UNSEEN")
            out.append("after_fetch:" + d[0].decode())
            c.logout()
            s = smtplib.SMTP("127.0.0.1", sp)
            s.login(ASSISTANT, PASSWORD)
            s.sendmail(ASSISTANT, [OWNER], "Subject: Re: x\r\nIn-Reply-To: <a@b>\r\n\r\nbody\r\n")
            s.quit()
            return out

        res = await loop.run_in_executor(None, client)
        isrv.close()
        ssrv.close()
        want = ["login:OK", "select:OK", "search:2 3", "high:3", "fetch:m1", "after_fetch:1 3"]
        ok = res == want and len(sink.sent) == 1 and sink.sent[0]["rcpt"] == [OWNER] \
            and sink.sent[0]["msg"]["In-Reply-To"] == "<a@b>"
        print("server-test", "PASS" if ok else f"FAIL got={res} sent={len(sink.sent)}")
        return 0 if ok else 1

    return asyncio.run(main())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--server-test", action="store_true")
    sub = ap.add_subparsers(dest="mode")
    r = sub.add_parser("run")
    r.add_argument("--daemon", required=True)
    r.add_argument("--facts")
    r.add_argument("--keep-log")
    j = sub.add_parser("judge")
    j.add_argument("facts")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.server_test:
        return server_test()
    if a.mode == "judge":
        return judge(json.load(open(a.facts)))
    if a.mode == "run":
        if not os.access(a.daemon, os.X_OK):
            print(f"CANNOT-RUN: daemon binary not executable: {a.daemon}", file=sys.stderr)
            return 78
        facts = asyncio.run(drive(a.daemon, a.keep_log))
        out = json.dumps(facts, indent=1)
        if a.facts:
            open(a.facts, "w").write(out)
        print(out)
        return 0
    ap.print_help()
    return 78


if __name__ == "__main__":
    sys.exit(main())
