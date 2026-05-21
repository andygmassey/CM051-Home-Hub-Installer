"""Canonical filesystem paths for the Ostler product family.

The two-zone layout splits customer-generated content from
engine-internal state:

    ~/Documents/Ostler/    user-facing artefacts (wiki, transcripts, conversations)
    ~/.ostler/             engine room (databases, configs, logs, caches)

This module exposes the two roots and their key subpaths plus the
first-launch migration that moves a pre-Ostler ``~/.pwg/`` install
into the new layout. Engine-room override resolution
(``OSTLER_*`` env vars > legacy ``PWG_*`` env vars > UserDefaults
> default) lives in ``settings.py`` -- this module is pure path
constants so the migration code can stay independent of the
broader settings stack.

CM048 mirror of the CM042 pattern shipped in PR #17. Engine-room
naming and the ``.migrated-from-pwg-dotdir`` sentinel match the
two-zone brief at /tmp/tnm_brief_two_zone_architecture_2026-05-02.md.
"""
from __future__ import annotations

import logging
import os
import shutil
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

log = logging.getLogger(__name__)


# ── Engine-room: ~/.ostler/ ────────────────────────────────────

def ostler_root() -> Path:
    """Engine-room root: ``~/.ostler/``."""
    return Path.home() / ".ostler"


def processing_dir() -> Path:
    """Per-conversation processing state under the engine room."""
    return ostler_root() / "processing"


def coach_db_path() -> Path:
    """Coach observations SQLite DB. Sidecar WAL + SHM files live
    alongside (``observations.db-wal``, ``observations.db-shm``)
    when the database has open transactions; the migration moves
    all three together after a WAL checkpoint."""
    return ostler_root() / "coach" / "observations.db"


def speaker_feedback_dir() -> Path:
    """Per-speaker feedback JSON under the engine room."""
    return ostler_root() / "speaker_feedback"


def settings_yaml_path() -> Path:
    """Customer settings file under the engine room."""
    return ostler_root() / "settings.yaml"


# ── User-facing: ~/Documents/Ostler/ ───────────────────────────

def user_facing_root() -> Path:
    """User-facing root: ``~/Documents/Ostler/``."""
    return Path.home() / "Documents" / "Ostler"


def conversations_dir() -> Path:
    """Default destination for processed conversation MDs. Customer-
    facing per Brief B's zoning decision: the customer browses
    these alongside Wiki/, Transcripts/, etc. Per-file structure
    is ``YYYY/MM/{id}.md`` under this root, set up at write time
    by ``ingest.py``."""
    return user_facing_root() / "Conversations"


# ── Legacy ~/.pwg/ paths (read-only -- for migration discovery) ──

def legacy_pwg_root() -> Path:
    """Pre-Ostler engine root, retained so the migration knows
    where to look. Do NOT use this for new writes."""
    return Path.home() / ".pwg"


# ── Migration sentinel + lockfile ──────────────────────────────

MIGRATION_SENTINEL_NAME = ".migrated-from-pwg-dotdir"
MIGRATION_LOCKFILE_NAME = ".migration.lock"


def migration_sentinel_path() -> Path:
    return ostler_root() / MIGRATION_SENTINEL_NAME


def migration_lockfile_path() -> Path:
    return ostler_root() / MIGRATION_LOCKFILE_NAME


# ── Migration ──────────────────────────────────────────────────

@dataclass(frozen=True)
class MigrationOutcome:
    """Result of a single migration attempt. ``status`` is one of
    ``already_migrated`` / ``fresh_install`` / ``migrated`` /
    ``locked`` / ``failed``. ``moved_subdirs`` lists the per-subdir
    moves performed (empty for the no-op statuses); ``message``
    carries the failure cause when status is ``failed``."""

    status: str
    moved_subdirs: tuple[str, ...] = ()
    backup_path: Path | None = None
    conversations_moved: int = 0
    message: str = ""


# Mapping of legacy subpath -> new subpath (relative to home), used
# by the migration. Order matters: settings.yaml is moved last so a
# failure mid-migration leaves the old YAML readable for diagnosis
# rather than a half-migrated state with no config.
_ENGINE_ROOM_MAPPING: tuple[tuple[str, str], ...] = (
    (".pwg/processing",       ".ostler/processing"),
    (".pwg/coach",            ".ostler/coach"),
    (".pwg/speaker_feedback", ".ostler/speaker_feedback"),
)


