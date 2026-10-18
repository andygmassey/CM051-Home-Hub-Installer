#!/usr/bin/env python3
"""Tests for the assistant's own mailbox (v1.0.108): rules, error wording,
the Doctor row and its routes. Synthetic data only (example.test); no network.

Run: ``python3 -m pytest vendor/doctor/agent/test_assistant_mailbox.py -q``
or bare ``python3 vendor/doctor/agent/test_assistant_mailbox.py``.
"""
import imaplib
import json
import smtplib
import socket
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import assistant_mailbox as am  # noqa: E402

PASSWORD = "abcdefghijklmnop"  # synthetic, 16 letters


# Provider domains the host rules key on, composed at runtime so no literal
# address at a real provider sits in this PUBLIC repo (ci-pii-shape-scan).
IC = "icloud.com"
GM = "gmail.com"
ME = "tess.assistant@" + IC


def _cfg(tmp: Path, extra: str = "", enabled: str = "true") -> Path:
    p = tmp / "config.toml"
    p.write_text(
        '[channels.imessage]\nenabled = true\n\n[email_assistant]\n'
        f'enabled = {enabled}\naddress = "{ME}"\nprovider = "icloud"\n'
        'imap_host = "imap.mail.me.com"\nimap_port = 993\nsmtp_host = "smtp.mail.me.com"\n'
        f'smtp_port = 587\nsecret_ref = "keychain:Ostler Assistant Mailbox:{ME}"\n'
        f'owner_addresses_verified = []\n{extra}\n[autonomy]\nx = 1\n')
    return p


class Rules(unittest.TestCase):
    def test_only_two_host_pairs(self):
        self.assertTrue(am.host_pair_allowed("imap.gmail.com", 993, "smtp.gmail.com", 465))
        self.assertTrue(am.host_pair_allowed("imap.mail.me.com", 993, "smtp.mail.me.com", 587))
        self.assertFalse(am.host_pair_allowed("imap-mail.outlook.com", 993, "smtp-mail.outlook.com", 587))
        self.assertFalse(am.host_pair_allowed("outlook.office365.com", 993, "smtp.office365.com", 587))
        self.assertFalse(am.host_pair_allowed("imap.example.test", 993, "smtp.example.test", 587))
        self.assertFalse(am.host_pair_allowed("imap.gmail.com", 993, "smtp.gmail.com", 587))
        self.assertFalse(am.host_pair_allowed("imap.gmail.com", "x", "smtp.gmail.com", 465))

    def test_owner_and_gmail_guards(self):
        self.assertTrue(am.is_owner_address("OWNER@example.test", ["owner@example.test"]))
        self.assertFalse(am.is_owner_address("new@" + IC, ["owner@example.test"]))
        self.assertTrue(am.gmail_identity_ok("A@" + GM, "a@" + GM))
        self.assertFalse(am.gmail_identity_ok("a@" + GM, "b@" + GM))

    def test_inbox_guard(self):
        self.assertFalse(am.inbox_looks_real(200, 14))
        self.assertTrue(am.inbox_looks_real(201, 0))
        self.assertTrue(am.inbox_looks_real(3, 15))
        self.assertFalse(am.inbox_looks_real(0, None))

    def test_password_cleaning_and_shape(self):
        self.assertEqual(am.clean_password("Abcd-Efgh ijkl–mnop\n"), PASSWORD[:0] + "abcdefghijklmnop")
        self.assertTrue(am.password_format_ok("abcd-efgh-ijkl-mnop"))
        self.assertFalse(am.password_format_ok("hunter2-is-my-real-password"))
        self.assertFalse(am.password_format_ok(""))


