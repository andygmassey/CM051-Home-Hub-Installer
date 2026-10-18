#!/usr/bin/env python3
"""A RECORDING-CONSENT FIELD MUST BE SET FROM A REAL INPUT AND BRANCHED ON.

HR015 #942, verbatim:

    ADD A GATE: for each field in the recording-consent contract, assert that
    (a) some code path SETS it from a real input, and (b) some code path
    BRANCHES on it. Neither is satisfied by a test that merely round-trips the
    value. Start narrow, with these two fields, rather than attempting a
    general solution.

============================================================================
WHAT WAS MEASURED, ON CM051 origin/main e0fb21bf, 2026-09-16
============================================================================

From a NON-iCloud checkout, because #942 records the previous scan as
CANNOT-RUN after it timed out on an iCloud path.

    jurisdiction    6 sites in ical-server.py, 2 in API.md, 0 elsewhere
    consent_basis   5 sites in ical-server.py, 2 in API.md, 0 elsewhere
    producers       0.  Every site validated the value and echoed it back.
    branches        0.  Nothing anywhere behaved differently because of it.

CONTROL, same file and same predicate: ``RECORDING_`` returns 19 sites and
``RECORDING_VALID_STATES`` is read by a real branch, so the search can find
both a constant and a branch, and the zeros are real absences.

============================================================================
WHY THIS EXECUTES AND DOES NOT GREP
============================================================================

A gate that greps for the field name passes against exactly the tree it was
written to fail: the names were already there, six and five times over. What
was missing was BEHAVIOUR. So this loads the real module, drives the real
endpoint against real temporary files, and asserts that the OUTPUT CHANGES:

    (a) SET FROM A REAL INPUT: with the producer writing jurisdiction null and
        a region file on disk saying GB, the endpoint must report GB. Paired
        with the negative: with no region file, it must report null. A
        constant cannot satisfy both.

    (b) BRANCHES ON IT: with the same one_party basis, the endpoint must
        report it in a one-party country and withhold it in an all-party one.
        Paired with the anti-vacuity arm: an all_party basis must survive in
        the same all-party country, so the branch reads the BASIS and not just
        the country.

MUTATION IS PART OF THE FILE, not a claim about it. Both limbs are re-run
against a mutant module with the producer and the branch removed, and each
must go red. A guard nobody has watched fail proves nothing.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
API_DIR = REPO / "vendor" / "cm041" / "assistant_api"
SUBJECT = API_DIR / "ical-server.py"

# ical-server.py runs as a SCRIPT with its own directory and parent on the
# path; reproduce that rather than relying on the caller's cwd.
sys.path.insert(0, str(API_DIR))
sys.path.insert(0, str(API_DIR.parent))
os.environ.setdefault("USER_ID", "testuser")

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def cannot_run(msg: str) -> None:
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    print(
        "  NOTHING was measured about the recording-consent contract. "
        "This is not a pass.",
        file=sys.stderr,
    )
    sys.exit(2)


if not SUBJECT.is_file():
    cannot_run(f"no ical-server.py at {SUBJECT}")


def install_house_stub() -> None:
    """The house ostler_security stub, copied from this repo's own suite.

    ical-server.py hard-fails at import without ostler_security.database,
    .posture and .db_key, and the real package needs `cryptography`, which is
    not a dependency a gate about a consent field may acquire. This is the
    SAME stub tests/test_cm041_usage_journal_producer.sh and the vendored
    wire-shape suite install, and it returns the "no key configured" shape on
    purpose: nothing here touches a database.
    """
    import collections
    import sqlite3
    import types

    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules.setdefault("ostler_security", pkg)
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda *a, **k: sqlite3.connect(":memory:")
    sys.modules.setdefault("ostler_security.database", db)
    po = types.ModuleType("ostler_security.posture")
    po.record_posture = lambda *a, **k: None
    sys.modules.setdefault("ostler_security.posture", po)
    DbKey = collections.namedtuple("DbKey", "key source reason detail")
    dk = types.ModuleType("ostler_security.db_key")
    dk.SOURCE_ENV = "OSTLER_DB_KEY"
    dk.SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"
    dk.REASON_NO_KEY = "no_key"
    dk.DbKey = DbKey
    dk.resolve_db_key = lambda: DbKey(None, None, "no_key", None)
    sys.modules.setdefault("ostler_security.db_key", dk)


def load(path: Path, name: str):
    """Import a copy of the server module with its side effects contained.

    The module reads env vars at import time; every path it touches is
    redirected into the caller's temp tree first.
    """
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        return None, "could not build an import spec"
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    try:
        spec.loader.exec_module(mod)
    except ModuleNotFoundError as exc:  # a missing DEPENDENCY, not a verdict
        return None, f"dependency unavailable: {exc}"
    except BaseException as exc:  # noqa: BLE001 - report, never mask
        return None, f"{type(exc).__name__}: {exc}"
    return mod, None


def drive(mod, *, jurisdiction, consent_basis, iso_country):
    """Write the producer's file and the region file, then read the endpoint.

    Returns the ``recording`` dict, or None when the endpoint reported no
    active recording (which would mean the fixture, not the product, failed).
    """
    state = {
        "meeting_id": "01HZX7QAMP9V8RKJC5X3T2W4Q1",
        "started_at": "2026-05-20T10:15:00Z",
        "state": "recording",
        "hub_machine_name": "test-hub",
        "participant_count": 3,
        "consent_basis": consent_basis,
        "jurisdiction": jurisdiction,
    }
    mod.RECORDING_STATE_FILE.write_text(json.dumps(state))
    os.utime(mod.RECORDING_STATE_FILE, (time.time(), time.time()))
    if iso_country is None:
        try:
            mod.RECORDING_REGION_FILE.unlink()
        except OSError:
            pass
    else:
        mod.RECORDING_REGION_FILE.parent.mkdir(parents=True, exist_ok=True)
        mod.RECORDING_REGION_FILE.write_text(json.dumps({
            "region": "eu",
            "iso_country": iso_country,
            "source": "locale",
            "timestamp": "2026-09-16T00:00:00Z",
        }))
    return mod.api_recording_active().get("recording")


def prepare(path: Path, tag: str):
    """Point the module's two file paths into a fresh temp tree, then load."""
    work = Path(tempfile.mkdtemp(prefix=f"rc942-{tag}-"))
    os.environ["RECORDING_STATE_FILE"] = str(work / "recording_state.json")
    os.environ["OSTLER_REGION_FILE"] = str(work / "posture" / "region.json")
    os.environ["OSTLER_HOME"] = str(work)
    mod, err = load(path, f"icalserver_{tag}")
    if mod is None:
        return None, err
    if not hasattr(mod, "api_recording_active"):
        return None, "the module has no api_recording_active"
    return mod, None