def _take_lock(lockfile: Path) -> bool:
    """Atomic best-effort lock: O_CREAT|O_EXCL succeeds only when
    the file does not already exist. Returns True if we got the
    lock; False if another process has it. The lock file is small
    (PID + ISO timestamp) so a stale lock can be diagnosed."""
    lockfile.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(
            str(lockfile),
            os.O_CREAT | os.O_EXCL | os.O_WRONLY,
            0o600,
        )
    except FileExistsError:
        return False
    try:
        body = f"pid={os.getpid()} at={datetime.now(timezone.utc).isoformat()}\n"
        os.write(fd, body.encode("utf-8"))
    finally:
        os.close(fd)
    return True


def _release_lock(lockfile: Path) -> None:
    try:
        lockfile.unlink()
    except FileNotFoundError:
        pass


def _checkpoint_and_close_sqlite(db_path: Path) -> None:
    """Best-effort WAL checkpoint + close. Squashes the WAL into
    the main DB so the subsequent move only needs to relocate one
    file rather than three (and so the destination is consistent
    even if the operator's filesystem doesn't preserve the
    db-wal / db-shm files atomically). Failures here are non-
    fatal: if the checkpoint can't run (DB locked, corrupt,
    missing) the migration falls through to moving all three
    files together."""
    try:
        conn = sqlite3.connect(str(db_path), timeout=2.0)
    except sqlite3.Error as exc:
        log.warning("WAL checkpoint skipped on %s: %s", db_path, exc)
        return
    try:
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
            conn.commit()
        except sqlite3.Error as exc:
            log.warning("WAL checkpoint failed on %s: %s", db_path, exc)
    finally:
        conn.close()


def _move_sqlite_triple(src_db: Path, dst_db: Path) -> None:
    """Move the SQLite main file plus any -wal / -shm sidecars
    together. The checkpoint above usually drains the WAL, but
    moving any leftover sidecars keeps the destination DB
    consistent regardless of what the engine wrote last."""
    dst_db.parent.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-wal", "-shm"):
        src = src_db.with_name(src_db.name + suffix) if suffix else src_db
        if not src.exists():
            continue
        dst = dst_db.with_name(dst_db.name + suffix) if suffix else dst_db
        shutil.move(str(src), str(dst))


def _move_subdir(legacy: Path, new: Path) -> bool:
    """Move a directory tree from the legacy location to the new
    one. Returns True if the move happened, False if the legacy
    path didn't exist. Destination's parent is created on demand."""
    if not legacy.exists():
        return False
    new.parent.mkdir(parents=True, exist_ok=True)
    if new.exists():
        # Conservative: if the new location already exists (e.g.
        # the customer pre-created it manually), merge by moving
        # only the entries that don't collide. Same shape as the
        # CM042 Gap 1 collision policy.
        for entry in legacy.iterdir():
            target = new / entry.name
            if target.exists():
                continue
            shutil.move(str(entry), str(target))
        # Drop the now-empty (or collision-only) legacy dir.
        try:
            legacy.rmdir()
        except OSError:
            # Non-empty due to collisions; leave it for the
            # operator to inspect.
            pass
        return True
    shutil.move(str(legacy), str(new))
    return True


def _route_conversations(
    legacy_conversations: Path,
    new_conversations_root: Path,
) -> int:
    """Move conversation MDs from the flat legacy layout to the
    new ``YYYY/MM/{id}.md`` structure under the user-facing root.
    Date is taken from each file's mtime; if mtime is unreadable
    (rare), the file lands under ``unknown-date/`` rather than
    being silently skipped or losing its position."""
    if not legacy_conversations.exists():
        return 0
    moved = 0
    for entry in legacy_conversations.iterdir():
        if entry.is_dir():
            # Already nested (e.g. pre-existing YYYY/ tree from a
            # partial earlier attempt). Walk it and lift each
            # leaf .md onto the new YYYY/MM/ shape based on
            # mtime; we own the layout post-migration.
            for nested in entry.rglob("*.md"):
                if _move_one_conversation_md(nested, new_conversations_root):
                    moved += 1
            try:
                shutil.rmtree(entry)
            except OSError:
                pass
            continue
        if entry.suffix != ".md":
            # Non-markdown files (e.g. an accidental .DS_Store)
            # are skipped rather than moved -- they don't belong
            # in a customer-facing tree.
            continue
        if _move_one_conversation_md(entry, new_conversations_root):
            moved += 1
    # Drop the now-empty legacy conversations dir if no
    # collisions left a remnant behind.
    try:
        legacy_conversations.rmdir()
    except OSError:
        pass
    return moved


