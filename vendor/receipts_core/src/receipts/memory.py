"""Learn-once supplier memory. A supplier the owner confirmed once is recognised by any of its
fingerprints (normalised name, sender domain, VAT number). Stored as a dict; the caller persists it
(kv `supplier_memory`). Auto-file is allowed only when the memory is known AND the total came from a
total line AND the currency is resolved; otherwise the receipt goes to Check.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Iterable, List, Optional

from .names import normalise_supplier

_MAIL_SUB = {"mail", "email", "e", "billing", "invoice", "invoices", "receipts", "info", "noreply", "no-reply"}


def sender_domain(addr: Optional[str]) -> Optional[str]:
    """The registrable domain of an email sender, with mail/billing subdomains removed."""
    if not addr:
        return None
    m = re.search(r"[\w.+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})", addr)
    if not m:
        return None
    parts = m.group(1).lower().split(".")
    while len(parts) > 2 and parts[0] in _MAIL_SUB:
        parts = parts[1:]
    return ".".join(parts)


def fingerprints(rec: Dict[str, Any]) -> List[str]:
    out: List[str] = []
    name = normalise_supplier(rec.get("supplier"))
    if name:
        out.append(f"name:{name}")
    dom = (rec.get("sender_domain") or "").lower()
    if dom:
        out.append(f"domain:{dom}")
    vat = re.sub(r"[^A-Z0-9]", "", (rec.get("vat_number") or "").upper())
    if vat:
        out.append(f"vat:{re.sub(r'^[A-Z]{2}', '', vat)}")
    return out


def learn(store: Dict[str, Any], rec: Dict[str, Any]) -> None:
    """Record a CONFIRMED supplier under every fingerprint it has."""
    entry = {"supplier": rec.get("supplier"), "book": rec.get("book"),
             "category": rec.get("category"), "currency": rec.get("currency")}
    for fp in fingerprints(rec):
        store[fp] = entry


def recall(store: Dict[str, Any], rec: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    for fp in fingerprints(rec):
        if fp in store:
            return dict(store[fp])
    return None


def auto_file_ok(memory: Optional[Dict[str, Any]], rec: Dict[str, Any]) -> bool:
    """Known supplier, total from a total line, resolved currency, and the remembered currency agrees."""
    if not memory:
        return False
    if not rec.get("supplier") or rec.get("amount_gross") is None:
        return False
    if not rec.get("total_on_total_line"):
        return False
    cur = rec.get("currency")
    return bool(cur) and cur == memory.get("currency")
