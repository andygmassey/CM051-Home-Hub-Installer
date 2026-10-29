"""Food evidence from the owner's own mail, calendar and browsing.

Turns four FDA/mail extracts into food preferences the derive engine reads:

    apple_mail.json / *.mbox.txt   reservation confirmations (OpenTable, Resy,
                                   SevenRooms, TheFork, Quandoo, TableCheck,
                                   Chope, OpenRice, Google, direct restaurant
                                   mail), delivery receipts (Deliveroo,
                                   Foodpanda, Uber Eats, Keeta ...), grocery
                                   receipts
    calendar_events.json           meals ("Lunch @ X", "Dinner with J" at a
                                   venue) and events located at a restaurant
    safari_history.json /
    safari_bookmarks.json          restaurant pages on review, booking, delivery
                                   and map sites

A restaurant becomes ONE preference, category ``food``, ``extra.restaurant``
(the derive reader's key) and, when it can be told, ``extra.cuisine`` from the
local rule arm or the local model. A dish or grocery item is its own
preference with ``extra.food_item`` (never ``extra.restaurant``, so a dish is
not counted as a restaurant visit). A diet-shaped signal is category
``dietary`` at compartment level 0 and no derive row reads it: stored, never
surfaced, never nudged on.

PRIVACY. Only the venue name, area, party size, dish and item names leave the
source. The raw subject, the people in a title ("Dinner with ..."), message
bodies and addresses are never stored.
"""

from __future__ import annotations

import hashlib
import html
import importlib.util
import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator, Callable, Dict, Iterable, Iterator, List, Optional, Tuple
from urllib.parse import unquote, urlparse

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)

SOURCE = "food_evidence"
CLAIMED = {"calendar_events.json", "apple_mail.json", "safari_history.json", "safari_bookmarks.json"}


def _load_sibling(module: str):
    """Load a derive module by path, so ingest needs no import of the enrich package."""
    here = Path(__file__).resolve()
    for root in (here.parents[3] / "enrich" / "src" / "derive", here.parents[2] / "enrich" / "src" / "derive"):
        f = root / f"{module}.py"
        if f.is_file():
            spec = importlib.util.spec_from_file_location(f"_food_{module}", f)
            mod = importlib.util.module_from_spec(spec)
            import sys
            sys.modules[spec.name] = mod
            spec.loader.exec_module(mod)
            return mod
    raise ImportError(f"derive/{module}.py not found beside the ingest service")


# The vocabulary lives beside the derive engine (one shared table). If a build
# ships ingest without it, this parser switches itself off rather than take the
# whole parser package down with it.
try:
    vocab = _load_sibling("cuisine_vocab")
    import sys as _sys
    _sys.modules.setdefault("cuisine_vocab", vocab)   # cuisine_local_model's flat-import fallback
    local_model = _load_sibling("cuisine_local_model")
except ImportError as _exc:  # pragma: no cover - exercised by test_missing_vocab_disables_the_parser
    logging.getLogger(__name__).warning("food_evidence disabled: %s", _exc)
    vocab = local_model = None

