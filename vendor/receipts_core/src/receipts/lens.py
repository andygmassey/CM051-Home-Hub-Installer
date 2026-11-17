"""Receipts lens: fields and book from text, on the tier model (qwen3.5:4b).

One call per receipt to the local model over loopback. The model is asked for
JSON. Its answer is only trusted where it is GROUNDED in the source text:

* a supplier must appear in the text (case and spacing ignored);
* an amount must appear as a number in the text;
* a date must equal a date the text actually contains;
* a currency must be named in the text.

A value that fails grounding is dropped to null with confidence 0.0. The lens
can therefore lower confidence or fill a gap, never invent a value that reads as
checked. Book is "business", "personal" or "unsure"; unsure goes to Check.

The endpoint must be loopback. Set RECEIPTS_LENS_URL (default the Studio tunnel
at http://127.0.0.1:21600, see ~/walkdriver/STUDIO_OLLAMA_ANDY.md) and
RECEIPTS_LENS_MODEL (default qwen3.5:4b).
"""

from __future__ import annotations

import json
import os
import re
from .supplier_guard import is_boilerplate, is_owner_or_processor
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

from .extract import TOTAL_LABEL, _PAGE_MARK, _TAX_LABEL, extract, is_total_line, parse_date

DEFAULT_URL = "http://127.0.0.1:21600"
DEFAULT_MODEL = "qwen3.5:4b"
MAX_CHARS = 4000

SCHEMA: Dict[str, Any] = {
    "type": "object",
    "properties": {
        "date": {"type": ["string", "null"]},
        "supplier": {"type": ["string", "null"]},
        "amount_gross": {"type": ["number", "null"]},
        "currency": {"type": ["string", "null"], "enum": ["GBP", "USD", "EUR", "HKD", None]},
        "tax_amount": {"type": ["number", "null"]},
        "book": {"type": "string", "enum": ["business", "personal", "unsure"]},
        "confidence": {
            "type": "object",
            "properties": {k: {"type": "number"} for k in
                           ("date", "supplier", "amount_gross", "currency", "tax_amount", "book")},
        },
    },
    "required": ["date", "supplier", "amount_gross", "currency", "tax_amount", "book", "confidence"],
}

PROMPT = """You read ONE receipt (OCR or PDF text; it may span several pages). Return JSON only.
Rules: copy values exactly as printed. If a field is not clearly printed, return null.
amount_gross is the total paid, as a number. tax_amount is VAT or sales tax printed, else null.
currency is the ISO code of the total. date is YYYY-MM-DD, the transaction date.
book: "business" if it is a business purchase (supplies, software, services for work),
"personal" if it is a personal purchase (food shop, pharmacy, cinema, household),
"unsure" if you cannot tell. Never guess; unsure is correct when in doubt.
amount_gross is the TOTAL line amount (Total, Amount due, Balance), never a line item and never the
net before tax. confidence: 0 to 1 per field, honest. Do not write any other keys.

{context}RECEIPT TEXT:
"""


def _norm(s: str) -> str:
    return re.sub(r"[\s\W_]+", "", s or "").lower()


def ground(parsed: Dict[str, Any], text: str, date_order: str = "dmy", owner_terms=()) -> Dict[str, Any]:
    """Drop every lens value the text does not support. Returns fields + grounded flags."""
    fields: Dict[str, Any] = {}
    grounded: Dict[str, bool] = {}
    t_norm = _norm(text)

    sup = parsed.get("supplier")
    # Role, not presence: the name must sit in the header (the first three non-empty lines), which is
    # where a merchant prints it. Sender-domain and merchant-template matching are not built yet (the
    # text carries no sender address), so they cannot grant a supplier here.
    body = [x for x in text.splitlines() if x.strip() and not _PAGE_MARK.match(x.strip())]
    header = "".join(body[:3])
    flags = extract(text, date_order=date_order)["flags"]
    ok = bool(sup) and len(_norm(sup)) >= 3 and _norm(sup) in _norm(header)
    if ok and (is_boilerplate(sup) or is_owner_or_processor(sup, owner_terms)):
        ok = False   # a label, a processor or the owner is never the merchant
    fields["supplier"] = sup if ok else None
    grounded["supplier"] = ok

    for key in ("amount_gross", "tax_amount"):
        v = parsed.get(key)
        ok = False
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            pat = r"(?<![\d.])" + re.escape(f"{abs(float(v)):,.2f}") + r"(?!\d)"
            pat2 = r"(?<![\d.])" + re.escape(f"{abs(float(v)):.2f}") + r"(?!\d)"
            ok = bool(re.search(pat, text) or re.search(pat2, text))
            if ok and key == "amount_gross":
                ok = total_role(text, abs(float(v)))   # present is not enough: it must be the TOTAL
        fields[key] = float(v) if ok else None
        grounded[key] = ok

    d = parsed.get("date")
    ok = False
    if isinstance(d, str) and not flags.get("date_ambiguous"):   # an ambiguous numeric date is never grounded
        want = parse_date(d, date_order)
        found = {parse_date(m.group(0), date_order) for m in re.finditer(r"\d{4}-\d{2}-\d{2}|\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{4}", text)}
        ok = want is not None and want in found
        fields["date"] = want.isoformat() if ok else None
    else:
        fields["date"] = None
    grounded["date"] = ok

    cur = parsed.get("currency")
    ok = isinstance(cur, str) and cur in {"GBP", "USD", "EUR", "HKD"} and (
        cur in text or {"GBP": "£", "USD": "$", "EUR": "€", "HKD": "HK$"}[cur] in text)
    if ok and flags.get("currency_ambiguous") and cur not in text:
        ok = False                                    # a bare "$" names no currency: the model may not pick one
    fields["currency"] = cur if ok else None
    grounded["currency"] = ok

    book = parsed.get("book") if parsed.get("book") in {"business", "personal", "unsure"} else "unsure"
    fields["book"] = book
    grounded["book"] = True
    fields["book_confidence"] = _conf(parsed, "book")
    return {"fields": fields, "grounded": grounded}


