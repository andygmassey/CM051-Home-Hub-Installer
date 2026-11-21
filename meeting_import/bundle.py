"""Meeting -> CM048 four-artefact bundle. Reuses, never re-implements.

Goes through ``channel_adapter.make_bundle`` with ``channel="spoken"`` so a
meeting gets exactly the CM042 call defaults: L2 unless the owner marks it
private (vendor/cm048_pipeline/src/channel_adapter.py:98-128,
privacy.py:_CHANNEL_DEFAULTS). Written by ``conversation_writer.
write_conversation`` (conversation_writer.py:205), which owns the folder
``<root>/<YYYY-MM-DD>/<slug>-<short-id>/`` and summary.md / transcript.md /
todos.md with the metadata as frontmatter on each.
"""
from __future__ import annotations

import dataclasses
import hashlib
import os
import sys
from pathlib import Path
from typing import Optional

_CM048 = Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"
if str(_CM048) not in sys.path and _CM048.is_dir():
    sys.path.insert(0, str(_CM048))

from src import channel_adapter, conversation_writer  # noqa: E402
from src.bundle_extractor import BundleExtraction  # noqa: E402

from .model import Meeting  # noqa: E402
from .people import LinkedAttendee  # noqa: E402

IMPORT_SCHEMA = 1


def conversation_id(m: Meeting) -> str:
    """Stable per source meeting. The source's own id when it has one, else a
    hash of title + start + the first 500 chars of transcript, so the same
    export re-imported maps to the same folder. (An edited re-export of an
    id-less file is a new meeting: documented limitation.)"""
    if m.source_id:
        basis = f"{m.source}\x1f{m.source_id}"
    else:
        head = "\n".join(f"{u.speaker}:{u.text}" for u in m.utterances)[:500]
        basis = f"{m.source}\x1f{m.title.strip().lower()}\x1f{m.started_at}\x1f{head}"
    return f"meeting-{m.source}-{hashlib.sha1(basis.encode()).hexdigest()[:16]}"


def _clock(s: Optional[float]) -> str:
    if s is None:
        return ""
    s = int(s)
    return f"[{s // 3600:d}:{s % 3600 // 60:02d}:{s % 60:02d}] " if s >= 3600 else f"[{s // 60:02d}:{s % 60:02d}] "


def render_transcript(m: Meeting) -> str:
    return "\n\n".join(f"{_clock(u.start_s)}**{u.speaker or 'Unknown'}:** {u.text.strip()}"
                       for u in m.utterances if u.text.strip())


def _owner_for(assignee: str, owner_name: str, links: list[LinkedAttendee]) -> str:
    a = assignee.strip()
    if not a:
        return "unassigned"
    if a.lower() in ("me", "you", "i") or (owner_name and a.lower() == owner_name.lower()):
        return "user"
    for l in links:
        if a.lower() in (l.name.lower(), l.email.lower()):
            return l.name
    return a


def build(m: Meeting, links: list[LinkedAttendee], *, owner_name: str = "",
          privacy_level: Optional[str] = None):
    label = m.source_label
    cid = conversation_id(m)
    topics = [{"name": f"{n} (from {label})", "points": list(p)} for n, p in m.summary_topics]
    overview = (f"From {label}: {m.summary_overview.strip()}" if m.summary_overview.strip()
                else f"{label} supplied no summary for this meeting. The transcript is in transcript.md."
                if not topics else f"From {label}: see the topics below.")
    todos = [{"text": a.text, "owner": _owner_for(a.assignee, owner_name, links),
              "deadline": a.deadline, "source_anchor": f"from {label}"}
             for a in m.action_items]
    # Raw attendee names (not resolved ones) feed participants, so the folder
    # slug cannot change when a person is linked later: re-import stays idempotent.
    parts = [{"id": (a.name or a.email), "display": a.name or a.email, "role": "other"}
             for a in m.attendees if (a.name or a.email)]
    if owner_name:
        parts.insert(0, {"id": owner_name, "display": owner_name, "role": "user"})
    metadata = {
        "conversation_id": cid, "date": m.started_at[:10], "source": f"{m.source}_import",
        "source_app": label, "source_session_id": m.source_id or cid, "channel": "spoken",
        "participants": parts, "started_at": m.started_at,
        "ended_at": m.ended_at or m.started_at,
    }
    if privacy_level:
        metadata["privacy_level"] = privacy_level
    bundle = channel_adapter.make_bundle(
        metadata=metadata, classification=None,
        extraction=BundleExtraction(overall_summary=overview, topics=topics, todos=todos),
        transcript=render_transcript(m), privacy_level=None)
    extra = dict(bundle.extra_metadata)
    extra.update({
        "imported_from": m.source, "import_schema": IMPORT_SCHEMA, "title": m.title,
        "summary_origin": m.source if (m.summary_overview or m.summary_topics) else "none",
        "action_items_origin": m.source if m.action_items else "none",
        "attendees_linked": sum(1 for l in links if l.person_uri),
        "attendees_unlinked": sum(1 for l in links if not l.person_uri and l.how != "owner"),
    })
    for i, l in enumerate(x for x in links if x.person_uri):
        extra[f"linked_person_{i + 1}"] = l.person_uri
    return dataclasses.replace(bundle, extra_metadata=extra)


def write(bundle, *, root: Optional[Path], push_reminders: bool = False,
          reminders_db_path: Optional[Path] = None):
    """``demo_mode=True`` short-circuits the Reminders mapping DB before it is
    opened (reminders_push.py:apply_push_status_to_todos), so an import records
    nothing the assistant could push. The owner opts in with push_reminders,
    which runs the normal gate (L3 never pushed, L2 redacted titles)."""
    return conversation_writer.write_conversation(
        bundle, root=root, gist_post_fn=None,
        demo_mode=not push_reminders, reminders_db_path=reminders_db_path)