# ── platforms ───────────────────────────────────────────────────────────────
RES_PLATFORMS: Dict[str, str] = {
    "opentable": "OpenTable", "resy.com": "Resy", "sevenrooms": "SevenRooms", "thefork": "TheFork",
    "lafourchette": "TheFork", "quandoo": "Quandoo", "tablecheck": "TableCheck", "chope": "Chope",
    "openrice": "OpenRice", "reserve.google": "Google", "tock": "Tock", "bookatable": "Bookatable",
    "designmynight": "DesignMyNight", "tabelog": "Tabelog", "dojo.co": "Dojo", "bookenda": "Bookenda",
}
DEL_PLATFORMS: Dict[str, str] = {
    "deliveroo": "Deliveroo", "foodpanda": "Foodpanda", "ubereats": "Uber Eats", "keeta": "Keeta",
    "doordash": "DoorDash", "grubhub": "Grubhub", "just-eat": "Just Eat", "justeat": "Just Eat",
    "glovo": "Glovo", "zomato": "Zomato", "swiggy": "Swiggy", "talabat": "Talabat", "foodora": "Foodora",
    "wolt": "Wolt", "lineman": "LINE MAN", "hungrypanda": "HungryPanda", "meituan": "Meituan",
}
# Grocery retailer by sender domain fragment. Marketing mail from these is
# ignored; only receipt-shaped subjects count.
GROCERS: Dict[str, str] = {
    "tesco": "Tesco", "sainsbury": "Sainsbury's", "ocado": "Ocado", "waitrose": "Waitrose", "asda": "Asda",
    "morrisons": "Morrisons", "marksandspencer": "Marks & Spencer", "parknshop": "PARKnSHOP",
    "wellcome": "Wellcome", "hktvmall": "HKTVmall", "instacart": "Instacart", "freshdirect": "FreshDirect",
    "amazonfresh": "Amazon Fresh", "wholefoods": "Whole Foods", "riverford": "Riverford", "oddbox": "Oddbox",
    "abelandcole": "Abel & Cole", "hellofresh": "HelloFresh", "gousto": "Gousto", "aldi": "Aldi",
    "lidl": "Lidl", "iceland.co": "Iceland", "coop.co": "Co-op", "redmart": "RedMart", "fairprice": "FairPrice",
    "coles": "Coles", "woolworths": "Woolworths", "carrefour": "Carrefour", "picnic": "Picnic",
    "getir": "Getir", "kroger": "Kroger", "walmart": "Walmart", "costco": "Costco", "traderjoes": "Trader Joe's",
}

_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
_DELIMS = re.compile(r"\s+(?:is|has|was|on|for|at|from|with|via|by|-|–|—|\|)\s+|[:|!(\[]|\s{2,}|\.\s|,\s")
_BAD_NAME = re.compile(r"^(your|the table|a table|table|you|us|confirmed|confirmation|reservation|booking|order|"
                       r"receipt|delivery|dinner|lunch|brunch|tonight|today|tomorrow|this|has|is)\b", re.I)

# ── reservations ────────────────────────────────────────────────────────────
_RES_SUBJECT = [
    re.compile(r"(?:reservation|booking|table)\s+(?:is\s+)?(?:now\s+)?(?:confirm(?:ed|ation)\s+)?(?:at|@)\s+(?P<n>.+)", re.I),
    re.compile(r"(?:reservation|booking)\s+confirm(?:ed|ation)\s*[:\-–—]\s*(?P<n>.+)", re.I),
    re.compile(r"confirm(?:ed|ation)\b.{0,30}?\b(?:reservation|booking|table)\s+(?:at|for|@)\s+(?P<n>.+)", re.I),
    re.compile(r"you(?:'|’)?re\s+(?:booked|all set|confirmed)\s+(?:at|for\s+(?:dinner|lunch|brunch)\s+at)\s+(?P<n>.+)", re.I),
    re.compile(r"(?:dinner|lunch|brunch|breakfast)\s+(?:reservation\s+)?(?:at|@)\s+(?P<n>.+)", re.I),
]
_RES_SHAPE = re.compile(r"reservation|booking confirm|your table|table (?:is )?(?:booked|confirmed)|you(?:'|’)?re booked|party of", re.I)
_PARTY = re.compile(r"(?:party of|table for|for)\s+(\d{1,2})(?:\s*(?:people|guests|persons|pax|diners|adults))?\b", re.I)
_PARTY_STRICT = re.compile(r"(?:party of\s+(\d{1,2})|table for\s+(\d{1,2})|(\d{1,2})\s*(?:people|guests|persons|pax|diners))", re.I)

