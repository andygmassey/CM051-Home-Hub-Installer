"""One person with two Contacts cards stays ONE Person node across syncs.

WHAT THE v1.0.120 WALK MEASURED (Mini16, read-only, shapes only). The
shipped birthdays endpoint listed one person 8 times, each under a different
person id. All 8 live nodes carried the same full name, the same birthday,
the same 3 emails and the same 2 mobiles. Between them they held TWO
``icloud_contact_uid`` values: one human, two Contacts cards. One node held
BOTH uids and had 5 merged-in nodes; the other 7 held one uid each. Their
``createdAt`` stamps were spread one or two per contact-resync tick
(the job runs every 30 minutes).

WHY. The converge path's ratified exception (``exact_identifier.py``: same
full name plus a shared email, mobile or LinkedIn may override a
card-uid-only RULE 2 refusal) correctly folds the two cards' nodes into one
node that holds both uids. The contact syncer's WRITE-side RULE 2 guard,
``_node_holds_a_different_canonical_key``, then asked only "does this node
hold ANY uid other than the incoming card's?". For that survivor the answer
is always yes (it holds the other card), even though it ALSO holds the
incoming card. So on every sync each card's match to its own node was
declined and a fresh node was minted, and the ingest-time collapse folded
some of them back: one human, a growing pile of Person nodes.

THE FIX. A node that already holds the incoming card's uid IS that card's
node: no conflict. Only a node holding a different uid and NOT the incoming
one is refused, which is the resolver's own rule (two present and DISJOINT
value sets). RULE 2 is not loosened: a node holding only a different card
still refuses, and the negative arms below prove it.

Real resolver, real syncer write path, a real SPARQL engine (pyoxigraph
behind the HTTP socket in ``_fake_oxigraph.py``). Both syncer twins are
driven: ``vendor/cm041/contact_syncer`` and the repo-root
``contact_syncer``. Synthetic data only (approved cast, example.com,
+44 7700 900xxx).
"""
from __future__ import annotations

import os
import sys
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
VENDOR = REPO / "vendor" / "cm041"
sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"

U1 = "SYNTHETIC-CARD-UID-0001"
U2 = "SYNTHETIC-CARD-UID-0002"
U3 = "SYNTHETIC-CARD-UID-0003"
NAME = "Jane Stewart"
EMAIL_A = "jane.stewart@example.com"
EMAIL_B = "jstewart@example.com"
MOBILE = "+447700900123"
BIRTHDAY = "1980-11-02"

SUBJECTS = {
    "vendored": (VENDOR / "contact_syncer" / "syncer.py", [VENDOR]),
    "repo-root": (REPO / "contact_syncer" / "syncer.py", [REPO, VENDOR]),
}


def _purge():
    for n in [n for n in sys.modules
              if n.split(".")[0] in ("contact_syncer", "identity_resolver")]:
        del sys.modules[n]


def _load(subject):
    path, order = SUBJECTS[subject]
    _purge()
    for entry in (str(REPO), str(VENDOR)):
        while entry in sys.path:
            sys.path.remove(entry)
    for entry in reversed(order):
        sys.path.insert(0, str(entry))
    import importlib
    mod = importlib.import_module("contact_syncer.syncer")
    # The two twins share a package name, so prove which one ran.
    assert os.path.realpath(mod.__file__) == os.path.realpath(path), (
        "imported %s, wanted %s" % (mod.__file__, path))
    return mod


