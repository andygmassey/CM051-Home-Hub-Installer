"""Operations behind the API contract (~/walkdriver/RECEIPTS_API_CONTRACT.md).

Each op takes (store, request dict) and returns a response dict with
`schema` and `state`. Nothing here talks to the network. Edits are
owner-sourced and recorded in `edited_by_owner`.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import books as bk
from . import presets
from .model import SCHEMA, THRESHOLD
from .pipeline import MISSING_AFTER_DAYS, business_books, file_into_book, is_filed, line_id, personal_book, refile
from .store import Store, files_root
from .store import files_root as _files_root

PRIVACY_LEVEL = "L3"   # the #504 gate refuses anything else; money is L3 everywhere

NAME_FIELDS = {"book_id", "category", "date", "supplier", "amount_gross", "currency"}
EDITABLE = {"book_id", "category", "business_use_pct", "notes", "description", "supplier", "date", "amount_gross", "currency"}


def _ok(**kw: Any) -> Dict[str, Any]:
    return {"schema": SCHEMA, "state": "ok", **kw}


def _state(state: str, **kw: Any) -> Dict[str, Any]:
    return {"schema": SCHEMA, "state": state, **kw}


def _summary(r: Dict[str, Any]) -> Dict[str, Any]:
    keys = ("id", "book_id", "date", "supplier", "category", "amount_gross", "currency", "amount_home",
            "business_use_pct", "status", "reasons", "source")
    return {k: r.get(k) for k in keys}


def books_list(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    out = []
    for b in store.books():
        rows = [r for r in store.receipts() if r.get("book_id") == b["id"]]
        out.append({**b, "counts": {"ok": sum(r["status"] == "ok" for r in rows),
                                    "check": sum(r["status"] == "check" for r in rows), "total": len(rows)}})
    unsure = [r for r in store.receipts() if r.get("book_id") is None]
    return _ok(books=out, personal_enabled=store.personal_enabled, check_unfiled=len(unsure))


def books_settings_get(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    b = store.get_book(req.get("book_id", ""))
    if not b:
        return _state("not_found")
    return _ok(book=b, categories=bk.categories(b))


def books_settings_set(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    b = store.get_book(req.get("book_id", ""))
    if not b:
        return _state("not_found")
    if "preset" in req and req["preset"] not in presets.PRESETS and b["kind"] == "business":
        return _state("invalid", reason="unknown preset")
    for k in ("name", "home_currency", "tax_year_start", "tax_registered", "preset", "enabled"):
        if k in req:
            b[k] = req[k].upper() if k == "home_currency" else req[k]
    store.put_book(b)
    return _ok(book=b)


def supplier_rule_set(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    """The owner ties a supplier to one book. Future receipts from it file there (reason owner_rule)."""
    b = store.get_book(req.get("book_id", ""))
    if not b:
        return _state("not_found")
    if not req.get("supplier"):
        return _state("invalid", reason="supplier required")
    store.set_supplier_rule(req["supplier"], b["id"])
    return _ok(rules=store.supplier_rules())


def supplier_rule_list(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    return _ok(rules=store.supplier_rules())


def books_create(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    if req.get("kind") == "personal":
        if not store.personal_enabled:
            return _state("invalid", reason="personal book is off; enable it first (books.personal.set)")
        if personal_book(store):
            return _state("invalid", reason="personal book already exists")
    try:
        b = bk.make_book(store, kind=req.get("kind", "business"), name=req.get("name", "Business"),
                         preset=req.get("preset", "general"), home_currency=req.get("home_currency", "GBP"),
                         tax_year_start=req.get("tax_year_start"), tax_registered=req.get("tax_registered", False))
    except ValueError as e:
        return _state("invalid", reason=str(e))
    return _ok(book=b)


def personal_set(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    on = bool(req.get("enabled"))
    store.set_kv("personal_enabled", on)
    return _ok(personal_enabled=on)


def receipts_list(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    rows = store.receipts()
    if req.get("book_id"):
        rows = [r for r in rows if r.get("book_id") == req["book_id"]]
    if req.get("status"):
        rows = [r for r in rows if r.get("status") == req["status"]]
    if req.get("month"):
        rows = [r for r in rows if (r.get("date") or "")[:7] == req["month"]]
    rows.sort(key=lambda r: (r.get("date") or "", r["id"]), reverse=True)
    limit = int(req.get("limit") or 200)
    return _ok(receipts=[_summary(r) for r in rows[:limit]], next_cursor=None)


def receipts_get(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    r = store.get_receipt(req.get("id", ""))
    if not r:
        return _state("not_found")
    out = {k: v for k, v in r.items() if k not in ("file_path",)}
    return _ok(receipt=out)


def receipts_edit(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    r = store.get_receipt(req.get("id", ""))
    if not r:
        return _state("not_found")
    changed = [k for k in EDITABLE if k in req]
    if not changed:
        return _state("invalid", reason="no editable field given")
    target_id = req["book_id"] if "book_id" in req else r.get("book_id")
    if "category" in req:
        book = store.get_book(target_id or "") if target_id else None
        if not book:
            return _state("invalid", reason="set a book before a category")
        valid = {c["id"] for c in bk.categories(book)} | {c["label"].lower() for c in bk.categories(book)}
        if str(req["category"]).lower() not in {v.lower() for v in valid}:
            return _state("invalid", reason="category is not in the target book's preset")
        req = dict(req, category=category_id(book, req["category"]))
    if "business_use_pct" in req and not (0 <= float(req["business_use_pct"]) <= 100):
        return _state("invalid", reason="business_use_pct must be 0 to 100")
    if "book_id" in req:
        target = store.get_book(req["book_id"]) if req["book_id"] else None
        if req["book_id"] and not target:
            return _state("invalid", reason="unknown book")
        if target and target["kind"] == "personal" and not store.personal_enabled:
            return _state("invalid", reason="personal book is off")
    if store.corrections_on:
        for k in changed:
            if k in ("date", "supplier", "amount_gross", "currency", "tax_amount") and r.get(k) != req[k]:
                store.add_correction({"receipt_id": r["id"], "field": k, "extracted": r.get(k), "owner": req[k],
                                      "source": r.get("source"), "lens_book_guess": r.get("book_guess")})
    for k in changed:
        r[k] = req[k]
        if k not in r.get("edited_by_owner", []):
            r.setdefault("edited_by_owner", []).append(k)
    if "book_id" in changed and r.get("book_id"):
        # Learning: a supplier moved between books is a suggestion for the future, never a silent re-file.
        store.remember_supplier(r.get("supplier") or "", r["book_id"])
    if "book_id" in changed:
        r["book_decision"] = "owner"
    if r.get("file_path") and set(changed) & NAME_FIELDS:
        book = store.get_book(r.get("book_id") or "")
        if book:
            try:
                refile(r, book, _files_root())
            except OSError as e:
                r["reasons"] = sorted(set(r.get("reasons", []) + [f"cannot_run:{type(e).__name__}"]))
    r["confidence"] = {**r.get("confidence", {}), **{k: 1.0 for k in changed if k in ("date", "supplier", "amount_gross", "currency")}}
    from .model import decide_status
    decide_status(r, extra_reasons=[x for x in r.get("reasons", []) if x.startswith(("lens_", "no_fx", "statement_", "book_suggested"))])
    store.put_receipt(r)
    return _ok(receipt=r)


CONFIRMABLE = ("date", "supplier", "amount_gross", "currency", "tax_amount", "book", "category")


def receipts_confirm(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    """The owner's one tap (v1 prefill-only). Confirms the named fields; when the receipt is not yet filed it
    files it into the business book (req book_id, else the only business book) and copies the original into
    the book tree. Status becomes ok when every required field is confirmed and the book is decided."""
    from .pipeline import REQUIRED_CONFIRM, file_into_book
    from .store import files_root as _files_root
    r = store.get_receipt(req.get("id", ""))
    if not r:
        return _state("not_found")
    fields = req.get("fields") or list(CONFIRMABLE)
    bad = [f for f in fields if f not in CONFIRMABLE]
    if bad:
        return _state("invalid", reason=f"not confirmable: {bad}")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for f in fields:
        r.setdefault("confirmed_by_owner", {})[f] = now
        r.setdefault("confidence", {})[f] = 1.0
    if r.get("book_id") is None:
        biz = business_books(store)
        book = store.get_book(req["book_id"]) if req.get("book_id") else (biz[0] if len(biz) == 1 else None)
        if book is None:
            return _state("invalid", reason="choose a book to confirm into")
        r["book_id"], r["book_decision"] = book["id"], "owner"
        r["reasons"] = [x for x in r.get("reasons", []) if x not in ("book_unsure", "book_suggested", "lens_prefill_only", "book_low_conf")]
    book = store.get_book(r["book_id"])
    if not is_filed(r, _files_root()) and r.get("source_path") and r.get("file_sha256"):
        try:
            file_into_book(store, r, book, Path(r["source_path"]), Path(r["source_path"]).suffix,
                           _files_root(), r["file_sha256"])
        except (OSError, FileNotFoundError) as e:
            r["reasons"] = sorted(set(r.get("reasons", []) + [f"cannot_run:{type(e).__name__}"]))
    if all(f in r.get("confirmed_by_owner", {}) for f in REQUIRED_CONFIRM) and r.get("book_id") and not r.get("reasons"):
        r["status"] = "ok"
        store.learn_supplier_fp(r)   # learn once, on the owner's confirmation
    store.put_receipt(r)
    return _ok(receipt=r)


def check_list(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    rows = [r for r in store.receipts() if r.get("status") == "check"]
    if req.get("book_id"):
        rows = [r for r in rows if r.get("book_id") == req["book_id"]]
    return _ok(receipts=[{**_summary(r), "reasons": r.get("reasons", [])} for r in rows])


def missing_list(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    rows = [m for m in store.missing() if not m.get("dismissed")]
    if req.get("book_id"):
        rows = [m for m in rows if m.get("book_id") == req["book_id"]]
    return _ok(candidates=rows)


def missing_dismiss(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    m = store.get_missing(req.get("id", ""))
    if not m:
        return _state("not_found")
    m["dismissed"] = bool(req.get("dismissed", True))
    store.update_missing(m)
    return _ok(ok=True)


def scan_missing(store: Store, statements: List[Any], today: Optional[date] = None) -> int:
    """Business-looking card debits with no receipt after 14 days become ONE candidate each (asked once)."""
    today = today or date.today()
    biz = business_books(store)
    if len(biz) != 1:
        return 0
    claimed = {r.get("statement_line_id") for r in store.receipts() if r.get("statement_line_id")}
    added = 0
    for t in statements:
        if t.amount >= 0 or (today - t.date).days < MISSING_AFTER_DAYS:
            continue
        lid = line_id(t)
        if lid in claimed or "transfer" in (t.kind_hint or "").lower() or "transfer" in t.merchant_key:
            continue
        mem = store.supplier_book(t.merchant)
        pb = personal_book(store)
        if pb is not None and mem == pb["id"]:
            continue       # the owner has put this merchant in personal
        if pb is not None and mem != biz[0]["id"]:
            continue       # personal is on: only merchants the owner has put in business are asked about
        cand = {"id": lid, "statement_line_id": lid, "merchant": t.merchant, "date": t.date.isoformat(),
                "amount": abs(t.amount), "currency": t.currency, "book_id": biz[0]["id"],
                "asked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "dismissed": False}
        added += 1 if store.put_missing(cand) else 0
    return added


def judgement_rows(candidates: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Missing-receipt candidates as rows for the judgement loop. [VERIFY] field names against the loop's row schema."""
    return [{"subject": f"Missing receipt: {c['merchant']} {c['amount']:.2f} {c['currency']} on {c['date']}",
             "preference_type": "missing_receipt", "source": "receipts", "strength": 0.3,
             "compartment_level": "L3", "email_id": c["id"], "extra": {"asked_at": c["asked_at"]}}
            for c in candidates]


