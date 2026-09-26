#!/usr/bin/env python3
"""Photo events carry a city-level place name, so the wiki's "Photos here" fills.

THE BUG: photos_metadata.extract_photo_events wrote ``location=None`` for
every photo (a TODO to parse the reverse-geocode blob), and on macOS 26 did
not even select the blob. pwg_ingest only writes pwg:photoPlace when a label
exists, and CM044 place_pages matches a photo to a place page ONLY by that
label (first token of the area name, as a substring, lower-cased). So every
PhotoEvent landed with no place and "Photos here" stayed empty on every
place page. Measured on a macOS 26.4 library: 1291 events, 1291 with GPS,
0 with a label on main, 970 with a label on the fix.

This builds a synthetic Photos.sqlite in the macOS 26 layout with synthetic
NSKeyedArchiver reverse-geocode blobs, runs the REAL extract_photo_events,
feeds the rows through the REAL ingest_photo_events (SPARQL stubbed), and
asserts:
  1. a photo with a reverse-geocode blob gets "City, Country";
  2. street and postcode never reach the label (city level, not an address);
  3. no city falls back to the state;
  4. an unreadable blob and a missing blob give None, not a crash;
  5. the written pwg:photoPlace matches the way CM044 matches an area.
"""
from __future__ import annotations

import json
import plistlib
import sqlite3
import sys
import tempfile
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor"))

from ostler_fda import photos_metadata as pm  # noqa: E402
from ostler_fda import pwg_ingest as ing  # noqa: E402

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok: " if cond else "FAIL: ") + msg, file=sys.stdout if cond else sys.stderr)
    if not cond:
        FAILURES.append(msg)


def revgeo_blob(**address: str) -> bytes:
    """A PLRevGeoLocationInfo archive in the shape Photos writes (keys only
    measured from a real library; every value here is invented)."""
    objects: list = ["$null"]

    def add(obj) -> plistlib.UID:
        objects.append(obj)
        return plistlib.UID(len(objects) - 1)

    addr_cls = add({"$classname": "CNPostalAddress", "$classes": ["CNPostalAddress", "NSObject"]})
    info_cls = add({"$classname": "PLRevGeoLocationInfo", "$classes": ["PLRevGeoLocationInfo", "NSObject"]})
    addr = {"$class": addr_cls}
    for k, v in address.items():
        addr[k] = add(v)
    addr_uid = add(addr)
    root = add({"$class": info_cls, "postalAddress": addr_uid, "isHome": False,
                "countryCode": add("ZZ")})
    return plistlib.dumps({"$archiver": "NSKeyedArchiver", "$version": 100000,
                           "$top": {"root": root}, "$objects": objects},
                          fmt=plistlib.FMT_BINARY)


def build_db(path: Path) -> None:
    c = sqlite3.connect(path)
    c.executescript("""
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDATECREATED REAL,
            ZLATITUDE REAL, ZLONGITUDE REAL, ZTRASHEDSTATE INTEGER);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY,
            ZASSET INTEGER, ZREVERSELOCATIONDATA BLOB);
        CREATE TABLE ZDETECTEDFACE (Z_PK INTEGER PRIMARY KEY,
            ZASSETFORFACE INTEGER, ZPERSONFORFACE INTEGER);
        CREATE TABLE ZPERSON (Z_PK INTEGER PRIMARY KEY, ZFULLNAME TEXT);
    """)
    recent = 800_000_000.0  # Mac-epoch seconds, well inside since_days=36500
    rows = [
        (1, recent + 4, 1.5, 2.5, revgeo_blob(_city="Testville", _country="Nowhereland",
                                             _street="1 Invented Road", _postalCode="ZZ1 1ZZ",
                                             _state="Imaginary County")),
        (2, recent + 3, 1.6, 2.6, revgeo_blob(_state="Fictional State", _country="Nowhereland")),
        (3, recent + 2, 1.7, 2.7, b"not a plist at all"),
        (4, recent + 1, 1.8, 2.8, None),
    ]
    for pk, date, lat, lon, blob in rows:
        c.execute("INSERT INTO ZASSET VALUES (?,?,?,?,0)", (pk, date, lat, lon))
        if blob is not None:
            c.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES (ZASSET, ZREVERSELOCATIONDATA) VALUES (?,?)",
                      (pk, blob))
    c.commit()
    c.close()


with tempfile.TemporaryDirectory() as td:
    d = Path(td)
    db = d / "Photos.sqlite"
    build_db(db)
    events = pm.extract_photo_events(db_path=db, since_days=36500, with_people_only=False)
    by_lat = {round(e.latitude, 1): e.location for e in events}
    check(len(events) == 4, f"4 photos extracted, got {len(events)}")
    check(by_lat.get(1.5) == "Testville, Nowhereland",
          f"blob with a city gives 'City, Country', got {by_lat.get(1.5)!r}")
    label = by_lat.get(1.5) or ""
    check("Invented" not in label and "ZZ1" not in label,
          "street and postcode never reach the label")
    check(by_lat.get(1.6) == "Fictional State, Nowhereland",
          f"no city falls back to the state, got {by_lat.get(1.6)!r}")
    check(by_lat.get(1.7) is None, f"unreadable blob gives None, got {by_lat.get(1.7)!r}")
    check(by_lat.get(1.8) is None, f"no blob gives None, got {by_lat.get(1.8)!r}")

    # Through the real writer, the way extract_all hands rows over.
    from dataclasses import asdict
    (d / "photos_events.json").write_text(json.dumps([asdict(e) for e in events], default=str))
    sent: list[str] = []
    with mock.patch.object(ing, "_sparql_update", side_effect=lambda q: sent.append(q)):
        result = ing.ingest_photo_events(d)
    body = "\n".join(sent)
    check(result.get("status") == "ok", f"ingest ok, got {result!r}")
    check('pwg:photoPlace "Testville, Nowhereland"' in body,
          "the label is written as pwg:photoPlace")
    check(body.count("pwg:photoPlace") == 2, f"2 photos carry a place, got {body.count('pwg:photoPlace')}")

    # CM044 place_pages._find_photos_in_area: area tag = first comma token of
    # the area subject, lower-cased, matched as a substring of the label.
    area_subject = "Testville, Nowhereland"
    tag = area_subject.split(",")[0].strip().lower()
    places = [e.location for e in events if e.location]
    check(sum(tag in p.lower() for p in places) == 1,
          "exactly one photo lands on the Testville place page")

if FAILURES:
    print(f"\n{len(FAILURES)} FAILURE(S)", file=sys.stderr)
    sys.exit(1)
print("\nall checks passed")
