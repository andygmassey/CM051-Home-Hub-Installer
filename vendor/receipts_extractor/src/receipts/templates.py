"""Deterministic per-merchant templates.

Each template reads the line text of one email (table cells are tab separated)
and returns a partial Receipt dict. Anything the layout does not state stays
None; nothing is guessed. Delivery addresses are reduced to a coarse area and
the raw address is dropped on the spot.
"""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any, Callable, Dict, List, Optional

from .merchants import Merchant
from .mime import ParsedMessage
from .privacy import coarse_area
from .textutil import (iso, iso_date, labelled, labelled_money, parse_datetime, parse_money)

_SUMMARY = re.compile(
    r"^(?:sub-?total|total|order total|items total|delivery|delivery fee|delivery charge|service fee|"
    r"booking fee|tip|dasher tip|tax|vat|cleaning fee|trip fare|paid|discount|promo|payment|"
    r"driver tip|bag charge|fees?)\b", re.I)
_QTY_PREFIX = re.compile(r"^(\d+)\s*[x×]\s*(.+)$", re.I)
_QTY_SUFFIX = re.compile(r"^(.+?)\s*[x×]\s*(\d+)$", re.I)
_QTY_CELL = re.compile(r"^(?:qty|quantity)\s*[:.]?\s*(\d+)$", re.I)


def parse_items(text: str) -> List[Dict[str, Any]]:
    """Line items: ``2 x Name | £9.00``, ``1 | Name | $4.00``, ``Name | Qty 2 | £3.50``.

    ``price`` is the line price as printed (quantity already included).
    """
    items: List[Dict[str, Any]] = []
    for line in text.split("\n"):
        cells = [c.strip() for c in line.split("\t") if c.strip()]
        if len(cells) < 2 or not parse_money(cells[-1]):
            continue
        if _SUMMARY.match(cells[0]) or re.match(r"^[£$€¥]", cells[0]):
            continue
        price = parse_money(cells[-1])[0]
        qty, name = None, None
        if len(cells) == 3 and cells[0].isdigit():
            qty, name = int(cells[0]), cells[1]
        elif len(cells) == 3 and _QTY_CELL.match(cells[1]):
            qty, name = int(_QTY_CELL.match(cells[1]).group(1)), cells[0]
        elif len(cells) == 2:
            m = _QTY_PREFIX.match(cells[0])
            if m:
                qty, name = int(m.group(1)), m.group(2).strip()
        if not name:
            continue
        items.append({"name": name, "quantity": qty or 1, "price": price})
    return items


def _money(text: str, labels: List[str]):
    r = labelled_money(text, labels)
    return r[0] if r else None


def _when(text: str, labels: List[str], dayfirst: bool) -> Optional[datetime]:
    v = labelled(text, labels)
    return parse_datetime(v, dayfirst) if v else None


def _combine(text: str, date_labels: List[str], time_labels: List[str], dayfirst: bool) -> Optional[datetime]:
    v = labelled(text, date_labels)
    if not v:
        return None
    t = labelled(text, time_labels) if time_labels else None
    if t and not re.search(r"\d{1,2}:\d{2}", v):
        v = f"{v} {t}"
    return parse_datetime(v, dayfirst)


def _currency(text: str, default: Optional[str]) -> Optional[str]:
    for line in text.split("\n"):
        m = parse_money(line)
        if m:
            return m[1]
    return default


def _base(msg: ParsedMessage, m: Merchant, when: Optional[datetime], notes: List[str]) -> Dict[str, Any]:
    out: Dict[str, Any] = {"merchant": m.name, "service": m.service, "category": m.category}
    if when is None and msg.date is not None:
        when = msg.date
        notes.append("date:header")
    out["occurred_at"] = iso(when)
    return out


def _fees(text: str) -> Dict[str, Any]:
    return {
        "subtotal": _money(text, [r"sub-?total", r"items total"]),
        "delivery_fee": _money(text, [r"delivery(?: fee| charge)?"]),
        "service_fee": _money(text, [r"service fee"]),
        "tip": _money(text, [r"dasher tip", r"driver tip", r"tip"]),
    }


_TOTAL_LABELS = [r"order total", r"total paid", r"total price", r"total charged",
                 r"total(?: \([A-Z]{3}\))?"]


