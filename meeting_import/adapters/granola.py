"""Granola: three owner-side sources, all read from a file the owner saved.

1. CSV export (every plan). Settings > Profile > Generate CSV; emailed link,
   valid 24 h. Contains "the title, note summary, transcript, and other basic
   details for each note", only notes with a summary
   (docs.granola.ai/help-center/sharing/exporting-notes, read 2026-10-18).
   The column NAMES are not documented: headers are matched
   case-insensitively by keyword (ASSUMED), and a CSV with no transcript and
   no summary column is refused with ValueError, never imported as empty.
2. Public API v1 note JSON (``GET /v1/notes/{id}?include=transcript``, or a
   ``{"notes": [...]}`` list page). Field names are CONFIRMED from Granola's
   own OpenAPI document (docs.granola.ai/api-reference/openapi.json, read
   2026-10-18): ``speaker`` is an OBJECT {source, attribution, diarization_label,
   name}; times are ISO 8601 ``start_time`` / ``end_time``; attendees are
   {name, email}; ``calendar_event`` carries scheduled times and invitees.
3. A Markdown note (copy/paste or a third-party exporter).

CAN'T DO: Granola's local cache (undocumented, reportedly encrypted).
"""
from __future__ import annotations

import csv
import io
import json
import re
from datetime import datetime
from pathlib import Path

from ..model import ActionItem, Attendee, Meeting, Utterance
from . import transcript_files as tf

_H = re.compile(r"^#{1,6}\s+(.*)$")
_B = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.*)$")


def split_markdown(md: str):
    """-> (overview, topics, action_items). Headings named like 'Action
    items' / 'Next steps' / 'To do' feed action items; other headings become
    topics; text before the first heading is the overview."""
    overview: list[str] = []
    topics: list[tuple[str, list[str]]] = []
    items: list[str] = []
    cur = None
    for line in md.splitlines():
        h = _H.match(line)
        if h:
            cur = h.group(1).strip().strip("*")
            if not re.search(r"action|next step|to-?do|follow.?up", cur, re.I):
                topics.append((cur, []))
            continue
        if not line.strip():
            continue
        b = _B.match(line)
        text = (b.group(1) if b else line).strip()
        if cur is None:
            overview.append(text)
        elif re.search(r"action|next step|to-?do|follow.?up", cur, re.I):
            items.append(text)
        elif topics:
            topics[-1][1].append(text)
    return " ".join(overview), tuple((n, tuple(p)) for n, p in topics if p), tuple(items)


def _iso(v) -> datetime | None:
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _speaker(sp) -> str:
    """Official speaker object -> display label. A resolved ``name`` wins; an
    iOS ``diarization_label`` is next; then ``attribution`` (me/them); then
    ``source`` (microphone is the owner's mic on macOS)."""
    if isinstance(sp, str):
        return sp or "Unknown"
    if not isinstance(sp, dict):
        return "Unknown"
    if sp.get("name"):
        return str(sp["name"])
    if sp.get("diarization_label"):
        return str(sp["diarization_label"])
    a = sp.get("attribution") or {"microphone": "me", "speaker": "them"}.get(sp.get("source"), "")
    return {"me": "Me", "them": "Them"}.get(a, "Unknown")


def _note(n: dict) -> Meeting | None:
    cal = n.get("calendar_event") if isinstance(n.get("calendar_event"), dict) else {}
    started = cal.get("scheduled_start_time") or n.get("created_at") or n.get("start") or ""
    t0 = _iso(started)
    utts = []
    last_end = ""
    for x in n.get("transcript") or []:
        if not (isinstance(x, dict) and x.get("text")):
            continue
        st = x.get("start_time", x.get("start"))
        if isinstance(st, (int, float)):
            off = float(st)
        else:
            d = _iso(st)
            if d and t0 is None:
                t0 = d
            off = max((d - t0).total_seconds(), 0.0) if d and t0 else None
        last_end = x.get("end_time") or last_end
        utts.append(Utterance(_speaker(x.get("speaker")), str(x["text"]), off))
    md = str(n.get("summary_markdown") or n.get("summary_text") or n.get("summary") or "")
    if not utts and not md:
        return None
    ov, topics, items = split_markdown(md)
    att: list[Attendee] = []
    seen: set[str] = set()
    for a in (n.get("attendees") or []) + list(cal.get("invitees") or []):
        if isinstance(a, dict):
            at = Attendee(str(a.get("name") or ""), str(a.get("email") or ""))
        else:
            at = Attendee(email=str(a)) if "@" in str(a) else Attendee(name=str(a))
        key = (at.email or at.name).lower()
        if key and key not in seen:
            seen.add(key)
            att.append(at)
    return Meeting(source="granola", source_label="Granola", title=str(n.get("title") or cal.get("event_title") or "Untitled meeting"),
                   source_id=str(n.get("id") or ""), started_at=str(started),
                   ended_at=str(cal.get("scheduled_end_time") or n.get("end") or last_end or ""),
                   attendees=tuple(att), utterances=tuple(utts),
                   summary_overview=ov, summary_topics=topics,
                   action_items=tuple(ActionItem(i) for i in items))


