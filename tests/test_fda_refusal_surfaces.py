#!/usr/bin/env python3
"""Every shape a macOS refusal takes must reach the summary as no_fda.

CM051 G1 follow-up, status-honesty sweep V26 (2026-10-15). The FDA readers in
vendor/ostler_fda turned a refusal into PermissionError (-> no_fda) only when
sqlite's message was literally "authorization denied". A refused open() reaches
Python as SQLITE_CANTOPEN "unable to open database file"; a helper can raise
EPERM "Operation not permitted"; a query can raise SQLITE_AUTH. Those fell to
status "error", so the fda tick (#2908) could not record cannot_run and the
Doctor never asked for the grant.

Arms:
  A  the classifier, one row per refusal surface, plus the non-refusals
  B  each REAL reader, pointed at a sqlite file the OS refuses to open
     (chmod 000: the same SQLITE_CANTOPEN, code 14, that a TCC refusal gives),
     must raise PermissionError. Control: a MISSING file is not a refusal.
  C  run_all's catch-all: a refusal that escapes a reader as EPERM or
     SQLITE_AUTH is reported no_fda; a plain bug is still "error".

Synthetic fixtures only; no real store is read (run_all's other sources are
disabled and owner_addresses.collect is stubbed).

Exit 0 all pass, 1 a failure, 2 CANNOT-RUN.  --repo-root <dir> for RED on main.
"""
from __future__ import annotations

import errno
import importlib
import os
import sqlite3
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
if "--repo-root" in sys.argv:
    root = Path(sys.argv[sys.argv.index("--repo-root") + 1]).resolve()
vendor = root / "vendor"
if not (vendor / "ostler_fda" / "extract_all.py").is_file():
    print("CANNOT-RUN: no vendor/ostler_fda under %s" % root, file=sys.stderr)
    sys.exit(2)
if os.geteuid() == 0:
    print("CANNOT-RUN: running as root; chmod 000 cannot simulate a refusal", file=sys.stderr)
    sys.exit(2)
sys.path.insert(0, str(vendor))

PASS = FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  [pass] " + name)
    else:
        FAIL += 1
        print("  [FAIL] " + name + (" -- " + detail if detail else ""))


def sqlite_err(code, msg):
    e = sqlite3.OperationalError(msg)
    e.sqlite_errorcode = code
    return e


tmp = Path(tempfile.mkdtemp(prefix="fdasurf."))
locked = tmp / "locked.db"
con = sqlite3.connect(str(locked))
con.execute("CREATE TABLE t (x)")
con.close()
os.chmod(locked, 0)
missing = tmp / "missing.db"

