"""Run all FDA extractors and produce a summary.

This is the entry point called by the installer to do the instant
onboarding sweep. It tries each extractor, handles permission
errors gracefully, and produces a summary of what was found.

Per-source consent
------------------
Each source can be individually enabled or disabled. The installer's
Phase 2 picker writes the set of enabled sources to the
OSTLER_FDA_SOURCES environment variable as a comma-separated list,
which run_all() reads. Photos face data (GDPR Art. 9 special category)
is OFF unless explicitly enabled – see policy §2.

Recognised source names:
    safari_history, safari_bookmarks, imessage, apple_notes,
    photos_metadata, photos_faces, calendar, reminders, apple_mail,
    google_takeout

Usage:
    python -m ostler_fda.extract_all [--output-dir DIR]
                                       [--sources LIST]
                                       [--include-faces]
                                       [--takeout-path PATH]
"""
from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)


# Default set: everything EXCEPT photos_faces (Art. 9 special category;
# requires explicit opt-in).
DEFAULT_SOURCES = frozenset({
    "safari_history",
    "safari_bookmarks",
    "imessage",
    "apple_notes",
    "photos_metadata",
    "calendar",
    "reminders",
    "apple_mail",
})

ALL_SOURCES = DEFAULT_SOURCES | {"photos_faces", "google_takeout", "whatsapp_history", "chrome_history"}


def _resolve_enabled_sources(
    enabled_sources: Optional[Iterable[str]] = None,
) -> frozenset[str]:
    """Resolve which sources to run.

    Precedence:
        1. enabled_sources argument (if provided)
        2. OSTLER_FDA_SOURCES env var (comma-separated)
        3. DEFAULT_SOURCES (everything except photos_faces)
    """
    if enabled_sources is not None:
        return frozenset(enabled_sources)

    env_value = os.environ.get("OSTLER_FDA_SOURCES", "").strip()
    if env_value:
        # Empty entries from trailing commas etc. are dropped.
        return frozenset(s.strip() for s in env_value.split(",") if s.strip())

    return DEFAULT_SOURCES


