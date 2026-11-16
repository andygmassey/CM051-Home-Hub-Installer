"""Privacy guard for receipt rows.

Rules, enforced on every row before it leaves the extractor:
  * no card numbers (full or partial digits), no CVV or expiry
  * no street addresses, email addresses or phone numbers in any value
  * delivery location is a coarse area only (postcode district or city)
  * no email body: the row model has no body field, and free text that looks
    like a block of prose is dropped

Financial rows use the strictest existing PWG level (L1, FINANCIAL_LEVEL).
"""

from __future__ import annotations

import re
from typing import Any, Dict, Optional

FINANCIAL_LEVEL = 1  # mirrors services/ingest/src/parsers/base.py FINANCIAL_LEVEL

# 13 to 19 digits, optionally grouped by space or dash. Dates and order ids
# that are plain digit runs shorter than 13 do not match.
CARD_NUMBER_RE = re.compile(r"(?<!\d)(?:\d[ -]?){13,19}(?!\d)")
CARD_HINT_RE = re.compile(
    r"(?:card|visa|mastercard|amex|maestro|debit|credit)[^\n]{0,24}?(?:ending|ends|last\s*4|\*{2,}|x{2,}|•{2,})\s*(?:in\s*)?\d{2,4}"
    r"|(?:\*{2,}|x{3,}|•{3,})\s?\d{4}\b|\bcvv\b|\bcvc\b",
    re.I,
)
STREET_RE = re.compile(
    r"\b\d{1,5}[A-Za-z]?\s+(?:[A-Z][A-Za-z'.-]*\s+){0,3}"
    r"(?:Street|St|Road|Rd|Avenue|Ave|Lane|Ln|Drive|Dr|Close|Court|Ct|Way|Place|Pl|"
    r"Terrace|Gardens|Square|Crescent|Boulevard|Blvd|Hill|Grove|Mews)\b\.?",
)
FLAT_RE = re.compile(r"\b(?:flat|apt|apartment|unit|suite|room)\s*#?\s*\w+\b", re.I)
EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
# Amazon style order ids (3-7-7 digits) are long digit runs but are not cards.
ORDER_ID_RE = re.compile(r"\b\d{3}-\d{7}-\d{7}\b")
UK_POSTCODE_RE = re.compile(r"\b([A-Z]{1,2}\d[A-Z\d]?)\s*(\d[A-Z]{2})\b")
US_ZIP_RE = re.compile(r"\b([A-Z][a-z]+(?: [A-Z][a-z]+)?),?\s+([A-Z]{2})\s+\d{5}(?:-\d{4})?\b")

_MAX_FREE_TEXT = 140


def coarse_area(address_text: Optional[str]) -> Optional[str]:
    """Reduce an address to a coarse area. Never returns street or full postcode.

    UK: outward code only ("N1"). US: "City, ST". Otherwise None. We refuse to
    guess a locality from free text, so unknown stays null.
    """
    if not address_text:
        return None
    m = UK_POSTCODE_RE.search(address_text.upper())
    if m:
        return m.group(1)
    m = US_ZIP_RE.search(address_text)
    if m:
        return f"{m.group(1)}, {m.group(2)}"
    return None


def _luhn(digits: str) -> bool:
    total, flip = 0, False
    for ch in reversed(digits):
        n = int(ch)
        if flip:
            n *= 2
            if n > 9:
                n -= 9
        total += n
        flip = not flip
    return total % 10 == 0


def is_sensitive(value: str) -> bool:
    """True if a string looks like a card number, street address, email or phone."""
    if CARD_HINT_RE.search(value):
        return True
    for m in CARD_NUMBER_RE.finditer(ORDER_ID_RE.sub("", value)):
        digits = re.sub(r"\D", "", m.group(0))
        if 13 <= len(digits) <= 19 and _luhn(digits):
            return True
    if STREET_RE.search(value) or FLAT_RE.search(value):
        return True
    if EMAIL_RE.search(value):
        return True
    return False


def _clean_value(value: Any, flags: list, path: str) -> Any:
    if isinstance(value, str):
        if is_sensitive(value) or len(value) > _MAX_FREE_TEXT or "\n" in value:
            flags.append(path)
            return None
        return value
    if isinstance(value, dict):
        return {k: _clean_value(v, flags, f"{path}.{k}") for k, v in value.items()}
    if isinstance(value, list):
        cleaned = [_clean_value(v, flags, f"{path}[{i}]") for i, v in enumerate(value)]
        # an item whose name was redacted is dropped whole, not kept nameless
        return [c for c in cleaned if c not in (None, {})
                and not (isinstance(c, dict) and "name" in c and c["name"] is None)]
    return value


def scrub_row(row: Dict[str, Any], keep: tuple = ()) -> Dict[str, Any]:
    """Return a copy of ``row`` with every sensitive string removed (set to null).

    ``keep`` names fields exempt from scrubbing (the local-only message id).
    Redactions are recorded in ``notes`` as field paths only, never the value.
    """
    flags: list = []
    out = {k: (v if k in keep else _clean_value(v, flags, k)) for k, v in row.items() if k != "notes"}
    notes = list(row.get("notes") or [])
    notes += [f"redacted:{p}" for p in flags]
    out["notes"] = notes
    return out
