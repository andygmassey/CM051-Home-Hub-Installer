"""Unit tests for the AddressBook-v22.abcddb reader's email extraction.

Regression cover for the silent email-drop bug: Contacts cards reached the
graph phone-only (card->phone ~97%, card->email ~1%) because the hard-coded
``SELECT ... ZADDRESS ... FROM ZABCDEMAILADDRESS`` returned no usable rows on
macOS stores that carry the address in ZADDRESSNORMALIZED, and the failure was
swallowed with a bare ``except: pass``.

These tests drive ``ContactSyncer._read_abcddb_as_vcards`` /
``ContactSyncer._read_child_values`` against synthetic abcddb fixtures and
assert that:
  * a card with emails yields ``EMAIL`` lines in the synthesised vCard,
  * multiple emails per card all survive (de-duped, case-insensitive),
  * a phone-only card still yields its ``TEL`` line,
  * the alternate ZADDRESSNORMALIZED column shape is read (the live bug),
  * a malformed / empty value is skipped rather than emitted.

No vobject parse is exercised: we assert on the raw vCard text the reader
synthesises, which is the layer the bug lives in.
"""
from __future__ import annotations

import sqlite3
import sys
import tempfile
import types
from pathlib import Path

import pytest

# contact_syncer.syncer imports several siblings at module load (vobject for
# the vCard *parse* path, plus photo_storage / dedup / identity_resolver).
# None are exercised by the abcddb *reader* under test (it is pure sqlite3),
# so stub any that are not importable in the current environment. This keeps
# the test runnable against both the full vendored copy and the partial
# root-of-repo slice.
def _ensure_stub(name: str, attrs: dict | None = None) -> None:
    try:  # prefer the real module when present
        __import__(name)
        return
    except Exception:
        pass
    mod = types.ModuleType(name)
    for k, v in (attrs or {}).items():
        setattr(mod, k, v)
    sys.modules[name] = mod


_ensure_stub("vobject")
_ensure_stub("contact_syncer.photo_storage", {
    "remove_photo": lambda *a, **k: None,
    "write_photo": lambda *a, **k: None,
})

# contact_syncer.dedup imports identity_resolver.normalise at module level.
# In the complete (vendored) copy that package sits alongside on the path; in
# the partial root-of-repo slice it does not. Skip the whole module cleanly
# in that case rather than erroring out collection -- the same assertions run
# against the complete copy under vendor/cm041/.
try:
    from contact_syncer.syncer import ContactSyncer  # noqa: E402
except Exception as _exc:  # pragma: no cover - partial slice without CM041 deps
    pytest.skip(
        f"contact_syncer.syncer not importable in this slice ({_exc}); "
        "abcddb reader test runs against the complete vendored copy",
        allow_module_level=True,
    )


def _make_db(tmp: Path, *, email_col: str = "ZADDRESS") -> Path:
    """Build an AddressBook-v22.abcddb fixture under a fake home tree.

    Returns the fake HOME path (so the caller can monkeypatch Path.home).
    The contacts live under Sources/<uuid>/ as on a real iCloud customer.
    """
    src = tmp / "Library" / "Application Support" / "AddressBook" / "Sources" / "UUID-1"
    src.mkdir(parents=True)
    db = src / "AddressBook-v22.abcddb"
    con = sqlite3.connect(db)
    con.executescript(
        f"""
        CREATE TABLE ZABCDRECORD (
            Z_PK INTEGER PRIMARY KEY, ZUNIQUEID TEXT,
            ZFIRSTNAME TEXT, ZMIDDLENAME TEXT, ZLASTNAME TEXT,
            ZORGANIZATION TEXT, ZJOBTITLE TEXT, ZNOTE TEXT
        );
        CREATE TABLE ZABCDEMAILADDRESS (
            Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, {email_col} TEXT
        );
        CREATE TABLE ZABCDPHONENUMBER (
            Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT
        );
        """
    )
    con.commit()
    con.close()
    return db


def _read(tmp: Path, monkeypatch: pytest.MonkeyPatch) -> list[str]:
    monkeypatch.setattr(Path, "home", staticmethod(lambda: tmp))
    inst = ContactSyncer.__new__(ContactSyncer)
    return inst._read_abcddb_as_vcards()


