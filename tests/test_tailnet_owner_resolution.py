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


# ---------------------------------------------------------------------------
# TYPE CONFUSION BELOW THE TOP LEVEL
#
# TestNoStderr above records an earlier fix: bare `null` and `[]` reached
# d.get() and raised, closed with `if not isinstance(d, dict)`. That guard is
# correct and it is only one level deep. Every lookup UNDER it was still
# unguarded:
#
#     uid  = (d.get("Self") or {}).get("UserID")        <- Self must be a dict
#     user = (d.get("User") or {}).get(str(uid)) or {}  <- User must be a dict
#     login = (user.get("LoginName") or "").strip()     <- and so must the entry
#
# `x or {}` only substitutes when x is FALSY. A truthy non-dict -- a string, a
# number, a non-empty list -- passes straight through to .get() and raises
# AttributeError. Measured 2026-08-13 against the then-shipped parser: 11 of 12
# such shapes raised.
#
# test_no_stderr_on_any_input did not catch it because all six of its payloads
# are well-formed BELOW the top level: it varies the root and holds the nested
# shape fixed, which is the axis the defect does not live on.
#
# Severity, stated plainly: each call site redirects `2>/dev/null` and appends
# `|| true`, so stdout stayed empty and the traceback was discarded. Nothing
# reached a customer. This is hardening of a parser whose output is an
# authorisation input, and removal of the dependency on a call-site redirect --
# not the repair of a live fault.
# ---------------------------------------------------------------------------

# The second inline parser, which resolves the MagicDNS name. It had no tests
# at all, and carried the identical `(d.get("Self") or {})` shape.
DNS_START = re.compile(r'OSTLER_WIKI_TAILNET_URL="https://\$\(.*python3 -c \x27\s*$')


def extract_dns_parser() -> str:
    lines = INSTALL_SH.read_text().splitlines()
    start = None
    for i, line in enumerate(lines):
        if DNS_START.search(line):
            start = i + 1
            break
    if start is None:
        raise AssertionError(
            "could not find the OSTLER_WIKI_TAILNET_URL python3 block in "
            "install.sh. Fix this extraction -- do NOT paste in a copy of the "
            "parser, or this test starts proving things about a file nobody ships."
        )
    for j in range(start, len(lines)):
        if END.match(lines[j]):
            return "\n".join(lines[start:j])
    raise AssertionError("found the DNSName parser start in install.sh but not its end")


DNS_PARSER = extract_dns_parser()


def run_parser(body: str, payload: str):
    """Return (stdout, stderr, returncode) for a parser body over raw stdin."""
    p = subprocess.run([sys.executable, "-c", body],
                       input=payload, capture_output=True, text=True)
    return p.stdout.strip(), p.stderr.strip(), p.returncode


# Each entry is a shape that is valid JSON and structurally wrong. Every one
# must produce EMPTY output and EMPTY stderr, because for the owner parser
# empty is the fail-closed answer.
OWNER_TYPE_CONFUSION = [
    ("Self is a non-empty list", '{"Self": ["a"], "User": {}}'),
    ("Self is a string",         '{"Self": "x", "User": {}}'),
    ("Self is a number",         '{"Self": 5, "User": {}}'),
    ("User is a string",         '{"Self": {"UserID": 1}, "User": "x"}'),
    ("User is a non-empty list", '{"Self": {"UserID": 1}, "User": ["a"]}'),
    ("User is a number",         '{"Self": {"UserID": 1}, "User": 7}'),
    ("user entry is a string",   '{"Self": {"UserID": 1}, "User": {"1": "x"}}'),
    ("user entry is a list",     '{"Self": {"UserID": 1}, "User": {"1": ["a"]}}'),
    ("LoginName is a number",    '{"Self": {"UserID": 1}, "User": {"1": {"LoginName": 5}}}'),
    ("LoginName is a list",      '{"Self": {"UserID": 1}, "User": {"1": {"LoginName": ["a"]}}}'),
    ("LoginName is a dict",      '{"Self": {"UserID": 1}, "User": {"1": {"LoginName": {"a": 1}}}}'),
]


