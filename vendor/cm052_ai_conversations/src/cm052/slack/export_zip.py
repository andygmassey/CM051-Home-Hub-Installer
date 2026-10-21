"""Route 1: the Slack workspace export ZIP (Owners / Admins).

Read straight from the ZIP with ``zipfile``; nothing is extracted to disk,
so a hostile member name cannot write outside anywhere. An unpacked export
directory is also accepted (the owner may have double-clicked the ZIP).

Layout, from Slack Help "Export your workspace data"
(https://slack.com/help/articles/201658943) and community parsers. NOT yet
checked against a real export (no real export was opened, by rule):

    users.json      [{id, name, real_name, is_bot, profile: {email, display_name, real_name}}]
    channels.json   [{id, name, members: [...]}]           public channels
    groups.json     [{id, name, members: [...]}]           private channels (approved exports)
    dms.json        [{id, members: [u1, u2]}]              DMs (approved exports)
    mpims.json      [{id, name, members: [...]}]           group DMs (approved exports)
    <folder>/YYYY-MM-DD.json   [message, ...]  one file per day

Folder naming, UNVERIFIED: public/private channels by ``name``; DMs by the
DM ``id``; MPIMs by their ``name`` (``mpdm-a--b-1``). Both the name and the
id are tried for every container, and a folder that matches neither is
still imported (keyed by folder name) and COUNTED in
``unmatched_folders``, never dropped.

What a Free/Pro export lacks (Slack Help): DMs and private channels. That
absence is reported as zero containers of that kind, which is the true
answer for those plans, not an error.
"""
from __future__ import annotations

import json
import logging
import re
import zipfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

from .model import ChannelInfo

log = logging.getLogger(__name__)

# A single JSON member larger than this is refused (zip-bomb guard); the
# reader streams per folder, so total export size is not bounded by RAM. A busy
# channel's day file is kilobytes; users.json for a 10k-person org is ~30 MB.
MAX_MEMBER_BYTES = 256 * 1024 * 1024

_DAY_FILE = re.compile(r"^\d{4}-\d{2}-\d{2}\.json$")
_META_FILES = {
    "channels.json": "public",
    "groups.json": "private",
    "dms.json": "im",
    "mpims.json": "mpim",
}


class ExportError(Exception):
    """The export could not be read at all (not a ZIP, no users.json, a
    corrupt top-level file...). CANNOT-RUN, exit 3."""


# Everything a single member read can raise: bad JSON, bad UTF-8, a ZIP CRC
# or decompression error, an unreadable file, our own size cap.
_MEMBER_ERRORS = (ValueError, zipfile.BadZipFile, zlib.error, OSError, EOFError, ExportError)


@dataclass
class ExportContents:
    users: list[dict]
    channels: dict[str, ChannelInfo]           # folder name -> container
    messages: dict[str, list[dict]]            # folder name -> raw messages
    unmatched_folders: int = 0
    skipped_files: int = 0
    bad_day_files: int = 0
    kinds: dict[str, int] = field(default_factory=dict)


class _Source:
    """Uniform read access over a ZIP or an unpacked directory."""

    def __init__(self, path: Path):
        self.path = path
        self._zip: zipfile.ZipFile | None = None
        if path.is_dir():
            return
        try:
            self._zip = zipfile.ZipFile(path)
        except (zipfile.BadZipFile, OSError) as exc:
            raise ExportError(f"not a readable Slack export ZIP: {exc}") from exc

    def names(self) -> list[str]:
        if self._zip is not None:
            return [i.filename for i in self._zip.infolist() if not i.is_dir()]
        return [
            p.relative_to(self.path).as_posix()
            for p in self.path.rglob("*.json")
            if p.is_file()
        ]

    def read_json(self, name: str) -> Any:
        if self._zip is not None:
            info = self._zip.getinfo(name)
            if info.file_size > MAX_MEMBER_BYTES:
                raise ExportError(f"member too large: {info.file_size} bytes")
            raw = self._zip.read(info)
        else:
            p = self.path / name
            if p.stat().st_size > MAX_MEMBER_BYTES:
                raise ExportError(f"file too large: {p.stat().st_size} bytes")
            raw = p.read_bytes()
        return json.loads(raw.decode("utf-8"))

    def close(self) -> None:
        if self._zip is not None:
            self._zip.close()


def _strip_root(names: list[str]) -> str:
    """Some unzippers wrap everything in one top folder. Find the prefix
    under which ``users.json`` sits."""
    for n in names:
        parts = PurePosixPath(n).parts
        if parts and parts[-1] == "users.json" and len(parts) <= 2:
            return "/".join(parts[:-1])
    return ""


