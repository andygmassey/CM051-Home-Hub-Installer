"""Supplier guard: a candidate supplier that is a boilerplate label, a payment processor, or the owner.

Measured on the real set (2026-11-15): boilerplate lines ("Payment Receipt", "Due date", "VAT
Registration", "Questions? Visit ...") were the largest supplier failure; the owner's own mail subject
and processors were a smaller share. Owner terms come from book settings (kv `owner_terms`), never a
constant in code.
"""
from __future__ import annotations

import re
from typing import Iterable

PROCESSORS = ("stripe", "paddle", "paypal", "shopify", "square")

_BOILERPLATE = re.compile(
    r"^\s*(payment\s+receipt|receipt|invoice(\s+date)?|tax\s+invoice|due\s+date|date(\s+paid)?|amount(\s+paid)?"
    r"|vat\s+registration|vat\s+no|questions?\b|visit\b|from\b|to\b|bill\s+to|ship\s+to|summary|statement"
    r"|operations\s+department|p\.?\s*o\.?\s*box|order(\s+total)?|your\s+order|thank\s+you|billing\s+period"
    r"|subject\b|page\b|tel\b|www\b|customer\b|copy\b|total\b|subtotal\b|balance\b|description\b|item\b)",
    re.I,
)
_URLISH = re.compile(r"https?://|www\.|@|\.(com|net|org|io|hk|uk)\b", re.I)
# Payment and document labels, message counts, order and invoice numbers, street addresses.
_LABELLED = re.compile(
    r"^\s*(payment\s+(method|record|id|status|details)|transaction\s+(id|no|number)|\d+\s+messages?"
    r"|(order|invoice|receipt|ref(erence)?|account)\s*(no\.?|number|#|id)\b|amount\s+paid\b)", re.I)
_ADDRESS = re.compile(
    r"(\b(street|road|avenue|suite|ste|floor|flr)\b|\b[A-Z]{2}\s+\d{5}\b"
    r"|\b\d{1,5}\s+[A-Za-z]+\s+(street|road|avenue|lane|drive)\b)", re.I)
_MAIL_SUBJECT = re.compile(r"\bmail\s*-\s", re.I)


def _norm(s: str) -> str:
    return re.sub(r"[\s\W_]+", "", s or "").lower()


def is_boilerplate(name: str | None) -> bool:
    """A label or a line of boilerplate, not a merchant. Bare labels, URLs, email subjects, addresses."""
    if not name or not name.strip():
        return True
    n = name.strip()
    if _URLISH.search(n) or _MAIL_SUBJECT.search(n):
        return True
    return bool(_BOILERPLATE.match(n)) or bool(_LABELLED.match(n)) or bool(_ADDRESS.search(n))


def is_owner_or_processor(name: str | None, owner_terms: Iterable[str] = ()) -> bool:
    """True when the candidate is a payment processor, or contains one of the owner's own names."""
    if not name:
        return False
    k = _norm(name)
    if any(p in k for p in PROCESSORS):
        return True
    return any(_norm(t) and _norm(t) in k for t in owner_terms)
