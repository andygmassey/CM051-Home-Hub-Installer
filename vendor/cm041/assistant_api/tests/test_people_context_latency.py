"""people/context latency bar and the scoped privacy read (2026-11-19).

Synthetic data only: fixture names and example.com identifiers.

What this proves, and what it does not:
- The scoped level read (pwg_privacy.sparql_effective_level subjects=) returns
  the same rows as the unscoped read for the same subjects.
- person_context stays under a latency bar on a store of OSTLER_SCALE_PERSONS
  synthetic persons (default 11,500, the size of the owner's graph).
- A mutant that drops the scope (the pre-fix call) must miss the bar. This is
  the proof the bar can fail.

Transport. Default: the handler's _sparql_select is pointed at an in-process
pyoxigraph store. Server mode: set OXIGRAPH_TEST_URL to an Oxigraph SERVER
(the shipped transport, with its 30 s socket timeout) and the store is loaded
into it over HTTP before timing. The server run is the proof; the in-process
run is the CI scale fixture.
"""
import importlib.util
import json
import itertools
import os
import pathlib
import random
import statistics
import time
import urllib.request

import pytest

import pwg_privacy as pp

PWG = "https://schema.ostler.ai/ontology#"
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCALE = int(os.environ.get("OSTLER_SCALE_PERSONS", "11500"))
BAR_P95_S = float(os.environ.get("OSTLER_PEOPLE_CONTEXT_BAR_S", "0.5"))
ROUTE_BAR_S = float(os.environ.get("OSTLER_ROUTE_BAR_S", "0.25"))
SERVER = os.environ.get("OXIGRAPH_TEST_URL", "").rstrip("/")
OWNER = "urn:ostler:person:owner"


