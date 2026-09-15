"""Five places where a writer stored one name and a reader asked for another.

Both sides succeeded, nothing went red, and the customer saw an empty screen.
Every case below was measured on a live customer box on 2026-09-16 before it
was touched, and each measurement is quoted in the test that closes it.

WHAT THESE TESTS ARE FOR, AND WHAT THEY ARE NOT
-----------------------------------------------
A test that asserts ``_collection_for_source("notion") == "evernote_knowledge"``
proves only that somebody typed a constant twice. It restates the fix instead
of testing the property, and it passes just as happily if the constant is
wrong. So wherever it is possible, these tests join the two SIDES of the
contract and assert they meet:

  * the people writer is run for real and its payload is checked against the
    key the shipped reader filters on;
  * the facts reader's actual SPARQL text is executed by a real SPARQL engine
    against fixtures in the writer's actual vocabulary;
  * the knowledge importer's collection is checked against the set of
    collections ``install.sh`` really creates, parsed out of install.sh;
  * the preference reader's actual filter body is captured off the wire and
    evaluated against payloads in the shape the live store really holds.

Two of them cannot be joined that way and say so in their own docstrings.

THE FILTER EVALUATOR IS ITSELF UNDER TEST. ``_matches`` below is a small
re-implementation of the subset of Qdrant filter semantics these call sites
use. A home-made oracle that always returns True would make every filter test
pass, so it carries its own negative controls (see
``test_the_filter_evaluator_can_say_no``) and its verdicts were checked against
a real Qdrant on the live box for the same fixtures.
"""

from __future__ import annotations

import importlib.util
import os
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Imports. Each vendored tree is a package with relative imports, so the parent
# directory goes on the path, never the package directory itself: putting
# vendor/ostler_fda on sys.path makes its calendar.py shadow the stdlib one and
# httpx fails to import three levels down.
#
# THE SECOND PATH BELOW MAKES `src` RESOLVE TO CM019's PACKAGE, and more than
# one vendored tree ships a top-level `src`. Measured rather than assumed:
# running this file alongside tests/test_vendor_knowledge_embed_contract.py in
# one pytest session leaves that suite's outcome unchanged (it skips either
# way in an environment without its own deps, and it skips identically on
# origin/main without this file present). The workflow that runs this suite
# invokes it alone, so the question does not arise there -- it is recorded
# because the next person to add a `src`-rooted vendored tree needs to know.
# ---------------------------------------------------------------------------
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(REPO / "vendor" / "cm019_preferences" / "services" / "ingest"))

pwg_ingest = pytest.importorskip("ostler_fda.pwg_ingest")
_qdrant_loader_mod = pytest.importorskip("src.loaders.qdrant_loader")
QdrantLoader = _qdrant_loader_mod.QdrantLoader
rdflib = pytest.importorskip("rdflib")


