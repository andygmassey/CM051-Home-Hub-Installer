"""Fireflies.ai: the JSON the owner saves from their own GraphQL query.

The importer never calls Fireflies: the owner runs the query with their own
key (outside Ostler) and drops the JSON. Accepts ``{"data": {"transcript":
{...}}}``, ``{"data": {"transcripts": [...]}}``, a bare transcript object, or
a list of them.

Field names (id, title, dateString, duration, participants, speakers,
sentences[speaker_name,text,start_time], summary{overview,action_items,...})
are from Fireflies' schema pages as surfaced by search; exact spellings are
from community samples. ASSUMED until checked against a real response.
``participants`` is a list of EMAIL addresses; names come from ``speakers``.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from ..model import ActionItem, Attendee, Meeting, Utterance


def _lines(v) -> list[str]:
    if isinstance(v, list):
        v = "\n".join(str(x) for x in v)
    out = []
    for l in str(v or "").splitlines():
        l = re.sub(r"^\s*(?:[-*•]|\d+[.)])\s*(?:\[[ xX]\]\s*)?", "", l).strip()
        if l and not (l.startswith("**") and l.endswith("**")):
            out.append(l)
    return out


def _one(t: dict) -> Meeting | None:
    sents = t.get("sentences") or []
    utts = tuple(Utterance(str(s.get("speaker_name") or "Unknown"), str(s.get("text") or ""),
                           s.get("start_time")) for s in sents if s.get("text"))
    if not utts and not t.get("summary"):
        return None
    start = str(t.get("dateString") or "")
    end = ""
    if utts and t.get("duration"):
        try:
            from datetime import datetime, timedelta
            d = datetime.fromisoformat(start.replace("Z", "+00:00"))
            end = (d + timedelta(minutes=float(t["duration"]))).isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    att = [Attendee(email=str(e)) for e in (t.get("participants") or []) if "@" in str(e)]
    emails = {a.email.lower() for a in att}
    names = [Attendee(name=str(s.get("name"))) for s in (t.get("speakers") or []) if s.get("name")]
    s = t.get("summary") or {}
    overview = str(s.get("overview") or s.get("short_summary") or s.get("gist") or "")
    topics = []
    bullets = tuple(_lines(s.get("shorthand_bullet") or s.get("outline")))
    if bullets:
        topics.append(("Outline", bullets))
    items = tuple(ActionItem(x) for x in _lines(s.get("action_items")))
    return Meeting(source="fireflies", source_label="Fireflies", title=str(t.get("title") or "Untitled meeting"),
                   source_id=str(t.get("id") or ""), started_at=start, ended_at=end,
                   attendees=tuple(names) + tuple(a for a in att if a.email.lower() in emails),
                   utterances=utts, summary_overview=overview, summary_topics=tuple(topics),
                   action_items=items)


def parse(path: Path) -> list[Meeting]:
    if path.suffix.lower() != ".json":
        return []
    d = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(d, dict) and "data" in d:
        d = d["data"]
    if isinstance(d, dict):
        d = d.get("transcripts") or d.get("transcript") or d
    items = d if isinstance(d, list) else [d]
    return [m for m in (_one(t) for t in items if isinstance(t, dict)) if m]
