#!/usr/bin/env python3
"""End to end for the assistant's own email address, with the REAL components.

Driven by tests/e2e/assistant_mailbox_e2e.sh (which checks the preconditions and
makes the temporary keychain). Synthetic data only. Real parts:

  * the installer step: install.sh's helper block and flow function, run
    non-interactively (only the prompt reader is replaced by an answers file);
  * the probes and the Keychain writes: vendor/doctor/agent/assistant_mailbox.py;
  * the daemon: the release binary built from the ostler-assistant branch,
    started with the config the installer step generated;
  * the Doctor: assistant_mailbox.read_row / render_html / test_now;
  * the mail provider: tests/e2e/mailsim.py over real sockets, which stamps
    Authentication-Results on delivery.

Exit 0 all ok, 1 a check failed, 2 CANNOT-RUN. Never a silent pass.
"""
from __future__ import annotations

import json
import os
import random
import re
import signal
import socket
import string
import subprocess
import sys
import tempfile
import threading
import time
from email.utils import make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "vendor" / "doctor" / "agent"))

OWNER = "owner@example.test"
STRANGER = "stranger@example.test"
ASSISTANT = "tess.assistant@example.test"
NAME = "Tess"

results: list[tuple[str, str, str]] = []


def check(name: str, cond: bool, detail: str = "") -> bool:
    results.append(("ok" if cond else "FAIL", name, detail))
    print(f"{'ok:  ' if cond else 'FAIL:'} {name}" + (f"  [{detail}]" if detail else ""), flush=True)
    return cond


def cannot_run(why: str) -> None:
    print(f"CANNOT-RUN: {why}", flush=True)
    sys.exit(2)


def wait(pred, timeout: float, step: float = 0.25) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return bool(pred())


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Llm(BaseHTTPRequestHandler):  # stub model, as in the v1.0.107 email probe
    def log_message(self, *a): pass

    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self): self._json({"models": [{"name": "stub", "model": "stub"}]})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        msg = {"role": "assistant", "content": "Synthetic reply from the loopback model."}
        base = {"model": req.get("model", "stub"), "created_at": "2026-10-15T00:00:00Z"}
        if req.get("stream", True) and self.path.endswith("/api/chat"):
            self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.end_headers()
            self.wfile.write((json.dumps({**base, "message": msg, "done": False}) + "\n").encode())
            self.wfile.write((json.dumps({**base, "message": {"role": "assistant", "content": ""}, "done": True,
                                          "done_reason": "stop", "total_duration": 1,
                                          "prompt_eval_count": 1, "eval_count": 1}) + "\n").encode())
            return
        self._json({**base, "message": msg, "done": True, "done_reason": "stop",
                    "prompt_eval_count": 1, "eval_count": 1})


def mail(sender, subject, msgid, extra="", body="hello", signed=True, to=ASSISTANT) -> bytes:
    dom = sender.rsplit("@", 1)[1]
    sig = f"X-Sim-Signed-By: {dom}\r\n" if signed else ""
    return (f"From: <{sender}>\r\nTo: <{to}>\r\nSubject: {subject}\r\nMessage-ID: {msgid}\r\n"
            f"Date: Thu, 15 Oct 2026 10:00:00 +0000\r\nMIME-Version: 1.0\r\n"
            f"Content-Type: text/plain; charset=utf-8\r\n{sig}{extra}\r\n{body}\r\n").encode()


