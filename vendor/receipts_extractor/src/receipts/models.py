"""Receipt row model."""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional

CATEGORIES = (
    "food_delivery",
    "grocery",
    "retail",
    "travel",
    "ticket",
    "subscription",
    "restaurant_booking",
)

# Fields that exist only for one category. Anything unknown stays None.
TRAVEL_FIELDS = ("travel_kind", "origin", "destination", "start_date", "end_date", "carrier")
SUBSCRIPTION_FIELDS = ("plan", "period", "price", "event", "renewal_date", "cancel_date", "old_price")
TICKET_FIELDS = ("event_name", "venue", "event_date", "ticket_count")
BOOKING_FIELDS = ("party_size", "booking_at")


@dataclass
class Receipt:
    message_id: str
    merchant: str
    category: str
    service: Optional[str] = None  # PWG service key, e.g. "deliveroo"
    occurred_at: Optional[str] = None  # ISO 8601, local wall time as printed
    currency: Optional[str] = None
    total: Optional[float] = None
    subtotal: Optional[float] = None
    delivery_fee: Optional[float] = None
    service_fee: Optional[float] = None
    tip: Optional[float] = None
    items: List[Dict[str, Any]] = field(default_factory=list)  # name, quantity, price
    order_id: Optional[str] = None
    restaurant: Optional[str] = None  # venue for food delivery and bookings
    area: Optional[str] = None  # coarse area only (postcode district or city)
    # travel
    travel_kind: Optional[str] = None  # flight, lodging, ride, train
    origin: Optional[str] = None
    destination: Optional[str] = None
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    carrier: Optional[str] = None
    city: Optional[str] = None  # rides: city of the trip, never a street
    distance_miles: Optional[float] = None
    # subscription
    plan: Optional[str] = None
    period: Optional[str] = None  # monthly, annual
    price: Optional[float] = None
    event: Optional[str] = None  # renewal, price_change, cancellation, signup
    renewal_date: Optional[str] = None
    cancel_date: Optional[str] = None
    old_price: Optional[float] = None
    # ticket
    event_name: Optional[str] = None
    venue: Optional[str] = None
    event_date: Optional[str] = None
    ticket_count: Optional[int] = None
    # restaurant booking
    party_size: Optional[int] = None
    booking_at: Optional[str] = None
    # provenance
    method: str = "template"  # template, jsonld, microdata, llm
    sender_domain: Optional[str] = None
    notes: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
