"""Drop-folder scan + dispatch. Flag OFF by default."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Callable, Iterable, Optional

from . import bundle as _bundle
from .adapters import SOURCES, detect, parse_file
from .model import Meeting
from .people import PersonDirectory, resolve_attendees

FLAG = "OSTLER_MEETING_IMPORT_ENABLED"
DEFAULT_DROP = "~/Documents/Ostler/Imports"


def enabled() -> bool:
    return os.environ.get(FLAG, "").strip() == "1"


def drop_root() -> Path:
    return Path(os.environ.get("OSTLER_MEETING_IMPORT_DIR") or DEFAULT_DROP).expanduser()


def iter_files(root: Path) -> Iterable[tuple[str, Path]]:
    """(source_hint, file) for ``<root>/<source>/**``; hint is the folder name."""
    for src in SOURCES:
        d = root / src
        if d.is_dir():
            for p in sorted(d.rglob("*")):
                if p.is_file() and not p.name.startswith("."):
                    yield src, p


def iter_loose(root: Path, max_depth: int = 3) -> Iterable[tuple[str, Path]]:
    """(source, file) for every file under a flat folder such as ~/Downloads
    that ``detect`` can attribute. Unattributable files are left alone."""
    base = len(root.parts)
    for p in sorted(root.rglob("*")):
        if len(p.parts) - base > max_depth or any(x.startswith(".") for x in p.parts[base:]):
            continue
        if p.is_file():
            src = detect(p)
            if src:
                yield src, p


SENTINEL_SOURCE = "meetings"


def default_sentinel_dir() -> Path:
    base = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
    return (Path(base) if base else Path.home() / ".ostler") / "state" / "hydrate"


def write_sentinel(d: Path, *, imported: int, failed: int, by_source: dict) -> Path:
    """The key=value record the Doctor's source table reads
    (``<state>/hydrate/<source>.done``, same keys install.sh's
    _hydrate_sentinel_record writes). ok / no_data / error, never silent."""
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    status = "error" if failed else "ok" if imported else "no_data"
    lines = [f"recorded_at={now}", f"source={SENTINEL_SOURCE}", f"status={status}",
             f"item_count={imported}", f"failed={failed}",
             "payload=" + " ".join(f"{k}={v}" for k, v in sorted(by_source.items()))]
    if imported:
        lines.append(f"last_update_at={now}")
    if status == "no_data":
        lines.append("detail=no meeting export found")
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{SENTINEL_SOURCE}.done"
    tmp = f.with_suffix(".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(f)
    return f


def import_all(*, root: Optional[Path] = None, out_root: Optional[Path] = None,
               directory: Optional[PersonDirectory] = None, owner_name: str = "",
               owner_email: str = "", privacy_level: Optional[str] = None,
               push_reminders: bool = False, reminders_db_path: Optional[Path] = None,
               force: bool = False, loose: bool = False,
               sentinel_dir: Optional[Path] = None) -> dict:
    if not (enabled() or force):
        return {"status": "disabled", "detail": f"set {FLAG}=1 to enable"}
    owner_name = owner_name or os.environ.get("OSTLER_USER_DISPLAY_NAME", "")
    owner_email = owner_email or os.environ.get("OSTLER_USER_EMAIL", "")
    imported = failed = 0
    folders: list[str] = []
    by_source: dict[str, int] = {}
    files = iter_loose(root) if (loose and root) else iter_files(root or drop_root())
    for hint, path in files:
        try:
            meetings = parse_file(hint, path)
        except Exception as exc:  # noqa: BLE001 -- type only: transcripts are private
            failed += 1
            print(f"meeting_import: cannot parse a {hint} file ({type(exc).__name__})")
            continue
        for m in meetings:
            links = resolve_attendees(m.attendees, directory,
                                      owner_name=owner_name, owner_email=owner_email)
            b = _bundle.build(m, links, owner_name=owner_name, privacy_level=privacy_level)
            out = _bundle.write(b, root=out_root, push_reminders=push_reminders,
                                reminders_db_path=reminders_db_path)
            imported += 1
            by_source[hint] = by_source.get(hint, 0) + 1
            folders.append(str(out.folder))
    if sentinel_dir is not None:   # the CLI passes default_sentinel_dir(); tests pass tmp
        write_sentinel(sentinel_dir, imported=imported, failed=failed, by_source=by_source)
    return {"status": "ok", "imported": imported, "failed": failed, "by_source": by_source,
            "folders": folders}
