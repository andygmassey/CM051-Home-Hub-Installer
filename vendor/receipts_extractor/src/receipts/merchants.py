"""Sender and domain table for the merchants with deterministic templates.

Matching is by registrable-domain suffix of the From address. Uber is shared
by rides and Uber Eats, so the template resolver looks at the subject too.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Merchant:
    key: str  # template key
    name: str
    category: str
    service: str  # PWG service key where one exists
    currency: Optional[str]  # default when the email omits it
    dayfirst: bool = True


_M = [
    # food delivery
    Merchant("deliveroo", "Deliveroo", "food_delivery", "deliveroo", "GBP", True),
    Merchant("ubereats", "Uber Eats", "food_delivery", "uber_eats", "GBP", True),
    Merchant("doordash", "DoorDash", "food_delivery", "doordash", "USD", False),
    Merchant("justeat", "Just Eat", "food_delivery", "justeat", "GBP", True),
    # groceries
    Merchant("tesco", "Tesco", "grocery", "tesco", "GBP", True),
    Merchant("instacart", "Instacart", "grocery", "instacart", "USD", False),
    # retail
    Merchant("amazon", "Amazon", "retail", "amazon", None, True),
    # travel
    Merchant("britishairways", "British Airways", "travel", "british_airways", "GBP", True),
    Merchant("airbnb", "Airbnb", "travel", "airbnb", None, True),
    Merchant("trainline", "Trainline", "travel", "trainline", "GBP", True),
    Merchant("uber", "Uber", "travel", "uber", None, True),
    Merchant("booking", "Booking.com", "travel", "booking_com", None, True),
    # tickets
    Merchant("odeon", "Odeon", "ticket", "odeon", "GBP", True),
    Merchant("ticketmaster", "Ticketmaster", "ticket", "ticketmaster", "GBP", True),
    # subscriptions
    Merchant("spotify", "Spotify", "subscription", "spotify", None, True),
    Merchant("netflix", "Netflix", "subscription", "netflix", None, True),
    Merchant("adobe", "Adobe", "subscription", "adobe", None, True),
    # restaurant bookings
    Merchant("opentable", "OpenTable", "restaurant_booking", "opentable", None, True),
]
BY_KEY = {m.key: m for m in _M}

# domain suffix -> merchant key
DOMAINS = {
    "deliveroo.co.uk": "deliveroo", "deliveroo.com": "deliveroo", "deliveroo.hk": "deliveroo",
    "ubereats.com": "ubereats", "uber.com": "uber",
    "doordash.com": "doordash",
    "just-eat.co.uk": "justeat", "just-eat.com": "justeat", "justeat.com": "justeat",
    "tesco.com": "tesco", "groceries.tesco.com": "tesco",
    "instacart.com": "instacart",
    "amazon.co.uk": "amazon", "amazon.com": "amazon", "amazon.de": "amazon",
    "ba.com": "britishairways", "britishairways.com": "britishairways",
    "airbnb.com": "airbnb", "airbnb.co.uk": "airbnb",
    "trainline.com": "trainline",
    "booking.com": "booking",
    "odeon.co.uk": "odeon",
    "ticketmaster.co.uk": "ticketmaster", "ticketmaster.com": "ticketmaster",
    "spotify.com": "spotify", "netflix.com": "netflix",
    "adobe.com": "adobe",
    "opentable.com": "opentable", "opentable.co.uk": "opentable",
}


def lookup(from_domain: str) -> Optional[Merchant]:
    d = (from_domain or "").lower()
    while d:
        if d in DOMAINS:
            return BY_KEY[DOMAINS[d]]
        if "." not in d:
            break
        d = d.split(".", 1)[1]
    return None
