"""Provenance headers for embedded/RAG chunks (REUSE-5).

Chunks fed to the embedding model land in Qdrant as opaque text. When
the assistant later retrieves one of those chunks for an answer, the
text alone carries no signal about *where it came from* – so downstream
citations are weak ("the assistant said X" with no source).

This module stamps a compact, machine-parseable, single-line provenance
header onto each chunk's text *at chunk-creation time*, before embedding.
The header travels with the embedded text, so any retrieved chunk
self-describes its origin. Keep it tight (one line, a handful of fields)
so it costs only a few tokens and never dwarfs the chunk body.

Header grammar (one line, terminated by a single newline)::

    [pwg:src=imessage id=conv-123 date=2026-06-20 from=alice]

Rules:
- Always opens ``[pwg:`` and closes ``]`` so it is unambiguous to detect
  and strip. The ``pwg:`` sentinel avoids colliding with stray ``[...]``
  in the body.
- ``key=value`` pairs, space-separated. Values are sanitised: any of
  space, ``]``, ``=`` or newline in a value is replaced with ``_`` so
  the line stays parseable without quoting.
- Field order is fixed (``src id date from``) for determinism; absent
  fields are simply omitted.
- ``src`` is required (the source kind); everything else is best-effort.

The header round-trips: :func:`parse_header` recovers the field dict from
either a bare header line or a full chunk (header + body), and
:func:`strip_header` returns the body with the header removed.
"""
from __future__ import annotations

import re
from typing import Optional

# Fixed emit order. `src` first (required); rest best-effort.
_FIELD_ORDER = ("src", "id", "date", "from")

_HEADER_RE = re.compile(r"^\[pwg:(?P<fields>[^\]]*)\]")
_PAIR_RE = re.compile(r"(\w+)=([^\s\]]*)")
_BAD_VALUE_CHARS = re.compile(r"[\s\]=]")


def _sanitise(value: str) -> str:
    """Make a value safe to drop into the unquoted header line."""
    return _BAD_VALUE_CHARS.sub("_", value.strip())


def build_header(
    *,
    src: str,
    source_id: Optional[str] = None,
    date: Optional[str] = None,
    speaker: Optional[str] = None,
) -> str:
    """Return a one-line provenance header (no trailing newline).

    Parameters
    ----------
    src:
        Source kind – ``imessage`` / ``email`` / ``whatsapp`` /
        ``meeting`` / ``note`` etc. Required; falls back to ``unknown``
        if blank.
    source_id:
        Source id or path (conversation_id, session id, file path).
    date:
        Source date (``YYYY-MM-DD`` preferred, but any token is kept).
    speaker:
        Speaker / sender when known (``from=`` field).
    """
    values = {
        "src": _sanitise(src) or "unknown",
        "id": _sanitise(source_id) if source_id else "",
        "date": _sanitise(date) if date else "",
        "from": _sanitise(speaker) if speaker else "",
    }
    parts = [f"{k}={values[k]}" for k in _FIELD_ORDER if values[k]]
    return "[pwg:" + " ".join(parts) + "]"


def prepend_header(
    text: str,
    *,
    src: str,
    source_id: Optional[str] = None,
    date: Optional[str] = None,
    speaker: Optional[str] = None,
) -> str:
    """Return ``text`` with a provenance header on its own first line.

    Idempotent: if ``text`` already starts with a ``[pwg:...]`` header it
    is returned unchanged, so re-running the chunker never double-stamps.
    """
    if _HEADER_RE.match(text.lstrip()):
        return text
    header = build_header(
        src=src, source_id=source_id, date=date, speaker=speaker
    )
    return f"{header}\n{text}"


def parse_header(text: str) -> dict:
    """Recover the provenance fields from a header line or a full chunk.

    Returns a dict with whatever fields were present (e.g. ``{"src":
    "imessage", "id": "conv-123", "date": "2026-06-20", "from":
    "alice"}``). Returns ``{}`` when no header is found.
    """
    match = _HEADER_RE.match(text.lstrip())
    if not match:
        return {}
    return dict(_PAIR_RE.findall(match.group("fields")))


def strip_header(text: str) -> str:
    """Return ``text`` with a leading provenance header (and its newline)
    removed. Text without a header is returned unchanged."""
    stripped = text.lstrip()
    match = _HEADER_RE.match(stripped)
    if not match:
        return text
    rest = stripped[match.end():]
    return rest[1:] if rest.startswith("\n") else rest.lstrip("\n")
