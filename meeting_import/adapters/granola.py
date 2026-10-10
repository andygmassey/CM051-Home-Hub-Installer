"""Granola: note JSON from the official API (owner's own key, saved by the
owner) or a markdown note export.

CAN'T DO: Granola's local cache. Current installs reportedly use an
encrypted cache (cache-v6.json.enc) and older ones a double-encoded
cache-v3.json; both are community findings, not documented, so this adapter
does not read them. Granola's native in-app export is a CSV of titles and
short summaries with no transcript (UNVERIFIED, one community source).

API note JSON field names (id, title, created_at, attendees, summary_markdown
/ summary_text, transcript[speaker,text,start]) are from a COMMUNITY
reference, not Granola's own docs: ASSUMED. Tolerant of ``{"notes": [...]}``.
"""
from __future__ import annotations

import json
import re
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


def _note(n: dict) -> Meeting | None:
    t = n.get("transcript") or []
    utts = tuple(Utterance(str(x.get("speaker") or "Unknown"), str(x.get("text") or ""),
                           x.get("start") if isinstance(x.get("start"), (int, float)) else None)
                 for x in t if isinstance(x, dict) and x.get("text"))
    md = str(n.get("summary_markdown") or n.get("summary_text") or "")
    if not utts and not md:
        return None
    ov, topics, items = split_markdown(md)
    att = tuple(Attendee(str(a.get("name") or ""), str(a.get("email") or "")) if isinstance(a, dict)
                else Attendee(email=str(a)) if "@" in str(a) else Attendee(name=str(a))
                for a in (n.get("attendees") or []))
    return Meeting(source="granola", source_label="Granola", title=str(n.get("title") or "Untitled meeting"),
                   source_id=str(n.get("id") or ""), started_at=str(n.get("created_at") or n.get("start") or ""),
                   ended_at=str(n.get("end") or ""), attendees=att, utterances=utts,
                   summary_overview=ov, summary_topics=topics,
                   action_items=tuple(ActionItem(i) for i in items))


def parse(path: Path) -> list[Meeting]:
    ext = path.suffix.lower()
    if ext == ".json":
        d = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(d, dict) and isinstance(d.get("notes"), list):
            d = d["notes"]
        return [m for m in (_note(n) for n in (d if isinstance(d, list) else [d])
                            if isinstance(n, dict)) if m]
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
