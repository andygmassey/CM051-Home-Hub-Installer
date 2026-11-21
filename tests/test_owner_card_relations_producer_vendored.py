"""G1 producer, in the copy that ships (vendor/cm041).

``_read_abcddb_as_vcards`` synthesises the vCards the owner-relations writer
reads. For the OWNER's card it must emit the marker ``X-OSTLER-OWNER-CARD:TRUE``
and the related-name lines (``itemN.X-ABRELATEDNAMES`` with
``itemN.X-ABLABEL``). Other cards get neither.

The owner's card is the record whose Z_PK equals the store's ZME pointer. ZME
is non-NULL on one pointer row, and the owner's own row has ZME NULL (measured
on the box, 2026-11-15).

All identifiers here are synthetic (Rule 0): reserved names, no real people.
"""
from __future__ import annotations

import pathlib
import re
import sqlite3
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM041 = ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from contact_syncer.syncer import ContactSyncer  # noqa: E402

OWNER = "Alex Doe"
SPOUSE = "Jane Smith"
MANAGER = "Bob Jones, Jr"  # comma must be vCard-escaped
OTHER = "Ben Jones"
OTHER_SPOUSE = "Carl Brown"


def _store(tmp: pathlib.Path) -> pathlib.Path:
    src = tmp / "Library" / "Application Support" / "AddressBook" / "Sources" / "UUID-1"
    src.mkdir(parents=True)
    db = src / "AddressBook-v22.abcddb"
    con = sqlite3.connect(db)
    con.executescript(
        """
        CREATE TABLE ZABCDRECORD (
            Z_PK INTEGER PRIMARY KEY, ZUNIQUEID TEXT, ZME INTEGER,
            ZFIRSTNAME TEXT, ZMIDDLENAME TEXT, ZLASTNAME TEXT,
            ZORGANIZATION TEXT, ZJOBTITLE TEXT, ZNOTE TEXT
        );
        CREATE TABLE ZABCDRELATEDNAME (
            Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZNAME TEXT, ZLABEL TEXT
        );
        CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
        CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
        """
    )
    # The owner's card is pk 7 with ZME NULL. The pointer (ZME = 7) sits on
    # row 99, which is another person's card.
    con.execute("INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZME, ZFIRSTNAME, ZLASTNAME) "
                "VALUES (7, 'uid-owner', NULL, 'Alex', 'Doe')")
    con.execute("INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZME, ZFIRSTNAME, ZLASTNAME) "
                "VALUES (99, 'uid-other', 7, 'Ben', 'Jones')")
    con.execute("INSERT INTO ZABCDRELATEDNAME (ZOWNER, ZNAME, ZLABEL) VALUES (7, ?, '_$!<Spouse>!$_')", (SPOUSE,))
    con.execute("INSERT INTO ZABCDRELATEDNAME (ZOWNER, ZNAME, ZLABEL) VALUES (7, ?, '_$!<Manager>!$_')", (MANAGER,))
    # Relations on a non-owner card are perspectival and must not be emitted.
    con.execute("INSERT INTO ZABCDRELATEDNAME (ZOWNER, ZNAME, ZLABEL) VALUES (99, ?, '_$!<Spouse>!$_')", (OTHER_SPOUSE,))
    con.commit()
    con.close()
    return db


def _cards(tmp: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> dict:
    monkeypatch.setattr(pathlib.Path, "home", staticmethod(lambda: tmp))
    out = ContactSyncer.__new__(ContactSyncer)._read_abcddb_as_vcards()
    by_uid = {}
    for card in out:
        m = re.search(r"^UID:(.+)$", card, re.MULTILINE)
        by_uid[m.group(1).strip()] = card
    return by_uid


def test_owner_card_is_marked_and_carries_its_relations(tmp_path, monkeypatch):
    _store(tmp_path)
    owner = _cards(tmp_path, monkeypatch)["uid-owner"]
    assert "X-OSTLER-OWNER-CARD:TRUE" in owner
    assert f"item1.X-ABRELATEDNAMES;TYPE=pref:{SPOUSE}" in owner
    assert "item1.X-ABLABEL:_$!<Spouse>!$_" in owner
    assert "item2.X-ABRELATEDNAMES;TYPE=pref:Bob Jones\\, Jr" in owner
    assert "item2.X-ABLABEL:_$!<Manager>!$_" in owner


def test_non_owner_card_has_no_marker_and_no_relation_lines(tmp_path, monkeypatch):
    _store(tmp_path)
    other = _cards(tmp_path, monkeypatch)["uid-other"]
    assert "X-OSTLER-OWNER-CARD" not in other
    assert "X-ABRELATEDNAMES" not in other
    assert OTHER_SPOUSE not in other


def test_owner_card_without_relations_is_marked_and_has_no_relation_lines(tmp_path, monkeypatch):
    db = _store(tmp_path)
    con = sqlite3.connect(db)
    con.execute("DELETE FROM ZABCDRELATEDNAME WHERE ZOWNER = 7")
    con.commit()
    con.close()
    owner = _cards(tmp_path, monkeypatch)["uid-owner"]
    assert "X-OSTLER-OWNER-CARD:TRUE" in owner
    assert "X-ABRELATEDNAMES" not in owner
