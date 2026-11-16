"""Receipt record, status rules and field names.

A receipt is `ok` only when every required field clears THRESHOLD and the book is
decided. Anything else goes to the Check queue. A field with no value has
confidence 0.0, so a null can never read as "checked and fine".
"""

from __future__ import annotations

from typing import Any, Dict, List

SCHEMA = "receipts.v1"
THRESHOLD = 0.80        # field confidence needed for ok
BOOK_THRESHOLD = 0.80   # model book confidence needed to file; below it the receipt is Check
# The lens may only PRE-FILL until the calibration bar passes (tests/receipts_calibrate.py: seed 1 found no
# passing pair, 2026-11-15). While False, a lens answer never files, never marks ok, and goes to Check.
LENS_CAN_FILE = False
REQUIRED_FIELDS = ("date", "supplier", "amount_gross", "currency")
SCORED_FIELDS = ("date", "supplier", "amount_gross", "currency", "tax_amount", "book")
BOOKS = ("business", "personal", "unsure")
SOURCES = ("photo", "share", "folder", "email")
# Best file first when duplicates collide: a text PDF beats a photo beats an email body.
SOURCE_RANK = {"folder": 0, "share": 1, "photo": 2, "email": 3}


def new_record(**kw: Any) -> Dict[str, Any]:
    rec: Dict[str, Any] = {
        "id": kw.get("id"),
        "book_id": kw.get("book_id"),
        "date": None,
        "supplier": None,
        "description": None,
        "category": None,
        "business_use_pct": 100,
        "amount_gross": None,
        "currency": None,
        "tax_amount": None,
        "tax_rate": None,
        "tax_reclaimable": False,
        "supplier_tax_no": None,
        "amount_home": None,
        "fx_rate": None,
        "fx_source": None,
        "payment_method": None,
        "file": None,
        "file_sha256": None,
        "source": kw.get("source"),
        "status": "check",
        "reasons": [],
        "confidence": {},
        "statement_line_id": None,
        "notes": None,
        "edited_by_owner": [],
        "confirmed_by_owner": {},          # field -> ISO time, set only by the owner's own confirm tap
        "created_at": kw.get("created_at"),
        "duplicates": [],
        "doc_numbers": [],                 # primary document number first, then the others printed on it
        "related_ids": [],                 # linked, never merged (an order acknowledgement and its invoice)
    }
    rec.update({k: v for k, v in kw.items() if k in rec})
    return rec


def decide_status(rec: Dict[str, Any], *, extra_reasons: List[str] = ()) -> Dict[str, Any]:
    """Set `status` and `reasons` from per-field confidence and the book decision."""
    conf = rec.get("confidence") or {}
    reasons = list(extra_reasons)
    for f in REQUIRED_FIELDS:
        if float(conf.get(f, 0.0)) < THRESHOLD:
            reasons.append(f"low_conf:{f}")
    if rec.get("book_decision") == "unsure" or rec.get("book_id") is None:
        reasons.append("book_unsure")
    if rec.get("duplicates_pending"):
        reasons.append("possible_duplicate")
    rec["reasons"] = sorted(set(reasons))
    rec["status"] = "ok" if not rec["reasons"] else "check"
    return rec
