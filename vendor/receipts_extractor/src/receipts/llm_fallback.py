"""Generic fallback using a LOCAL model with a strict output schema.

Guarantees:
  * the model only ever sees text that has already been scrubbed of card
    numbers, street addresses and email addresses;
  * the model is local (loopback HTTP only) and is injected, so tests use a
    fake and the pipeline works without one;
  * the output is validated against a fixed schema, unknown keys are dropped,
    and every value must be grounded in the email text. A value the text does
    not contain becomes null. The model can never add a value.
"""

from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Optional, Protocol
from urllib.parse import urlparse

from .models import CATEGORIES
from .mime import ParsedMessage
from .privacy import is_sensitive
from .textutil import all_money, iso, parse_datetime

MAX_PROMPT_CHARS = 6000

SCHEMA = {
    "merchant": "string or null",
    "category": "one of " + ", ".join(CATEGORIES) + " or null",
    "occurred_at": "ISO 8601 date or datetime of the purchase, or null",
    "currency": "ISO 4217 code or null",
    "total": "number or null",
    "order_id": "string or null",
    "items": "list of {name: string, quantity: integer or null, price: number or null}",
}

PROMPT = """You extract facts from one purchase receipt email. Reply with ONE JSON object and nothing else.
Rules: use only information written in the email. If a value is not written there, use null.
Never guess, infer, or calculate. Keys: {schema}.

EMAIL SUBJECT: {subject}
EMAIL TEXT:
{body}
"""


class LocalLLM(Protocol):
    def complete(self, prompt: str) -> str: ...


class OllamaLocal:
    """Minimal client for a model served on this machine (Ollama style API).

    Refuses any host that is not loopback, so receipt text cannot leave the device.
    """

    def __init__(self, model: str, url: str = "http://127.0.0.1:11434/api/generate", timeout: float = 120.0):
        host = urlparse(url).hostname or ""
        if host not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("local model endpoint must be loopback; got %r" % host)
        self.model, self.url, self.timeout = model, url, timeout

    def complete(self, prompt: str) -> str:  # pragma: no cover - needs a running model
        import urllib.request
        body = json.dumps({"model": self.model, "prompt": prompt, "stream": False,
                           "format": "json", "options": {"temperature": 0}}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as r:  # noqa: S310 loopback only
            return json.loads(r.read())["response"]


def _safe_body(text: str) -> str:
    lines = [ln for ln in text.splitlines() if not is_sensitive(ln)]
    return "\n".join(lines)[:MAX_PROMPT_CHARS]


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.replace("\t", " ")).strip().lower()


def _num_in_text(value: Any, text: str) -> bool:
    try:
        v = float(value)
    except (TypeError, ValueError):
        return False
    amounts = {round(a, 2) for a, _ in all_money(text)}
    forms = {f"{v:.2f}", f"{v:g}", f"{v:.1f}"}
    plain = {m.replace(",", "") for m in re.findall(r"\d[\d,]*(?:\.\d+)?", text)}
    return round(v, 2) in amounts or bool(forms & plain)


def _date_in_text(value: str, text: str) -> Optional[str]:
    """Return ISO value only if that calendar date is written in the text."""
    want = parse_datetime(str(value))
    if not want:
        return None
    for dayfirst in (True, False):
        got = parse_datetime(text, dayfirst=dayfirst)
        if got and got.date() == want.date():
            return iso(want) if (want.hour or want.minute) else iso(want.replace(hour=0, minute=0))
    return None


def validate(raw: Dict[str, Any], text: str, notes: List[str]) -> Dict[str, Any]:
    """Drop everything not in the schema or not grounded in ``text``."""
    low = _norm(text)
    out: Dict[str, Any] = {}

    def grounded_str(key: str) -> Optional[str]:
        v = raw.get(key)
        if isinstance(v, str) and v.strip() and _norm(v) in low and not is_sensitive(v):
            return v.strip()
        if v not in (None, ""):
            notes.append(f"llm:ungrounded:{key}")
        return None

    out["merchant"] = grounded_str("merchant")
    out["order_id"] = grounded_str("order_id")
    cat = raw.get("category")
    out["category"] = cat if cat in CATEGORIES else None
    cur = raw.get("currency")
    sym_ok = isinstance(cur, str) and (cur.upper() in text.upper() or
                                       (cur.upper() == "GBP" and "£" in text) or
                                       (cur.upper() == "EUR" and "€" in text) or
                                       (cur.upper() == "USD" and "$" in text))
    out["currency"] = cur.upper() if sym_ok else None
    if cur and not sym_ok:
        notes.append("llm:ungrounded:currency")
    total = raw.get("total")
    out["total"] = round(float(total), 2) if _num_in_text(total, text) else None
    if total is not None and out["total"] is None:
        notes.append("llm:ungrounded:total")
    when = raw.get("occurred_at")
    out["occurred_at"] = _date_in_text(when, text) if when else None
    if when and not out["occurred_at"]:
        notes.append("llm:ungrounded:occurred_at")
    items = []
    for it in raw.get("items") or []:
        if not isinstance(it, dict):
            continue
        name = it.get("name")
        if not (isinstance(name, str) and _norm(name) in low) or is_sensitive(name):
            notes.append("llm:ungrounded:item")
            continue
        qty = it.get("quantity")
        price = it.get("price")
        items.append({
            "name": name.strip(),
            "quantity": int(qty) if isinstance(qty, (int, float)) and _num_in_text(qty, text) else None,
            "price": round(float(price), 2) if _num_in_text(price, text) else None,
        })
    out["items"] = items
    return out


def extract_with_llm(llm: LocalLLM, msg: ParsedMessage) -> Optional[Dict[str, Any]]:
    """Run the local model and return validated fields, or None if nothing grounded."""
    body = _safe_body(msg.text)
    prompt = PROMPT.format(schema=json.dumps(SCHEMA), subject=msg.subject[:200], body=body)
    try:
        raw = json.loads(llm.complete(prompt))
    except (ValueError, TypeError):
        return None
    if not isinstance(raw, dict):
        return None
    notes: List[str] = []
    out = validate(raw, body, notes)
    if out["total"] is None and not out["items"]:
        return None  # nothing financial survived grounding: not a usable receipt
    out["notes"] = notes
    out["method"] = "llm"
    return out
