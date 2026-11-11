"""Drive WhatsApp ChatStorage -> CM048 four-artefact bundle on the Hub.

This is the product-path conversation-memory feed for the WHATSAPP leg,
wired by a LaunchAgent tick (mirrors the email-bundle + spoken-bundle +
imessage-bundle ticks; see
``launchd/com.creativemachines.ostler.whatsapp-bundle.plist``). On each
tick it:

  1. Reads the macOS WhatsApp Desktop ChatStorage.sqlite (FDA granted at
     install) for in-tier chats (T1 DM + T2 intimate/active group),
     WITH message bodies. T3 large-passive chats are skipped at read
     time, never read.
  2. Renders each chat into a cleaned speaker-labelled transcript +
     CM048 metadata (``channel="whatsapp"`` plus chat_jid, participants,
     timestamps, the tier label, and any operator contact/group label).
  3. Invokes ``pwg-convo process <transcript> <metadata>`` so CM048
     emits the four artefacts under
     ``~/Ostler/Conversations/<date>/<slug>-<short-id>/``.

CM048 owns classification, enrichment, the L3 short-circuit, the
WhatsApp privacy ladder, and the four-artefact write. This module only
produces transcript + metadata and hands off. It is intentionally
subprocess-coupled (not an import) so the WhatsApp source and CM048 stay
independently deployable, exactly like the email + spoken feeds. It does
NOT capture or sync anything from Meta; the read is local-file-only
against WhatsApp Desktop's already-synced store.

Privacy: bodies are sensitive, so the tier gate (T3 skip) + the
L1/L2/L3 ladder gate them as strictly as any source. An operator
contacts.yaml can mark a JID's ``contact_label`` (DM) or a chat's
``group_label`` (group) -- a family / partner / sensitive label
escalates the thread to L3 via CM048's ladder, so its bundle lands on
disk but never reaches Qdrant / Oxigraph. An explicit ``privacy_level``
in the same map always wins.

State: a watermark file records, per chat, the last-bundled message
timestamp. A tick only re-dispatches a chat when it carries a message
newer than the watermark (a fresh reply re-bundles the whole chat so
the four-artefact output stays complete).
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Optional

from .reader import WhatsAppConversation, read_chats
from .renderer import build_metadata, render_transcript

logger = logging.getLogger(__name__)


# --- v1018-D020: every pwg-convo dispatch is bounded ---------------------
#
# `subprocess.run` without a timeout waits forever. One document that never
# returns therefore wedges this tick permanently -- and because the tick
# holds the shared single-flight ingest lock (deliberately never reclaimed
# on age, so the hours-long wiki summary backfill is not evicted), a single
# wedged dispatch stops EVERY conversation feed: email, WhatsApp, iMessage
# and spoken. `launchctl list` reports the label healthy throughout.
#
# Observed on the shipped v1.0.18 box, 2026-08-09: one pwg-convo alive
# 6h47m, the shared lock held 9h19m by the email tick, 36 iMessage and 38
# spoken ticks yielded to it. Nothing anywhere recorded a reason.
#
# The ceiling is per-dispatch, not per-tick, so a slow-but-progressing
# backlog still drains; only an individual pathological document is
# abandoned.
_DISPATCH_TIMEOUT_DEFAULT_SECS = 900

# 124, the timeout(1) convention. Deliberately distinct from any code
# pwg-convo itself returns, so "this document is slow" is never confused
# with "this document is broken" by whoever reads the log next. NOT 75:
# `pwg-convo process` exits 75 (EX_TEMPFAIL) when its model or gateway
# cannot be REACHED, and a catch-up caller reads 75 as an outage (no poison
# attempt) but 124 as a possibly item-specific hang (counted, unless a
# health probe finds the sink down).
DISPATCH_TIMEOUT_RC = 124


def _dispatch_timeout_secs():
    """Per-dispatch wall-clock ceiling in seconds, or None for unbounded.

    ``OSTLER_DISPATCH_TIMEOUT_SECS=0`` restores the old unbounded
    behaviour for debugging. A malformed value falls back to the default
    rather than raising: a typo in an env var must not be the thing that
    stops ingest.
    """
    raw = os.environ.get("OSTLER_DISPATCH_TIMEOUT_SECS")
    if raw is None or not raw.strip():
        return float(_DISPATCH_TIMEOUT_DEFAULT_SECS)
    try:
        secs = float(raw)
    except ValueError:
        return float(_DISPATCH_TIMEOUT_DEFAULT_SECS)
    return None if secs <= 0 else secs


# --- v1018-D032: keep the TAIL of a captured stream, never the head ------
#
# The original form took the FIRST 500 chars of stderr. For a process that
# HUNG, the first 500 characters are the least informative 500 characters
# available -- they record the run starting normally. The last thing it did
# before wedging, the only line that localises the hang, is at the other
# end, and was discarded on every single dispatch failure.
#
# This cost a real diagnosis. A document that hung 13 hours on the shipped
# box surfaced exactly 500 characters, cut mid-word, every one of them from
# the first ten seconds of a thirteen-hour run. It read like an ending. It
# was a truncation, and a conclusion was drawn from it.
#
# The marker is not decoration: a clipped window that does not say it was
# clipped invites the next reader to repeat that exact mistake.
_STDERR_EXCERPT_DEFAULT_CHARS = 2000


def _stderr_excerpt(raw):
    """Tail of a captured stream, with an explicit marker when clipped."""
    if raw is None:
        return "<no stderr captured>"
    text = raw if isinstance(raw, str) else raw.decode("utf-8", "replace")
    text = text.strip()
    if not text:
        return "<stderr empty>"
    raw_limit = os.environ.get("OSTLER_DISPATCH_STDERR_CHARS")
    try:
        limit = int(raw_limit) if raw_limit and raw_limit.strip() else _STDERR_EXCERPT_DEFAULT_CHARS
    except ValueError:
        limit = _STDERR_EXCERPT_DEFAULT_CHARS
    if limit <= 0 or len(text) <= limit:
        return text
    dropped = len(text) - limit
    return f"<...{dropped} earlier chars dropped, showing last {limit}...>\n{text[-limit:]}"
# ------------------------------------------------------------------------
# ------------------------------------------------------------------------


# Engine-zone state under ~/.ostler/ (two-zone architecture). The
# watermark records the last-bundled message timestamp per chat id.
def _default_state_dir() -> Path:
    override = os.getenv("OSTLER_STATE_DIR") or os.getenv("STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".ostler" / "workspace"


def _state_path() -> Path:
    return _default_state_dir() / "whatsapp_source_state.json"


def _load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"chats": {}}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _load_contacts_map(path: Optional[Path]) -> dict[str, str]:
    """Load a JID -> display-name map from a contacts.yaml.

    Reuses the email feed's contacts.yaml shape under a ``whatsapp`` key
    so one operator file can drive every feed::

        whatsapp:
          contacts:
            "447700900123@s.whatsapp.net":
              name: Alex Synthetic
              contact_label: Partner          # -> L3 via CM048 ladder
              privacy_level: L3               # explicit override (wins)
          groups:
            "group:42":
              group_label: Family             # -> L3 via CM048 ladder

    Keys are lower-cased. Missing file / PyYAML -> empty map (JIDs render
    as their phone-number local part, no L3 overrides).
    """
    return _load_whatsapp_section(path, "contacts", "name")


def _load_label_map(
    path: Optional[Path], section: str, label_key: str
) -> dict[str, str]:
    """Load a JID/chat -> label-or-privacy map from the contacts.yaml."""
    return _load_whatsapp_section(path, section, label_key)


def _load_whatsapp_section(
    path: Optional[Path], section: str, value_key: str
) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    try:
        import yaml
    except ImportError:
        logger.warning("PyYAML not installed; WhatsApp %s map ignored", section)
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        logger.warning("Could not parse contacts file %s: %s", path, exc)
        return {}
    wa = data.get("whatsapp") or {}
    mapping = wa.get(section) or {}
    out: dict[str, str] = {}
    if isinstance(mapping, dict):
        for key, entry in mapping.items():
            if isinstance(entry, dict) and entry.get(value_key):
                out[str(key).strip().lower()] = str(entry[value_key]).strip()
    return out


def _name_resolver(contacts: dict[str, str]) -> Callable[[str], Optional[str]]:
    def resolve(jid: Optional[str]) -> Optional[str]:
        return contacts.get((jid or "").strip().lower())

    return resolve


def _label_lookup(label_map: dict[str, str], key: Optional[str]) -> Optional[str]:
    if not key:
        return None
    return label_map.get(key.strip().lower())


def _dispatch_to_cm048(
    transcript_md: str,
    metadata: dict,
    *,
    pwg_convo_cmd: list[str],
    dry_run: bool,
) -> int:
    """Write transcript + metadata to temp files and invoke
    ``pwg-convo process``. Returns the subprocess return code (0 ok).

    Temp files live in the engine-zone tmp and are cleaned up after;
    CM048 copies the raw transcript into its own state dir at step 00.
    """
    with tempfile.TemporaryDirectory(prefix="hr015_whatsapp_") as tmp:
        tdir = Path(tmp)
        tpath = tdir / "transcript.md"
        mpath = tdir / "metadata.json"
        tpath.write_text(transcript_md, encoding="utf-8")
        mpath.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        cmd = list(pwg_convo_cmd) + ["process", str(tpath), str(mpath)]
        if dry_run:
            cmd.append("--dry-run")
        logger.info(
            "Dispatching %s to CM048 (%s)",
            metadata["conversation_id"],
            " ".join(pwg_convo_cmd),
        )
        started = time.monotonic()
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=_dispatch_timeout_secs(),
            )
        except subprocess.TimeoutExpired as exc:
            # v1018-D020. subprocess.run has already killed the child by
            # the time this is raised, so the shared ingest lock is
            # released when this tick ends rather than being held until
            # the machine reboots. Abandon this one document and let the
            # caller move on -- the watermark is left untouched, so the
            # next tick retries it.
            logger.error(
                "pwg-convo TIMED OUT for %s after %ss; abandoning this "
                "document and continuing. Raise or disable the ceiling "
                "with OSTLER_DISPATCH_TIMEOUT_SECS. Last output before the "
                "kill: %s",
                metadata["conversation_id"],
                exc.timeout,
                # v1018-D032. TimeoutExpired carries what was captured
                # before the kill, and for a wedged document that tail is
                # the ONLY record of what it was doing. The first cut of
                # the D020 ceiling logged the timeout and dropped this --
                # bounding the hang while discarding its diagnosis.
                _stderr_excerpt(exc.stderr),
            )
            return DISPATCH_TIMEOUT_RC
        elapsed = time.monotonic() - started
        if proc.returncode != 0:
            logger.error(
                "pwg-convo failed for %s after %.1fs (rc=%d): %s",
                metadata["conversation_id"],
                elapsed,
                proc.returncode,
                _stderr_excerpt(proc.stderr),
            )
        else:
            # v1018-D021. The ONLY per-document timing that survives a
            # successful dispatch. capture_output=True discards pwg-convo's
            # own instrumentation on rc=0, so without this line the feed is
            # unmeasurable except by diffing "Dispatching" timestamps, which
            # attributes queueing and lock waits to the document. Two windows
            # 13h apart both measured ~100s/document that way; where the time
            # actually goes could not be established, because the evidence was
            # being thrown away on every success.
            logger.info(
                "pwg-convo completed %s in %.1fs",
                metadata["conversation_id"],
                elapsed,
            )
        return proc.returncode


# --- Reply-debt snapshot (the WhatsApp leg of "waiting on a reply") ------
#
# Same design as the iMessage feed's snapshot (imessage_source.pipeline,
# CM051 #30): this tick already reads ChatStorage.sqlite under the signed
# assistant's grant, so it writes the one thing reply debt needs, the LAST
# text message of each recent in-tier chat with its direction, into the
# engine room. The Hub's /api/v1/reply-debt (CM048 reply_debt_sources) reads
# it there and never opens a protected store itself.
#
# What is copied out, and what is NOT:
#   * per chat: an opaque chat id, group or not, the DM partner's JID, the
#     last message's author JID, text (capped), time and direction, and
#     whether the owner wrote anything in the recent tail (scam evidence);
#   * the operator's own labels and explicit privacy level for the chat, so
#     the CM048 WhatsApp privacy ladder applies (family / partner -> L3);
#   * NEVER a push name or a group subject: a name comes from the owner's
#     Contacts card on the Hub side, or nowhere.
# The file is 0600 in a 0700 directory, rewritten whole on every tick.
REPLY_DEBT_SNAPSHOT_SCHEMA = 1
REPLY_DEBT_LOOKBACK_DAYS = 30
_REPLY_DEBT_TAIL = 20
_SNAPSHOT_TEXT_LIMIT = 500
_PRODUCER = "whatsapp_source (whatsapp-bundle tick)"


def reply_debt_snapshot_path() -> Path:
    """Must agree with CM048 ``reply_debt_sources.snapshot_path("whatsapp")``."""
    explicit = (os.environ.get("OSTLER_REPLY_DEBT_WHATSAPP_SNAPSHOT") or "").strip()
    if explicit:
        return Path(explicit).expanduser()
    root = (os.environ.get("OSTLER_DIR") or "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".ostler"
    return base / "state" / "reply_debt" / "whatsapp_threads.json"


def _write_snapshot_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=".whatsapp_threads.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def build_reply_debt_snapshot(
    *,
    db_path: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    lookback_days: int = REPLY_DEBT_LOOKBACK_DAYS,
    now_utc=None,
) -> dict:
    """Read the recent tail of every in-tier chat and return the snapshot.

    Raises PermissionError / FileNotFoundError exactly as the reader does, so
    the caller records WHY there is no data rather than an empty list.
    """
    from datetime import datetime, timezone

    contact_labels = _load_label_map(contacts_path, "contacts", "contact_label")
    contact_privacy = _load_label_map(contacts_path, "contacts", "privacy_level")
    group_labels = _load_label_map(contacts_path, "groups", "group_label")
    group_privacy = _load_label_map(contacts_path, "groups", "privacy_level")

    threads = []
    for conv in read_chats(
        db_path=db_path,
        since_days=lookback_days,
        now_utc=now_utc,
        max_messages_per_chat=_REPLY_DEBT_TAIL,
    ):
        last = conv.utterances[-1] if conv.utterances else None
        if last is None or last.timestamp is None:
            continue
        if conv.is_group:
            key = f"group:{conv.chat_id}"
            labels = {"group_label": _label_lookup(group_labels, key),
                      "privacy_level": _label_lookup(group_privacy, key)}
        else:
            jid = conv.chat.contact_jid
            labels = {"contact_label": _label_lookup(contact_labels, jid),
                      "privacy_level": _label_lookup(contact_privacy, jid)}
        row = {
            "chat_id": str(conv.chat_id),
            "is_group": bool(conv.is_group),
            "counterpart_jid": None if conv.is_group else conv.chat.contact_jid,
            "owner_wrote": any(u.is_from_me for u in conv.utterances),
            "last": {
                "text": (last.text or "")[:_SNAPSHOT_TEXT_LIMIT],
                "is_from_me": bool(last.is_from_me),
                "author_jid": None if last.is_from_me else last.author_jid,
                "timestamp": last.timestamp.isoformat(),
            },
        }
        row.update({k: v for k, v in labels.items() if v})
        threads.append(row)
    return {
        "schema": REPLY_DEBT_SNAPSHOT_SCHEMA,
        "status": "ok",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "producer": _PRODUCER,
        "lookback_days": lookback_days,
        "threads": threads,
    }


def write_reply_debt_snapshot(
    *,
    db_path: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    out_path: Optional[Path] = None,
    now_utc=None,
) -> str:
    """Write the reply-debt snapshot; return its status.

    A store this process cannot read is RECORDED as ``status: "unreadable"``,
    never written as an empty-but-ok list, so the Hub says "couldn't check"
    rather than "nothing owed". No WhatsApp Desktop store at all is a true
    zero (``absent``). Never raises: the snapshot must not stop ingest.
    """
    from datetime import datetime, timezone

    out = out_path or reply_debt_snapshot_path()
    try:
        payload = build_reply_debt_snapshot(
            db_path=db_path, contacts_path=contacts_path, now_utc=now_utc
        )
    except PermissionError as exc:
        payload = {"status": "unreadable", "reason": str(exc)[:200]}
    except FileNotFoundError:
        payload = {"status": "absent", "threads": []}
    except Exception as exc:  # noqa: BLE001 -- recorded, never swallowed silently
        payload = {"status": "error", "reason": f"{type(exc).__name__}: {str(exc)[:200]}"}
    if payload.get("status") != "ok":
        payload.update(
            schema=REPLY_DEBT_SNAPSHOT_SCHEMA,
            generated_at=datetime.now(timezone.utc).isoformat(),
            producer=_PRODUCER,
        )
    try:
        _write_snapshot_atomic(out, payload)
    except OSError as exc:
        logger.error("reply-debt snapshot could not be written to %s: %s", out, exc)
        return "write_failed"
    if payload["status"] == "ok":
        logger.info("reply-debt snapshot: %d chat(s) -> %s",
                    len(payload.get("threads") or []), out)
    else:
        logger.warning("reply-debt snapshot: status=%s -> %s", payload["status"], out)
    return payload["status"]
# ------------------------------------------------------------------------


def _latest_ts_iso(conv: WhatsAppConversation) -> str:
    ended = conv.ended_at
    return ended.isoformat().replace("+00:00", "Z") if ended else ""


# A chat with no recorded window is re-read once by a tick whose window is at
# least this wide; the 2-day daytime clamp is far below it.
LEGACY_REBACKFILL_MIN_DAYS = 30


def _rank(days: int) -> float:
    """since_days <= 0 means "no limit", i.e. the widest window of all."""
    return float("inf") if days <= 0 else float(days)


def process_whatsapp(
    *,
    db_path: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    user_display_name: str = "You",
    since_days: int = 365,
    max_messages_per_chat: Optional[int] = 2000,
    pwg_convo_cmd: Optional[list[str]] = None,
    state_path: Optional[Path] = None,
    now_utc=None,
    dry_run: bool = False,
    snapshot_path: Optional[Path] = None,
) -> dict:
    """Read WhatsApp chats (with bodies) and dispatch new/updated chats.

    Returns a summary dict: chats scanned, dispatched, skipped (no new
    message since last bundle), failed.
    """
    pwg_convo_cmd = pwg_convo_cmd or _resolve_pwg_convo_cmd()
    state_file = state_path or _state_path()
    # Reply-debt snapshot FIRST: one cheap read of each chat's recent tail,
    # before dispatch can spend the tick (same order as the iMessage feed).
    # A caller that moved the state (tests, a second profile) gets the
    # snapshot beside it, never in the real engine room.
    if snapshot_path is None and state_path is not None:
        snapshot_path = Path(state_path).parent / "reply_debt_whatsapp_threads.json"
    if not dry_run:
        write_reply_debt_snapshot(
            db_path=db_path, contacts_path=contacts_path,
            out_path=snapshot_path, now_utc=now_utc,
        )
    state = _load_state(state_file)
    chat_state: dict[str, str] = state.setdefault("chats", {})
    # The read window (days) each chat was last dispatched with. The newest-
    # message watermark alone cannot tell "bundled the whole year" from
    # "bundled the daytime 2-day clamp": both leave the watermark at the
    # newest message, so the busiest chats kept 2 days for ever.
    chat_windows: dict[str, int] = state.setdefault("windows", {})

    contacts = _load_contacts_map(contacts_path)
    contact_labels = _load_label_map(contacts_path, "contacts", "contact_label")
    contact_privacy = _load_label_map(contacts_path, "contacts", "privacy_level")
    group_labels = _load_label_map(contacts_path, "groups", "group_label")
    group_privacy = _load_label_map(contacts_path, "groups", "privacy_level")
    name_for_jid = _name_resolver(contacts)

    conversations = read_chats(
        db_path=db_path,
        since_days=since_days,
        now_utc=now_utc,
        max_messages_per_chat=max_messages_per_chat,
    )

    scanned = dispatched = skipped = failed = 0
    for conv in conversations:
        scanned += 1
        latest = _latest_ts_iso(conv)
        last_bundled = chat_state.get(conv.chat_id)
        # Re-dispatch only when this chat carries a message newer than
        # the last bundled one (a fresh reply, or a brand-new chat).
        if last_bundled and latest and latest <= last_bundled:
            recorded = chat_windows.get(conv.chat_id)
            if recorded is None:
                # Written before windows were recorded: unknown. Re-read once
                # on a real (non-clamp) window, never on a daytime clamp tick.
                widened = _rank(since_days) >= LEGACY_REBACKFILL_MIN_DAYS
            else:
                widened = _rank(since_days) > _rank(recorded)
            if not widened:
                skipped += 1
                continue
            logger.info(
                "re-dispatching %s: read window widened %s -> %s days",
                conv.chat_id, recorded if recorded is not None else "unknown",
                since_days,
            )

        # Resolve operator labels + explicit privacy, keyed on the chat's
        # identity (DM partner JID for T1, "group:<id>" for groups).
        if conv.is_group:
            group_key = f"group:{conv.chat_id}"
            group_label = _label_lookup(group_labels, group_key)
            explicit_privacy = _label_lookup(group_privacy, group_key)
            contact_label = None
        else:
            contact_label = _label_lookup(contact_labels, conv.chat.contact_jid)
            explicit_privacy = _label_lookup(contact_privacy, conv.chat.contact_jid)
            group_label = None

        transcript_md = render_transcript(
            conv,
            name_for_jid=name_for_jid,
            user_display_name=user_display_name,
        )
        metadata = build_metadata(
            conv,
            name_for_jid=name_for_jid,
            user_display_name=user_display_name,
            privacy_level=explicit_privacy,
            contact_label=contact_label,
            group_label=group_label,
        )
        rc = _dispatch_to_cm048(
            transcript_md,
            metadata,
            pwg_convo_cmd=pwg_convo_cmd,
            dry_run=dry_run,
        )
        if rc == 0:
            dispatched += 1
            if not dry_run and latest:
                chat_state[conv.chat_id] = latest
                chat_windows[conv.chat_id] = since_days
        else:
            failed += 1
            # Leave the watermark untouched so the next tick retries.

    if not dry_run:
        _save_state(state_file, state)

    summary = {
        "chats_scanned": scanned,
        "chats_dispatched": dispatched,
        "chats_skipped": skipped,
        "chats_failed": failed,
    }
    logger.info("whatsapp source tick complete: %s", summary)
    return summary


def _resolve_pwg_convo_cmd() -> list[str]:
    """Resolve how to invoke CM048's CLI.

    Priority:
      1. ``PWG_CONVO_CMD`` env (space-split) -- the installer sets this
         to the absolute venv path on the Hub.
      2. ``pwg-convo`` on PATH (installed console script).
    """
    override = os.getenv("PWG_CONVO_CMD")
    if override:
        return override.split()
    return ["pwg-convo"]


def run(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="hr015-whatsapp-source",
        description="Feed WhatsApp Desktop chats (DMs + active/intimate "
        "groups) into the CM048 four-artefact conversation pipeline.",
    )
    parser.add_argument("--db-path", type=Path, default=None)
    parser.add_argument("--contacts", type=Path, default=None)
    parser.add_argument(
        "--user-name", default=os.getenv("OSTLER_USER_DISPLAY_NAME", "You")
    )
    parser.add_argument("--since-days", type=int, default=365)
    parser.add_argument("--max-messages-per-chat", type=int, default=2000)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        summary = process_whatsapp(
            db_path=args.db_path,
            contacts_path=args.contacts,
            user_display_name=args.user_name,
            since_days=args.since_days,
            max_messages_per_chat=args.max_messages_per_chat,
            state_path=args.state_path,
            dry_run=args.dry_run,
        )
    except FileNotFoundError as exc:
        # WhatsApp Desktop not installed -- not an error, just nothing
        # to do. Mirror the metadata extractor's graceful skip.
        logger.info("%s", exc)
        print(json.dumps({
            "chats_scanned": 0, "chats_dispatched": 0,
            "chats_skipped": 0, "chats_failed": 0, "status": "no_app",
        }, indent=2))
        return 0
    except PermissionError as exc:
        logger.error("%s", exc)
        return 2
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(run())
