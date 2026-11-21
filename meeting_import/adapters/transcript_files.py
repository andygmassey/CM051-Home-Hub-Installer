"""Generic VTT / SRT / DOCX transcripts (Zoom, Teams, Meet) and shared parsing.

Formats here are CONFIRMED only by the synthetic fixtures and the WebVTT/SRT
standards; the Zoom/Teams/Meet speaker-label conventions are ASSUMED (see
meeting_import/README.md). Parsing is tolerant: ``Name: text`` and
``<v Name>text</v>`` voice tags are both read.
"""
from __future__ import annotations

import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from ..model import Meeting, Utterance

_TS = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")
_CUE = re.compile(r"^\s*(\S+)\s+-->\s+(\S+)")
_VOICE = re.compile(r"^<v\s+([^>]+)>(.*?)(?:</v>)?$", re.S)
_LABEL = re.compile(r"^([^:\[\]\n]{1,60}?):\s+(\S.*)$", re.S)
_DATE_IN_NAME = re.compile(r"(\d{4})[-_.]?(\d{2})[-_.]?(\d{2})")


def seconds(ts: str):
    m = _TS.match(ts)
    if not m:
        return None
    h, mi, s, ms = m.groups()
    return int(h or 0) * 3600 + int(mi) * 60 + int(s) + int(ms.ljust(3, "0")) / 1000


def date_from(path: Path) -> str:
    """Date in the filename, else the file's modification time (UTC)."""
    m = _DATE_IN_NAME.search(path.stem)
    if m:
        try:
            return datetime(*map(int, m.groups()), tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def title_from(path: Path) -> str:
    t = _DATE_IN_NAME.sub("", path.stem).replace("_", " ").replace("-", " ").strip()
    return re.sub(r"\s+", " ", t) or path.stem


def split_speaker(text: str, last: str = ""):
    text = text.strip()
    m = _VOICE.match(text)
    if m:
        return m.group(1).strip(), re.sub(r"</?[^>]+>", "", m.group(2)).strip()
    m = _LABEL.match(text)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return last, re.sub(r"</?[^>]+>", "", text)


def parse_cues(raw: str) -> list[Utterance]:
    """VTT and SRT share cue blocks: [id] / start --> end / text lines."""
    out: list[Utterance] = []
    last = ""
    for block in re.split(r"\r?\n\s*\r?\n", raw.replace("﻿", "")):
        lines = [l for l in block.splitlines() if l.strip()]
        for i, l in enumerate(lines):
            c = _CUE.match(l)
            if c:
                body = " ".join(x.strip() for x in lines[i + 1:])
                if not body:
                    break
                spk, txt = split_speaker(body, last)
                last = spk or last
                out.append(Utterance(spk, txt, seconds(c.group(1))))
                break
    return out


def docx_paragraphs(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    ns = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    return ["".join(t.text or "" for t in p.iter(ns + "t")).strip() for p in root.iter(ns + "p")]


_HDR = re.compile(r"^(.{1,60}?)\s{1,}\(?((?:\d+:)?\d{1,2}:\d{2})\)?$")


def parse_paragraphs(paras: list[str]) -> list[Utterance]:
    """DOCX body: either 'Name  0:12' header paragraph followed by text, or
    one 'Name: text' paragraph per turn."""
    out: list[Utterance] = []
    i = 0
    paras = [p for p in paras if p]
    last = ""
    while i < len(paras):
        h = _HDR.match(paras[i])
        if h and i + 1 < len(paras):
            out.append(Utterance(h.group(1).strip(), paras[i + 1], seconds(h.group(2) + ".000")))
            last = h.group(1).strip()
            i += 2
            continue
        spk, txt = split_speaker(paras[i], last)
        if spk and ":" in paras[i][: len(spk) + 2]:
            out.append(Utterance(spk, txt))
            last = spk
        i += 1
    return out


def read_utterances(path: Path) -> list[Utterance]:
    ext = path.suffix.lower()
    if ext in (".vtt", ".srt"):
        return parse_cues(path.read_text(encoding="utf-8", errors="replace"))
    if ext == ".docx":
        return parse_paragraphs(docx_paragraphs(path))
    raise ValueError(f"unsupported transcript extension {ext}")


def parse(path: Path, *, source="transcript", label="Transcript file") -> list[Meeting]:
    if path.suffix.lower() not in (".vtt", ".srt", ".docx"):
        return []
    utts = read_utterances(path)
    if not utts:
        return []
    return [Meeting(source=source, source_label=label, title=title_from(path),
                    started_at=date_from(path), utterances=tuple(utts),
                    source_file=path.name)]
