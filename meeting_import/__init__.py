"""Meeting-history importer (Lane 31).

Brings a new owner's EXISTING meeting history (Granola, Otter.ai,
Fireflies.ai, and generic Zoom / Teams / Meet transcript files) across on
day one, locally. One adapter per source maps into a source-neutral
``Meeting``; ``bundle`` hands it to the existing CM048 four-artefact writer.

Feature flag: OFF. Nothing here runs unless ``OSTLER_MEETING_IMPORT_ENABLED=1``.
Nothing here touches the network.
"""
from .model import ActionItem, Attendee, Meeting, Utterance

__all__ = ["ActionItem", "Attendee", "Meeting", "Utterance"]