_ADDR = re.compile(r"^\s*(.*?)\s*<([^>@\s]+@[^>\s]+)>\s*$")


def _col(header: list[str], *words: str) -> str | None:
    for h in header:
        if any(w in h.strip().lower() for w in words):
            return h
    return None


def parse_csv(path: Path) -> list[Meeting]:
    rows = csv.DictReader(io.StringIO(path.read_text(encoding="utf-8-sig")))
    hdr = rows.fieldnames or []
    c_title, c_sum, c_tx = _col(hdr, "title"), _col(hdr, "summary", "note"), _col(hdr, "transcript")
    c_date = _col(hdr, "created", "date", "start", "time")
    c_att = _col(hdr, "attendee", "participant", "invitee")
    c_id = next((h for h in hdr if h.strip().lower() in ("id", "note id", "note_id")), None)
    if not (c_tx or c_sum):
        raise ValueError("not a Granola CSV export: no transcript or summary column")
    out: list[Meeting] = []
    for r in rows:
        tx = (r.get(c_tx) or "") if c_tx else ""
        utts, last = [], ""
        for line in tx.splitlines():
            if not line.strip():
                continue
            spk, txt = tf.split_speaker(line, last)
            last = spk or last
            utts.append(Utterance(spk or "Unknown", txt))
        md = (r.get(c_sum) or "") if c_sum else ""
        if not utts and not md.strip():
            continue
        att = []
        for a in re.split(r"[;\n]", (r.get(c_att) or "") if c_att else ""):
            if not a.strip():
                continue
            m = _ADDR.match(a)
            att.append(Attendee(m.group(1).strip('" '), m.group(2)) if m else
                       Attendee(email=a.strip()) if "@" in a else Attendee(name=a.strip()))
        ov, topics, items = split_markdown(md)
        out.append(Meeting(source="granola", source_label="Granola",
                           title=((r.get(c_title) or "") if c_title else "").strip() or "Untitled meeting",
                           source_id=((r.get(c_id) or "") if c_id else "").strip(),
                           started_at=((r.get(c_date) or "") if c_date else "").strip() or tf.date_from(path),
                           attendees=tuple(att), utterances=tuple(utts), summary_overview=ov,
                           summary_topics=topics, action_items=tuple(ActionItem(i) for i in items),
                           source_file=path.name))
    return out


def parse(path: Path) -> list[Meeting]:
    ext = path.suffix.lower()
    if ext == ".json":
        d = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(d, dict) and isinstance(d.get("notes"), list):
            d = d["notes"]
        return [m for m in (_note(n) for n in (d if isinstance(d, list) else [d])
                            if isinstance(n, dict)) if m]
    if ext == ".csv":
        return parse_csv(path)
    if ext in (".md", ".markdown"):
        raw = path.read_text(encoding="utf-8")
        fm = {}
        if raw.startswith("---"):
            head, _, raw = raw[3:].partition("\n---")
            fm = dict(re.findall(r"^(\w+):\s*(.+)$", head, re.M))
        ov, topics, items = split_markdown(raw)
        return [Meeting(source="granola", source_label="Granola",
                        title=fm.get("title", tf.title_from(path)).strip("\"'"),
                        source_id=fm.get("id", "").strip("\"'"),
                        started_at=fm.get("created_at", tf.date_from(path)).strip("\"'"),
                        summary_overview=ov, summary_topics=topics,
                        action_items=tuple(ActionItem(i) for i in items), source_file=path.name)]
    return tf.parse(path, source="granola", label="Granola")
