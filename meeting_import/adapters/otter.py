"""Otter.ai owner export: TXT, DOCX, SRT from a conversation's Export menu
(three dots > Export), or a Business-plan bulk export ZIP unpacked into the
drop folder.

Layouts CONFIRMED from Otter's own "Export conversations" article
(help.otter.ai/hc/en-us/articles/360047733634, updated 2026-10-10; its
export examples image read 2026-10-18):
- file name ``<Title>_otter_ai.<ext>``;
- TXT: no title line; ``Name  m:ss`` header, the paragraph, a blank line;
  footer ``Transcribed by https://otter.ai``. Basic (free) plan exports TXT only;
- DOCX: title, ``Fri, Feb 20, 2026 3:34PM • 1:38`` (start, duration),
  SUMMARY KEYWORDS, SPEAKERS (comma list), then ``Name  mm:ss`` turns, footer;
- SRT: cues whose first line is ``Name: text``.
PDF is not parsed. "Show speaker names" / "Show timestamps" are export
toggles; a TXT exported with both OFF has no turn structure and imports as
one unattributed block.

Otter's summary (overview, action items, outline, insights) is a separate
export whose file layout Otter does not show: NOT parsed (Otter's own FAQ:
"action items can't be exported directly"). Each imported Otter meeting says
plainly that no summary was supplied.
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta
from pathlib import Path

from ..model import Attendee, Meeting, Utterance
from . import transcript_files as tf

_FOOTER = re.compile(r"^transcribed by\s+https?://otter\.ai\s*$", re.I)
_SUFFIX = re.compile(r"_otter_ai$", re.I)
_DOCX_DATE = re.compile(r"^\w{3}, (\w{3} \d{1,2}, \d{4} \d{1,2}:\d{2}\s*[AP]M)\s*•\s*((?:\d+:)?\d{1,2}:\d{2})\s*$")
_GENERIC = re.compile(r"^(speaker|unknown speaker)\s*\d*$", re.I)


def _title(path: Path) -> str:
    return _SUFFIX.sub("", path.stem).replace("_", " ").strip() or path.stem


def _turns(lines: list[str]) -> list[Utterance]:
    """``Name  m:ss`` header, then every line up to the next header."""
    out: list[Utterance] = []
    spk, at, buf = None, None, []
    for raw in lines:
        line = raw.strip()
        if not line or _FOOTER.match(line):
            continue
        h = tf._HDR.match(line)
        if h:
            if spk is not None and buf:
                out.append(Utterance(spk, " ".join(buf), at))
            spk, at, buf = h.group(1).strip(), tf.seconds(h.group(2) + ".000"), []
        elif spk is not None:
            buf.append(line)
        else:
            buf.append(line)   # no headers at all: speaker names/timestamps toggled off
    if spk is not None and buf:
        out.append(Utterance(spk, " ".join(buf), at))
    elif spk is None and buf:
        out.append(Utterance("Unknown", " ".join(buf)))
    return out


def _attendees(names) -> tuple[Attendee, ...]:
    seen, out = set(), []
    for n in names:
        n = n.strip()
        if n and not _GENERIC.match(n) and n.lower() not in seen:
            seen.add(n.lower())
            out.append(Attendee(name=n))
    return tuple(out)


def _docx(path: Path) -> list[Meeting]:
    paras = [p for p in tf.docx_paragraphs(path) if p.strip()]
    title, started, ended, speakers = _title(path), tf.date_from(path), "", []
    i = 0
    if paras and not tf._HDR.match(paras[0]):
        title, i = paras[0], 1
    if i < len(paras):
        d = _DOCX_DATE.match(paras[i])
        if d:
            t0 = datetime.strptime(re.sub(r"\s+([AP]M)$", r"\1", d.group(1)), "%b %d, %Y %I:%M%p")
            started = t0.isoformat()
            ended = (t0 + timedelta(seconds=tf.seconds(d.group(2) + ".000") or 0)).isoformat()
            i += 1
    while i < len(paras) and not tf._HDR.match(paras[i]):
        if paras[i].strip().upper() == "SPEAKERS" and i + 1 < len(paras):
            speakers = paras[i + 1].split(",")
            i += 2
            continue
        i += 1
    utts = _turns(paras[i:])
    if not utts:
        return []
    return [Meeting(source="otter", source_label="Otter", title=title, started_at=started,
                    ended_at=ended, attendees=_attendees(speakers or [u.speaker for u in utts]),
                    utterances=tuple(utts), source_file=path.name)]


def parse(path: Path) -> list[Meeting]:
    ext = path.suffix.lower()
    if ext == ".docx":
        return _docx(path)
    if ext in (".srt", ".vtt"):
        ms = tf.parse(path, source="otter", label="Otter")
        return [Meeting(**{**m.__dict__, "title": _title(path),
                           "attendees": _attendees(u.speaker for u in m.utterances)}) for m in ms]
    if ext != ".txt":
        return []
    utts = _turns(path.read_text(encoding="utf-8-sig", errors="replace").splitlines())
    if not utts:
        return []
    return [Meeting(source="otter", source_label="Otter", title=_title(path),
                    started_at=tf.date_from(path), utterances=tuple(utts),
                    attendees=_attendees(u.speaker for u in utts), source_file=path.name)]
