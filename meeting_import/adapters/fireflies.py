"""Fireflies.ai: the owner's own data, saved to a file.

1. GraphQL API JSON (owner's own key, run outside Ostler). Accepts
   ``{"data": {"transcript": {...}}}``, ``{"data": {"transcripts": [...]}}``,
   a bare Transcript object, or a list. Field names CONFIRMED from Fireflies'
   schema pages (docs.fireflies.ai/schema/transcript, /sentence, /summary,
   /meeting-attendee, read 2026-10-18): ``Sentence.start_time`` is a STRING;
   ``duration`` is minutes; ``meeting_attendees`` carry name + email;
   ``summary.action_items`` is one String.
2. Dashboard download (Meetings > open > Download; Pro plan and up):
   transcript as PDF, DOCX, SRT, CSV, JSON or MD
   (guide.fireflies.ai/articles/3319752033, read 2026-10-18). Fireflies does
   not document those layouts. SRT/VTT/DOCX go through the generic
   transcript reader (``Name: text``, ASSUMED). A dashboard JSON that is a
   list of sentence objects is read the same way as API sentences (ASSUMED).
   Any other JSON shape is REFUSED with ValueError, never imported as empty.

Action items: Fireflies groups them under a bold assignee line
(``**Name**``) with a trailing ``(mm:ss)``; the grouping is ASSUMED from the
dashboard rendering, and an ungrouped line simply has no assignee.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

from ..model import ActionItem, Attendee, Meeting, Utterance
from . import transcript_files as tf

_BOLD = re.compile(r"^\*\*(.+?)\*\*:?$")
_TRAIL_TS = re.compile(r"\s*\((?:\d+:)?\d{1,2}:\d{2}\)\s*$")


def _num(v):
    try:
        return float(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _bullets(v) -> list[str]:
    if isinstance(v, list):
        v = "\n".join(str(x) for x in v)
    out = []
    for l in str(v or "").splitlines():
        l = re.sub(r"^\s*(?:[-*•]|\d+[.)])\s*(?:\[[ xX]\]\s*)?", "", l).strip()
        if l and not _BOLD.match(l):
            out.append(_TRAIL_TS.sub("", l))
    return out


def _action_items(v) -> tuple[ActionItem, ...]:
    if isinstance(v, list):
        v = "\n".join(str(x) for x in v)
    who, out = "", []
    for raw in str(v or "").splitlines():
        line = raw.strip()
        if not line:
            continue
        b = _BOLD.match(line)
        if b:
            who = b.group(1).strip()
            continue
        text = _TRAIL_TS.sub("", re.sub(r"^\s*(?:[-*•]|\d+[.)])\s*(?:\[[ xX]\]\s*)?", "", line)).strip()
        if text:
            out.append(ActionItem(text, assignee=who))
    return tuple(out)


def _utts(sents) -> tuple[Utterance, ...]:
    return tuple(Utterance(str(s.get("speaker_name") or "Unknown"), str(s.get("text") or s.get("raw_text") or ""),
                           _num(s.get("start_time")))
                 for s in sents if isinstance(s, dict) and (s.get("text") or s.get("raw_text")))


def _attendees(t: dict) -> tuple[Attendee, ...]:
    out: list[Attendee] = []
    by_email: dict[str, int] = {}
    names: set[str] = set()
    for a in t.get("meeting_attendees") or []:
        if not isinstance(a, dict):
            continue
        n, e = str(a.get("name") or a.get("displayName") or ""), str(a.get("email") or "")
        if e and e.lower() in by_email:
            continue
        if e:
            by_email[e.lower()] = len(out)
        if n:
            names.add(n.lower())
        out.append(Attendee(n, e))
    for e in t.get("participants") or []:
        e = str(e)
        if "@" in e and e.lower() not in by_email:
            by_email[e.lower()] = len(out)
            out.append(Attendee(email=e))
    for s in t.get("speakers") or []:
        n = str((s or {}).get("name") or "") if isinstance(s, dict) else ""
        if n and n.lower() not in names:
            names.add(n.lower())
            out.append(Attendee(name=n))
    return tuple(out)


def _one(t: dict) -> Meeting | None:
    utts = _utts(t.get("sentences") or [])
    s = t.get("summary") if isinstance(t.get("summary"), dict) else {}
    if not utts and not s:
        return None
    start = str(t.get("dateString") or "")
    if not start and _num(t.get("date")):
        start = datetime.fromtimestamp(_num(t["date"]) / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
    end = ""
    if _num(t.get("duration")):
        try:
            d = datetime.fromisoformat(start.replace("Z", "+00:00"))
            end = (d + timedelta(minutes=_num(t["duration"]))).isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    overview = str(s.get("overview") or s.get("short_summary") or s.get("gist") or "")
    topics = []
    bullets = tuple(_bullets(s.get("shorthand_bullet") or s.get("outline")))
    if bullets:
        topics.append(("Outline", bullets))
    if s.get("topics_discussed"):
        topics.append(("Topics discussed", tuple(_bullets(s["topics_discussed"]))))
    return Meeting(source="fireflies", source_label="Fireflies", title=str(t.get("title") or "Untitled meeting"),
                   source_id=str(t.get("id") or ""), started_at=start, ended_at=end,
                   attendees=_attendees(t), utterances=utts, summary_overview=overview,
                   summary_topics=tuple(topics), action_items=_action_items(s.get("action_items")))


def _is_transcript(d) -> bool:
    return isinstance(d, dict) and any(k in d for k in ("sentences", "summary", "dateString"))


def parse(path: Path) -> list[Meeting]:
    ext = path.suffix.lower()
    if ext in (".srt", ".vtt", ".docx"):
        return tf.parse(path, source="fireflies", label="Fireflies")
    if ext != ".json":
        return []
    d = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(d, dict) and isinstance(d.get("data"), dict):
        d = d["data"].get("transcripts") or d["data"].get("transcript")
    if isinstance(d, list) and d and all(isinstance(x, dict) and "speaker_name" in x for x in d):
        utts = _utts(d)  # dashboard JSON as a bare sentence list (ASSUMED)
        return [Meeting(source="fireflies", source_label="Fireflies", title=tf.title_from(path),
                        started_at=tf.date_from(path), utterances=utts, source_file=path.name)] if utts else []
    items = d if isinstance(d, list) else [d]
    if not any(_is_transcript(t) for t in items):
        raise ValueError("unrecognised Fireflies JSON: no transcript object found")
    return [m for m in (_one(t) for t in items if _is_transcript(t)) if m]