def run_all(
    output_dir: Optional[Path] = None,
    enabled_sources: Optional[Iterable[str]] = None,
) -> dict:
    """Run enabled extractors and save results.

    Args:
        output_dir: Where to write JSON outputs. Defaults to
            ~/.ostler/imports/fda
        enabled_sources: Iterable of source names to run. None means
            "use the env var or fall back to DEFAULT_SOURCES" – see
            _resolve_enabled_sources.

    Returns:
        A summary dict suitable for the installer's completion screen.
    """
    output_dir = output_dir or (Path.home() / ".ostler" / "imports" / "fda")
    output_dir.mkdir(parents=True, exist_ok=True)

    sources = _resolve_enabled_sources(enabled_sources)

    summary = {
        "extracted_at": datetime.now(timezone.utc).isoformat(),
        "enabled_sources": sorted(sources),
        "sources": {},
    }

    # ── Safari History ──────────────────────────────────────────────
    if "safari_history" in sources:
        try:
            from .safari_history import extract_history, top_domains, to_timeline_entries
            # #48g historical backfill (CX-86): 5-year default at
            # install time. The single hardcoded `since_days=365`
            # silently truncated browsing history to 12 months even
            # when the customer was a 5-year Safari user. Operator
            # override via OSTLER_SAFARI_BACKFILL_DAYS mirrors the
            # OSTLER_IMESSAGE_BACKFILL_DAYS + OSTLER_BROWSER_BACKFILL_DAYS
            # shape so install.sh can pass one number for all three
            # browsing sources if needed.
            safari_backfill_days = int(os.environ.get("OSTLER_SAFARI_BACKFILL_DAYS", "365"))
            entries = extract_history(since_days=safari_backfill_days)
            domains = top_domains(entries, limit=100)

            timeline = to_timeline_entries(entries)
            (output_dir / "safari_history.json").write_text(
                json.dumps(timeline, indent=2, default=str)
            )
            (output_dir / "safari_domains.json").write_text(
                json.dumps([asdict(d) for d in domains], indent=2, default=str)
            )

            summary["sources"]["safari_history"] = {
                "status": "ok",
                "visits": len(entries),
                "unique_domains": len(domains),
                "top_3": [d.domain for d in domains[:3]],
            }
            logger.info("[ok] Safari: %d visits across %d domains", len(entries), len(domains))

        except PermissionError:
            summary["sources"]["safari_history"] = {"status": "no_fda"}
            logger.info("[skip] Safari History: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["safari_history"] = {"status": "not_found"}
            logger.info("[skip] Safari History: database not found")
        except Exception as e:
            summary["sources"]["safari_history"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Safari History: %s", e)
    else:
        summary["sources"]["safari_history"] = {"status": "disabled_by_user"}

    # ── Chrome History (CX-86 Gap C) ────────────────────────────────
    # Opt-in only -- default OFF, same shape as whatsapp_history.
    # JSON shape matches safari_history so the pwg_ingest.
    # ingest_browser_history() consumer reads both with one code path.
    if "chrome_history" in sources:
        try:
            from .chrome_history import (
                extract_history as _chrome_extract,
                top_domains as _chrome_top,
                to_timeline_entries as _chrome_timeline,
            )
            backfill_days = int(os.environ.get("OSTLER_BROWSER_BACKFILL_DAYS", "365"))
            chrome_entries = _chrome_extract(since_days=backfill_days)
            chrome_domains = _chrome_top(chrome_entries, limit=100)

            (output_dir / "chrome_history.json").write_text(
                json.dumps(_chrome_timeline(chrome_entries), indent=2, default=str)
            )
            (output_dir / "chrome_domains.json").write_text(
                json.dumps([asdict(d) for d in chrome_domains], indent=2, default=str)
            )
            summary["sources"]["chrome_history"] = {
                "status": "ok",
                "visits": len(chrome_entries),
                "unique_domains": len(chrome_domains),
                "top_3": [d.domain for d in chrome_domains[:3]],
            }
            logger.info(
                "[ok] Chrome: %d visits across %d domains",
                len(chrome_entries), len(chrome_domains),
            )
        except PermissionError:
            summary["sources"]["chrome_history"] = {"status": "no_fda"}
            logger.info("[skip] Chrome History: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["chrome_history"] = {"status": "not_found"}
            logger.info("[skip] Chrome History: Chrome not installed")
        except Exception as e:
            summary["sources"]["chrome_history"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Chrome History: %s", e)
    else:
        summary["sources"]["chrome_history"] = {"status": "disabled_by_user"}

    # ── Safari Bookmarks ────────────────────────────────────────────
    if "safari_bookmarks" in sources:
        try:
            from .safari_bookmarks import extract_bookmarks, reading_list
            bookmarks = extract_bookmarks()

            (output_dir / "safari_bookmarks.json").write_text(
                json.dumps([asdict(b) for b in bookmarks], indent=2)
            )

            rl = reading_list(bookmarks)
            summary["sources"]["safari_bookmarks"] = {
                "status": "ok",
                "bookmarks": len(bookmarks),
                "reading_list": len(rl),
                "folders": len(set(b.folder for b in bookmarks)),
            }
            logger.info("[ok] Safari Bookmarks: %d bookmarks, %d in Reading List", len(bookmarks), len(rl))

        except PermissionError:
            summary["sources"]["safari_bookmarks"] = {"status": "no_fda"}
            logger.info("[skip] Safari Bookmarks: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["safari_bookmarks"] = {"status": "not_found"}
        except Exception as e:
            summary["sources"]["safari_bookmarks"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Safari Bookmarks: %s", e)
    else:
        summary["sources"]["safari_bookmarks"] = {"status": "disabled_by_user"}

    # ── iMessage ────────────────────────────────────────────────────
    if "imessage" in sources:
        try:
            from .imessage import extract_conversations, conversation_stats
            # CX-84: operator override for chat.db backfill window
            # (e.g. customer with a long iMessage history may want 5y).
            # Same shape as OSTLER_BROWSER_BACKFILL_DAYS (CX-86).
            imsg_backfill_days = int(os.environ.get("OSTLER_IMESSAGE_BACKFILL_DAYS", "365"))
            conversations = extract_conversations(since_days=imsg_backfill_days)
            stats = conversation_stats(conversations)

            (output_dir / "imessage_conversations.json").write_text(
                json.dumps([asdict(c) for c in conversations], indent=2, default=str)
            )

            summary["sources"]["imessage"] = {
                "status": "ok",
                **stats,
            }
            logger.info(
                "[ok] iMessage: %d conversations, %d messages, %d contacts",
                stats.get("total_conversations", 0),
                stats.get("total_messages", 0),
                stats.get("unique_contacts", 0),
            )

        except PermissionError:
            summary["sources"]["imessage"] = {"status": "no_fda"}
            logger.info("[skip] iMessage: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["imessage"] = {"status": "not_found"}
        except Exception as e:
            summary["sources"]["imessage"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] iMessage: %s", e)
    else:
        summary["sources"]["imessage"] = {"status": "disabled_by_user"}

    # ── WhatsApp historical (CX-85) ─────────────────────────────────
    # Opt-in only: default OFF per the Q3b sign-off (more sensitive
    # than iMessage; third-party app + ToS friction). Customer
    # enables via the Phase 2 picker tickbox `whatsapp_history`.
    # T3 chats are filtered out at JSON-write time so a downstream
    # ingest cannot accidentally emit T3 triples on a stale file.
    if "whatsapp_history" in sources:
        try:
            from .whatsapp_history import (
                extract_conversations as _wa_extract,
                conversation_stats as _wa_stats,
                chat_to_dict as _wa_to_dict,
                TIER_T3_SKIP,
            )
            # #48g historical backfill (CX-85): 5-year default at
            # install time. The hardcoded `since_days=365` silently
            # capped intimate-or-active WhatsApp groups at 12 months
            # even when the customer was a 5-year user. Operator
            # override via OSTLER_WHATSAPP_BACKFILL_DAYS.
            wa_backfill_days = int(os.environ.get("OSTLER_WHATSAPP_BACKFILL_DAYS", "365"))
            chats = _wa_extract(since_days=wa_backfill_days)
            stats = _wa_stats(chats)

            # Drop T3 chats before writing the JSON -- they contain
            # nothing the ingest layer should act on, and persisting
            # them creates ambiguity for re-runs ("is this an empty
            # T3 record or a real chat that lost participants?").
            ingestible = [c for c in chats if c.tier != TIER_T3_SKIP]
            (output_dir / "whatsapp_conversations.json").write_text(
                json.dumps([_wa_to_dict(c) for c in ingestible], indent=2)
            )

            summary["sources"]["whatsapp_history"] = {
                "status": "ok",
                **stats,
            }
            logger.info(
                "[ok] WhatsApp: t1_dm=%d, t2_intimate=%d, t2_active=%d, t3_skipped=%d, people_added=%d",
                stats.get("tier_t1_dm_chats", 0),
                stats.get("tier_t2_intimate_chats", 0),
                stats.get("tier_t2_active_chats", 0),
                stats.get("tier_t3_skipped_chats", 0),
                stats.get("people_added", 0),
            )

        except PermissionError:
            summary["sources"]["whatsapp_history"] = {"status": "no_fda"}
            logger.info("[skip] WhatsApp: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["whatsapp_history"] = {"status": "not_found"}
            logger.info("[skip] WhatsApp: ChatStorage.sqlite not found (install WhatsApp Desktop)")
        except Exception as e:
            summary["sources"]["whatsapp_history"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] WhatsApp: %s", e)
    else:
        summary["sources"]["whatsapp_history"] = {"status": "disabled_by_user"}

    # ── Apple Notes ─────────────────────────────────────────────────
    if "apple_notes" in sources:
        try:
            from .apple_notes import extract_notes, notes_stats, _note_to_record
            notes = extract_notes(include_locked=False)

            notes_data = [_note_to_record(n) for n in notes]
            (output_dir / "apple_notes.json").write_text(
                json.dumps(notes_data, indent=2, default=str)
            )

            stats = notes_stats(notes)
            summary["sources"]["apple_notes"] = {"status": "ok", **stats}
            logger.info(
                "[ok] Apple Notes: %d notes (%d words)",
                stats["notes"], stats["total_words"],
            )

        except PermissionError:
            summary["sources"]["apple_notes"] = {"status": "no_fda"}
            logger.info("[skip] Apple Notes: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["apple_notes"] = {"status": "not_found"}
        except Exception as e:
            summary["sources"]["apple_notes"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Apple Notes: %s", e)
    else:
        summary["sources"]["apple_notes"] = {"status": "disabled_by_user"}

    # ── Photos Metadata + Faces ─────────────────────────────────────
    # photos_metadata: dates, place names, photo events. Always-safe to enable.
    # photos_faces: face recognition data – GDPR Art. 9 special-category data.
    # Requires explicit opt-in via the installer picker (--include-faces or
    # OSTLER_FDA_SOURCES contains "photos_faces"). See policy §2.
    if "photos_metadata" in sources or "photos_faces" in sources:
        try:
            from .photos_metadata import extract_people, extract_photo_events

            people = []
            if "photos_faces" in sources:
                # Explicit opt-in: extract face-recognition labels.
                people = extract_people()
                (output_dir / "photos_people.json").write_text(
                    json.dumps([asdict(p) for p in people], indent=2, default=str)
                )

            events = []
            if "photos_metadata" in sources:
                # If face data was opted in, include people in events;
                # otherwise return events without people labels.
                events = extract_photo_events(
                    since_days=365,
                    with_people_only=("photos_faces" in sources),
                )
                (output_dir / "photos_events.json").write_text(
                    json.dumps([asdict(e) for e in events], indent=2, default=str)
                )

            summary["sources"]["photos"] = {
                "status": "ok",
                "faces_enabled": "photos_faces" in sources,
                "recognised_people": len(people),
                "photo_events": len(events),
                "top_people": [p.name for p in people[:5]] if people else [],
            }
            logger.info(
                "[ok] Photos: %d people, %d events (faces=%s)",
                len(people), len(events), "on" if "photos_faces" in sources else "off",
            )

        except PermissionError:
            summary["sources"]["photos"] = {"status": "no_fda"}
            logger.info("[skip] Photos: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["photos"] = {"status": "not_found"}
        except Exception as e:
            summary["sources"]["photos"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Photos: %s", e)
    else:
        summary["sources"]["photos"] = {"status": "disabled_by_user"}

    # ── Calendar ────────────────────────────────────────────────────
    if "calendar" in sources:
        try:
            from .calendar import extract_events, meeting_contacts
            events = extract_events(since_days=365, future_days=30)
            contacts = meeting_contacts(events)

            (output_dir / "calendar_events.json").write_text(
                json.dumps([asdict(e) for e in events], indent=2, default=str)
            )

            summary["sources"]["calendar"] = {
                "status": "ok",
                "events": len(events),
                "meeting_contacts": len(contacts),
            }
            logger.info("[ok] Calendar: %d events, %d meeting contacts", len(events), len(contacts))

        except PermissionError:
            summary["sources"]["calendar"] = {"status": "no_fda"}
            logger.info("[skip] Calendar: Full Disk Access not granted")
        except FileNotFoundError:
            # CX-109 (DMG #48l, 2026-05-29): pre-fix this branch wrote
            # status but emitted NO log line, so the install summary
            # showed every other source's [ok]/[skip] EXCEPT Calendar.
            # Customers saw Calendar silently missing from the readout
            # with no indication of why. Always emit a [skip] line so
            # the FDA section is impossible to read as a silent fail.
            summary["sources"]["calendar"] = {"status": "not_found"}
            logger.info("[skip] Calendar: cache not found (Calendar.app has not synced yet)")
        except Exception as e:
            # CX-109 (DMG #48l): convert from [warn] to [skip] so the
            # install.sh roll-up grep for ^\[ok\] / ^\[skip\] counts it.
            # Pre-fix, generic exceptions emitted [warn] which the grep
            # skipped over -- a third silent-fail axis on Calendar.
            summary["sources"]["calendar"] = {
                "status": "error",
                "error": "%s: %s" % (type(e).__name__, str(e)[:120]),
            }
            logger.info("[skip] Calendar: %s: %s", type(e).__name__, str(e)[:120])
    else:
        # CX-109 (DMG #48l): emit [skip] for the disabled-by-user branch
        # too. Pre-fix the else branch wrote status but no log line, so
        # Calendar disappeared from the per-source readout when the user
        # had deselected it during onboarding.
        summary["sources"]["calendar"] = {"status": "disabled_by_user"}
        logger.info("[skip] Calendar: disabled by user")

    # ── Reminders ───────────────────────────────────────────────────
    if "reminders" in sources:
        try:
            from .reminders import extract_reminders, reminder_stats
            reminders = extract_reminders(include_completed=True)
            stats = reminder_stats(reminders)

            (output_dir / "reminders.json").write_text(
                json.dumps([asdict(r) for r in reminders], indent=2, default=str)
            )

            summary["sources"]["reminders"] = {
                "status": "ok",
                **stats,
            }
            logger.info(
                "[ok] Reminders: %d total (%d pending, %d completed)",
                stats["total_reminders"], stats["pending"], stats["completed"],
            )

        except PermissionError:
            summary["sources"]["reminders"] = {"status": "no_fda"}
            logger.info("[skip] Reminders: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["reminders"] = {"status": "not_found"}
            logger.info("[skip] Reminders: database not found")
        except Exception as e:
            summary["sources"]["reminders"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Reminders: %s", e)
    else:
        summary["sources"]["reminders"] = {"status": "disabled_by_user"}

    # ── Google Takeout (Gmail mbox) ─────────────────────────────────
    # Opt-in source: requires OSTLER_FDA_SOURCES contains "google_takeout"
    # AND OSTLER_TAKEOUT_PATH points at a .mbox file (or a directory
    # containing one). The installer's Phase 2 picker auto-detects
    # Takeout archives in Downloads/Desktop/Documents and sets these.
    if "google_takeout" in sources:
        try:
            from .google_takeout import (
                find_mbox_files,
                stream_messages,
                summarise,
            )

            takeout_path_str = os.environ.get("OSTLER_TAKEOUT_PATH", "").strip()
            mbox_path: Optional[Path] = None
            if takeout_path_str:
                p = Path(takeout_path_str).expanduser()
                if p.is_file() and p.suffix.lower() == ".mbox":
                    mbox_path = p
                elif p.is_dir():
                    candidates = find_mbox_files([p])
                    mbox_path = candidates[0] if candidates else None

            if mbox_path is None:
                summary["sources"]["google_takeout"] = {"status": "not_found"}
                logger.info("[skip] Google Takeout: no .mbox file at OSTLER_TAKEOUT_PATH")
            else:
                user_email = os.environ.get("OSTLER_USER_EMAIL", "").strip() or None
                messages = list(stream_messages(
                    mbox_path,
                    since_days=365 * 5,  # 5 years; Gmail history is usually long
                    user_email=user_email,
                ))
                stats = summarise(messages)

                # Save lightweight per-message records (no full bodies)
                (output_dir / "google_takeout_messages.json").write_text(
                    json.dumps(
                        [
                            {
                                "message_id": m.message_id,
                                "from_address": m.from_address,
                                "from_name": m.from_name,
                                "from_domain": m.from_domain,
                                "to_addresses": m.to_addresses,
                                "subject": m.subject,
                                "date": m.date.isoformat() if m.date else None,
                                "body_preview": m.body_preview,
                                "gmail_labels": m.gmail_labels,
                                "is_sent": m.is_sent,
                            }
                            for m in messages
                        ],
                        indent=2,
                    )
                )

                # Save aggregate summary
                (output_dir / "google_takeout_summary.json").write_text(
                    json.dumps(
                        {
                            "total_messages": stats.total_messages,
                            "sent_count": stats.sent_count,
                            "received_count": stats.received_count,
                            "by_year": stats.by_year,
                            "top_senders": stats.top_senders,
                            "top_sender_domains": stats.top_sender_domains,
                            "gmail_labels": stats.gmail_labels,
                            "source_path": str(mbox_path),
                        },
                        indent=2,
                        default=str,
                    )
                )

                summary["sources"]["google_takeout"] = {
                    "status": "ok",
                    "total_messages": stats.total_messages,
                    "sent_count": stats.sent_count,
                    "received_count": stats.received_count,
                    "top_3_domains": [d for d, _ in stats.top_sender_domains[:3]],
                    "source_path": str(mbox_path),
                }
                logger.info(
                    "[ok] Google Takeout: %d messages from %s",
                    stats.total_messages, mbox_path.name,
                )

        except FileNotFoundError as e:
            summary["sources"]["google_takeout"] = {"status": "not_found", "error": str(e)}
            logger.info("[skip] Google Takeout: %s", e)
        except Exception as e:
            summary["sources"]["google_takeout"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Google Takeout: %s", e)
    else:
        summary["sources"]["google_takeout"] = {"status": "disabled_by_user"}

    # ── Apple Mail ─────────────────────────────────────────────────
    if "apple_mail" in sources:
        try:
            from .apple_mail import extract_messages, email_stats, frequent_contacts
            # Mail history window is configurable, same shape as the
            # other sources (OSTLER_IMESSAGE_BACKFILL_DAYS etc). The
            # hardcoded since_days=365 silently dropped everything older
            # than a year at install time; a fresh customer with a long
            # mailbox saw only the last 12 months land in the graph.
            # Default to 5 years (1825 days) to match the other
            # extractors. The customer can extend further from Doctor
            # later (#260). The message limit is lifted in step with the
            # window so a multi-year backfill is not clipped at the old
            # 10k cap.
            mail_backfill_days = int(
                os.environ.get("OSTLER_MAIL_BACKFILL_DAYS", "1825")
            )
            mail_limit = int(os.environ.get("OSTLER_MAIL_BACKFILL_LIMIT", "100000"))
            messages = extract_messages(since_days=mail_backfill_days, limit=mail_limit)
            stats = email_stats(messages)
            contacts = frequent_contacts(messages)

            (output_dir / "apple_mail.json").write_text(
                json.dumps([asdict(m) for m in messages], indent=2, default=str)
            )
            (output_dir / "apple_mail_contacts.json").write_text(
                json.dumps(contacts, indent=2, default=str)
            )

            # #259: when Apple Mail is configured but the local store
            # holds no messages in the window, do not pretend success.
            # Surface an empty_no_content status so install.sh can guide
            # the customer to connect an account / open Mail and re-run,
            # instead of silently recording "ok, 0 messages".
            if stats["total_messages"] == 0:
                summary["sources"]["apple_mail"] = {
                    "status": "empty_no_content",
                    **stats,
                }
                logger.info(
                    "[skip] Apple Mail: configured but no local messages found "
                    "in the last %d days (connect an account in Apple Mail, "
                    "then re-run)",
                    mail_backfill_days,
                )
            else:
                summary["sources"]["apple_mail"] = {
                    "status": "ok",
                    **stats,
                }
                logger.info(
                    "[ok] Apple Mail: %d messages, %d unread",
                    stats["total_messages"], stats["unread"],
                )

        except PermissionError:
            summary["sources"]["apple_mail"] = {"status": "no_fda"}
            logger.info("[skip] Apple Mail: Full Disk Access not granted")
        except FileNotFoundError:
            summary["sources"]["apple_mail"] = {"status": "not_found"}
            logger.info("[skip] Apple Mail: not configured on this Mac")
        except Exception as e:
            summary["sources"]["apple_mail"] = {"status": "error", "error": str(e)}
            logger.warning("[warn] Apple Mail: %s", e)
    else:
        summary["sources"]["apple_mail"] = {"status": "disabled_by_user"}

    # ── Save summary ────────────────────────────────────────────────
    (output_dir / "extraction_summary.json").write_text(
        json.dumps(summary, indent=2, default=str)
    )

    # Print overall summary (counting only sources we attempted)
    attempted = [s for s in summary["sources"].values() if s.get("status") != "disabled_by_user"]
    ok_count = sum(1 for s in attempted if s.get("status") == "ok")
    logger.info("")
    logger.info(
        "Extracted from %d/%d enabled sources. Data saved to %s",
        ok_count, len(attempted), output_dir,
    )

    return summary


def main():
    """CLI entry point."""
    import argparse
    parser = argparse.ArgumentParser(description="Extract data from macOS apps")
    parser.add_argument("--output-dir", type=str, default=None)
    parser.add_argument(
        "--sources",
        type=str,
        default=None,
        help="Comma-separated list of source names to enable. "
             "If omitted, uses OSTLER_FDA_SOURCES env var or falls back to "
             "the default set (everything except photos_faces).",
    )
    parser.add_argument(
        "--include-faces",
        action="store_true",
        help="Add photos_faces to the enabled sources (Art. 9 face recognition data).",
    )
    args = parser.parse_args()

    output = Path(args.output_dir) if args.output_dir else None

    enabled = None
    if args.sources is not None:
        enabled = {s.strip() for s in args.sources.split(",") if s.strip()}
    if args.include_faces:
        enabled = (enabled or set(DEFAULT_SOURCES)) | {"photos_faces"}

    summary = run_all(output, enabled_sources=enabled)

    # Print machine-readable summary for the installer to parse
    print(json.dumps(summary, default=str))


if __name__ == "__main__":
    main()
