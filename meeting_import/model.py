"""Source-neutral meeting shape every adapter maps into."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass(frozen=True)
class Attendee:
    name: str = ""
    email: str = ""


@dataclass(frozen=True)
class Utterance:
    speaker: str
    text: str
    start_s: Optional[float] = None


@dataclass(frozen=True)
class ActionItem:
    text: str
    assignee: str = ""
    deadline: Optional[str] = None


@dataclass(frozen=True)
class Meeting:
    """One imported meeting.

    ``source`` is the stable key (``granola`` / ``otter`` / ``fireflies`` /
    ``transcript``); ``source_label`` is the customer-facing name used in
    "From Granola" labels. ``source_id`` is the source's own meeting id when
    the format carries one, else ``""`` and the importer derives a
    content-based id.
    """

    source: str
    source_label: str
    title: str
    started_at: str  # ISO 8601, UTC where known
    source_id: str = ""
    ended_at: str = ""
    attendees: tuple[Attendee, ...] = ()
    utterances: tuple[Utterance, ...] = ()
    summary_overview: str = ""
    summary_topics: tuple[tuple[str, tuple[str, ...]], ...] = ()
    action_items: tuple[ActionItem, ...] = ()
    source_file: str = ""
    extra: dict = field(default_factory=dict)
