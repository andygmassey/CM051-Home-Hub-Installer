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
# Hang guard only. The latency claim is the RATIO (mutant P95 >= 3x fix P95),
# measured in one process, so it does not depend on the runner's speed.
HANG_CEILING_S = float(os.environ.get("OSTLER_HANG_CEILING_S", "2.0"))
# Secondary guard, per route. The structural guard below is the primary one.
# The card route is 2x, not 3x: the vendored CM051 person_enrichment resolves
# the slug with two full scans, which dominate its fix path (CB137-ENRICHMENT-
# SLUG-SCAN: 2.8x on the CM051 graft, 6.8x on CM041). Lift it when CB137 lands.
RATIO_MIN_BY_ROUTE = {"people/context": 3.0, "people/timeline": 3.0,
                      "people/enrichment": 2.0}
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


# --- the person card route: /api/v1/people/{slug}/enrichment (2026-11-19) ---
#
# Route bar: a route with three to four unscoped level reads costs about
# 0.15 s each at 11,500 persons, so its mutant sits near 0.5 s. The bar for
# the route cases is 0.25 s. Scoped: timeline 0.001 s; enrichment about 0.08 s,
# whose cost is one slug-resolution scan of every person.

ENRICH_SLUG = "fixture-person-35"


def _enrich(srv):
    return srv.person_enrichment(ENRICH_SLUG, destination=DEST)


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


# --- the latency claim: a ratio, measured in one process ------------------

def _p95(times):
    times = sorted(times)
    return times[max(0, int(round(0.95 * (len(times) - 1))))]


def _ratio_case(route, fix_call, monkeypatch, capsys, transport, n_fix=20, n_mut=10):
    RATIO_MIN = RATIO_MIN_BY_ROUTE[route]
    """Time the fix, then the same route with the scope dropped (the pre-fix
    call), in this process. The claim is mutant P95 >= RATIO_MIN x fix P95.
    The fix P95 must also sit under HANG_CEILING_S, which only guards a hang."""
    fix_times = []
    for _ in range(n_fix):
        t = time.perf_counter()
        out = fix_call()
        fix_times.append(time.perf_counter() - t)
        assert out is not None
    real = pp.sparql_effective_level
    monkeypatch.setattr(pp, "sparql_effective_level",
                        lambda subject_var="s", out_var="effLevel", subjects=None:
                        real(subject_var, out_var))
    mut_times = []
    for _ in range(n_mut):
        t = time.perf_counter()
        fix_call()
        mut_times.append(time.perf_counter() - t)
    monkeypatch.setattr(pp, "sparql_effective_level", real)
    fix_p95, mut_p95 = _p95(fix_times), _p95(mut_times)
    ratio = mut_p95 / fix_p95 if fix_p95 > 0 else float("inf")
    with capsys.disabled():
        print("\n[%s %s persons=%d] fix p50=%.4fs P95=%.4fs | mutant p50=%.4fs P95=%.4fs | RATIO mutant/fix P95=%.1fx (min %.1fx) | hang ceiling %.1fs"
              % (route, transport, SCALE, statistics.median(fix_times), fix_p95,
                 statistics.median(mut_times), mut_p95, ratio, RATIO_MIN, HANG_CEILING_S))
    assert fix_p95 < HANG_CEILING_S, "%s fix P95 %.3fs is over the hang ceiling" % (route, fix_p95)
    assert ratio >= RATIO_MIN, "%s: mutant/fix P95 ratio %.2fx is under %.1fx" % (route, ratio, RATIO_MIN)


def test_person_context_ratio(store_and_mod, monkeypatch, capsys):
    srv, transport = store_and_mod
    _ratio_case("people/context", lambda: srv.person_context("Fixture Person 1"),
                monkeypatch, capsys, transport)


def test_person_timeline_ratio(store_and_mod, monkeypatch, capsys):
    srv, transport = store_and_mod
    _ratio_case("people/timeline", lambda: srv.person_timeline_by_uri(
        TIMELINE_URI, destination=DEST), monkeypatch, capsys, transport)


def test_person_enrichment_ratio(store_and_mod, monkeypatch, capsys):
    srv, transport = store_and_mod
    _ratio_case("people/enrichment", lambda: _enrich(srv),
                monkeypatch, capsys, transport)


# --- fail closed for the timeline and the person card -----------------------
#
# The same three failure modes as person_context: the level read raises, times
# out, or returns nothing. The L3 text must be absent. Serve-on-error mutant:
# the real assertion must trip in every case.

TL_L3 = "SECRET-L3-MEETING-DO-NOT-SERVE"
TL_L1 = "fc-control-L1-meeting"
TL_URI = "urn:ostler:person/dana"
TL_SLUG = "dana"


