"""Drive Apple Mail -> CM048 four-artefact bundle on the Hub Mac.

This is the product-path conversation-memory feed wired by a
LaunchAgent tick (mirrors the email-ingest tick; see
``launchd/com.creativemachines.ostler.email-bundle.plist``). On each
tick it:

  1. Reads Apple Mail's ``.emlx`` tree (FDA granted at install) for
     recently-received messages.
  2. Threads them into conversation threads (reference-graph +
     subject fallback).
  3. Renders the cleaned transcript + builds the CM048 metadata dict
     (``channel="email"`` plus the ``email_thread`` sidecar).
  4. Invokes ``pwg-convo process <transcript> <metadata>`` so CM048
     emits the four artefacts under
     ``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

CM048 owns classification, enrichment, the L3 short-circuit, the
email-domain privacy ladder, and the four-artefact write. This module
only produces transcript + metadata and hands off. It is intentionally
subprocess-coupled (not an import) so the email source and CM048 stay
independently deployable.

Privacy: a per-contact / per-domain privacy map (optional) lets the
operator mark an address or domain ``L3``; that rides through
``metadata['privacy_level']`` and CM048's writer short-circuits the
gist arm. Default is unset, so CM048's email-domain ladder + classifier
inference (L2 baseline) applies.

State: a watermark file records the last-processed message-ids so a
tick only dispatches a thread when it contains a message not seen
before (a new reply re-dispatches the whole thread so the bundle stays
complete).
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

from .reader import read_messages
from .threader import build_metadata, render_transcript, thread_messages

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
# watermark records the set of message-ids already bundled per thread.
def _default_state_dir() -> Path:
    override = os.getenv("OSTLER_STATE_DIR") or os.getenv("STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".ostler" / "workspace"


def _state_path() -> Path:
    return _default_state_dir() / "email_source_state.json"


def _load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"threads": {}}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _load_contacts_map(path: Optional[Path]) -> dict[str, str]:
    """Load an address -> display-name map.

    Reuses the contacts.yaml shape (``contacts: {<addr>: {name: ...}}``).
    Keys are lower-cased so a header's mixed-case address still
    resolves. Missing file or PyYAML -> empty map (addresses render as
    their raw value).
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
            out[str(cid).strip().lower()] = entry["name"]
    return out


def _load_privacy_map(path: Optional[Path]) -> dict[str, str]:
    """Optional address-or-domain -> privacy-level (e.g. L3) map.

    Same contacts.yaml file, optional ``privacy_level`` per contact.
    A key may be a full address (``person@example.test``) or a bare
    domain (``example.test``); both lower-cased. Lets the operator
    mark a lawyer / clinic / family address L3 so its bundles never
    reach Qdrant / Oxigraph, on top of CM048's own domain ladder.
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
            out[str(cid).strip().lower()] = str(entry["privacy_level"]).upper()
    return out


def _name_resolver(contacts: dict[str, str]) -> Callable[[str], str]:
    def resolve(addr: str) -> str:
        return contacts.get((addr or "").strip().lower(), addr)

    return resolve


def _level_for_addresses(
    addresses: list[str], privacy_map: dict[str, str], user_address: str
) -> Optional[str]:
    """Return ``"L3"`` if any non-user participant address (or its
    domain) is mapped L3 in the operator's privacy map.

    Defence in depth: a single L3 participant marks the whole thread
    L3 so a private contact's words never leak via a mixed thread.
    This is the operator-explicit override; CM048 still applies its
    own email-domain ladder on top when this returns ``None``.
    """
    user_address = (user_address or "").strip().lower()
    for addr in addresses:
        a = (addr or "").strip().lower()
        if not a or a == user_address:
            continue
        if privacy_map.get(a) == "L3":
            return "L3"
        domain = a.split("@", 1)[1] if "@" in a else ""
        if domain and privacy_map.get(domain) == "L3":
            return "L3"
    return None


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
    with tempfile.TemporaryDirectory(prefix="hr015_email_") as tmp:
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


def process_email(
    *,
    mail_dir: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    user_display_name: str = "You",
    user_address: str = "",
    since_days: int = 30,
    min_thread_messages: int = 1,
    pwg_convo_cmd: Optional[list[str]] = None,
    state_path: Optional[Path] = None,
    dry_run: bool = False,
) -> dict:
    """Read Apple Mail, thread, and dispatch new/updated threads to CM048.

    Returns a summary dict: threads scanned, threads dispatched,
    threads skipped (no new message since last bundle), failures.
    """
    pwg_convo_cmd = pwg_convo_cmd or _resolve_pwg_convo_cmd()
    state_file = state_path or _state_path()
    state = _load_state(state_file)
    thread_state: dict[str, list[str]] = state.setdefault("threads", {})

    contacts = _load_contacts_map(contacts_path)
    privacy_map = _load_privacy_map(contacts_path)
    name_for_address = _name_resolver(contacts)

    messages = read_messages(mail_dir=mail_dir, since_days=since_days)
    threads = thread_messages(messages, min_thread_messages=min_thread_messages)

    scanned = dispatched = skipped = failed = 0
    for thread in threads:
        scanned += 1
        current_ids = [m.message_id for m in thread.messages]
        seen_ids = set(thread_state.get(thread.thread_id, []))
        # A thread is worth re-dispatching only if it carries a message
        # we have not bundled before (a fresh reply, or a brand-new
        # thread). Re-bundling on a new reply keeps the four-artefact
        # output complete rather than stale.
        if seen_ids and set(current_ids).issubset(seen_ids):
            skipped += 1
            continue

        level = _level_for_addresses(
            thread.participant_addresses, privacy_map, user_address
        )
        transcript = render_transcript(
            thread,
            user_address=user_address,
            name_for_address=name_for_address,
        )
        metadata = build_metadata(
            thread,
            user_display_name=user_display_name,
            user_address=user_address,
            name_for_address=name_for_address,
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
            if not dry_run:
                # Record every message-id now bundled so the next tick
                # only re-dispatches on a genuinely new reply.
                thread_state[thread.thread_id] = sorted(
                    seen_ids.union(current_ids)
                )
        else:
            failed += 1
            # Leave the watermark untouched so the next tick retries.

    if not dry_run:
        _save_state(state_file, state)

    summary = {
        "threads_scanned": scanned,
        "threads_dispatched": dispatched,
        "threads_skipped": skipped,
        "threads_failed": failed,
    }
    logger.info("email source tick complete: %s", summary)
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
        prog="hr015-email-source",
        description="Feed Apple Mail threads into the CM048 four-artefact "
        "conversation pipeline.",
    )
    parser.add_argument("--mail-dir", type=Path, default=None)
    parser.add_argument("--contacts", type=Path, default=None)
    parser.add_argument(
        "--user-name", default=os.getenv("OSTLER_USER_DISPLAY_NAME", "You")
    )
    parser.add_argument(
        "--user-address", default=os.getenv("OSTLER_USER_EMAIL", "")
    )
    parser.add_argument("--since-days", type=int, default=30)
    parser.add_argument("--min-thread-messages", type=int, default=1)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        summary = process_email(
            mail_dir=args.mail_dir,
            contacts_path=args.contacts,
            user_display_name=args.user_name,
            user_address=args.user_address,
            since_days=args.since_days,
            min_thread_messages=args.min_thread_messages,
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
