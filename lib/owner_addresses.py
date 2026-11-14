#!/usr/bin/env python3
"""Derive the owner's own email addresses from Accounts4 and store them.

WHY. The email, reply-debt and mail-contact consumers need to know which
addresses are the owner's, so they can tell "the owner wrote this" from
"someone wrote to the owner". Nothing in the shipped install set
OSTLER_USER_EMAIL on any recurring path, so every box ran with no owner
address: owner_wrote was false on every thread.

WHAT. Every mail-type account's username, plus every address held in the
account's EmailAliases and IdentityEmailAddress properties (all accounts,
including aliases; not just the first). Written to the owner state file
mode 0600. Addresses are never logged: the CLI prints counts only.

    python3 lib/owner_addresses.py --db ~/Library/Accounts/Accounts4.sqlite \
        --out ~/.ostler/state/owner_addresses.json

Output schema (schema 1):
    {"schema": 1, "status": "ok" | "none" | "unreadable",
     "addresses": [...], "derived_at": "<UTC ISO>"}

status "none": the store was read and holds no owner mail address (a
webmail-only owner, or no account). The Doctor row for that case is a
separate change. status "unreadable": the store could not be read.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from typing import Iterable, Optional

SCHEMA = 1

# Mail-type account identifiers. Same list as _accountsdb_owner_mail_domains
# in install.sh (#3528), so the domain and address reads agree.
MAIL_ACCOUNT_TYPES = (
    "com.apple.account.IMAP",
    "com.apple.account.IMAPMail",
    "com.apple.account.Hotmail",
    "com.apple.account.Google",
    "com.apple.account.Yahoo",
    "com.apple.account.Exchange",
    "com.apple.account.AppleAccount",
    "com.apple.account.MobileMe",
    "com.apple.account.iCloud",
)
# Account properties that can carry the owner's further addresses.
ADDRESS_PROPERTIES = ("EmailAliases", "IdentityEmailAddress")

_ADDR = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
_FIND = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def _strings(value) -> Iterable[str]:
    """Every string inside a decoded plist value, however nested."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from _strings(k)
            yield from _strings(v)
    elif isinstance(value, (list, tuple, set)):
        for v in value:
            yield from _strings(v)


def _addresses_in(text: str) -> Iterable[str]:
    for hit in _FIND.findall(text or ""):
        a = hit.strip().lower()
        if _ADDR.match(a):
            yield a


def _decode(blob) -> Optional[object]:
    if blob is None:
        return None
    if isinstance(blob, str):
        return blob
    try:
        return plistlib.loads(bytes(blob))
    except Exception:
        try:
            return bytes(blob).decode("utf-8", "replace")
        except Exception:
            return None


def derive(db_path: str) -> dict:
    """Read the Accounts store and return the owner's addresses.

    Read-only. Returns status "unreadable" (never an empty list) when the
    store cannot be opened, so "could not read" and "found none" stay apart.
    """
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.Error:
        return {"status": "unreadable", "addresses": []}
    try:
        placeholders = ",".join("?" for _ in MAIL_ACCOUNT_TYPES)
        account_rows = conn.execute(
            f"""SELECT a.Z_PK, a.ZUSERNAME FROM ZACCOUNT a
                JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
                WHERE t.ZIDENTIFIER IN ({placeholders})
                  AND (a.ZAUTHENTICATIONTYPE IS NULL OR a.ZAUTHENTICATIONTYPE != 'parent')
                  AND COALESCE(a.ZACTIVE, 1) = 1""",
            MAIL_ACCOUNT_TYPES,
        ).fetchall()
        found: set[str] = set()
        for pk, username in account_rows:
            found.update(_addresses_in(username or ""))
        pk_list = [pk for pk, _ in account_rows]
        if pk_list:
            prop_marks = ",".join("?" for _ in ADDRESS_PROPERTIES)
            acct_marks = ",".join("?" for _ in pk_list)
            for blob, key in conn.execute(
                f"""SELECT ZVALUE, ZKEY FROM ZACCOUNTPROPERTY
                    WHERE ZKEY IN ({prop_marks}) AND ZOWNER IN ({acct_marks})""",
                (*ADDRESS_PROPERTIES, *pk_list),
            ):
                decoded = _decode(blob)
                for s in _strings(decoded) if not isinstance(decoded, str) else [decoded]:
                    found.update(_addresses_in(s))
    except sqlite3.Error:
        return {"status": "unreadable", "addresses": []}
    finally:
        conn.close()
    addresses = sorted(found)
    return {"status": "ok" if addresses else "none", "addresses": addresses}


def write_state(path: str, result: dict) -> None:
    """Atomic write, mode 0600 from creation. Never logs the addresses."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    payload = {
        "schema": SCHEMA,
        "status": result["status"],
        "addresses": list(result["addresses"]),
        "derived_at": datetime.now(timezone.utc).isoformat(),
    }
    fd, tmp = tempfile.mkstemp(prefix=".owner_addresses.", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, sort_keys=True)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    result = derive(args.db)
    write_state(args.out, result)
    # Counts only: the addresses never reach stdout or the install log.
    print(f"owner addresses: status={result['status']} count={len(result['addresses'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
