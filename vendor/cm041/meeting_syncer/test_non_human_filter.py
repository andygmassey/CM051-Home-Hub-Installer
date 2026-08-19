"""Unit tests for MeetingSyncer._looks_non_human.

Run from the people-graph project root with the local venv:

    .venv/bin/python meeting_syncer/test_non_human_filter.py

No pytest dependency — pure asserts so it works with the same Python
that ships on the Mac Mini (3.9).
"""
from __future__ import annotations

import sys
from pathlib import Path

# Import the classmethod without booting the whole syncer (which needs
# Qdrant / Oxigraph connections). We dynamically load the file and grab
# the class attribute directly.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from meeting_syncer.syncer import MeetingSyncer  # noqa: E402

looks = MeetingSyncer._looks_non_human


def t(name, email, expected, why):
    got = looks(name, email)
    marker = "OK" if got == expected else "FAIL"
    print(f"  [{marker}] ({name!r:40s} <{email}>) -> {got}  — {why}")
    return got == expected


def main():
    results = []

    print("\n=== Should be FILTERED (non-human) ===")
    results += [
        t("Eventbrite", "events@eventbrite.com", True, "local=events"),
        t("Substack Team", "hello@substack.com", True, "local=hello"),
        t("Foo Updates", "updates@mail.foo.com", True, "local=updates"),
        t("Foo Newsletter", "digest@foo.io", True, "local=digest"),
        t("GitHub", "notifications@github.com", True, "local=notifications"),
        t("Support", "noreply@example.com", True, "local=noreply"),
        t("Cal", "do-not-reply@example.com", True, "local=do-not-reply"),
        t("Jane Doe", "jane@notifications.github.com", True, "domain suffix notifications.github.com"),
        t("Joe Blogs", "joe@reply.mailchimp.com", True, "domain suffix .mailchimp.com"),
        t("Product Updates", "x@foo.eventbrite.com", True, "domain suffix .eventbrite.com"),
        t("Acme Support Team", "help@acme.com", True, "name contains ' team'"),
        t("Substack HQ", "a@b.com", True, "name contains ' hq'"),
        t("Claude Bot", "c@d.com", True, "name contains ' bot'"),
        t("HKWD", "", True, "all-caps short name"),
        t("AWS", "aws@amazon.com", True, "all-caps short name"),
        t("", "unknownorganizer@calendar.google.com", True, "calendar sentinel: local=unknownorganizer"),
        t("Unknown Organizer", "unknownorganizer@calendar.google.com", True, "calendar sentinel: domain calendar.google.com"),
        t("Resource", "room-a@calendar.google.com", True, "domain suffix .calendar.google.com"),
    ]

    print("\n=== Should NOT be filtered (real humans) ===")
    results += [
        t("Test User", "testuser@example.com", False, "regular human"),
        t("Robert Hoskins", "robert@company.com", False, "contains 'Bot' but not as word"),
        t("Sandra Stewart", "sandra@example.com", False, "regular human"),
        t("Li Na", "li@company.cn", False, "short 2-word name, lowercase"),
        t("J", "j@tiny.co", False, "single letter but not all-caps-short"),
        t("Madonna", "madonna@madonna.com", False, "single-word real human"),
        t("John Smith", "john@riverside.com", False, "regular human"),
        t("Tina Dyer", "tina@rekruit.com", False, "regular human"),
        t("Jane Smith", "jane.smith@example.com", False, "regular human, not a calendar sentinel"),
        # "support" in name is a false positive risk we accept — a
        # human called "Support" would have been weird anyway.
    ]

    passed = sum(1 for r in results if r)
    failed = len(results) - passed
    print(f"\n{passed}/{len(results)} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
