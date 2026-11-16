"""Contract: the pre-meeting brief sender reads meetings ONLY from a filtered Hub surface.

The owner's "ignore calendar X" rule is enforced on the Hub, before the sender
sees a meeting (CM041 #266, the four-surface eval plus meeting prep). That is
only true while the sender's read goes to one of those filtered surfaces. This
test reads the sender heredoc out of install.sh and fails if the sender:

  1. fetches from any Hub route that is not on the filtered list, or
  2. reads a calendar itself (EventKit, CalDAV, .ics, Calendar sqlite), or
  3. makes a read through any HTTP client other than the one filtered GET.

The only outbound POST (the /announce send to the assistant gateway) is a
delivery, not a read, and is listed explicitly.

Mutant: the same checker is run on a copy of the sender with its read pointed
at /api/v1/person/<slug>/timeline (an unfiltered graph route). It must go RED.

Synthetic text only; no personal data.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO_ROOT / "install.sh"

# The Hub routes whose output the Hub filters by the owner's calendar rules
# (CM041 #266 eval: calendar, calendar_today, meeting_upcoming; timeline and
# meeting prep are in-process and not routes the sender can name).
FILTERED_HUB_ROUTES = frozenset({
    "/calendar",
    "/calendar/today",
    "/api/v1/meeting/upcoming",
})
# The one read the sender is allowed to make, and the one delivery POST.
SENDER_READ = "/api/v1/meeting/upcoming"
SENDER_DELIVERY_POST = "/announce"

HEREDOC_OPEN = "cat > \"${OSTLER_DIR}/bin/ostler-meeting-brief-sender\" <<'BRIEFEOF'"
HEREDOC_CLOSE = "BRIEFEOF"

# Shapes, not names: anything that reads a calendar store or an ICS/CalDAV feed,
# or an HTTP client other than the sender's own curl.
CALENDAR_READ_SHAPES = re.compile(
    r"EventKit|EKEventStore|requestFullAccessToEvents|caldav|CalDAV|"
    r"icalendar|\.ics\b|Calendar\.sqlitedb|Calendar Cache|calendarstore|"
    r"ical-query|gws\s+calendar|osascript.*Calendar",
    re.IGNORECASE,
)
OTHER_HTTP_SHAPES = re.compile(
    r"urllib|urlopen|requests\.|http\.client|httpx|aiohttp|\bwget\b|/dev/tcp|\bnc\s",
)


def sender_block(install_text: str) -> str:
    """The sender script body, between its heredoc markers."""
    start = install_text.index(HEREDOC_OPEN) + len(HEREDOC_OPEN)
    end = install_text.index("\n" + HEREDOC_CLOSE, start)
    return install_text[start:end]


def hub_reads(block: str) -> list[str]:
    """Every Hub route the sender GETs (curl without -X POST), by path."""
    paths = []
    for m in re.finditer(r'\$\{HUB_HOST\}(/[^"\s?]*)', block):
        paths.append(m.group(1))
    return paths


def check(install_text: str) -> list[str]:
    """Return the list of violations. Empty means the sender is filtered."""
    block = sender_block(install_text)
    problems = []

    reads = hub_reads(block)
    if not reads:
        problems.append("no Hub read found in the sender (cannot verify the filter)")
    for path in reads:
        if path not in FILTERED_HUB_ROUTES:
            problems.append(f"sender reads unfiltered Hub route {path}")
    if reads and set(reads) != {SENDER_READ}:
        problems.append(f"sender reads {sorted(set(reads))}, expected only {SENDER_READ}")

    for m in CALENDAR_READ_SHAPES.finditer(block):
        problems.append(f"sender reads a calendar store or feed itself: {m.group(0)!r}")

    for m in OTHER_HTTP_SHAPES.finditer(block):
        problems.append(f"sender makes a read through another HTTP shape: {m.group(0)!r}")

    # Every POST must be the known delivery, nothing else.
    for m in re.finditer(r'-X POST[^\n]*\n?[^\n]*', block):
        if SENDER_DELIVERY_POST not in m.group(0) and "ASSISTANT_URL" not in m.group(0):
            problems.append(f"unexpected POST: {m.group(0)[:120]!r}")

    return problems


class MeetingSenderEndpointIsFiltered(unittest.TestCase):
    def setUp(self):
        self.text = INSTALL_SH.read_text(encoding="utf-8")

    def test_control_the_real_sender_is_filtered(self):
        # Positive control: the shipped sender passes, and the checker really
        # found the sender's read (a checker that reads nothing also passes).
        self.assertEqual(hub_reads(sender_block(self.text)), [SENDER_READ])
        self.assertEqual(check(self.text), [], check(self.text))

    def test_mutant_unfiltered_route_goes_red(self):
        # Mutant: point the sender's read at the person timeline (an unfiltered
        # graph route). The checker must report it, or the contract is blind.
        mutated = self.text.replace(
            '"${HUB_HOST}/api/v1/meeting/upcoming?within_minutes=${WITHIN_MINUTES}"',
            '"${HUB_HOST}/api/v1/person/example-person/timeline?limit=50"',
            1,
        )
        self.assertNotEqual(mutated, self.text, "mutant did not apply")
        problems = check(mutated)
        self.assertTrue(
            any("/api/v1/person/example-person/timeline" in p for p in problems),
            problems,
        )

    def test_mutant_calendar_read_in_sender_goes_red(self):
        # Mutant: the sender reads an ICS feed itself. Shape check must catch it.
        marker = "import json, os, sqlite3, subprocess, sys, tempfile"
        mutated = self.text.replace(
            marker, marker + "\n# ical = open('/tmp/x.ics')", 1)
        self.assertNotEqual(mutated, self.text, "mutant did not apply")
        problems = check(mutated)
        self.assertTrue(any(".ics" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main(verbosity=2)
