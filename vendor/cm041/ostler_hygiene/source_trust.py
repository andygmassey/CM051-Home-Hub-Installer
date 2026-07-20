"""The shared canonical source-trust table (MEMORY_HYGIENE_SPEC.md 2.5).

Promotes CM059's ``SOURCE_TRUST`` (interest_profile.py) to a single
canonical module so the Editor and the graph agree. Maps every CM041
``factSource`` / ``signalType`` / node-level ``source`` value and every
CM019 preference ``source`` value into one table.

Numbers are the spec's, which themselves fold in CM059's empirical
findings (csv/email/imap = 0.18 known noise; DEFAULT 0.45). The ranking
is deliberately monotonic:

    you 1.0 > user_correction 0.95 > icloud/calendar/linkedin 0.85
    > conversation(stated) 0.70 > voice(stated) 0.55
    > conversation(inferred) 0.45 > voice(inferred) 0.35 > csv 0.18

``authoritative=True`` clamps trust to 1.0 (and, in later phases,
exempts the fact from decay-driven archival). This finally ENFORCES the
authority ranking that ``schema/people.ttl`` documents but no code
applied.

Phase 1 uses trust only as a supersession tie-break guard (a newer fact
may not auto-retire a higher-trust older one). The effective-weight
product (trust * recency * corroboration) is Phase 2.
"""
from __future__ import annotations

from typing import Optional

DEFAULT_SOURCE_TRUST = 0.45

# Exact-source table. Keys are normalised (lower-case) source identifiers
# as they appear in the stores; prefix families are handled below.
SOURCE_TRUST = {
    # learning-loop confirmed / operator
    "user_asserted": 1.00,
    "you": 1.00,                    # CM059's name for the same thing
    "user_correction": 0.95,
    "manual": 0.95,
    # declared / structured
    "icloud_contacts": 0.85,
    "google_calendar": 0.85,
    "calendar": 0.85,
    "linkedin": 0.85,
    # typed / authored conversation channel (CM048)
    "conversation_memory": 0.70,        # confidence == "stated"
    # transcribed voice (CM048, Phase 2 write path; rows reserved here so
    # the table is complete per spec 2.5 / 3.7)
    "voice_conversation": 0.55,         # confidence == "stated"
    # social
    "facebook": 0.55,
    "instagram": 0.55,
    "twitter": 0.55,
    "meta": 0.40,                       # CM059 value
    # user's own notes
    "evernote": 0.60,
    # known noise (matches CM059)
    "csv": 0.18,
    "email": 0.18,
    "imap": 0.18,
}

# Prefix families: node-level pwg:source / signalType values arrive with
# suffixes ("linkedin_connections", "facebook_friends", "instagram_social",
# "whatsapp_contact", ...). First matching prefix wins.
_PREFIX_TRUST = (
    ("linkedin", 0.85),
    ("icloud", 0.85),
    ("google_calendar", 0.85),
    ("facebook", 0.55),
    ("instagram", 0.55),
    ("twitter", 0.55),
    ("whatsapp", 0.70),   # a message the user actually exchanged
    ("evernote", 0.60),
    ("email", 0.18),
    ("imap", 0.18),
    ("csv", 0.18),
)

# Trust for extraction-confidence "inferred" (vs "stated") on the two
# conversation-derived sources, per the spec table.
_INFERRED_TRUST = {
    "conversation_memory": 0.45,
    "voice_conversation": 0.35,
}


def resolve_source_trust(
    source: Optional[str],
    confidence: Optional[str] = None,
    authoritative: bool = False,
) -> float:
    """Resolve a source identifier to its trust weight in [0, 1].

    ``confidence`` is CM048's extraction confidence literal
    (``"stated"`` | ``"inferred"``) where known. Conversation-derived
    facts whose confidence is UNKNOWN are scored at the inferred
    (lower) band -- conservative on purpose: an unknown-provenance fact
    should find it harder, not easier, to retire another fact.

    ``authoritative=True`` clamps to 1.0 regardless of source.
    """
    if authoritative:
        return 1.00
    key = (source or "").strip().lower()
    if not key:
        return DEFAULT_SOURCE_TRUST
    if key in _INFERRED_TRUST and confidence != "stated":
        return _INFERRED_TRUST[key]
    if key in SOURCE_TRUST:
        return SOURCE_TRUST[key]
    for prefix, trust in _PREFIX_TRUST:
        if key.startswith(prefix):
            return trust
    return DEFAULT_SOURCE_TRUST