def main() -> int:
    binary = os.environ.get("OSTLER_E2E_DAEMON", "")
    if not binary or not os.access(binary, os.X_OK):
        cannot_run(f"OSTLER_E2E_DAEMON is not an executable daemon binary ({binary!r})")
    keychain = os.environ.get("OSTLER_E2E_KEYCHAIN", "")
    if not keychain or not os.path.exists(keychain):
        cannot_run("OSTLER_E2E_KEYCHAIN (a temporary keychain file) is missing")

    import mailsim

    root = Path(tempfile.mkdtemp(prefix="ostler-am-e2e-"))
    home = root / "home"; ostler = home / ".ostler"; cfgdir = root / "cfg"
    (ostler / "secrets").mkdir(parents=True); (cfgdir / "workspace").mkdir(parents=True)
    password = "".join(random.choice(string.ascii_lowercase) for _ in range(16))

    sim = mailsim.Sim(ASSISTANT, password)
    sim.start()
    llm_port = free_port()
    httpd = ThreadingHTTPServer(("127.0.0.1", llm_port), Llm)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    gw_port = free_port()

    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        env.pop(k, None)
    env.update({
        "OSTLER_E2E_LOOPBACK": "1",
        "OSTLER_E2E_IMAP_PORT": str(sim.ports["imap"]),
        "OSTLER_E2E_SMTP_PORT": str(sim.ports["submission"]),
        "HOME": str(home), "OSTLER_HOME": str(ostler), "OSTLER_DIR": str(ostler),
        "ZEROCLAW_CONFIG_DIR": str(cfgdir), "ZEROCLAW_WORKSPACE": str(cfgdir / "workspace"),
        "OSTLER_ASSISTANT_CONFIG": str(cfgdir / "config.toml"),
        "OSTLER_CHAT_GATEWAY_PORT": str(gw_port),
        "OSTLER_CHAT_ADMIN_TOKEN_FILE": str(ostler / "secrets" / "zeroclaw_admin_token"),
        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
        "RUST_LOG": "warn,zeroclaw_channels=info",
    })
    os.environ.update({k: env[k] for k in env if k.startswith(("OSTLER_", "HOME"))})
    token = "".join(random.choice(string.hexdigits.lower()) for _ in range(64))
    (ostler / "secrets" / "zeroclaw_admin_token").write_text(token)
    os.chmod(ostler / "secrets" / "zeroclaw_admin_token", 0o600)

    base = cfgdir / "base.toml"
    base.write_text(f'''schema_version = 2

[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://127.0.0.1:{llm_port}"
model = "stub"
timeout_secs = 30

[channels.email]
enabled = false
imap_host = "127.0.0.1"
imap_port = 1
imap_tls = false
smtp_host = "127.0.0.1"
smtp_port = 1
smtp_tls = false
username = "unused"
password = "unused"
from_address = "unused@example.test"
allowed_senders = ["{OWNER}"]
''')
    answers = root / "answers.txt"
    answers.write_text(f"am_choose=loopback\nam_address={ASSISTANT}\nam_password={password}\n")
    config = cfgdir / "config.toml"
    state = ostler / "state" / "email_assistant_status.json"
    daemon_log = root / "daemon.log"
    proc: dict = {"p": None}

    def start_daemon():
        log = open(daemon_log, "ab")
        proc["p"] = subprocess.Popen(
            [binary, "daemon", "--host", "127.0.0.1", "--port", str(gw_port)],
            env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)

    def stop_daemon():
        p = proc["p"]
        if p is None:
            return
        try:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=10)
        except Exception:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except Exception:
                pass
        proc["p"] = None

    def status() -> dict:
        try:
            return json.loads(state.read_text())
        except (OSError, ValueError):
            return {}

    def kc_has(use_keychain: bool) -> str:
        cmd = ["security", "find-generic-password", "-s", "Ostler Assistant Mailbox", "-a", ASSISTANT, "-w"]
        if use_keychain:
            cmd.append(keychain)
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""

    try:
        import assistant_mailbox as am
        check("loopback seam is on only because this run set it",
              am.E2E_LOOPBACK and "loopback" in am.PROVIDERS)

        # ---------------------------------------------------------------- (a)
        step_env = dict(env)
        step_env.update({"E2E_REPO": str(REPO), "E2E_ANSWERS": str(answers), "E2E_BASE_CONFIG": str(base),
                        "E2E_OUT_CONFIG": str(config), "E2E_OWNER": OWNER})
        r = subprocess.run(["/bin/bash", str(HERE / "drive_installer_step.sh")], env=step_env,
                           capture_output=True, text=True, timeout=180)
        out = r.stdout
        if r.returncode == 2 and "CANNOT-RUN" in out:
            cannot_run(out.strip())
        strings = (REPO / "install.sh.strings.en-GB.sh").read_text()

        def msg(name):
            return re.search(rf'^{name}="(.*)"$', strings, re.M).group(1)
        imap_ok, smtp_ok, self_ok = msg("MSG_OK_AM_IMAP"), msg("MSG_OK_AM_SMTP"), msg("MSG_OK_AM_SELFTEST")
        hello_ok = msg("MSG_OK_AM_HELLO_SENT") % OWNER
        check("(a) validation ticks: IMAP login + SELECT, then SMTP AUTH",
              f"[ok] {imap_ok}" in out and f"[ok] {smtp_ok}" in out, out.replace("\n", " | ")[:300])
        check("(a) installer self-test and hello both reported ok",
              f"[ok] {self_ok}" in out and f"[ok] {hello_ok}" in out)
        check("(a) installer finished enabled, address recorded",
              "ENABLED=true" in out and f"ADDRESS={ASSISTANT}" in out)
        check("(a) nothing was sent by the SMTP probe itself (AUTH only): sends = self-test + hello",
              [s["rcpt"] for s in sim.submission.sent] == [[ASSISTANT], [OWNER]],
              str([s["rcpt"] for s in sim.submission.sent]))
        check("(a) bad credentials are refused by the server (control: the probes can fail)",
              am.probe("loopback", ASSISTANT, "z" * 16)["imap"] != "ok" and sim.box.bad_logins >= 1)
        check("(a) password is in the TEMPORARY keychain",
              kc_has(True) == password)
        check("(a) control: the same lookup without the temporary keychain finds nothing",
              kc_has(False) == "")
        cfg_text = config.read_text()
        check("(a) password is not in config, installer output or the daemon-visible state",
              password not in cfg_text and password not in out and password not in r.stderr)
        hello_sent = sim.submission.sent[1]
        hello_id = str(hello_sent["msg"]["Message-ID"])
        m = re.search(r'^hello_message_id = "(.*)"$', cfg_text, re.M)
        check("(c) config records the hello mail's real Message-ID (as the server received it)",
              bool(m) and m.group(1) == hello_id and hello_sent["msg"]["Subject"] == f"Hello from {NAME}",
              f"config={m.group(1) if m else None} sent={hello_id}")
        check("(c) config starts with nobody verified",
              "owner_addresses_verified = []" in cfg_text)

        # ------------------------------------------------------------ daemon
        start_daemon()
        check("daemon connects to the mailbox and keeps polling",
              wait(lambda: sim.box.logins >= 3 and sim.box.searches >= 3, 90),
              f"logins={sim.box.logins} searches={sim.box.searches}")
        if sim.box.searches < 3:
            print(daemon_log.read_text()[-3000:])
            return finish(1)
        row0 = am.read_row(config, ostler / "state")
        check("(b) before any test: Doctor shows the self-test as not run",
              row0.get("selftest_result") is None and "Not run yet" in am.render_html(row0))

        # ---------------------------------------------------------------- (b)
        os.environ["OSTLER_CHAT_ADMIN_TOKEN_FILE"] = str(ostler / "secrets" / "zeroclaw_admin_token")
        good = am.test_now()
        check("(b) Doctor 'Test now' -> daemon endpoint -> self-test round trip passes",
              good == {"result": "ok"}, str(good))
        st = status()
        check("(b) the daemon's status file holds the result (single source of truth)",
              st.get("self_test_result") == "ok" and bool(st.get("self_test_at")), str(st.get("self_test_result")))
        row1 = am.read_row(config, ostler / "state")
        check("(b) the Doctor card reads that result from the daemon's file",
              row1.get("selftest_result") == "ok" and "Passed" in am.render_html(row1))
        check("(b) the Doctor wrote no self-test file of its own",
              not (ostler / "state" / "email_assistant_selftest.json").exists())
        (ostler / "secrets" / "zeroclaw_admin_token").write_text("0" * 64)
        bad = am.test_now()
        (ostler / "secrets" / "zeroclaw_admin_token").write_text(token)
        check("(b) control: a wrong token is reported as unreachable, never as a pass",
              bad == {"result": "daemon_unreachable"}, str(bad))

        # ---------------------------------------------------------------- (c)
        def drops() -> dict:
            return dict(status().get("drops_24h") or {})

        def deliver(raw: bytes) -> None:
            import smtplib
            with smtplib.SMTP("127.0.0.1", sim.ports["mx"], timeout=20) as s:
                frm = re.search(rb"From: <([^>]+)>", raw).group(1).decode()
                s.sendmail(frm, [ASSISTANT], raw)

        def replies_to(addr):
            return [s for s in sim.submission.sent if addr in s["rcpt"]
                    and str(s["msg"]["Subject"]).startswith("Re:")]

        def settle(uid_box_before: int, secs: float = 25) -> None:
            wait(lambda: all(m["seen"] for m in sim.box.msgs if m["uid"] > uid_box_before), secs)
            time.sleep(3)

        before = sim.box.next_uid - 1
        deliver(mail(OWNER, "Re: Hello from Tess", "<wrong-thread@example.test>",
                     extra="In-Reply-To: <someone-else@example.test>\r\n"))
        settle(before)
        cfg_now = config.read_text()
        check("(c) a 'Re: Hello from' mail that cites another message does NOT verify the owner",
              OWNER not in re.search(r"owner_addresses_verified = \[(.*)\]", cfg_now).group(1)
              and drops().get("not_listed") == 1 and not replies_to(OWNER), str(drops()))
        before = sim.box.next_uid - 1
        deliver(mail(OWNER, "Re: Hello from Tess", "<handshake-forged@example.test>",
                     extra=f"In-Reply-To: {hello_id}\r\n", signed=False))
        settle(before)
        check("(c) control: a forged reply citing the right id (no valid signature) does not verify",
              OWNER not in re.search(r"owner_addresses_verified = \[(.*)\]", config.read_text()).group(1)
              and drops().get("failed_auth") == 1, str(drops()))
        before = sim.box.next_uid - 1
        deliver(mail(OWNER, "Re: Hello from Tess", "<handshake-1@example.test>",
                     extra=f"In-Reply-To: {hello_id}\r\n", body="yes"))
        ok = wait(lambda: OWNER in config.read_text().split("owner_addresses_verified", 1)[1].split("\n", 1)[0], 30)
        check("(c) the owner's authenticated reply carrying the hello Message-ID verifies the address",
              ok, config.read_text().split("owner_addresses_verified", 1)[1].split("\n", 1)[0])
        check("(c) status file records owner_verified_at; Doctor shows the address confirmed",
              OWNER in (status().get("owner_verified_at") or {}) and
              am.read_row(config, ostler / "state").get("owner_verified") is True and
              "Yes" in am.render_html(am.read_row(config, ostler / "state")))
        check("(c) the handshake itself is not answered", not replies_to(OWNER))

        # ---------------------------------------------------------------- (d)
        before = sim.box.next_uid - 1
        mid = "<lunch-1@example.test>"
        deliver(mail(OWNER, "Lunch plans", mid))
        got = wait(lambda: replies_to(OWNER), 60)
        rep = replies_to(OWNER)[0]["msg"] if got else None
        check("(d) the owner's mail gets exactly one reply", got and len(replies_to(OWNER)) == 1)
        if rep is not None:
            check("(d) reply is FROM the assistant address, to the owner",
                  ASSISTANT in str(rep["From"]).lower() and OWNER in str(rep["To"]).lower(),
                  f"from={rep['From']} to={rep['To']}")
            check("(d) reply is threaded: Re: subject, In-Reply-To and References carry the inbound id",
                  rep["Subject"] == "Re: Lunch plans" and rep["In-Reply-To"] == mid
                  and mid in str(rep["References"]).split(), f"{rep['Subject']} {rep['In-Reply-To']} {rep['References']}")
            check("(d) reply carries Auto-Submitted", bool(rep["Auto-Submitted"]), str(rep["Auto-Submitted"]))
            check("(d) the reply went out through the authenticated submission door",
                  replies_to(OWNER)[0]["auth_user"] == ASSISTANT)
        check("(d) the Doctor shows a last reply time",
              am.read_row(config, ostler / "state").get("last_reply") is not None)

        # ---------------------------------------------------------------- (e)
        d0 = drops()
        sent0 = len(sim.submission.sent)
        before = sim.box.next_uid - 1
        deliver(mail(OWNER, "Wire the money", "<forged-1@example.test>", signed=False))
        deliver(mail(STRANGER, "Hello", "<stranger-1@example.test>"))
        deliver(mail(OWNER, "Out of office", "<auto-1@example.test>", extra="Auto-Submitted: auto-replied\r\n"))
        settle(before, 40)
        d1 = drops()
        check("(e) forged From (no valid signature) is counted under failed_auth",
              d1.get("failed_auth", 0) == d0.get("failed_auth", 0) + 1, str(d1))
        check("(e) an unlisted sender is counted under not_listed",
              d1.get("not_listed", 0) == d0.get("not_listed", 0) + 1, str(d1))
        check("(e) automated mail from the owner is counted under automated",
              d1.get("automated", 0) == d0.get("automated", 0) + 1, str(d1))
        check("(e) none of the three got any reply", len(sim.submission.sent) == sent0,
              f"{len(sim.submission.sent) - sent0} extra sends")
        canon = {"not_listed", "failed_auth", "automated", "rate_limited"}
        check("(e) every counted reason is in the canonical set", set(d1) <= canon, str(d1))

        stop_daemon()
        wait(lambda: False, 1)
        start_daemon()
        wait(lambda: sim.box.logins >= 6, 60)
        check("(e) after a daemon restart the drop counts survive", drops() == d1, f"{drops()} vs {d1}")
        # The file alone can look right until the daemon next writes it, so make
        # it write: one more unlisted sender, and every old count must still be there.
        before = sim.box.next_uid - 1
        deliver(mail(STRANGER, "Hello again", "<stranger-2@example.test>"))
        settle(before, 40)
        d2 = drops()
        want = dict(d1, not_listed=d1.get("not_listed", 0) + 1)
        check("(e) after a restart AND a new drop, the old counts are still there (not reset)",
              d2 == want, f"{d2} vs {want}")
        before = sim.box.next_uid - 1
        n_rep = len(replies_to(OWNER))
        deliver(mail(OWNER, "After restart", "<after-1@example.test>"))
        check("(e) after the restart the verified owner is still answered",
              wait(lambda: len(replies_to(OWNER)) == n_rep + 1, 60))

        # ---------------------------------------------------------------- (f)
        row = am.read_row(config, ostler / "state")
        html = am.render_html(row)
        check("(f) Doctor row equals the daemon's status",
              row["drops_24h"] == drops() and row["selftest_result"] == "ok" and row["owner_verified"]
              and row["address"] == ASSISTANT and row["enabled"] is True, str(row))
        check("(f) Doctor card text shows address, every counted reason, self-test, confirmation",
              all(x in html for x in (ASSISTANT, "Passed", "Yes", "Test now"))
              and all(f"{k}: {v}" in html for k, v in drops().items()))
        check("(f) the card never carries the password or the secret reference",
              password not in html and "keychain:" not in html)
    finally:
        stop_daemon()
        sim.stop()
        httpd.shutdown()
        if os.environ.get("E2E_KEEP"):
            print(f"kept: {root}")
        else:
            try:
                tail = daemon_log.read_text()[-2000:] if daemon_log.exists() else ""
                if any(r[0] == "FAIL" for r in results):
                    print("--- daemon log tail ---\n" + tail)
            except OSError:
                pass
            subprocess.run(["rm", "-rf", str(root)])
    return finish(0)


def finish(rc: int) -> int:
    fails = [r for r in results if r[0] == "FAIL"]
    print(f"\n{len(results) - len(fails)} ok, {len(fails)} FAIL, {len(results)} checks", flush=True)
    return 1 if fails or rc else 0


if __name__ == "__main__":
    sys.exit(main())