install_house_stub()

SUBJECT_MOD, SUBJECT_ERR = prepare(SUBJECT, "subject")
if SUBJECT_MOD is None:
    cannot_run(f"could not load {SUBJECT}: {SUBJECT_ERR}")

print("== the fixture must produce an active recording at all ==")
_probe = drive(
    SUBJECT_MOD, jurisdiction="GB", consent_basis="one_party", iso_country="GB",
)
if _probe is None:
    cannot_run(
        "the endpoint reported no active recording for a well-formed fixture, "
        "so every 'withheld' verdict below would be unearned"
    )
ok("a well-formed producer file yields an active recording")

print()
print("== (a) the field is SET FROM A REAL INPUT ==")

_r = drive(
    SUBJECT_MOD, jurisdiction=None, consent_basis=None, iso_country="GB",
)
if _r is not None and _r.get("jurisdiction") == "GB":
    ok("producer wrote null, the Hub's own device region supplied GB")
else:
    bad(
        "producer wrote null and the endpoint still reports "
        f"{None if _r is None else _r.get('jurisdiction')!r}. Nothing sets "
        "this field from a real input."
    )

# THE NEGATIVE HALF. Without it, a hardcoded "GB" would pass the arm above.
_r = drive(
    SUBJECT_MOD, jurisdiction=None, consent_basis=None, iso_country=None,
)
if _r is not None and _r.get("jurisdiction") is None:
    ok("CONTROL: with no region file the jurisdiction stays null, never guessed")