# --------------------------------------------------------------------- food and groceries
def _basket(msg, m, cfg) -> Dict[str, Any]:
    t = msg.text
    notes: List[str] = []
    when = _when(t, cfg["when"], m.dayfirst)
    out = _base(msg, m, when, notes)
    rest = None
    if cfg.get("restaurant_label"):
        rest = labelled(t, cfg["restaurant_label"])
    if not rest and cfg.get("restaurant_rx"):
        for rx in cfg["restaurant_rx"]:
            mm = re.search(rx, t + "\n" + msg.subject, re.I | re.M)
            if mm:
                rest = mm.group(1).strip().rstrip(".")
                break
    oid = None
    if cfg.get("order_label"):
        oid = labelled(t, cfg["order_label"])
    if not oid and cfg.get("order_rx"):
        mm = re.search(cfg["order_rx"], t, re.I)
        oid = mm.group(1) if mm else None
    addr = labelled(t, [r"delivery address", r"deliver to", r"ship to", r"delivered to"])
    total = _money(t, _TOTAL_LABELS)
    out.update(
        restaurant=rest if m.category == "food_delivery" else None,
        order_id=oid, area=coarse_area(addr),
        currency=_currency(t, m.currency), total=total,
        items=parse_items(t), notes=notes, **_fees(t),
    )
    return out


_FOOD = {
    "deliveroo": dict(when=[r"ordered"], restaurant_label=[r"order from"], order_label=[r"order number"]),
    "ubereats": dict(when=[r"ordered"], restaurant_rx=[r"receipt for (.+)$", r"order with (.+)$"]),
    "doordash": dict(when=[r"order placed"], restaurant_rx=[r"your order from (.+?) is confirmed"],
                     order_label=[r"order number"]),
    "justeat": dict(when=[r"ordered at"], restaurant_label=[r"restaurant"], order_label=[r"order ref"]),
    "tesco": dict(when=[r"order placed"], order_label=[r"order number"]),
    "instacart": dict(when=[r"delivered"], order_label=[r"order #"]),
    "amazon": dict(when=[r"order placed", r"ordered on"], order_rx=r"order\s*#\s*([\d-]{10,})"),
}


def _food_template(key: str):
    def run(msg: ParsedMessage, m: Merchant) -> Dict[str, Any]:
        return _basket(msg, m, _FOOD[key])
    return run


# --------------------------------------------------------------------- travel
def _ba(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, _when(t, [r"date of issue"], True), notes)
    out.update(
        travel_kind="flight", order_id=labelled(t, [r"booking reference"]),
        origin=labelled(t, [r"from"]), destination=labelled(t, [r"to"]),
        start_date=iso_date(_when(t, [r"departs"], True)),
        end_date=iso_date(_when(t, [r"return departs"], True)),
        carrier="British Airways", total=_money(t, _TOTAL_LABELS), currency=_currency(t, m.currency),
        notes=notes)
    return out


def _airbnb(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, None, notes)
    out.update(
        travel_kind="lodging", order_id=labelled(t, [r"confirmation code"]),
        destination=labelled(t, [r"city"]),
        start_date=iso_date(_when(t, [r"check-?in"], True)),
        end_date=iso_date(_when(t, [r"check-?out"], True)),
        total=_money(t, _TOTAL_LABELS), currency=_currency(t, m.currency), notes=notes)
    return out


def _uber(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, _when(t, [r"pickup time", r"date"], True), notes)
    dist = re.search(r"distance\s*[:\t]\s*([\d.]+)\s*(miles?|mi|km)", t, re.I)
    miles = None
    if dist:
        miles = float(dist.group(1)) * (0.621371 if dist.group(2).lower() == "km" else 1.0)
    out.update(
        travel_kind="ride", origin=coarse_area(labelled(t, [r"from", r"pickup"])),
        destination=coarse_area(labelled(t, [r"to", r"drop-?off"])),
        city=labelled(t, [r"city"]), distance_miles=round(miles, 2) if miles is not None else None,
        total=_money(t, [r"total"]), currency=_currency(t, m.currency), notes=notes)
    return out


def _trainline(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, None, notes)
    out.update(
        travel_kind="train", order_id=labelled(t, [r"booking reference"]),
        origin=labelled(t, [r"from"]), destination=labelled(t, [r"to"]),
        start_date=iso_date(_when(t, [r"outward"], True)),
        end_date=iso_date(_when(t, [r"return"], True)),
        total=_money(t, _TOTAL_LABELS), currency=_currency(t, m.currency), notes=notes)
    return out


