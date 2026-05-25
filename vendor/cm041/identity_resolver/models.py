from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class PersonIdentity:
    display_name: str
    given_name: Optional[str] = None
    family_name: Optional[str] = None
    organization: Optional[str] = None
    phones: list[str] = field(default_factory=list)
    emails: list[str] = field(default_factory=list)
    whatsapp_lids: list[str] = field(default_factory=list)
    icloud_uid: Optional[str] = None
    linkedin_url: Optional[str] = None


@dataclass
class MatchResult:
    person_uri: Optional[str]
    match_type: str  # "exact_identifier", "cross_identifier", "fuzzy_name", "new"
    confidence: float
    details: str