def _top_level(src: "_Source", name: str) -> Any:
    """users.json and the container lists are load-bearing: without them no
    author or channel can be named, so a corrupt one is CANNOT-RUN."""
    try:
        return src.read_json(name)
    except ExportError:
        raise
    except _MEMBER_ERRORS as exc:
        raise ExportError(
            f"{PurePosixPath(name).name} is unreadable ({type(exc).__name__})"
        ) from exc


class ExportReader:
    """Streaming reader: one channel's day files in memory at a time.

    Red team, 19 Oct: ``read_export`` used to hold every day file of every
    channel before building a single conversation, so a 10 GB export needed
    10 GB of RAM. Opening reads only the small top-level files and the member
    NAMES; ``iter_folders`` then reads one folder, yields it, and drops it.
    A folder is the right unit: a thread never spans two channels, so
    grouping per folder loses nothing. Peak memory is the largest channel.
    """

    def __init__(self, path: Path):
        self._src = _Source(Path(path).expanduser())
        try:
            self._open()
        except BaseException:
            self._src.close()
            raise

    def _open(self) -> None:
        src = self._src
        names = src.names()
        root = _strip_root(names)
        prefix = f"{root}/" if root else ""
        if f"{prefix}users.json" not in names:
            raise ExportError("users.json not found: this does not look like a Slack export")
        users = _top_level(src, f"{prefix}users.json")
        if not isinstance(users, list):
            raise ExportError("users.json is not a list")
        self.users: list[dict] = users

        by_key: dict[str, ChannelInfo] = {}
        self.kinds: dict[str, int] = {k: 0 for k in _META_FILES.values()}
        for meta_name, kind in _META_FILES.items():
            full = f"{prefix}{meta_name}"
            if full not in names:
                continue
            rows = _top_level(src, full)
            for row in rows if isinstance(rows, list) else []:
                if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                    continue
                members = [m for m in row.get("members") or [] if isinstance(m, str)]
                info = ChannelInfo(
                    channel_id=row["id"],
                    name=str(row.get("name") or row["id"]),
                    kind=kind,
                    members=members if kind in ("im", "mpim") else [],
                )
                self.kinds[kind] += 1
                by_key.setdefault(row["id"], info)
                if row.get("name"):
                    by_key.setdefault(str(row["name"]), info)
        self._by_key = by_key

        self._day_files: dict[str, list[str]] = {}
        self.skipped_files = 0
        for name in sorted(names):
            if prefix and not name.startswith(prefix):
                self.skipped_files += 1
                continue
            rel = PurePosixPath(name[len(prefix):])
            if len(rel.parts) != 2:
                if len(rel.parts) != 1:
                    self.skipped_files += 1
                continue
            folder, fname = rel.parts
            if not _DAY_FILE.match(fname):
                self.skipped_files += 1
                continue
            self._day_files.setdefault(folder, []).append(name)
        self.bad_day_files = 0
        self.unmatched_folders = 0

    def iter_folders(self):
        """Yield ``(folder, ChannelInfo, messages)`` one folder at a time."""
        for folder in sorted(self._day_files):
            messages: list[dict] = []
            read_any = False
            for name in self._day_files[folder]:
                try:
                    day = self._src.read_json(name)
                except _MEMBER_ERRORS as exc:
                    # One bad day must not lose the rest of the workspace.
                    # Counted and reported; the name stays out of the log
                    # (folder names are channel or person names).
                    self.bad_day_files += 1
                    log.warning("slack export: skipped an unreadable day file (%s)", type(exc).__name__)
                    continue
                if not isinstance(day, list):
                    self.bad_day_files += 1
                    continue
                read_any = True
                messages.extend(m for m in day if isinstance(m, dict))
            if not read_any:
                continue
            info = self._by_key.get(folder)
            if info is None:
                self.unmatched_folders += 1
                log.warning("slack export: a folder matched no container metadata")
                info = ChannelInfo(channel_id=f"folder:{folder}", name=folder, kind="public")
            yield folder, info, messages

    def close(self) -> None:
        self._src.close()

    def __enter__(self) -> "ExportReader":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


def read_export(path: Path) -> ExportContents:
    """Materialise a whole export. TESTS AND SMALL TOOLS ONLY: the importer
    streams through ``ExportReader.iter_folders``."""
    with ExportReader(path) as reader:
        channels: dict[str, ChannelInfo] = {}
        messages: dict[str, list[dict]] = {}
        for folder, info, msgs in reader.iter_folders():
            channels[folder] = info
            messages[folder] = msgs
        return ExportContents(
            users=reader.users,
            channels=channels,
            messages=messages,
            unmatched_folders=reader.unmatched_folders,
            skipped_files=reader.skipped_files,
            bad_day_files=reader.bad_day_files,
            kinds=reader.kinds,
        )