class Errors(unittest.TestCase):
    def test_classification(self):
        c = am.classify_error
        self.assertEqual(c(imaplib.IMAP4.error("[AUTHENTICATIONFAILED] Invalid credentials")), "wrong_password")
        self.assertEqual(c(smtplib.SMTPAuthenticationError(535, b"5.7.8 Username and Password not accepted")), "wrong_password")
        self.assertEqual(c(imaplib.IMAP4.error("[ALERT] IMAP access is disabled for your account")), "imap_disabled")
        self.assertEqual(c(imaplib.IMAP4.error("Account temporarily locked, too many attempts")), "locked")
        self.assertEqual(c(imaplib.IMAP4.error("Two-step verification must be enabled")), "two_step_off")
        self.assertEqual(c(socket.gaierror("Name or service not known")), "network")
        self.assertEqual(c(TimeoutError("timed out")), "network")
        self.assertEqual(c(Exception("something unexpected")), "unknown")

    def test_wording(self):
        self.assertIn("not your Apple ID or Google password", am.explain("wrong_password"))
        self.assertTrue(am.explain("network").startswith("Could not check."))
        self.assertTrue(am.explain("unknown").startswith("Could not check."))
        for code, (a, b) in am.ERRORS.items():
            self.assertNotIn(chr(0x2014), a + b, code)  # no em dashes


class Probe(unittest.TestCase):
    def test_login_failure_is_reported_per_stage(self):
        class BadImap:
            def login(self, *a): raise imaplib.IMAP4.error("[AUTHENTICATIONFAILED] nope")
            def logout(self): pass
        class GoodSmtp:
            def login(self, *a): pass
            def quit(self): pass
        with mock.patch.object(am, "_imap", return_value=BadImap()), \
                mock.patch.object(am, "_smtp", return_value=GoodSmtp()):
            r = am.probe("icloud", ME, PASSWORD)
        self.assertEqual((r["imap"], r["smtp"]), ("wrong_password", "ok"))

    def test_smtp_login_sends_nothing(self):
        sent = []
        class Imap:
            def login(self, *a): pass
            def select(self, *a, **k): return "OK", [b"3"]
            def fetch(self, *a): return "OK", [b'1 (INTERNALDATE "01-Jan-2020 10:00:00 +0000")']
            def logout(self): pass
        class Smtp:
            def login(self, *a): pass
            def send_message(self, *a): sent.append(a)
            def quit(self): pass
        with mock.patch.object(am, "_imap", return_value=Imap()), \
                mock.patch.object(am, "_smtp", return_value=Smtp()):
            r = am.probe("gmail", "tess.assistant@" + GM, PASSWORD)
        self.assertEqual((r["imap"], r["smtp"], r["inbox_count"]), ("ok", "ok", 3))
        self.assertGreater(r["oldest_days"], 14)
        self.assertEqual(sent, [])

    def test_probe_cannot_reach_provider_says_could_not_check(self):
        with mock.patch.object(am, "_imap", side_effect=socket.gaierror("no")), \
                mock.patch.object(am, "_smtp", side_effect=TimeoutError("timed out")):
            r = am.probe("icloud", ME, PASSWORD)
        self.assertEqual((r["imap"], r["smtp"]), ("network", "network"))


