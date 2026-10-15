#!/usr/bin/env python3
"""The loopback mail provider used by tests/e2e/assistant_mailbox_e2e.sh must
behave like a provider where the end-to-end run depends on it: login checks, the
self-test's search/delete/expunge, and Authentication-Results stamped on
delivery that a sender cannot forge. Synthetic only; loopback only; stdlib.
"""
import imaplib
import smtplib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "e2e"))
import mailsim  # noqa: E402

ME, PW = "tess.assistant@example.test", "abcdefghijklmnop"


def raw(frm, extra=""):
    return (f"From: <{frm}>\r\nTo: <{ME}>\r\nSubject: s\r\nMessage-ID: <m@example.test>\r\n{extra}\r\nbody\r\n").encode()


class Sim(unittest.TestCase):
    def setUp(self):
        self.s = mailsim.Sim(ME, PW)
        self.s.start()
        self.addCleanup(self.s.stop)

    def mx(self, frm, extra=""):
        with smtplib.SMTP("127.0.0.1", self.s.ports["mx"], timeout=10) as c:
            c.sendmail(frm, [ME], raw(frm, extra))

    def top_ar(self):
        body = self.s.box.msgs[-1]["raw"].decode()
        return body.splitlines()[0]

    def test_signed_owner_passes_unsigned_or_forged_fails(self):
        self.mx("owner@example.test", "X-Sim-Signed-By: example.test\r\n")
        self.assertIn("dmarc=pass header.from=example.test", self.top_ar())
        self.assertNotIn("X-Sim-Signed-By", self.s.box.msgs[-1]["raw"].decode())
        self.mx("owner@example.test")
        self.assertIn("dmarc=fail", self.top_ar())
        # A signature for some other domain does not align with the From.
        self.mx("owner@example.test", "X-Sim-Signed-By: attacker.test\r\n")
        self.assertIn("dmarc=fail", self.top_ar())

    def test_a_sender_supplied_authentication_results_is_replaced_not_trusted(self):
        self.mx("owner@example.test", "Authentication-Results: x; dmarc=pass header.from=example.test\r\n")
        text = self.s.box.msgs[-1]["raw"].decode()
        self.assertIn("dmarc=fail", text.splitlines()[0])
        self.assertEqual(text.lower().count("authentication-results:"), 1)

    def test_submission_needs_auth_and_delivers_to_the_inbox(self):
        with smtplib.SMTP("127.0.0.1", self.s.ports["submission"], timeout=10) as c:
            with self.assertRaises(smtplib.SMTPException):
                c.sendmail(ME, [ME], raw(ME))
        with smtplib.SMTP("127.0.0.1", self.s.ports["submission"], timeout=10) as c:
            with self.assertRaises(smtplib.SMTPAuthenticationError):
                c.login(ME, "wrongwrongwrong1")
        with smtplib.SMTP("127.0.0.1", self.s.ports["submission"], timeout=10) as c:
            c.login(ME, PW)
            c.sendmail(ME, [ME], raw(ME))
        self.assertEqual(len(self.s.box.msgs), 1)

    def test_imap_login_search_delete_expunge(self):
        self.mx("owner@example.test", "X-Sim-Signed-By: example.test\r\n")
        bad = imaplib.IMAP4("127.0.0.1", self.s.ports["imap"])
        with self.assertRaises(imaplib.IMAP4.error):
            bad.login(ME, "wrongwrongwrong1")
        m = imaplib.IMAP4("127.0.0.1", self.s.ports["imap"])
        m.login(ME, PW)
        self.assertEqual(m.select("INBOX")[1], [b"1"])
        self.assertEqual(m.uid("SEARCH", "SUBJECT", '"s"')[1], [b"1"])
        self.assertEqual(m.uid("SEARCH", "SUBJECT", '"nope"')[1], [b""])
        m.uid("STORE", "1", "+FLAGS", "(\\Deleted)")
        m.expunge()
        self.assertEqual(m.search(None, "ALL")[1], [b""])


if __name__ == "__main__":
    unittest.main()