try:
    print("== A. the classifier, one row per refusal surface ==")
    try:
        from ostler_fda.tcc_refusal import is_fda_refusal
    except ImportError as exc:
        is_fda_refusal = None
        check("ostler_fda.tcc_refusal exists", False, repr(exc))
    if is_fda_refusal:
        rows = [
            ("PermissionError", PermissionError("x"), None, True),
            ("OSError EPERM 'Operation not permitted'", OSError(errno.EPERM, "Operation not permitted"), None, True),
            ("OSError EACCES", OSError(errno.EACCES, "Permission denied"), None, True),
            ("SQLITE_AUTH (23)", sqlite_err(23, "authorization denied"), None, True),
            ("SQLITE_PERM (3)", sqlite_err(3, "access permission denied"), None, True),
            ("SQLITE_CANTOPEN (14) on a file that exists", sqlite_err(14, "unable to open database file"), locked, True),
            ("SQLITE_CANTOPEN extended code (14 | 256)", sqlite_err(14 | 256, "unable to open database file"), locked, True),
            ("message only, no code: 'unable to open database file', file exists",
             sqlite3.OperationalError("unable to open database file"), locked, True),
            ("message only, no code: 'authorization denied'", sqlite3.OperationalError("authorization denied"), None, True),
            ("a refusal wrapped as the cause of another error",
             RuntimeError("wrapped").with_traceback(None), None, True),
            # NOT refusals (controls):
            ("CONTROL SQLITE_CANTOPEN on a MISSING file", sqlite_err(14, "unable to open database file"), missing, False),
            ("CONTROL SQLITE_CANTOPEN with no path", sqlite_err(14, "unable to open database file"), None, False),
            ("CONTROL SQLITE_CORRUPT (11)", sqlite_err(11, "database disk image is malformed"), None, False),
            ("CONTROL FileNotFoundError", FileNotFoundError("gone"), None, False),
            ("CONTROL ValueError", ValueError("bug"), None, False),
        ]
        rows[9][1].__cause__ = PermissionError("inner")
        for name, exc, path, want in rows:
            got = is_fda_refusal(exc, path)
            check("%s -> %s" % (name, "refusal" if want else "not a refusal"), got is want, "got %r" % got)

    print("== B. each real reader, on a file the OS refuses to open ==")
    probe = None
    try:
        sqlite3.connect("file:%s?mode=ro" % locked, uri=True).execute("SELECT 1")
    except sqlite3.Error as exc:
        probe = exc
    if probe is None:
        print("CANNOT-RUN: chmod 000 did not refuse the open on this host", file=sys.stderr)
        sys.exit(2)
    print("     (the host's refusal: %r, code %s)" % (probe, getattr(probe, "sqlite_errorcode", "n/a")))

    def call_reminders(p):
        return importlib.import_module("ostler_fda.reminders").extract_reminders(db_path=p)

    def call_notes(p):
        return importlib.import_module("ostler_fda.apple_notes").extract_notes(db_path=p)

    def call_safari(p):
        return importlib.import_module("ostler_fda.safari_history").extract_history(db_path=p)

    def call_photos(p):
        return importlib.import_module("ostler_fda.photos_metadata").extract_people(db_path=p)

    def call_photo_events(p):
        return importlib.import_module("ostler_fda.photos_metadata").extract_photo_events(db_path=p)

    def call_mail(p):
        return importlib.import_module("ostler_fda.apple_mail").extract_messages(db_path=p)

    def call_calendar(p):
        return importlib.import_module("ostler_fda.calendar").extract_events(db_path=p)

    def call_imessage(p):
        return importlib.import_module("ostler_fda.imessage").extract_conversations(db_path=p)

    def call_whatsapp(p):
        return importlib.import_module("ostler_fda.whatsapp_history")._open_readonly(p)

    readers = [("Reminders", call_reminders), ("Notes", call_notes), ("Safari", call_safari),
               ("Photos people", call_photos), ("Photos events", call_photo_events),
               ("Mail", call_mail), ("Calendar", call_calendar), ("iMessage", call_imessage),
               ("WhatsApp", call_whatsapp)]
    for label, fn in readers:
        try:
            fn(locked)
            check("%s: a refused open raises PermissionError" % label, False, "returned normally")
        except PermissionError:
            check("%s: a refused open raises PermissionError (-> no_fda)" % label, True)
        except TypeError as exc:
            check("%s: reader signature" % label, False, repr(exc))
        except Exception as exc:  # noqa: BLE001
            check("%s: a refused open raises PermissionError" % label, False, repr(exc))
    try:
        call_imessage(missing)
        check("CONTROL iMessage: a missing file is not a refusal", False, "returned normally")
    except PermissionError:
        check("CONTROL iMessage: a missing file is not a refusal", False, "raised PermissionError")
    except Exception:  # noqa: BLE001
        check("CONTROL iMessage: a missing file is not a refusal", True)

    print("== C. run_all's catch-all classifies an escaped refusal ==")
    import ostler_fda.extract_all as ea
    import ostler_fda.owner_addresses as oa
    import ostler_fda.reminders as rem
    oa.collect = lambda *a, **k: {"status": "stubbed"}
    real = rem.extract_reminders
    for label, exc, want in [
        ("EPERM from a helper", OSError(errno.EPERM, "Operation not permitted"), "no_fda"),
        ("SQLITE_AUTH at query time", sqlite_err(23, "authorization denied"), "no_fda"),
        ("CONTROL a plain bug", ValueError("bug"), "error"),
    ]:
        def boom(*a, _e=exc, **k):
            raise _e
        rem.extract_reminders = boom
        out = tmp / ("out-" + str(abs(hash(label))))
        try:
            summary = ea.run_all(output_dir=out, enabled_sources={"reminders"})
            got = summary["sources"]["reminders"]["status"]
        except Exception as e2:  # noqa: BLE001
            got = "raised %r" % e2
        check("%s -> %s" % (label, want), got == want, "got %s" % got)
    rem.extract_reminders = real

    print("== D. Apple Music: ok-with-nothing-read is not ok ==")
    import ostler_fda.apple_music as am
    real_lib = am.extract_library
    real_prev = am.previous_export_track_count
    am.previous_export_track_count = lambda *_a, **_k: 0
    fake_track = am.Track(track_id="1", name="Synthetic Song", artist="Synthetic Artist", album=None, genre=None, play_count=1, last_played=None, rating=None, loved=False)
    for label, lib, want in [
        ("0 tracks, reader none, native unavailable -> media_library_not_granted",
         am.MusicLibrary(reader="none", native_status="unavailable"), "media_library_not_granted"),
        ("0 tracks, native empty (framework answered) -> not_found",
         am.MusicLibrary(reader="none", native_status="empty"), "not_found"),
        ("0 tracks, no helper tried -> not_found",
         am.MusicLibrary(reader="none", native_status="not_tried"), "not_found"),
        ("CONTROL 1 track read natively -> ok",
         am.MusicLibrary(tracks=[fake_track], reader="native", native_status="ok"), "ok"),
    ]:
        am.extract_library = lambda *a, _l=lib, **k: _l
        out = tmp / ("music-" + str(abs(hash(label))))
        try:
            summary = ea.run_all(output_dir=out, enabled_sources={"apple_music"})
            got = summary["sources"]["apple_music"]["status"]
        except Exception as e3:  # noqa: BLE001
            got = "raised %r" % e3
        check(label, got == want, "got %s" % got)
    am.extract_library = real_lib
    am.previous_export_track_count = real_prev
finally:
    os.chmod(locked, 0o600)

print()
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
if PASS == 0:
    print("CANNOT-RUN: nothing was measured", file=sys.stderr)
    sys.exit(2)
sys.exit(1 if FAIL else 0)