def test_card_with_email_yields_email_line(tmp_path, monkeypatch):
    db = _make_db(tmp_path)
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZFIRSTNAME, ZLASTNAME) "
        "VALUES (1, 'uid-1', 'Alice', 'Smith')"
    )
    con.execute(
        "INSERT INTO ZABCDEMAILADDRESS (Z_PK, ZOWNER, ZADDRESS) "
        "VALUES (1, 1, 'alice@example.com')"
    )
    con.commit()
    con.close()

    cards = _read(tmp_path, monkeypatch)
    assert len(cards) == 1
    assert "EMAIL;TYPE=INTERNET:alice@example.com" in cards[0]


def test_multiple_emails_all_survive_deduped(tmp_path, monkeypatch):
    db = _make_db(tmp_path)
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZFIRSTNAME, ZLASTNAME) "
        "VALUES (1, 'uid-1', 'Bob', 'Jones')"
    )
    con.executemany(
        "INSERT INTO ZABCDEMAILADDRESS (ZOWNER, ZADDRESS) VALUES (?, ?)",
        [
            (1, "bob@example.com"),
            (1, "bob.work@example.com"),
            (1, "BOB@EXAMPLE.COM"),  # case-insensitive duplicate of the first
        ],
    )
    con.commit()
    con.close()

    cards = _read(tmp_path, monkeypatch)
    card = cards[0]
    assert "EMAIL;TYPE=INTERNET:bob@example.com" in card
    assert "EMAIL;TYPE=INTERNET:bob.work@example.com" in card
    # The case-variant duplicate must not produce a second identical-value line.
    assert card.count("bob@example.com") == 1 or card.upper().count("BOB@EXAMPLE.COM") == 1
    assert card.count("EMAIL;TYPE=INTERNET:") == 2


def test_phone_only_card_still_yields_phone(tmp_path, monkeypatch):
    db = _make_db(tmp_path)
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZFIRSTNAME, ZLASTNAME) "
        "VALUES (1, 'uid-1', 'Carol', 'Doe')"
    )
    con.execute(
        "INSERT INTO ZABCDPHONENUMBER (ZOWNER, ZFULLNUMBER) "
        "VALUES (1, '+447700900123')"
    )
    con.commit()
    con.close()

    cards = _read(tmp_path, monkeypatch)
    card = cards[0]
    assert "TEL:+447700900123" in card
    assert "EMAIL" not in card


def test_email_in_addressnormalized_column_is_read(tmp_path, monkeypatch):
    """The live bug: the store carries the email only in ZADDRESSNORMALIZED.

    The previous hard-coded ZADDRESS query returned nothing and the failure
    was swallowed, so the card shipped phone-only. The fix falls back to the
    alternate value column.
    """
    db = _make_db(tmp_path, email_col="ZADDRESSNORMALIZED")
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZFIRSTNAME, ZLASTNAME) "
        "VALUES (1, 'uid-1', 'Dave', 'Roe')"
    )
    con.execute(
        "INSERT INTO ZABCDEMAILADDRESS (ZOWNER, ZADDRESSNORMALIZED) "
        "VALUES (1, 'dave@example.com')"
    )
    con.commit()
    con.close()

    cards = _read(tmp_path, monkeypatch)
    assert "EMAIL;TYPE=INTERNET:dave@example.com" in cards[0]


def test_empty_and_null_email_values_skipped(tmp_path, monkeypatch):
    db = _make_db(tmp_path)
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZFIRSTNAME, ZLASTNAME) "
        "VALUES (1, 'uid-1', 'Erin', 'Poe')"
    )
    con.executemany(
        "INSERT INTO ZABCDEMAILADDRESS (ZOWNER, ZADDRESS) VALUES (?, ?)",
        [(1, ""), (1, "   "), (1, None), (1, "erin@example.com")],
    )
    con.commit()
    con.close()

    cards = _read(tmp_path, monkeypatch)
    card = cards[0]
    assert card.count("EMAIL;TYPE=INTERNET:") == 1
    assert "EMAIL;TYPE=INTERNET:erin@example.com" in card
