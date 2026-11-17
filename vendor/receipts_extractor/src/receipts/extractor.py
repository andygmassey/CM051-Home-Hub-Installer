"""Orchestrates classify, extract, privacy scrub and the idempotent store."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Set

from .classify import classify
from .llm_fallback import LocalLLM, extract_with_llm
from .merchants import BY_KEY, Merchant, lookup
from .mime import ParsedMessage, parse_bytes
from .models import Receipt
from .privacy import scrub_row
from .structured import extract_structured
from .templates import TEMPLATES, is_complete

_RECEIPT_FIELDS = set(Receipt.__dataclass_fields__)


@dataclass
class Result:
    status: str  # receipt, not_receipt, duplicate, unparsed, needs_llm
    reason: str = ""
    receipt: Optional[Receipt] = None


class ReceiptStore:
    """JSONL store, one receipt per message-id. Re-adding is a no-op."""

    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path) if path else None
        self.rows: Dict[str, Dict[str, Any]] = {}
        if self.path and self.path.exists():
            for line in self.path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    row = json.loads(line)
                    self.rows[row["message_id"]] = row

    def __contains__(self, message_id: str) -> bool:
        return message_id in self.rows

    def add(self, receipt: Receipt) -> bool:
        if receipt.message_id in self.rows:
            return False
        self.rows[receipt.message_id] = receipt.to_dict()
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(json.dumps(receipt.to_dict(), sort_keys=True) + "\n")
        return True

    def all(self) -> List[Dict[str, Any]]:
        return list(self.rows.values())


def resolve_merchant(msg: ParsedMessage) -> Optional[Merchant]:
    m = lookup(msg.from_domain)
    if m and m.key == "uber" and re.search(r"uber eats|order with|receipt for", msg.subject + "\n" + msg.text, re.I):
        return BY_KEY["ubereats"]
    return m


class ReceiptExtractor:
    def __init__(self, store: Optional[ReceiptStore] = None, llm: Optional[LocalLLM] = None):
        self.store = store or ReceiptStore()
        self.llm = llm
        self.stats: Dict[str, int] = {}

    # -------------------------------------------------------------- core
    def extract(self, msg: ParsedMessage) -> Result:
        if msg.message_id in self.store:
            return Result("duplicate")
        verdict = classify(msg)
        if not verdict.is_receipt:
            return Result("not_receipt", verdict.reason)
        merchant = resolve_merchant(msg)

        partial: Optional[Dict[str, Any]] = None
        method = "template"
        if merchant and merchant.key in TEMPLATES:
            cand = TEMPLATES[merchant.key](msg, merchant)
            if is_complete(cand):
                partial = cand
        if partial is None:
            s = extract_structured(msg)
            if s:
                partial, method = s, s.pop("method")
        if partial is None and self.llm is not None:
            s = extract_with_llm(self.llm, msg)
            if s:
                partial, method = s, "llm"
        if partial is None:
            return Result("unparsed" if self.llm is not None else "needs_llm", verdict.reason)

        receipt = self._build(msg, merchant, partial, method)
        if receipt is None:
            return Result("unparsed", "no category")
        return Result("receipt", verdict.reason, receipt)

    def _build(self, msg, merchant, p: Dict[str, Any], method: str) -> Optional[Receipt]:
        notes = list(p.get("notes") or [])
        category = (merchant.category if merchant and method != "llm" and p.get("category") in (None, "retail")
                    and merchant.category != "retail" else None) or p.get("category") \
            or (merchant.category if merchant else None)
        if not category:
            return None
        name = (merchant.name if merchant else None) or p.get("merchant") or msg.from_name or msg.from_domain
        when = p.get("occurred_at")
        if not when and msg.date:
            when = msg.date.isoformat(timespec="minutes")
            notes.append("date:header")
        fields = {k: v for k, v in p.items() if k in _RECEIPT_FIELDS and k not in
                  ("message_id", "merchant", "category", "occurred_at", "notes", "method")}
        r = Receipt(message_id=msg.message_id, merchant=name, category=category,
                    occurred_at=when, method=method, sender_domain=msg.from_domain,
                    service=(merchant.service if merchant else None), notes=notes, **{
                        k: v for k, v in fields.items() if k != "service"})
        if not r.currency and merchant:
            r.currency = merchant.currency
        # privacy scrub: any sensitive string is nulled before the row can leave
        clean = scrub_row(r.to_dict(), keep=("message_id",))
        return Receipt(**{k: v for k, v in clean.items() if k in _RECEIPT_FIELDS})

    # -------------------------------------------------------------- drivers
    def process_message(self, msg: ParsedMessage) -> Result:
        res = self.extract(msg)
        if res.status == "receipt":
            if not self.store.add(res.receipt):
                res = Result("duplicate")
        self.stats[res.status] = self.stats.get(res.status, 0) + 1
        return res

    def process_bytes(self, raw: bytes) -> Result:
        return self.process_message(parse_bytes(raw))

    def process_many(self, raws: Iterable[bytes]) -> List[Result]:
        return [self.process_bytes(r) for r in raws]