def _conf(parsed: Dict[str, Any], key: str) -> float:
    """The model's own confidence for a field, clamped to 0..1. Missing means 0, never a default."""
    try:
        return max(0.0, min(1.0, float((parsed.get("confidence") or {}).get(key, 0.0))))
    except (TypeError, ValueError):
        return 0.0


_MONEY_ANY = re.compile(r"-?\d{1,3}(?:,\d{3})*\.\d{2}|-?\d+\.\d{2}")


def total_role(text: str, value: float) -> bool:
    """True when `value` is the receipt's TOTAL: printed on a total line (Total, Amount due, Balance), or
    equal to the sum of the non-total, non-tax amounts plus the tax printed (net plus tax). A number that
    merely appears elsewhere (a line item, the net) is not enough."""
    lines = [ln for ln in text.splitlines() if ln.strip() and not _PAGE_MARK.match(ln.strip())]
    for ln in lines:
        if is_total_line(ln):
            if any(abs(float(m.group(0).replace(",", "")) - value) < 0.005 for m in _MONEY_ANY.finditer(ln)):
                return True
    tax = 0.0
    items = 0.0
    for ln in lines:
        nums = [float(m.group(0).replace(",", "")) for m in _MONEY_ANY.finditer(ln)]
        if not nums:
            continue
        if _TAX_LABEL.search(ln) and not TOTAL_LABEL.search(ln):
            tax += nums[-1]
        elif not TOTAL_LABEL.search(ln):
            items += nums[-1]
    return items + tax > 0 and abs(items + tax - value) < 0.02


class LensUnavailable(RuntimeError):
    """The model did not answer. Callers record reason `lens_unavailable` and use the control."""


def prompt_text(text: str, limit: int = MAX_CHARS) -> str:
    """The text the model reads. Short receipts go whole. A long document keeps its head (the merchant),
    its tail, and EVERY total-labelled line from every page, so a total on page two is never cut off."""
    lines = [ln for ln in text.splitlines() if ln.strip() and not _PAGE_MARK.match(ln.strip())]
    body = "\n".join(lines)
    if len(body) <= limit:
        return body
    head = "\n".join(lines[:12])
    tail = "\n".join(lines[-40:])
    totals = [ln for ln in lines if is_total_line(ln)]
    kept = "\n".join(dict.fromkeys(totals))
    return "\n".join([head, "...", kept, "...", tail])[: limit * 2]


class OllamaLens:
    def __init__(self, url: Optional[str] = None, model: Optional[str] = None, seed: int = 1,
                 timeout: float = 120.0, context: Optional[str] = None):
        self.context = (context or "").strip()
        self.url = (url or os.environ.get("RECEIPTS_LENS_URL") or DEFAULT_URL).rstrip("/")
        self.model = model or os.environ.get("RECEIPTS_LENS_MODEL") or DEFAULT_MODEL
        self.seed = seed
        self.timeout = timeout
        if not re.match(r"^http://(127\.0\.0\.1|localhost)(:\d+)?$", self.url):
            raise ValueError("lens endpoint must be loopback http")
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def prompt_for(self, text: str, candidates=None) -> str:
        ctx = (self.context + "\n\n") if self.context else ""
        if candidates is not None:
            ctx += ("SUPPLIER CANDIDATES. The supplier must be exactly one of these, or null if none is the merchant:\n"
                    + "\n".join(f"- {c}" for c in candidates) + "\n\n")
        return PROMPT.format(context=ctx) + prompt_text(text)

    def ask(self, text: str, candidates=None) -> Dict[str, Any]:
        body = {
            "model": self.model,
            "stream": False,
            "think": False,
            "format": SCHEMA,
            "options": {"temperature": 0, "seed": self.seed, "num_predict": 400},
            "messages": [{"role": "user", "content": self.prompt_for(text, candidates)}],
        }
        req = urllib.request.Request(self.url + "/api/chat", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                payload = json.loads(resp.read().decode())
            return json.loads(payload["message"]["content"])
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            raise LensUnavailable(type(e).__name__) from e
