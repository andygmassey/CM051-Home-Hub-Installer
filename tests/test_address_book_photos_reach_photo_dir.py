#!/usr/bin/env python3
"""v1.0.111: an Apple Contacts photo reaches PHOTO_DIR and foaf:img.

THE DEFECT. `ostler-contact-resync` forces the shipped syncer down
`_read_abcddb_as_vcards`, and that reader selected no image column, so no
Apple Contacts photo ever reached `write_photo`. Measured on the walk box
(Mini16, UUID checked) on 2026-10-19: no `~/.pwg/people/photos` directory at
all, `PHOTO_DIR` unset, 0 "photo write failed" lines in contact-resync.log.
The wiki consumer (CM044 `compiler/person_photo.py`) and its mount (#3018)
were therefore wired to an empty producer.

WHAT THIS DRIVES, all of it the SHIPPED vendored code (vendor/cm041, the copy
gui/project.yml bundles; the installed syncer.py on the walk box is
byte-identical to it):

    synthetic AddressBook-v22.abcddb under a fake HOME
      -> ContactSyncer._read_abcddb_as_vcards        (the change)
      -> vcard_parser.parse_vcard                    (real, sniffs + caps)
      -> ContactSyncer._persist_photo -> write_photo (real, to PHOTO_DIR)
      -> ContactSyncer._create_person_oxigraph       (real SPARQL text,
                                                      captured, not sent)

and asserts the file the CM044 consumer will read exists with the producer's
`<sha256(uri)[:32]>.<ext>` name and the exact bytes, and that the graph write
carries `foaf:img <file://...>` pointing at it.

WHERE macOS KEEPS THE IMAGE IS NOT MEASURED HERE: reading a real store needs
Full Disk Access. Every known storage shape is a row below; the reader's log
line (columns=... inline=N external=N images_dir=N none=N not_image=N) is
what a walk reads to say which one a real Mac uses.

No real person, no real photo: names are from the approved synthetic cast and
every image is generated here.

Exit 0 all pass, 1 any fail, 2 could not run.
"""
from __future__ import annotations

import hashlib
import logging
import os
import sqlite3
import struct
import sys
import tempfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
VENDOR = REPO / "vendor" / "cm041"
SUBJECT = VENDOR / "contact_syncer" / "syncer.py"

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  [PASS] %s" % m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  [FAIL] %s" % m)


def cannot(m):
    print("CANNOT-RUN: %s" % m)
    sys.exit(2)


