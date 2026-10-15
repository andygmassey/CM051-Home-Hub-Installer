#!/usr/bin/env python3
"""A small loopback mail provider for the assistant-mailbox end-to-end run.

Synthetic only (example.test); plaintext; 127.0.0.1 only. Three doors:

  IMAP        the assistant's INBOX (LOGIN needs the right password).
  SUBMISSION  SMTP with AUTH, how the assistant (and the installer's probes)
              SEND. Mail addressed to the assistant lands in its INBOX; the rest
              is recorded in ``sent`` for the test to read.
  MX          SMTP without AUTH, how the outside world (the owner, a stranger,
              a forger) delivers INTO the assistant's INBOX.

AUTHENTICATION-RESULTS ARE STAMPED ON DELIVERY, as a real provider does. Any
Authentication-Results header the sender supplied is stripped first, and a new
one is put at the TOP. A message is "signed" only if it carries
``X-Sim-Signed-By: <domain>`` AND that domain is the From domain, which stands
in for a DKIM signature only the real domain's owner can make. Signed means
``dkim=pass header.d=D; dmarc=pass header.from=D``; anything else is
``dmarc=fail``. The marker header is removed before storage.

Not a mock of the product: the product's IMAP/SMTP clients (the daemon's
async-imap and lettre, the installer's imaplib and smtplib) talk to it over
real sockets.
"""
from __future__ import annotations

import asyncio
import email
import email.utils
import re
import threading
import time
from email import policy as _policy

UIDVALIDITY = 7001


class Mailbox:
    def __init__(self, address: str, password: str) -> None:
        self.address, self.password = address.lower(), password
        self.msgs: list[dict] = []  # {uid, raw, seen, deleted, when}
        self.next_uid = 1
        self.logins = 0
        self.bad_logins = 0
        self.searches = 0
        self.lock = threading.Lock()

    def add(self, raw: bytes, seen: bool = False) -> int:
        with self.lock:
            uid = self.next_uid
            self.next_uid += 1
            self.msgs.append({"uid": uid, "raw": raw, "seen": seen, "deleted": False,
                              "when": time.time()})
            return uid

    def get(self, uid: int):
        for m in self.msgs:
            if m["uid"] == uid:
                return m
        return None

    def subjects(self) -> list[str]:
        out = []
        for m in self.msgs:
            if not m["deleted"]:
                out.append(email.message_from_bytes(m["raw"], policy=_policy.default).get("Subject", ""))
        return out


# --------------------------------------------------------------------- IMAP
def _range(spec: str, top: int):
    out = []
    for part in spec.split(","):
        a, _, b = part.partition(":")
        lo = int(a) if a != "*" else top
        hi = top if b in ("*",) else (int(b) if b else lo)
        out.append((lo, hi))
    return out


def _in(sets, n) -> bool:
    return any(lo <= n <= hi for lo, hi in sets)


_TOK = re.compile(r'"((?:[^"\\]|\\.)*)"|(\S+)')


def _tokens(s: str) -> list[str]:
    return [m.group(1) if m.group(1) is not None else m.group(2) for m in _TOK.finditer(s)]


