"""CLI front door for the CM052 AI Conversations ingest engine.

This is the runnable entrypoint declared in ``pyproject.toml`` as
``pwg-ai-convo = "src.cm052.cli:main"``. It wraps the already-built
engine library: it runs the unifier across the external-LLM adapters
(Claude Code session watcher + ChatGPT export), then hands every
unified conversation to ``wire.post()``.

It does NOT reimplement any of the engine's privacy or storage logic.
In particular the L3 short-circuit and the dual-storage episodic write
both live in ``wire.post()``; the CLI just calls it and tallies the
result.

Invocation model
----------------

The CLI is a "run once, then exit" command. It is meant to be called
two ways, both from the same command:

- **install-time backfill**: a one-shot run that processes everything
  newer than the ``--since-days`` clamp (default 365 days).
- **periodic tick**: a LaunchAgent re-invokes the same command on a
  schedule; the per-source watermark means a tick only processes
  conversations that are new or changed since the last run.

There is no daemon. PLAN.md defers the live watcher daemon; a
LaunchAgent re-invoking ``pwg-ai-convo`` covers the recurring case
without one.

Watermark
---------

State lives in a small JSON file (default
``~/.pwg/cm052/cli_state.json``, overridable via ``CM052_STATE_DIR``).
It mirrors the sibling human-feed convention (CM041 meeting_syncer's
``meeting_state.json``): a ``processed`` mapping of
``conversation_id -> last_activity`` plus a ``last_run`` timestamp. A
conversation is reprocessed only when its ``last_activity`` is newer
than the recorded value, so re-running with no new data is a clean
no-op.

Exit codes
----------

- ``0``: success, OR nothing to do (empty-by-design: the customer has
  no Claude Code projects and no ChatGPT export). Empty is not an
  error.
- non-zero: a hard config failure that means the run could not even
  start sensibly (e.g. ``CM052_USER_EMAIL`` unset, which the wire
  requires; or an unwritable state directory).

Per-conversation failures are caught and counted; one bad transcript
never aborts the run.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import wire
from .schemas import Conversation
from .unifier import (
    _chatgpt_export_dir,
    _claude_code_projects_dir,
    unify,
)
from .adapters import chatgpt_export, claude_code_watcher


log = logging.getLogger("cm052.cli")


_DEFAULT_SINCE_DAYS = 365
_STATE_FILENAME = "cli_state.json"


def _state_dir() -> Path:
    raw = os.environ.get("CM052_STATE_DIR") or "~/.pwg/cm052"
    return Path(raw).expanduser()


def _state_path() -> Path:
    return _state_dir() / _STATE_FILENAME


_SOURCE_CHOICES = ("claude_code", "chatgpt", "all")


def _ai_adapters(source: str = "all") -> list[tuple]:
    """The external-LLM adapter set this CLI drives, scoped by ``source``.

    Deliberately narrower than the unifier's full ``_registry()``: the
    hub-channel adapters (zeroclaw_sessions + channel_jsonl) belong to
    the human-conversation pipelines, not to the AI Conversations
    ingest engine. We pass these explicitly to ``unify()`` so the
    dedup/merge/sort behaviour is identical to the default path, just
    scoped to the sources this command owns.

    ``source`` selects which AI adapters run. The Claude Code watcher
    LaunchAgent ticks with ``claude_code`` (frequent, cheap re-scan of
    the live session tree); the one-shot ChatGPT importer runs
    ``chatgpt`` over the drop folder; ``all`` (default, e.g. the
    install-time backfill) runs both.
    """
    pairs: list[tuple] = []
    if source in ("claude_code", "all"):
        pairs.append((claude_code_watcher.read, _claude_code_projects_dir()))
    if source in ("chatgpt", "all"):
        pairs.append((chatgpt_export.read, _chatgpt_export_dir()))
    return pairs


def _load_state(path: Path) -> dict:
    """Load the watermark state, tolerating a missing or corrupt file.

    A corrupt state file is treated as empty rather than fatal: the
    worst case is one redundant reprocess (idempotent at the wire
    layer), which is strictly better than refusing to run.
    """
    if not path.is_file():
        return {"processed": {}, "last_run": None}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        log.warning(
            "State file %s is unreadable (%s); starting from empty "
            "watermark. Conversations may be reprocessed (idempotent).",
            path,
            exc,
        )
        return {"processed": {}, "last_run": None}
    processed = data.get("processed")
    if not isinstance(processed, dict):
        processed = {}
    return {"processed": processed, "last_run": data.get("last_run")}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(state, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    tmp.replace(path)


def _is_new_or_changed(conv: Conversation, processed: dict) -> bool:
    """A conversation is worth processing if we have not seen it, or if
    its ``last_activity`` is newer than the recorded watermark.

    ISO-8601 timestamps compare correctly as strings when they share a
    format, which the adapters guarantee for a given source. If the
    stored value is somehow unparseable we err toward reprocessing.
    """
    prev = processed.get(conv.conversation_id)
    if prev is None:
        return True
    return conv.last_activity > prev


def _since_cutoff(since_days: int) -> datetime | None:
    if since_days <= 0:
        return None
    return datetime.now(timezone.utc) - timedelta(days=since_days)


def _parse_iso(value: str) -> datetime | None:
    """Best-effort ISO-8601 parse. Returns None on anything we cannot
    read, so the caller can decide a sensible default (we keep the
    conversation rather than silently dropping it)."""
    if not value:
        return None
    raw = value.strip()
    # ``datetime.fromisoformat`` on 3.11 handles a trailing ``Z`` only
    # from 3.11+, but be defensive for the common ``...Z`` shape.
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _within_since(conv: Conversation, cutoff: datetime | None) -> bool:
    if cutoff is None:
        return True
    dt = _parse_iso(conv.last_activity)
    if dt is None:
        # Unparseable timestamp: keep it rather than silently drop.
        return True
    return dt >= cutoff


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pwg-ai-convo",
        description=(
            "Ingest AI chat history (Claude Code sessions + ChatGPT "
            "exports) into the Ostler conversation memory. Runs once "
            "and exits; a LaunchAgent re-invokes it on a schedule. "
            "Privacy and dual-storage are handled by the engine: L3 "
            "conversations are written to the local episodic store but "
            "never POSTed for vector indexing."
        ),
    )
    parser.add_argument(
        "--since-days",
        type=int,
        default=_DEFAULT_SINCE_DAYS,
        metavar="N",
        help=(
            "Only consider conversations whose last activity is within "
            "the last N days (default: %(default)s). Use 0 for no clamp "
            "(process all history). Consistent with the other Ostler "
            "feeds' backfill clamp."
        ),
    )
    parser.add_argument(
        "--state-file",
        type=str,
        default=None,
        metavar="PATH",
        help=(
            "Override the watermark state file path (default: "
            "$CM052_STATE_DIR/cli_state.json, i.e. "
            "~/.pwg/cm052/cli_state.json)."
        ),
    )
    parser.add_argument(
        "--reset-watermark",
        action="store_true",
        help=(
            "Ignore and overwrite the existing watermark, reprocessing "
            "every in-window conversation. Idempotent at the wire "
            "layer (episodic overwrite, deterministic ids)."
        ),
    )
    parser.add_argument(
        "--source",
        choices=_SOURCE_CHOICES,
        default="all",
        help=(
            "Which AI-conversation source(s) to ingest (default: "
            "%(default)s). The Claude Code watcher LaunchAgent runs "
            "'claude_code'; the one-shot ChatGPT importer runs "
            "'chatgpt'; 'all' runs both."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help=(
            "Emit a counts-only JSON summary "
            "{discovered, ingested, written, l3_skipped, failed} as the "
            "final stdout line. No conversation content crosses the "
            "boundary, so it is safe for the installer to parse. Logs "
            "go to stderr."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Discover and report what would be processed without "
            "calling the wire or advancing the watermark."
        ),
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )
    return parser


def _discover(since_days: int, source: str = "all") -> list[Conversation]:
    """Run the unifier across the selected AI adapters and return the
    merged, most-recent-first conversation list, clamped to the
    since-window.

    Missing source directories are handled inside the adapters (they
    yield nothing), so an environment with neither Claude Code nor a
    ChatGPT export simply returns an empty list.
    """
    convs = unify(adapters=_ai_adapters(source))
    cutoff = _since_cutoff(since_days)
    return [c for c in convs if _within_since(c, cutoff)]


def _emit_json(counts: dict, *, enabled: bool) -> None:
    """Print the counts-only summary as the final stdout line.

    Counts only -- no conversation id, title, or content crosses the
    boundary, so the installer can parse it with ``--json | tail -n1``
    without any PII leak. A no-op when ``--json`` was not requested.
    """
    if enabled:
        print(json.dumps(counts))


def run(args: argparse.Namespace) -> int:
    """Core orchestration. Returns the process exit code."""
    state_path = (
        Path(args.state_file).expanduser()
        if args.state_file
        else _state_path()
    )

    # Fail-fast config check: the wire requires CM052_USER_EMAIL to
    # render the transcript/episodic user label. Surface it here with
    # the env-var name so an installer or operator sees exactly what to
    # set, rather than failing per-conversation deep in the wire.
    if not os.environ.get("CM052_USER_EMAIL"):
        log.error(
            "CM052_USER_EMAIL is not set. The wire needs it to label "
            "the user side of each transcript. Set it in the "
            "environment or the Ostler .env before running."
        )
        return 2

    state = (
        {"processed": {}, "last_run": None}
        if args.reset_watermark
        else _load_state(state_path)
    )
    processed: dict = state["processed"]

    try:
        conversations = _discover(args.since_days, args.source)
    except Exception as exc:  # pragma: no cover - defensive
        log.error("Discovery failed: %s", exc, exc_info=True)
        return 1

    discovered = len(conversations)
    pending = [c for c in conversations if _is_new_or_changed(c, processed)]

    log.info(
        "Discovered %d conversation(s) in window; %d new/changed since "
        "last run.",
        discovered,
        len(pending),
    )

    if not pending:
        # Clean no-op. Empty-by-design (no sources) and "nothing new"
        # are both exit 0; advance last_run so the timestamp reflects
        # the tick even when nothing changed.
        if not args.dry_run:
            state["last_run"] = datetime.now(timezone.utc).isoformat()
            try:
                _save_state(state_path, state)
            except OSError as exc:
                log.error("Could not write state file %s: %s", state_path, exc)
                return 1
        log.info("Nothing to process. Done.")
        _emit_json(
            {
                "discovered": discovered,
                "ingested": 0,
                "written": 0,
                "l3_skipped": 0,
                "failed": 0,
            },
            enabled=args.json,
        )
        return 0

    posted = 0
    l3_skipped = 0
    errors = 0

    for conv in pending:
        if args.dry_run:
            log.info(
                "[dry-run] would process %s (source=%s, last_activity=%s)",
                conv.conversation_id,
                conv.provenance.source_subtype,
                conv.last_activity,
            )
            continue
        try:
            result = wire.post(conv)
        except Exception as exc:
            # One bad transcript must not abort the run. Log with the
            # conversation id + traceback and leave the watermark
            # unadvanced for this id so a later run retries it.
            errors += 1
            log.warning(
                "Failed to process %s (%s): %s",
                conv.conversation_id,
                conv.provenance.source_subtype,
                exc,
                exc_info=True,
            )
            continue

        if isinstance(result, dict) and result.get("reason") == "privacy_level_l3":
            l3_skipped += 1
        else:
            posted += 1
        # Advance the watermark only on a successful (non-raising)
        # process, whether the gist arm posted or was L3-skipped: both
        # outcomes mean the conversation has been durably handled.
        processed[conv.conversation_id] = conv.last_activity

    if not args.dry_run:
        state["last_run"] = datetime.now(timezone.utc).isoformat()
        try:
            _save_state(state_path, state)
        except OSError as exc:
            log.error("Could not write state file %s: %s", state_path, exc)
            return 1

    log.info(
        "Done. discovered=%d posted=%d l3_skipped=%d errors=%d",
        discovered,
        posted,
        l3_skipped,
        errors,
    )
    _emit_json(
        {
            "discovered": discovered,
            # ``ingested`` = conversations durably handled this run,
            # whether the gist arm POSTed or was L3-short-circuited.
            "ingested": posted + l3_skipped,
            "written": posted,
            "l3_skipped": l3_skipped,
            "failed": errors,
        },
        enabled=args.json,
    )
    # Per-conversation errors are non-fatal: they are tallied and the
    # affected ids stay un-watermarked for retry. The run itself
    # succeeded.
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    parser = _build_arg_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