# --------------------------------------------------------------------- tickets
def _odeon(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, None, notes)
    items = parse_items(t)
    out.update(
        order_id=labelled(t, [r"booking reference"]), event_name=labelled(t, [r"film"]),
        venue=labelled(t, [r"cinema"]),
        event_date=iso(_combine(t, [r"date"], [r"showing"], True)),
        ticket_count=sum(i["quantity"] for i in items) or None,
        total=_money(t, _TOTAL_LABELS), currency=_currency(t, m.currency), notes=notes)
    return out


def _ticketmaster(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, None, notes)
    items = parse_items(t)
    out.update(
        order_id=labelled(t, [r"order number"]), event_name=labelled(t, [r"event"]),
        venue=labelled(t, [r"venue"]), event_date=iso(_when(t, [r"date"], True)),
        ticket_count=sum(i["quantity"] for i in items) or None,
        total=_money(t, _TOTAL_LABELS), currency=_currency(t, m.currency), notes=notes)
    return out


# --------------------------------------------------------------------- subscriptions
def _sub_event(msg: ParsedMessage) -> str:
    blob = (msg.subject + "\n" + msg.text).lower()
    if re.search(r"cancel+ation|has been cancel+ed|cancel+ed", msg.subject.lower()) or \
            "cancellation date" in blob:
        return "cancellation"
    if re.search(r"price .*(chang|increas)|(chang|increas).* price|new price", blob):
        return "price_change"
    if re.search(r"welcome|thanks for subscribing|you.ve subscribed", blob):
        return "signup"
    return "renewal"


def _period(text: str) -> Optional[str]:
    v = labelled(text, [r"billing period", r"billing", r"period"]) or text
    if re.search(r"\b(?:annual|yearly|per year|12[- ]month)\b|/\s*year", v, re.I):
        return "annual"
    if re.search(r"\b(?:monthly|per month)\b|/\s*month", v, re.I):
        return "monthly"
    return None


def _subscription(msg, m):
    t, notes = msg.text, []
    event = _sub_event(msg)
    out = _base(msg, m, _when(t, [r"date"], True), notes)
    cur_price = _money(t, [r"current price"])
    new_price = _money(t, [r"new price"])
    price = new_price if event == "price_change" else (_money(t, [r"price"]) or _money(t, _TOTAL_LABELS))
    out.update(
        event=event, plan=labelled(t, [r"plan"]), period=_period(t), price=price,
        old_price=cur_price if event == "price_change" else None,
        total=None if event in ("price_change", "cancellation") else _money(t, _TOTAL_LABELS),
        currency=_currency(t, m.currency),
        renewal_date=iso_date(_when(t, [r"next payment", r"next billing date", r"renews on", r"effective"], True)),
        cancel_date=iso_date(_when(t, [r"cancellation date", r"ends on"], True)) if event == "cancellation" else None,
        notes=notes)
    return out


# --------------------------------------------------------------------- bookings
def _opentable(msg, m):
    t, notes = msg.text, []
    out = _base(msg, m, None, notes)
    party = re.search(r"(?:party of|table for)\s+(\d+)", t, re.I)
    out.update(
        restaurant=labelled(t, [r"reservation at"]),
        party_size=int(party.group(1)) if party else None,
        booking_at=iso(_combine(t, [r"date"], [r"time"], True)),
        order_id=labelled(t, [r"confirmation\s*#"]), notes=notes)
    return out


TEMPLATES: Dict[str, Callable[[ParsedMessage, Merchant], Dict[str, Any]]] = {
    **{k: _food_template(k) for k in _FOOD},
    "britishairways": _ba, "airbnb": _airbnb, "uber": _uber, "trainline": _trainline,
    "odeon": _odeon, "ticketmaster": _ticketmaster,
    "spotify": _subscription, "netflix": _subscription, "adobe": _subscription,
    "opentable": _opentable,
}


def is_complete(r: Dict[str, Any]) -> bool:
    """A template result is usable only if the fields that matter were found."""
    cat = r.get("category")
    if cat in ("food_delivery",):
        return bool(r.get("restaurant")) and (r.get("total") is not None or bool(r.get("items")))
    if cat in ("grocery", "retail"):
        return r.get("total") is not None or bool(r.get("items"))
    if cat == "travel":
        return r.get("total") is not None or bool(r.get("destination") or r.get("origin"))
    if cat == "ticket":
        return bool(r.get("event_name")) and (r.get("total") is not None or bool(r.get("event_date")))
    if cat == "subscription":
        return r.get("price") is not None or bool(r.get("plan"))
    if cat == "restaurant_booking":
        return bool(r.get("restaurant")) and bool(r.get("booking_at"))
    return False
