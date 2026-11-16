"""Text helpers: HTML to line text, money and date parsing. Pure, offline."""

from __future__ import annotations

import re
from datetime import datetime
from typing import List, Optional, Tuple

from bs4 import BeautifulSoup

CURRENCY_SYMBOLS = {
    "£": "GBP", "$": "USD", "€": "EUR", "¥": "JPY",
    "HK$": "HKD", "US$": "USD", "A$": "AUD", "C$": "CAD", "S$": "SGD",
}
ISO_CODES = ("GBP", "USD", "EUR", "HKD", "JPY", "AUD", "CAD", "SGD", "CHF")

_MONEY_RE = re.compile(
    r"(?:(?P<sym>HK\$|US\$|A\$|C\$|S\$|£|\$|€|¥)\s?(?P<a1>\d[\d,]*(?:\.\d{1,2})?)"
    r"|(?P<a2>\d[\d,]*(?:\.\d{2}))\s?(?P<code>GBP|USD|EUR|HKD|JPY|AUD|CAD|SGD|CHF)\b"
    r"|\b(?P<code2>GBP|USD|EUR|HKD|JPY|AUD|CAD|SGD|CHF)\s?(?P<a3>\d[\d,]*(?:\.\d{1,2})?))"
)
_EU_MONEY_RE = re.compile(r"(?P<a>\d[\d.]*,\d{2})\s?€")


def html_to_text(html: str) -> str:
    """Flatten HTML into lines. Table cells are tab separated. Nothing is fetched."""
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "head", "img", "noscript"]):
        tag.decompose()
    for br in soup.find_all("br"):
        br.replace_with("\n")
    for cell in soup.find_all(["td", "th"]):
        cell.append("\t")
    for blk in soup.find_all(["tr", "p", "div", "h1", "h2", "h3", "h4", "li", "table"]):
        blk.append("\n")
    return normalise_lines(soup.get_text())


def normalise_lines(text: str) -> str:
    out: List[str] = []
    for raw in text.replace("\r", "").replace("\xa0", " ").split("\n"):
        line = re.sub(r"[ ]+", " ", raw).strip(" \t")
        line = re.sub(r"\t+", "\t", line).strip("\t")
        if line:
            out.append(line)
    return "\n".join(out)


def parse_money(text: str) -> Optional[Tuple[float, str]]:
    """First money amount in ``text`` as (amount, ISO currency)."""
    m = _MONEY_RE.search(text)
    if m:
        amt = m.group("a1") or m.group("a2") or m.group("a3")
        cur = CURRENCY_SYMBOLS.get(m.group("sym") or "") or m.group("code") or m.group("code2")
        return float(amt.replace(",", "")), cur
    m = _EU_MONEY_RE.search(text)
    if m:
        return float(m.group("a").replace(".", "").replace(",", ".")), "EUR"
    return None


def all_money(text: str) -> List[Tuple[float, str]]:
    return [(_to_float(m), _cur(m)) for m in _MONEY_RE.finditer(text)]


def _to_float(m) -> float:
    return float((m.group("a1") or m.group("a2") or m.group("a3")).replace(",", ""))


def _cur(m) -> str:
    return CURRENCY_SYMBOLS.get(m.group("sym") or "") or m.group("code") or m.group("code2")


MONTHS = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7,
    "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
}
_MON = r"(?P<mon>[A-Za-z]{3,9})\.?"
_TIME = r"(?:[ ,]*(?:at|@)?\s*(?P<h>\d{1,2}):(?P<mi>\d{2})\s?(?P<ap>[AaPp][Mm])?)?"
_DATE_PATTERNS = [
    ("iso", re.compile(r"(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})(?:[T ](?P<h>\d{2}):(?P<mi>\d{2}))?(?P<ap>)")),
    ("dmy_name", re.compile(r"(?P<d>\d{1,2})(?:st|nd|rd|th)?\s+" + _MON + r",?\s+(?P<y>\d{4})" + _TIME)),
    ("mdy_name", re.compile(_MON + r"\s+(?P<d>\d{1,2})(?:st|nd|rd|th)?,?\s+(?P<y>\d{4})" + _TIME)),
    ("slash", re.compile(r"(?P<a>\d{1,2})/(?P<b>\d{1,2})/(?P<y>\d{4})" + _TIME)),
]


def parse_datetime(text: str, dayfirst: bool = True) -> Optional[datetime]:
    """First date (and time if present) in ``text``. Returns naive local time."""
    best: Optional[Tuple[int, datetime]] = None
    for kind, rx in _DATE_PATTERNS:
        m = rx.search(text)
        if not m:
            continue
        g = m.groupdict()
        try:
            if kind == "iso":
                y, mo, d = int(g["y"]), int(g["m"]), int(g["d"])
            elif kind == "slash":
                a, b = int(g["a"]), int(g["b"])
                d, mo = (a, b) if dayfirst else (b, a)
                y = int(g["y"])
            else:
                mo = MONTHS.get(g["mon"][:4].lower().rstrip(".")) or MONTHS.get(g["mon"][:3].lower())
                if not mo:
                    continue
                y, d = int(g["y"]), int(g["d"])
            h = int(g.get("h") or 0)
            mi = int(g.get("mi") or 0)
            ap = (g.get("ap") or "").lower()
            if ap == "pm" and h < 12:
                h += 12
            if ap == "am" and h == 12:
                h = 0
            dt = datetime(y, mo, d, h, mi)
        except (ValueError, TypeError):
            continue
        if best is None or m.start() < best[0]:
            best = (m.start(), dt)
    return best[1] if best else None


def iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat(timespec="minutes") if dt else None


def iso_date(dt: Optional[datetime]) -> Optional[str]:
    return dt.strftime("%Y-%m-%d") if dt else None


def labelled(text: str, labels: List[str], stop_at_tab: bool = True) -> Optional[str]:
    """Value after ``Label:`` (or ``Label<TAB>``) on one line."""
    for label in labels:
        rx = re.compile(r"^\s*" + label + r"\s*[:\t]\s*(?P<v>[^\n\t]+)", re.I | re.M)
        m = rx.search(text)
        if m:
            return m.group("v").strip()
    return None


def labelled_money(text: str, labels: List[str]) -> Optional[Tuple[float, str]]:
    """Money on the line that starts with one of ``labels``. Last amount wins."""
    for label in labels:
        rx = re.compile(r"^\s*" + label + r"\b[^\n]*$", re.I | re.M)
        for m in rx.finditer(text):
            found = list(_MONEY_RE.finditer(m.group(0)))
            if found:
                last = found[-1]
                return _to_float(last), _cur(last)
    return None