class TestOwnerParserTypeConfusion(unittest.TestCase):

    def test_every_shape_is_empty_and_silent(self):
        for label, payload in OWNER_TYPE_CONFUSION:
            with self.subTest(label):
                out, err, rc = run_parser(PARSER, payload)
                self.assertEqual(out, "", f"{label}: returned an owner, must fail closed")
                self.assertNotIn("Traceback", err, f"{label}: raised\n{err}")
                self.assertEqual(err, "", f"{label}: wrote to stderr\n{err}")
                self.assertEqual(rc, 0, f"{label}: non-zero exit")

    def test_the_valid_case_still_resolves(self):
        """Hardening that also broke the happy path would pass every check above."""
        self.assertEqual(resolve(status()), "owner@example.com")

    def test_a_tagged_node_is_still_refused(self):
        self.assertEqual(
            resolve(status(users={"1": {"ID": 1, "LoginName": "tagged-devices"}})), "",
            "the tagged-devices rule must survive the type guards",
        )


class TestDNSNameParserTypeConfusion(unittest.TestCase):
    """The DNSName parser had zero coverage. Its output builds the wiki URL."""

    def test_extraction_found_real_code(self):
        self.assertIn("DNSName", DNS_PARSER)
        self.assertIn(DNS_PARSER.strip().splitlines()[0], INSTALL_SH.read_text())

    def test_resolves_a_valid_dns_name(self):
        out, err, _ = run_parser(DNS_PARSER, '{"Self": {"DNSName": "hub.tail.ts.net."}}')
        self.assertEqual(out, "hub.tail.ts.net", "trailing dot must be stripped")
        self.assertEqual(err, "")

    def test_type_confusion_is_empty_and_silent(self):
        for label, payload in [
            ("Self is a string",   '{"Self": "x"}'),
            ("Self is a list",     '{"Self": ["a"]}'),
            ("DNSName is a number", '{"Self": {"DNSName": 5}}'),
            ("DNSName is a list",  '{"Self": {"DNSName": ["a"]}}'),
            ("DNSName is null",    '{"Self": {"DNSName": null}}'),
            ("no Self",            '{}'),
            ("bare null",          'null'),
            ("bare list",          '[]'),
            ("malformed",          '{oh no'),
        ]:
            with self.subTest(label):
                out, err, rc = run_parser(DNS_PARSER, payload)
                self.assertEqual(out, "", f"{label}: produced a hostname")
                self.assertNotIn("Traceback", err, f"{label}: raised\n{err}")
                self.assertEqual(rc, 0, f"{label}: non-zero exit")


class TestTypeGuardsAreWhatIsBeingTested(unittest.TestCase):
    """NEGATIVE CONTROL.

    The assertions above would pass just as happily against a parser that
    printed nothing ever. Neuter one type guard and the suite must go red --
    otherwise it is not testing the guards, it is testing that Python is quiet.
    """

    def test_removing_a_guard_reintroduces_the_crash(self):
        neutered = PARSER.replace(
            'if not isinstance(users, dict):', 'if False:')
        self.assertNotEqual(neutered, PARSER,
                            "could not neuter the User guard; this control is inert")
        _, err, _ = run_parser(neutered, '{"Self": {"UserID": 1}, "User": "x"}')
        self.assertIn(
            "Traceback", err,
            "removing the isinstance guard did NOT reintroduce the crash, so "
            "TestOwnerParserTypeConfusion is not testing that guard at all",
        )

    def test_removing_the_dns_guard_reintroduces_the_crash(self):
        neutered = DNS_PARSER.replace(
            'if not isinstance(name, str):', 'if False:')
        self.assertNotEqual(neutered, DNS_PARSER,
                            "could not neuter the DNSName guard; control is inert")
        _, err, _ = run_parser(neutered, '{"Self": {"DNSName": 5}}')
        self.assertIn("Traceback", err,
                      "the DNSName type assertions are not testing the guard")


if __name__ == "__main__":
    unittest.main(verbosity=2)