class ImapServer:
    def __init__(self, box: Mailbox) -> None:
        self.box = box

    def _live(self):
        return [m for m in self.box.msgs if not m["deleted"]]

    def _match(self, m, toks) -> bool:
        up = [t.upper() for t in toks]
        if "UNSEEN" in up and m["seen"]:
            return False
        if "SUBJECT" in up:
            want = toks[up.index("SUBJECT") + 1].lower()
            subj = email.message_from_bytes(m["raw"], policy=_policy.default).get("Subject", "")
            if want not in str(subj).lower():
                return False
        return True

    async def handle(self, reader, writer) -> None:
        box = self.box
        authed = False

        def send(s: str) -> None:
            writer.write(s.encode() + b"\r\n")

        send("* OK [CAPABILITY IMAP4rev1] sim ready")
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
                live = self._live()
                if cmd == "CAPABILITY":
                    send("* CAPABILITY IMAP4rev1")
                    send(f"{tag} OK done")
                elif cmd == "LOGIN":
                    t = _TOK.findall(args)
                    user = (t[0][0] or t[0][1]).lower() if t else ""
                    pw = (t[1][0] or t[1][1]) if len(t) > 1 else ""
                    if user == box.address and pw == box.password:
                        authed = True
                        box.logins += 1
                        send(f"{tag} OK LOGIN completed")
                    else:
                        box.bad_logins += 1
                        send(f"{tag} NO [AUTHENTICATIONFAILED] Invalid credentials")
                elif not authed:
                    send(f"{tag} NO not authenticated")
                elif cmd in ("SELECT", "EXAMINE"):
                    send(f"* {len(live)} EXISTS")
                    send("* 0 RECENT")
                    send("* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)")
                    send(f"* OK [UIDVALIDITY {UIDVALIDITY}] UIDs valid")
                    send(f"* OK [UIDNEXT {box.next_uid}] Predicted next UID")
                    send("* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] ok")
                    send(f"{tag} OK [READ-WRITE] {cmd} completed")
                elif cmd == "NOOP":
                    send(f"{tag} OK NOOP completed")
                elif cmd in ("SEARCH", "UID") and (cmd == "SEARCH" or args.upper().startswith("SEARCH")):
                    box.searches += 1
                    crit = args if cmd == "SEARCH" else args.split(" ", 1)[1]
                    toks = _tokens(crit)
                    up = [t.upper() for t in toks]
                    uidset = None
                    if "UID" in up:
                        top = max((m["uid"] for m in live), default=0)
                        uidset = _range(toks[up.index("UID") + 1], top)
                    hits = []
                    for seq, m in enumerate(live, 1):
                        if uidset is not None and not _in(uidset, m["uid"]):
                            continue
                        if self._match(m, toks):
                            hits.append(m["uid"] if cmd == "UID" else seq)
                    # RFC 3501: `n:*` always includes the highest UID.
                    if cmd == "UID" and uidset is not None and live:
                        top_m = live[-1]
                        if top_m["uid"] < uidset[0][0] and self._match(top_m, toks):
                            hits = [top_m["uid"]]
                    send("* SEARCH" + "".join(f" {h}" for h in sorted(hits)))
                    send(f"{tag} OK SEARCH completed")
                elif cmd in ("FETCH", "STORE") or (cmd == "UID" and args.split(" ", 1)[0].upper() in ("FETCH", "STORE")):
                    by_uid = cmd == "UID"
                    sub = args.split(" ", 1)[0].upper() if by_uid else cmd
                    body = args.split(" ", 1)[1] if by_uid else args
                    spec, _, rest2 = body.partition(" ")
                    top = max((m["uid"] if by_uid else i for i, m in enumerate(live, 1)), default=0)
                    sets = _range(spec, top)
                    for seq, m in enumerate(live, 1):
                        key = m["uid"] if by_uid else seq
                        if not _in(sets, key):
                            continue
                        if sub == "FETCH":
                            r = rest2.upper()
                            parts = [f"UID {m['uid']}"]
                            if "INTERNALDATE" in r:
                                d = time.strftime("%d-%b-%Y %H:%M:%S +0000", time.gmtime(m["when"]))
                                parts.append(f'INTERNALDATE "{d}"')
                            if "FLAGS" in r:
                                parts.append("FLAGS (" + ("\\Seen" if m["seen"] else "") + ")")
                            raw = m["raw"]
                            if "RFC822" in r or "BODY" in r:
                                m["seen"] = m["seen"] or "PEEK" not in r
                                label = "BODY[]" if "BODY" in r else "RFC822"
                                head = " ".join(parts) + f" {label} {{{len(raw)}}}"
                                writer.write(f"* {seq} FETCH ({head}\r\n".encode() + raw + b")\r\n")
                            else:
                                send(f"* {seq} FETCH ({' '.join(parts)})")
                        else:  # STORE
                            r = rest2.upper()
                            if "\\SEEN" in r:
                                m["seen"] = "-FLAGS" not in r
                            if "\\DELETED" in r:
                                m["deleted"] = "-FLAGS" not in r
                            send(f"* {seq} FETCH (UID {m['uid']} FLAGS ("
                                 + ("\\Deleted" if m["deleted"] else "") + ("\\Seen" if m["seen"] else "") + "))")
                    send(f"{tag} OK {sub} completed")
                elif cmd == "EXPUNGE":
                    seq = 0
                    for m in list(box.msgs):
                        if m["deleted"]:
                            send(f"* {seq + 1} EXPUNGE")
                            box.msgs.remove(m)
                        else:
                            seq += 1
                    send(f"{tag} OK EXPUNGE completed")
                elif cmd == "CLOSE":
                    box.msgs[:] = [m for m in box.msgs if not m["deleted"]]
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


# --------------------------------------------------------------------- SMTP
def stamp(raw: bytes) -> bytes:
    """Strip any sender-supplied Authentication-Results and the signing marker,
    then put a freshly computed Authentication-Results at the very top."""
    head, sep, body = raw.partition(b"\r\n\r\n")
    if not sep:
        head, sep, body = raw.partition(b"\n\n")
    msg = email.message_from_bytes(head + b"\r\n\r\n", policy=_policy.compat32)
    signed_by = (msg.get("X-Sim-Signed-By") or "").strip().lower()
    _, frm = email.utils.parseaddr(msg.get("From", ""))
    dom = frm.rsplit("@", 1)[-1].lower() if "@" in frm else ""
    lines = [ln for ln in head.decode("utf-8", "replace").splitlines()]
    kept, skip = [], False
    for ln in lines:
        if ln[:1] in (" ", "\t"):
            if not skip:
                kept.append(ln)
            continue
        name = ln.split(":", 1)[0].lower()
        skip = name in ("authentication-results", "x-sim-signed-by")
        if not skip:
            kept.append(ln)
    if dom and signed_by == dom:
        ar = f"Authentication-Results: mx.sim.example.test; dkim=pass header.d={dom}; dmarc=pass header.from={dom}"
    else:
        ar = f"Authentication-Results: mx.sim.example.test; dmarc=fail header.from={dom or 'unknown'}"
    return ("\r\n".join([ar] + kept) + "\r\n\r\n").encode() + body


