"""Books, settings and tax-year windows. Personal is OFF unless the owner turns it on."""

from __future__ import annotations

import uuid
from datetime import date
from typing import Any, Dict, Optional, Tuple

from . import presets
from .store import Store

FX_METHOD = "statement-actual-else-daily-rate"   # one method per book, see pipeline._fx


DATE_LOCALES = ("uk", "hk", "us")   # uk and hk read day/month; us reads month/day


def make_book(store: Store, *, kind: str, name: str, preset: str, home_currency: str,
              tax_year_start: Optional[str] = None, tax_registered: bool = False,
              book_id: Optional[str] = None, date_locale: Optional[str] = None) -> Dict[str, Any]:
    if kind not in ("business", "personal"):
        raise ValueError("kind must be business or personal")
    if date_locale is not None and date_locale not in DATE_LOCALES:
        raise ValueError("date_locale must be uk, hk or us")
    if preset not in presets.PRESETS and kind == "business":
        raise ValueError("unknown preset")
    book = {
        "id": book_id or ("bk_" + uuid.uuid4().hex[:12]),
        "kind": kind,
        "name": name,
        "preset": preset if kind == "business" else "personal",
        "home_currency": home_currency.upper(),
        "tax_year_start": tax_year_start or presets.TAX_YEAR_START.get(preset, "01-01"),
        "tax_registered": bool(tax_registered),
        "enabled": True,
        "fx_method": FX_METHOD,
        "date_locale": date_locale or ("us" if home_currency.upper() == "USD" else "uk"),
    }
    store.put_book(book)
    return book


def categories(book: Dict[str, Any]) -> list:
    return presets.PERSONAL if book["kind"] == "personal" else presets.categories_for(book["preset"])


def tax_year_window(book: Dict[str, Any], label: Optional[str] = None, today: Optional[date] = None
                    ) -> Tuple[str, date, date]:
    """(label, first day, last day). label like '2025/26' names the year that starts in 2025."""
    m, d = (int(x) for x in book["tax_year_start"].split("-"))
    today = today or date.today()
    if label:
        start_year = int(label.split("/")[0])
    else:
        start_year = today.year if (today.month, today.day) >= (m, d) else today.year - 1
    start = date(start_year, m, d)
    end = date.fromordinal(date(start_year + 1, m, d).toordinal() - 1)
    return f"{start_year}/{str(start_year + 1)[2:]}", start, end
