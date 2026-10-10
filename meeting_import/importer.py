"""Drop-folder scan + dispatch. Flag OFF by default."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Callable, Iterable, Optional

from . import bundle as _bundle
from .adapters import SOURCES, parse_file
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


def import_all(*, root: Optional[Path] = None, out_root: Optional[Path] = None,
               directory: Optional[PersonDirectory] = None, owner_name: str = "",
               owner_email: str = "", privacy_level: Optional[str] = None,
               push_reminders: bool = False, reminders_db_path: Optional[Path] = None,
               force: bool = False) -> dict:
    if not (enabled() or force):
        return {"status": "disabled", "detail": f"set {FLAG}=1 to enable"}
    owner_name = owner_name or os.environ.get("OSTLER_USER_DISPLAY_NAME", "")
    owner_email = owner_email or os.environ.get("OSTLER_USER_EMAIL", "")
    imported = failed = 0
    folders: list[str] = []
    for hint, path in iter_files(root or drop_root()):
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
            folders.append(str(out.folder))
    return {"status": "ok", "imported": imported, "failed": failed, "folders": folders}
