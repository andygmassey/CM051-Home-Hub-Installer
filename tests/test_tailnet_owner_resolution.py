#!/usr/bin/env python3
"""Tailscale owner-resolution parser test.

WHAT IT GUARDS

install.sh resolves the human who owns this node by parsing
`tailscale status --json`: Self.UserID indexes the User map, and that user's
LoginName becomes the identity the wiki tailnet gate will admit. Everything
downstream depends on it -- with no owner, install.sh writes the fail-closed
placeholder and the wiki is simply not served on the tailnet.

WHY A TEST, GIVEN THE GATE IS ALREADY TESTED

tests/test_wiki_tailnet_gate.sh proves the nginx gate rejects the wrong user.
It stays green when the owner was never resolved in the first place, because a
gate with no owner rejects everyone -- which is correct, and indistinguishable
from working. So the gate cannot catch a parser regression.

The failure direction is SAFE (fail closed, nothing exposed) but it is silent,
and it is a feature quietly disappearing: if Tailscale changes this JSON shape,
the wiki stops being reachable over the tailnet and nothing says why. Raised in
review, 2026-08-07.

WHY IT EXTRACTS THE PARSER RATHER THAN COPYING IT

A copied parser tests the copy. This pulls the actual Python out of install.sh
and runs that, so the test cannot drift away from what ships. If the extraction
stops matching, that is a hard failure, not a skip -- see test_extraction.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "install.sh"

# The parser is the python3 -c '...' block assigned to OSTLER_TAILNET_OWNER.
START = re.compile(r'OSTLER_TAILNET_OWNER="\$\(.*python3 -c \x27\s*$')
END = re.compile(r"^\x27\s*2>/dev/null")


def extract_parser() -> str:
    lines = INSTALL_SH.read_text().splitlines()
    start = None
    for i, line in enumerate(lines):
        if START.search(line):
            start = i + 1
            break
    if start is None:
        raise AssertionError(
            "could not find the OSTLER_TAILNET_OWNER python3 block in install.sh.\n"
            "The parser moved or was rewritten. Fix this extraction -- do NOT\n"
            "replace it with a copy of the parser, or this test starts proving\n"
            "things about a file nobody ships."
        )
    for j in range(start, len(lines)):
        if END.match(lines[j]):
            return "\n".join(lines[start:j])
    raise AssertionError("found the parser's start in install.sh but not its end")


PARSER = extract_parser()


def resolve(payload) -> str:
    """Run the SHIPPED parser over a status payload; return its stdout."""
    text = payload if isinstance(payload, str) else json.dumps(payload)
    p = subprocess.run(
        [sys.executable, "-c", PARSER],
        input=text, capture_output=True, text=True,
    )
    return p.stdout.strip()


def status(uid=1, users=None, **self_extra):
    """A `tailscale status --json` payload of the real shape."""
    self_block = {"UserID": uid, "HostName": "hub", "Online": True}
    self_block.update(self_extra)
    return {
        "Version": "1.covered.0",
        "BackendState": "Running",
        "Self": self_block,
        "User": users if users is not None else {
            "1": {"ID": 1, "LoginName": "owner@example.com",
                  "DisplayName": "Owner", "ProfilePicURL": ""},
        },
    }


class TestExtraction(unittest.TestCase):
    """The test's own foundations. If these fail, nothing below means anything."""

    def test_parser_was_extracted(self):
        self.assertIn("LoginName", PARSER)
        self.assertIn("tagged-devices", PARSER)
        self.assertIn("UserID", PARSER)

    def test_parser_is_the_shipped_one(self):
        # Guards against someone "fixing" a failure by editing the test.
        self.assertIn(PARSER.strip().splitlines()[0], INSTALL_SH.read_text())


class TestHappyPath(unittest.TestCase):

    def test_resolves_the_owner_login(self):
        self.assertEqual(resolve(status()), "owner@example.com")

    def test_picks_the_user_matching_self_userid(self):
        """The map holds every user the node has seen, not just the owner."""
        out = resolve(status(uid=2, users={
            "1": {"ID": 1, "LoginName": "someone-else@example.com"},
            "2": {"ID": 2, "LoginName": "the-owner@example.com"},
            "3": {"ID": 3, "LoginName": "third@example.com"},
        }))
        self.assertEqual(out, "the-owner@example.com")

    def test_userid_is_looked_up_as_a_string_key(self):
        """Self.UserID is a number; the User map is keyed by string."""
        self.assertEqual(resolve(status(uid=7, users={
            "7": {"ID": 7, "LoginName": "seven@example.com"},
        })), "seven@example.com")

    def test_github_style_login_is_accepted(self):
        self.assertEqual(resolve(status(users={
            "1": {"ID": 1, "LoginName": "someuser@github"},
        })), "someuser@github")

    def test_surrounding_whitespace_is_stripped(self):
        self.assertEqual(resolve(status(users={
            "1": {"ID": 1, "LoginName": "  owner@example.com  "},
        })), "owner@example.com")


