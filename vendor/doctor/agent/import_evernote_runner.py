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
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


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
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="The command to execute; precede with -- to disambiguate.",
    )
    args = parser.parse_args(argv)
    # argparse REMAINDER preserves the leading ``--`` token; drop it.
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
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

    try:
        result = subprocess.run(args.command, check=False)
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

    completed_at = datetime.now(timezone.utc).isoformat()
    state = {
        "job_id": args.job_id,
        "status": "succeeded" if exit_code == 0 else "failed",
        "exit_code": exit_code,
        "started_at": args.started_at,
        "completed_at": completed_at,
        "log_path": args.log_path,
        "enex_path": args.enex_path,
    }

    try:
        _atomic_write_json(Path(args.state), state)
    except OSError as exc:
        sys.stderr.write(f"runner: could not write state file: {exc}\n")
        # Fall through and still try to remove the lockfile so the
        # next start_import isn't blocked by a stale lock.

    try:
        Path(args.lock).unlink(missing_ok=True)
    except OSError as exc:
        sys.stderr.write(f"runner: could not remove lockfile: {exc}\n")

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
