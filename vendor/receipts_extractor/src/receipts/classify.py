"""Receipt versus everything else.

A message is a receipt only if it carries transaction evidence: a labelled
total, an order or booking reference, or schema.org transaction data. A known
sender is not enough, because merchants also send promotions.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .mime import ParsedMessage
from .textutil import parse_money

POS_SUBJECT = re.compile(
    r"receipt|order confirm|your (?:\w+ ){0,3}order|order with|order #|thanks for your order|thank you for your order|"
    r"booking confirm|reservation|your booking|e-?ticket|your tickets?|itinerary|"
    r"payment (?:received|confirm)|invoice|renew|price (?:is )?(?:chang|increas)|"
    r"subscription|cancel+ation|cancel+ed|your trip|your .* ride|trip with|membership|purchase",
    re.I,
)
NEG_SUBJECT = re.compile(
    r"\d+\s?% off|\boff your\b|\bdeals?\b|\bsale\b|\boffers?\b|newsletter|digest|weekly|"
    r"new in\b|don'?t miss|recommended|has shipped|out for delivery|rate your|review your|"
    r"we miss you|free delivery on|\bwin\b|\bsave\b|limited time|top picks|just for you",
    re.I,
)
TOTAL_LINE = re.compile(
    r"^[^\n]*\b(?:total|amount paid|you paid|charged|fare|new price|price)\b[^\n]*$", re.I | re.M)
REF_RE = re.compile(
    r"\b(?:order|booking|reservation|confirmation|reference|receipt|invoice|ticket)\s*"
    r"(?:(?:#|no\.?|number|id|ref(?:erence)?|code)\s*[:#]?|[:#])\s*"
    r"(?=[A-Z0-9/-]*\d)[A-Z0-9][A-Z0-9/-]{3,}", re.I)
BOOKING_WORDS = re.compile(r"table for|party of|guests?\b|seat[s]?\b|reservation (?:is )?confirmed", re.I)
TRANSACTION_TYPES = {
    "Order", "FlightReservation", "LodgingReservation", "EventReservation",
    "FoodEstablishmentReservation", "TrainReservation", "RentalCarReservation",
    "Invoice", "ReservationPackage",
}


@dataclass
class Verdict:
    is_receipt: bool
    reason: str


def _types(items) -> set:
    out = set()
    for it in items:
        t = it.get("@type")
        for x in (t if isinstance(t, list) else [t]):
            if isinstance(x, str):
                out.add(x.rsplit("/", 1)[-1])
    return out


def classify(msg: ParsedMessage) -> Verdict:
    structured = (_types(msg.jsonld) | _types(msg.microdata)) & TRANSACTION_TYPES
    neg = bool(NEG_SUBJECT.search(msg.subject))
    pos = bool(POS_SUBJECT.search(msg.subject))
    bulk = msg.headers.get("precedence", "").lower() == "bulk"

    has_total = any(parse_money(m.group(0)) for m in TOTAL_LINE.finditer(msg.text))
    has_ref = bool(REF_RE.search(msg.text) or REF_RE.search(msg.subject))
    has_booking = bool(BOOKING_WORDS.search(msg.text)) and pos

    if structured:
        if neg and not (has_total or has_ref):
            return Verdict(False, "promotional subject without transaction evidence")
        return Verdict(True, f"structured:{sorted(structured)[0]}")
    if neg and not has_ref:
        return Verdict(False, "promotional subject, no order reference")
    if bulk and not has_ref:
        return Verdict(False, "bulk mail without order reference")
    if has_total and (pos or has_ref):
        return Verdict(True, "total and order evidence")
    if has_booking and has_ref:
        return Verdict(True, "booking confirmation")
    if has_total and not pos:
        return Verdict(False, "amounts present but no receipt wording or reference")
    return Verdict(False, "no transaction evidence")
