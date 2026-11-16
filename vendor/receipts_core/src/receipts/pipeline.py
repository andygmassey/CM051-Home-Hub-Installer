"""Ingest one document (file, email row or iOS upload) into the books.

Order: hash (never ingest the same bytes twice) -> extract (lens, else control)
-> book decision -> duplicate check across routes -> statement match and FX ->
filing COPY -> status. Nothing here deletes, moves or re-encodes a file. Filing
copies the original with copy2 and checks the bytes; the source stays where it was.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import unicodedata
from difflib import SequenceMatcher
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

from .extract import document_numbers, extract
from .lens import LensUnavailable, OllamaLens, ground
from .names import normalise_supplier
from . import model, presets
from .model import BOOK_THRESHOLD, SOURCE_RANK, decide_status, new_record
from .store import Store, new_id, supplier_key

# Control book rule: used only when the lens is unavailable (the "no lens" state).
_BIZ = re.compile(r"\b(invoice|vat\s*no|software|saas|subscription|ltd|limited|hosting|licence|license)\b", re.I)
_PERS = re.compile(r"\b(groceries|pharmacy|chemist|cinema|takeaway|restaurant|cafe|bakery|supermarket)\b", re.I)
AMOUNT_TOL = 0.01          # 1 percent, for duplicates and statement matches
MATCH_DAYS = 3
MISSING_AFTER_DAYS = 14
RateFn = Callable[[date, str, str], Optional[Tuple[float, str]]]
LENS_FIELDS = ("date", "supplier", "amount_gross", "currency", "tax_amount")
REQUIRED_CONFIRM = ("date", "supplier", "amount_gross", "currency")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slug(text: Optional[str], limit: int = 40, fallback: str = "unknown") -> str:
    s = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-")[:limit].strip("-")
    return s or fallback


def control_book(text: str) -> str:
    if _BIZ.search(text):
        return "business"
    if _PERS.search(text):
        return "personal"
    return "unsure"


def filed_name(rec: Dict[str, Any], ext: str) -> str:
    amt = f"{rec['amount_gross']:.2f}" if rec.get("amount_gross") is not None else "no-amount"
    base = "_".join([rec.get("date") or "undated", slug(rec.get("supplier")), f"{amt}-{rec.get('currency') or 'XXX'}",
                     slug(rec.get("category") or "uncategorised", 30)])
    return base + ext


def line_id(t: Any) -> str:
    """Stable id for a statement line (#401 Transaction). No account data is in it."""
    key = f"{t.date.isoformat()}|{t.amount:.2f}|{t.currency}|{t.merchant_key}|{t.raw_description}"
    return "stmt_" + hashlib.sha256(key.encode()).hexdigest()[:16]


def date_order_for(book: Dict[str, Any]) -> str:
    """The book's own date locale: us reads month/day, uk and hk read day/month. Books made before the
    locale existed fall back to the home currency (USD is US)."""
    locale = book.get("date_locale") or ("us" if book.get("home_currency") == "USD" else "uk")
    return "mdy" if locale == "us" else "dmy"


def business_books(store: Store) -> List[Dict[str, Any]]:
    return [b for b in store.books("business") if b.get("enabled", True)]


def personal_book(store: Store) -> Optional[Dict[str, Any]]:
    if not store.personal_enabled:
        return None
    ps = store.books("personal")
    return ps[0] if ps else None


def _match_statement(rec: Dict[str, Any], statements: Iterable[Any], claimed: set) -> Optional[Any]:
    gross, cur, when = rec.get("amount_gross"), rec.get("currency"), rec.get("date")
    if gross is None or not cur or not when:
        return None
    d = date.fromisoformat(when)
    tol = AMOUNT_TOL * gross + 0.005
    for t in statements:
        if t.amount >= 0 or abs((t.date - d).days) > MATCH_DAYS or line_id(t) in claimed:
            continue
        same_cur = t.currency == cur and abs(abs(t.amount) - gross) <= tol
        foreign = bool(t.orig_currency == cur and t.orig_amount) and abs(abs(t.orig_amount) - gross) <= tol
        if same_cur or foreign:
            return t
    return None


def _fx(rec: Dict[str, Any], home: Optional[str], stmt: Any, rate_fn: Optional[RateFn]) -> Optional[str]:
    """Set amount_home. Returns a reason code when a rate was needed and not found."""
    cur, gross = rec.get("currency"), rec.get("amount_gross")
    if not home or not cur or gross is None:
        return None
    if cur == home:
        rec.update(amount_home=gross, fx_rate=1.0, fx_source="same-currency")
        return None
    if stmt is not None and stmt.currency == home:
        home_amt = abs(stmt.amount)
        rec.update(amount_home=home_amt, fx_rate=round(home_amt / gross, 6), fx_source="statement-actual")
        return None
    got = rate_fn(date.fromisoformat(rec["date"]), cur, home) if (rate_fn and rec.get("date")) else None
    if got:
        rate, source = got
        rec.update(amount_home=round(gross * rate, 2), fx_rate=rate, fx_source=source)
        return None
    return "no_fx_rate"


def _same_supplier(a: Optional[str], b: Optional[str]) -> bool:
    """OCR and email print the same supplier differently; a near match counts, a different name does not."""
    ka, kb = supplier_key(a), supplier_key(b)
    if not ka or not kb:
        return False
    return ka == kb or ka in kb or kb in ka or SequenceMatcher(None, ka, kb).ratio() >= 0.8


def _owner_rule_book(store: Store, supplier: Optional[str]) -> Optional[Dict[str, Any]]:
    """The book the owner tied this supplier to, if any. A rule is the owner's decision, not a guess."""
    if not supplier:
        return None
    book_id = store.supplier_rules().get(normalise_supplier(supplier))
    return store.get_book(book_id) if book_id else None


def _primary(rec: Dict[str, Any]) -> Optional[str]:
    nums = rec.get("doc_numbers") or []
    return nums[0] if nums else None


def _find_related(store: Store, rec: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Different documents that cite each other: an order acknowledgement and the invoice that bills it.
    Linked, never merged: each keeps its own amount, date and file."""
    out = []
    mine = _primary(rec)
    for other in store.receipts():
        if other["id"] == rec.get("id") or not mine:
            continue
        theirs = _primary(other)
        if not theirs or theirs == mine:
            continue
        if mine in (other.get("doc_numbers") or [])[1:] or theirs in (rec.get("doc_numbers") or [])[1:]:
            out.append(other)
    return out


def _same_money_and_day(other: Dict[str, Any], rec: Dict[str, Any]) -> bool:
    """Same date, same resolved currency, same amount within 1 percent, same supplier. An unresolved
    currency (None) is never equal to another unresolved currency."""
    if not rec.get("date") or rec.get("amount_gross") is None or not rec.get("currency"):
        return False
    return (other.get("date") == rec["date"] and other.get("currency") == rec["currency"]
            and other.get("amount_gross") is not None
            and abs(other["amount_gross"] - rec["amount_gross"]) <= AMOUNT_TOL * max(rec["amount_gross"], 0.01)
            and _same_supplier(other.get("supplier"), rec.get("supplier")))


def _find_duplicate(store: Store, rec: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Two receipts are one document only when they agree on everything a copy would share. A document
    number is necessary when both carry one (different numbers are never duplicates), and it is not
    sufficient on its own: a reference printed on two receipts is not the same document. Without numbers
    on both sides, the same day, resolved currency, amount and supplier decide."""
    mine = _primary(rec)
    for other in store.receipts():
        theirs = _primary(other)
        if mine and theirs:
            if mine == theirs and _same_money_and_day(other, rec):
                return other
            continue
        if _same_money_and_day(other, rec):
            return other
    return None


def _merge_lens(fields: Dict[str, Any], conf: Dict[str, float], parsed: Dict[str, Any], text: str,
                date_order: str, reasons: List[str], owner_terms=()) -> Tuple[str, float]:
    """Lens values replace control values only when grounded. Returns (lens book, the model's own book
    confidence). Book confidence is never a constant: the caller decides from it."""
    g = ground(parsed, text, date_order, owner_terms=owner_terms)
    for k in LENS_FIELDS:
        if g["grounded"][k]:
            fields[k] = g["fields"][k]
            conf[k] = _model_conf(parsed, k)
        elif fields.get(k) is not None and k != "amount_gross":
            reasons.append(f"lens_ungrounded:{k}")   # keep the control value, at its own confidence
        else:
            if k == "amount_gross" and fields.get(k) is not None:
                reasons.append("lens_ungrounded:amount_gross")   # the control's guess is not a total either
            fields[k] = None if k == "amount_gross" else fields.get(k)
            conf[k] = 0.0
    return g["fields"]["book"], g["fields"]["book_confidence"]


def _model_conf(parsed: Dict[str, Any], key: str) -> float:
    from .lens import _conf
    return _conf(parsed, key)


def ingest(store: Store, *, source: str, text: str, files_root: Path,
           source_path: Optional[Path] = None, data: Optional[bytes] = None, ext: str = "",
           lens: Optional[OllamaLens] = None, statements: Iterable[Any] = (),
           rate_fn: Optional[RateFn] = None, original_name: str = "",
           prefilled: Optional[Dict[str, Any]] = None, boxes=None, sender: Optional[str] = None) -> Dict[str, Any]:
    """Ingest one document. Returns {outcome, receipt_id?, status?, reasons}. Never raises on a bad document.

    Either `source_path` (a file: folder, share, photo; copied on filing) or `data` (bytes with no
    file, e.g. an email row) must be given. `text` is the OCR or PDF text, or the email body text.
    """
    if source not in SOURCE_RANK:
        return {"outcome": "invalid", "reasons": ["unknown_source"]}
    if source_path is not None:
        data = Path(source_path).read_bytes()
        ext = ext or Path(source_path).suffix
        original_name = original_name or Path(source_path).name
    sha = hashlib.sha256(data or text.encode()).hexdigest()
    if store.has_sha(sha):
        return {"outcome": "known", "reasons": []}

    biz = business_books(store)
    home = biz[0]["home_currency"] if len(biz) == 1 else None
    date_order = date_order_for(biz[0]) if len(biz) == 1 else "dmy"

    det = extract(text, date_order=date_order)
    fields, conf = dict(det["fields"]), dict(det["confidence"])
    reasons: List[str] = []
    if det["flags"].get("date_ambiguous"):
        reasons.append("date_ambiguous")          # a numeric date reads both ways: Check, never a guess
    if det["flags"].get("currency_ambiguous"):
        reasons.append("currency_ambiguous")      # a bare "$" with no HK or US evidence: Check
    book_decision = control_book(text)
    book_guess = None
    book_raw, book_conf = None, 0.0
    # Positive supplier selection: the supplier must be one of the candidates, or it is Check.
    from .candidates import supplier_candidates, qualifies
    _remembered = [e.get("supplier") for e in (store.get_kv("supplier_fingerprints", {}) or {}).values()
                   if isinstance(e, dict) and e.get("supplier")]
    cands = supplier_candidates(text, boxes=boxes, sender=sender, remembered=_remembered,
                                owner_terms=store.get_kv("owner_terms", []) or [])
    if prefilled is not None:
        # Structured fields from a sender-side extractor (email-intelligence #8). Values are its own, not ours to ground.
        fields.update({k: prefilled.get(k) for k in LENS_FIELDS if prefilled.get(k) is not None})
        for k in LENS_FIELDS:
            conf[k] = 0.9 if fields.get(k) is not None else 0.0
        # The sender-side extractor's book is a GUESS, never a filing (owner rule 2026-11-15: prefill-only).
        # Before this change a prefilled 'business' filed straight into the one business book.
        extractor_book = prefilled.get("book") if prefilled.get("book") in ("business", "personal") else None
        book_guess, book_decision = (extractor_book or book_decision), "unsure"
    elif lens is None:
        reasons.append("lens_unavailable")
        book_guess, book_decision = book_decision, "unsure"   # no lens: the keyword guess is shown, never filed
    else:
        try:
            parsed = lens.ask(text, candidates=cands)
            book_decision, book_conf = _merge_lens(fields, conf, parsed, text, date_order, reasons, owner_terms=store.get_kv('owner_terms', []) or [])
            book_raw = book_decision
            if not model.LENS_CAN_FILE:
                book_guess = book_decision         # shown on the Check screen, never filed
                book_decision = "unsure"
                reasons.append("lens_prefill_only")
            if book_conf < BOOK_THRESHOLD:
                book_decision = "unsure"           # the model is not sure enough of the book: Check
                reasons.append("book_low_conf")
        except LensUnavailable:
            reasons.append("lens_unavailable")
            book_guess, book_decision = book_decision, "unsure"

    # Layout (Vision or PDF boxes): fill a missing total from a total line; note whether the total is on one.
    owner_terms = store.get_kv("owner_terms", []) or []
    total_on_line = False
    if boxes:
        from .layout import layout_supplier, layout_total
        lt = layout_total(boxes)
        if lt is not None:
            if fields.get("amount_gross") is None:
                fields["amount_gross"], conf["amount_gross"] = lt[1], 0.8
            total_on_line = abs(float(fields["amount_gross"]) - lt[1]) < 0.005
        if fields.get("supplier") is None:
            ls = layout_supplier(boxes, owner_terms)
            if ls:
                fields["supplier"], conf["supplier"] = ls, 0.7
    if fields.get("supplier") is not None and not qualifies(fields.get("supplier"), cands):
        fields["supplier"], conf["supplier"] = None, 0.0
        reasons.append("supplier_not_a_candidate")
    from .memory import sender_domain
    rec = new_record(id=new_id("rcpt_", sha), source=source, created_at=_now())
    rec["sender_domain"] = sender_domain(sender)
    rec["total_on_total_line"] = total_on_line
    rec.update({k: fields.get(k) for k in LENS_FIELDS})
    rec["confidence"] = {k: round(float(conf.get(k, 0.0)), 3) for k in LENS_FIELDS}
    rec["confidence"]["book"] = round(book_conf, 3) if lens is not None and "lens_unavailable" not in reasons else 0.0
    rec["book_raw"] = book_raw if lens is not None and "lens_unavailable" not in reasons else None
    rec["book_guess"] = book_guess
    rec["description"] = ocr_description(text, rec.get("supplier"))
    rec["file_sha256"] = sha
    rec["original_name"] = original_name or None
    rec["doc_numbers"] = document_numbers(text)

    # The owner's supplier rule is the owner's decision: it files, and it overrides the lens's guess.
    rule_book = _owner_rule_book(store, rec.get("supplier"))
    rule_ok = rule_book is not None and (
        (rule_book.get("kind") == "business" and rule_book.get("enabled", True))
        or (rule_book.get("kind") == "personal" and store.personal_enabled))
    if rule_ok:
        book_decision = rule_book["kind"]
        reasons.append("owner_rule")

    if rule_ok:
        rec["book_id"], rec["book_decision"] = rule_book["id"], book_decision
    elif book_decision == "personal":
        pb = personal_book(store)
        if pb is None:
            return {"outcome": "not_stored", "reasons": ["personal_book_off"]}
        rec["book_id"], rec["book_decision"] = pb["id"], "personal"
    elif book_decision == "business" and len(biz) == 1:
        rec["book_id"], rec["book_decision"] = biz[0]["id"], "business"
    else:
        rec["book_id"], rec["book_decision"] = None, "unsure"
        remembered = store.supplier_book(rec.get("supplier"))
        if remembered:
            reasons.append("book_suggested")           # a suggestion, never a decision
            rec["suggested_book_id"] = remembered

    # Learn-once memory: a supplier the owner confirmed before, with its total on a total line and a
    # resolved currency that agrees, files as ok. Otherwise it stays on Check.
    if rec.get("book_id") is None:
        from .memory import auto_file_ok
        mem = store.recall_supplier_fp(rec)
        mb = store.get_book(mem["book"]) if mem and mem.get("book") else None
        if mb and mb.get("kind") == "business" and auto_file_ok(mem, rec):
            rec["book_id"], rec["book_decision"] = mb["id"], "business"
            rec["auto_filed_by"] = "supplier_memory"
            book_decision = "business"

    dup = _find_duplicate(store, rec)
    if dup is not None:
        dup.setdefault("duplicates", []).append({"source": source, "file_sha256": sha})
        store.put_receipt(dup)
        return {"outcome": "duplicate", "receipt_id": dup["id"], "reasons": []}
    for other in _find_related(store, rec):
        rec["related_ids"] = sorted(set(rec.get("related_ids", []) + [other["id"]]))
        other["related_ids"] = sorted(set(other.get("related_ids", []) + [rec["id"]]))
        store.put_receipt(other)

    stmt = None
    claimed = {r.get("statement_line_id") for r in store.receipts() if r.get("statement_line_id")}
    if rec.get("amount_gross") is not None:
        stmt = _match_statement(rec, statements, claimed)
    if stmt is not None:
        rec["statement_line_id"] = line_id(stmt)
    fx_reason = _fx(rec, home, stmt, rate_fn)   # home is the single business book's currency, Check or not
    if fx_reason:
        reasons.append(fx_reason)
    if home and rec.get("book_id") is None and rec.get("currency") not in (None, home):
        reasons.append("no_fx_rate")

    rec["file"] = original_name or None
    rec["source_path"] = str(source_path) if source_path is not None else None
    if rec.get("book_id") and data is not None and source_path is not None:
        file_into_book(store, rec, store.get_book(rec["book_id"]), Path(source_path), ext, files_root, sha)

    decide_status(rec, extra_reasons=reasons)
    store.put_receipt(rec)
    return {"outcome": "stored", "receipt_id": rec["id"], "status": rec["status"], "reasons": rec["reasons"]}


def placeholder(store: Store, *, path: Path, source: str, text: str, files_root: Path) -> Dict[str, Any]:
    """A `processing` row for an upload whose lens has not run yet. It holds no sha column value, so it
    never counts as a duplicate or as known bytes; the finishing ingest replaces it under the same id."""
    data = Path(path).read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    if store.has_sha(sha):
        return {"outcome": "known", "receipt_id": new_id("rcpt_", sha)}
    rid = new_id("rcpt_", sha)
    rec = new_record(id=rid, source=source, created_at=_now())
    rec.update(status="processing", reasons=[], file=Path(path).name, file_sha256=sha, file_path=None)
    rec["file_sha256"] = None          # the sha column stays empty until the finishing ingest
    rec["pending_sha256"] = sha
    store.put_receipt(rec)
    return {"outcome": "processing", "receipt_id": rid}


def _filed_target(rec: Dict[str, Any], book: Dict[str, Any], files_root: Path) -> Path:
    """Where the copy belongs right now: book folder, year, month, and the name from the CURRENT fields."""
    d = rec.get("date")
    folder = files_root / slug(book["name"], 60, "Book") / (d[:4] if d else "undated") / (d[5:7] if d else "undated")
    ext = rec.get("ext") or ""
    target = folder / filed_name(rec, ext)
    n = 2
    while target.exists():
        target = folder / (filed_name(rec, "").rstrip(".") + f"_{n}" + ext)
        n += 1
    return target


def file_into_book(store: Store, rec: Dict[str, Any], book: Dict[str, Any], source_path: Path, ext: str,
                   files_root: Path, sha: str) -> None:
    """Copy the original into the book tree and check the bytes. Sets rec file, file_path, ext.
    The original stays where it was. A copy that fails its checksum is removed (our copy, not the original)."""
    rec["category"] = rec.get("category") or presets.UNCATEGORISED
    rec["ext"] = ext
    target = _filed_target(rec, book, files_root)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_path, target)
    if hashlib.sha256(target.read_bytes()).hexdigest() != sha:
        target.unlink()
        raise OSError("copy_verify_failed")
    rec["file"] = target.name
    rec["file_path"] = str(target.relative_to(files_root))


def refile(rec: Dict[str, Any], book: Dict[str, Any], files_root: Path) -> bool:
    """Move OUR COPY to the name and folder the current fields give. The original is never touched.
    Returns True when the copy moved. Verifies the bytes after the move."""
    if not rec.get("file_path"):
        return False
    cur = files_root / rec["file_path"]
    if not cur.exists():
        raise OSError("filed_copy_missing")
    target = _filed_target(rec, book, files_root)
    if target.resolve() == cur.resolve():
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(cur), str(target))
    if hashlib.sha256(target.read_bytes()).hexdigest() != rec.get("file_sha256"):
        raise OSError("refile_verify_failed")
    rec["file"] = target.name
    rec["file_path"] = str(target.relative_to(files_root))
    return True


def is_filed(rec: Dict[str, Any], files_root: Path) -> bool:
    return bool(rec.get("file_path")) and (files_root / rec["file_path"]).exists()


def ocr_description(text: str, supplier: Optional[str]) -> Optional[str]:
    """First item line from the OCR text: letters, a money amount, not a total or tax line. Never invented."""
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln or re.search(r"\b(total|vat|tax|balance|amount due|subtotal|date|invoice|receipt)\b", ln, re.I):
            continue
        if re.search(r"\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{2,4}", ln):
            continue                       # a date line is not an item
        if supplier and _norm_eq(ln, supplier):
            continue
        m = re.match(r"^(.*?[A-Za-z][A-Za-z ]*?)\s+[£$€]?-?\d", ln)
        if m and len(m.group(1).strip()) >= 3:
            return m.group(1).strip()[:80]
    return None


def _norm_eq(a: str, b: str) -> bool:
    return re.sub(r"[^a-z0-9]", "", a.lower()) == re.sub(r"[^a-z0-9]", "", b.lower())