def _move_one_conversation_md(
    src: Path,
    new_conversations_root: Path,
) -> bool:
    try:
        mtime = datetime.fromtimestamp(src.stat().st_mtime, tz=timezone.utc)
        year = f"{mtime.year:04d}"
        month = f"{mtime.month:02d}"
    except OSError:
        year = "unknown-date"
        month = ""
    if month:
        target_dir = new_conversations_root / year / month
    else:
        target_dir = new_conversations_root / year
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / src.name
    if target.exists():
        # Collision: leave the legacy file in place so the
        # operator can resolve. Idempotency is the priority.
        return False
    shutil.move(str(src), str(target))
    return True


def _rewrite_settings_yaml_paths(yaml_text: str) -> str:
    """Translate any literal ``~/.pwg/<x>`` path values inside the
    settings YAML to their new homes. Conservative: only matches
    the exact ``~/.pwg/`` prefix at the start of a value -- any
    other path the operator has set (e.g. an absolute path on a
    different volume) is left unchanged.

    Conversations get the user-facing destination per Brief B;
    everything else goes to the engine room ``~/.ostler/``."""
    out_lines: list[str] = []
    for line in yaml_text.splitlines(keepends=True):
        out_lines.append(_rewrite_yaml_line(line))
    return "".join(out_lines)


def _rewrite_yaml_line(line: str) -> str:
    # ``key: value`` on a single line; we only touch values that
    # start with ``~/.pwg/`` (with or without leading whitespace).
    stripped = line.lstrip()
    if not stripped.startswith(("processing_state_dir:",
                                "output_conversations_dir:",
                                "coach_db_path:",
                                "settings_path:")):
        return line
    key, _, raw = stripped.partition(":")
    value = raw.strip()
    if not value.startswith("~/.pwg/"):
        return line
    indent = line[: len(line) - len(stripped)]
    rest = value[len("~/.pwg/"):]
    if key == "output_conversations_dir":
        new_value = "~/Documents/Ostler/Conversations"
    elif key == "processing_state_dir":
        new_value = f"~/.ostler/{rest}" if rest else "~/.ostler/processing"
    elif key == "coach_db_path":
        new_value = f"~/.ostler/{rest}" if rest else "~/.ostler/coach/observations.db"
    elif key == "settings_path":
        new_value = f"~/.ostler/{rest}" if rest else "~/.ostler/settings.yaml"
    else:
        return line
    return f"{indent}{key}: {new_value}\n"


