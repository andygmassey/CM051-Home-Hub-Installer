"""Canonical privacy model for the PWG People Graph (CM041).

Single source of truth for the string ``pwg:privacyLevel`` vocabulary.

This module is intentionally self-contained (no imports from the rest of
CM041) so it can be mirrored verbatim into CM019 as a documented
no-shared-dep twin. If you change the canonical definitions or the
legacy mapping table here, mirror the identical change in the CM019 copy.

Background
----------
PWG historically carried two privacy vocabularies that were never bridged:

* Scheme A - the **string** ``pwg:privacyLevel`` of ``"L0".."L3"`` written
  by the CM041 graph writers (higher digit = MORE private).
* Scheme B - a **numeric** compartment scheme written by the CM019
  preference ingest, via ``pwg:belongsToCompartment`` pointing at named
  compartment nodes (``pwg:L2Trusted`` etc.) that were supposed to carry
  ``pwg:compartmentLevel 0..6`` (higher digit = MORE public, i.e. the
  INVERTED sense of Scheme A).

The numeric scheme is structurally dead on the live graph (the
``compartmentLevel`` predicate has zero triples), so the canonical model
is Scheme A. This module makes the string scheme the single source of
truth and provides a one-way, read-time-only mapping to interpret any
legacy numeric data.

The canonical levels (string scheme)
------------------------------------
* ``L0`` - owner-private. Never shared. The owner's own identity
  (me-card), health, finance. Most restrictive.
* ``L1`` - private. Assistant-usable; the wiki renders it only on the
  owner's OWN pages, never broadcast. Source: private channels
  (WhatsApp, iMessage, email, user-asserted facts).
* ``L2`` - trusted / publishable to the wiki. Low-sensitivity public and
  social facts (LinkedIn connections, Twitter, Facebook friend, public
  profile facts).
* ``L3`` - body-private / index-only. The fact is known and may be
  indexed, but its body is suppressed unless explicitly unredacted
  (sensitive conversations).

IMPORTANT - inverted-sense warning
----------------------------------
The digit in the NUMERIC scheme is NOT the digit in the STRING scheme.
Numeric is mapped by *sensitivity*, not by digit:

    numeric ``L2Trusted``  -> string ``"L2"``   (trusted, publishable)
    numeric ``L4Public``   -> string ``"L2"``   (public, publishable)

so a higher numeric digit (more public) can map to the SAME string level.
Never map ``compartmentLevel N`` to ``"L<N>"`` naively - use
:func:`numeric_compartment_to_string` / :data:`LEGACY_NUMERIC_NAME_TO_STRING`.
"""
from __future__ import annotations

from typing import Optional

# -- Canonical string levels --------------------------------------------------

#: The four canonical privacy levels, most-private first.
LEVEL_L0 = "L0"  # owner-private, never shared
LEVEL_L1 = "L1"  # private, assistant-usable, owner-pages only
LEVEL_L2 = "L2"  # trusted / publishable to the wiki
LEVEL_L3 = "L3"  # body-private / index-only

#: Ordered tuple, most private first.
CANONICAL_LEVELS = (LEVEL_L0, LEVEL_L1, LEVEL_L2, LEVEL_L3)

#: Levels that must NEVER be assigned to private-channel content.
#: Private-channel content errs to L1 (private), never to L2 (publishable).
PUBLISHABLE_LEVELS = frozenset({LEVEL_L2})

#: Fail-closed default when a level is unknown / malformed. We treat an
#: unrecognised value as body-private so a typo cannot accidentally
#: broadcast content. (Consumers that want owner-pages-only behaviour may
#: choose L1; this is the most-cautious single default.)
DEFAULT_UNKNOWN_LEVEL = LEVEL_L3

# -- Legacy numeric -> string mapping (READ-TIME ONLY) ------------------------

#: One-way mapping from the legacy CM019 numeric compartment NODE NAMES to
#: the canonical string level, BY SENSITIVITY. This is used solely to
#: interpret legacy numeric data at read time. New writes are string.
#:
#: Note the inverted sense: L4Public/L5Commercial/L6Broadcast are all
#: "publishable" and collapse to the trusted/publishable string "L2".
LEGACY_NUMERIC_NAME_TO_STRING = {
    "L0Personal": LEVEL_L0,
    "L1Family": LEVEL_L1,
    "L1Private": LEVEL_L1,
    "L2Trusted": LEVEL_L2,
    "L3Community": LEVEL_L3,
    "L4Public": LEVEL_L2,
    "L5Commercial": LEVEL_L2,
    "L6Broadcast": LEVEL_L2,
}

#: One-way mapping from the legacy numeric DIGIT (0..6) to the canonical
#: string level, by sensitivity. Mirrors the name table above. Provided
#: for callers that only have the integer ``compartmentLevel``.
LEGACY_NUMERIC_DIGIT_TO_STRING = {
    0: LEVEL_L0,  # L0Personal
    1: LEVEL_L1,  # L1Family / L1Private
    2: LEVEL_L2,  # L2Trusted
    3: LEVEL_L3,  # L3Community
    4: LEVEL_L2,  # L4Public      (publishable)
    5: LEVEL_L2,  # L5Commercial  (publishable)
    6: LEVEL_L2,  # L6Broadcast   (publishable)
}


