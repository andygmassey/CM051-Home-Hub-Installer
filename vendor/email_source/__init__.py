"""Email source for the four-artefact conversation pipeline (HR015).

This package is the customer-install feed for the human-conversation
four-artefact spec (HR015 locked directive, 2026-05-09). It reads the
Hub Mac's Apple Mail store (the ``.emlx`` tree under ``~/Library/Mail``,
Full Disk Access already granted at install time), threads the raw
messages into per-conversation email threads, renders a cleaned
speaker-labelled transcript plus CM048 metadata, and hands each thread
to the CM048 ConversationBundle processor (``pwg-convo process``).
CM048 then emits the four artefacts under
``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

This is the CONVERSATION-MEMORY leg. It is deliberately separate from
the existing ``email-ingest/`` LaunchAgent (which drains Apple Mail
into an mbox and pushes email FACTS into the graph via
``pwg-email-ingest``). The two feeds read the same Apple Mail store
but write different products: the ingest tick writes graph facts, this
feed writes the four-artefact conversation bundle.

Reuse: the low-level Apple Mail primitives (``parse_emlx``,
``discover_emlx_files``) come from ``ostler_fda.apple_mail_mbox`` so
there is one Apple Mail parser on the Hub, not two. Threading,
transcript rendering, and the CM048 dispatch are this package's own.
"""

from .reader import EmailMessage, read_messages
from .threader import (
    EmailThread,
    build_metadata,
    render_transcript,
    thread_messages,
)
from .pipeline import process_email, run as run_pipeline

__all__ = [
    "EmailMessage",
    "EmailThread",
    "read_messages",
    "thread_messages",
    "render_transcript",
    "build_metadata",
    "process_email",
    "run_pipeline",
]
