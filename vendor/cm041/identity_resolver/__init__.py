from __future__ import annotations

from .models import MatchResult, PersonIdentity
from .normalise import normalise_email, normalise_phone
from .resolver import IdentityResolver

__all__ = [
    "IdentityResolver",
    "MatchResult",
    "PersonIdentity",
    "normalise_email",
    "normalise_phone",
]