# ── delivery ────────────────────────────────────────────────────────────────
_DEL_SUBJECT = [
    re.compile(r"(?:order|delivery|receipt|meal|food)\s+(?:from|at)\s+(?P<n>.+)", re.I),
    re.compile(r"thanks?\s+for\s+ordering\s+(?:from|at)\s+(?P<n>.+)", re.I),
    re.compile(r"(?:your|an?)\s+(?P<n>[^:|]+?)\s+order\s+(?:has been|is|was)\s+(?:delivered|confirmed|on its way|accepted|placed)", re.I),
]
_DEL_SHAPE = re.compile(r"\border\b|delivery|receipt|enjoy your meal|rider|on its way", re.I)
_DISH = [
    re.compile(r"^\s*(?P<q>\d{1,2})\s*[x×]\s*(?P<d>[^\d£$€].{2,70}?)\s*(?:(?:HK\$|S\$|RM|[£$€])\s*)?\d[\d,]*(?:\.\d{2})?\s*$", re.I),
    re.compile(r"^\s*(?P<d>[A-Za-z][^\d£$€\n]{2,70}?)\s+[x×]\s*(?P<q>\d{1,2})\s+(?:(?:HK\$|S\$|RM|[£$€])\s*)?\d[\d,]*(?:\.\d{2})?\s*$", re.I),
]

# ── grocery ─────────────────────────────────────────────────────────────────
_GRO_SHAPE = re.compile(r"order confirm|receipt|your (?:groceries|shop|delivery|order)|substitution|e-?receipt|invoice", re.I)
_ITEM = re.compile(r"^\s*(?:(?P<q>\d{1,2})\s*[x×]\s*)?(?P<d>[A-Za-z][^£$€\n]{2,70}?)\s+(?:(?:HK\$|S\$|RM|[£$€])\s*)\d[\d,]*(?:\.\d{2})?\s*$")
_ITEM_NOISE = re.compile(r"\b(total|subtotal|delivery|savings|voucher|discount|bag|carrier|service|tax|vat|tip|order|balance|payment|card|slot|fee)\b", re.I)
_PACK = re.compile(r"\b\d+(?:\.\d+)?\s*(?:g|kg|ml|l|cl|oz|lb|pk|pack|x\d+)\b|\b\d+\s*x\s*\d+\b|\(\s*\d+\s*\)", re.I)
BRANDS = ("Heinz", "Kellogg's", "Nestle", "Cadbury", "Walkers", "Warburtons", "Innocent", "Alpro", "Oatly", "Ben & Jerry's",
          "Hovis", "Muller", "Danone", "Lurpak", "Coca-Cola", "Pepsi", "Fever-Tree", "Twinings", "PG Tips", "Tilda",
          "Dolmio", "Hellmann's", "Birds Eye", "Quorn", "Green Giant", "Marmite", "Nescafe", "Lavazza", "Yeo's",
          "Lee Kum Kee", "Kikkoman", "Pringles", "Doritos", "Haribo", "Magnum", "Haagen-Dazs", "Philadelphia",
          "Activia", "Weetabix", "Cheerios", "Nutella", "Colgate", "Fage", "Yakult", "Vitasoy", "Kewpie", "Maggi")
_DIET = (("vegan", re.compile(r"\bvegan\b", re.I)), ("vegetarian", re.compile(r"\bvegetarian\b|\bmeat[- ]free\b", re.I)),
         ("gluten_free", re.compile(r"gluten[- ]free", re.I)), ("dairy_free", re.compile(r"dairy[- ]free|lactose[- ]free", re.I)),
         ("halal", re.compile(r"\bhalal\b", re.I)), ("kosher", re.compile(r"\bkosher\b", re.I)),
         ("nut_free", re.compile(r"nut[- ]free", re.I)), ("sugar_free", re.compile(r"sugar[- ]free|no added sugar", re.I)))

# ── calendar ────────────────────────────────────────────────────────────────
_MEAL = re.compile(r"\b(dinner|lunch|brunch|breakfast|supper|drinks|dim sum|yum cha|tea|coffee)\b", re.I)
_CAL_AT = re.compile(r"(?:@|\bat\b)\s*(?P<v>[^,()\[\]|]+)", re.I)
_VENUE_WORD = re.compile(r"restaurant|cafe|café|bistro|kitchen|grill|sushi|noodle|pizz|trattoria|brasserie|tavern|diner|"
                         r"tea house|bar & |steakhouse|izakaya|ramen|dim sum|bakery|pub\b|osteria|taqueria|cantina", re.I)