def _description(r: Dict[str, Any], book: Dict[str, Any]) -> str:
    """Never blank: the lens or OCR description, else supplier plus category label, else a plain fallback."""
    if r.get("description"):
        return r["description"]
    cid = category_id(book, r.get("category"))
    parts = [r.get("supplier") or "Receipt", category_label(book, cid)]
    return " ".join(parts)


def category_id(book: Dict[str, Any], value: Optional[str]) -> str:
    """Internal id for a category given either its id or its owner-facing label. Unknown means `other`."""
    ids = {c["id"]: c["id"] for c in bk.categories(book)}
    labels = {c["label"].lower(): c["id"] for c in bk.categories(book)}
    if not value:
        return presets.UNCATEGORISED
    if value in ids:
        return value
    return labels.get(str(value).lower(), presets.UNCATEGORISED)


def _cat_entry(book: Dict[str, Any], cid: str) -> Dict[str, Any]:
    """id, label, allowable and professional for one category; the uncategorised bucket carries the same fields."""
    c = next((c for c in bk.categories(book) if c["id"] == cid), presets.UNCATEGORISED_ENTRY)
    return {"id": cid, "label": c["label"], "allowable": c["allowable"], "professional": bool(c["professional"])}


def category_label(book: Dict[str, Any], cid: str) -> str:
    return next((c["label"] for c in bk.categories(book) if c["id"] == cid), cid)


