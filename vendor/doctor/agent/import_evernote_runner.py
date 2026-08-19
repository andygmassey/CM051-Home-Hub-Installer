"""Supervisor wrapper for the Evernote import (CM024 Block 3.3).

Doctor's ``import_evernote.start_import`` forks this script with
``start_new_session=True`` so the import survives a Doctor restart or
a closed browser tab. The wrapper's job is to:

1. Run ``ostler-knowledge convert --source evernote <enex> --output <staging>``
2. Wait for it to finish, capturing the exit code
3. Atomically write the terminal state file
4. Remove the lockfile

Stdout/stderr of the wrapped command are inherited from the parent
process, which Doctor has already wired to
``~/.ostler/logs/import-evernote-<job_id>.log``. The wrapper never
prints to that log itself -- its only outputs are the state file and
the lockfile removal.

The wrapper is deliberately stdlib-only so it can run inside a
fresh-install Doctor venv before any extra deps land.

Invocation contract (Doctor passes these via argv):

    python import_evernote_runner.py \\
        --state /path/to/state.json \\
        --lock  /path/to/import-evernote.lock \\
        --job-id 20260513T143052Z-a1b2c3d4 \\
        --log-path /path/to/log.log \\
        --enex-path /path/to/source.enex \\
        --started-at 2026-05-13T14:30:52.123456+00:00 \\
        -- \\
        /usr/local/bin/ostler-knowledge convert --source evernote ... --output ...

The ``--`` sentinel separates the wrapper's own flags from the command
to execute. Everything after ``--`` is passed straight to ``subprocess.run``.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

# Best-effort settling-progress import. The runner is stdlib-only by design
# so it can boot inside a fresh Doctor venv before extra deps land -- the
# helper import is guarded so an absent module never blocks the runner from
# finishing the import (the settling panel then falls back to calendar mode,
# which is the correct honest degradation).
try:
    _REPO_ROOT = Path(__file__).resolve().parents[2]
    if str(_REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(_REPO_ROOT))
    from ostler_fda.settling_progress import (  # noqa: E402
        report_settling_progress,
    )
except Exception:  # noqa: BLE001 -- see comment above
    report_settling_progress = None  # type: ignore[assignment]

_logger = logging.getLogger(__name__)

# Channel identifier for the "notes" settling shard. Runner is a subprocess
# of start_import (in import_evernote.py); both emit into the same shard.
_SETTLING_CHANNEL = "notes"


def _emit_notes_settling(
    *,
    done: int,
    total: int,
    needs_source: bool = False,
    started_at: str,
) -> None:
    """Emit a `notes` settling shard from the runner subprocess.

    Safe against a missing helper import or a full-disk write -- neither
    can abort the runner (which owns the terminal state file + lockfile
    removal). Silent failure here is degrades-to-calendar-mode, not lost
    data.
    """
    if report_settling_progress is None:
        return
    try:
        report_settling_progress(
            channel=_SETTLING_CHANNEL,
            done=done,
            total=total,
            needs_source=needs_source,
            started_at=started_at,
        )
    except Exception:  # noqa: BLE001 -- see docstring
        # Runner's own log stream is inherited by the parent; write a
        # single warning line so a real problem is at least visible.
        sys.stderr.write("runner: settling-progress emit failed\n")


# Sentinel that separates sequential phases in the command after ``--``.
# Doctor passes ``convert ... --and-then embed ...`` so the supervisor
# runs convert, then embed ONLY if convert succeeded. A command with no
# sentinel is a single phase, preserving the original one-command contract.
PHASE_SENTINEL = "--and-then"


def _split_phases(tokens: List[str]) -> List[List[str]]:
    """Split a flat token list into sequential command phases on the
    ``--and-then`` sentinel. Empty phases (a leading/trailing/double
    sentinel) are dropped so the runner never tries to exec ``[]``."""
    phases: List[List[str]] = []
    current: List[str] = []
    for tok in tokens:
        if tok == PHASE_SENTINEL:
            if current:
                phases.append(current)
                current = []
            continue
        current.append(tok)
    if current:
        phases.append(current)
    return phases


def _parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evernote import supervisor (Doctor-internal).",
    )
    parser.add_argument("--state", required=True, help="terminal state file path")
    parser.add_argument("--lock", required=True, help="lockfile path")
    parser.add_argument("--job-id", required=True, dest="job_id")
    parser.add_argument("--log-path", required=True, dest="log_path")
    parser.add_argument("--enex-path", required=True, dest="enex_path")
    parser.add_argument("--started-at", required=True, dest="started_at")
    # Optional: count of `<note>` tags in the ENEX, measured by start_import
    # before fork. Feeds the settling-progress `total` denominator; 0 means
    # "count unknown" and results in a needs_source=False, total=0 shard
    # (reader classifies as ready). Optional so old callers still work.
    parser.add_argument(
        "--note-count",
        type=int,
        default=0,
        dest="note_count",
        help="ENEX <note>-tag count for settling-progress total (optional).",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="The command(s) to execute; precede with -- to disambiguate. "
             "Multiple phases may be chained with the --and-then sentinel.",
    )
    args = parser.parse_args(argv)
    # argparse REMAINDER preserves the leading ``--`` token; drop it.
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("no command supplied after --")
    args.phases = _split_phases(args.command)
    if not args.phases:
        parser.error("no command supplied after --")
    return args


def _atomic_write_json(path: Path, payload: Dict[str, Any]) -> None:
    """Write JSON atomically: write to .tmp, fsync, rename.

    Doctor reads the state file concurrently with the runner writing
    it. ``rename`` on the same filesystem is atomic on POSIX so a
    reader sees either the old or the new file, never a half-written
    one.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    data = json.dumps(payload, indent=2).encode("utf-8")
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def main(argv: List[str]) -> int:
    args = _parse_args(argv)

    # Run phases in order; stop at the first non-zero exit so a failed
    # convert never runs embed against a half-written staging tree. The
    # state file records which phase was last attempted so Doctor can
    # tell "convert failed" from "embed failed".
    exit_code = 0
    phase_index = 0
    for phase_index, phase_cmd in enumerate(args.phases):
        try:
            result = subprocess.run(phase_cmd, check=False)
            exit_code = result.returncode
        except FileNotFoundError as exc:
            # The bundled ``ostler-knowledge`` was not found on PATH.
            # Surface as a non-zero exit and a note in the state file --
            # Doctor's UI shows the failure to the operator who can then
            # check that the installer ran.
            exit_code = 127
            sys.stderr.write(f"runner: command not found: {exc}\n")
        except OSError as exc:
            exit_code = 1
            sys.stderr.write(f"runner: failed to exec command: {exc}\n")
        if exit_code != 0:
            break

    # Graceful-degrade status. The phases are ordered so the *last* one is
    # the non-critical enrichment step -- for a knowledge import that is
    # ``embed`` (indexing into Qdrant for search), preceded by ``convert``
    # (writing the markdown that IS the import). Because the loop above
    # stops at the first non-zero exit, reaching the last phase means every
    # earlier phase exited 0. So a non-zero exit *on the last phase of a
    # multi-phase run* means the data landed and only search indexing
    # failed (Qdrant/Ollama down) -- a degraded success, not a hard
    # failure. The operator's notes ARE imported; search catches up on a
    # re-run. We surface it as ``partial`` so the UI shows amber + a
    # "search pending" note rather than a red "failed". A single-phase run
    # (no --and-then) keeps the original succeeded/failed contract.
    phases_total = len(args.phases)
    is_last_phase = phase_index == phases_total - 1
    if exit_code == 0:
        status = "succeeded"
    elif phases_total > 1 and is_last_phase:
        status = "partial"
    else:
        status = "failed"

    completed_at = datetime.now(timezone.utc).isoformat()
    state = {
        "job_id": args.job_id,
        "status": status,
        "exit_code": exit_code,
        "phase_index": phase_index,
        "phases_total": phases_total,
        "started_at": args.started_at,
        "completed_at": completed_at,
        "log_path": args.log_path,
        "enex_path": args.enex_path,
    }
    if status == "partial":
        # Human-facing hint the UI surfaces verbatim.
        state["note"] = (
            "Notes imported. Search indexing did not complete "
            "(the embedding service may be offline); it will catch up "
            "on the next import."
        )

    try:
        _atomic_write_json(Path(args.state), state)
    except OSError as exc:
        sys.stderr.write(f"runner: could not write state file: {exc}\n")
        # Fall through and still try to remove the lockfile so the
        # next start_import isn't blocked by a stale lock.

    # Settling-progress: emit the terminal shard so the wiki "notes" panel
    # transitions off waiting/partway once this import completes. We treat
    # `succeeded` AND `partial` as "notes landed" -- partial means only
    # the embed step failed (Qdrant/Ollama down); the markdown IS in the
    # staging tree, which is what the settling panel actually cares about.
    # A hard `failed` state does NOT emit -- the panel keeps its last-known
    # `done` and the reader's stale-updated_at handling (via the A9 gate)
    # catches truly-abandoned imports.
    if status in ("succeeded", "partial"):
        # A zero note_count means the caller could not measure a
        # denominator (mangled ENEX, or older caller pre-dating the
        # --note-count flag). Emit total=0/done=0 which the reader
        # classifies as ready (needs_source=False), NOT as an invitation
        # to add a source -- the source IS connected, an import ran.
        note_count = max(0, args.note_count)
        _emit_notes_settling(
            done=note_count,
            total=note_count,
            needs_source=False,
            started_at=args.started_at,
        )

    try:
        Path(args.lock).unlink(missing_ok=True)
    except OSError as exc:
        sys.stderr.write(f"runner: could not remove lockfile: {exc}\n")

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
