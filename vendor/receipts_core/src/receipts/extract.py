"""Deterministic field extraction from OCR or PDF text (the control, and the floor).

Works without any model. Every value it returns is a substring of the input, and
every field carries a confidence: a labelled total line scores high, a guessed
largest amount scores low. The lens (lens.py) may replace a value only when the
replacement is also grounded in the text.

Multi-page text (Vision OCR, `__PAGE_n__` markers) is read as one document: the
markers are never a supplier, and the total is the last total-labelled line that
carries a currency, on whichever page it sits. A numeric date that reads both ways
(day and month both 12 or less, and different) is flagged `date_ambiguous`. A bare
"$" is `currency_ambiguous` unless the text names its country.
"""

from __future__ import annotations

import re
from .supplier_guard import is_boilerplate
from datetime import date
from typing import Any, Dict, List, Optional, Tuple

MONEY = r"(?P<cur>£|\$|€|HK\$|US\$|GBP|USD|EUR|HKD)?\s?(?P<num>-?\d{1,3}(?:,\d{3})*\.\d{2}|-?\d+\.\d{2})"
_MONEY_RE = re.compile(MONEY)
_PAGE_MARK = re.compile(r"^__PAGE_\d+__$")
_ISO_DATE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_NUM_DATE = re.compile(r"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})\b")
_TEXT_DATE = re.compile(
    r"\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?,?\s+(\d{4})\b"
    r"|\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b",
    re.I,
)
_MONTHS = {m: i + 1 for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}

# Total labels. English (UK, US), Hong Kong Chinese (合計, 總計, 總額, 應付, 實付, 付款金額), and the
# card-confirmation wording ("Payment of ... charged", "amount of this charge") that carries no "total".
TOTAL_LABEL = re.compile(
    r"\b(grand\s+total|total\s*(?:due|paid|charged|amount|payable)?|amount\s+(?:due|paid|payable|charged)"
    r"|amount\s+of\s+this\s+charge|balance(?:\s+due)?|payment\s+of|charged|you\s+paid)\b"
    r"|合計|總計|總額|應付|實付|付款金額",
    re.I,
)
# Lines that carry a money amount but are not the total.
NOT_TOTAL = re.compile(r"\b(sub\s*-?\s*total|net|discount|saving|items?|qty|quantity|change|cash|tendered|tax|vat|gst|sales\s+tax)\b", re.I)
_TAX_LABEL = re.compile(r"\b(vat|gst|sales\s+tax|tax)\b", re.I)
_GENERIC = re.compile(r"^(tax\s+)?(invoice|receipt|orders?|thank\w*|customer|copy|page|date|tel|www|vat\s+no|reg)\b", re.I)
_COMPANY = re.compile(r"\b(ltd|limited|llc|inc|plc|gmbh|co\.?|company|corp|pte|hk)\b", re.I)
_ISO_CUR = re.compile(r"\b(GBP|USD|EUR|HKD)\b")
# Evidence for a bare "$". Hong Kong: a HK address, district, or +852. US: a US address, state and zip, or +1.
_HK_EVIDENCE = re.compile(r"Hong\s+Kong|\bHK\b|\+852|香港|九龍|Kowloon|Kwun\s+Tong|Wan\s+Chai|Central,", re.I)
_US_EVIDENCE = re.compile(r"\bUSA\b|United\s+States|\bU\.S\.|\b[A-Z]{2}\s+\d{5}(?:-\d{4})?\b|\+1[ -]\d{3}", re.I)


def _num(s: str) -> float:
    return float(s.replace(",", ""))


def _strip_pages(text: str) -> List[str]:
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not _PAGE_MARK.match(ln.strip())]


def is_total_line(ln: str) -> bool:
    return bool(TOTAL_LABEL.search(ln)) and not NOT_TOTAL.search(ln) and bool(_MONEY_RE.search(ln))


def pick_total(lines: List[str]) -> Optional[Tuple[str, Any]]:
    """The total: the last total-labelled line with a currency next to its amount, else the last such line.
    Returns (line, money match) or None."""
    cands = [(ln, m) for ln in lines if is_total_line(ln) for m in [list(_MONEY_RE.finditer(ln))[-1]]]
    with_cur = [c for c in cands if c[1].group("cur")]
    pool = with_cur or cands
    return pool[-1] if pool else None


def dollar_currency(text: str) -> Optional[str]:
    """A bare "$" resolves to HKD on Hong Kong evidence, USD on US evidence, else None (Check)."""
    hk = bool(_HK_EVIDENCE.search(text))
    us = bool(_US_EVIDENCE.search(text))
    if hk and not us:
        return "HKD"
    if us and not hk:
        return "USD"
    return None


_DOC_NUMBER = re.compile(
    r"\b(?:tax\s+)?(invoice|receipt|order|voucher|reference|ref|transaction|booking)\s*(?:no\.?|number|num|#|:)\s*"
    r"([A-Za-z0-9][A-Za-z0-9\-/]{2,})", re.I)


