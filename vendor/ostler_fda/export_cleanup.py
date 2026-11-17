"""Offer to delete an export the owner dropped into Downloads, after it imported.

Red team, 19 Oct: an imported export (Instagram, Telegram, Messenger, a
Takeout) stays in ~/Downloads holding every message again in plain files,
and Instagram and Telegram exports also carry voice-note AUDIO. Ostler never
keeps audio (transcribe on device, then delete), so leaving it in Downloads
after Ostler has what it needs is a gap in the same promise.

This module only OFFERS. It never deletes on its own:

* :func:`cleanup_offer` returns an offer only when the import really landed
  something (``status == "ok"`` and conversations persisted, or a knowledge
  export converted), and the export is a real file or folder directly in, or
  below, the owner's Downloads folder. A symlink, Downloads itself, or
  anything outside it gets no offer.
* :func:`delete_export` runs only when the owner said yes (the CLI's
  ``--delete-export-after``, or the Doctor / installer button). It re-checks
  every condition at delete time, and never follows a symlink out of
  Downloads.

``OSTLER_DOWNLOADS_DIR`` overrides the Downloads location (tests use it).
"""
from __future__ import annotations

import os
import shutil
import zipfile
from pathlib import Path
from typing import Optional

AUDIO_SUFFIXES = frozenset({
    ".m4a", ".mp3", ".aac", ".ogg", ".oga", ".opus", ".wav", ".amr", ".caf", ".flac",
})

OFFER_ACTIONS = ("Delete export", "Keep it")

_OFFER_TEXT = (
    "Your {label} export is still in Downloads. It holds another copy of "
    "your messages{audio}. Ostler has everything it needs from it, so you "
    "can delete it."
)


def downloads_dir() -> Path:
    raw = os.environ.get("OSTLER_DOWNLOADS_DIR")
    return Path(raw).expanduser() if raw else Path.home() / "Downloads"


def _inside_downloads(path: Path) -> bool:
    """True for a real (non-symlink) path strictly inside Downloads."""
    if path.is_symlink():
        return False
    try:
        root = downloads_dir().resolve(strict=True)
        real = path.resolve(strict=True)
    except (OSError, RuntimeError):
        return False
    return root in real.parents  # Downloads itself is not its own parent


def _scan(path: Path) -> tuple:
    """(total bytes, audio file count), never following symlinks."""
    if path.is_file():
        audio = 0
        if zipfile.is_zipfile(path):
            try:
                with zipfile.ZipFile(path) as zf:
                    audio = sum(1 for n in zf.namelist()
                                if Path(n).suffix.lower() in AUDIO_SUFFIXES)
            except (OSError, zipfile.BadZipFile):
                audio = 0
        return path.stat().st_size, audio
    total = audio = 0
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        for name in filenames:
            fp = Path(dirpath) / name
            if fp.is_symlink():
                continue
            try:
                total += fp.stat().st_size
            except OSError:
                continue
            if fp.suffix.lower() in AUDIO_SUFFIXES:
                audio += 1
    return total, audio


def _landed(result: dict) -> bool:
    if result.get("status") != "ok":
        return False
    # A partial persist is not a landed import. If the pipeline rejected any
    # thread, the export still holds data that never reached the graph, and
    # offering to delete it would destroy the only copy of that data.
    # Both spellings are checked: the staged-persist and the email paths name
    # the same count differently.
    if int(result.get("persist_failed") or 0) > 0 or int(result.get("conversations_failed") or 0) > 0:
        return False
    if int(result.get("persisted") or 0) > 0:
        return True
    return result.get("converted") is True


def cleanup_offer(path: Path, result: dict, label: Optional[str] = None) -> Optional[dict]:
    """The offer to show after an import, or None when there is nothing to offer."""
    path = Path(path).expanduser()
    if not _landed(result) or not _inside_downloads(path):
        return None
    size, audio = _scan(path)
    label = label or "data"
    return {
        "path": str(path),
        "bytes": size,
        "contains_audio": audio > 0,
        "audio_files": audio,
        "message": _OFFER_TEXT.format(
            label=label, audio=", including voice notes" if audio else ""),
        "actions": list(OFFER_ACTIONS),
    }


def delete_export(path: Path) -> dict:
    """Delete an export the owner chose to delete. Re-checks everything."""
    path = Path(path).expanduser()
    if not _inside_downloads(path):
        return {"deleted": False, "reason": "not_in_downloads"}
    size, _ = _scan(path)
    try:
        if path.is_dir():
            shutil.rmtree(path)  # does not follow symlinks inside the tree
        else:
            path.unlink()
    except OSError as exc:
        return {"deleted": False, "reason": type(exc).__name__}
    return {"deleted": True, "bytes": size}
