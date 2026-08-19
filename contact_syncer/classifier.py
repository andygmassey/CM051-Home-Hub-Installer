"""Contact classification: person, business, or unclassified."""
from __future__ import annotations

import re
from typing import Dict

# Case-insensitive patterns that strongly suggest a business / non-person contact
_BUSINESS_PATTERNS = re.compile(
    r"\b("
    r"ltd|limited|inc|corp|corporation|restaurant|hotel|hotline|"
    r"service|services|centre|center|clinic|hospital|bank|insurance|"
    r"company|group|foundation|association|institute|ministry|"
    r"embassy|consulate|government|authority|agency"
    r")\b",
    re.IGNORECASE,
)


def classify_contact(parsed: Dict) -> str:
    """Classify a parsed vCard dict as ``"person"``, ``"business"``, or ``"unclassified"``.

    Rules
    -----
    * **Business** if the contact has an ORG but no given_name AND no
      family_name, OR if the formatted name matches common business
      patterns.
    * **Person** if the contact has both given_name and family_name, or has
      a birthday.
    * **Unclassified** otherwise.
    """
    fn = parsed.get("fn") or ""
    given_name = parsed.get("given_name")
    family_name = parsed.get("family_name")
    org = parsed.get("org")
    birthday = parsed.get("birthday")

    # --- Business checks ---
    # Has ORG but no structured name at all
    if org and not given_name and not family_name:
        return "business"

    # FN matches business patterns
    if fn and _BUSINESS_PATTERNS.search(fn):
        return "business"

    # --- Person checks ---
    if given_name and family_name:
        return "person"

    if birthday:
        return "person"

    return "unclassified"