class SmtpDoor:
    """``mode`` is "submission" (AUTH required) or "mx" (no AUTH)."""

    def __init__(self, box: Mailbox, mode: str) -> None:
        self.box, self.mode = box, mode
        self.sent: list[dict] = []  # {rcpt, raw, msg, auth_user, at}
        self.bad_auth = 0

    async def handle(self, reader, writer) -> None:
        def send(s: str) -> None:
            writer.write(s.encode() + b"\r\n")

        send("220 sim ESMTP")
        await writer.drain()
        rcpts: list[str] = []
        auth_user = None
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                t = line.decode(errors="replace").rstrip("\r\n")
                up = t.upper()
                if up.startswith(("EHLO", "HELO")):
                    send("250-sim")
                    if self.mode == "submission":
                        send("250-AUTH PLAIN LOGIN")
                    send("250 8BITMIME")
                elif up.startswith("AUTH PLAIN"):
                    import base64
                    tok = t.split()[2] if len(t.split()) > 2 else ""
                    try:
                        _, user, pw = base64.b64decode(tok).decode().split("\x00")
                    except Exception:
                        user, pw = "", ""
                    if user.lower() == self.box.address and pw == self.box.password:
                        auth_user = user.lower()
                        send("235 2.7.0 ok")
                    else:
                        self.bad_auth += 1
                        send("535 5.7.8 Authentication failed")
                elif up.startswith("AUTH LOGIN"):
                    import base64
                    send("334 VXNlcm5hbWU6")
                    await writer.drain()
                    user = base64.b64decode((await reader.readline()).strip()).decode(errors="replace")
                    send("334 UGFzc3dvcmQ6")
                    await writer.drain()
                    pw = base64.b64decode((await reader.readline()).strip()).decode(errors="replace")
                    if user.lower() == self.box.address and pw == self.box.password:
                        auth_user = user.lower()
                        send("235 2.7.0 ok")
                    else:
                        self.bad_auth += 1
                        send("535 5.7.8 Authentication failed")
                elif up.startswith("MAIL FROM"):
                    if self.mode == "submission" and not auth_user:
                        send("530 5.7.0 Authentication required")
                    else:
                        rcpts = []
                        send("250 ok")
                elif up.startswith("RCPT TO"):
                    rcpts.append(t[t.find("<") + 1: t.rfind(">")].lower())
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
                    self._deliver(rcpts, buf, auth_user)
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

    def _deliver(self, rcpts, raw: bytes, auth_user) -> None:
        msg = email.message_from_bytes(raw, policy=_policy.default)
        self.sent.append({"rcpt": list(rcpts), "raw": raw, "msg": msg, "auth_user": auth_user,
                          "at": time.time(), "door": self.mode})
        if self.box.address in rcpts:
            self.box.add(stamp(raw))


# --------------------------------------------------------------- the server
class Sim:
    """Runs the three listeners on a private event loop in a thread."""

    def __init__(self, address: str, password: str) -> None:
        self.box = Mailbox(address, password)
        self.imap = ImapServer(self.box)
        self.submission = SmtpDoor(self.box, "submission")
        self.mx = SmtpDoor(self.box, "mx")
        self.ports: dict[str, int] = {}
        self._loop = asyncio.new_event_loop()
        self._ready = threading.Event()
        self._servers: list = []
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)

        async def boot():
            for name, h in (("imap", self.imap.handle), ("submission", self.submission.handle),
                            ("mx", self.mx.handle)):
                srv = await asyncio.start_server(h, "127.0.0.1", 0)
                self._servers.append(srv)
                self.ports[name] = srv.sockets[0].getsockname()[1]
            self._ready.set()

        self._loop.run_until_complete(boot())
        self._loop.run_forever()

    def start(self) -> None:
        self._thread.start()
        if not self._ready.wait(10):
            raise RuntimeError("mail simulator did not start")

    def stop(self) -> None:
        def _stop():
            for s in self._servers:
                s.close()
            for t in asyncio.all_tasks(self._loop):
                t.cancel()
            self._loop.call_later(0.3, self._loop.stop)
        self._loop.call_soon_threadsafe(_stop)
        self._thread.join(5)