class TestMustNotResolve(unittest.TestCase):
    """Every one of these must yield NOTHING, so install.sh fails closed."""

    def assertNoOwner(self, payload, why):
        self.assertEqual(resolve(payload), "", why)

    def test_tagged_node_has_no_human_owner(self):
        self.assertNoOwner(status(users={
            "1": {"ID": 1, "LoginName": "tagged-devices"},
        }), "a tagged node must never open the gate")

    def test_tagged_devices_with_suffix(self):
        self.assertNoOwner(status(users={
            "1": {"ID": 1, "LoginName": "tagged-devices.example.ts.net"},
        }), "tagged-devices prefix must be rejected however it is suffixed")

    def test_no_self_block(self):
        self.assertNoOwner({"BackendState": "NeedsLogin", "User": {}},
                           "logged out: no Self block")

    def test_self_without_userid(self):
        self.assertNoOwner({"Self": {"HostName": "hub"}, "User": {}},
                           "Self present but no UserID")

    def test_userid_not_in_user_map(self):
        self.assertNoOwner(status(uid=99), "UserID with no matching entry")

    def test_empty_login_name(self):
        self.assertNoOwner(status(users={"1": {"ID": 1, "LoginName": ""}}), "empty login")

    def test_whitespace_only_login_name(self):
        self.assertNoOwner(status(users={"1": {"ID": 1, "LoginName": "   "}}),
                           "whitespace-only login must not become an nginx value")

    def test_missing_login_name_key(self):
        self.assertNoOwner(status(users={"1": {"ID": 1}}), "no LoginName key")

    def test_null_login_name(self):
        self.assertNoOwner(status(users={"1": {"ID": 1, "LoginName": None}}), "null login")

    def test_null_user_map(self):
        d = status(); d["User"] = None
        self.assertNoOwner(d, "User is null")

    def test_empty_input(self):
        self.assertNoOwner("", "tailscale not running -> empty stdin")

    def test_malformed_json(self):
        self.assertNoOwner("{not json at all", "must not traceback or emit")

    def test_truncated_json(self):
        self.assertNoOwner('{"Self": {"UserID": 1}, "User": {"1": {"Log',
                           "a half-written response must not resolve")

    def test_json_is_a_list(self):
        self.assertNoOwner("[1, 2, 3]", "unexpected top-level type")


class TestNeverCrashes(unittest.TestCase):
    """The parser must not crash on ANY input it can actually be handed.

    Be precise about the stakes, because it is tempting to overstate them: the
    call site is `python3 -c '...' 2>/dev/null || true`, so today a crash is
    invisible. stderr is discarded and stdout is empty, so install.sh fails
    closed and the customer sees nothing wrong. There is no live symptom.

    It is still worth holding, for two reasons:

      * a parser should not depend on its call site to hide a crash. The day
        someone drops the 2>/dev/null to debug something -- an entirely
        reasonable thing to do -- tracebacks start appearing in install logs.
      * "crashes on valid JSON" and "returns nothing on valid JSON" are
        different contracts, and only the second one is safe to rely on.

    Found by this test on first run: bare `null` and `[]` are valid JSON that
    json.load accepts, after which d.get() raised AttributeError. Fixed with an
    isinstance check in both inline parsers.
    """

    def test_no_stderr_on_any_input(self):
        for label, payload in [
            ("empty", ""),
            ("malformed", "{oh no"),
            ("list", "[]"),
            ("null", "null"),
            ("valid", json.dumps(status())),
            ("no User map", json.dumps({"Self": {"UserID": 1}})),
        ]:
            with self.subTest(label):
                p = subprocess.run(
                    [sys.executable, "-c", PARSER],
                    input=payload, capture_output=True, text=True,
                )
                self.assertEqual(p.returncode, 0, f"{label}: non-zero exit")
                self.assertEqual(p.stderr.strip(), "", f"{label}: wrote to stderr")


class TestPositiveControl(unittest.TestCase):
    """A test suite that cannot fail proves nothing. Show the harness bites."""

    def test_harness_detects_a_broken_parser(self):
        broken = "import sys\nsys.stdin.read()\nprint('attacker@evil.example')"
        p = subprocess.run([sys.executable, "-c", broken],
                           input=json.dumps(status()), capture_output=True, text=True)
        self.assertEqual(p.stdout.strip(), "attacker@evil.example")
        self.assertNotEqual(
            p.stdout.strip(), resolve(status()),
            "the harness cannot tell a wrong parser from the real one",
        )

    def test_a_rejected_case_would_be_noticed(self):
        always = "import sys\nsys.stdin.read()\nprint('tagged-devices')"
        p = subprocess.run([sys.executable, "-c", always],
                           input=json.dumps(status()), capture_output=True, text=True)
        self.assertEqual(p.stdout.strip(), "tagged-devices",
                         "a parser that leaked a tagged node would produce output "
                         "here, so the assertNoOwner checks are meaningful")


if __name__ == "__main__":
    unittest.main(verbosity=2)