_NOT_A_VENUE = re.compile(r"\b(zoom|teams|meet\.google|webex|skype|facetime|hangout|http|call|phone|dial|home|my place|"
                          r"office|room|floor|/f\b|flat|unit|suite|building|tower|level|street|st\.?$|road|rd\.?$|avenue|"
                          r"ave\.?$|lane|drive|boulevard|airport|station|hotel lobby|tbc|tba|online)\b", re.I)

# ── web ─────────────────────────────────────────────────────────────────────
def _slug_name(slug: str) -> str:
    s = unquote(slug).replace("+", " ").replace("_", " ").replace("-", " ")
    return re.sub(r"\s+", " ", s).strip().title()


_WEB_RULES: List[Tuple[re.Pattern, str, float]] = [
    (re.compile(r"tripadvisor\.[a-z.]+/Restaurant_Review-[^/]*?-Reviews-([^/.]+?)(?:-[A-Z][a-zA-Z_]+)?\.html"), "tripadvisor", 0.35),
    (re.compile(r"yelp\.[a-z.]+/biz/([^/?#]+)"), "yelp", 0.35),
    (re.compile(r"opentable\.[a-z.]+/(?:r|restaurant/profile)/([^/?#]+)"), "opentable", 0.45),
    (re.compile(r"resy\.com/cities/[^/]+/(?:venues/)?([^/?#]+)"), "resy", 0.45),
    (re.compile(r"thefork\.[a-z.]+/restaurant/([^/?#]+?)(?:-r\d+)?(?:[/?#]|$)"), "thefork", 0.45),
    (re.compile(r"openrice\.com/[a-z\-]+/[a-z]+/restaurant/([^/?#]+?)(?:/r-.*)?(?:[?#]|$)"), "openrice", 0.35),
    (re.compile(r"openrice\.com/[a-z\-]+/[a-z]+/r-([a-z0-9\-]+?)-r\d+(?:[/?#]|$)"), "openrice", 0.35),
    (re.compile(r"guide\.michelin\.com/[^?#]*/restaurant/([^/?#]+)"), "michelin", 0.35),
    (re.compile(r"deliveroo\.[a-z.]+/menu/[^/]+/[^/]+/([^/?#]+)"), "deliveroo_menu", 0.35),
    (re.compile(r"foodpanda\.[a-z.]+/restaurant/[a-z0-9]+/([^/?#]+)"), "foodpanda_menu", 0.35),
    (re.compile(r"google\.[a-z.]+/maps/place/([^/@?#]+)"), "maps", 0.3),
]


# ── helpers ─────────────────────────────────────────────────────────────────
def _dom(sender: str) -> str:
    m = re.search(r"@([\w.\-]+)", sender or "")
    return m.group(1).lower() if m else ""


def _display_name(sender: str) -> str:
    m = re.match(r'\s*"?([^"<@]+?)"?\s*<', sender or "")
    return m.group(1).strip() if m else ""


def _match_platform(table: Dict[str, str], domain: str) -> Optional[str]:
    for frag, label in table.items():
        if frag in domain:
            return label
    return None


def clean_name(raw: str, limit: int = 60) -> Optional[str]:
    if not raw:
        return None
    s = _DELIMS.split(raw.strip(), maxsplit=1)[0]
    s = s.strip(" \t\"'“”‘’.!,;:-–—*")
    s = re.sub(r"\s{2,}", " ", s)
    if len(s) < 2 or len(s) > limit or _BAD_NAME.match(s) or not re.search(r"[A-Za-zÀ-￿]", s):
        return None
    if sum(c.isdigit() for c in s) > len(s) // 3:
        return None
    if "@" in s or "http" in s.lower():
        return None
    return s