def _route_fake(level_mode):
    """A store for the timeline and card routes. level_mode: normal, raise,
    timeout, empty. Meetings: one L3 meeting and one L1 control."""
    import socket

    meetings = [
        {"m": "urn:ostler:meeting/fc-l3", "summary": TL_L3, "date": "2026-10-01",
         "location": "", "lvl": "L3"},
        {"m": "urn:ostler:meeting/fc-l1", "summary": TL_L1, "date": "2026-10-02",
         "location": "", "lvl": "L1"},
    ]

    def fake(query):
        if "VALUES ?m {" in query:
            if level_mode == "raise":
                raise RuntimeError("oxigraph 500 on the level query")
            if level_mode == "timeout":
                raise socket.timeout("timed out")
            if level_mode == "empty":
                return []
            return [{"m": r["m"], "lvl": r["lvl"]} for r in meetings]
        if "VALUES ?person {" in query or "VALUES ?fact {" in query:
            return []
        if "SELECT ?name WHERE" in query:
            return [{"name": "Dana"}]
        if "pwg:Meeting" in query:
            return [{k: v for k, v in r.items() if k != "lvl"} for r in meetings]
        # the card's slug candidate query: plain in CM041, merge-aware in the
        # CM051 vendored tree ("SELECT DISTINCT ?person ?name ?node")
        if "?person ?name" in query and "displayName" in query:
            return [{"person": TL_URI, "name": "Dana", "node": TL_URI}]
        if "lastContactCalendar" in query:
            return [{}]
        return []

    return fake


def _route_run(srv, route, level_mode):
    from unittest.mock import patch
    fake = _route_fake(level_mode)
    with patch.object(srv, "_sparql_select", side_effect=fake):
        try:
            if route == "timeline":
                return srv.person_timeline_by_uri(TL_URI, destination="owner_own_brief")[0], None
            return srv.person_enrichment(TL_SLUG, destination="owner_own_brief")[0], None
        except Exception as exc:
            return None, exc


@pytest.mark.parametrize("route", ["timeline", "enrichment"])
@pytest.mark.parametrize("level_mode", ["normal", "raise", "timeout", "empty"])
def test_route_level_failure_withholds_the_l3_meeting(route, level_mode):
    srv = _srv()
    result, error = _route_run(srv, route, level_mode)
    out = json.dumps(result) if result is not None else ""
    assert TL_L3 not in out, "%s/%s served the L3 meeting" % (route, level_mode)
    if level_mode == "normal":
        assert TL_L1 in out, "control: the L1 meeting must be served on the normal path"


def test_route_mutant_serve_on_error_is_caught(monkeypatch):
    """Mutant: a failed or empty level read is served as L1. The fail-closed
    assertion must trip in every failure case on both routes."""
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
    for route in ("timeline", "enrichment"):
        for mode in ("raise", "timeout", "empty"):
            result, _ = _route_run(srv, route, mode)
            out = json.dumps(result) if result is not None else ""
            caught.append((route, mode, "caught" if TL_L3 in out else "NOT CAUGHT"))
    print("\n[MUTANT route serve-on-error] %s" % caught)
    assert all(v == "caught" for _, _, v in caught), caught


# --- PRIMARY guard: every effective-level subquery is scoped (structural) ---
#
# Deterministic and runner-speed independent. Capture every SPARQL string the
# three routes issue, and require each effective-level subquery to carry the
# VALUES scope. An unscoped subquery aggregates the whole store on every call,
# so this is the thing the latency claim rests on.

_LEVEL_MARK = "MAX(?_rk)"
_SCOPED_MARK = "MAX(?_bl) AS ?_anyb) WHERE { VALUES"


def _route_captures(srv):
    """{route: [every SPARQL string the route issued]}, against the fixture store."""
    calls = {
        "people/context": lambda: srv.person_context("Fixture Person 1"),
        "people/timeline": lambda: srv.person_timeline_by_uri(TIMELINE_URI, destination=DEST),
        "people/enrichment": lambda: _enrich(srv),
    }
    out = {}
    for route, call in calls.items():
        rec = []
        real = srv._sparql_select

        def wrap(q, *a, _rec=rec, _real=real, **k):
            _rec.append(q)
            return _real(q, *a, **k)

        srv._sparql_select = wrap
        try:
            call()
        finally:
            srv._sparql_select = real
        out[route] = rec
    return out


def _assert_scoped(captures):
    for route, qs in captures.items():
        levels = [q for q in qs if _LEVEL_MARK in q]
        assert levels, "%s issued no level subquery: the structural guard would be vacuous" % route
        bad = [q for q in levels if _SCOPED_MARK not in q]
        assert not bad, "%s issued %d unscoped level subquer%s (of %d)" % (
            route, len(bad), "y" if len(bad) == 1 else "ies", len(levels))


def test_structural_every_level_subquery_is_scoped(store_and_mod, capsys):
    srv, transport = store_and_mod
    caps = _route_captures(srv)
    with capsys.disabled():
        for route, qs in caps.items():
            levels = [q for q in qs if _LEVEL_MARK in q]
            print("\n[STRUCTURAL %s %s] level subqueries=%d scoped=%d"
                  % (route, transport, len(levels),
                     sum(_SCOPED_MARK in q for q in levels)))
    _assert_scoped(caps)


def test_structural_guard_fails_on_the_unscoped_mutant(store_and_mod, monkeypatch, capsys):
    """Mutant: the scope is dropped. The structural guard must fail on all three routes."""
    srv, transport = store_and_mod
    real = pp.sparql_effective_level
    monkeypatch.setattr(pp, "sparql_effective_level",
                        lambda subject_var="s", out_var="effLevel", subjects=None:
                        real(subject_var, out_var))
    caps = _route_captures(srv)
    red = {}
    for route in caps:
        try:
            _assert_scoped({route: caps[route]})
            red[route] = "NOT CAUGHT"
        except AssertionError as exc:
            red[route] = "caught: " + str(exc)
    with capsys.disabled():
        for route, verdict in red.items():
            print("\n[MUTANT STRUCTURAL %s %s] %s" % (route, transport, verdict))
    assert all(v.startswith("caught") for v in red.values()), red
