"""VENDORED COPY of HR015 ostler_fda/tests/test_call_history.py, run against
vendor/ostler_fda (the tree that ships), not the upstream copy.

Same synthetic fixtures and the same real-SPARQL-engine (rdflib) method; the
only differences are the import header and the HOME isolation below. The
extractor, the ingest and the extract_all arm are exercised through the
vendored modules end to end, so a vendor graft that drifts from upstream, or
a vendored pwg_ingest that handles a call differently, fails HERE.

Synthetic only: every number is in OFCOM's drama range, composed from
fragments; every name is invented.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor"))


@pytest.fixture(autouse=True)
def _isolate_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("OSTLER_STATE_DIR", str(tmp_path / "state"))


from ostler_fda import call_history as ch
from ostler_fda import pwg_ingest as pi

_UK = "+44" + "7700" + "900"
_NAT = "0" + "7700" + "900"
NUM_A = _UK + "101"          # a contact
NUM_A_NATIONAL = _NAT + "101"
NUM_B = _UK + "102"          # a contact marked do-not-suggest
NUM_C = _UK + "103"          # a contact marked minor
NUM_D = _UK + "104"          # a contact at privacy level L3
NUM_E = _UK + "105"          # nobody holds it
NUM_SHARED = _UK + "106"     # a household line held by two people
EMAIL_F = "facetime-friend@example.com"

PREFIX = "https://schema.ostler.ai/ontology#"

NOW = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)


def _mac(dt: datetime) -> float:
    return dt.timestamp() - ch.MAC_EPOCH_OFFSET


def make_call_db(path: Path, rows: list[dict], extra_cols: bool = True) -> Path:
    """A CallHistory.storedata with the Core Data ZCALLRECORD schema."""
    conn = sqlite3.connect(str(path))
    conn.execute("""
        CREATE TABLE ZCALLRECORD (
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZANSWERED INTEGER, ZCALLTYPE INTEGER, ZDISCONNECTED_CAUSE INTEGER,
            ZFACE_TIME_DATA INTEGER, ZNUMBER_AVAILABILITY INTEGER,
            ZORIGINATED INTEGER, ZREAD INTEGER, ZDATE TIMESTAMP,
            ZDURATION FLOAT, ZADDRESS BLOB, ZDEVICE_ID VARCHAR,
            ZISO_COUNTRY_CODE VARCHAR, ZNAME VARCHAR,
            ZSERVICE_PROVIDER VARCHAR, ZUNIQUE_ID VARCHAR
        )""")
    for i, r in enumerate(rows, 1):
        addr = r["address"]
        conn.execute(
            "INSERT INTO ZCALLRECORD (Z_PK, Z_ENT, Z_OPT, ZANSWERED, ZCALLTYPE, "
            "ZORIGINATED, ZDATE, ZDURATION, ZADDRESS, ZNAME, ZSERVICE_PROVIDER, "
            "ZUNIQUE_ID) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (i, 2, 1, r.get("answered", 1), r.get("calltype", 1),
             r.get("originated", 0), _mac(r["when"]), r.get("duration", 60.0),
             addr.encode("utf-8") if isinstance(addr, str) else addr,
             "Cached Name", "com.apple.Telephony", r.get("uid", f"uid-{i}")))
    conn.commit()
    conn.close()
    return path


def _day(n: int) -> datetime:
    return NOW - timedelta(days=n)


STANDARD_ROWS = [
    # incoming answered phone call from A, 5 minutes
    {"address": NUM_A, "when": _day(2), "duration": 300.0, "uid": "u1"},
    # incoming MISSED call from A
    {"address": NUM_A, "when": _day(1), "answered": 0, "duration": 0.0, "uid": "u2"},
    # outgoing answered FaceTime video call to A (national format address)
    {"address": NUM_A_NATIONAL, "when": _day(3), "originated": 1, "calltype": 8,
     "duration": 900.0, "uid": "u3"},
    # outgoing unanswered: nobody picked up (NOT "missed")
    {"address": NUM_A, "when": _day(4), "originated": 1, "answered": 0,
     "duration": 0.0, "uid": "u4"},
    # FaceTime audio from an Apple ID email
    {"address": EMAIL_F.upper(), "when": _day(5), "calltype": 16, "uid": "u5"},
    # unknown call type
    {"address": NUM_A, "when": _day(6), "calltype": 99, "uid": "u6"},
    # withheld number (empty address) and an undecodable one
    {"address": "", "when": _day(7), "uid": "u7"},
    {"address": b"\xff\xfe\x00", "when": _day(8), "uid": "u8"},
    # future-dated (clock skew)
    {"address": NUM_A, "when": NOW + timedelta(days=3), "uid": "u9"},
]


# ── extractor ───────────────────────────────────────────────────────────

class TestExtractor:
    def test_fields_direction_kind_missed(self, tmp_path):
        db = make_call_db(tmp_path / "CallHistory.storedata", STANDARD_ROWS)
        out = ch.extract_calls(db, now=NOW)
        by_uid = {}
        for e in out.events:
            by_uid[e.event_id] = e
        assert len(out.events) == 6
        phone_in = next(e for e in out.events if e.duration_s == 300)
        assert (phone_in.direction, phone_in.kind, phone_in.missed) == \
            ("incoming", "phone", False)
        assert phone_in.address == NUM_A
        assert phone_in.when == _day(2)
        missed = next(e for e in out.events if e.missed)
        assert (missed.direction, missed.answered) == ("incoming", False)
        video = next(e for e in out.events if e.kind == ch.KIND_FACETIME_VIDEO)
        assert (video.direction, video.duration_s, video.missed) == \
            ("outgoing", 900, False)
        unanswered_out = next(e for e in out.events
                              if e.direction == "outgoing" and not e.answered)
        assert unanswered_out.missed is False
        audio = next(e for e in out.events if e.kind == ch.KIND_FACETIME_AUDIO)
        assert audio.address == EMAIL_F          # lower-cased

    def test_unusable_rows_are_counted_not_dropped_silently(self, tmp_path):
        db = make_call_db(tmp_path / "c.storedata", STANDARD_ROWS)
        out = ch.extract_calls(db, now=NOW)
        assert out.skipped_no_address == 2
        assert out.skipped_future == 1
        assert out.unknown_kind == 1
        assert [e.kind for e in out.events].count(ch.KIND_OTHER) == 1
        stats = ch.call_stats(out)
        assert stats["total_calls"] == 6 and stats["missed"] == 1
        assert stats["by_kind"]["other"] == 1

    def test_window_bounds(self, tmp_path):
        db = make_call_db(tmp_path / "c.storedata", STANDARD_ROWS)
        recent = ch.extract_calls(db, since_days=2, now=NOW).events
        assert [e.when for e in recent] == [_day(1)]   # lower bound is exclusive: day 2 is out
        win = ch.extract_calls(db, since=_day(4), until=_day(2), now=NOW).events
        assert len(win) == 2                                    # day 3 and day 2; day 4 is the exclusive lower bound
        assert all(_day(4) < e.when <= _day(2) for e in win)

    def test_oldest_call(self, tmp_path):
        db = make_call_db(tmp_path / "c.storedata", STANDARD_ROWS)
        assert ch.oldest_call(db) == _day(8)
        empty = make_call_db(tmp_path / "e.storedata", [])
        assert ch.oldest_call(empty) is None

    def test_event_ids_stable_and_do_not_contain_the_number(self, tmp_path):
        db = make_call_db(tmp_path / "c.storedata", STANDARD_ROWS)
        a = ch.extract_calls(db, now=NOW).events
        b = ch.extract_calls(db, now=NOW).events
        assert [e.event_id for e in a] == [e.event_id for e in b]
        assert len({e.event_id for e in a}) == len(a)
        assert all(NUM_A[-6:] not in e.event_id for e in a)

    def test_schema_mismatch_fails_loud_never_empty(self, tmp_path):
        p = tmp_path / "bad.storedata"
        conn = sqlite3.connect(str(p))
        conn.execute("CREATE TABLE ZCALLRECORD (Z_PK INTEGER, ZDATE REAL)")
        conn.commit(); conn.close()
        with pytest.raises(ch.CallHistorySchemaError):
            ch.extract_calls(p, now=NOW)
        with pytest.raises(ch.CallHistorySchemaError):
            ch.oldest_call(p)
        p2 = tmp_path / "none.storedata"
        sqlite3.connect(str(p2)).close()
        with pytest.raises(ch.CallHistorySchemaError):
            ch.extract_calls(p2, now=NOW)

    def test_missing_db_and_denied_db_raise_distinct_errors(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            ch.extract_calls(tmp_path / "nope.storedata", now=NOW)
        db = make_call_db(tmp_path / "c.storedata", STANDARD_ROWS)
        with patch.object(ch.shutil, "copy2", side_effect=PermissionError("EPERM")):
            with pytest.raises(PermissionError, match="Full Disk Access"):
                ch.extract_calls(db, now=NOW)

    def test_apple_database_is_never_written_and_copy_is_removed(self, tmp_path):
        db = make_call_db(tmp_path / "c.storedata", STANDARD_ROWS)
        before = (db.read_bytes(), db.stat().st_mtime_ns)
        seen = {}
        real_mkdtemp = ch.tempfile.mkdtemp

        def spy(*a, **k):
            d = real_mkdtemp(*a, **k)
            seen["dir"] = d
            return d
        with patch.object(ch.tempfile, "mkdtemp", side_effect=spy):
            ch.extract_calls(db, now=NOW)
        assert (db.read_bytes(), db.stat().st_mtime_ns) == before
        assert not os.path.exists(seen["dir"])           # staging copy deleted
        assert sorted(p.name for p in tmp_path.iterdir()) == ["c.storedata"]

    def test_a_wal_only_call_is_seen(self, tmp_path):
        """The newest calls live in the -wal until a checkpoint. A reader that
        opened the main file alone (or immutable=1) would miss them."""
        p = tmp_path / "w.storedata"
        conn = sqlite3.connect(str(p))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("""CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY,
            ZANSWERED INTEGER, ZCALLTYPE INTEGER, ZORIGINATED INTEGER,
            ZDATE TIMESTAMP, ZDURATION FLOAT, ZADDRESS BLOB, ZUNIQUE_ID TEXT)""")
        conn.commit()
        conn.execute("PRAGMA wal_autocheckpoint=0")
        conn.execute("INSERT INTO ZCALLRECORD VALUES (1,1,1,0,?,?,?,?)",
                     (_mac(_day(1)), 42.0, NUM_A.encode(), "w1"))
        conn.commit()
        assert (tmp_path / "w.storedata-wal").stat().st_size > 0
        try:
            out = ch.extract_calls(p, now=NOW)
        finally:
            conn.close()
        assert [e.duration_s for e in out.events] == [42]


# ── ingest, against a real SPARQL engine ────────────────────────────────

import rdflib  # a hard dependency: absent, the module fails to COLLECT (scripts/run_fda_tests.sh names it CANNOT-RUN), never skips green


class FakeStore:
    """rdflib Dataset behind the pwg_ingest SPARQL seams."""

    def __init__(self):
        self.g = rdflib.Graph()
        self.fail_query = False
        self.fail_update = False

    def query(self, sparql):
        if self.fail_query:
            raise ConnectionError("oxigraph down")
        res = self.g.query(sparql)
        out = []
        for row in res:
            b = {}
            for var in res.vars:
                v = row[var]
                if v is not None:
                    b[str(var)] = {"value": str(v)}
            out.append(b)
        return out

    def update(self, sparql):
        if self.fail_update:
            raise ConnectionError("oxigraph down")
        self.g.update(sparql)

    def add_person(self, key, name, values, priv=None):
        uri = PREFIX + "person_" + key
        P = rdflib.Namespace(PREFIX)
        s = rdflib.URIRef(uri)
        self.g.add((s, rdflib.RDF.type, P.Person))
        self.g.add((s, P.displayName, rdflib.Literal(name)))
        if priv:
            self.g.add((s, P.privacyLevel, rdflib.Literal(priv)))
        for i, (typ, val) in enumerate(values):
            idn = rdflib.URIRef(f"{uri}_id{i}")
            self.g.add((s, P.hasIdentifier, idn))
            self.g.add((idn, P.identifierType, rdflib.Literal(typ)))
            self.g.add((idn, P.identifierValue, rdflib.Literal(val)))
        return uri

    def add_record(self, cls, **preds):
        P = rdflib.Namespace(PREFIX)
        s = rdflib.URIRef(PREFIX + f"{cls.lower()}_rec_{len(self.g)}")
        self.g.add((s, rdflib.RDF.type, P[cls]))
        for k, v in preds.items():
            node = rdflib.URIRef(v) if k == "suppressedPerson" else rdflib.Literal(v)
            self.g.add((s, P[k], node))

    def calls(self):
        P = rdflib.Namespace(PREFIX)
        return list(self.g.subjects(rdflib.RDF.type, P.CallEvent))

    def objects(self, s, pred):
        P = rdflib.Namespace(PREFIX)
        return [str(o) for o in self.g.objects(rdflib.URIRef(s), P[pred])]


@pytest.fixture
def store():
    st = FakeStore()
    with patch.object(pi, "_sparql_query", st.query), \
            patch.object(pi, "_sparql_update", st.update):
        yield st


@pytest.fixture
def people(store):
    return {
        "a": store.add_person("a", "Alex Example", [("phone", NUM_A)]),
        "b": store.add_person("b", "Bea Example", [("phone", NUM_B)]),
        "c": store.add_person("c", "Cal Example", [("phone", NUM_C)]),
        "d": store.add_person("d", "Dee Example", [("phone", NUM_D)], priv="L3"),
        "f": store.add_person("f", "Fran Example", [("email", EMAIL_F)]),
        "s1": store.add_person("s1", "Sam Example", [("phone", NUM_SHARED)]),
        "s2": store.add_person("s2", "Sid Example", [("phone", NUM_SHARED)]),
    }


def _write_json(tmp_path, rows, name="c.storedata"):
    db = make_call_db(tmp_path / name, rows)
    out = ch.extract_calls(db, now=NOW)
    d = tmp_path / "fda"
    d.mkdir(exist_ok=True)
    (d / "call_history.json").write_text(
        json.dumps(ch.to_interaction_events(out.events)))
    return d


class TestIngest:
    def test_calls_attach_to_the_matched_person_with_every_field(
            self, store, people, tmp_path):
        d = _write_json(tmp_path, STANDARD_ROWS)
        res = pi.ingest_calls(d)
        assert res["status"] == "ok"
        # A: u1,u2,u3 (national format),u4,u6 ; F: u5
        assert res["events_written"] == 6
        assert res["matched_people"] == 2
        evs = store.calls()
        assert len(evs) == 6
        a = [e for e in evs if store.objects(e, "callPerson") == [people["a"]]]
        assert len(a) == 5
        missed = [e for e in a if store.objects(e, "callMissed") == ["true"]]
        assert len(missed) == 1
        assert store.objects(missed[0], "callDirection") == ["incoming"]
        video = [e for e in a if store.objects(e, "callKind") == ["facetime_video"]][0]
        assert store.objects(video, "callDirection") == ["outgoing"]
        assert store.objects(video, "callDurationSeconds") == ["900"]
        assert store.objects(video, "occurredAt") == [_day(3).isoformat()]
        # the number is NOT copied onto the event
        for e in evs:
            for o in store.g.objects(e, None):
                assert NUM_A[-6:] not in str(o)

    def test_no_person_is_ever_created_for_an_unknown_number(
            self, store, people, tmp_path):
        d = _write_json(tmp_path, [
            {"address": NUM_E, "when": _day(1), "uid": "x1"},
            {"address": NUM_E, "when": _day(2), "uid": "x2"},
        ])
        persons_before = len(list(store.g.subjects(
            rdflib.RDF.type, rdflib.Namespace(PREFIX).Person)))
        res = pi.ingest_calls(d)
        assert res["status"] == "ok"
        assert res["events_written"] == 0
        assert res["unmatched"] == 1          # distinct numbers, counted
        assert len(list(store.g.subjects(
            rdflib.RDF.type, rdflib.Namespace(PREFIX).Person))) == persons_before

    def test_a_shared_household_line_is_attributed_to_nobody(
            self, store, people, tmp_path):
        d = _write_json(tmp_path, [
            {"address": NUM_SHARED, "when": _day(1), "uid": "h1"}])
        res = pi.ingest_calls(d)
        assert (res["events_written"], res["ambiguous"]) == (0, 1)
        assert store.calls() == []

    def test_deceased_do_not_suggest_gets_no_call_events(
            self, store, people, tmp_path):
        store.add_record("SuggestionSuppression", suppressedIdentifier=NUM_B,
                         suppressedSlug="bea-example")
        d = _write_json(tmp_path, [
            {"address": NUM_B, "when": _day(1), "uid": "b1"},
            {"address": NUM_A, "when": _day(1), "uid": "a1"}])
        res = pi.ingest_calls(d)
        assert res["suppressed"] == 1 and res["events_written"] == 1
        assert store.objects(store.calls()[0], "callPerson") == [people["a"]]

    def test_minor_flag_gets_no_call_events_even_via_a_merged_node(
            self, store, people, tmp_path):
        store.add_record("MinorFlag", suppressedPerson=people["c"])
        # a second node for the same human carrying the same number
        store.add_person("c2", "Cal E.", [("phone", NUM_C)])
        d = _write_json(tmp_path, [
            {"address": NUM_C, "when": _day(1), "uid": "c1"}])
        res = pi.ingest_calls(d)
        # two holders of NUM_C -> ambiguous, and the flagged one is never written
        assert res["events_written"] == 0
        assert store.calls() == []

    def test_minor_flag_by_uri_alone(self, store, people, tmp_path):
        store.add_record("MinorFlag", suppressedPerson=people["c"])
        d = _write_json(tmp_path, [
            {"address": NUM_C, "when": _day(1), "uid": "c1"}])
        res = pi.ingest_calls(d)
        assert res["suppressed"] == 1 and store.calls() == []

    def test_l3_person_gets_no_call_events(self, store, people, tmp_path):
        d = _write_json(tmp_path, [
            {"address": NUM_D, "when": _day(1), "uid": "d1"}])
        res = pi.ingest_calls(d)
        assert res["l3_skipped"] == 1 and store.calls() == []

    def test_last_contact_only_for_connected_calls(self, store, people, tmp_path):
        d = _write_json(tmp_path, [
            {"address": NUM_A, "when": _day(10), "duration": 120.0, "uid": "k1"},
            # newer, but missed: exchanged nothing
            {"address": NUM_A, "when": _day(1), "answered": 0, "duration": 0.0,
             "uid": "k2"},
        ])
        res = pi.ingest_calls(d)
        assert res["last_contact_updated"] == 1
        assert store.objects(people["a"], "lastContactCall") == \
            [_day(10).strftime("%Y-%m-%d")]

    def test_only_missed_calls_leave_no_last_contact(self, store, people, tmp_path):
        d = _write_json(tmp_path, [
            {"address": NUM_A, "when": _day(1), "answered": 0, "duration": 0.0,
             "uid": "k2"}])
        res = pi.ingest_calls(d)
        assert res["events_written"] == 1 and res["last_contact_updated"] == 0
        assert store.objects(people["a"], "lastContactCall") == []

    def test_reimport_unchanged_writes_nothing_new(self, store, people, tmp_path):
        d = _write_json(tmp_path, STANDARD_ROWS)
        pi.ingest_calls(d)
        n1, t1 = len(store.calls()), len(store.g)
        pi.ingest_calls(d)
        assert (len(store.calls()), len(store.g)) == (n1, t1)

    def test_store_down_is_cannot_run_and_writes_nothing(
            self, store, people, tmp_path):
        d = _write_json(tmp_path, STANDARD_ROWS)
        store.fail_query = True
        res = pi.ingest_calls(d)
        assert res["status"] == "cannot_run" and "unavailable" in res["reason"]
        assert store.calls() == []

    def test_unreadable_suppression_records_fail_closed(
            self, store, people, tmp_path):
        d = _write_json(tmp_path, STANDARD_ROWS)
        real = store.query

        def flaky(q):
            if "SuggestionSuppression" in q:
                raise ConnectionError("suppression read failed")
            return real(q)
        with patch.object(pi, "_sparql_query", flaky):
            res = pi.ingest_calls(d)
        assert res["status"] == "cannot_run"
        assert store.calls() == []

    def test_no_file_and_corrupt_file_are_not_ok(self, store, tmp_path):
        d = tmp_path / "fda"; d.mkdir()
        assert pi.ingest_calls(d)["status"] == "skipped"
        (d / "call_history.json").write_text("{not json")
        assert pi.ingest_calls(d)["status"] == "cannot_run"
        (d / "call_history.json").write_text('{"a": 1}')
        assert pi.ingest_calls(d)["status"] == "cannot_run"

    def test_malformed_events_are_counted_unusable(self, store, people, tmp_path):
        d = tmp_path / "fda"; d.mkdir()
        good = ch.to_interaction_events(ch.extract_calls(
            make_call_db(tmp_path / "g.storedata",
                         [{"address": NUM_A, "when": _day(1), "uid": "g1"}]),
            now=NOW).events)[0]
        bad = dict(good, timestamp="not-a-date", event_id="zz")
        worse = {"address": NUM_A}
        (d / "call_history.json").write_text(json.dumps([good, bad, worse]))
        res = pi.ingest_calls(d)
        assert res["events_written"] == 1 and res["unusable"] == 2

    def test_dispatch_includes_calls_after_person_writers(self):
        names = [n for n, _ in pi._INGEST_DISPATCH]
        assert "calls" in names
        assert names.index("calls") > names.index("apple_mail")
        assert names.index("calls") > names.index("imessage")


# ── extract_all arm ─────────────────────────────────────────────────────

class TestExtractAllArm:
    def test_opt_in_and_listed(self):
        from ostler_fda import extract_all as ea
        assert "call_history" not in ea.DEFAULT_SOURCES
        assert "call_history" in ea.ALL_SOURCES

    def test_arm_writes_json_the_ingest_reads(self, tmp_path, monkeypatch):
        from ostler_fda import extract_all as ea
        db = make_call_db(tmp_path / "c.storedata", [
            {"address": NUM_A, "when": datetime.now(timezone.utc) - timedelta(days=1),
             "uid": "e1"}])
        monkeypatch.setattr(ch, "DEFAULT_CALL_DB", db)
        out = tmp_path / "out"
        summary = ea.run_all(output_dir=out, enabled_sources=["call_history"])
        assert summary["sources"]["call_history"]["status"] == "ok"
        assert summary["sources"]["call_history"]["total_calls"] == 1
        data = json.loads((out / "call_history.json").read_text())
        assert data[0]["kind"] == "phone" and data[0]["direction"] == "incoming"

    def test_schema_error_is_error_status_not_ok(self, tmp_path, monkeypatch):
        from ostler_fda import extract_all as ea
        p = tmp_path / "bad.storedata"
        conn = sqlite3.connect(str(p))
        conn.execute("CREATE TABLE ZCALLRECORD (Z_PK INTEGER)")
        conn.commit(); conn.close()
        monkeypatch.setattr(ch, "DEFAULT_CALL_DB", p)
        summary = ea.run_all(output_dir=tmp_path / "o",
                             enabled_sources=["call_history"])
        s = summary["sources"]["call_history"]
        assert s["status"] == "error" and "missing column" in s["error"]

    def test_disabled_by_default_run(self, tmp_path):
        from ostler_fda import extract_all as ea
        summary = ea.run_all(output_dir=tmp_path / "o", enabled_sources=["safari_history"])
        assert summary["sources"]["call_history"] == {"status": "disabled_by_user"}


# ── the twin gate: the vendored reader IS the upstream reader ───────────────
#
# vendor/ostler_fda/call_history.py is a byte copy of HR015
# ostler_fda/call_history.py. Until the ostler_fda pin moves past the HR015 PR
# that adds it, it is declared vendor-only (vendor/VENDOR_ONLY.tsv). Editing
# either copy alone changes this digest and fails here; re-copy BOTH and update
# the digest in the same PR.
CALL_HISTORY_SHA256 = "1957ab49bfc6ac7a848550fa1b75fb1419573ff24286d95edfffb0fdc807202a"


def test_vendored_call_history_is_byte_identical_to_the_pinned_upstream_copy():
    import hashlib
    got = hashlib.sha256(
        (ROOT / "vendor" / "ostler_fda" / "call_history.py").read_bytes()).hexdigest()
    assert got == CALL_HISTORY_SHA256, (
        "vendor/ostler_fda/call_history.py drifted from the pinned HR015 copy; "
        "re-copy it from HR015 and update CALL_HISTORY_SHA256 in the same PR")


def test_the_gate_can_fail_a_one_byte_drift(tmp_path):
    import hashlib
    src = (ROOT / "vendor" / "ostler_fda" / "call_history.py").read_bytes()
    assert hashlib.sha256(src + b" ").hexdigest() != CALL_HISTORY_SHA256