def document_numbers(text: str) -> List[str]:
    """Document, invoice, order, voucher or reference numbers printed on the receipt, normalised
    (upper case, letters and digits only), in the order printed. The first is the document's own number."""
    out: List[str] = []
    for m in _DOC_NUMBER.finditer(text):
        n = re.sub(r"[^A-Z0-9]", "", m.group(2).upper())
        if n and n not in out:
            out.append(n)
    return out


def _ambiguous_numeric(text: str) -> bool:
    for m in _NUM_DATE.finditer(text):
        a, b = int(m[1]), int(m[2])
        if a <= 12 and b <= 12 and a != b:
            return True
    return False


def parse_date(text: str, date_order: str = "dmy") -> Optional[date]:
    m = _ISO_DATE.search(text)
    if m:
        return _safe(int(m[1]), int(m[2]), int(m[3]))
    m = _TEXT_DATE.search(text)
    if m:
        if m[2]:
            return _safe(int(m[3]), _MONTHS[m[2][:3].lower()], int(m[1]))
        return _safe(int(m[6]), _MONTHS[m[4][:3].lower()], int(m[5]))
    m = _NUM_DATE.search(text)
    if m:
        a, b, y = int(m[1]), int(m[2]), int(m[3])
        if y < 100:
            y += 2000
        d, mo = (b, a) if date_order == "mdy" else (a, b)
        return _safe(y, mo, d)
    return None


def _safe(y: int, m: int, d: int) -> Optional[date]:
    try:
        return date(y, m, d)
    except ValueError:
        return None


def extract(text: str, *, date_order: str = "dmy") -> Dict[str, Any]:
    """Return fields, confidence and flags. Values are None when absent. Page markers are never values."""
    lines = _strip_pages(text)
    out: Dict[str, Any] = {}
    conf: Dict[str, float] = {}
    flags: Dict[str, bool] = {}

    d = parse_date(text, date_order)
    ambiguous = _ambiguous_numeric(text) and not (_ISO_DATE.search(text) or _TEXT_DATE.search(text))
    flags["date_ambiguous"] = bool(ambiguous)
    out["date"] = d.isoformat() if d else None
    if d and (_ISO_DATE.search(text) or _TEXT_DATE.search(text)):
        conf["date"] = 0.9
    elif d and not ambiguous:
        conf["date"] = 0.6
    else:
        conf["date"] = 0.5 if d else 0.0

    supplier = None
    for ln in lines[:6]:
        if re.search(r"[A-Za-z]{3}", ln) and not _GENERIC.search(ln) and not _MONEY_RE.search(ln) and not is_boilerplate(ln):
            supplier = ln
            break
    out["supplier"] = supplier
    conf["supplier"] = (0.8 if supplier and _COMPANY.search(supplier) else 0.6) if supplier else 0.0

    picked = pick_total(lines)
    if picked:
        ln, m = picked
        out["amount_gross"] = _num(m.group("num"))
        cur_hint = m.group("cur") or None
        conf["amount_gross"] = 0.9
    else:
        amts = [(_num(m.group("num")), m) for ln in lines for m in _MONEY_RE.finditer(ln)]
        amts = [a for a in amts if a[0] > 0]
        if amts:
            top = max(amts, key=lambda a: a[0])
            out["amount_gross"] = top[0]
            cur_hint = top[1].group("cur")
            conf["amount_gross"] = 0.4
        else:
            out["amount_gross"] = None
            cur_hint = None
            conf["amount_gross"] = 0.0

    cur, cc = None, 0.0
    iso = _ISO_CUR.search(text)
    flags["currency_ambiguous"] = False
    if iso:
        cur, cc = iso.group(1), 0.9
    elif cur_hint == "$":
        cur = dollar_currency(text)
        if cur:
            cc = 0.8
        else:
            flags["currency_ambiguous"] = True
    elif cur_hint:
        cur, cc = _cur_from_symbol(cur_hint)
    out["currency"] = cur
    conf["currency"] = cc if cur else 0.0

    tax = None
    for ln in lines:
        if _TAX_LABEL.search(ln) and not TOTAL_LABEL.search(ln) and _MONEY_RE.search(ln):
            tax = _num(list(_MONEY_RE.finditer(ln))[-1].group("num"))
    out["tax_amount"] = tax
    conf["tax_amount"] = 0.8 if tax is not None else 0.0
    return {"fields": out, "confidence": conf, "flags": flags}


def _cur_from_symbol(sym: Optional[str]) -> Tuple[Optional[str], float]:
    if not sym:
        return None, 0.0
    s = sym.strip()
    return {"£": "GBP", "GBP": "GBP", "€": "EUR", "EUR": "EUR", "HK$": "HKD", "HKD": "HKD",
            "US$": "USD", "USD": "USD"}.get(s), 0.8
