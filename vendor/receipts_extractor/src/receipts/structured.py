"""schema.org JSON-LD and microdata receipts.

Handles Order, FlightReservation, LodgingReservation, TrainReservation,
EventReservation and FoodEstablishmentReservation. Street addresses present in
the markup are ignored: only the locality is kept.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from .mime import ParsedMessage
from .textutil import iso, iso_date, parse_datetime

TYPE_CATEGORY = {
    "Order": "retail",
    "Invoice": "retail",
    "FlightReservation": "travel",
    "LodgingReservation": "travel",
    "TrainReservation": "travel",
    "RentalCarReservation": "travel",
    "EventReservation": "ticket",
    "FoodEstablishmentReservation": "restaurant_booking",
}
TRAVEL_KIND = {
    "FlightReservation": "flight", "LodgingReservation": "lodging",
    "TrainReservation": "train", "RentalCarReservation": "ride",
}


def _first(v: Any) -> Any:
    return v[0] if isinstance(v, list) and v else v


def _g(d: Any, *path: str) -> Any:
    for p in path:
        d = _first(d)
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return _first(d)


def _s(v: Any) -> Optional[str]:
    v = _first(v)
    if isinstance(v, dict):
        v = v.get("name")
    return str(v).strip() if v not in (None, "") else None


def _num(v: Any) -> Optional[float]:
    v = _first(v)
    if isinstance(v, dict):
        v = v.get("price") or v.get("value")
    try:
        return round(float(str(v).replace(",", "")), 2) if v not in (None, "") else None
    except ValueError:
        return None


def _dt(v: Any):
    s = _s(v)
    return parse_datetime(s) if s else None


def _types(item: Dict[str, Any]) -> List[str]:
    t = item.get("@type")
    return [x.rsplit("/", 1)[-1] for x in (t if isinstance(t, list) else [t]) if isinstance(x, str)]


def extract_structured(msg: ParsedMessage) -> Optional[Dict[str, Any]]:
    """First usable transaction entity as a partial Receipt dict, else None."""
    for source, items in (("jsonld", msg.jsonld), ("microdata", msg.microdata)):
        for item in items:
            for t in _types(item):
                if t in TYPE_CATEGORY:
                    out = _convert(t, item)
                    if out:
                        out["method"] = source
                        return out
    return None


def _convert(t: str, d: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    out: Dict[str, Any] = {"category": TYPE_CATEGORY[t]}
    out["order_id"] = _s(d.get("orderNumber") or d.get("reservationNumber") or d.get("confirmationNumber"))
    out["currency"] = _s(d.get("priceCurrency") or _g(d, "priceSpecification", "priceCurrency"))
    out["total"] = _num(d.get("totalPrice") or d.get("price") or d.get("priceSpecification"))
    seller = _s(d.get("merchant") or d.get("seller") or d.get("provider") or d.get("underName") and None)
    out["merchant"] = seller
    when = _dt(d.get("orderDate") or d.get("bookingTime"))
    out["occurred_at"] = iso(when)
    for_ = _first(d.get("reservationFor"))

    if t in ("Order", "Invoice"):
        items = []
        for offer in (d.get("acceptedOffer") or []) if isinstance(d.get("acceptedOffer"), list) else \
                ([d["acceptedOffer"]] if d.get("acceptedOffer") else []):
            name = _s(_g(offer, "itemOffered", "name"))
            if not name:
                continue
            qty = int(_num(_g(offer, "eligibleQuantity", "value") or offer.get("orderQuantity")) or 1)
            unit = _num(offer.get("price"))
            items.append({"name": name, "quantity": qty,
                          "price": round(unit * qty, 2) if unit is not None else None})
        for it in (d.get("orderedItem") or []) if isinstance(d.get("orderedItem"), list) else []:
            name = _s(_g(it, "orderedItem", "name") or it.get("name"))
            if name:
                items.append({"name": name, "quantity": int(_num(it.get("orderQuantity")) or 1),
                              "price": None})
        out["items"] = items
        if out["total"] is None and not items:
            return None
    elif t == "LodgingReservation":
        out.update(travel_kind="lodging",
                   destination=_s(_g(for_, "address", "addressLocality")),
                   start_date=iso_date(_dt(d.get("checkinTime") or d.get("checkinDate"))),
                   end_date=iso_date(_dt(d.get("checkoutTime") or d.get("checkoutDate"))))
        out["merchant"] = out["merchant"] or None
    elif t == "FlightReservation":
        flight = for_ if isinstance(for_, dict) else {}
        out.update(
            travel_kind="flight",
            carrier=_s(_g(flight, "airline", "name")),
            origin=_s(_g(flight, "departureAirport", "name") or _g(flight, "departureAirport", "iataCode")),
            destination=_s(_g(flight, "arrivalAirport", "name") or _g(flight, "arrivalAirport", "iataCode")),
            start_date=iso_date(_dt(flight.get("departureTime"))),
            end_date=None)
    elif t == "TrainReservation":
        train = for_ if isinstance(for_, dict) else {}
        out.update(travel_kind="train",
                   origin=_s(_g(train, "departureStation", "name")),
                   destination=_s(_g(train, "arrivalStation", "name")),
                   start_date=iso_date(_dt(train.get("departureTime"))))
    elif t == "RentalCarReservation":
        out.update(travel_kind="ride", start_date=iso_date(_dt(d.get("pickupTime"))),
                   end_date=iso_date(_dt(d.get("dropoffTime"))))
    elif t == "EventReservation":
        ev = for_ if isinstance(for_, dict) else {}
        seats = _num(d.get("numSeats"))
        out.update(event_name=_s(ev.get("name")), venue=_s(_g(ev, "location", "name")),
                   event_date=iso(_dt(ev.get("startDate"))),
                   ticket_count=int(seats) if seats else None)
    elif t == "FoodEstablishmentReservation":
        out.update(restaurant=_s(_g(d, "reservationFor", "name")),
                   booking_at=iso(_dt(d.get("startTime"))),
                   party_size=int(_num(d.get("partySize")) or 0) or None)
    useful = [out.get(k) for k in ("total", "event_name", "restaurant", "destination", "origin", "items")]
    return out if any(useful) else None
