"""CM040 iMessage source for the four-artefact conversation pipeline.

This package is the customer-install feed for the human-conversation
four-artefact spec (HR015 locked directive, 2026-05-09). It reads the
Hub Mac's iMessage ``chat.db`` (Full Disk Access already granted at
install time), threads the raw messages into per-conversation
sessions, renders a cleaned transcript plus metadata, and hands each
session to the CM048 ConversationBundle processor (``pwg-convo
process``). CM048 then emits the four artefacts under
``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

This is the product path. It does NOT use the ZeroClaw JSONL tail
(``publisher/publisher.py``) which is the legacy gamingrig personal
setup; the product reads chat.db directly under FDA on the single
Hub Mac.
"""

from .reader import (
    Conversation,
    Message,
    extract_conversations,
    extract_messages,
)
from .threader import Session, session_window, thread_messages
from .pipeline import process_imessage, run as run_pipeline

__all__ = [
    "Conversation",
    "Message",
    "Session",
    "extract_conversations",
    "extract_messages",
    "thread_messages",
    "session_window",
    "process_imessage",
    "run_pipeline",
]
