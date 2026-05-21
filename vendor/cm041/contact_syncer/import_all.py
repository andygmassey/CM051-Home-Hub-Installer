"""Master GDPR Import Script — runs all platform parsers in sequence.

This is the one-stop import for beta testers. Point it at a directory
containing GDPR exports from various platforms, and it will detect
which exports are present and run the appropriate parsers.

Usage:
    python -m contact_syncer.import_all \
        --exports-dir /path/to/gdpr/exports/ \
        [--dry-run] [--verbose]

Expected directory structure:
    exports/
    ├── LinkedIn/           (Complete_LinkedInDataExport_*)
    │   ├── Connections.csv
    │   ├── messages.csv
    │   ├── Positions.csv
    │   └── ...
    ├── Facebook/           (your_facebook_activity/)
    │   ├── connections/friends/your_friends.json
    │   ├── events/
    │   └── ...
    ├── Instagram/          (connections/)
    │   └── followers_and_following/
    ├── Twitter/            (extracted/data/)
    │   ├── contact.js
    │   └── ...
    ├── WhatsApp/           (extracted/whatsapp_connections/)
    │   └── contacts.json
    └── Google/             (extracted/Takeout/)
        └── Calendar/*.ics

Each parser is independent — missing exports are skipped gracefully.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple

from contact_syncer import config

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)


def find_export(base: Path, patterns: List[str]) -> str | None:
    """Find a file matching one of the given glob patterns under base."""
    for pattern in patterns:
        matches = list(base.rglob(pattern))
        if matches:
            return str(matches[0])
    return None


def find_dir(base: Path, patterns: List[str]) -> str | None:
    """Find a directory matching one of the given patterns under base."""
    for pattern in patterns:
        for p in base.rglob(pattern):
            if p.is_dir():
                return str(p)
    return None


def run_import(
    exports_dir: str,
    *,
    dry_run: bool = False,
    verbose: bool = False,
    user_name: str,
) -> Dict[str, Dict]:
    """Detect and run all available GDPR import parsers.

    Returns a dict of parser_name -> results dict.
    """
    base = Path(exports_dir)
    results: Dict[str, Dict] = {}
    start = time.time()

    print("=" * 60)
    print("PWG GDPR Import — scanning for available exports...")
    print("=" * 60)
    print()

    # ── 1. LinkedIn Connections ─────────────────────────────────
    csv_path = find_export(base, ["Connections.csv", "connections.csv"])
    if csv_path:
        print("📋 LinkedIn Connections found")
        from contact_syncer.linkedin_connections import import_connections
        results["linkedin_connections"] = import_connections(
            csv_path, dry_run=dry_run, verbose=verbose,
        )
        print()
    else:
        print("⏭  LinkedIn Connections — not found, skipping")

    # ── 2. LinkedIn Career ──────────────────────────────────────
    positions_path = find_export(base, ["Positions.csv", "positions.csv"])
    if positions_path:
        linkedin_dir = str(Path(positions_path).parent)
        print("💼 LinkedIn Career data found")
        from contact_syncer.linkedin_career import import_career_data
        results["linkedin_career"] = import_career_data(
            linkedin_dir, dry_run=dry_run, verbose=verbose,
            user_name=user_name,
        )
        print()
    else:
        print("⏭  LinkedIn Career — not found, skipping")

    # ── 3. LinkedIn Messages ────────────────────────────────────
    messages_path = find_export(base, ["messages.csv"])
    if messages_path and "linkedin" in str(messages_path).lower():
        print("💬 LinkedIn Messages found")
        from contact_syncer.linkedin_messages import import_messages
        results["linkedin_messages"] = import_messages(
            messages_path, dry_run=dry_run, verbose=verbose,
            user_name=user_name,
        )
        print()
    else:
        print("⏭  LinkedIn Messages — not found, skipping")

    # ── 4. Facebook Friends ─────────────────────────────────────
    friends_path = find_export(base, ["your_friends.json"])
    if friends_path:
        print("👥 Facebook Friends found")
        from contact_syncer.facebook_friends import import_friends
        results["facebook_friends"] = import_friends(
            friends_path, dry_run=dry_run, verbose=verbose,
        )
        print()
    else:
        print("⏭  Facebook Friends — not found, skipping")

    # ── 5. Facebook Events ──────────────────────────────────────
    events_dir = find_dir(base, ["events"])
    events_check = find_export(base, ["event_invitations.json", "your_events.json"])
    if events_check:
        events_directory = str(Path(events_check).parent)
        print("📅 Facebook Events found")
        from contact_syncer.facebook_events import import_events
        results["facebook_events"] = import_events(
            events_directory, dry_run=dry_run, verbose=verbose,
        )
        print()
    else:
        print("⏭  Facebook Events — not found, skipping")

    # ── 6. Instagram Social ─────────────────────────────────────
    ig_dir = find_dir(base, ["followers_and_following"])
    if ig_dir:
        print("📸 Instagram Social Graph found")
        from contact_syncer.instagram_social import import_instagram
        results["instagram_social"] = import_instagram(
            ig_dir, dry_run=dry_run, verbose=verbose,
        )
        print()
    else:
        print("⏭  Instagram Social — not found, skipping")

    # ── 7. Google Calendar ──────────────────────────────────────
    ics_path = find_export(base, ["*.ics"])
    if ics_path and os.path.getsize(ics_path) > 1000:
        print("📆 Google Calendar found")
        from contact_syncer.google_calendar import import_calendar
        results["google_calendar"] = import_calendar(
            ics_path, dry_run=dry_run, verbose=verbose,
            user_name=user_name,
        )
        print()
    else:
        print("⏭  Google Calendar — not found, skipping")

    # ── 8. WhatsApp Contacts ────────────────────────────────────
    wa_contacts = find_export(base, ["contacts.json"])
    if wa_contacts and "whatsapp" in str(wa_contacts).lower():
        print("📱 WhatsApp Contacts found")
        from contact_syncer.whatsapp_contacts import cross_reference
        results["whatsapp_contacts"] = cross_reference(
            wa_contacts, dry_run=dry_run, verbose=verbose,
        )
        print()
    else:
        print("⏭  WhatsApp Contacts — not found, skipping")

    # ── 9. Twitter/X Contacts ───────────────────────────────────
    twitter_contacts = find_export(base, ["contact.js"])
    if twitter_contacts:
        print("🐦 Twitter/X Contacts found")
        from contact_syncer.twitter_contacts import cross_reference as tw_xref
        results["twitter_contacts"] = tw_xref(
            twitter_contacts, dry_run=dry_run, verbose=verbose,
        )
        print()
    else:
        print("⏭  Twitter/X Contacts — not found, skipping")

    # ── Summary ─────────────────────────────────────────────────
    elapsed = time.time() - start
    print("=" * 60)
    print(f"Import complete in {elapsed:.0f}s")
    print(f"Parsers run: {len(results)}")
    for name, r in results.items():
        errors = r.get("errors", 0)
        status = "✅" if errors == 0 else f"⚠️  {errors} errors"
        print(f"  {name}: {status}")
    print("=" * 60)

    return results


def main():
    parser = argparse.ArgumentParser(
        description="PWG Master GDPR Import — detect and run all available parsers"
    )
    parser.add_argument("--exports-dir", type=str, required=True,
                        help="Root directory containing GDPR exports from various platforms")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument(
        "--user-name",
        type=str,
        default=config.USER_DISPLAY_NAME or None,
        help=(
            "Your name as it appears in platform exports (for sender "
            "matching). Falls back to the USER_DISPLAY_NAME (or PWG_USER_NAME) "
            "env var. Required — no hardcoded default, so another user's "
            "export can't get silently tagged under the developer's identity."
        ),
    )
    args = parser.parse_args()

    if not args.user_name:
        print(
            "Error: --user-name is required (or set USER_DISPLAY_NAME / "
            "PWG_USER_NAME in the environment). We refuse to fall back to a "
            "hardcoded name because it would silently misattribute senders "
            "across all detected exports.",
            file=sys.stderr,
        )
        return 2

    if not os.path.isdir(args.exports_dir):
        print(f"Directory not found: {args.exports_dir}", file=sys.stderr)
        return 1

    results = run_import(
        args.exports_dir,
        dry_run=args.dry_run,
        verbose=args.verbose,
        user_name=args.user_name,
    )

    total_errors = sum(r.get("errors", 0) for r in results.values())
    return 0 if total_errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
