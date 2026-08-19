"""Drive iMessage -> CM048 four-artefact bundle on the Hub Mac.

This is the product-path feed wired by a LaunchAgent tick (mirrors the
email-ingest tick; see ``launchd/com.ostler.imessage-bundle.plist``).
On each tick it:

  1. Reads chat.db (FDA granted at install) for recently-active
     threads.
  2. Threads each into conversation sessions (quiet-gap segmentation).
  3. Renders the cleaned transcript + builds the CM048 metadata dict.
  4. Invokes ``pwg-convo process <transcript> <metadata>`` so CM048
     emits the four artefacts under
     ``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

CM048 owns classification, enrichment, the L3 short-circuit, and the
four-artefact write. This module only produces transcript + metadata
and hands off. It is intentionally subprocess-coupled (not an import)
so CM040 and CM048 stay independently deployable.

Privacy: a per-contact privacy map (optional) lets the operator mark
a handle as ``L3``; that rides through ``metadata['privacy_level']``
and CM048's writer short-circuits the gist arm. Default is unset, so
CM048's classifier-driven inference (L2 baseline) applies.

State: a watermark file records the last-processed message ROWID per
chat so a tick only processes sessions containing new messages.
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
from datetime import timedelta
from pathlib import Path
from typing import Callable, Optional

from .reader import extract_conversations, extract_messages
from .threader import (
    DEFAULT_SESSION_GAP,
    build_metadata,
    render_transcript,
    thread_messages,
)

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

# EX_TEMPFAIL. Deliberately distinct from any code pwg-convo itself
# returns, so "this document is slow" is never confused with "this
# document is broken" by whoever reads the log next.
DISPATCH_TIMEOUT_RC = 75


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
# watermark records the highest message ROWID processed per chat.
def _default_state_dir() -> Path:
    override = os.getenv("OSTLER_STATE_DIR") or os.getenv("STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".ostler" / "workspace"


def _state_path() -> Path:
    return _default_state_dir() / "imessage_source_state.json"


def _load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"watermarks": {}}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _load_contacts_map(path: Optional[Path]) -> dict[str, str]:
    """Load a handle-id -> display-name map.

    Reuses the publisher's ``contacts.yaml`` shape
    (``contacts: {<id>: {name: ...}}``) so a single contacts file
    serves both the legacy publisher and this product path. Missing
    file or PyYAML -> empty map (handles render as their raw id).
    """
    if path is None or not path.exists():
        return {}
    try:
        import yaml
    except ImportError:
        logger.warning("PyYAML not installed; contact names unresolved")
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        logger.warning("Could not parse contacts file %s: %s", path, exc)
        return {}
    out: dict[str, str] = {}
    for cid, entry in (data.get("contacts") or {}).items():
        if isinstance(entry, dict) and entry.get("name"):
            out[str(cid)] = entry["name"]
    return out


def _load_privacy_map(path: Optional[Path]) -> dict[str, str]:
    """Optional handle-id -> privacy-level (e.g. L3) map.

    Same contacts.yaml file, optional ``privacy_level`` per contact.
    Lets the operator mark a partner / family handle L3 so its
    bundles never reach Qdrant / Oxigraph.
    """
    if path is None or not path.exists():
        return {}
    try:
        import yaml
    except ImportError:
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError:
        return {}
    out: dict[str, str] = {}
    for cid, entry in (data.get("contacts") or {}).items():
        if isinstance(entry, dict) and entry.get("privacy_level"):
            out[str(cid)] = str(entry["privacy_level"]).upper()
    return out


def _name_resolver(contacts: dict[str, str]) -> Callable[[str], str]:
    def resolve(handle: str) -> str:
        return contacts.get(handle, handle)

    return resolve


def _dispatch_to_cm048(
    transcript: str,
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
    with tempfile.TemporaryDirectory(prefix="cm040_imsg_") as tmp:
        tdir = Path(tmp)
        tpath = tdir / "transcript.md"
        mpath = tdir / "metadata.json"
        tpath.write_text(transcript, encoding="utf-8")
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


def process_imessage(
    *,
    db_path: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    user_display_name: str = "You",
    since_days: int = 30,
    session_gap: timedelta = DEFAULT_SESSION_GAP,
    pwg_convo_cmd: Optional[list[str]] = None,
    state_path: Optional[Path] = None,
    dry_run: bool = False,
) -> dict:
    """Read chat.db, thread, and dispatch new sessions to CM048.

    Returns a summary dict: threads scanned, sessions dispatched,
    sessions skipped (already processed), failures.
    """
    pwg_convo_cmd = pwg_convo_cmd or _resolve_pwg_convo_cmd()
    state_file = state_path or _state_path()
    state = _load_state(state_file)
    watermarks: dict[str, int] = state.setdefault("watermarks", {})

    contacts = _load_contacts_map(contacts_path)
    privacy_map = _load_privacy_map(contacts_path)
    name_for_handle = _name_resolver(contacts)

    conversations = extract_conversations(db_path=db_path, since_days=since_days)

    scanned = dispatched = skipped = failed = 0
    for convo in conversations:
        scanned += 1
        messages = extract_messages(convo.chat_id, db_path=db_path)
        if not messages:
            continue
        prev_watermark = watermarks.get(convo.chat_id, -1)
        max_rowid = prev_watermark
        # Lowest rowid that FAILED to dispatch in this chat, if any. The
        # watermark is capped below it after the loop -- see the comment at
        # the cap for why an inline claw-back is not enough.
        first_failed_rowid = None

        sessions = thread_messages(
            convo.chat_id,
            messages,
            is_group=convo.is_group,
            display_name=convo.display_name,
            gap=session_gap,
        )
        for session in sessions:
            session_max = max(m.rowid for m in session.messages)
            max_rowid = max(max_rowid, session_max)
            # Skip a session whose newest message we've already
            # processed -- the watermark guards re-dispatch.
            if session_max <= prev_watermark:
                skipped += 1
                continue

            # Per-contact L3: if ANY non-user handle in the session is
            # mapped L3, the whole session is L3 (defence in depth --
            # a private contact's words must not leak via a mixed
            # session).
            level = None
            for handle in session.participant_handles:
                if privacy_map.get(handle) == "L3":
                    level = "L3"
                    break

            transcript = render_transcript(
                session, name_for_handle=name_for_handle
            )
            metadata = build_metadata(
                session,
                user_display_name=user_display_name,
                name_for_handle=name_for_handle,
                privacy_level=level,
            )
            rc = _dispatch_to_cm048(
                transcript,
                metadata,
                pwg_convo_cmd=pwg_convo_cmd,
                dry_run=dry_run,
            )
            if rc == 0:
                dispatched += 1
            else:
                failed += 1
                if first_failed_rowid is None or session_max < first_failed_rowid:
                    first_failed_rowid = session_max

        # Cap the watermark BELOW the earliest failure in this chat.
        #
        # 2026-08-08: this used to claw back inline --
        #     max_rowid = min(max_rowid, session_max - 1)
        # -- immediately after a failure. That is defeated by any LATER
        # success in the same chat, because the top of the loop does
        #     max_rowid = max(max_rowid, session_max)
        # unconditionally:
        #
        #     session A rowid 100 FAILS -> max_rowid = 99
        #     session B rowid 200 OK    -> max_rowid = max(99, 200) = 200
        #     watermark advances to 200, past the failure at 100
        #
        # The failed session is then permanently skipped, because the next
        # tick's `session_max <= prev_watermark` check treats it as already
        # processed. Observed on the .208 box-walk: `sessions_failed: 1`, tick
        # reported complete, conversation never in the graph. Silent, and
        # unrecoverable without resetting the watermark by hand.
        #
        # Capping once, after the loop, is order-independent: a failure at any
        # position holds the line for everything after it. Re-dispatching a
        # few already-successful sessions on the next tick is cheap and
        # idempotent; losing a conversation forever is neither.
        max_rowid = cap_watermark(max_rowid, first_failed_rowid)

        if not dry_run and max_rowid > prev_watermark:
            watermarks[convo.chat_id] = max_rowid

    if not dry_run:
        _save_state(state_file, state)

    summary = {
        "threads_scanned": scanned,
        "sessions_dispatched": dispatched,
        "sessions_skipped": skipped,
        "sessions_failed": failed,
    }
    # Do not call a tick with failures "complete". A tick that dropped work
    # and reported completion is what let this go unnoticed for a whole
    # box-walk; Doctor now surfaces the same signal to the customer.
    if failed:
        logger.error(
            "iMessage source tick FINISHED WITH FAILURES (%s session(s) not "
            "processed; watermark held so they retry next tick): %s",
            failed, summary,
        )
    else:
        logger.info("iMessage source tick complete: %s", summary)
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



def cap_watermark(max_rowid: int, first_failed_rowid: "Optional[int]") -> int:
    """Highest rowid safe to record, given the earliest failure in this chat.

    Pure, so the rule can be tested without a chat.db. The rule itself:
    a watermark may never advance past a session that failed to dispatch,
    because the next tick treats anything at or below the watermark as already
    processed and will never retry it.
    """
    if first_failed_rowid is None:
        return max_rowid
    return min(max_rowid, first_failed_rowid - 1)


def run(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cm040-imessage-source",
        description="Feed iMessage threads into the CM048 four-artefact "
        "conversation pipeline.",
    )
    parser.add_argument("--db-path", type=Path, default=None)
    parser.add_argument("--contacts", type=Path, default=None)
    parser.add_argument("--user-name", default=os.getenv("OSTLER_USER_DISPLAY_NAME", "You"))
    parser.add_argument("--since-days", type=int, default=30)
    parser.add_argument("--session-gap-hours", type=float, default=6.0)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        summary = process_imessage(
            db_path=args.db_path,
            contacts_path=args.contacts,
            user_display_name=args.user_name,
            since_days=args.since_days,
            session_gap=timedelta(hours=args.session_gap_hours),
            state_path=args.state_path,
            dry_run=args.dry_run,
        )
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 1
    except PermissionError as exc:
        logger.error("%s", exc)
        return 2
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(run())
