"""#659 repair: un-merging Person nodes that swallowed 2+ Contacts cards.

WHAT THESE TESTS ARE FOR, AND THE TRAP THEY ARE BUILT TO AVOID
==============================================================
The defect is that one Person node carries two DIFFERENT ``icloud_contact_uid``
values, so two real humans appear as one contact. Measured on a live v1.0.38
box on 2026-08-22 -- re-measured for this work, not inherited:

    over-merged person nodes        128
    Contacts cards swallowed        263   (135 people with no node of their own)
    worst single node                 5
    CONTROL: icloud_contact_uid identifiers in the graph  2259

A test for a repair like this fails in a specific way: the fixture does not
actually reproduce the defect, the repair trivially "fixes" nothing, and every
limb is green. So the FIRST limb here is an ANTI-VACUITY check that runs the
SHIPPING violation query -- the same predicate as the box-walk probe
``no_person_holds_two_contact_cards.sh`` -- against the fixture and FAILS if the
fixture is not a genuine RULE 2 violation. Every other limb depends on it.

THE STORE IS REAL, NOT A MOCK. The module's SPARQL strings are executed by
rdflib rather than pattern-matched by a stub, so a query that is malformed, or
that stops selecting the defect, fails these tests instead of passing them. A
mock of ``_select`` would happily return whatever the test author expected and
prove nothing about the SPARQL that ships.

PII: every name, email, phone and UID below is SYNTHETIC -- reserved .invalid /
.example domains and Ofcom drama-range numbers. No real person appears in this
file, and ``test_report_leaks_no_pii`` asserts the tool itself never prints the
fixture's names or UIDs.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib", reason="rdflib backs the in-memory graph")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))

from ostler_fda import repair_overmerged_contact_cards as mod  # noqa: E402

NS = mod.NS

# ── Synthetic fixture vocabulary (Rule 0: nothing real) ──────────────────────
PID_HOME = "aaaa11112222"      # the node that swallowed a card
PID_GUEST = "bbbb33334444"     # the card's real owner, now a tombstone
PID_GONE = "cccc55556666"      # an origin erased from the graph
PID_OTHER = "dddd77778888"     # an origin that already has a card of its own

P_HOME = f"{NS}person_{PID_HOME}"
P_GUEST = f"{NS}person_{PID_GUEST}"
P_OTHER = f"{NS}person_{PID_OTHER}"

UID_HOME = "AAAAAAAA-1111-4222-8333-444444444444"
UID_GUEST = "BBBBBBBB-5555-4666-8777-888888888888"
UID_GONE = "CCCCCCCC-9999-4000-8111-222222222222"
UID_OTHER = "DDDDDDDD-3333-4444-8555-666666666666"

NAME_HOME = "Wendy Testperson"
NAME_GUEST = "Rhodri Fixture"
PHONE_GUEST = "+447700900123"          # Ofcom drama range
EMAIL_GUEST = "rhodri@example.invalid"


class Store:
    """An in-memory graph that speaks the two calls the module makes."""

    def __init__(self) -> None:
        self.g = rdflib.Graph()
        self.updates = 0

    def select(self, sparql: str):
        raw = self.g.query(sparql).serialize(format="json")
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        return json.loads(raw)["results"]["bindings"]

    def update(self, sparql: str) -> None:
        self.updates += 1
        self.g.update(sparql)

    def load(self, turtle: str) -> None:
        self.g.parse(data=turtle, format="turtle")

    def __len__(self) -> int:
        return len(self.g)


def _turtle(body: str) -> str:
    return (
        f"@prefix p: <{NS}> .\n"
        "@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .\n"
        "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n"
    ) + body


def _identifier(uri: str, id_type: str, value: str) -> str:
    return (
        f"<{uri}> a p:PersonIdentifier ;\n"
        f'  p:identifierType "{id_type}" ;\n'
        f'  p:identifierValue "{value}" .\n'
    )


def base_fixture() -> Store:
    """The real shape: HOME swallowed GUEST's Contacts card.

    Mirrors the graph as measured, including the details that make the repair
    possible or impossible:
      * identifier URIs embed the person_id that minted them (the only
        provenance ``merge_persons`` leaves behind);
      * the tombstone keeps its own displayName/givenName but ZERO identifiers,
        because merge step 1 MOVED them;
      * the tombstone is NOT rdf:typed as a Person -- true of 1,033 of the
        1,046 tombstones on the box.
    """
    s = Store()
    s.load(_turtle(
        # The over-merged node: its own card plus the one it swallowed.
        f"<{P_HOME}> a p:Person ;\n"
        f'  p:displayName "{NAME_HOME}" ;\n'
        f"  p:hasIdentifier <{NS}id_{PID_HOME}_icloud> ,\n"
        f"                  <{NS}id_{PID_GUEST}_icloud> ,\n"
        f"                  <{NS}id_{PID_GUEST}_phone0> ,\n"
        f"                  <{NS}id_{PID_GUEST}_email0> .\n"
        + _identifier(f"{NS}id_{PID_HOME}_icloud", "icloud_contact_uid", UID_HOME)
        + _identifier(f"{NS}id_{PID_GUEST}_icloud", "icloud_contact_uid", UID_GUEST)
        + _identifier(f"{NS}id_{PID_GUEST}_phone0", "phone", PHONE_GUEST)
        + _identifier(f"{NS}id_{PID_GUEST}_email0", "email", EMAIL_GUEST)
        # The tombstone: attributes intact, identifiers gone, untyped.
        + f"<{P_GUEST}> p:displayName \"{NAME_GUEST}\" ;\n"
          f"  p:givenName \"Rhodri\" ;\n"
          f"  p:mergedInto <{P_HOME}> ;\n"
          f'  p:mergedAt "2026-08-01T00:00:00+00:00"^^xsd:dateTime .\n'
    ))
    return s


@pytest.fixture
def store(monkeypatch):
    s = base_fixture()
    monkeypatch.setattr(mod, "_select", s.select)
    monkeypatch.setattr(mod, "_update", s.update)
    return s


def violations(store: Store):
    return mod.find_overmerged_nodes()


# ── LIMB 0: ANTI-VACUITY ─────────────────────────────────────────────────────

def test_fixture_actually_reproduces_a_real_over_merge(store):
    """If this fails, EVERY other limb in this file is meaningless.

    It runs the shipping violation predicate -- the one the box-walk probe uses
    -- and demands the fixture trip it. A fixture that does not is not a test
    of the repair, it is a test of nothing.
    """
    control = mod.control_count()
    assert control > 0, (
        "VACUOUS FIXTURE: the control query found zero icloud_contact_uid "
        "identifiers, so a zero violation count would prove nothing."
    )

    found = violations(store)
    assert found == [P_HOME], (
        f"VACUOUS FIXTURE: the shipping violation query returned {found!r}, "
        f"expected exactly [{P_HOME!r}]. The fixture does not contain a real "
        "RULE 2 over-merge, so nothing below can be trusted."
    )

    # And it is the defect for the stated reason: two DIFFERENT canonical keys.
    uids = {
        r["v"]["value"]
        for r in store.select(
            f'PREFIX p: <{NS}> SELECT ?v WHERE {{ <{P_HOME}> p:hasIdentifier ?i . '
            f'?i p:identifierType "icloud_contact_uid" ; p:identifierValue ?v }}'
        )
    }
    assert uids == {UID_HOME, UID_GUEST}, uids


def test_a_clean_graph_is_not_flagged(monkeypatch):
    """The negative control: the predicate must not fire on a healthy graph."""
    s = Store()
    s.load(_turtle(
        f"<{P_HOME}> a p:Person ; p:hasIdentifier <{NS}id_{PID_HOME}_icloud> .\n"
        + _identifier(f"{NS}id_{PID_HOME}_icloud", "icloud_contact_uid", UID_HOME)
    ))
    monkeypatch.setattr(mod, "_select", s.select)
    monkeypatch.setattr(mod, "_update", s.update)
    assert mod.control_count() == 1
    assert mod.find_overmerged_nodes() == []


# ── LIMB 1: DRY RUN IS THE DEFAULT ───────────────────────────────────────────

def test_dry_run_is_the_default_and_writes_nothing(store, capsys):
    """Asserts the DEFECT is untouched, not that the log said 'dry run'."""
    before = len(store)
    rc = mod.main([])
    assert rc == 0
    assert store.updates == 0, "a dry run issued a SPARQL UPDATE"
    assert len(store) == before, "a dry run changed the triple count"
    # The defect must still be there afterwards.
    assert violations(store) == [P_HOME]


def test_apply_is_required_to_write(store):
    """There is no env var or config that can make the default destructive."""
    import os
    os.environ["OSTLER_REPAIR_APPLY"] = "1"       # must be ignored
    try:
        mod.main([])
        assert store.updates == 0
        assert violations(store) == [P_HOME]
    finally:
        del os.environ["OSTLER_REPAIR_APPLY"]


# ── LIMB 2: RED BEFORE / GREEN AFTER ─────────────────────────────────────────

def test_repair_removes_the_violation(store, tmp_path):
    movelog = tmp_path / "m.movelog.json"

    assert violations(store) == [P_HOME], "RED precondition missing"

    rc = mod.main(["--apply", "--movelog", str(movelog)])
    assert rc == 0

    assert violations(store) == [], "GREEN postcondition failed: still over-merged"

    # The guest's card, phone and email all went home together.
    guest_ids = {u for u, _t in mod.node_identifiers(P_GUEST)}
    assert guest_ids == {
        f"{NS}id_{PID_GUEST}_icloud",
        f"{NS}id_{PID_GUEST}_phone0",
        f"{NS}id_{PID_GUEST}_email0",
    }, guest_ids

    # The over-merged node keeps its OWN card and nothing else.
    home_ids = {u for u, _t in mod.node_identifiers(P_HOME)}
    assert home_ids == {f"{NS}id_{PID_HOME}_icloud"}, home_ids

    # The revived node is a real Person again, not a tombstone.
    assert not mod.is_tombstone(P_GUEST), "mergedInto marker was not lifted"
    typed = store.select(
        f"PREFIX p: <{NS}> SELECT (COUNT(*) AS ?n) WHERE {{ <{P_GUEST}> a p:Person }}"
    )
    assert int(typed[0]["n"]["value"]) == 1, "revived node was not re-typed as a Person"

    # Its own attributes survived untouched.
    assert mod.node_values(P_GUEST, "displayName") == [NAME_GUEST]


def test_no_person_node_is_ever_deleted(store, tmp_path):
    """The bar: a wrong un-merge must never destroy a real record."""
    mod.main(["--apply", "--movelog", str(tmp_path / "m.movelog.json")])
    for uri in (P_HOME, P_GUEST):
        assert mod.node_triple_count(uri) > 0, f"{uri} was destroyed"
        typed = store.select(
            f"PREFIX p: <{NS}> SELECT (COUNT(*) AS ?n) WHERE {{ <{uri}> a p:Person }}"
        )
        assert int(typed[0]["n"]["value"]) == 1, f"{uri} stopped being a Person"


# ── LIMB 3: REVERSIBILITY ────────────────────────────────────────────────────

def test_undo_restores_the_graph_exactly(store, tmp_path):
    movelog = tmp_path / "m.movelog.json"
    before = set(store.g)

    mod.main(["--apply", "--movelog", str(movelog)])
    assert violations(store) == []
    assert set(store.g) != before

    assert mod.main(["--undo", str(movelog)]) == 0

    after = set(store.g)
    assert after == before, (
        "undo did not restore the graph exactly; "
        f"{len(before - after)} triple(s) lost, {len(after - before)} added"
    )
    # And the defect is genuinely back -- proof the undo was real, not cosmetic.
    assert violations(store) == [P_HOME]


def test_movelog_is_written_before_any_mutation(store, tmp_path, monkeypatch):
    """A repair you cannot undo is not a repair. If the process dies on the
    first UPDATE, the log on disk must already describe the whole plan."""
    movelog = tmp_path / "m.movelog.json"
    seen = {}

    real_update = store.update

    def exploding_update(sparql):
        seen["movelog_existed"] = movelog.exists()
        raise RuntimeError("simulated interrupt on the first write")

    monkeypatch.setattr(mod, "_update", exploding_update)
    with pytest.raises(RuntimeError):
        mod.main(["--apply", "--movelog", str(movelog)])

    assert seen["movelog_existed"], "the first UPDATE ran before the move-log existed"
    payload = json.loads(movelog.read_text())
    assert payload["schema"] == mod.MOVELOG_SCHEMA
    assert payload["operations"], "move-log recorded no operations"
    monkeypatch.setattr(mod, "_update", real_update)


def test_undo_is_idempotent(store, tmp_path):
    """An interrupted undo can simply be run again."""
    movelog = tmp_path / "m.movelog.json"
    mod.main(["--apply", "--movelog", str(movelog)])
    mod.main(["--undo", str(movelog)])
    snapshot = set(store.g)
    mod.main(["--undo", str(movelog)])
    assert set(store.g) == snapshot


def test_undo_refuses_a_foreign_movelog(store, tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"schema": "something/else", "operations": []}))
    assert mod.main(["--undo", str(bad)]) == 2
    assert store.updates == 0


# ── LIMB 4: IDEMPOTENCE ──────────────────────────────────────────────────────

def test_repair_is_idempotent(store, tmp_path):
    mod.main(["--apply", "--movelog", str(tmp_path / "a.movelog.json")])
    snapshot = set(store.g)
    updates_after_first = store.updates

    rc = mod.main(["--apply", "--movelog", str(tmp_path / "b.movelog.json")])
    assert rc == 0
    assert set(store.g) == snapshot, "second run mutated an already-repaired graph"
    assert store.updates == updates_after_first, "second run issued writes"


# ── LIMB 5: CONSERVATISM -- when uncertain, leave it and report it ───────────

def _store_with(monkeypatch, turtle: str) -> Store:
    s = Store()
    s.load(_turtle(turtle))
    monkeypatch.setattr(mod, "_select", s.select)
    monkeypatch.setattr(mod, "_update", s.update)
    return s


def test_card_is_left_alone_when_its_origin_node_is_gone(monkeypatch, tmp_path):
    s = _store_with(monkeypatch,
        f"<{P_HOME}> a p:Person ; p:hasIdentifier <{NS}id_{PID_HOME}_icloud> , "
        f"<{NS}id_{PID_GONE}_icloud> .\n"
        + _identifier(f"{NS}id_{PID_HOME}_icloud", "icloud_contact_uid", UID_HOME)
        + _identifier(f"{NS}id_{PID_GONE}_icloud", "icloud_contact_uid", UID_GONE)
    )
    assert mod.find_overmerged_nodes() == [P_HOME]
    plan = mod.plan_node(P_HOME)
    assert not plan.splittable
    assert [b["reason"] for b in plan.blocked] == [mod.BLOCK_ORIGIN_ABSENT]

    before = set(s.g)
    mod.main(["--apply", "--movelog", str(tmp_path / "m.movelog.json")])
    assert set(s.g) == before, "a node with no provable origin was modified"


def test_node_is_left_alone_when_no_card_was_minted_on_it(monkeypatch, tmp_path):
    """Both cards are foreign: choosing which one keeps the node would be
    arbitrary, and an arbitrary un-merge is worse than the over-merge."""
    s = _store_with(monkeypatch,
        f"<{P_HOME}> a p:Person ; p:hasIdentifier <{NS}id_{PID_GUEST}_icloud> , "
        f"<{NS}id_{PID_OTHER}_icloud> .\n"
        + _identifier(f"{NS}id_{PID_GUEST}_icloud", "icloud_contact_uid", UID_GUEST)
        + _identifier(f"{NS}id_{PID_OTHER}_icloud", "icloud_contact_uid", UID_OTHER)
        + f"<{P_GUEST}> p:displayName \"{NAME_GUEST}\" ; p:mergedInto <{P_HOME}> .\n"
        + f"<{P_OTHER}> p:displayName \"Someone Else\" ; p:mergedInto <{P_HOME}> .\n"
    )
    assert mod.find_overmerged_nodes() == [P_HOME]
    plan = mod.plan_node(P_HOME)
    assert not plan.splittable
    assert {b["reason"] for b in plan.blocked} == {mod.BLOCK_NO_HOME}

    before = set(s.g)
    mod.main(["--apply", "--movelog", str(tmp_path / "m.movelog.json")])
    assert set(s.g) == before


def test_unattributable_identifier_uri_is_left_alone(monkeypatch, tmp_path):
    """An identifier URI with no embedded person_id carries no provenance."""
    weird = f"{NS}identifier-with-no-pid"
    s = _store_with(monkeypatch,
        f"<{P_HOME}> a p:Person ; p:hasIdentifier <{NS}id_{PID_HOME}_icloud> , "
        f"<{weird}> .\n"
        + _identifier(f"{NS}id_{PID_HOME}_icloud", "icloud_contact_uid", UID_HOME)
        + _identifier(weird, "icloud_contact_uid", UID_GUEST)
    )
    assert mod.find_overmerged_nodes() == [P_HOME]
    plan = mod.plan_node(P_HOME)
    assert not plan.splittable
    assert [b["reason"] for b in plan.blocked] == [mod.BLOCK_UNATTRIBUTABLE]

    before = set(s.g)
    mod.main(["--apply", "--movelog", str(tmp_path / "m.movelog.json")])
    assert set(s.g) == before


# ── LIMB 6: THE MUTANT -- prove a guard is load-bearing ──────────────────────

def _origin_already_has_card_store(monkeypatch) -> Store:
    return _store_with(monkeypatch,
        f"<{P_HOME}> a p:Person ; p:hasIdentifier <{NS}id_{PID_HOME}_icloud> , "
        f"<{NS}id_{PID_OTHER}_icloud> .\n"
        + _identifier(f"{NS}id_{PID_HOME}_icloud", "icloud_contact_uid", UID_HOME)
        + _identifier(f"{NS}id_{PID_OTHER}_icloud", "icloud_contact_uid", UID_OTHER)
        # The origin is alive and already holds a card of its own.
        + f"<{P_OTHER}> a p:Person ; p:displayName \"Someone Else\" ; "
          f"p:hasIdentifier <{NS}id_{PID_OTHER}_icloud_contact_uid_abc123> .\n"
        + _identifier(f"{NS}id_{PID_OTHER}_icloud_contact_uid_abc123",
                      "icloud_contact_uid", UID_GONE)
    )


def test_guard_stops_the_repair_creating_a_new_over_merge(monkeypatch, tmp_path):
    s = _origin_already_has_card_store(monkeypatch)
    assert mod.find_overmerged_nodes() == [P_HOME]

    plan = mod.plan_node(P_HOME)
    assert not plan.splittable
    assert [b["reason"] for b in plan.blocked] == [mod.BLOCK_ORIGIN_HAS_CARD]

    before = set(s.g)
    mod.main(["--apply", "--movelog", str(tmp_path / "m.movelog.json")])
    assert set(s.g) == before


def test_mutant_without_the_guard_would_move_the_over_merge(monkeypatch, tmp_path):
    """MUTANT: blind the guard and prove it was doing real work.

    With ``node_identifiers`` unable to see the origin's existing card, the
    planner believes the origin is clean and the repair proceeds -- and the
    result is a NEW RULE 2 violation on the origin node. That is the harm the
    guard prevents, demonstrated rather than asserted.
    """
    s = _origin_already_has_card_store(monkeypatch)
    real_node_identifiers = mod.node_identifiers

    def blinded(uri):
        if uri == P_OTHER:
            return []          # the mutation: pretend the origin holds nothing
        return real_node_identifiers(uri)

    monkeypatch.setattr(mod, "node_identifiers", blinded)

    plan = mod.plan_node(P_HOME)
    assert plan.splittable, "mutant did not reach the repair path"
    for op in mod.build_operations(plan):
        mod.apply_operation(op)

    monkeypatch.setattr(mod, "node_identifiers", real_node_identifiers)
    assert mod.find_overmerged_nodes() == [P_OTHER], (
        "the mutant did NOT produce a new over-merge, so "
        "test_guard_stops_the_repair_creating_a_new_over_merge proves nothing"
    )


# ── LIMB 7: ANTI-VACUITY GATE ON THE TOOL ITSELF ─────────────────────────────

def test_tool_refuses_to_run_against_an_empty_store(monkeypatch, capsys):
    """A zero from a broken predicate and a zero from a healthy graph print
    identically, so the tool must refuse rather than report a clean bill."""
    s = _store_with(monkeypatch, f"<{P_HOME}> a p:Person .\n")
    assert mod.control_count() == 0
    assert mod.main([]) == 2
    assert "REFUSING TO RUN" in capsys.readouterr().err


# ── LIMB 8: PII ──────────────────────────────────────────────────────────────

def test_report_leaks_no_pii(store, capsys):
    """The whole defect is that these nodes carry names of people who are not
    each other. The report must never print one."""
    mod.main([])
    out = capsys.readouterr().out
    for secret in (NAME_HOME, NAME_GUEST, UID_HOME, UID_GUEST,
                   PHONE_GUEST, EMAIL_GUEST, "Rhodri"):
        assert secret not in out, f"report leaked {secret!r}"
    # Control: it DID report something, so the assertion above is not vacuous.
    assert P_HOME in out, "report printed no node URIs at all"


def test_apply_output_leaks_no_pii(store, capsys, tmp_path):
    mod.main(["--apply", "--movelog", str(tmp_path / "m.movelog.json")])
    out = capsys.readouterr().out
    for secret in (NAME_HOME, NAME_GUEST, UID_HOME, UID_GUEST,
                   PHONE_GUEST, EMAIL_GUEST):
        assert secret not in out, f"apply output leaked {secret!r}"


# ── LIMB 9: the pid parser, which the whole repair stands on ─────────────────

@pytest.mark.parametrize("uri,expected", [
    (f"{NS}id_{PID_GUEST}_icloud", PID_GUEST),
    (f"{NS}id_{PID_GUEST}_phone0", PID_GUEST),
    (f"{NS}id_{PID_GUEST}_email12", PID_GUEST),
    (f"{NS}id_{PID_GUEST}_icloud_contact_uid_abc123", PID_GUEST),
    (f"{NS}id_a1b2c3d4-1111-4222-8333-444444444444_icloud",
     "a1b2c3d4-1111-4222-8333-444444444444"),
    (f"{NS}identifier-with-no-pid", None),
    ("https://example.invalid/id_x_icloud", None),
])
def test_identifier_pid_parsing(uri, expected):
    assert mod.identifier_pid(uri) == expected


def test_person_pid_parsing():
    assert mod.person_pid(P_GUEST) == PID_GUEST
    assert mod.person_pid(f"{NS}meeting_123") is None
    assert mod.person_pid("https://example.invalid/person_x") is None