@pytest.fixture(params=sorted(SUBJECTS))
def world(request, monkeypatch, tmp_path):
    store = FakeOxigraph()
    monkeypatch.setenv("OXIGRAPH_URL", store.url)
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "tomb.json"))
    mod = _load(request.param)
    from contact_syncer import config as cfg
    monkeypatch.setattr(cfg, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(cfg, "QDRANT_URL", "http://127.0.0.1:9")
    monkeypatch.setattr(cfg, "USER_ID", "")
    monkeypatch.setattr(cfg, "DEFAULT_PRIVACY_LEVEL", "L2")
    monkeypatch.setattr(cfg, "DEFAULT_COUNTRY_CODE", 44)
    w = types.SimpleNamespace(store=store, mod=mod, cfg=cfg, subject=request.param)
    yield w
    store.close()
    _purge()


def _node(w, short, uids, name=NAME, emails=(EMAIL_A, EMAIL_B), phones=(MOBILE,),
          birthday=BIRTHDAY):
    """A Person node in the shape contact_syncer writes, holding *uids*."""
    uri = f"{PWG}person_{short}"
    triples = [
        f'<{uri}> a pwg:Person',
        f'<{uri}> pwg:displayName "{name}"',
        f'<{uri}> pwg:contactType "person"',
        f'<{uri}> pwg:privacyLevel "L2"',
    ]
    if birthday:
        triples.append(f'<{uri}> pwg:birthday "{birthday}"^^xsd:date')
    ids = [("icloud_contact_uid", u) for u in uids]
    ids += [("email", e) for e in emails] + [("phone", p) for p in phones]
    for i, (t, v) in enumerate(ids):
        idn = f"{PWG}id_{short}_{i}"
        triples += [
            f"<{uri}> pwg:hasIdentifier <{idn}>",
            f"<{idn}> a pwg:PersonIdentifier",
            f'<{idn}> pwg:identifierType "{t}"',
            f'<{idn}> pwg:identifierValue "{v}"',
        ]
    w.store.update("INSERT DATA { " + " .\n".join(triples) + " . }")
    return uri


def _sync(w, uid, name=NAME, emails=(EMAIL_A, EMAIL_B), phones=(MOBILE,),
          birthday=BIRTHDAY):
    """One contact-resync of ONE card, through the real write path."""
    from identity_resolver.resolver import IdentityResolver
    s = w.mod.ContactSyncer.__new__(w.mod.ContactSyncer)
    s.cfg = w.cfg
    s.resolver = IdentityResolver(oxigraph_url=w.store.url, default_country_code=44)
    s._persist_photo = lambda *a, **k: None
    given, family = name.split(" ", 1)
    parsed = {
        "fn": name, "given_name": given, "family_name": family, "uid": uid,
        "phones": [{"value": p} for p in phones],
        "emails": [{"value": e} for e in emails],
        "org": "", "title": "", "notes": "", "birthday": birthday,
    }
    return s._resolve_and_write_person(parsed, "person")


def _live(w):
    """Live person nodes, i.e. not merged away."""
    with w.store.lock:
        rows = w.store.ds.query(
            "PREFIX pwg: <%s> SELECT DISTINCT ?p WHERE { ?p a pwg:Person . "
            "FILTER NOT EXISTS { ?p pwg:mergedInto ?t } }" % PWG)
        return sorted(r["p"].value for r in rows)


def _uids(w, uri):
    with w.store.lock:
        rows = w.store.ds.query(
            "PREFIX pwg: <%s> SELECT ?v WHERE { <%s> pwg:hasIdentifier ?i . "
            '?i pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue ?v }'
            % (PWG, uri))
        return sorted({r["v"].value for r in rows})


# ── GREEN arms: the walk's shapes converge to ONE node ─────────────────────

def test_survivor_holding_both_cards_is_not_reminted_across_three_syncs(world):
    """The ratified-exception survivor holds both uids. Three hourly syncs of
    both cards must leave ONE live node, the survivor. Before the fix each
    card minted a fresh node on every sync (the 8-node shape)."""
    keep = _node(world, "aaaaaaaaaaaa", [U1, U2])
    for _ in range(3):
        _sync(world, U1)
        _sync(world, U2)
    live = _live(world)
    assert live == [keep], (world.subject, "live nodes after 3 syncs", len(live))
    assert _uids(world, keep) == [U1, U2]


def test_three_nodes_for_one_person_converge_to_one(world):
    """The walk's 3-way shape: a both-cards survivor plus one node per card,
    all one human (same name, same emails, same mobile, same birthday).
    Syncing both cards folds the per-card nodes into the survivor."""
    _node(world, "aaaaaaaaaaaa", [U1, U2])
    _node(world, "bbbbbbbbbbbb", [U1])
    _node(world, "cccccccccccc", [U2])
    assert len(_live(world)) == 3
    _sync(world, U1)
    _sync(world, U2)
    live = _live(world)
    assert len(live) == 1, (world.subject, "live nodes", len(live), [(u[-12:], _uids(world, u)) for u in live])
    assert _uids(world, live[0]) == [U1, U2]


# ── NEGATIVE arms: RULE 2 is not loosened ──────────────────────────────────

def test_two_different_people_sharing_nothing_stay_two(world):
    _node(world, "aaaaaaaaaaaa", [U1])
    _sync(world, U2, name="Tom Jones", emails=("tom.jones@example.com",),
          phones=("+447700900456",), birthday="1975-03-04")
    assert len(_live(world)) == 2, world.subject


def test_a_different_card_on_a_shared_number_still_gets_its_own_node(world):
    """Household landline shape: the node holds ONLY a different card. The
    write-side RULE 2 guard must still refuse, exactly as before."""
    _node(world, "aaaaaaaaaaaa", [U1], emails=(EMAIL_A,), phones=(MOBILE,))
    _sync(world, U3, name="Tom Jones", emails=("tom.jones@example.com",),
          phones=(MOBILE,), birthday="")
    live = _live(world)
    assert len(live) == 2, world.subject
    assert all(len(_uids(world, u)) == 1 for u in live), "a node holds two cards"


def test_same_name_second_card_is_still_not_welded_at_ingest(world):
    """The ratified exception belongs to the converge path, not the sync
    write. A node holding ONLY card 1 and an incoming card 2 with the same
    name and email stays two nodes at sync time, as before this change."""
    _node(world, "aaaaaaaaaaaa", [U1])
    _sync(world, U2)
    live = _live(world)
    assert len(live) == 2, world.subject
    assert all(len(_uids(world, u)) == 1 for u in live), "a node holds two cards"


def test_control_the_guard_is_asked_and_sees_the_store(world):
    """Anti-vacuity: the guard reads the real store. A node with ONLY a
    different card is a conflict, a node holding the incoming card is not."""
    a = _node(world, "aaaaaaaaaaaa", [U1])
    b = _node(world, "bbbbbbbbbbbb", [U1, U2])
    s = world.mod.ContactSyncer.__new__(world.mod.ContactSyncer)
    s.cfg = world.cfg
    assert s._node_holds_a_different_canonical_key(a, U2) is True
    assert s._node_holds_a_different_canonical_key(a, U1) is False
    assert s._node_holds_a_different_canonical_key(b, U1) is False
    assert s._node_holds_a_different_canonical_key(b, U2) is False
    assert s._node_holds_a_different_canonical_key(b, U3) is True