def migrate_pwg_dotdir_if_needed(
    *,
    legacy_root: Path | None = None,
    new_root: Path | None = None,
    new_conversations_root: Path | None = None,
) -> MigrationOutcome:
    """Move a pre-Ostler ``~/.pwg/`` install into the two-zone
    layout. Idempotent: a sentinel at the new root short-
    circuits subsequent invocations. Safe to call on every CLI
    invocation.

    Parameters are injected for testability; defaults resolve via
    the constants above."""
    legacy_root = legacy_root if legacy_root is not None else legacy_pwg_root()
    new_root = new_root if new_root is not None else ostler_root()
    new_conversations_root = (
        new_conversations_root
        if new_conversations_root is not None
        else conversations_dir()
    )

    sentinel = new_root / MIGRATION_SENTINEL_NAME
    lockfile = new_root / MIGRATION_LOCKFILE_NAME

    if sentinel.exists():
        return MigrationOutcome(status="already_migrated")

    new_root.mkdir(parents=True, exist_ok=True)

    if not _take_lock(lockfile):
        # Another invocation is already running the migration.
        # Returning rather than blocking keeps short-lived CLI
        # invocations responsive.
        return MigrationOutcome(status="locked")

    try:
        # Fresh install: nothing to migrate, but drop the
        # sentinel so subsequent launches short-circuit and
        # don't keep re-statting the legacy path.
        if not legacy_root.exists():
            _write_sentinel(sentinel)
            return MigrationOutcome(status="fresh_install")

        # Backup BEFORE touching anything. shutil.copytree
        # preserves mtimes (load-bearing for the conversations
        # YYYY/MM routing below). Failure here aborts before
        # any move, so the legacy install stays intact.
        backup_path = legacy_root.with_name(
            f".pwg.backup-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
        )
        try:
            shutil.copytree(legacy_root, backup_path)
        except OSError as exc:
            return MigrationOutcome(
                status="failed",
                message=f"Could not back up {legacy_root} -> {backup_path}: {exc}",
            )

        moved_subdirs: list[str] = []

        # SQLite first: checkpoint + atomic-triple move ahead of
        # the broader coach/ subtree move so we never end up
        # halfway through a multi-file SQLite move.
        legacy_db = legacy_root / "coach" / "observations.db"
        if legacy_db.exists():
            _checkpoint_and_close_sqlite(legacy_db)
            new_db = new_root / "coach" / "observations.db"
            try:
                _move_sqlite_triple(legacy_db, new_db)
                moved_subdirs.append("coach/observations.db")
            except OSError as exc:
                return MigrationOutcome(
                    status="failed",
                    backup_path=backup_path,
                    message=f"Could not move SQLite triple: {exc}",
                )

        # Engine-room subtree moves. The coach/ entry is mostly
        # empty by this point (its DB triple already moved
        # above); _move_subdir handles the now-mostly-empty dir.
        for legacy_sub, new_sub in _ENGINE_ROOM_MAPPING:
            legacy_path = Path.home() / legacy_sub
            new_path = Path.home() / new_sub
            try:
                if _move_subdir(legacy_path, new_path):
                    moved_subdirs.append(legacy_sub)
            except OSError as exc:
                return MigrationOutcome(
                    status="failed",
                    backup_path=backup_path,
                    message=f"Could not move {legacy_path}: {exc}",
                )

        # Conversation MDs to the user-facing zone.
        try:
            conversations_moved = _route_conversations(
                legacy_root / "conversations",
                new_conversations_root,
            )
            if conversations_moved:
                moved_subdirs.append("conversations")
        except OSError as exc:
            return MigrationOutcome(
                status="failed",
                backup_path=backup_path,
                message=f"Could not move conversations: {exc}",
            )

        # Settings YAML last: rewrite any literal ~/.pwg/ path
        # values to their new homes, then write the rewritten
        # body to the engine-room location. Move-vs-rewrite:
        # rewriting is safer because the YAML may name explicit
        # legacy paths the operator wants kept consistent with
        # the file moves above.
        legacy_yaml = legacy_root / "settings.yaml"
        new_yaml = new_root / "settings.yaml"
        if legacy_yaml.exists():
            try:
                body = legacy_yaml.read_text(encoding="utf-8")
                rewritten = _rewrite_settings_yaml_paths(body)
                new_yaml.parent.mkdir(parents=True, exist_ok=True)
                new_yaml.write_text(rewritten, encoding="utf-8")
                legacy_yaml.unlink()
                moved_subdirs.append("settings.yaml")
            except OSError as exc:
                return MigrationOutcome(
                    status="failed",
                    backup_path=backup_path,
                    message=f"Could not migrate settings.yaml: {exc}",
                )

        # Drop the (now likely empty) legacy root.
        try:
            legacy_root.rmdir()
        except OSError:
            # Non-empty due to a collision-skip above. Leave it
            # for the operator to inspect; the backup is the
            # canonical recoverable state.
            pass

        _write_sentinel(sentinel)
        return MigrationOutcome(
            status="migrated",
            moved_subdirs=tuple(moved_subdirs),
            backup_path=backup_path,
            conversations_moved=conversations_moved,
        )
    finally:
        _release_lock(lockfile)


def _write_sentinel(sentinel: Path) -> None:
    body = (
        f"Migrated from ~/.pwg/ on "
        f"{datetime.now(timezone.utc).isoformat()}\n"
    )
    sentinel.parent.mkdir(parents=True, exist_ok=True)
    sentinel.write_text(body, encoding="utf-8")