def numeric_compartment_to_string(value) -> str:
    """Map a legacy numeric compartment to the canonical string level.

    ``value`` may be a compartment node name (``"L2Trusted"``, or a full
    ``pwg:`` URI ending in it), or an integer / numeric string digit
    ``0..6``. Read-time only; never call this on a write path.

    Unknown inputs fail closed to :data:`DEFAULT_UNKNOWN_LEVEL`.
    """
    if value is None:
        return DEFAULT_UNKNOWN_LEVEL

    # Integer or numeric-string digit.
    if isinstance(value, bool):
        # bool is an int subclass; reject it explicitly.
        return DEFAULT_UNKNOWN_LEVEL
    if isinstance(value, int):
        return LEGACY_NUMERIC_DIGIT_TO_STRING.get(value, DEFAULT_UNKNOWN_LEVEL)

    text = str(value).strip()
    if not text:
        return DEFAULT_UNKNOWN_LEVEL

    # Strip a namespace / URI prefix, keep the trailing local name.
    local = text.rsplit("#", 1)[-1].rsplit("/", 1)[-1]

    if local in LEGACY_NUMERIC_NAME_TO_STRING:
        return LEGACY_NUMERIC_NAME_TO_STRING[local]

    if local.isdigit():
        return LEGACY_NUMERIC_DIGIT_TO_STRING.get(int(local), DEFAULT_UNKNOWN_LEVEL)

    return DEFAULT_UNKNOWN_LEVEL


def normalise_level(value) -> str:
    """Return a valid canonical string level, failing closed on anything else.

    Accepts an existing canonical string (``"L0".."L3"``, case-insensitive)
    and returns it normalised. Anything unrecognised -> the fail-closed
    :data:`DEFAULT_UNKNOWN_LEVEL`.
    """
    if value is None:
        return DEFAULT_UNKNOWN_LEVEL
    text = str(value).strip().upper()
    if text in CANONICAL_LEVELS:
        return text
    return DEFAULT_UNKNOWN_LEVEL


# -- Type + source -> level rule ----------------------------------------------

#: Provenance sources treated as PRIVATE channels. Content from these MUST
#: err to L1 (private), never L2 (publishable). Matched case-insensitively
#: as a substring of the source string so e.g. "whatsapp_contact",
#: "linkedin_messaging", "user_asserted" all classify correctly.
PRIVATE_CHANNEL_SOURCE_MARKERS = (
    "whatsapp",
    "imessage",
    "email",
    "user_asserted",
    "linkedin_messaging",  # message CONTENT, not the public connection
    "linkedin_message",
)

#: Provenance sources treated as PUBLIC / SOCIAL channels. "We are
#: connected" signals - low sensitivity, publishable -> L2.
PUBLIC_SOCIAL_SOURCE_MARKERS = (
    "linkedin_connection",
    "linkedin_career",
    "linkedin_position",
    "linkedin_endorsement",
    "linkedin_recommendation",
    "twitter",
    "facebook_friend",
    "facebook_event",
    "instagram",
    "google_calendar",
)

#: Tag / domain markers that force the most restrictive levels regardless
#: of source. Health and finance content is owner-private (L0).
SENSITIVE_OWNER_PRIVATE_MARKERS = (
    "health",
    "medical",
    "finance",
    "financial",
    "bank",
)


def _matches_any(haystack: str, markers) -> bool:
    return any(m in haystack for m in markers)


def level_for(rdf_type: Optional[str] = None,
              source: Optional[str] = None,
              tags=None) -> str:
    """Pick the canonical privacy level for a node from its type + source.

    This is the single rule used both by the write-time taggers (new nodes
    born tagged) and by the one-off backfill pass (existing untagged nodes).
    Keeping one function means the backfill and the writers can never drift.

    Rules, in priority order:

    1. Health / finance markers (in ``source`` or ``tags``) -> ``L0``.
    2. Private-channel source (WhatsApp / iMessage / email / user-asserted /
       LinkedIn message content) -> ``L1``. ERRS PRIVATE: a private channel
       is never publishable.
    3. Public / social source (LinkedIn connection/career, Twitter,
       Facebook friend, Instagram, calendar) -> ``L2``.
    4. Unknown source -> fail closed to ``L1`` (private, owner-pages only),
       NOT L2. An untagged node of unknown provenance must not broadcast.

    ``rdf_type`` is accepted for symmetry and future type-specific rules but
    the current ruleset keys on source + tags; it is used only to keep the
    signature stable for callers.
    """
    src = (source or "").strip().lower()
    tag_text = ""
    if tags:
        if isinstance(tags, str):
            tag_text = tags.lower()
        else:
            tag_text = " ".join(str(t) for t in tags).lower()

    combined = f"{src} {tag_text}".strip()

    # 1. Sensitive owner-private (health / finance).
    if _matches_any(combined, SENSITIVE_OWNER_PRIVATE_MARKERS):
        return LEVEL_L0

    # 2. Private channels -> L1 (never L2).
    if _matches_any(src, PRIVATE_CHANNEL_SOURCE_MARKERS):
        return LEVEL_L1

    # 3. Public / social -> L2.
    if _matches_any(src, PUBLIC_SOCIAL_SOURCE_MARKERS):
        return LEVEL_L2

    # 4. Unknown provenance -> fail closed to private (owner-pages only).
    return LEVEL_L1
