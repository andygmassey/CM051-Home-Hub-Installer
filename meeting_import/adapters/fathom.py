"""Fathom: the owner's own meetings, saved from the Fathom API.

Fathom's documented, self-serve route out is a per-user API key (User
Settings > API Access; developers.fathom.ai/quickstart) and
``GET https://api.fathom.ai/external/v1/meetings?include_transcript=true
&include_summary=true&include_action_items=true``. The owner saves the
response to a file and drops it in ``Imports/fathom/``; Ostler never calls
Fathom. Field names CONFIRMED from Fathom's own OpenAPI document
(developers.fathom.ai/api-reference/openapi.yaml, read 2026-10-18):
- list page ``{"items": [Meeting], "next_cursor", "limit"}`` (also a bare
  Meeting or a list of them);
- ``transcript[]``: ``{speaker: {display_name, matched_calendar_invitee_email},
  text, timestamp: "HH:MM:SS"}`` relative to the start;
- ``default_summary.markdown_formatted``; ``action_items[]``:
  ``{description, completed, assignee: {name, email}}``;
- ``calendar_invitees[]``: ``{name, email, is_external}``; ``recorded_by``.
A ``{"transcript": [...]}`` response from ``/recordings/{id}/transcript``
alone carries no title or date: it imports with the file name and date.

Completed action items are NOT imported as open todos.
No Fathom in-app file export is documented by Fathom: CANNOT-VERIFY, not read.
"""
from __future__ import annotations

import json
from pathlib import Path

from ..model import ActionItem, Attendee, Meeting, Utterance
from . import transcript_files as tf
from .granola import split_markdown


def _hms(v):
    try:
        h, m, s = (int(x) for x in str(v).split(":"))
        return float(h * 3600 + m * 60 + s)
    except (TypeError, ValueError):
        return None


def _utts(items) -> tuple[Utterance, ...]:
    out = []
    for x in items or []:
        if not (isinstance(x, dict) and x.get("text")):
            continue
        sp = x.get("speaker")
        name = sp.get("display_name") if isinstance(sp, dict) else sp
        out.append(Utterance(str(name or "Unknown"), str(x["text"]), _hms(x.get("timestamp"))))
    return tuple(out)


def _meeting(d: dict, path: Path) -> Meeting | None:
    utts = _utts(d.get("transcript"))
    summ = d.get("default_summary") if isinstance(d.get("default_summary"), dict) else {}
    md = str(summ.get("markdown_formatted") or "")
    items = tuple(ActionItem(str(a["description"]), assignee=str((a.get("assignee") or {}).get("name") or ""))
                  for a in d.get("action_items") or []
                  if isinstance(a, dict) and a.get("description") and not a.get("completed"))
    if not (utts or md.strip() or items):
        return None
    ov, topics, extra_items = split_markdown(md)
    att, seen = [], set()
    for a in d.get("calendar_invitees") or []:
        if isinstance(a, dict) and (a.get("email") or a.get("name")):
            k = str(a.get("email") or a.get("name")).lower()
            if k not in seen:
                seen.add(k)
                att.append(Attendee(str(a.get("name") or ""), str(a.get("email") or "")))
    return Meeting(source="fathom", source_label="Fathom",
                   title=str(d.get("title") or d.get("meeting_title") or tf.title_from(path)),
                   source_id=str(d.get("recording_id") or ""),
                   started_at=str(d.get("recording_start_time") or d.get("scheduled_start_time")
                                  or d.get("created_at") or tf.date_from(path)),
                   ended_at=str(d.get("recording_end_time") or d.get("scheduled_end_time") or ""),
                   attendees=tuple(att), utterances=utts, summary_overview=ov, summary_topics=topics,
                   action_items=items + tuple(ActionItem(i) for i in extra_items), source_file=path.name)


def parse(path: Path) -> list[Meeting]:
    ext = path.suffix.lower()
    if ext in (".srt", ".vtt", ".docx"):
        return tf.parse(path, source="fathom", label="Fathom")
    if ext != ".json":
        return []
    d = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(d, dict) and isinstance(d.get("items"), list):
        d = d["items"]
    rows = d if isinstance(d, list) else [d]
    known = [r for r in rows if isinstance(r, dict) and ("recording_id" in r or "transcript" in r)]
    if not known:
        raise ValueError("unrecognised Fathom JSON: no meeting or transcript object found")
    return [m for m in (_meeting(r, path) for r in known) if m]