def _srv():
    path = ROOT / "assistant_api" / "ical-server.py"
    spec = importlib.util.spec_from_file_location("ical_server_latency", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _quads(n=SCALE, seed=7):
    """Synthetic graph as N-Quads text. Names are 'Fixture Person <i>'."""
    rnd = random.Random(seed)
    out = []
    T = "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>"
    def lit(s):
        return '"%s"' % s
    def p(n):
        return "<%s%s>" % (PWG, n)
    for i in range(n):
        s = "<urn:ostler:person:%d>" % i
        out.append("%s %s %s ." % (s, T, p("Person")))
        out.append("%s %s %s ." % (s, p("displayName"), lit("Fixture Person %d" % i)))
        if i % 4 == 0:
            out.append("%s %s %s ." % (s, p("organization"), lit("Example Org %d" % (i % 97))))
        if i % 3:
            out.append("%s %s %s ." % (s, p("privacyLevel"), lit("L2" if i % 2 else "L1")))
        for k in range(2):
            idn = "<urn:ostler:id:%d:%d>" % (i, k)
            out.append("%s %s %s ." % (s, p("hasIdentifier"), idn))
            out.append("%s %s %s ." % (idn, p("identifierType"), lit("email")))
            out.append("%s %s %s ." % (idn, p("identifierValue"),
                                       lit("fixture%d_%d@example.com" % (i, k))))
        for k in range(5):
            f = "<urn:ostler:fact:%d:%d>" % (i, k)
            out.append("%s %s %s ." % (f, T, p("PersonFact")))
            out.append("%s %s %s ." % (f, p("aboutPerson"), s))
            out.append("%s %s %s ." % (f, p("factText"), lit("fixture fact %d %d" % (i, k))))
            if k % 2 == 0:
                out.append("%s %s %s ." % (f, p("privacyLevel"), lit("L1")))
        if i % 5 == 0:
            m = "<urn:ostler:meeting:%d>" % i
            out.append("%s %s %s ." % (m, T, p("Meeting")))
            out.append("%s %s %s ." % (m, p("meetingAttendee"), s))
            out.append("%s %s %s ." % (m, p("meetingSummary"), lit("fixture meeting %d" % i)))
            out.append("%s %s %s ." % (m, p("meetingDate"), lit("2026-10-%02dT09:00:00Z" % (1 + i % 28))))
            out.append("%s %s %s ." % (m, p("privacyLevel"), lit("L1")))
        if i % 12 == 0:
            r = "<urn:ostler:person:retired:%d>" % i
            out.append("%s %s %s ." % (r, T, p("RetiredPerson")))
            out.append("%s %s %s ." % (r, p("displayName"), lit("Fixture Person %d alt" % i)))
            out.append("%s %s %s ." % (r, p("mergedInto"), s))
    # the synthetic owner, with career facts
    out.append("<%s> %s %s ." % (OWNER, T, p("Person")))
    out.append("<%s> %s %s ." % (OWNER, p("displayName"), lit("Fixture Owner")))
    for k in range(6):
        f = "<urn:ostler:career:%d>" % k
        out.append("%s %s %s ." % (f, T, p("PersonFact")))
        out.append("%s %s <%s> ." % (f, p("aboutPerson"), OWNER))
        out.append("%s %s %s ." % (f, p("factType"), lit("career_position")))
        out.append("%s %s %s ." % (f, p("organization"), lit("Org %d" % k)))
        out.append("%s %s %s ." % (f, p("factText"), lit("career %d" % k)))
        out.append("%s %s %s ." % (f, p("privacyLevel"), lit("L2")))
    # CM048 conversation facts (the timeline's conversation source)
    for i in range(0, n, 7):
        fct = "<urn:ostler:tfact:%d>" % i
        conv = "<urn:ostler:conversation/c%d>" % i
        out.append("%s <urn:ostler:about> <urn:ostler:person:%d> ." % (fct, i))
        out.append("%s <urn:ostler:fromConversation> %s ." % (fct, conv))
        out.append("%s <urn:ostler:privacyLevel> %s ." % (fct, lit("L1" if i % 2 else "L2")))
        out.append("%s <urn:ostler:date> %s ." % (conv, lit("2026-10-%02d" % (1 + i % 28))))
    # CM048 signals in a user named graph (the signal read is graph-scoped)
    for k in range(5):
        out.append("<urn:ostler:signal:%d> <urn:ostler:about> <urn:ostler:person:%d> <urn:ostler:user:fixture> ."
                   % (k, k * 7))
        out.append("<urn:ostler:signal:%d> <urn:ostler:warmth> %s <urn:ostler:user:fixture> ." % (k, lit("0.5")))
        out.append("<urn:ostler:signal:%d> <urn:ostler:trust> %s <urn:ostler:user:fixture> ." % (k, lit("0.5")))
        out.append("<urn:ostler:signal:%d> <urn:ostler:observedAt> %s <urn:ostler:user:fixture> ."
                   % (k, lit("2026-10-01")))
        out.append("<urn:ostler:signal:%d> <urn:ostler:privacyLevel> %s <urn:ostler:user:fixture> ."
                   % (k, lit("L1")))
    rnd.shuffle(out)
    return "\n".join(out) + "\n"


@pytest.fixture(scope="module")
def store_and_mod():
    """(query_fn, srv_mod). query_fn(sparql) -> list of {var: str} rows."""
    srv = _srv()
    nq = _quads()
    if SERVER:
        req = urllib.request.Request(
            SERVER + "/store", data=nq.encode("utf-8"), method="POST",
            headers={"Content-Type": "application/n-quads"})
        urllib.request.urlopen(req, timeout=600).read()
        srv.OXIGRAPH_URL = SERVER
        srv.USER_URI = None
        return srv, "server"
    import pyoxigraph as ox
    store = ox.Store()
    store.load(nq.encode("utf-8"), ox.RdfFormat.N_QUADS)

    def _select(q):
        # unbound OPTIONAL vars are omitted, as the HTTP JSON results omit them
        res = store.query(q)
        names = [v.value for v in res.variables]
        return [{n: sol[n].value for n in names if sol[n] is not None}
                for sol in res]
    srv._sparql_select = _select
    srv.USER_URI = None
    return srv, "in-process"


def _unscoped_rows(store, subjects, var):
    q = ("SELECT ?%s ?effLevel WHERE { " % var
         + pp.sparql_effective_level(var, "effLevel") + " }")
    return {str(r[var].value): str(r["effLevel"].value) for r in store.query(q)
            if str(r[var].value) in subjects}


def test_scoped_level_read_matches_unscoped_rows():
    """Same rows for the same subjects, with and without the scope."""
    import pyoxigraph as ox
    store = ox.Store()
    store.load(_quads(n=600).encode("utf-8"), ox.RdfFormat.N_QUADS)
    subjects = ["urn:ostler:person:%d" % i for i in (0, 1, 2, 3, 4, 5, 9999)]
    iris = ["<%s>" % s for s in subjects]
    full = _unscoped_rows(store, set(subjects), "person")
    q = ("SELECT ?person ?effLevel WHERE { VALUES ?person { " + " ".join(iris) + " } "
         + "OPTIONAL { " + pp.sparql_effective_level("person", "effLevel", subjects=subjects)
         + " } }")
    scoped = {str(r["person"].value): (str(r["effLevel"].value) if r["effLevel"] is not None else None)
              for r in store.query(q)}
    for s in subjects:
        assert scoped.get(s) == full.get(s), s
    assert full, "control: the unscoped read must find some levels"


def test_scoped_fragment_is_the_default_when_unscoped():
    assert "VALUES" not in pp.sparql_effective_level("s", "e")
    assert "VALUES ?s" in pp.sparql_effective_level("s", "e", subjects=["https://example.org/a"])


def test_scoped_fragment_rejects_an_unsafe_iri():
    with pytest.raises(ValueError):
        pp.sparql_effective_level("s", "e", subjects=["https://example.org/a> } DROP"])


def _time_person_context(srv, name, n):
    times = []
    for _ in range(n):
        t = time.perf_counter()
        out = srv.person_context(name)
        times.append(time.perf_counter() - t)
        assert out.get("found") is True, out.get("message") or out
    times.sort()
    p50 = statistics.median(times)
    p95 = times[max(0, int(round(0.95 * (len(times) - 1))))]
    return p50, p95, times


def test_person_context_latency_bar(store_and_mod, capsys):
    srv, transport = store_and_mod
    # 'Fixture Person 1' matches 'Fixture Person 1', '1x', '1xx' and so on: several rows.
    p50, p95, times = _time_person_context(srv, "Fixture Person 1", 20)
    with capsys.disabled():
        print("\n[people/context %s n=%d persons=%d] p50=%.3fs P95=%.3fs bar=%.2fs"
              % (transport, len(times), SCALE, p50, p95, BAR_P95_S))
    assert p95 < BAR_P95_S, "P95 %.3fs over the %.2fs bar" % (p95, BAR_P95_S)


def test_mutant_unscoped_call_misses_the_bar(store_and_mod, monkeypatch, capsys):
    """The mutant restores the pre-fix call: the subject scope is dropped."""
    srv, transport = store_and_mod
    real = pp.sparql_effective_level

    def unscoped(subject_var="s", out_var="effLevel", subjects=None):
        return real(subject_var, out_var)

    monkeypatch.setattr(pp, "sparql_effective_level", unscoped)
    p50, p95, times = _time_person_context(srv, "Fixture Person 1", 10)
    with capsys.disabled():
        print("\n[MUTANT unscoped %s n=%d persons=%d] p50=%.3fs P95=%.3fs bar=%.2fs"
              % (transport, len(times), SCALE, p50, p95, BAR_P95_S))
    assert p95 > BAR_P95_S, (
        "mutant did NOT miss the bar (P95 %.3fs): the latency bar cannot detect the regression"
        % p95)


# --- fail closed when the level read fails (Archie, #308 review) ----------
#
# The level read is a second query. If it raises, times out, or returns
# nothing for a subject, the fact must be WITHHELD, never served as untagged.
# The L3 text must be absent from every output in all three cases.

L3_TEXT = "SECRET-L3-TEXT-DO-NOT-SERVE"
PERSON_L2 = {"person": "urn:ostler:person/fc-dana", "name": "Dana L2", "priv": "L2"}
FC_FACTS = [{"f": "urn:ostler:fact/fc-l3", "text": L3_TEXT},
            {"f": "urn:ostler:fact/fc-l1", "text": "fc-explicit-L1"}]


def _fc_fake(level_behaviour):
    """A fake store. level_behaviour: 'L3' (normal), 'raise', 'timeout', 'empty'."""
    import socket

    def fake(query):
        if "VALUES ?person" in query:
            return [{"person": PERSON_L2["person"], "lvl": "L2"}]
        if "VALUES ?f" in query:
            if level_behaviour == "raise":
                raise RuntimeError("oxigraph 500 on the level query")
            if level_behaviour == "timeout":
                raise socket.timeout("timed out")
            if level_behaviour == "empty":
                return []
            return [{"f": "urn:ostler:fact/fc-l3", "lvl": "L3"},
                    {"f": "urn:ostler:fact/fc-l1", "lvl": "L1"}]
        if "pwg:Person" in query and "displayName" in query:
            return [dict(PERSON_L2, name="Dana L2")]
        if "PersonFact" in query:
            return [dict(r) for r in FC_FACTS]
        return []
    return fake


def _fc_run(srv, level_behaviour):
    """(result, error). result is person_context's dict, or None if it raised."""
    from unittest.mock import patch
    with patch.object(srv, "_sparql_select", side_effect=_fc_fake(level_behaviour)), \
         patch.object(srv, "_timeline_conversations", return_value=([], None)):
        try:
            return srv.person_context("Dana L2", destination="owner_own_brief"), None
        except Exception as exc:  # the route turns this into a degraded answer
            return None, exc


def _fc_assert_withheld(result, error):
    out = json.dumps(result) if result is not None else ""
    assert L3_TEXT not in out, "L3 fact text was served"
    if result is not None:
        assert result.get("found") is not True or L3_TEXT not in out


@pytest.mark.parametrize("behaviour", ["L3", "raise", "timeout", "empty"])
def test_level_failure_withholds_the_l3_fact(behaviour, capsys):
    srv = _srv()
    result, error = _fc_run(srv, behaviour)
    _fc_assert_withheld(result, error)
    if behaviour == "L3":
        # control: the normal path serves the L1 fact and still withholds L3
        assert "fc-explicit-L1" in json.dumps(result)
        assert result["person"].get("facts") == ["fc-explicit-L1"]
    with capsys.disabled():
        print("\n[fail-closed %-7s] L3 text absent=%s error=%s"
              % (behaviour, L3_TEXT not in json.dumps(result or {}), type(error).__name__ if error else None))


def test_mutant_serve_on_error_is_caught(monkeypatch, capsys):
    """Mutant: a failed or empty level read is served as L1. The REAL
    fail-closed assertion must trip on every case (AssertionError)."""
    srv = _srv()
    real = srv._levels_for

    def serve_on_error(subject_var, uris):
        try:
            got = real(subject_var, uris)
        except Exception:
            got = {}
        for u in uris:
            got.setdefault(u, "L1")
        return got

    monkeypatch.setattr(srv, "_levels_for", serve_on_error)
    caught = []
    for behaviour in ("raise", "timeout", "empty"):
        result, error = _fc_run(srv, behaviour)
        try:
            _fc_assert_withheld(result, error)
            caught.append((behaviour, "NOT CAUGHT"))
        except AssertionError:
            caught.append((behaviour, "caught"))
    with capsys.disabled():
        print("\n[MUTANT serve-on-error] %s" % caught)
    assert all(v == "caught" for _, v in caught), caught


# --- the person timeline route (2026-11-19) -------------------------------

DEST = "owner_own_brief"   # undeclared = unknown withholds L1/L2 (strictest)
TIMELINE_URI = "urn:ostler:person:35"   # has meetings, conversation facts, a level


def _time_route(fn, n):
    times, last = [], None
    for _ in range(n):
        t = time.perf_counter()
        last = fn()
        times.append(time.perf_counter() - t)
    times.sort()
    p50 = statistics.median(times)
    p95 = times[max(0, int(round(0.95 * (len(times) - 1))))]
    return p50, p95, last


def test_person_timeline_latency_bar(store_and_mod, capsys):
    srv, transport = store_and_mod
    p50, p95, (body, status) = _time_route(
        lambda: srv.person_timeline_by_uri(TIMELINE_URI, destination=DEST), 20)
    assert status == 200, body
    with capsys.disabled():
        print("\n[people/timeline %s n=20 persons=%d] p50=%.3fs P95=%.3fs bar=%.2fs events=%d"
              % (transport, SCALE, p50, p95, BAR_P95_S, len(body.get("events", []))))
    assert p95 < ROUTE_BAR_S, "timeline P95 %.3fs over the %.2fs bar" % (p95, ROUTE_BAR_S)


def test_person_timeline_scoped_equals_unscoped(store_and_mod, monkeypatch):
    """The scope changes cost, not the answer: the events are identical with
    the scope dropped (the pre-fix call)."""
    srv, _ = store_and_mod
    scoped, st1 = srv.person_timeline_by_uri(TIMELINE_URI, destination=DEST)
    real = pp.sparql_effective_level
    monkeypatch.setattr(pp, "sparql_effective_level",
                        lambda subject_var="s", out_var="effLevel", subjects=None:
                        real(subject_var, out_var))
    unscoped, st2 = srv.person_timeline_by_uri(TIMELINE_URI, destination=DEST)
    assert st1 == st2 == 200
    key = lambda body: json.dumps(body.get("events", []), sort_keys=True)  # noqa: E731
    assert scoped.get("events"), "control: the timeline must have events"
    assert key(scoped) == key(unscoped)


def test_person_timeline_mutant_misses_the_bar(store_and_mod, monkeypatch, capsys):
    srv, transport = store_and_mod
    real = pp.sparql_effective_level
    monkeypatch.setattr(pp, "sparql_effective_level",
                        lambda subject_var="s", out_var="effLevel", subjects=None:
                        real(subject_var, out_var))
    p50, p95, _ = _time_route(lambda: srv.person_timeline_by_uri(TIMELINE_URI, destination=DEST), 10)
    with capsys.disabled():
        print("\n[MUTANT timeline unscoped %s n=10 persons=%d] p50=%.3fs P95=%.3fs bar=%.2fs"
              % (transport, SCALE, p50, p95, ROUTE_BAR_S))
    assert p95 > ROUTE_BAR_S, "timeline mutant did NOT miss the bar (P95 %.3fs)" % p95


# --- the person card route: /api/v1/people/{slug}/enrichment (2026-11-19) ---
#
# Route bar: a route with three to four unscoped level reads costs about
# 0.15 s each at 11,500 persons, so its mutant sits near 0.5 s. The bar for
# the route cases is 0.25 s. Scoped: timeline 0.001 s; enrichment about 0.08 s,
# whose cost is one slug-resolution scan of every person.

ENRICH_SLUG = "fixture-person-35"


def _enrich(srv):
    return srv.person_enrichment(ENRICH_SLUG, destination=DEST)


def test_person_enrichment_latency_bar(store_and_mod, capsys):
    srv, transport = store_and_mod
    p50, p95, (body, status) = _time_route(lambda: _enrich(srv), 20)
    assert status == 200, body
    with capsys.disabled():
        print("\n[people/enrichment %s n=20 persons=%d] p50=%.3fs P95=%.3fs bar=%.2fs"
              % (transport, SCALE, p50, p95, ROUTE_BAR_S))
    assert p95 < ROUTE_BAR_S, "enrichment P95 %.3fs over the %.2fs bar" % (p95, ROUTE_BAR_S)


def test_person_enrichment_scoped_equals_unscoped(store_and_mod, monkeypatch):
    srv, _ = store_and_mod
    scoped, st1 = _enrich(srv)
    real = pp.sparql_effective_level
    monkeypatch.setattr(pp, "sparql_effective_level",
                        lambda subject_var="s", out_var="effLevel", subjects=None:
                        real(subject_var, out_var))
    unscoped, st2 = _enrich(srv)
    assert st1 == st2 == 200
    assert scoped.get("person"), "control: the card must resolve"
    assert json.dumps(scoped, sort_keys=True) == json.dumps(unscoped, sort_keys=True)


def test_person_enrichment_mutant_misses_the_bar(store_and_mod, monkeypatch, capsys):
    srv, transport = store_and_mod
    real = pp.sparql_effective_level
    monkeypatch.setattr(pp, "sparql_effective_level",
                        lambda subject_var="s", out_var="effLevel", subjects=None:
                        real(subject_var, out_var))
    p50, p95, _ = _time_route(lambda: _enrich(srv), 10)
    with capsys.disabled():
        print("\n[MUTANT enrichment unscoped %s n=10 persons=%d] p50=%.3fs P95=%.3fs bar=%.2fs"
              % (transport, SCALE, p50, p95, ROUTE_BAR_S))
    assert p95 > ROUTE_BAR_S, "enrichment mutant did NOT miss the bar (P95 %.3fs)" % p95
