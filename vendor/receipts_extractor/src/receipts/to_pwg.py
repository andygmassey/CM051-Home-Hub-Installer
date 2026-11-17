"""Normalise receipts into the row shapes the PWG importers emit.

Food orders use the ``food_order`` shape of the Deliveroo, DoorDash, Just Eat
and Grubhub parsers (``extra.type == "food_order"``), so the local enrichment
stage consumes them unchanged. Money rows reuse the Amazon ``spend_record``
shape. Rides reuse the Uber ``trip_record`` shape. Everything carries
``source == "email_receipt"`` (accepted by PWG's EmailParser) and
``extra.channel == "email"``.

Privacy: only extracted fields are written. No body, no address (coarse area
only), no card data. The message-id is replaced by a hash. Level is L1
(PWG ``FINANCIAL_LEVEL``), the strictest level in use for money and location.
"""

from __future__ import annotations

import uuid
from typing import Any, Dict, Iterable, List, Optional

from .privacy import FINANCIAL_LEVEL, scrub_row

SOURCE = "email_receipt"
_NS = uuid.uuid5(uuid.NAMESPACE_DNS, "receipt.email-intelligence.ostler")
LEDGER_CATEGORY = {"grocery": "groceries", "retail": "shopping", "travel": "travel",
                   "ticket": "entertainment"}


def email_id(message_id: str) -> str:
    """Stable opaque id for a message. The real Message-ID never leaves the device store."""
    return str(uuid.uuid5(_NS, message_id))


def _clean(d: Dict[str, Any]) -> Dict[str, Any]:
    return {k: v for k, v in d.items() if v is not None and v != [] and v != ""}


def _row(r: Dict[str, Any], subject: str, category: str, pref_type: str, strength: float,
         extra: Dict[str, Any]) -> Dict[str, Any]:
    extra = _clean({**extra, "channel": "email", "service": r.get("service"),
                    "merchant": r.get("merchant"), "order_id": r.get("order_id"),
                    "extraction": r.get("method")})
    return {
        "subject": subject,
        "preference_type": pref_type,
        "category": category,
        "strength": strength,
        "source": SOURCE,
        "observed_at": (r.get("occurred_at") or "") + (":00" if r.get("occurred_at") and len(r["occurred_at"]) == 16 else ""),
        "compartment_level": FINANCIAL_LEVEL,
        "email_id": email_id(r["message_id"]) + ("|" + extra["type"] if extra.get("type") else ""),
        "extra": extra,
    }


def to_rows(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """PWG-shaped rows for one receipt dict (``Receipt.to_dict()`` output)."""
    rows = _build_rows(r)
    for row in rows:
        _drop_sensitive(row)
    return rows


def _build_rows(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    cat = r["category"]
    rows: List[Dict[str, Any]] = []
    cur = r.get("currency")

    if cat == "food_delivery" and r.get("restaurant"):
        items = [{"name": i["name"], "quantity": i.get("quantity") or 1, "price": i.get("price")}
                 for i in r.get("items") or []]
        names = ", ".join(i["name"] for i in items[:3])
        rows.append(_row(r, f"Order from {r['restaurant']}" + (f": {names}" if names else ""),
                         "food", "Experience", 0.25, {
            "type": "food_order", "restaurant": r["restaurant"], "items": items,
            "item_count": sum(i["quantity"] for i in items), "currency": cur,
            "ordered_at": r.get("occurred_at"), "total": r.get("total"),
            "subtotal": r.get("subtotal"), "delivery_fee": r.get("delivery_fee"),
            "service_fee": r.get("service_fee"), "tip": r.get("tip"), "area": r.get("area")}))
        return rows

    if cat in ("grocery", "retail", "ticket") and r.get("total") is not None:
        rows.append(_row(r, f"{LEDGER_CATEGORY[cat].capitalize()} spend at {r['merchant']}",
                         "spend", "Experience", 0.2, {
            "type": "spend_record", "vendor": (r.get("service") or r["merchant"]).lower(),
            "spend_category": LEDGER_CATEGORY[cat], "ledger_category": LEDGER_CATEGORY[cat],
            "amount": r["total"], "currency": cur or "USD", "quantity": sum(
                i.get("quantity") or 1 for i in r.get("items") or []) or None,
            "item_names": [i["name"] for i in (r.get("items") or [])][:20] or None}))

    if cat == "ticket" and r.get("event_name"):
        rows.append(_row(r, f"Tickets: {r['event_name']}", "entertainment", "Experience", 0.4, {
            "type": "ticket_booking", "event_name": r["event_name"], "venue": r.get("venue"),
            "event_date": r.get("event_date"), "ticket_count": r.get("ticket_count"),
            "total": r.get("total"), "currency": cur}))

    if cat == "travel":
        if r.get("travel_kind") == "ride" and r.get("city") and r.get("occurred_at"):
            ts = r["occurred_at"].replace("T", " ")[:16]
            row = _row(r, f"Uber trip in {r['city']}", "transportation", "Experience", 0.2, {
                "type": "trip_record", "city": r["city"], "timestamp": ts, "fare": r.get("total"),
                "currency": cur, "distance_miles": r.get("distance_miles"),
                "origin_area": r.get("origin"), "destination_area": r.get("destination")})
            rows.append(row)
        elif r.get("travel_kind") != "ride":
            dest = r.get("destination") or r.get("origin")
            if dest:
                rows.append(_row(r, f"Trip: {dest}", "travel", "Experience", 0.4, {
                    "type": "travel_booking", "travel_kind": r.get("travel_kind"),
                    "origin": r.get("origin"), "destination": r.get("destination"),
                    "start_date": r.get("start_date"), "end_date": r.get("end_date"),
                    "carrier": r.get("carrier"), "total": r.get("total"), "currency": cur}))
        if r.get("total") is not None:
            rows.append(_row(r, f"Travel spend at {r['merchant']}", "spend", "Experience", 0.2, {
                "type": "spend_record", "vendor": (r.get("service") or r["merchant"]).lower(),
                "spend_category": "travel", "ledger_category": "travel",
                "amount": r["total"], "currency": cur or "USD"}))

    if cat == "subscription":
        price = r.get("price")
        if price is not None and r.get("plan") or r.get("plan"):
            plan = r.get("plan") or r["merchant"]
            rows.append(_row(r, f"Subscription: {r['merchant']} {plan}", "service", "Experience", 0.4, {
                "type": "subscription_record", "subscription_name": f"{r['merchant']} {plan}".strip(),
                "plan": plan, "period": r.get("period"), "price": price, "old_price": r.get("old_price"),
                "currency": cur, "event": r.get("event"), "renewal_date": r.get("renewal_date"),
                "cancel_date": r.get("cancel_date")}))

    if cat == "restaurant_booking" and r.get("restaurant"):
        rows.append(_row(r, f"Booked a table at {r['restaurant']}", "dining", "Experience", 0.3, {
            "type": "restaurant_booking", "restaurant": r["restaurant"],
            "party_size": r.get("party_size"), "booking_at": r.get("booking_at")}))

    return rows


def _drop_sensitive(row: Dict[str, Any]) -> None:
    """Last line of defence: scrub free text in the finished row."""
    cleaned = scrub_row({"subject": row["subject"], **row["extra"]})
    cleaned.pop("notes", None)
    row["subject"] = cleaned.pop("subject") or "Receipt"
    row["extra"] = {k: v for k, v in cleaned.items() if v is not None}


def export(receipts: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for r in sorted(receipts, key=lambda x: (x.get("occurred_at") or "", x["message_id"])):
        out.extend(to_rows(r))
    return out
