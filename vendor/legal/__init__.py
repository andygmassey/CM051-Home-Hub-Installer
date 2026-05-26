"""Versioned legal-text constants for Ostler v0.1.

This package holds the verbatim wording strings the user is shown at
consent time (Article 9 EU screen, WhatsApp risk tickbox, EU voice
gate). The Hub installer, the Rust assistant CLI, and Doctor's
"renewal needed" check all import the SAME constant from this
package, so the on-screen wording, the SHA-256 we hash, and the
text persisted to ``~/.ostler/posture/consent.json`` cannot drift.

Wording in v0.1 is marked "[DRAFT – pending legal review]" inline
where the brief calls for it. The lawyer-friend reviews copy in a
separate track; engineering ships now per
``/tmp/plan_legal_position_implementation_2026-05-02.md`` §8.

Bumping wording text:
    - Material change → bump ``WORDING_VERSION``, expect every
      existing user to see a renewal prompt on next Hub start.
    - Typo / non-material → bump ``WORDING_VERSION`` with a
      ``minor`` suffix; runtime can elect to skip the renewal.
"""
from .consent_strings import (
    ARTICLE_9_EU_CONSENT,
    EU_VOICE_SPEAKER_ID_CONSENT,
    THIRD_PARTY_DATA_NOTICE,
    WHATSAPP_UNOFFICIAL_RISK_CONSENT,
    ConsentString,
)

__all__ = [
    "ARTICLE_9_EU_CONSENT",
    "EU_VOICE_SPEAKER_ID_CONSENT",
    "THIRD_PARTY_DATA_NOTICE",
    "WHATSAPP_UNOFFICIAL_RISK_CONSENT",
    "ConsentString",
]