def _belongs(store: Store, book: Dict[str, Any], r: Dict[str, Any]) -> bool:
    """Filed to this book, or not yet filed while this is the only business book (the owner's Check items)."""
    if r.get("book_id") == book["id"]:
        return True
    biz = business_books(store)
    return r.get("book_id") is None and book["kind"] == "business" and len(biz) == 1 and biz[0]["id"] == book["id"]


def export_payload(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    """Every receipt of the book appears, in Check or filed, with its status. Undated and unfiled items are
    always listed (the owner needs to see them); only filed, dated rows in the window count in totals."""
    book = store.get_book(req.get("book_id", ""))
    if not book:
        return _state("not_found")
    label, start, end = bk.tax_year_window(book, req.get("tax_year"))
    everything = [r for r in store.receipts() if r.get("book_id") == book["id"]]
    # Unfiled Check items belong to no book. They never count in any total and never appear as filed rows;
    # they are listed under their own label so the owner can file them or leave them out.
    # A receipt the owner or the extractor judged personal never shows in a business export, even as Check.
    needs_checking = [r for r in store.receipts()
                      if r.get("book_id") is None and _belongs(store, book, r)
                      and "personal" not in (r.get("book_guess"), r.get("book_decision"))]
    rows = []
    for r in everything:
        dated_in = bool(r.get("date")) and start <= date.fromisoformat(r["date"]) <= end
        if dated_in or not r.get("date"):
            rows.append(r)
    rows.sort(key=lambda r: (r.get("date") or "9999", r["id"]))
    cats = [c["id"] for c in bk.categories(book)]
    if presets.UNCATEGORISED not in cats:  # the personal preset already lists "other"; never a duplicate column
        cats.append(presets.UNCATEGORISED)
    months = []
    cur = date(start.year, start.month, 1)
    while cur <= end:
        months.append(cur.strftime("%Y-%m"))
        cur = date(cur.year + (cur.month // 12), cur.month % 12 + 1, 1)
    cells = {m: {c: 0.0 for c in cats} for m in months}
    expenses, unconverted, business_home_total, check_rows = [], 0, 0.0, 0
    for r in rows:
        filed = r.get("book_id") == book["id"]
        pct = float(r.get("business_use_pct") if r.get("business_use_pct") is not None else 100) / 100.0
        home = r.get("amount_home")
        biz_home = round(home * pct, 2) if home is not None else None
        cid = category_id(book, r.get("category"))
        if filed and r.get("date") and biz_home is not None:
            business_home_total += biz_home
            cells[r["date"][:7]][cid] = round(cells[r["date"][:7]][cid] + biz_home, 2)
        if filed and home is None:
            unconverted += 1
        if r.get("status") != "ok":
            check_rows += 1
        expenses.append({
            "id": r["id"], "book_id": book["id"], "date": r.get("date"), "supplier": r.get("supplier"),
            "description": _description(r, book), "notes": r.get("notes"), "reasons": r.get("reasons", []),
            "category_id": cid, "category_label": category_label(book, cid),
            "business_use_pct": pct * 100, "amount_gross": r.get("amount_gross"),
            "currency": r.get("currency"), "tax_amount": r.get("tax_amount"),
            "tax_reclaimable": r.get("tax_reclaimable"), "amount_home": home,
            "business_share_home": biz_home if filed else None,
            "fx_source": r.get("fx_source"), "status": r.get("status"), "reasons": r.get("reasons", []),
            "filed": filed, "file": r.get("file"),
            "path_in_zip": (r["file_path"] if (filed and r.get("file_path")) else None),
            "file_path": (str(files_root() / r["file_path"]) if (filed and r.get("file_path")) else None),
            "privacy_level": PRIVACY_LEVEL,
        })
    files = [{"name": e["file"], "path_in_zip": e["path_in_zip"], "file_path": e["file_path"]}
             for e in expenses if e["path_in_zip"]]
    checking = [{**_summary(r), "description": _description(r, book), "notes": r.get("notes"),
                 "reasons": r.get("reasons", []), "filed": False}
                for r in sorted(needs_checking, key=lambda r: r["id"])]
    return _ok(privacy_level=PRIVACY_LEVEL, book={k: book[k] for k in ("id", "name", "kind", "home_currency", "preset")},
               needs_checking={"label": "Needs checking", "receipts": checking},
               tax_year=label, window={"start": start.isoformat(), "end": end.isoformat()},
               expenses=expenses,
               summary={"months": months, "categories": [_cat_entry(book, c) for c in cats],
                        "cells": [[cells[m][c] for c in cats] for m in months]},
               categories=bk.categories(book),
               settings={k: book[k] for k in ("home_currency", "tax_year_start", "tax_registered", "preset", "fx_method")},
               files=files,
               totals={"business_share_home": round(business_home_total, 2), "rows": len(expenses),
                       "filed_rows": sum(e["filed"] for e in expenses), "check_rows": check_rows,
                       "unconverted_rows": unconverted})




OPS = {
    "books.list": books_list,
    "books.settings.get": books_settings_get,
    "books.settings.set": books_settings_set,
    "books.create": books_create,
    "books.personal.set": personal_set,
    "books.supplier_rule.set": supplier_rule_set,
    "books.supplier_rule.list": supplier_rule_list,
    "receipts.list": receipts_list,
    "receipts.get": receipts_get,
    "receipts.edit": receipts_edit,
    "receipts.confirm": receipts_confirm,
    "check.list": check_list,
    "missing.list": missing_list,
    "missing.dismiss": missing_dismiss,
    "export.payload": export_payload,
}
