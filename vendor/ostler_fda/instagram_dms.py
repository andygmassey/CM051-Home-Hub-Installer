"""Read direct messages out of a Meta "Download Your Information" (Instagram)
(DYI) export into CM048 conversation payloads.

Why this is a thin module
=========================

Instagram's DYI export uses the SAME per-thread JSON shape as the
Facebook Messenger export (``participants`` + ``messages`` +
``title`` + ``thread_path``, split across ``message_N.json`` files,
every string double-encoded as latin-1 escaped UTF-8). So this module
reuses ``facebook_messenger`` for everything that is genuinely shared:
the mojibake repair (``fix_mojibake``), the multi-file thread merge and
chronological sort (``load_thread``), the T1/T2/T3 privacy classifier
(``classify_thread``), the transcript renderer and the counts-only
stats. It only owns what differs:

* WHERE the threads live (``your_instagram_activity/messages/inbox`` in
  current exports, ``messages/inbox`` in older ones), and the
  ``message_requests`` folder, which is skipped by default (strangers'
  first messages the owner never accepted).
* WHO the operator is. Instagram ``sender_name`` is the profile display
  name, which often differs from the name the owner gave the installer.
  The export carries the owner's own profile under
  ``personal_information/personal_information.json``; that name wins
  over the env var, which stays the fallback.
* WHICH lines are noise. Instagram writes reactions and likes as
  content strings ("Liked a message", "Reacted <emoji> to your
  message"). They carry no conversational content and are dropped.
* The counterpart's Instagram USERNAME, recovered from the thread folder
  (``inbox/<username>_<digits>``) for 1:1 threads, so the People join
  can match a handle and not only a display name.
* Channel naming (``instagram``) and the conversation id prefix
  (``igd_``), so an Instagram thread can never collide with a
  Messenger thread of the same slug.

Export layout (from Meta's documented DYI JSON and community parsers;
see UNVERIFIED below)::

    <root>/your_instagram_activity/messages/inbox/<user>_<id>/message_1.json
    <root>/your_instagram_activity/messages/message_requests/<user>_<id>/...
    <root>/personal_information/personal_information/personal_information.json
    <root>/messages/inbox/<user>_<id>/message_1.json        (older exports)
    <root>/personal_information/personal_information.json   (older exports)

UNVERIFIED against a real export (no real export was opened; fixtures
are built from the documented shape):

* the exact ``personal_information.json`` key path
  (``profile_user[0].string_map_data.Name.value`` / ``.Username.value``);
* the reaction/like phrasing beyond the two patterns handled here;
* whether current exports still omit ``thread_type`` (group detection
  falls back to participant count > 2, which is safe either way);
* the ``<username>_<digits>`` thread-folder convention for usernames.

Privacy posture
===============

Same three-tier discipline as Messenger, explicit ``privacy_level`` L2
on every ingestible payload (CM048's channel-default table has no
``instagram`` row yet, and the L3 fallback would hide DMs from the
assistant). The ``--json`` stdout line is counts only: no names, no
handles, no bodies.

Ongoing capture is NOT this module. DMs on personal accounts have no
official Instagram API; re-import of a fresh DYI export is idempotent (stable
conversation ids), which is the supported refresh route.
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Iterable, List, Optional

from . import facebook_messenger as _fbm
from .facebook_messenger import (
    PRIVACY_L2,
    TIER_T1_DM,
    TIER_T2_GROUP,
    TIER_T3_SKIP,
    FacebookThread,
    conversation_stats,
    fix_mojibake,
    render_transcript,
)

logger = logging.getLogger(__name__)

CHANNEL = "instagram"
SOURCE = "instagram_dms"
SOURCE_APP = "instagram"
CONVERSATION_ID_PREFIX = "igd"
OUTPUT_FILENAME = "instagram_dm_conversations.json"

# Inbox roots inside an Instagram DYI export, newest layout first.
_INBOX_RELATIVE_ROOTS = (
    "your_instagram_activity/messages/inbox",
    "messages/inbox",
)
_REQUESTS_RELATIVE_ROOTS = (
    "your_instagram_activity/messages/message_requests",
    "messages/message_requests",
)
_PERSONAL_INFO_RELATIVE = (
    "personal_information/personal_information/personal_information.json",
    "personal_information/personal_information.json",
)

# Instagram writes likes and reactions as message content. Pure noise
# for a transcript: matched after the mojibake repair, whole-string.
_NOISE_PATTERNS = (
    re.compile(r"^Liked a message$"),
    re.compile(r"^Reacted .{1,16} to your message\s*$"),
)

# ``inbox/<username>_<digits>``: Instagram usernames are [a-z0-9._],
# at most 30 chars; the trailing digits are the thread id.
_THREAD_PATH_USERNAME = re.compile(r"(?:^|/)([a-z0-9._]{1,30})_\d{5,}$")


# ---------------------------------------------------------------------------
# Export traversal
# ---------------------------------------------------------------------------


def find_inbox_dirs(export_root: Path, *, include_requests: bool = False) -> List[Path]:
    """Every Instagram inbox directory under ``export_root``.

    Accepts the export root, a ``messages`` dir, or an ``inbox`` dir.
    ``message_requests`` is only included when asked for.
    """
    export_root = Path(export_root)
    rels = list(_INBOX_RELATIVE_ROOTS)
    if include_requests:
        rels += list(_REQUESTS_RELATIVE_ROOTS)
    found: List[Path] = []
    if export_root.name == "inbox" and export_root.is_dir():
        found.append(export_root)
    if export_root.name == "messages":
        for sub in ("inbox", "message_requests") if include_requests else ("inbox",):
            cand = export_root / sub
            if cand.is_dir() and cand not in found:
                found.append(cand)
    for rel in rels:
        cand = export_root / rel
        if cand.is_dir() and cand not in found:
            found.append(cand)
    return found


def count_message_requests(export_root: Path) -> int:
    """How many request threads were present (and skipped). Counts only."""
    n = 0
    for rel in _REQUESTS_RELATIVE_ROOTS:
        d = Path(export_root) / rel
        if d.is_dir():
            n += sum(1 for p in d.iterdir() if p.is_dir())
    return n


# ---------------------------------------------------------------------------
# Operator identity
# ---------------------------------------------------------------------------


def _string_map_value(entry: dict, key: str) -> str:
    smd = entry.get("string_map_data")
    if not isinstance(smd, dict):
        return ""
    field_ = smd.get(key)
    if not isinstance(field_, dict):
        return ""
    return fix_mojibake(field_.get("value")).strip()


def read_owner_profile(export_root: Path) -> dict:
    """The owner's own Instagram display name and username, if exported.

    Returns ``{"name": str|None, "username": str|None}``. Never raises:
    a missing or reshaped file yields Nones (the env fallback then
    applies).
    """
    out = {"name": None, "username": None}
    for rel in _PERSONAL_INFO_RELATIVE:
        path = Path(export_root) / rel
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        users = data.get("profile_user") if isinstance(data, dict) else None
        if not isinstance(users, list) or not users or not isinstance(users[0], dict):
            continue
        name = _string_map_value(users[0], "Name")
        username = _string_map_value(users[0], "Username")
        out["name"] = name or None
        out["username"] = username or None
        break
    return out


def resolve_operator_name(export_root: Path, explicit: Optional[str] = None) -> Optional[str]:
    """Operator display name AS IT APPEARS IN THIS EXPORT.

    Precedence: explicit argument, then the export's own profile name,
    then the install-wide env vars (via facebook_messenger).
    """
    if explicit and explicit.strip():
        return explicit.strip()
    profile_name = read_owner_profile(export_root).get("name")
    if profile_name:
        return profile_name
    return _fbm.resolve_operator_name(None)


# ---------------------------------------------------------------------------
# Instagram-specific thread clean-up
# ---------------------------------------------------------------------------


def is_noise(text: str) -> bool:
    return any(p.match(text or "") for p in _NOISE_PATTERNS)


def counterpart_username(thread: FacebookThread) -> Optional[str]:
    """Instagram username of the other party in a 1:1 thread, else None."""
    if thread.is_group:
        return None
    m = _THREAD_PATH_USERNAME.search(thread.thread_slug or "")
    return m.group(1) if m else None


def _strip_noise(thread: FacebookThread) -> FacebookThread:
    thread.messages = [m for m in thread.messages if not is_noise(m.text)]
    # Re-classify: dropping noise can change the operator's share.
    thread.tier = _fbm.classify_thread(thread)
    return thread


def parse_export(
    export_root: Path,
    operator_name: Optional[str] = None,
    *,
    include_requests: bool = False,
) -> List[FacebookThread]:
    """Parse every Instagram DM thread under a DYI export root.

    Returns threads including T3 (callers filter), excluding threads with
    no operator or no conversational content left after noise removal.

    Raises FileNotFoundError when no Instagram inbox exists.
    """
    export_root = Path(export_root)
    inbox_dirs = find_inbox_dirs(export_root, include_requests=include_requests)
    if not inbox_dirs:
        raise FileNotFoundError(
            f"No Instagram messages inbox found under {export_root}. Point "
            "--export-path at the unzipped Instagram 'Download Your "
            "Information' folder (JSON format)."
        )
    operator = resolve_operator_name(export_root, operator_name)

    threads: List[FacebookThread] = []
    skipped_no_operator = 0
    for inbox in inbox_dirs:
        for thread_dir in sorted(p for p in inbox.iterdir() if p.is_dir()):
            thread = _fbm.load_thread(thread_dir, operator)
            if thread is None:
                continue
            thread = _strip_noise(thread)
            if not thread.messages:
                continue
            if operator is None:
                skipped_no_operator += 1
                continue
            present = thread.operator_is_participant or any(
                m.is_from_operator for m in thread.messages
            )
            if not present:
                skipped_no_operator += 1
                continue
            threads.append(thread)
    if skipped_no_operator:
        logger.info(
            "instagram_dms: skipped %d thread(s) with no identifiable operator",
            skipped_no_operator,
        )
    return threads


# ---------------------------------------------------------------------------
# CM048 payload construction
# ---------------------------------------------------------------------------


def thread_conversation_id(thread: FacebookThread) -> str:
    """Stable id: same export (or a later re-export) gives the same id.

    Keyed on the thread folder (stable across re-exports) and the date of
    the first message; prefixed ``igd_`` so it cannot collide with a
    Messenger thread id (``fbm_``) built from an identical slug.
    """
    fb_id = _fbm.thread_conversation_id(thread)  # fbm_<date>_<slug>
    return CONVERSATION_ID_PREFIX + fb_id[len("fbm"):]


def thread_to_payload(thread: FacebookThread) -> dict:
    """CM048 ``process()`` payload for one Instagram thread."""
    started = thread.started_at
    ended = thread.ended_at
    participants: List[dict] = []
    if thread.operator_name:
        participants.append(
            {"id": thread.operator_name, "display": thread.operator_name, "role": "user"}
        )
    handle = counterpart_username(thread)
    for name in thread.participants:
        entry = {"id": name, "display": name, "role": "other"}
        if handle and len(thread.participants) == 1:
            # Flat per-participant handle, the same shape CM048's schema
            # gives ``email``. CM048's handle_resolver joins on phone/email
            # only today, so this rides along for the People join that
            # contact_syncer/instagram_social.py already keys on usernames.
            entry["instagram"] = handle
        participants.append(entry)

    conversation_id = thread_conversation_id(thread)
    metadata = {
        "conversation_id": conversation_id,
        "date": started.strftime("%Y-%m-%d") if started else "1970-01-01",
        "source": SOURCE,
        "channel": CHANNEL,
        "source_app": SOURCE_APP,
        "participants": participants,
        "started_at": started.isoformat() if started else None,
        "ended_at": ended.isoformat() if ended else None,
        "privacy_level": PRIVACY_L2,
        "chat_type": "group" if thread.is_group else "private",
        "is_group_chat": thread.is_group,
        "group_subject": thread.title if thread.is_group else None,
        "thread_slug": thread.thread_slug,
        "contact_source_tier": thread.tier,
        "message_count": len(thread.messages),
    }
    return {
        "conversation_id": conversation_id,
        "transcript": render_transcript(thread),
        "metadata": metadata,
    }


def ingestible_payloads(threads: Iterable[FacebookThread]) -> List[dict]:
    return [thread_to_payload(t) for t in threads if t.tier != TIER_T3_SKIP]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    """Extract + classify + stage payloads; counts-only JSON on stdout.

    Exit 0 on success or graceful skip (export missing, no operator);
    1 on an unexpected crash; 2 on argparse failure.
    """
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        prog="pwg-instagram-dms",
        description="Read DMs from an Instagram data export (JSON format).",
    )
    parser.add_argument("--export-path", type=Path, required=True)
    parser.add_argument("--operator-name", type=str, default=None)
    parser.add_argument("--output-dir", type=Path, default=None)
    parser.add_argument("--include-requests", action="store_true",
                        help="Also import unaccepted message requests (off by default).")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    result: dict = {
        "tier_t1_dm_threads": 0, "tier_t2_group_threads": 0,
        "tier_t3_skipped_threads": 0, "ingestible_threads": 0,
        "total_messages": 0, "people_added": 0,
        "message_requests_skipped": 0, "errors": [], "status": "ok",
    }

    def _emit() -> None:
        if args.json:
            print(json.dumps(result))

    try:
        threads = parse_export(args.export_path, args.operator_name,
                               include_requests=args.include_requests)
    except FileNotFoundError as exc:
        print(f"pwg-instagram-dms: export not found ({exc})", file=sys.stderr)
        result["status"] = "not_found"
        _emit()
        return 0
    except Exception as exc:  # noqa: BLE001 -- type only (privacy)
        print(f"pwg-instagram-dms: unexpected failure ({type(exc).__name__})", file=sys.stderr)
        result["status"] = "error"
        result["errors"].append(type(exc).__name__)
        _emit()
        return 1

    if resolve_operator_name(args.export_path, args.operator_name) is None:
        print("pwg-instagram-dms: operator name not found in the export or "
              "OSTLER_USER_DISPLAY_NAME; skipping", file=sys.stderr)
        result["status"] = "no_operator"
        _emit()
        return 0

    result.update(conversation_stats(threads))
    if not args.include_requests:
        result["message_requests_skipped"] = count_message_requests(args.export_path)

    if not args.dry_run:
        out_dir = args.output_dir or (Path.home() / ".ostler" / "imports" / "fda")
        try:
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / OUTPUT_FILENAME).write_text(
                json.dumps(ingestible_payloads(threads), indent=2)
            )
        except OSError as exc:
            result["status"] = "write_error"
            result["errors"].append(type(exc).__name__)
            _emit()
            return 0
    _emit()
    return 0


__all__ = [
    "CHANNEL", "SOURCE", "SOURCE_APP", "OUTPUT_FILENAME",
    "TIER_T1_DM", "TIER_T2_GROUP", "TIER_T3_SKIP",
    "find_inbox_dirs", "count_message_requests", "read_owner_profile",
    "resolve_operator_name", "is_noise", "counterpart_username",
    "parse_export", "thread_conversation_id", "thread_to_payload",
    "ingestible_payloads", "conversation_stats", "main",
]


if __name__ == "__main__":
    import sys

    sys.exit(main())
