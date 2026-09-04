"""Persist extracted vCard PHOTO payloads to disk.

Photos are written as raw bytes (not base64) under ``PHOTO_DIR``, filed by a
stable hash of the person URI so the same person overwrites the same file on
re-sync. Callers receive the absolute path back — that path is what gets
stored in Qdrant (``profile_photo_path``) and Oxigraph (``foaf:img``).
"""
from __future__ import annotations

import hashlib
import os
import tempfile
from typing import Optional


def person_photo_hash(person_uri: str) -> str:
    """Stable, filesystem-safe identifier derived from the person URI.

    32 hex chars (128 bits of SHA-256) — plenty for collision resistance
    across the tens-of-thousands-of-people scale the graph plans for, while
    keeping filenames short enough to skim in a directory listing.
    """
    return hashlib.sha256(person_uri.encode("utf-8")).hexdigest()[:32]


def photo_path_for(person_uri: str, ext: str, base_dir: str) -> str:
    """Compute the absolute photo path for a person URI without writing."""
    filename = f"{person_photo_hash(person_uri)}.{ext.lstrip('.')}"
    return os.path.join(base_dir, filename)


def write_photo(
    person_uri: str,
    data: bytes,
    ext: str,
    base_dir: str,
) -> str:
    """Atomically write *data* to the canonical path for *person_uri*.

    Returns the absolute path written. Writes via a temp file + rename so a
    crash mid-write cannot leave a half-image behind for the next reader.
    """
    os.makedirs(base_dir, exist_ok=True)
    final_path = photo_path_for(person_uri, ext, base_dir)

    fd, tmp_path = tempfile.mkstemp(
        prefix=".photo_", suffix=f".{ext.lstrip('.')}.tmp", dir=base_dir
    )
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp_path, final_path)
    except Exception:
        # Best-effort cleanup of the tmp file.
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    return final_path


def remove_photo(person_uri: str, base_dir: str) -> Optional[str]:
    """Remove any photo file for *person_uri*. Returns the removed path or None.

    Tries each known extension; vCard PHOTOs in the wild are one of png/jpg/gif.
    Safe to call when no photo exists — returns None instead of raising.
    """
    for ext in ("jpg", "png", "gif"):
        candidate = photo_path_for(person_uri, ext, base_dir)
        if os.path.isfile(candidate):
            try:
                os.unlink(candidate)
                return candidate
            except OSError:
                return None
    return None