def png(seed: int) -> bytes:
    w = h = 8
    raw = b"".join(b"\x00" + bytes(((x + seed) * 30) % 256 for x in range(w * 3)) for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


EXT_UUID = "0A11D000-0000-4000-8000-0000000000E1"
# key: (uid, first, last, ZIMAGEDATA, ZTHUMBNAILIMAGEDATA, Images/ file, expected source)
ROWS = {
    "raw":      ("00000000-AAAA-4000-8000-000000000001:ABPerson", "Jane", "Doe", png(1), None, None, "inline"),
    "framed":   ("00000000-AAAA-4000-8000-000000000002:ABPerson", "John", "Smith", b"\x01" + png(2), None, None, "inline"),
    "external": ("00000000-AAAA-4000-8000-000000000003:ABPerson", "Mary", "Jones", b"\x02" + EXT_UUID.encode() + b"\x00", None, None, "external"),
    "thumb":    ("00000000-AAAA-4000-8000-000000000004:ABPerson", "Raj", "Patel", None, b"\x01" + png(4), None, "inline"),
    "imagesdir": ("00000000-AAAA-4000-8000-000000000005:ABPerson", "Ben", "Brown", None, None, png(5), "images_dir"),
    "none":     ("00000000-AAAA-4000-8000-000000000006:ABPerson", "Sam", "Coe", None, None, None, None),
    "garbage":  ("00000000-AAAA-4000-8000-000000000007:ABPerson", "Liz", "Ross", b"\x02not-a-uuid", b"<html>", None, None),
}


def build_store(home: Path) -> Path:
    ab = home / "Library" / "Application Support" / "AddressBook"
    ab.mkdir(parents=True)
    db = ab / "AddressBook-v22.abcddb"
    conn = sqlite3.connect(str(db))
    conn.execute("CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZUNIQUEID TEXT, "
                 "ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZIMAGEDATA BLOB, ZTHUMBNAILIMAGEDATA BLOB)")
    conn.execute("CREATE TABLE ZABCDEMAILADDRESS (ZOWNER INTEGER, ZADDRESS TEXT)")
    conn.execute("CREATE TABLE ZABCDPHONENUMBER (ZOWNER INTEGER, ZFULLNUMBER TEXT)")
    for pk, (key, (uid, first, last, image, thumb, imgfile, _src)) in enumerate(ROWS.items(), 1):
        conn.execute("INSERT INTO ZABCDRECORD VALUES (?,?,?,?,?,?)", (pk, uid, first, last, image, thumb))
        conn.execute("INSERT INTO ZABCDEMAILADDRESS VALUES (?,?)", (pk, "%s@example.com" % key))
        if imgfile:
            d = ab / "Images"
            d.mkdir(exist_ok=True)
            (d / uid.split(":", 1)[0]).write_bytes(imgfile)
    conn.commit()
    conn.close()
    ext = ab / ".AddressBook-v22_SUPPORT" / "_EXTERNAL_DATA"
    ext.mkdir(parents=True)
    (ext / EXT_UUID).write_bytes(png(3))
    return db


def expected_bytes(key):
    uid, _f, _l, image, thumb, imgfile, src = ROWS[key]
    if src is None:
        return None
    if key == "external":
        return png(3)
    if imgfile:
        return imgfile
    blob = image or thumb
    return blob[1:] if blob[:1] == b"\x01" else blob


def main() -> int:
    if not SUBJECT.is_file():
        cannot("the shipped syncer is missing at %s" % SUBJECT)
    sys.path.insert(0, str(VENDOR))
    try:
        from contact_syncer import syncer as mod
        from contact_syncer.vcard_parser import parse_vcard
    except ImportError as exc:
        cannot("cannot import the vendored syncer (%s). Install "
               "vendor/cm041/contact_syncer/requirements.txt and "
               "vendor/cm041/identity_resolver/requirements.txt." % exc)
    if Path(mod.__file__).resolve() != SUBJECT.resolve():
        cannot("imported %s, not the shipped %s" % (mod.__file__, SUBJECT))

    tmp = Path(tempfile.mkdtemp(prefix="abphotos-"))
    home = tmp / "home"
    build_store(home)
    photo_dir = tmp / "people-photos"

    # The SHIPPED config module's values, with PHOTO_DIR pointed at a temp dir
    # and an Oxigraph URL nothing listens on (every update is captured below).
    from contact_syncer import config as shipped_cfg
    import types
    cfg = types.SimpleNamespace(**{k: getattr(shipped_cfg, k) for k in dir(shipped_cfg)
                                   if k.isupper()})
    cfg.PHOTO_DIR = str(photo_dir)
    cfg.OXIGRAPH_URL = "http://127.0.0.1:9"

    syncer = object.__new__(mod.ContactSyncer)
    syncer.cfg = cfg

    log_lines = []

    class _H(logging.Handler):
        def emit(self, rec):
            log_lines.append(rec.getMessage())
    mod.logger.addHandler(_H())

    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = str(home)
    try:
        vcards = syncer._read_abcddb_as_vcards()
    finally:
        if saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = saved_home

    print("abcddb photos: the reader read %d card(s) from the synthetic store" % len(vcards))
    if len(vcards) != len(ROWS):
        bad("expected %d cards, read %d, so nothing below is measured on the whole store"
            % (len(ROWS), len(vcards)))

    by_first = {}
    for vc in vcards:
        parsed = parse_vcard(vc)
        by_first[(parsed.get("given_name") or parsed.get("fn") or "").split(" ")[0]] = parsed

    captured = []
    syncer._sparql_update = lambda q: captured.append(q)

    for key, (uid, first, _last, _i, _t, _f, src) in ROWS.items():
        parsed = None
        for k, v in by_first.items():
            if k == first or (v.get("fn") or "").startswith(first):
                parsed = v
        if parsed is None:
            bad("%s: no parsed card" % key)
            continue
        want = expected_bytes(key)
        photo = parsed.get("photo")
        if want is None:
            if photo:
                bad("%s: a photo was produced where none exists" % key)
            else:
                ok("%s: no image in the store, no photo on the card" % key)
            continue
        if not photo or photo.get("data") != want:
            bad("%s (%s): the card carries no photo, or the wrong bytes" % (key, src))
            continue
        uri = "https://schema.ostler.ai/ontology#person_%s" % key
        syncer._persist_photo(uri, parsed)
        path = parsed.get("profile_photo_path") or ""
        name = "%s.png" % hashlib.sha256(uri.encode()).hexdigest()[:32]
        if Path(path).name != name or Path(path).read_bytes() != want:
            bad("%s: PHOTO_DIR file missing or misnamed (%r)" % (key, path))
            continue
        ok("%s (%s): %s written to PHOTO_DIR with the producer's name" % (key, src, name))

    # The graph write, for one person: real SPARQL text, captured.
    jane = by_first.get("Jane")
    if jane and jane.get("profile_photo_path"):
        try:
            syncer._create_person_oxigraph(
                "https://schema.ostler.ai/ontology#person_raw", "raw", jane, "person")
        except Exception as exc:  # noqa: BLE001
            bad("_create_person_oxigraph raised %s: %s" % (type(exc).__name__, exc))
        want = "foaf:img <file://%s>" % jane["profile_photo_path"]
        if any(want in q for q in captured):
            ok("the graph write carries %s" % want.split("<")[0] + "<file://.../" + Path(jane["profile_photo_path"]).name + ">")
        else:
            bad("no foaf:img triple in %d captured update(s)" % len(captured))
    else:
        bad("cannot reach the graph-write arm: the raw card has no persisted photo")

    line = next((l for l in log_lines if l.startswith("abcddb photos in")), "")
    print("LOG: %s" % line)
    if "columns=ZIMAGEDATA,ZTHUMBNAILIMAGEDATA" in line and "inline=3" in line \
            and "external=1" in line and "images_dir=1" in line and "none=1" in line \
            and "not_image=1" in line:
        ok("the per-store counter line names every bucket, so a walk can read which shape a real Mac uses")
    else:
        bad("the counter line is missing or wrong: %r" % line)

    print("\nRESULT: %d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