class Row(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())

    def _state(self, **kw):
        sd = self.d / "state"; sd.mkdir(exist_ok=True)
        now = datetime.now(timezone.utc)
        (sd / "email_assistant_status.json").write_text(json.dumps({
            "last_inbound_at": (now - timedelta(minutes=5)).isoformat(),
            "last_reply_at": (now - timedelta(hours=3)).isoformat(),
            "drops_24h": {"not_listed": 4, "automated": 1},
            "self_test_result": "ok",
            "self_test_at": (now - timedelta(days=2)).isoformat(), **kw}))
        return sd

    def test_not_configured_renders_nothing(self):
        p = self.d / "c.toml"; p.write_text("[autonomy]\nx = 1\n")
        self.assertEqual(am.read_row(p, self.d), {"configured": False})
        self.assertEqual(am.render_html({"configured": False}), "")

    def test_row_fields(self):
        row = am.read_row(_cfg(self.d), self._state())
        self.assertEqual(row["address"], ME)
        self.assertEqual(row["provider"], "iCloud")
        self.assertEqual(row["last_inbound"], "5 min ago")
        self.assertEqual(row["last_reply"], "3 h ago")
        self.assertEqual(row["selftest_result"], "ok")
        self.assertEqual(row["selftest_age"], "2 days ago")
        self.assertEqual(row["drops_24h"], {"automated": 1, "not_listed": 4})
        self.assertEqual(row["drops_24h_total"], 5)

    def test_html_shows_everything_and_no_password(self):
        with mock.patch.object(am, "keychain_read", return_value=PASSWORD):
            html = am.render_html(am.read_row(_cfg(self.d), self._state()))
        for want in (ME, "iCloud", "Test now", "Replace password",
                     "Turn off", "not_listed: 4", "Passed (2 days ago)", "5 min ago"):
            self.assertIn(want, html)
        self.assertNotIn(PASSWORD, html)
        self.assertNotIn("keychain:", html)
        self.assertNotIn(chr(0x2014), html)

    def test_html_escapes_daemon_supplied_text(self):
        sd = self._state()
        (sd / "email_assistant_status.json").write_text(json.dumps(
            {"drops_24h": {"<script>x</script>": 1}}))
        html = am.render_html(am.read_row(_cfg(self.d), sd))
        self.assertNotIn("<script>x", html)
        self.assertIn("&lt;script&gt;", html)

    def test_off_state_offers_turn_on(self):
        html = am.render_html(am.read_row(_cfg(self.d, enabled="false"), self.d))
        self.assertIn("Turn on", html)

    def test_set_enabled_edits_only_its_own_section(self):
        p = _cfg(self.d)
        self.assertTrue(am.set_enabled(False, p))
        t = p.read_text()
        self.assertIn("[channels.imessage]\nenabled = true", t)
        self.assertIn("[email_assistant]\nenabled = false", t)
        self.assertEqual(am.read_config(p)["enabled"], False)

    def test_replace_password_keeps_old_one_when_new_is_refused(self):
        p = _cfg(self.d)
        with mock.patch.object(am, "probe", return_value={"imap": "wrong_password", "smtp": "wrong_password"}), \
                mock.patch.object(am, "keychain_store") as store:
            r = am.replace_password("zzzzzzzzzzzzzzzz", p)
        self.assertEqual(r, {"ok": False, "error": "wrong_password"})
        store.assert_not_called()

    def test_replace_password_stores_after_live_check(self):
        p = _cfg(self.d)
        with mock.patch.object(am, "probe", return_value={"imap": "ok", "smtp": "ok"}), \
                mock.patch.object(am, "keychain_store", return_value=True) as store:
            r = am.replace_password("zzzz-zzzz-zzzz-zzzz", p)
        self.assertEqual(r, {"ok": True})
        store.assert_called_once()

    def test_keychain_store_keeps_the_password_off_argv(self):
        with mock.patch.object(am.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertTrue(am.keychain_store(ME, "abcd-efgh-ijkl-mnop"))
        args, kw = run.call_args
        self.assertEqual(args[0], ["security", "-i"])
        self.assertNotIn(PASSWORD, " ".join(args[0]))
        self.assertIn(PASSWORD, kw["input"])

    def test_cli_never_prints_the_password(self):
        import io, os, contextlib
        env = {"AM_PROVIDER": "icloud", "AM_ADDRESS": ME, "AM_PASSWORD": PASSWORD}
        buf = io.StringIO()
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(am, "probe", return_value={"imap": "ok", "smtp": "ok", "inbox_count": 0, "oldest_days": None}), \
                contextlib.redirect_stdout(buf):
            self.assertEqual(am._cli(["x", "probe"]), 0)
        self.assertNotIn(PASSWORD, buf.getvalue())
        self.assertIn("imap=ok", buf.getvalue())


class Routes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from fastapi.testclient import TestClient
            import web_ui
        except Exception as exc:  # pragma: no cover
            raise unittest.SkipTest(f"web_ui not importable here: {exc}")
        cls.web_ui = web_ui
        cls.client = TestClient(web_ui.app)

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.cfg = _cfg(self.d)
        import os
        self._env = mock.patch.dict(os.environ, {"OSTLER_ASSISTANT_CONFIG": str(self.cfg),
                                                 "OSTLER_STATE_DIR": str(self.d)})
        self._env.start()

    def tearDown(self):
        self._env.stop()

    LOCAL = {"host": "127.0.0.1:8089"}
    ACTIONS = ("on", "off", "test-now", "replace-password")

    def test_get_row_has_no_secret(self):
        # (a) The Keychain holds a password and the route still never returns
        # it: present-but-empty is the only allowed shape of a secret here.
        with mock.patch.object(am, "keychain_read", return_value=PASSWORD):
            r = self.client.get("/api/v1/assistant-mailbox", headers=self.LOCAL)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertNotIn(PASSWORD, r.text)
        for k, v in r.json().items():
            if "password" in k.lower() or "secret" in k.lower():
                self.assertFalse(v, f"{k} carries a value")
        r = self.client.get("/api/v1/assistant-mailbox", headers=self.LOCAL)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["address"], ME)
        self.assertNotIn("secret_ref", r.text)
        self.assertNotIn("password", r.text.lower())

    def test_off_and_on(self):
        h = {"host": "127.0.0.1:8089"}
        r = self.client.post("/api/v1/assistant-mailbox/off", headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertFalse(am.read_config(self.cfg)["enabled"])
        self.client.post("/api/v1/assistant-mailbox/on", headers=h)
        self.assertTrue(am.read_config(self.cfg)["enabled"])

    def test_cross_site_post_is_refused(self):
        r = self.client.post("/api/v1/assistant-mailbox/off",
                             headers={"host": "127.0.0.1:8089", "sec-fetch-site": "cross-site"})
        self.assertEqual(r.status_code, 403)
        self.assertTrue(am.read_config(self.cfg)["enabled"])

    def test_non_local_host_is_refused(self):
        r = self.client.post("/api/v1/assistant-mailbox/off", headers={"host": "evil.example.test"})
        self.assertEqual(r.status_code, 403)

    def test_every_route_refuses_a_non_loopback_host(self):
        # (b) No paired credential, so the Hub-local Host is the boundary.
        for host in ("192.168.1.5:8089", "ostler-hub.tailnet.example:8089", ""):
            h = {"host": host} if host else {"host": ""}
            r = self.client.get("/api/v1/assistant-mailbox", headers=h)
            self.assertEqual(r.status_code, 403, f"GET host={host!r}")
            self.assertNotIn(ME, r.text)
            for a in self.ACTIONS:
                r = self.client.post(f"/api/v1/assistant-mailbox/{a}", headers=h, json={"password": PASSWORD})
                self.assertEqual(r.status_code, 403, f"POST {a} host={host!r}")
        self.assertTrue(am.read_config(self.cfg)["enabled"])

    def test_every_route_refuses_a_cross_site_origin(self):
        # (c) A page on another site must not read the row or flip a switch.
        for extra in ({"origin": "https://evil.example.test"},
                      {"origin": "http://192.168.1.5:8089"},
                      {"sec-fetch-site": "cross-site"}):
            h = {**self.LOCAL, **extra}
            r = self.client.get("/api/v1/assistant-mailbox", headers=h)
            self.assertEqual(r.status_code, 403, f"GET {extra}")
            self.assertNotIn(ME, r.text)
            for a in self.ACTIONS:
                r = self.client.post(f"/api/v1/assistant-mailbox/{a}", headers=h, json={"password": PASSWORD})
                self.assertEqual(r.status_code, 403, f"POST {a} {extra}")
        self.assertTrue(am.read_config(self.cfg)["enabled"])
        # Control: the same-origin Doctor page is served.
        r = self.client.get("/api/v1/assistant-mailbox",
                            headers={**self.LOCAL, "origin": "http://127.0.0.1:8089", "sec-fetch-site": "same-origin"})
        self.assertEqual(r.status_code, 200, r.text)

    def test_the_doctor_listens_on_loopback_only(self):
        # (b) The process binds 127.0.0.1, so the routes are not on the LAN.
        import ast
        src = Path(self.web_ui.__file__).read_text()
        hosts = [kw.value.value for node in ast.walk(ast.parse(src)) if isinstance(node, ast.Call)
                 and getattr(node.func, "attr", "") == "run" and getattr(node.func.value, "id", "") == "uvicorn"
                 for kw in node.keywords if kw.arg == "host" and isinstance(kw.value, ast.Constant)]
        self.assertEqual(hosts, ["127.0.0.1"], hosts)

    def test_test_now_asks_the_daemon_and_writes_nothing_itself(self):
        # The route returns the daemon's answer; the Doctor writes no file of
        # its own (the daemon's status file is the single record).
        with mock.patch.object(am, "test_now", return_value={"result": "ok"}):
            r = self.client.post("/api/v1/assistant-mailbox/test-now", headers={"host": "127.0.0.1:8089"})
        self.assertEqual(r.json()["result"], "ok")
        self.assertEqual(r.json()["message"], "Passed")
        self.assertFalse((self.d / "email_assistant_selftest.json").exists())
        with mock.patch.object(am, "test_now", return_value={"result": "daemon_unreachable"}):
            r = self.client.post("/api/v1/assistant-mailbox/test-now", headers={"host": "127.0.0.1:8089"})
        self.assertIn("not running", r.json()["message"])

    def test_replace_password_never_echoes_it(self):
        with mock.patch.object(am, "replace_password", return_value={"ok": False, "error": "wrong_password"}):
            r = self.client.post("/api/v1/assistant-mailbox/replace-password",
                                 headers={"host": "127.0.0.1:8089"}, json={"password": PASSWORD})
        self.assertEqual(r.status_code, 400)
        self.assertNotIn(PASSWORD, r.text)

    def test_dashboard_embeds_the_row(self):
        with mock.patch.object(self.web_ui, "is_first_run", return_value=False):
            r = self.client.get("/doctor")
        if r.status_code != 200:
            self.skipTest(f"dashboard not renderable here ({r.status_code})")
        self.assertIn("Assistant's own email", r.text.replace("&#x27;", "'").replace("&#39;", "'"))


class SeamClosed(unittest.TestCase):
    """The e2e loopback seam must not exist on a customer machine."""

    def test_only_two_providers_and_no_loopback_host_unless_the_seam_is_on(self):
        import os
        if os.environ.get("OSTLER_E2E_LOOPBACK") == "1":
            self.skipTest("this run is the e2e run")
        self.assertEqual(sorted(am.PROVIDERS), ["gmail", "icloud"])
        self.assertFalse(am.E2E_LOOPBACK)
        self.assertFalse(am.host_pair_allowed("127.0.0.1", 993, "127.0.0.1", 587))
        self.assertEqual(am._e2e_keychain_args(), [])

    def test_install_sh_loopback_needs_the_seam_variable(self):
        import subprocess
        repo = Path(__file__).resolve().parents[3]
        src = (repo / "install.sh").read_text()
        import re
        block = re.search(r"^# BEGIN assistant-mailbox-helpers.*?^# END assistant-mailbox-helpers",
                          src, re.M | re.S).group(0)
        script = block + '\n_am_hosts_for_provider loopback && echo OPEN || echo CLOSED\n' \
            '_am_address_ok loopback x@example.test && echo OPEN || echo CLOSED\n'
        env = {"PATH": "/usr/bin:/bin"}
        out = subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True, text=True).stdout.split()
        self.assertEqual(out, ["CLOSED", "CLOSED"])
        env["OSTLER_E2E_LOOPBACK"] = "1"
        out = subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True, text=True).stdout.split()
        self.assertEqual(out, ["OPEN", "OPEN"])


