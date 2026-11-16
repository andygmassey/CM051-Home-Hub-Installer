"""Readers for local mail stores: .eml files, MBOX, and Apple Mail .emlx."""

from __future__ import annotations

from pathlib import Path
from typing import Iterator


def parse_emlx(raw: bytes) -> bytes:
    """Apple Mail .emlx: first line is the message byte count, then the RFC 822 message."""
    nl = raw.find(b"\n")
    try:
        n = int(raw[:nl].strip())
    except ValueError:
        return raw
    return raw[nl + 1: nl + 1 + n]


def iter_mbox(path: Path) -> Iterator[bytes]:
    """Stream messages from an MBOX without loading the file."""
    buf: list = []
    with open(path, "rb") as f:
        for line in f:
            if line.startswith(b"From ") and (not buf or buf[-1] in (b"\n", b"\r\n")):
                if buf:
                    yield b"".join(buf[1:] if buf[0].startswith(b"From ") else buf)
                buf = [line]
            else:
                buf.append(line)
    if buf:
        yield b"".join(buf[1:] if buf[0].startswith(b"From ") else buf)


def iter_path(path: Path) -> Iterator[bytes]:
    """Messages under a file or directory (Apple Mail store, .eml folder or .mbox)."""
    p = Path(path)
    if p.is_dir():
        for f in sorted(p.rglob("*")):
            if f.suffix.lower() in (".eml", ".emlx", ".mbox") and f.is_file():
                yield from iter_path(f)
        return
    suffix = p.suffix.lower()
    if suffix == ".mbox":
        yield from iter_mbox(p)
    elif suffix == ".emlx":
        yield parse_emlx(p.read_bytes())
    else:
        yield p.read_bytes()