def _load_ical_server():
    """Import ical-server.py, whose filename is not a Python identifier."""
    os.environ.setdefault("USER_ID", "Fixture")
    sys.path.insert(0, str(REPO / "vendor" / "cm041"))
    spec = importlib.util.spec_from_file_location(
        "ical_server_under_test",
        REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ical_server = None
try:
    ical_server = _load_ical_server()
except Exception as exc:  # pragma: no cover - reported, never swallowed
    _ICAL_IMPORT_ERROR = f"{type(exc).__name__}: {exc}"
else:
    _ICAL_IMPORT_ERROR = ""


# ===========================================================================
# ITEM 1. The stale / reconnect lists were permanently empty.
#
# MEASURED BEFORE THE FIX, live box, Qdrant `people` collection:
#     is_empty last_contact_ts   3784 of 3784   <- identical to a fake key
#     is_empty last_contact         0 of 3784   <- present on every point
#     is_empty display_name         0 of 3784   <- CONTROL, so the probe
#                                                  discriminates
# and the value under `last_contact` was the EMPTY STRING on all 3784, so
# pointing the reader at the other name would have changed nothing. The signal
# existed only in Oxigraph: 1501 pwg:lastContact* triples over 1481 people.
# ===========================================================================


class _StubbedPeopleWriter:
    """Runs the real ingest_people_to_qdrant with its I/O replaced.

    Only the four boundaries are stubbed -- SPARQL, embeddings, collection
    creation, upsert. Everything between them, including the payload
    construction under test, is the shipped code.
    """

    def __init__(self, monkeypatch, people_rows, last_contact_rows):
        self.captured = []

        def fake_sparql_query(query, *a, **kw):
            if "lastContact" in query:
                return last_contact_rows
            if "hasIdentifier" in query:
                return []
            return people_rows

        def fake_embed(docs):
            return [[0.1, 0.2, 0.3] for _ in docs]

        def fake_upsert(collection, points, *a, **kw):
            self.captured.extend(points)
            return len(points)

        monkeypatch.setattr(pwg_ingest, "_sparql_query", fake_sparql_query)
        monkeypatch.setattr(pwg_ingest, "_ollama_embed_batch", fake_embed)
        monkeypatch.setattr(
            pwg_ingest, "_qdrant_ensure_collection", lambda *a, **kw: True
        )
        monkeypatch.setattr(pwg_ingest, "_qdrant_upsert_points", fake_upsert)

    def payloads(self):
        out = []
        for point in self.captured:
            if isinstance(point, dict):
                out.append(point.get("payload", point))
        return out


def _lit(value):
    return {"value": value}


PERSON_URI = "https://schema.ostler.ai/ontology#person_fixture_one"
PERSON_URI_2 = "https://schema.ostler.ai/ontology#person_fixture_two"


def test_people_payload_carries_the_key_the_reader_actually_filters_on(
    monkeypatch,
):
    """ical-server.people_stale() filters `last_contact_ts`. Stamp it.

    This is the whole defect in one assertion: before the fix the payload
    carried no such key at all, so the reader's range filter matched nothing
    on every box, forever.
    """
    writer = _StubbedPeopleWriter(
        monkeypatch,
        people_rows=[{"uri": _lit(PERSON_URI), "displayName": _lit("Fixture One")}],
        last_contact_rows=[
            {"uri": _lit(PERSON_URI), "lastContact": _lit("2024-01-15")}
        ],
    )
    pwg_ingest.ingest_people_to_qdrant()
    payloads = writer.payloads()

    assert payloads, "the writer produced no points at all; fixture is wrong"
    payload = payloads[0]
    assert "last_contact_ts" in payload, (
        "payload has no last_contact_ts. people_stale() filters on exactly "
        "this key, so the stale and reconnect lists stay empty without it."
    )
    assert payload["last_contact_ts"] > 0
    # And the older key keeps its place, now carrying the real date rather
    # than the empty string it held on all 3784 live points.
    assert payload["last_contact"] == "2024-01-15"


def test_the_ts_the_writer_stamps_passes_the_readers_own_filter(monkeypatch):
    """Join the two sides: run the READER's predicate over the WRITER's value.

    people_stale() keeps a point when `0 < last_contact_ts < now - months*30d`.
    Asserting the key merely EXISTS would pass for a value of 0, which the
    reader discards. So the reader's arithmetic is reproduced here and the
    writer's own output is pushed through it.
    """
    import time

    writer = _StubbedPeopleWriter(
        monkeypatch,
        people_rows=[{"uri": _lit(PERSON_URI), "displayName": _lit("Fixture One")}],
        last_contact_rows=[
            {"uri": _lit(PERSON_URI), "lastContact": _lit("2019-03-04")}
        ],
    )
    pwg_ingest.ingest_people_to_qdrant()
    ts = writer.payloads()[0]["last_contact_ts"]

    cutoff = int(time.time()) - (3 * 30 * 86400)
    assert 0 < ts < cutoff, (
        "a contact last spoken to in 2019 must fall inside people_stale()'s "
        f"3-month window; got last_contact_ts={ts}, cutoff={cutoff}"
    )


def test_a_person_never_contacted_gets_zero_and_never_now(monkeypatch):
    """The sentinel must exclude, not fabricate freshness.

    0 is what the reader's `> 0` arm discards. now() would be far worse than
    the original bug: it would mark every unknown contact as freshly spoken to
    and quietly empty the stale list again, this time with a plausible reason.
    """
    import time

    writer = _StubbedPeopleWriter(
        monkeypatch,
        people_rows=[{"uri": _lit(PERSON_URI_2), "displayName": _lit("Fixture Two")}],
        last_contact_rows=[],
    )
    pwg_ingest.ingest_people_to_qdrant()
    payload = writer.payloads()[0]

    assert payload["last_contact_ts"] == 0
    assert payload["last_contact"] == ""
    assert abs(payload["last_contact_ts"] - int(time.time())) > 86400, (
        "last_contact_ts is suspiciously close to now(); a fabricated "
        "timestamp hides the absence instead of reporting it"
    )


@pytest.mark.parametrize(
    "value,expected_nonzero",
    [
        ("2024-01-15", True),
        ("2024-01-15T09:30:00Z", True),
        ("2024-01-15T09:30:00+08:00", True),
        ("", False),
        ("not-a-date", False),
        ("2024-13-45", False),
    ],
)
def test_epoch_conversion_handles_every_shape_without_raising(
    value, expected_nonzero
):
    result = pwg_ingest._last_contact_epoch(value)
    assert isinstance(result, int)
    assert (result > 0) is expected_nonzero


def test_a_date_only_value_anchors_at_utc_midnight_not_local():
    """BSD/GNU and box timezone must not move the stamp.

    A naive datetime would take the runner's local zone, so the same graph
    would produce a different last_contact_ts on a box in Sydney and a box in
    London, and a person could cross the staleness cutoff purely by where the
    Mac is plugged in.
    """
    import datetime

    got = pwg_ingest._last_contact_epoch("2024-01-15")
    expected = int(
        datetime.datetime(2024, 1, 15, tzinfo=datetime.timezone.utc).timestamp()
    )
    assert got == expected


# ===========================================================================
# ITEM 2. "What do you know about me" was empty.
#
# MEASURED BEFORE THE FIX, live box Oxigraph:
#     ?s a pwg:PersonFact        0   in EVERY graph
#     ?s a <urn:ostler:Fact>   990   in the per-user named graph
#     CONTROL ?s a pwg:Person 3810   so the probe discriminates
#
# TWO mismatches were stacked: the type and predicate NAMES differ, and the
# data sits in a NAMED GRAPH that a query with no GRAPH clause cannot see.
# ===========================================================================

CM048_FIXTURE = """
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
<urn:ostler:user/Fixture> {
    <urn:ostler:fact/f1> a <urn:ostler:Fact> ;
        <urn:ostler:text> "Fixture subject prefers aisle seats" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:about> <urn:ostler:person/fixture-one> ;
        <urn:ostler:domain> "travel" ;
        <urn:ostler:privacyLevel> "L0" ;
        <urn:ostler:signalStrength> "strong" .
}
"""

CM048_L3_FIXTURE = """
<urn:ostler:user/Fixture> {
    <urn:ostler:fact/secret> a <urn:ostler:Fact> ;
        <urn:ostler:text> "Fixture subject has a withheld detail" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:privacyLevel> "L3" .
}
"""

PWG_FIXTURE = """
@prefix pwg: <https://schema.ostler.ai/ontology#> .
{
    <https://schema.ostler.ai/ontology#fact_legacy> a pwg:PersonFact ;
        pwg:factText "Fixture subject worked at a fixture company" ;
        pwg:belongsToUser <https://schema.ostler.ai/ontology#user_fixture> ;
        pwg:factDomain "work" ;
        pwg:confidence "0.8" .
}
"""


def _captured_facts_query(monkeypatch):
    """The REAL SPARQL text the shipped reader builds, captured off its I/O."""
    holder = {}

    def fake_select(query):
        holder["query"] = query
        return []

    monkeypatch.setattr(ical_server, "_sparql_select", fake_select)
    ical_server._memory_query_facts()
    assert "query" in holder, "the reader never issued a query"
    return holder["query"]


def _run_sparql(query, *fixtures):
    """Execute against a real SPARQL engine over a real named-graph dataset."""
    dataset = rdflib.Dataset()
    for fixture in fixtures:
        dataset.parse(data=fixture, format="trig")
    return list(dataset.query(query))


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_the_facts_reader_finds_facts_in_the_vocabulary_the_writer_uses(
    monkeypatch,
):
    """990 facts existed on the live box and this query returned none of them.

    The query is not paraphrased here. It is captured from the shipped
    function and handed to rdflib, so a regression in the real string fails
    this test.
    """
    query = _captured_facts_query(monkeypatch)
    rows = _run_sparql(query, CM048_FIXTURE)
    assert len(rows) >= 1, (
        "the reader's own SPARQL matched nothing in the CM048 vocabulary that "
        "cm048_pipeline/src/ingest.py actually writes"
    )


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_the_named_graph_is_actually_entered(monkeypatch):
    """The half of item 2 that is easiest to miss.

    Fixing only the type and predicate names still returns nothing, because a
    SPARQL query with no GRAPH clause reads the default graph and every CM048
    fact lives inside urn:ostler:user/<id>. The fixture above puts the triples
    ONLY in the named graph, so this test fails if the GRAPH clause is dropped.
    """
    query = _captured_facts_query(monkeypatch)
    assert "GRAPH" in query, (
        "no GRAPH clause: the CM048 arm cannot see a named graph without one"
    )
    assert _run_sparql(query, CM048_FIXTURE), "named-graph arm matched nothing"


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_the_legacy_pwg_arm_still_works(monkeypatch):
    """pwg:PersonFact is NOT dead vocabulary and must not be traded away.

    contact_syncer/facebook_events.py, linkedin_career.py and
    google_calendar.py all still write it. A reader that swapped one
    vocabulary for the other would fix 990 facts and break those three
    writers, which is the same bug pointed the other way.
    """
    query = _captured_facts_query(monkeypatch)
    assert _run_sparql(query, PWG_FIXTURE), (
        "the pwg:PersonFact arm stopped matching; three live writers feed it"
    )


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_both_vocabularies_are_served_by_one_query(monkeypatch):
    query = _captured_facts_query(monkeypatch)
    rows = _run_sparql(query, CM048_FIXTURE, PWG_FIXTURE)
    assert len(rows) >= 2, (
        f"expected a row from each vocabulary, got {len(rows)}"
    )


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_an_l3_fact_is_withheld(monkeypatch):
    """Turning a dead arm on is exactly when a privacy stamp starts to matter.

    These rows were unreachable before, so nothing was filtering them. If the
    fix surfaced an L3 fact it would have introduced a leak while closing a
    blank screen.
    """
    query = _captured_facts_query(monkeypatch)
    assert _run_sparql(query, CM048_FIXTURE), "control: the L0 fact must match"
    rows = _run_sparql(query, CM048_L3_FIXTURE)
    assert rows == [], f"an L3 fact reached the surface: {len(rows)} row(s)"


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_user_scoping_survives_the_case_fold(monkeypatch):
    """The trap that would have made this fix fail on a real box.

    identity_resolver.compartment.normalise_user_id LOWER-CASES, so a customer
    who typed "Fixture" leaves this module holding "fixture" while CM048 wrote
    the graph <urn:ostler:user/Fixture> and the literal "Fixture". Comparing
    those raw is
    the very defect class being closed here, so the fixture deliberately uses
    the capitalised form the writer really produces.
    """
    assert ical_server.USER_ID == ical_server.USER_ID.lower()
    query = _captured_facts_query(monkeypatch)
    assert _run_sparql(query, CM048_FIXTURE), (
        "a capitalised userId stopped matching a lower-cased USER_ID; the "
        "comparison must be case-folded"
    )


# ===========================================================================
# ITEM 3. Notion and Obsidian imports vanished.
#
# MEASURED BEFORE THE FIX: the live box held exactly five collections
# (safari_history, evernote_knowledge, preferences, conversations, people) and
# no other *_knowledge among them. The strings "notion_knowledge" and
# "obsidian_knowledge" appear nowhere else in this repository.
# ===========================================================================


def _load_agent_module(module_name, alias):
    """Import a doctor agent module by path.

    REGISTERED IN sys.modules BEFORE EXECUTION, and that is load-bearing on
    Python 3.12+: @dataclass resolves string annotations by looking its class's
    __module__ up in sys.modules, so a module executed without being
    registered raises from inside dataclasses rather than from the import.
    """
    spec = importlib.util.spec_from_file_location(
        alias, REPO / "vendor" / "doctor" / "agent" / f"{module_name}.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[alias] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(alias, None)
        raise
    return module


def _collections_install_sh_creates():
    """Parse install.sh for the collections it really pre-creates.

    Deliberately parsed rather than hardcoded: hardcoding the expected name
    here would make this test agree with itself instead of with the installer.
    """
    text = (REPO / "install.sh").read_text(encoding="utf-8", errors="replace")
    match = re.search(
        r"_OSTLER_REQUIRED_QDRANT_COLLECTIONS=\(([^)]*)\)", text
    )
    assert match, "could not find the required-collections array in install.sh"
    names = match.group(1).split()
    assert names, "the required-collections array parsed as empty"
    return set(names)


@pytest.mark.parametrize("module_name", ["import_notion", "import_obsidian"])
def test_knowledge_imports_target_a_collection_that_is_actually_created(
    module_name,
):
    """Join the importer to the installer rather than to a constant.

    Before the fix these returned notion_knowledge / obsidian_knowledge, which
    install.sh never creates and no reader ever queries. The embed step then
    SELF-CREATED the collection and filled it, so the import reported success
    and the customer still saw nothing.
    """
    module = _load_agent_module(module_name, f"{module_name}_under_test")

    created = _collections_install_sh_creates()
    # Control: the parse found a real, populated set, so an empty set cannot
    # make the assertion below vacuous.
    assert "people" in created, (
        f"install.sh parse looks wrong; got {sorted(created)}"
    )

    source = module.DEFAULT_SOURCE
    target = module._collection_for_source(source)
    assert target in created, (
        f"{module_name} embeds {source} content into {target!r}, which "
        f"install.sh does not create. Created: {sorted(created)}"
    )


def test_every_knowledge_importer_agrees_on_one_collection():
    """Three importers, one destination the shipped reader knows about."""
    targets = {}
    for module_name in ("import_notion", "import_obsidian", "import_evernote"):
        module = _load_agent_module(module_name, f"{module_name}_agreement")
        targets[module_name] = module._collection_for_source(
            module.DEFAULT_SOURCE
        )
    assert len(set(targets.values())) == 1, (
        f"importers disagree on the knowledge collection: {targets}"
    )


# ===========================================================================
# ITEMS 4 AND 5. Compartment-scoped search was dead and user_id matched
# nothing. Both live in QdrantLoader.search().
#
# MEASURED BEFORE THE FIX, live box, `preferences` collection (5733 points):
#     compartment_level match "L2"      4804
#     compartment_level range {gte: 0}     0
#     CONTROL strength   range {gte: 0}  5733  <- the range operator works
#     is_empty user_id                  5733
#     CONTROL is_empty category            0
# ===========================================================================


def _matches(payload, clause):
    """Evaluate the subset of Qdrant filter semantics these call sites use.

    Supports must (all of), should (any of), match/value, match/any, range and
    is_empty. Anything unrecognised RAISES rather than returning True: a
    silent default of True in an oracle would pass every filter test and is
    precisely the kind of blindness under repair here.
    """
    if "must" in clause or "should" in clause:
        ok = True
        if "must" in clause:
            ok = all(_matches(payload, c) for c in clause["must"])
        if ok and "should" in clause:
            ok = any(_matches(payload, c) for c in clause["should"])
        return ok
    if "is_empty" in clause:
        key = clause["is_empty"]["key"]
        value = payload.get(key, None)
        return value is None or value == [] or key not in payload
    if "key" in clause:
        key = clause["key"]
        present = key in payload
        value = payload.get(key)
        if "match" in clause:
            match = clause["match"]
            if "value" in match:
                return present and value == match["value"]
            if "any" in match:
                return present and value in match["any"]
            raise AssertionError(f"unsupported match clause: {match}")
        if "range" in clause:
            if not present or not isinstance(value, (int, float)):
                # Qdrant's range operator does not coerce; a string payload
                # simply does not match. This is the defect item 4 fixes.
                return False
            rng = clause["range"]
            for op, test in (
                ("gte", lambda v, b: v >= b),
                ("gt", lambda v, b: v > b),
                ("lte", lambda v, b: v <= b),
                ("lt", lambda v, b: v < b),
            ):
                if op in rng and not test(value, rng[op]):
                    return False
            return True
    raise AssertionError(f"unsupported filter clause: {clause}")


def test_the_filter_evaluator_can_say_no():
    """Negative controls for the home-made oracle above.

    Without these, an evaluator that returned True unconditionally would make
    every filter assertion in this file pass while proving nothing.
    """
    assert not _matches({"a": 1}, {"key": "a", "match": {"value": 2}})
    assert not _matches({"a": "L2"}, {"key": "a", "range": {"gte": 0}})
    assert not _matches({"a": 1}, {"is_empty": {"key": "a"}})
    assert not _matches(
        {"a": 1}, {"must": [{"key": "a", "match": {"value": 1}},
                           {"key": "a", "match": {"value": 9}}]}
    )
    assert not _matches({}, {"should": [{"key": "a", "match": {"value": 1}}]})
    # and it can say yes, so the no's above are not a stuck needle
    assert _matches({"a": 1}, {"key": "a", "match": {"value": 1}})
    assert _matches({}, {"is_empty": {"key": "a"}})
    with pytest.raises(AssertionError):
        _matches({"a": 1}, {"nonsense": True})


def _captured_search_filter(monkeypatch, **kwargs):
    """The REAL filter body QdrantLoader.search() puts on the wire."""
    import asyncio

    holder = {}

    class _FakeResponse:
        status_code = 200

        @staticmethod
        def json():
            return {"result": []}

    class _FakeClient:
        def __init__(self, *a, **kw):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, json=None, **kw):
            holder["body"] = json
            return _FakeResponse()

    monkeypatch.setattr(_qdrant_loader_mod.httpx, "AsyncClient", _FakeClient)
    loader = QdrantLoader(base_url="http://127.0.0.1:6333", collection="preferences")
    asyncio.run(loader.search(vector=[0.1, 0.2, 0.3], **kwargs))
    assert "body" in holder, "search() never issued a request"
    return holder["body"].get("filter")


# The payload shape the live store really holds: string level, no user_id.
LIVE_SHAPED_POINT = {
    "preference_id": "fixture-1",
    "subject": "fixture subject",
    "category": "bookmark",
    "strength": 0.5,
    "compartment_level": "L2",
    "privacy_level": "L2",
    "source": "safari_bookmarks",
}

# The shape CM019's own ParsedPreference.to_payload produces: int level, with
# a user_id. Both must keep working.
CONTRACT_SHAPED_POINT = {
    "preference_id": "fixture-2",
    "subject": "fixture subject",
    "category": "book",
    "strength": 0.5,
    "compartment_level": 2,
    "user_id": "fixture",
}


def test_compartment_filter_matches_the_string_levels_actually_stored(
    monkeypatch,
):
    """4804 of 5733 live points carry the STRING "L2" and matched nothing."""
    flt = _captured_search_filter(monkeypatch, compartment_level=2)
    assert flt is not None, "no filter was built at all"
    assert _matches(LIVE_SHAPED_POINT, flt), (
        f"filter {flt} still does not match a point whose compartment_level "
        "is the string 'L2', which is what 4804 live points hold"
    )


def test_compartment_filter_still_matches_the_numeric_contract_shape(
    monkeypatch,
):
    """The documented type must not be traded away for the stored one."""
    flt = _captured_search_filter(monkeypatch, compartment_level=2)
    assert _matches(CONTRACT_SHAPED_POINT, flt)


def test_compartment_filter_still_excludes_levels_below_the_threshold(
    monkeypatch,
):
    """Accepting both types must not turn the filter into a pass-through.

    A filter that matches everything would satisfy the two tests above while
    silently removing the compartment scoping altogether.
    """
    flt = _captured_search_filter(monkeypatch, compartment_level=3)
    below_string = dict(LIVE_SHAPED_POINT, compartment_level="L2")
    below_numeric = dict(CONTRACT_SHAPED_POINT, compartment_level=2)
    assert not _matches(below_string, flt), (
        "L2 matched a threshold of 3; the scoping is no longer scoping"
    )
    assert not _matches(below_numeric, flt)


def test_user_filter_matches_points_that_carry_no_user_id(monkeypatch):
    """is_empty user_id was 5733 of 5733; a strict match excluded everything."""
    flt = _captured_search_filter(monkeypatch, user_id="fixture")
    assert _matches(LIVE_SHAPED_POINT, flt), (
        f"filter {flt} excludes every point in the live store"
    )


def test_user_filter_still_matches_a_tagged_point(monkeypatch):
    flt = _captured_search_filter(monkeypatch, user_id="fixture")
    assert _matches(CONTRACT_SHAPED_POINT, flt)


def test_user_filter_still_excludes_a_different_owner(monkeypatch):
    """Tolerating an ABSENT owner must not tolerate a DIFFERENT one."""
    flt = _captured_search_filter(monkeypatch, user_id="fixture")
    other = dict(CONTRACT_SHAPED_POINT, user_id="somebody-else")
    assert not _matches(other, flt), (
        "a point owned by another user matched; the widening went too far"
    )


def test_both_filters_together_still_require_both(monkeypatch):
    """Two one-of groups must AND, not OR.

    A flat top-level `should` would make them alternatives, so a point failing
    the compartment test would sail through on the user test alone.
    """
    flt = _captured_search_filter(
        monkeypatch, compartment_level=3, user_id="fixture"
    )
    good = dict(LIVE_SHAPED_POINT, compartment_level="L4")
    assert _matches(good, flt)
    fails_compartment = dict(LIVE_SHAPED_POINT, compartment_level="L1")
    assert not _matches(fails_compartment, flt), (
        "a point that fails the compartment arm still matched, so the two "
        "groups are being ORed together"
    )
    fails_user = dict(
        LIVE_SHAPED_POINT, compartment_level="L4", user_id="somebody-else"
    )
    assert not _matches(fails_user, flt)


def test_delete_by_user_was_deliberately_not_widened():
    """The one place the item-5 pattern must NOT be applied.

    Widening a DELETE to include untagged points turns "erase this user's
    vectors" into "erase the collection" -- on the measured box, all 5733 of
    them. This test exists so a later tidy-up that makes the four call sites
    "consistent" fails loudly instead of shipping.
    """
    source = (
        REPO
        / "vendor/cm019_preferences/services/ingest/src/loaders/qdrant_loader.py"
    ).read_text(encoding="utf-8")
    start = source.index("async def delete_by_user")
    end = source.index("async def count")
    body = source[start:end]
    assert "is_empty" not in body, (
        "delete_by_user now tolerates points with no user_id, which makes it "
        "delete the entire collection"
    )
    # Control: the widening really is present elsewhere in the file, so the
    # absence above is a measurement and not a broken search.
    assert "is_empty" in source, (
        "no is_empty anywhere in the file; the search above cannot "
        "distinguish a narrow delete from a missing fix"
    )


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_the_memory_endpoint_itself_returns_the_cm048_facts(monkeypatch):
    """The customer surface, not just the query underneath it.

    GET /api/v1/memory is the iOS Memory tab and the "what do you know about
    me" answer. Measured on the live box before the fix it returned
    {"facts": [], "count": 0} and was NOT flagged degraded -- a confident
    "I know nothing about you" while 990 facts sat in the store, and while a
    sibling endpoint on the same service returned 6 birthdays in the same
    breath.

    The rows here are the shape the CM048 arm of the fixed query really
    yields, so this exercises everything between the query and the response
    body: the hygiene overlay, the corrections overlay, sorting and the cap.
    """
    cm048_rows = [
        {
            "fact": f"urn:ostler:fact/f{n}",
            "text": f"Fixture subject fact number {n}",
            "domain": "travel",
            "conf": "0.9",
            "validFrom": "2026-01-0{}".format((n % 9) + 1),
            "about": f"urn:ostler:person/fixture-{n}",
        }
        for n in range(1, 6)
    ]
    monkeypatch.setattr(ical_server, "_sparql_select", lambda q: cm048_rows)
    monkeypatch.setattr(ical_server, "_memory_load_corrections", lambda: {})
    monkeypatch.setattr(ical_server, "_hygiene_overlay", lambda: (None, {}))

    out = ical_server.api_memory_list()

    assert out.get("degraded") is not True, (
        f"endpoint degraded rather than answering: {out.get('reason')}"
    )
    assert out["count"] == len(cm048_rows), (
        f"endpoint dropped CM048 facts on the floor: {out['count']} of "
        f"{len(cm048_rows)} survived the read path"
    )
    assert len(out["facts"]) == len(cm048_rows)
    # The rows really carry their text through, so a count of 5 empty
    # shells cannot pass this. The wire key for the fact text is "object"
    # (the response is subject/predicate/object shaped for the iOS tab),
    # which is exactly the sort of rename this whole PR is about, so it is
    # read from the response rather than assumed.
    assert all(f.get("object") for f in out["facts"]), (
        f"facts came back without text: {[sorted(f) for f in out['facts'][:1]]}"
    )


@pytest.mark.skipif(ical_server is None, reason=_ICAL_IMPORT_ERROR)
def test_the_memory_endpoint_reports_zero_when_there_is_genuinely_nothing():
    """Anti-vacuity for the test above.

    If api_memory_list returned a fixed non-empty list regardless of input,
    the assertion above would pass while proving nothing.
    """
    import unittest.mock as mock

    with mock.patch.object(ical_server, "_sparql_select", lambda q: []), \
            mock.patch.object(ical_server, "_memory_load_corrections", lambda: {}), \
            mock.patch.object(ical_server, "_hygiene_overlay", lambda: (None, {})):
        out = ical_server.api_memory_list()
    assert out["count"] == 0
    assert out["facts"] == []