else:
    bad(
        "CONTROL: with no region file the endpoint still reports "
        f"{None if _r is None else _r.get('jurisdiction')!r}. That is a "
        "constant, not a value read from a real input."
    )

# WRITER AND READER MUST RESOLVE THE SAME ROOT. region.json is written by a
# DIFFERENT component (ostler_security.region), which resolves OSTLER_HOME
# before falling back to ~/.ostler. A reader that ignored OSTLER_HOME would
# find nothing on any Hub that sets it, and "nothing" here reads as "we do not
# know the jurisdiction" -- a silent, safe-looking miss.
_home = Path(tempfile.mkdtemp(prefix="rc942-home-"))
os.environ.pop("OSTLER_REGION_FILE", None)
os.environ["OSTLER_HOME"] = str(_home)
os.environ["RECORDING_STATE_FILE"] = str(_home / "recording_state.json")
_hm, _he = load(SUBJECT, "icalserver_home")
if _hm is None:
    cannot_run(f"could not reload the module for the OSTLER_HOME arm: {_he}")
if _hm.RECORDING_REGION_FILE == _home / "posture" / "region.json":
    ok("CONTROL: with OSTLER_HOME set and no override, the reader resolves the writer's own path")
else:
    bad(
        "CONTROL: OSTLER_HOME is ignored. The reader looks at "
        f"{_hm.RECORDING_REGION_FILE}, the writer writes to "
        f"{_home / 'posture' / 'region.json'}. That pair is a contract only by accident."
    )
_hm.RECORDING_REGION_FILE.parent.mkdir(parents=True, exist_ok=True)
_hm.RECORDING_REGION_FILE.write_text(json.dumps({
    "region": "eu", "iso_country": "IT", "source": "locale",
    "timestamp": "2026-09-16T00:00:00Z",
}))
_hm.RECORDING_STATE_FILE.write_text(json.dumps({
    "meeting_id": "01HZX7QAMP9V8RKJC5X3T2W4Q1",
    "started_at": "2026-05-20T10:15:00Z",
    "state": "recording",
    "hub_machine_name": "test-hub",
    "participant_count": 2,
    "consent_basis": None,
    "jurisdiction": None,
}))
_r = _hm.api_recording_active().get("recording")
if _r is not None and _r.get("jurisdiction") == "IT":
    ok("CONTROL: a region file under OSTLER_HOME is actually read end to end")
else:
    bad(
        "CONTROL: a region file under OSTLER_HOME was not read; the endpoint "
        f"reports {None if _r is None else _r.get('jurisdiction')!r}"
    )

# The producer remains the decider where it spoke.
_r = drive(
    SUBJECT_MOD, jurisdiction="FR", consent_basis=None, iso_country="GB",
)
if _r is not None and _r.get("jurisdiction") == "FR":
    ok("CONTROL: a jurisdiction the producer DID set is never overwritten")
else:
    bad(
        "CONTROL: the Hub overwrote the producer's own jurisdiction with "
        f"{None if _r is None else _r.get('jurisdiction')!r}. CM042 is the "
        "single decider."
    )

print()
print("== (b) some code path BRANCHES on it ==")

_one = drive(
    SUBJECT_MOD, jurisdiction="GB", consent_basis="one_party", iso_country="GB",
)
_all = drive(
    SUBJECT_MOD, jurisdiction="DE", consent_basis="one_party", iso_country="DE",
)
if (
    _one is not None and _one.get("consent_basis") == "one_party"
    and _all is not None and _all.get("consent_basis") is None
):
    ok("the SAME one_party basis is reported in GB and withheld in DE")
