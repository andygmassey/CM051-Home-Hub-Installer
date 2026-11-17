"""SQLite store: books, receipts, missing-receipt candidates, supplier memory.

One file, default ~/.ostler/receipts/receipts.db (mode 0600), overridable with
OSTLER_RECEIPTS_HOME (tests always set it to a scratch directory). Each row keeps
its JSON body, so the record shape lives in one place (model.py).
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from .model import new_record


def home_dir() -> Path:
    env = os.environ.get("OSTLER_RECEIPTS_HOME")
    return Path(env) if env else Path.home() / ".ostler" / "receipts"


def files_root() -> Path:
    """Where the originals are filed. OSTLER_RECEIPTS_FILES overrides (tests always set it)."""
    env = os.environ.get("OSTLER_RECEIPTS_FILES")
    return Path(env) if env else Path.home() / "Ostler" / "Receipts"


def supplier_key(name: Optional[str]) -> str:
    return re.sub(r"[^a-z0-9]", "", (name or "").lower())


class Store:
    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path) if path else home_dir() / "receipts.db"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        new = not self.path.exists()
        self.db = sqlite3.connect(str(self.path))
        self.db.row_factory = sqlite3.Row
        if new:
            os.chmod(self.path, 0o600)
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS books (id TEXT PRIMARY KEY, kind TEXT NOT NULL, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, book_id TEXT, sha256 TEXT UNIQUE, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS missing (id TEXT PRIMARY KEY, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS supplier_memory (key TEXT PRIMARY KEY, book_id TEXT NOT NULL);
            """
        )

    # ---- kv / settings
    def get_kv(self, k: str, default: Any = None) -> Any:
        row = self.db.execute("SELECT v FROM kv WHERE k=?", (k,)).fetchone()
        return json.loads(row["v"]) if row else default

    def set_kv(self, k: str, v: Any) -> None:
        self.db.execute("INSERT OR REPLACE INTO kv(k,v) VALUES(?,?)", (k, json.dumps(v)))
        self.db.commit()

    @property
    def corrections_on(self) -> bool:
        """Owner's correction capture for a future eval set. OFF by default and never enabled by code."""
        return bool(self.get_kv("corrections_capture", False))

    def add_correction(self, row: Dict[str, Any]) -> None:
        log = self.get_kv("corrections_log", [])
        log.append(row)
        self.set_kv("corrections_log", log)

    @property
    def personal_enabled(self) -> bool:
        return bool(self.get_kv("personal_enabled", False))

    # ---- books
    def put_book(self, book: Dict[str, Any]) -> None:
        self.db.execute("INSERT OR REPLACE INTO books(id,kind,body) VALUES(?,?,?)",
                        (book["id"], book["kind"], json.dumps(book)))
        self.db.commit()

    def get_book(self, book_id: str) -> Optional[Dict[str, Any]]:
        row = self.db.execute("SELECT body FROM books WHERE id=?", (book_id,)).fetchone()
        return json.loads(row["body"]) if row else None

    def books(self, kind: Optional[str] = None) -> List[Dict[str, Any]]:
        q, a = "SELECT body FROM books", ()
        if kind:
            q, a = q + " WHERE kind=?", (kind,)
        return [json.loads(r["body"]) for r in self.db.execute(q + " ORDER BY id", a)]

    # ---- receipts
    def put_receipt(self, rec: Dict[str, Any]) -> None:
        self.db.execute(
            "INSERT OR REPLACE INTO receipts(id,book_id,sha256,body) VALUES(?,?,?,?)",
            (rec["id"], rec.get("book_id"), rec.get("file_sha256"), json.dumps(rec)))
        self.db.commit()

    def get_receipt(self, rid: str) -> Optional[Dict[str, Any]]:
        row = self.db.execute("SELECT body FROM receipts WHERE id=?", (rid,)).fetchone()
        return json.loads(row["body"]) if row else None

    def receipts(self) -> List[Dict[str, Any]]:
        return [json.loads(r["body"]) for r in self.db.execute("SELECT body FROM receipts ORDER BY id")]

    def has_sha(self, sha: str) -> bool:
        return self.db.execute("SELECT 1 FROM receipts WHERE sha256=?", (sha,)).fetchone() is not None

    # ---- missing-receipt candidates (asked once: the row is never removed)
    def put_missing(self, cand: Dict[str, Any]) -> bool:
        if self.db.execute("SELECT 1 FROM missing WHERE id=?", (cand["id"],)).fetchone():
            return False
        self.db.execute("INSERT INTO missing(id,body) VALUES(?,?)", (cand["id"], json.dumps(cand)))
        self.db.commit()
        return True

    def missing(self) -> List[Dict[str, Any]]:
        return [json.loads(r["body"]) for r in self.db.execute("SELECT body FROM missing ORDER BY id")]

    def get_missing(self, mid: str) -> Optional[Dict[str, Any]]:
        row = self.db.execute("SELECT body FROM missing WHERE id=?", (mid,)).fetchone()
        return json.loads(row["body"]) if row else None

    def update_missing(self, cand: Dict[str, Any]) -> None:
        self.db.execute("UPDATE missing SET body=? WHERE id=?", (json.dumps(cand), cand["id"]))
        self.db.commit()

    # ---- supplier memory
    def remember_supplier(self, name: str, book_id: str) -> None:
        self.db.execute("INSERT OR REPLACE INTO supplier_memory(key,book_id) VALUES(?,?)",
                        (supplier_key(name), book_id))
        self.db.commit()

    def set_supplier_rule(self, name: str, book_id: str) -> None:
        """The owner's rule: receipts from this supplier belong to this book. Keyed on the normalised name."""
        from .names import normalise_supplier
        rules = self.get_kv("supplier_rules", {})
        rules[normalise_supplier(name)] = book_id
        self.set_kv("supplier_rules", rules)

    def learn_supplier_fp(self, rec: Dict[str, Any]) -> None:
        """Learn once, on the owner's confirmation: the supplier's fingerprints map to its book and currency."""
        from .memory import learn
        m = dict(self.get_kv("supplier_fingerprints", {}))
        learn(m, {"supplier": rec.get("supplier"), "sender_domain": rec.get("sender_domain"),
                  "vat_number": rec.get("vat_number"), "book": rec.get("book_id"),
                  "category": rec.get("category"), "currency": rec.get("currency")})
        self.set_kv("supplier_fingerprints", m)

    def recall_supplier_fp(self, rec: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        from .memory import recall
        return recall(dict(self.get_kv("supplier_fingerprints", {})), rec)

    def supplier_rules(self) -> Dict[str, str]:
        return dict(self.get_kv("supplier_rules", {}))

    def supplier_book(self, name: Optional[str]) -> Optional[str]:
        row = self.db.execute("SELECT book_id FROM supplier_memory WHERE key=?", (supplier_key(name),)).fetchone()
        return row["book_id"] if row else None

    def close(self) -> None:
        self.db.close()


def new_id(prefix: str, seed: str) -> str:
    import hashlib
    return prefix + hashlib.sha256(seed.encode()).hexdigest()[:16]


__all__ = ["Store", "home_dir", "supplier_key", "new_id", "new_record", "Iterable"]