class FakeResp:
    def __init__(self, body): self._b = json.dumps(body).encode()
    def read(self): return self._b
    def __enter__(self): return self
    def __exit__(self, *a): return False


class DaemonSelfTest(unittest.TestCase):
    """test_now() is a client of the daemon's endpoint and nothing else."""

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        (self.d / "secrets").mkdir()
        (self.d / "secrets" / "zeroclaw_admin_token").write_text("tok-synthetic\n")
        self.env = mock.patch.dict("os.environ", {"OSTLER_DIR": str(self.d),
                                                  "OSTLER_CHAT_GATEWAY_PORT": "42617"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_posts_to_the_daemon_with_the_bearer_and_returns_its_result(self):
        seen = {}

        def fake(req, timeout=None):
            seen["url"], seen["auth"], seen["method"] = req.full_url, req.get_header("Authorization"), req.get_method()
            return FakeResp({"result": "timeout", "at": "2026-10-15T09:30:00+00:00"})
        with mock.patch.object(am.urllib.request, "urlopen", fake):
            r = am.test_now()
        self.assertEqual(r, {"result": "timeout"})
        self.assertEqual(seen["url"], "http://127.0.0.1:42617/api/assistant-mailbox/self-test")
        self.assertEqual(seen["auth"], "Bearer tok-synthetic")
        self.assertEqual(seen["method"], "POST")

    def test_no_daemon_is_unreachable_never_a_pass(self):
        with mock.patch.object(am.urllib.request, "urlopen", side_effect=ConnectionRefusedError("refused")):
            self.assertEqual(am.test_now(), {"result": "daemon_unreachable"})
        (self.d / "secrets" / "zeroclaw_admin_token").unlink()
        self.assertEqual(am.test_now(), {"result": "daemon_unreachable"})

    def test_disabled_and_unauthorised_are_named(self):
        import io
        import urllib.error
        def err(code, body):
            return urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(json.dumps(body).encode()))
        with mock.patch.object(am.urllib.request, "urlopen", side_effect=err(404, {"result": "disabled"})):
            self.assertEqual(am.test_now(), {"result": "disabled"})
        with mock.patch.object(am.urllib.request, "urlopen", side_effect=err(401, {"error": "no"})):
            self.assertEqual(am.test_now(), {"result": "daemon_unreachable"})

    def test_every_result_has_words(self):
        for k in ("ok", "timeout", "daemon_unreachable", "disabled", *am.ERRORS):
            self.assertTrue(am.selftest_words(k))


class HelloMessageId(unittest.TestCase):
    def test_hello_returns_the_message_id_it_sent(self):
        sent = {}

        class Smtp:
            def login(self, *a): pass
            def send_message(self, m): sent["m"] = m
            def quit(self): pass
        with mock.patch.object(am, "_smtp", return_value=Smtp()):
            r = am.hello_owner("icloud", ME, PASSWORD, "owner@example.test", "Tess")
        self.assertEqual(r["result"], "ok")
        self.assertEqual(r["message_id"], sent["m"]["Message-ID"])
        self.assertRegex(r["message_id"], r"^<[^<>\s]+@icloud\.com>$")
        self.assertEqual(sent["m"]["Subject"], "Hello from Tess")

    def test_cli_prints_the_message_id(self):
        import io
        from contextlib import redirect_stdout
        env = {"AM_PROVIDER": "icloud", "AM_ADDRESS": ME,
               "AM_PASSWORD": PASSWORD, "AM_OWNER": "owner@example.test", "AM_NAME": "Tess"}
        buf = io.StringIO()
        with mock.patch.dict("os.environ", env), \
                mock.patch.object(am, "hello_owner", return_value={"result": "ok", "message_id": "<m1@icloud.example>"}), \
                redirect_stdout(buf):
            am._cli(["x", "hello"])
        self.assertIn("result=ok", buf.getvalue())
        self.assertIn("message_id=<m1@icloud.example>", buf.getvalue())
        self.assertNotIn(PASSWORD, buf.getvalue())


# ── The golden contract fixture (same bytes in ostler-assistant) ─────────

FIXTURE = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "assistant_mailbox_contract.json"
# Pinned digest. ostler-assistant pins the SAME value in its own test. Change
# the fixture in BOTH repos together, then update this constant and that one.
FIXTURE_SHA256 = "b9a10daea75b476cdcee2fc7f81df44b5d72dc1042d739fabc8e11d93086c89f"


class Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import hashlib
        if not FIXTURE.is_file():
            raise unittest.SkipTest(f"CANNOT-RUN: {FIXTURE} not present (vendored tree outside the repo)")
        raw = FIXTURE.read_bytes()
        cls.sha = hashlib.sha256(raw).hexdigest()
        cls.fx = json.loads(raw)

    def test_fixture_is_the_pinned_copy(self):
        self.assertEqual(self.sha, FIXTURE_SHA256,
                         "contract fixture drifted from the pinned copy; sync it with ostler-assistant")

    def test_reader_conforms_to_the_config_block(self):
        d = Path(tempfile.mkdtemp())
        p = d / "config.toml"
        p.write_text(self.fx["config_block"])
        cfg = am.read_config(p)
        i = self.fx["installer_inputs"]
        self.assertEqual(cfg["address"], i["address"])
        self.assertEqual(cfg["provider"], i["provider"])
        self.assertEqual(cfg["hello_message_id"], i["hello_message_id"])
        self.assertEqual(cfg["owner_addresses_verified"], [])
        self.assertTrue(am.host_pair_allowed(cfg["imap_host"], cfg["imap_port"],
                                             cfg["smtp_host"], cfg["smtp_port"]))
        self.assertEqual(cfg["secret_ref"], am.secret_ref(i["address"]))

    def test_reader_conforms_to_the_status_file(self):
        d = Path(tempfile.mkdtemp())
        (d / "state").mkdir()
        (d / "state" / "email_assistant_status.json").write_text(json.dumps(self.fx["status_file"]))
        p = d / "config.toml"
        p.write_text(self.fx["config_block"])
        row = am.read_row(p, d / "state")
        sf = self.fx["status_file"]
        self.assertEqual(row["drops_24h"], sf["drops_24h"])
        self.assertEqual(row["drops_24h_total"], sum(sf["drops_24h"].values()))
        self.assertEqual(row["selftest_result"], sf["self_test_result"])
        self.assertIsNotNone(row["selftest_age"])
        self.assertIsNotNone(row["last_inbound"])
        self.assertIsNotNone(row["last_reply"])
        # Verified by the daemon's status even before the config is re-read.
        self.assertTrue(row["owner_verified"])
        html = am.render_html(row)
        for reason in sf["drops_24h"]:
            self.assertIn(f"{reason}: ", html)

    def test_reason_and_result_vocabularies_match(self):
        self.assertEqual(list(am.DROP_REASONS), self.fx["drop_reasons"])
        # Every self-test result the daemon can emit renders in words here.
        for k in self.fx["self_test_results"]:
            self.assertTrue(am.selftest_words(k))
            self.assertTrue(k in ("ok", "timeout") or k in am.ERRORS, k)

    def test_nothing_reads_the_retired_doctor_selftest_file(self):
        src = Path(am.__file__).read_text()
        self.assertNotIn("email_assistant_selftest", src)


if __name__ == "__main__":
    unittest.main()
