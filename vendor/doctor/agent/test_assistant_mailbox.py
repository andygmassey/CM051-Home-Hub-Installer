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


def _cfg(tmp: Path, extra: str = "", enabled: str = "true") -> Path:
    p = tmp / "config.toml"
    p.write_text(
        '[channels.imessage]\nenabled = true\n\n[email_assistant]\n'
        f'enabled = {enabled}\naddress = "tess.assistant@icloud.com"\nprovider = "icloud"\n'
        'imap_host = "imap.mail.me.com"\nimap_port = 993\nsmtp_host = "smtp.mail.me.com"\n'
        'smtp_port = 587\nsecret_ref = "keychain:Ostler Assistant Mailbox:tess.assistant@icloud.com"\n'
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
        self.assertTrue(am.is_owner_address("Owner@Example.test", ["owner@example.test"]))
        self.assertFalse(am.is_owner_address("new@icloud.com", ["owner@example.test"]))
        self.assertTrue(am.gmail_identity_ok("A@gmail.com", "a@gmail.com"))
        self.assertFalse(am.gmail_identity_ok("a@gmail.com", "b@gmail.com"))

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
            r = am.probe("icloud", "tess.assistant@icloud.com", PASSWORD)
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
            r = am.probe("gmail", "tess.assistant@gmail.com", PASSWORD)
        self.assertEqual((r["imap"], r["smtp"], r["inbox_count"]), ("ok", "ok", 3))
        self.assertGreater(r["oldest_days"], 14)
        self.assertEqual(sent, [])

    def test_probe_cannot_reach_provider_says_could_not_check(self):
        with mock.patch.object(am, "_imap", side_effect=socket.gaierror("no")), \
                mock.patch.object(am, "_smtp", side_effect=TimeoutError("timed out")):
            r = am.probe("icloud", "tess.assistant@icloud.com", PASSWORD)
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
            "drops_24h": {"not_owner": 4, "loop_guard": 1}, **kw}))
        (sd / "email_assistant_selftest.json").write_text(json.dumps(
            {"result": "ok", "at": (now - timedelta(days=2)).isoformat()}))
        return sd

    def test_not_configured_renders_nothing(self):
        p = self.d / "c.toml"; p.write_text("[autonomy]\nx = 1\n")
        self.assertEqual(am.read_row(p, self.d), {"configured": False})
        self.assertEqual(am.render_html({"configured": False}), "")

    def test_row_fields(self):
        row = am.read_row(_cfg(self.d), self._state())
        self.assertEqual(row["address"], "tess.assistant@icloud.com")
        self.assertEqual(row["provider"], "iCloud")
        self.assertEqual(row["last_inbound"], "5 min ago")
        self.assertEqual(row["last_reply"], "3 h ago")
        self.assertEqual(row["selftest_result"], "ok")
        self.assertEqual(row["selftest_age"], "2 days ago")
        self.assertEqual(row["drops_24h"], {"loop_guard": 1, "not_owner": 4})
        self.assertEqual(row["drops_24h_total"], 5)

    def test_html_shows_everything_and_no_password(self):
        with mock.patch.object(am, "keychain_read", return_value=PASSWORD):
            html = am.render_html(am.read_row(_cfg(self.d), self._state()))
        for want in ("tess.assistant@icloud.com", "iCloud", "Test now", "Replace password",
                     "Turn off", "not_owner: 4", "Passed (2 days ago)", "5 min ago"):
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
            self.assertTrue(am.keychain_store("tess.assistant@icloud.com", "abcd-efgh-ijkl-mnop"))
        args, kw = run.call_args
        self.assertEqual(args[0], ["security", "-i"])
        self.assertNotIn(PASSWORD, " ".join(args[0]))
        self.assertIn(PASSWORD, kw["input"])

    def test_cli_never_prints_the_password(self):
        import io, os, contextlib
        env = {"AM_PROVIDER": "icloud", "AM_ADDRESS": "tess.assistant@icloud.com", "AM_PASSWORD": PASSWORD}
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

    def test_get_row_has_no_secret(self):
        r = self.client.get("/api/v1/assistant-mailbox")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["address"], "tess.assistant@icloud.com")
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

    def test_test_now_records_result(self):
        with mock.patch.object(am, "keychain_read", return_value=PASSWORD), \
                mock.patch.object(am, "selftest", return_value={"result": "ok", "token": "t", "seconds": 4}):
            r = self.client.post("/api/v1/assistant-mailbox/test-now", headers={"host": "127.0.0.1:8089"})
        self.assertEqual(r.json()["result"], "ok")
        self.assertEqual(json.loads((self.d / "email_assistant_selftest.json").read_text())["result"], "ok")

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


if __name__ == "__main__":
    unittest.main()
