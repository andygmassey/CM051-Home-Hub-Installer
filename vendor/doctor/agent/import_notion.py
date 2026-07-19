"""Doctor endpoint logic for the Notion import service (CM024 Knowledge).

Sibling of ``import_evernote.py`` -- same shape, same shared runner
(``import_evernote_runner.py``), different knowledge source. Kept as a
parallel module rather than a shared core so each source stays
independently reviewable and the proven Evernote path is untouched; a
later refactor can fold the three sources onto one core. The Doctor web
UI exposes three routes that this module backs:

    POST /api/v1/import/notion                – start a job
    GET  /api/v1/import/notion/<job_id>/status – poll job state
    GET  /api/v1/import/notion/<job_id>/tail   – tail the last 100 log lines

All four customer-visible surfaces (3 API routes + the ``/import-notion``
UI page) are feature-flag-gated by ``features.notion_import`` in
``~/.ostler/config/features.yaml``. When the flag is off they 404. The
installer always deploys ``ostler-knowledge``; only the customer-visible
surface stays hidden until the operator flips the flag.

A Notion export is a ``.zip`` (or a pre-unzipped directory) of ``.md``
files, NOT a single ``.enex`` file -- so the only real divergence from
the Evernote module is ``validate_notion_path`` (accepts a ``.zip`` or a
directory). The CM024 ``ostler-knowledge`` ``notion`` adapter handles
both forms; convert + embed run via the same shared runner, and the embed
phase carries the same L3 privacy cap (``--max-compartment-level``).

Concurrency: a single global lockfile at
``~/.ostler/locks/import-notion.lock`` prevents two imports running
at once. PID-based stale detection reclaims a lock whose owning process
exited (Doctor crashed, machine rebooted, etc.). The forked import
subprocess is detached (``start_new_session=True``) so closing the
Doctor page does not kill the import.

Per-job state is split into two on-disk records:

* While running, only ``~/.ostler/locks/import-notion.lock`` exists.
  It carries the job_id, pid, started_at, log_path, enex_path so
  ``read_status`` can synthesise the running state without a state
  file. The lockfile is the running-state record.
* On completion (or runner crash), the runner wrapper writes a
  terminal state file at
  ``~/.ostler/state/import-notion-<job_id>.json`` with status =
  succeeded / failed / partial, exit_code, completed_at -- then removes
  the lockfile. The state file is the terminal-state record.

Reads order: state file (terminal) wins over lockfile (running). The
runner uses fsync + atomic rename so a read cannot observe a half-written
state file.

Auth model: Doctor binds 127.0.0.1 (see ``web_ui.py`` __main__). No
HTTP middleware gates these endpoints -- any process on the customer's
Mac that can already reach ``localhost:8089/doctor`` can reach these
routes. The lockfile is operational concurrency control, not an auth
boundary.

NOTE: the lock/state field is still called ``enex_path`` -- it is the
shared-runner contract (``--enex-path``); for Notion it carries the
export path. Renaming is deferred to the eventual shared-core refactor.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import yaml  # PyYAML, listed in doctor/agent/requirements.txt


# ── Default paths ─────────────────────────────────────────────────────

DEFAULT_OSTLER_DIR = Path.home() / ".ostler"
DEFAULT_FEATURES_FILE = DEFAULT_OSTLER_DIR / "config" / "features.yaml"
DEFAULT_LOCK_DIR = DEFAULT_OSTLER_DIR / "locks"
DEFAULT_LOG_DIR = DEFAULT_OSTLER_DIR / "logs"
DEFAULT_STATE_DIR = DEFAULT_OSTLER_DIR / "state"
DEFAULT_STAGING_DIR = DEFAULT_OSTLER_DIR / "data" / "knowledge-staging"
DEFAULT_METADATA_DB = DEFAULT_OSTLER_DIR / "data" / "knowledge-metadata.db"

LOCK_FILENAME = "import-notion.lock"
LOG_FILENAME_PREFIX = "import-notion-"
STATE_FILENAME_PREFIX = "import-notion-"

DEFAULT_OSTLER_KNOWLEDGE_BIN = "/usr/local/bin/ostler-knowledge"

# The knowledge source this import handles. Selects the CM024
# ``ostler-knowledge`` adapter and the ``<source>_knowledge`` Qdrant
# collection the wiki + MCP read.
DEFAULT_SOURCE = "notion"

# Canonical Ostler Hub embedding model. The install pre-creates the
# knowledge Qdrant collections at 768 dims (nomic-embed-text), so embed
# MUST use the same model or every upsert fails the dimension check and
# the wiki Knowledge section stays silently empty. Overridable for
# operators who standardise on a different 768-dim model.
DEFAULT_EMBED_MODEL = "nomic-embed-text"


def _embed_model() -> str:
    return os.environ.get("OSTLER_KNOWLEDGE_EMBED_MODEL", DEFAULT_EMBED_MODEL)


def _collection_for_source(source: str) -> str:
    """The Qdrant collection the wiki + MCP read for a given source."""
    return f"{source}_knowledge"


# Privacy cap: the highest compartment level (sensitivity) that may be
# embedded into the searchable collection. Default 2 keeps L3
# (compartment_level 3, "private") notes OUT of search. They are still
# converted to markdown in the staging tree -- just never indexed into
# Qdrant. This matters because the wiki Knowledge reader does NOT filter
# by level at render time, so excluding L3 at embed is the only thing
# standing between a private note and the browsable wiki. Overridable via
# env for an operator who deliberately wants their full corpus searchable
# on their single-user box.
DEFAULT_MAX_COMPARTMENT_LEVEL = 2


def _max_compartment_level() -> int:
    raw = os.environ.get("OSTLER_KNOWLEDGE_MAX_COMPARTMENT_LEVEL")
    if raw is None:
        return DEFAULT_MAX_COMPARTMENT_LEVEL
    try:
        return int(raw)
    except (TypeError, ValueError):
        # A garbled override must never widen the cap and leak L3; fall
        # back to the safe default.
        return DEFAULT_MAX_COMPARTMENT_LEVEL

# Job IDs are ``YYYYMMDDTHHMMSSZ-<8 hex>``. The format is deliberately
# narrow so the regex can double as a path-traversal defence on
# ``GET /status/{job_id}`` and ``GET /tail/{job_id}``.
JOB_ID_PATTERN = r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"
_JOB_ID_RE = re.compile(JOB_ID_PATTERN)


# ── Errors ────────────────────────────────────────────────────────────


@dataclass
class NotionImportError(Exception):
    """Carries an HTTP status code so the FastAPI handler can map cleanly.

    Same pattern as ``wiki_correct.ValidationError`` (commit 015736c) –
    the route handler in ``web_ui.py`` catches this once and turns it
    into a ``JSONResponse``. Status codes mirror the contract documented
    in the launch-scope brief:

    * 400 – bad request body / invalid path / invalid job_id
    * 404 – job_id not found
    * 409 – another import is already running (lockfile held)
    * 500 – filesystem error reading state / log
    """

    status: int
    detail: str

    def __str__(self) -> str:
        return self.detail


# ── Feature flag ──────────────────────────────────────────────────────


def _features_file() -> Path:
    """Resolve the features.yaml path. ``OSTLER_FEATURES_FILE`` env var
    wins over the home-dir default so tests can point at a tmp file."""
    raw = os.environ.get("OSTLER_FEATURES_FILE")
    return Path(raw) if raw else DEFAULT_FEATURES_FILE


def is_feature_enabled(*, _path: Optional[Path] = None) -> bool:
    """Return True iff ``features.notion_import: true`` in features.yaml.

    Safe default is OFF: a missing file, malformed YAML, missing key,
    or a non-True value all return False. This is intentional -- v1
    ships flag-off, the customer does not see the surface until the
    operator explicitly flips it.

    Read on every request so flag flips are hot and do not require a
    Hub restart.
    """
    path = _path or _features_file()
    if not path.is_file():
        return False
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return False
    if not isinstance(data, dict):
        return False
    features = data.get("features")
    if not isinstance(features, dict):
        return False
    return features.get("notion_import") is True


# ── Path validation ───────────────────────────────────────────────────


def validate_notion_path(raw_path: Any) -> Path:
    """Resolve and validate a Notion export path supplied by the user.

    Notion's "Export" produces a ``.zip``; the operator may also point at
    a pre-unzipped directory of the export. Both are accepted (the CM024
    ``notion`` adapter handles either). Returns the resolved absolute
    Path. Raises ``NotionImportError(400)`` on any failure -- missing
    field, wrong type, empty string, unresolvable path, path does not
    exist, or a file that is neither a ``.zip`` nor a directory.

    Path validation is light-touch: we resolve symlinks so the operator
    can paste a symlinked path. We do **not** restrict the path to a
    particular root because the operator legitimately exports wherever
    they like (Downloads, Desktop, external drive).
    """
    if not isinstance(raw_path, str):
        raise NotionImportError(400, "notion_path must be a string")

    stripped = raw_path.strip()
    if not stripped:
        raise NotionImportError(400, "notion_path must be non-empty")

    try:
        resolved = Path(stripped).expanduser().resolve()
    except (OSError, RuntimeError) as exc:
        raise NotionImportError(400, f"could not resolve notion_path: {exc}")

    # A directory (pre-unzipped export) is accepted as-is.
    if resolved.is_dir():
        return resolved

    if not resolved.exists():
        raise NotionImportError(400, f"notion export not found: {resolved}")

    # Otherwise it must be a regular ``.zip`` file.
    if resolved.is_file() and resolved.suffix.lower() == ".zip":
        return resolved

    raise NotionImportError(
        400,
        "Notion import expects a .zip export or a directory "
        f"(got '{resolved.suffix or 'no extension'}')",
    )


# ── Lockfile ─────────────────────────────────────────────────────────


def _lock_path(lock_dir: Optional[Path]) -> Path:
    return (Path(lock_dir) if lock_dir else DEFAULT_LOCK_DIR) / LOCK_FILENAME


def _pid_alive(pid: Any) -> bool:
    """Return True iff ``pid`` is a live process this user can signal.

    Uses ``os.kill(pid, 0)`` -- the standard portable liveness probe on
    POSIX. PermissionError means the process exists but is owned by
    someone else; we treat that as alive so we never clobber a process
    we cannot reason about.
    """
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def lockfile_state(*, _lock_dir: Optional[Path] = None) -> Optional[Dict[str, Any]]:
    """Return the current lockfile contents annotated with ``alive``.

    Returns None when no lockfile exists or the file is malformed.
    The ``alive`` key is added by this function -- callers use it to
    distinguish "another import is running" (409) from "stale lock,
    safe to reclaim".
    """
    path = _lock_path(_lock_dir)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    data["alive"] = _pid_alive(data.get("pid"))
    return data


def current_running_job_id(*, _lock_dir: Optional[Path] = None) -> Optional[str]:
    """Return the job_id of the currently-running import, or None.

    Block 3.4's UI calls this on page load to reattach to an
    in-progress job whose POST was issued from a previous browser
    session. Returns None for both "no lock" and "stale lock".
    """
    lock = lockfile_state(_lock_dir=_lock_dir)
    if lock and lock.get("alive"):
        return lock.get("job_id")
    return None


# ── Start import ──────────────────────────────────────────────────────

# Single in-process lock so two FastAPI handlers cannot both pass the
# lockfile check and both fork. The cross-process guard is the on-disk
# lockfile; this lock just closes the microsecond window between the
# disk check and the Popen call.
_start_lock = threading.Lock()


def _runner_path() -> Path:
    """Resolve the supervisor wrapper script alongside this module."""
    return Path(__file__).resolve().parent / "import_evernote_runner.py"


def start_import(
    enex_path: Path,
    *,
    source: str = DEFAULT_SOURCE,
    _now: Optional[datetime] = None,
    _lock_dir: Optional[Path] = None,
    _log_dir: Optional[Path] = None,
    _state_dir: Optional[Path] = None,
    _staging_dir: Optional[Path] = None,
    _metadata_db: Optional[Path] = None,
    _binary: Optional[str] = None,
    _subprocess: Any = None,
    _runner: Optional[Path] = None,
    _python: Optional[str] = None,
    _embed_model_name: Optional[str] = None,
    _max_compartment_level_value: Optional[int] = None,
) -> Dict[str, Any]:
    """Fork ``ostler-knowledge`` via the supervisor wrapper.

    Returns ``{"job_id": "...", "status": "started"}``. Raises
    ``NotionImportError(409)`` if a non-stale lock is held by another
    import; raises ``(500)`` on unexpected filesystem errors. Caller is
    responsible for checking ``is_feature_enabled()`` first -- this
    function trusts that the route handler has done the gate.
    """
    lock_dir = Path(_lock_dir or DEFAULT_LOCK_DIR).expanduser()
    log_dir = Path(_log_dir or DEFAULT_LOG_DIR).expanduser()
    state_dir = Path(_state_dir or DEFAULT_STATE_DIR).expanduser()
    staging_dir = Path(_staging_dir or DEFAULT_STAGING_DIR).expanduser()
    metadata_db = Path(_metadata_db or DEFAULT_METADATA_DB).expanduser()
    embed_model = _embed_model_name or _embed_model()
    max_level = (
        _max_compartment_level_value
        if _max_compartment_level_value is not None
        else _max_compartment_level()
    )

    # Resolve subprocess at call time (not in the default arg) so
    # ``monkeypatch.setattr(ie, "subprocess", rec)`` in tests actually
    # captures the Popen invocation through the FastAPI route.
    sub = _subprocess if _subprocess is not None else subprocess

    runner = _runner or _runner_path()
    binary = _binary or os.environ.get(
        "OSTLER_KNOWLEDGE_BIN", DEFAULT_OSTLER_KNOWLEDGE_BIN,
    )
    python = _python or sys.executable

    with _start_lock:
        existing = lockfile_state(_lock_dir=lock_dir)
        if existing and existing.get("alive"):
            raise NotionImportError(
                409,
                f"another import is already in progress "
                f"(job_id={existing.get('job_id')}, pid={existing.get('pid')})",
            )

        for d in (lock_dir, log_dir, state_dir, staging_dir):
            try:
                d.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                raise NotionImportError(
                    500, f"could not create directory {d}: {exc}",
                )

        now = _now or datetime.now(timezone.utc)
        job_id = now.strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]

        log_path = log_dir / f"{LOG_FILENAME_PREFIX}{job_id}.log"
        state_path = state_dir / f"{STATE_FILENAME_PREFIX}{job_id}.json"
        lock_path = _lock_path(lock_dir)
        started_at = now.isoformat()

        try:
            log_handle = open(log_path, "wb", buffering=0)
        except OSError as exc:
            raise NotionImportError(
                500, f"could not open log file {log_path}: {exc}",
            )

        try:
            try:
                # Phase 1: convert the export to markdown in the staging
                # tree. Phase 2: embed that markdown into the source's
                # Qdrant collection so the wiki + MCP actually have
                # something to read -- this is the step whose absence
                # left Knowledge silently empty. nomic-embed-text/768
                # matches the collection the installer pre-creates; the
                # runner runs embed ONLY if convert exits 0.
                convert_phase = [
                    binary, "convert", "--source", source,
                    str(enex_path), "--output", str(staging_dir),
                ]
                embed_phase = [
                    binary, "embed", str(staging_dir),
                    "--collection", _collection_for_source(source),
                    "--embedding-model", embed_model,
                    # Privacy gate: keep L3 ("private") notes out of the
                    # searchable collection the wiki + MCP read. The
                    # reader does not re-filter by level, so this is the
                    # only barrier.
                    "--max-compartment-level", str(max_level),
                    "--db-path", str(metadata_db),
                ]
                proc = sub.Popen(
                    [
                        python, str(runner),
                        "--state", str(state_path),
                        "--lock", str(lock_path),
                        "--job-id", job_id,
                        "--log-path", str(log_path),
                        "--enex-path", str(enex_path),
                        "--started-at", started_at,
                        "--",
                        *convert_phase,
                        "--and-then",
                        *embed_phase,
                    ],
                    stdout=log_handle,
                    stderr=sub.STDOUT,
                    stdin=sub.DEVNULL,
                    start_new_session=True,
                )
            except (OSError, FileNotFoundError) as exc:
                raise NotionImportError(
                    500, f"could not fork import subprocess: {exc}",
                )
        finally:
            log_handle.close()

        # Write the lockfile *after* fork so we can record the runner
        # PID. The microsecond window between Popen returning and the
        # write below is closed by the in-process ``_start_lock`` above.
        lock = {
            "job_id": job_id,
            "pid": proc.pid,
            "started_at": started_at,
            "log_path": str(log_path),
            "enex_path": str(enex_path),
        }
        lock_path.write_text(json.dumps(lock, indent=2), encoding="utf-8")

    return {"job_id": job_id, "status": "started"}


# ── Read status / tail ───────────────────────────────────────────────


def _safe_job_id(job_id: Any) -> str:
    """Reject job_ids that do not match the format ``start_import`` mints.

    Defence against path-traversal -- ``job_id`` is interpolated into
    state and log file paths, so an attacker who can hit Doctor
    (localhost-only, but still) could try ``../../etc/passwd``
    shenanigans without this.
    """
    if not isinstance(job_id, str) or not _JOB_ID_RE.match(job_id):
        raise NotionImportError(400, "invalid job_id")
    return job_id


def read_status(
    job_id: str,
    *,
    _state_dir: Optional[Path] = None,
    _lock_dir: Optional[Path] = None,
    _now: Optional[datetime] = None,
) -> Dict[str, Any]:
    """Return the current state for ``job_id``.

    Read order: terminal state file > lockfile-derived running state.
    If neither matches, raises 404. If the lockfile carries the
    matching job_id but the PID is dead and no terminal state file
    exists, returns a synthesised ``failed`` state -- the runner
    crashed without writing.
    """
    job_id = _safe_job_id(job_id)
    state_dir = Path(_state_dir or DEFAULT_STATE_DIR).expanduser()
    state_path = state_dir / f"{STATE_FILENAME_PREFIX}{job_id}.json"

    if state_path.is_file():
        try:
            return json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise NotionImportError(
                500, f"could not read state file: {exc}",
            )

    lock = lockfile_state(_lock_dir=_lock_dir)
    if lock and lock.get("job_id") == job_id:
        if lock.get("alive"):
            return {
                "job_id": job_id,
                "status": "running",
                "pid": lock.get("pid"),
                "started_at": lock.get("started_at"),
                "log_path": lock.get("log_path"),
                "enex_path": lock.get("enex_path"),
                "exit_code": None,
                "completed_at": None,
            }
        # Matching job, dead PID, no terminal state -- runner crashed.
        now = _now or datetime.now(timezone.utc)
        return {
            "job_id": job_id,
            "status": "failed",
            "exit_code": None,
            "started_at": lock.get("started_at"),
            "completed_at": now.isoformat(),
            "log_path": lock.get("log_path"),
            "enex_path": lock.get("enex_path"),
            "note": "runner exited without writing final state",
        }

    raise NotionImportError(404, f"unknown job_id: {job_id}")


def read_tail(
    job_id: str,
    *,
    lines: int = 100,
    _state_dir: Optional[Path] = None,
    _lock_dir: Optional[Path] = None,
) -> str:
    """Return the last ``lines`` lines of the job's log as text.

    Empty string if the log file does not exist yet. Raises 404 if the
    job_id is unknown (no state file *and* no lockfile pointing to it).

    Reads the whole file then slices -- import logs are bounded (a
    500-note import produces a few hundred KB) and the seek-from-end
    incantation needed to do this efficiently is fiddly enough that
    the readability win wins. Revisit if we ever ship multi-million-
    note imports.
    """
    job_id = _safe_job_id(job_id)
    state_dir = Path(_state_dir or DEFAULT_STATE_DIR).expanduser()
    log_path: Optional[str] = None

    state_path = state_dir / f"{STATE_FILENAME_PREFIX}{job_id}.json"
    if state_path.is_file():
        try:
            data = json.loads(state_path.read_text(encoding="utf-8"))
            log_path = data.get("log_path")
        except (OSError, json.JSONDecodeError):
            pass

    if not log_path:
        lock = lockfile_state(_lock_dir=_lock_dir)
        if lock and lock.get("job_id") == job_id:
            log_path = lock.get("log_path")

    if not log_path:
        raise NotionImportError(404, f"unknown job_id: {job_id}")

    log = Path(log_path)
    if not log.is_file():
        return ""

    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise NotionImportError(500, f"could not read log: {exc}")

    all_lines = text.splitlines()
    return "\n".join(all_lines[-lines:])
