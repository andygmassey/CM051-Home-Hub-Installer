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

try:  # progress signal is best-effort; never let its absence break a tick
    from . import hydration_progress as _hp
except Exception:  # pragma: no cover - defensive
    _hp = None

logger = logging.getLogger(__name__)

# Which progress channel this feed reports into (see
# hydration_progress.FEED_CHANNEL). One key per feed; the wiki panel groups
# imessage/whatsapp/spoken into "your message history" for display.
_PROGRESS_CHANNEL = "imessage"


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
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            logger.error(
                "pwg-convo failed for %s (rc=%d): %s",
                metadata["conversation_id"],
                proc.returncode,
                proc.stderr.strip()[:500],
            )
        return proc.returncode


def _emit_progress(*, queued: int, done: int) -> None:
    """Best-effort write of this feed's slice of the shared progress signal.

    ``queued`` is the conversation backlog this feed will work through
    (processed-so-far + still-pending); ``done`` is how much of it is
    finished. The wiki settling panel reads the aggregate. A failure here
    must never disturb the tick, so it is fully swallowed.
    """
    if _hp is None:
        return
    try:
        _hp.update_channel(_PROGRESS_CHANNEL, queued=queued, done=done)
    except Exception:  # pragma: no cover - defensive
        pass


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
    max_sessions: int = 0,
    emit_progress: bool = True,
) -> dict:
    """Read chat.db, thread, and dispatch new sessions to CM048.

    Returns a summary dict: threads scanned, sessions dispatched,
    sessions skipped (already processed), failures.

    ``max_sessions`` (0 = unbounded) bounds how many NEW sessions a single
    call dispatches. The install-time light pass sets a small cap so it
    reaches the Pair-QR in seconds; the background LaunchAgent then runs
    unbounded ticks to drain the rest over time. The watermark means a
    capped pass and the later ticks never re-dispatch the same session.

    ``emit_progress`` (default True) writes this feed's slice of the shared
    ~/.ostler/state/hydration_progress.json so the wiki "still settling in"
    panel can show real, climbing per-channel progress with a falling ETA.
    """
    pwg_convo_cmd = pwg_convo_cmd or _resolve_pwg_convo_cmd()
    state_file = state_path or _state_path()
    state = _load_state(state_file)
    watermarks: dict[str, int] = state.setdefault("watermarks", {})

    contacts = _load_contacts_map(contacts_path)
    privacy_map = _load_privacy_map(contacts_path)
    name_for_handle = _name_resolver(contacts)

    conversations = extract_conversations(db_path=db_path, since_days=since_days)

    # First sweep: thread every conversation so we know the TOTAL new-session
    # backlog up front. That lets the progress signal carry a real
    # ``queued`` from the first emit (so the panel's bar/ETA are honest from
    # the start rather than discovering the denominator as it goes). We hold
    # the threaded sessions so the dispatch sweep below does not re-thread.
    threaded: list[tuple] = []  # (convo, prev_watermark, [pending sessions])
    backlog = 0
    scanned = 0
    for convo in conversations:
        scanned += 1
        messages = extract_messages(convo.chat_id, db_path=db_path)
        if not messages:
            continue
        prev_watermark = watermarks.get(convo.chat_id, -1)
        sessions = thread_messages(
            convo.chat_id,
            messages,
            is_group=convo.is_group,
            display_name=convo.display_name,
            gap=session_gap,
        )
        pending = [s for s in sessions
                   if max(m.rowid for m in s.messages) > prev_watermark]
        backlog += len(pending)
        threaded.append((convo, prev_watermark, sessions, pending))

    # The cumulative backlog already counts work prior ticks finished
    # (their sessions are below the watermark, so not in ``pending``). To
    # show a climbing bar across ticks we anchor ``queued`` at the
    # previously-recorded total and grow it if new messages arrived.
    done_before = int(state.get("progress_done", 0))
    queued_total = max(int(state.get("progress_queued", 0)),
                       done_before + backlog)
    if emit_progress:
        _emit_progress(queued=queued_total, done=done_before)

    dispatched = skipped = failed = 0
    done_running = done_before
    capped = False
    for convo, prev_watermark, sessions, _pending in threaded:
        if capped:
            break
        max_rowid = prev_watermark
        for session in sessions:
            session_max = max(m.rowid for m in session.messages)
            max_rowid = max(max_rowid, session_max)
            # Skip a session whose newest message we've already
            # processed -- the watermark guards re-dispatch.
            if session_max <= prev_watermark:
                skipped += 1
                continue
            if max_sessions and dispatched >= max_sessions:
                # Light-pass cap reached: stop advancing this thread's
                # watermark here so the background ticks pick up the rest.
                capped = True
                break

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
                done_running += 1
                # Heartbeat the progress signal per conversation so the
                # panel's bar never looks frozen during a long drain.
                if emit_progress:
                    _emit_progress(queued=queued_total, done=done_running)
            else:
                failed += 1
                # Don't advance the watermark past a failed session so
                # the next tick retries it.
                max_rowid = min(max_rowid, session_max - 1)

        if not dry_run and max_rowid > prev_watermark:
            watermarks[convo.chat_id] = max_rowid

    if not dry_run:
        # Persist the cumulative progress totals so the next tick continues
        # the climbing bar rather than restarting the denominator.
        state["progress_queued"] = queued_total
        state["progress_done"] = done_running
        _save_state(state_file, state)

    if emit_progress:
        _emit_progress(queued=queued_total, done=done_running)

    summary = {
        "threads_scanned": scanned,
        "sessions_dispatched": dispatched,
        "sessions_skipped": skipped,
        "sessions_failed": failed,
        "backlog_remaining": max(0, queued_total - done_running),
    }
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
    # Light-pass cap for the install-time first drain: bound how many new
    # sessions one invocation dispatches so the installer reaches Pair-QR in
    # seconds. 0 (the LaunchAgent default) is unbounded.
    parser.add_argument("--max-sessions", type=int, default=0)
    parser.add_argument("--no-progress", action="store_true",
                        help="suppress the hydration progress signal write")
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
            max_sessions=args.max_sessions,
            emit_progress=not args.no_progress,
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