else:
    bad(
        "the same one_party basis produced "
        f"GB={None if _one is None else _one.get('consent_basis')!r} "
        f"DE={None if _all is None else _all.get('consent_basis')!r}. "
        "Nothing branches on the pair."
    )

# ANTI-VACUITY. A branch that withheld EVERY basis in DE would pass the arm
# above while destroying a correctly-obtained all-party consent.
_r = drive(
    SUBJECT_MOD, jurisdiction="DE", consent_basis="all_party", iso_country="DE",
)
if _r is not None and _r.get("consent_basis") == "all_party":
    ok("CONTROL: an all_party basis SURVIVES in DE, so the branch reads the basis too")
else:
    bad(
        "CONTROL: an all_party basis was withheld in DE "
        f"({None if _r is None else _r.get('consent_basis')!r}). The branch "
        "is reading the country only, and is destroying a valid consent."
    )

# The key set must not move: CM031 decodes this shape today.
_r = drive(
    SUBJECT_MOD, jurisdiction="DE", consent_basis="one_party", iso_country="DE",
)
_expected = {
    "meeting_id", "started_at", "state", "hub_machine_name",
    "participant_count", "consent_basis", "jurisdiction",
}
if _r is not None and set(_r) == _expected:
    ok("the wire key set is unchanged, so the shipped iOS consumer still decodes it")
else:
    bad(
        "the wire key set changed to "
        f"{sorted(_r) if _r else None}, expected {sorted(_expected)}"
    )

print()
print("== mutation: remove the producer and the branch, watch both go red ==")

_src = SUBJECT.read_text()
_mut = _src
# Strip the fallback assignment (the producer) and the withholding block (the
# branch), leaving a tree that still carries both field NAMES everywhere.
_mut, _n1 = re.subn(
    r"\n    if jurisdiction is None:\n        jurisdiction = _recording_device_jurisdiction\(\)\n",
    "\n",
    _mut,
)
_mut, _n2 = re.subn(
    r"\n    if \(\n        consent_basis is not None\n.*?\n        consent_basis = None\n",
    "\n",
    _mut,
    flags=re.S,
)
if _n1 != 1 or _n2 != 1:
    cannot_run(
        f"the mutation did not apply (producer={_n1}, branch={_n2}). "
        "A mutant that did not apply looks exactly like one that was not caught"
    )

with tempfile.TemporaryDirectory(prefix="rc942-mutant-") as _md:
    _mp = Path(_md) / "ical-server.py"
    _mp.write_text(_mut)
    _mm, _me = prepare(_mp, "mutant")
    if _mm is None:
        cannot_run(f"the mutant did not load: {_me}")

    _r = drive(_mm, jurisdiction=None, consent_basis=None, iso_country="GB")
    if _r is not None and _r.get("jurisdiction") is None:
        ok("MUTATION (a): without the producer the jurisdiction is null again, so arm (a) fires")
    else:
        bad(
            "MUTATION (a): the mutant STILL reports "
            f"{None if _r is None else _r.get('jurisdiction')!r}. Arm (a) is "
            "not measuring the producer."
        )

    _r = drive(_mm, jurisdiction="DE", consent_basis="one_party", iso_country="DE")
    if _r is not None and _r.get("consent_basis") == "one_party":
        ok("MUTATION (b): without the branch the one_party claim is repeated in DE, so arm (b) fires")
    else:
        bad(
            "MUTATION (b): the mutant STILL withheld the basis "
            f"({None if _r is None else _r.get('consent_basis')!r}). Arm (b) "
            "is not measuring the branch."
        )

print()
print("== mutation: blind the loader ==")
with tempfile.TemporaryDirectory(prefix="rc942-blind-") as _bd:
    _bp = Path(_bd) / "ical-server.py"
    _bp.write_text("# a file with no endpoint in it\n")
    _bm, _be = prepare(_bp, "blind")
    if _bm is None:
        ok("a subject with no endpoint is rejected by the loader, not scored as a pass")
    else:
        bad("a subject with no endpoint loaded and would have produced verdicts")

print()
print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
