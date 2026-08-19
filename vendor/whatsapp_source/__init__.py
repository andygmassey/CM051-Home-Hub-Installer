"""WhatsApp source for the four-artefact conversation pipeline (HR015).

This package is the customer-install feed for the human-conversation
four-artefact spec (HR015 locked directive, 2026-05-09). It reads the
Hub Mac's WhatsApp Desktop store (``ChatStorage.sqlite`` under
``~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/``, Full
Disk Access already granted at install time), pulls the message bodies
for the in-tier chats (T1 DM + T2 intimate/active group), renders a
cleaned speaker-labelled transcript plus CM048 metadata, and hands each
chat to the CM048 ConversationBundle processor (``pwg-convo process``).
CM048 then emits the four artefacts under
``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

This is the CONVERSATION-MEMORY leg for WhatsApp. It is deliberately
separate from the existing ``ostler_fda.whatsapp_history`` metadata
extractor (the ``hydrate_whatsapp`` install sub-phase), which reads chat
metadata + participant JIDs only and pushes people-graph FACTS. The two
feeds read the same ChatStorage.sqlite but write different products:
the hydrate leg writes graph facts (Person + lastContactWhatsApp +
tier), this feed writes the four-artefact conversation bundle WITH
bodies.

Reuse: the low-level WhatsApp primitives (the read-only open, the
three-tier classifier, the Mac-epoch conversion, the JID filter) come
from ``ostler_fda.whatsapp_history`` so there is one WhatsApp reader on
the Hub and one set of tier threshold lock-ins. Body extraction,
transcript rendering, and the CM048 dispatch are this package's own.

Privacy: T3 large-passive chats are never read (no body pull at all).
The L1/L2/L3 ladder is applied by CM048 from the tier + the operator's
contact/group labels: a family / partner / sensitive label escalates a
thread to L3 so its bundle lands on disk but never reaches Qdrant /
Oxigraph.
"""

from .reader import (
    WhatsAppConversation,
    WhatsAppUtterance,
    read_chats,
)
from .renderer import build_metadata, conversation_id_for, render_transcript
from .pipeline import process_whatsapp, run as run_pipeline

__all__ = [
    "WhatsAppConversation",
    "WhatsAppUtterance",
    "read_chats",
    "render_transcript",
    "build_metadata",
    "conversation_id_for",
    "process_whatsapp",
    "run_pipeline",
]
