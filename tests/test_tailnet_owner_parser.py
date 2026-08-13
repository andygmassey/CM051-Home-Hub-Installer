#!/usr/bin/env python3
"""Unit-test the Tailscale owner-resolution parser (#512 follow-up / D660).

WHAT THIS PARSER DECIDES, WHICH IS WHY IT NEEDS TESTS

install.sh resolves the human who owns this Tailscale node, then feeds that
login to `write_wiki_tailnet_gate`. The gate demands
`Tailscale-User-Login == owner` before proxying the wiki. So the parser's
output is an authorisation input:

    non-empty  -> a gate is written that admits THAT login
    empty      -> fail-closed: no listener, the wiki stays on-device

Both directions are load-bearing and they fail in opposite ways. Returning
the WRONG login, or a login for a tagged (human-less) node, opens a personal
wiki to whoever holds that identity. Returning empty when a real owner exists
merely costs the off-box feature. So the tests below are asymmetric on
purpose: every ambiguous or malformed input must produce EMPTY.

WHY IT IS EXTRACTED FROM install.sh RATHER THAN COPIED

The parser is an inline `python3 -c '...'` heredoc inside install.sh. A copy
pasted into this file would drift the moment someone edits the installer, and
the test would then be green about code that no longer ships. This extracts
the real block from install.sh at run time, so the thing under test is the
thing that ships. `test_the_extraction_found_real_code` guards the extraction
itself, because an extractor that silently returned "" would make every case
below pass by running nothing.

WHY STDLIB unittest AND NOT pytest

The `contract` workflow runs on a bare hosted runner with no pip install step,
so `python3 -m pytest` there fails with "No module named pytest" BEFORE a
single assertion executes. That is the worst failure mode for a security test:
the gate is wired, the step is red for an infrastructure reason, and the
temptation is to read the red as noise. Every other suite in this repo is
invoked as `python3 -m unittest tests.<module> -v`; this one matches, so the
gate depends on nothing that has to be fetched over the network.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = REPO_ROOT / "install.sh"

# The block opens with `... status --json ... | python3 -c '` and closes on the
# line beginning with `' 2>/dev/null`. Anchored on both ends so a second
# python3 -c elsewhere in install.sh cannot be picked up by accident.
_OPEN = re.compile(r"status --json[^|]*\|\s*python3 -c '\s*$")
_CLOSE = re.compile(r"^\s*'\s*2>/dev/null")


def _extract_parser() -> str:
    lines = INSTALL_SH.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if _OPEN.search(line):
            body = []
            for j in range(i + 1, len(lines)):
                if _CLOSE.match(lines[j]):
                    return "\n".join(body)
                body.append(lines[j])
    return ""


PARSER = _extract_parser()


def _run(stdin_text: str) -> str:
    """Feed stdin to the extracted parser, return its stdout stripped."""
    p = subprocess.run(
        [sys.executable, "-c", PARSER],
        input=stdin_text, capture_output=True, text=True,
    )
    # The shipped call site appends `|| true`, so a non-zero exit is tolerated
    # by install.sh; what matters to the gate is stdout.
    return p.stdout.strip()


def _status(uid=1, users=None, self_extra=None):
    self_obj = {"UserID": uid}
    if self_extra:
        self_obj.update(self_extra)
    return json.dumps({"Self": self_obj, "User": users if users is not None else {}})


# Everything in this list MUST resolve to empty. A non-empty answer here writes
# an nginx gate that admits an identity, so these are the security-relevant
# cases. Built at module scope so the table stays readable as a table.
FAIL_CLOSED_CASES = [
    ("tagged node (no human owner)",
     _status(uid=1, users={"1": {"LoginName": "tagged-devices"}})),
    ("tagged node with suffix",
     _status(uid=1, users={"1": {"LoginName": "tagged-devices-prod"}})),
    ("no Self object",           json.dumps({"User": {"1": {"LoginName": "x@y.z"}}})),
    ("Self without UserID",      json.dumps({"Self": {}, "User": {"1": {"LoginName": "x@y.z"}}})),
    ("UserID not in User map",   _status(uid=99, users={"1": {"LoginName": "x@y.z"}})),
    ("empty User map",           _status(uid=1, users={})),
    ("LoginName empty",          _status(uid=1, users={"1": {"LoginName": ""}})),
    ("LoginName whitespace",     _status(uid=1, users={"1": {"LoginName": "   "}})),
    ("user object has no LoginName", _status(uid=1, users={"1": {}})),
    ("malformed JSON",           "{not json at all"),
    ("empty stdin",              ""),
    ("JSON is a list",           "[]"),
    ("JSON is a string",         '"hello"'),
    ("JSON is null",             "null"),
    ("User is not a dict",       json.dumps({"Self": {"UserID": 1}, "User": []})),
]


class TailnetOwnerParserTests(unittest.TestCase):

    def test_the_extraction_found_real_code(self):
        """Without this, an empty PARSER would make every case below vacuously pass."""
        self.assertTrue(PARSER, (
            "could not extract the owner parser from install.sh -- the anchors "
            "changed. Every test in this file would otherwise pass by running an "
            "empty program."
        ))
        self.assertIn("LoginName", PARSER,
                      "extracted block does not look like the owner parser")
        self.assertIn("tagged-devices", PARSER, (
            "extracted block has no tagged-devices guard; either the wrong block "
            "was captured or the fail-closed rule was removed"
        ))
        self.assertGreaterEqual(len(PARSER.splitlines()), 8,
                                f"suspiciously short: {PARSER!r}")

    # ----------------------------------------------------------------------
    # The ONE case that must return a login. Empty here = the wiki is never
    # served off-box, so a false negative is a real (if safe) regression.
    # ----------------------------------------------------------------------
    def test_resolves_the_owner_login(self):
        out = _run(_status(uid=42, users={"42": {"LoginName": "person@example.com"}}))
        self.assertEqual(out, "person@example.com")

    def test_uid_is_looked_up_as_a_string_key(self):
        """Tailscale's User map is keyed by STRING uid while Self.UserID is an int.

        If the lookup ever stops coercing, this silently returns empty and the
        wiki quietly stops being served -- a failure with no error message.
        """
        self.assertEqual(
            _run(_status(uid=7, users={"7": {"LoginName": "a@b.example"}})),
            "a@b.example",
        )

    # ----------------------------------------------------------------------
    # subTest so ONE red case does not mask the fourteen after it. A plain
    # loop would stop at the first failure and report a single defect where
    # there might be several, which is how a partial fix reads as a full one.
    # ----------------------------------------------------------------------
    def test_returns_empty_and_fails_closed(self):
        for label, payload in FAIL_CLOSED_CASES:
            with self.subTest(case=label):
                out = _run(payload)
                self.assertEqual(out, "", (
                    f"{label}: parser returned {out!r}. A non-empty owner writes an "
                    f"nginx gate that admits that identity, so anything ambiguous "
                    f"must be empty."
                ))

    def test_never_crashes_the_installer(self):
        """The call site is inside a command substitution during install.

        An uncaught traceback on stderr would land in the customer's install log
        looking like a failure even though `|| true` swallows the status.
        """
        for payload in ("{not json", "", "[]", "null"):
            with self.subTest(payload=payload):
                p = subprocess.run([sys.executable, "-c", PARSER],
                                   input=payload, capture_output=True, text=True)
                self.assertNotIn("Traceback", p.stderr,
                                 f"parser raised on {payload!r}:\n{p.stderr}")

    def test_the_suite_discriminates(self):
        """NEGATIVE CONTROL.

        Strip the tagged-devices guard and the tagged-node case MUST start
        returning a login. Without this, a parser that returned "" for absolutely
        everything would pass every fail-closed case above while also being
        completely broken.
        """
        neutered = PARSER.replace('not login.startswith("tagged-devices")', "True")
        self.assertNotEqual(neutered, PARSER,
                            "could not neuter the guard; control is inert")
        p = subprocess.run(
            [sys.executable, "-c", neutered],
            input=_status(uid=1, users={"1": {"LoginName": "tagged-devices"}}),
            capture_output=True, text=True,
        )
        self.assertEqual(p.stdout.strip(), "tagged-devices", (
            "removing the tagged-devices guard did NOT change the outcome, so the "
            "fail-closed assertions above are not testing that guard at all"
        ))


if __name__ == "__main__":
    unittest.main()