def _parse_dt(raw) -> Optional[datetime]:
    if not isinstance(raw, str) or not raw.strip():
        return None
    s = raw.strip()
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        try:
            from email.utils import parsedate_to_datetime
            dt = parsedate_to_datetime(s)
        except Exception:
            return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def dining_date(text: str, ref: Optional[datetime]) -> Optional[datetime]:
    """A date written in a subject or body ("12 Oct", "October 12 2026", ISO), else None."""
    m = re.search(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b", text or "")   # day first, as the sources write it
    if m:
        try:
            return datetime(int(m[3]), int(m[2]), int(m[1]), tzinfo=timezone.utc)
        except ValueError:
            return None
    m = re.search(r"\b(\d{4})-(\d{2})-(\d{2})\b", text or "")
    if m:
        try:
            return datetime(int(m[1]), int(m[2]), int(m[3]), tzinfo=timezone.utc)
        except ValueError:
            return None
    pat = r"(?:(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?([A-Za-z]{3})[a-z]*|([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?)(?:,?\s+(\d{4}))?"
    for m in re.finditer(pat, text or ""):
        d = m[1] or m[4]
        mon = _MONTHS.get((m[2] or m[3]).lower())
        if not (d and mon):
            continue
        year = int(m[5]) if m[5] else (ref.year if ref else datetime.now(timezone.utc).year)
        try:
            return datetime(year, mon, int(d), tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def _sid(*parts: str) -> str:
    return hashlib.sha1("|".join(parts).encode("utf-8", "ignore")).hexdigest()[:24]


def party_size(text: str) -> Optional[int]:
    m = _PARTY_STRICT.search(text or "")
    if m:
        n = int(next(g for g in m.groups() if g))
        return n if 1 <= n <= 40 else None
    return None


def clean_item(raw: str) -> Optional[str]:
    s = _PACK.sub(" ", raw or "")
    s = re.sub(r"\s+", " ", s).strip(" -–,.*")
    if len(s) < 3 or len(s) > 60 or _ITEM_NOISE.search(s):
        return None
    return s


def brand_of(item: str) -> Optional[str]:
    low = item.lower()
    for b in BRANDS:
        if low.startswith(b.lower() + " ") or low == b.lower():
            return b
    return None


def diet_signals(item: str) -> List[str]:
    return [label for label, pat in _DIET if pat.search(item)]


# ── mail ────────────────────────────────────────────────────────────────────
class MailItem:
    __slots__ = ("subject", "sender", "date", "body", "message_id")

    def __init__(self, subject="", sender="", date=None, body="", message_id=""):
        self.subject, self.sender, self.date, self.body, self.message_id = subject or "", sender or "", date, body or "", str(message_id or "")


class FoodExtractor:
    """Pure extraction. ``cuisine_for`` is injected so tests need no model."""

    def __init__(self, cuisine_for: Optional[Callable[[str, str, List[str]], Tuple[Optional[str], str]]] = None,
                 now: Optional[datetime] = None):
        self.cuisine_for = cuisine_for or rules_cuisine
        self.now = now or datetime.now(timezone.utc)

    # -- shared builders --
    def _restaurant(self, name, source_type, strength, observed, sid, area="", dishes=None, **extra) -> ParsedPreference:
        cuisine, how = self.cuisine_for(name, area, list(dishes or []))
        # signal_type is part of the filter's dedup key: one per OBSERVATION, so
        # three dinners at one restaurant stay three pieces of evidence.
        ex = {"restaurant": name, "source_type": source_type, "signal_type": f"{source_type}:{sid}"}
        if area:
            ex["area"] = area
        if cuisine:
            # A model's guess is kept apart from a rule/tag reading: a lower-weight
            # derive reader takes extra.cuisine_inferred (0.4 against 0.6).
            ex["cuisine_inferred" if how == "local_model" else "cuisine"] = cuisine
            ex["cuisine_source"] = how
        ex.update({k: v for k, v in extra.items() if v not in (None, "", [])})
        return ParsedPreference(subject=name, preference_type="Like", category="food", strength=strength,
                                compartment_level=2, source=SOURCE, source_id=f"{source_type}|{sid}|{name.lower()}",
                                observed_at=observed, extra=ex)

    def _item(self, item, qty, source_type, strength, observed, sid, brand=None) -> ParsedPreference:
        ex = {"food_item": item.lower(), "source_type": source_type, "signal_type": f"{source_type}:{sid}"}
        if qty and qty > 1:
            ex["quantity"] = qty
        if brand:
            ex["brand"] = brand
        return ParsedPreference(subject=item, preference_type="Like", category="food", strength=strength,
                                compartment_level=2, source=SOURCE, source_id=f"{source_type}-item|{sid}|{item.lower()}",
                                observed_at=observed, extra=ex)

    def _diet(self, signal, observed, sid) -> ParsedPreference:
        return ParsedPreference(subject=f"dietary signal: {signal}", preference_type="Like", category="dietary",
                                strength=0.3, compartment_level=0, source=SOURCE,
                                source_id=f"diet|{sid}|{signal}", observed_at=observed,
                                extra={"diet_signal": signal, "sensitive": True, "nudge": False, "source_type": "grocery_item",
                                       "signal_type": f"diet:{sid}:{signal}"})

    # -- email --
    def from_mail(self, m: MailItem) -> Iterator[ParsedPreference]:
        dom = _dom(m.sender)
        observed = m.date
        sid = _sid(dom, m.subject, m.date.isoformat() if m.date else "", m.message_id)
        res = _match_platform(RES_PLATFORMS, dom)
        dlv = _match_platform(DEL_PLATFORMS, dom)
        gro = _match_platform(GROCERS, dom)
        if dom.endswith("uber.com") and re.search(r"uber eats|ubereats", m.subject + " " + m.sender, re.I):
            dlv = "Uber Eats"
        blob = m.subject + "\n" + m.body[:4000]
        if res or (not dlv and not gro and _RES_SHAPE.search(m.subject)):
            name = self._name(_RES_SUBJECT, m.subject)
            if not name and not res:
                name = clean_name(_display_name(m.sender))
            if name:
                when = dining_date(blob, m.date) or observed
                yield self._restaurant(name, "reservation_email", 0.8, when, sid,
                                       party_size=party_size(blob), platform=res or "direct")
            return
        if dlv:
            if not (_DEL_SHAPE.search(m.subject) or m.body):
                return
            name = self._name(_DEL_SUBJECT, m.subject) or self._name_from_body(m.body)
            dishes = list(self._dishes(m.body))
            if name:
                yield self._restaurant(name, "delivery_email", 0.65, observed, sid,
                                       dishes=[d for d, _ in dishes], platform=dlv)
                for d, q in dishes:
                    yield self._item(d, q, "delivery_email", 0.5, observed, sid)
            return
        if gro and _GRO_SHAPE.search(m.subject):
            yield ParsedPreference(subject=gro, preference_type="Like", category="food", strength=0.5,
                                   compartment_level=2, source=SOURCE, source_id=f"grocery_email|{sid}|{gro.lower()}",
                                   observed_at=observed, extra={"brand": gro, "store_type": "grocery", "source_type": "grocery_email",
                                          "signal_type": f"grocery_email:{sid}"})
            for raw, q in self._grocery_lines(m.body):
                item = clean_item(raw)
                if not item:
                    continue
                yield self._item(item, q, "grocery_email", 0.45, observed, sid, brand=brand_of(item))
                for sig in diet_signals(item):
                    yield self._diet(sig, observed, sid)

    @staticmethod
    def _name(patterns, subject) -> Optional[str]:
        for pat in patterns:
            m = pat.search(subject or "")
            if m:
                n = clean_name(m.group("n"))
                if n:
                    return n
        return None

    @staticmethod
    def _name_from_body(body: str) -> Optional[str]:
        m = re.search(r"(?:^|\n)\s*(?:restaurant|order from|your order from|from)\s*[:\-]\s*(.{2,60})", body or "", re.I)
        if m:
            return clean_name(m.group(1))
        # "Your order from" on one line, the restaurant on the next (Foodpanda).
        lines = [ln.strip() for ln in (body or "").splitlines() if ln.strip()]
        for i, ln in enumerate(lines[:-1]):
            if re.fullmatch(r"(?:your )?order from:?", ln, re.I):
                return clean_name(lines[i + 1])
        return None

    @staticmethod
    def _dishes(body: str) -> Iterator[Tuple[str, int]]:
        seen = set()
        for line in (body or "").splitlines():
            for pat in _DISH:
                m = pat.match(line)
                if m:
                    d = clean_item(m.group("d"))
                    if d and d.lower() not in seen:
                        seen.add(d.lower())
                        yield d, int(m.group("q"))
                    break

    @staticmethod
    def _grocery_lines(body: str) -> Iterator[Tuple[str, int]]:
        for line in (body or "").splitlines():
            m = _ITEM.match(line)
            if m:
                yield m.group("d"), int(m.group("q") or 1)

    # -- calendar --
    def from_calendar(self, ev: dict) -> Iterator[ParsedPreference]:
        title = str(ev.get("title") or "")
        loc = str(ev.get("location") or "").strip()
        start = _parse_dt(ev.get("start_date"))
        if start is None or start > self.now or re.search(r"cancel", title, re.I):
            return
        meal = _MEAL.search(title)
        name, how = None, None
        if meal:
            m = _CAL_AT.search(title[meal.end():])
            if m:
                name, how = clean_name(m.group("v")), "title"
        if not name and loc:
            first = re.split(r"[\n,;]", loc, maxsplit=1)[0].strip()
            ok = first and not re.match(r"^\d", first) and not _NOT_A_VENUE.search(first)
            if ok and (meal or _VENUE_WORD.search(first)):
                name, how = clean_name(first), "location"
        if not name or _NOT_A_VENUE.search(name):
            return
        area = ""
        parts = [p.strip() for p in re.split(r"[\n,]", loc) if p.strip()] if loc else []
        if len(parts) >= 2 and not re.search(r"\d", parts[-1]) and len(parts[-1]) < 30:
            area = parts[-1]
        sid = _sid("cal", ev.get("start_date") or "", name)
        yield self._restaurant(name, "calendar_meal", 0.6 if how == "location" else 0.65, start, sid, area=area,
                               meal=meal.group(1).lower() if meal else None)

    # -- web --
    def from_url(self, url: str, observed: Optional[datetime] = None) -> Iterator[ParsedPreference]:
        u = (url or "").strip()
        for pat, kind, strength in _WEB_RULES:
            m = pat.search(u)
            if not m:
                continue
            name = clean_name(_slug_name(m.group(1)))
            if not name:
                return
            if kind == "maps" and not (_VENUE_WORD.search(name) or vocab.infer_cuisine(name)):
                return  # a map pin is any place; keep only the ones that read as eating places
            if kind in ("tripadvisor", "yelp"):
                name = re.sub(r"\s+(?:Hong Kong|London|New York|Singapore|Tokyo|Bangkok|Paris)$", "", name)
            yield self._restaurant(name, f"web_{kind}", strength, observed, _sid("web", u))
            return


def rules_cuisine(name: str, area: str, dishes: List[str]) -> Tuple[Optional[str], str]:
    hit = vocab.infer_cuisine(name, *dishes)
    if hit:
        return hit[0], "name_rules" if not dishes else "name_and_dishes_rules"
    return None, ""


def make_cuisine_resolver(generate=None, cap: int = 400, use_model: bool = True):
    """Rules first (offline), then the local model for names the rules cannot read.

    Results are cached per name for the run; the model is asked at most ``cap``
    times. ``use_model=False`` is pure rules.
    """
    cache: Dict[str, Tuple[Optional[str], str]] = {}
    asked = [0]

    def resolve(name: str, area: str, dishes: List[str]):
        key = name.strip().lower()
        if key in cache and not dishes:
            return cache[key]
        got = rules_cuisine(name, area, dishes)
        if not got[0] and use_model and asked[0] < cap:
            asked[0] += 1
            c = local_model.infer_with_local_model(name, area, dishes, generate=generate)
            got = (c, "local_model") if c else (None, "")
        cache[key] = got
        return got

    return resolve


# ── file readers ────────────────────────────────────────────────────────────
def _read_json_list(path: Path) -> list:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        logger.warning("food_evidence: could not read %s (%s)", path.name, type(exc).__name__)
        return []
    return data if isinstance(data, list) else []


_MBOX_FROM = re.compile(r"^From \S+.*\d{4}\s*$")
_ALL_PLATFORMS = {**RES_PLATFORMS, **DEL_PLATFORMS, **GROCERS, "uber.com": "Uber"}


def iter_mbox(path: Path) -> Iterator[MailItem]:
    """Stream an mbox; build a message only when the sender is a food platform."""
    from email import message_from_bytes
    from email.header import decode_header, make_header
    buf: List[str] = []

    def flush():
        if not buf:
            return None
        raw = "".join(buf)
        head = raw.split("\n\n", 1)[0]
        m = re.search(r"^From:(.*(?:\n[ \t].*)*)", head, re.M | re.I)
        dom = _dom(m.group(1)) if m else ""
        if not any(f in dom for f in _ALL_PLATFORMS) and not _RES_SHAPE.search(head):
            return None
        # bytes, not str: a text parse drops non-ASCII (the pound sign) from the body
        msg = message_from_bytes(raw.encode("utf-8", "surrogateescape"))

        def dec(v):
            try:
                return str(make_header(decode_header(v or "")))
            except Exception:
                return v or ""
        body = ""
        parts = msg.walk() if msg.is_multipart() else [msg]
        plain, htm = "", ""
        for p in parts:
            ct = p.get_content_type()
            if ct in ("text/plain", "text/html"):
                try:
                    txt = (p.get_payload(decode=True) or b"").decode(p.get_content_charset() or "utf-8", "ignore")
                except Exception:
                    continue
                if ct == "text/plain":
                    plain += txt
                else:
                    htm += txt
        if plain.strip():
            body = plain
        elif htm:
            body = html.unescape(re.sub(r"(?is)<(script|style).*?</\1>", " ", htm))
            body = re.sub(r"(?i)</(p|div|tr|li|h\d|table)>|<br\s*/?>", "\n", body)
            body = re.sub(r"<[^>]+>", " ", body)
            body = "\n".join(re.sub(r"[ \t ]+", " ", ln) for ln in body.splitlines())
        return MailItem(dec(msg.get("Subject")), dec(msg.get("From")), _parse_dt(msg.get("Date")), body, msg.get("Message-ID", ""))

    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            if _MBOX_FROM.match(line):
                item = flush()
                if item:
                    yield item
                buf = [line]
            else:
                buf.append(line)
                if len(buf) > 4000:  # a huge message: keep headers + the start, drop the rest
                    buf = buf[:3000]
        item = flush()
        if item:
            yield item


class FoodEvidenceParser(BaseParser):
    """Claims the FDA extracts named above and the hourly mail mbox files."""

    source_name = SOURCE

    def __init__(self, extractor: Optional[FoodExtractor] = None):
        self._extractor = extractor

    def can_parse(self, file_path: Path) -> bool:
        if vocab is None:
            return False
        n = file_path.name.lower()
        return n in CLAIMED or n.endswith(".mbox.txt")

    def _ex(self) -> FoodExtractor:
        if self._extractor is None:
            off = os.environ.get("OSTLER_FOOD_LOCAL_MODEL", "1") == "0"
            self._extractor = FoodExtractor(cuisine_for=make_cuisine_resolver(use_model=not off))
        return self._extractor

    async def parse(self, file_path: Path, default_compartment: Optional[int] = None, **kwargs) -> AsyncIterator[ParsedPreference]:
        ex = self._ex()
        n = file_path.name.lower()
        seen = set()
        for pref in self._iter(ex, file_path, n):
            if pref.id in seen:
                continue
            seen.add(pref.id)
            yield pref

    @staticmethod
    def _iter(ex: FoodExtractor, path: Path, name: str) -> Iterator[ParsedPreference]:
        if name == "calendar_events.json":
            for ev in _read_json_list(path):
                if isinstance(ev, dict):
                    yield from ex.from_calendar(ev)
        elif name == "apple_mail.json":
            for r in _read_json_list(path):
                if isinstance(r, dict):
                    yield from ex.from_mail(MailItem(r.get("subject"), r.get("sender"),
                                                     _parse_dt(r.get("date_sent") or r.get("date_received")),
                                                     "", r.get("message_id")))
        elif name.endswith(".mbox.txt"):
            for m in iter_mbox(path):
                yield from ex.from_mail(m)
        elif name in ("safari_history.json", "safari_bookmarks.json"):
            for r in _read_json_list(path):
                if isinstance(r, dict):
                    yield from ex.from_url(str(r.get("url") or ""), _parse_dt(r.get("timestamp") or r.get("date_added")))
