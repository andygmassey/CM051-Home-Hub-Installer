"""Property-based tests over the CM041 outbound privacy gates (Hypothesis).

Invariant (the stated one): no L3 or untagged FACT reaches an outbound
surface, and every L0/L1/L2 fact that should be served is served.

Doctrine exception, recorded not hidden: PERSON records with no privacy tag
are served by people_search (``_outbound_level_ok`` returns True for None).
That is a documented decision (133 rule, "untagged passes, as these readers
always did"), so the person property below encodes it and reports the
untagged count. Untagged FACTS are dropped (pwg_privacy fails closed), so the
fact property encodes the stricter stated invariant.

Spellings checked: privacy_level, privacyLevel, level (pwg_privacy
FACT_PRIVACY_KEYS) and privacy (the bare spelling, which the gate does not
read). Values: canonical, lowercase, padded, empty, garbage, numeric, None.

Mutants: each property is run once against a deliberately weakened gate and
MUST fail there. A property that passes on the mutant is not testing the gate.

Synthetic data only: reserved names, no real people.
"""

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"
if str(HERE.parent) not in sys.path:
    sys.path.insert(0, str(HERE.parent))

from hypothesis import HealthCheck, given, settings, strategies as st  # noqa: E402

import pwg_privacy  # noqa: E402


def _load_server():
    spec = importlib.util.spec_from_file_location("ical_server_prop", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server()

SPELLINGS = ("privacy_level", "privacyLevel", "level", "privacy")
VALUES = st.one_of(
    st.sampled_from(["L0", "L1", "L2", "L3"]),
    st.sampled_from(["l3", " L2 ", "l1", "L4", "", "bogus", "L3 ", "0"]),
    st.none(),
    st.integers(min_value=0, max_value=3),
)
FACT = st.fixed_dictionaries({"text": st.just("synthetic fact")}).flatmap(
    lambda base: st.dictionaries(st.sampled_from(SPELLINGS), VALUES, max_size=4).map(
        lambda extra: {**base, **extra}
    )
)
SETTINGS = settings(
    max_examples=400,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
    derandomize=True,
)


SINGLE_SPELLING_FACT = st.tuples(st.sampled_from(["privacy_level", "privacyLevel"]), VALUES).map(
    lambda kv: {"text": "synthetic fact", kv[0]: kv[1]}
)


def _expect_red(fn):
    """Run a property that must FAIL on a mutant. Hypothesis reports several
    distinct shrunk failures as an ExceptionGroup, so unwrap it. Returns the
    AssertionError messages (the shrunk counterexamples) and re-raises if the
    property held, which means the mutant was NOT caught."""
    try:
        fn()
    except BaseException as exc:  # noqa: BLE001
        leaves = exc.exceptions if isinstance(exc, BaseExceptionGroup) else [exc]
        msgs = [str(e) for e in leaves if isinstance(e, AssertionError)]
        if msgs:
            for m in msgs:
                print("MUTANT CAUGHT, shrunk counterexample:", m)
            return msgs
    raise AssertionError("mutant NOT caught: property held on the weakened gate")


def _parsed_levels(record):
    """Every parseable level under ANY spelling. The ground truth reads all."""
    out = []
    for key in SPELLINGS:
        if key in record:
            level = pwg_privacy.parse_privacy_level(record.get(key))
            if level is not None:
                out.append(level)
    return out


def _gate_serves_fact(fact, gate=None):
    """The real path a fact takes to leave: fail-closed filter, then outbound."""
    gate = gate or server._fact_outbound_ok
    return bool(server._filter_qdrant_facts([fact])) and gate(fact)


def _truth_must_serve(fact):
    # Serve only when every PRESENT spelling reads L1/L2. An unparseable
    # present value is UNREADABLE and withholds (CM041 #295: junk beside a
    # valid level may be a corrupted stricter label, so it fails closed).
    # Absent/blank spellings are not present and do not count.
    present = [fact.get(k) for k in pwg_privacy.FACT_PRIVACY_KEYS
               if k in fact and fact.get(k) is not None and str(fact.get(k)).strip() != ""]
    levels = [pwg_privacy.parse_privacy_level(v) for v in present]
    return bool(levels) and all(lvl in ("L1", "L2") for lvl in levels)


# ---------------------------------------------------------------------------
# Property 1: facts. No L3, no untagged, no unparseable fact is served; every
# fact whose every readable spelling is L1/L2 is served.
# ---------------------------------------------------------------------------

def _fact_property(gate, facts=None):
    @SETTINGS
    @given(facts or FACT)
    def prop(fact):
        served = _gate_serves_fact(fact, gate)
        levels = _parsed_levels(fact)
        if any(lvl in ("L0", "L3") for lvl in levels):
            assert not served, f"L0/L3 under some spelling was served: {fact!r}"
        if not levels:
            assert not served, f"untagged/unparseable fact was served: {fact!r}"
        if _truth_must_serve(fact):
            assert served, f"L1/L2 fact withheld (over-withholding): {fact!r}"
    return prop


def test_facts_no_l3_or_untagged_served_all_spellings():
    _fact_property(None)()


def test_facts_property_holds_on_the_canonical_spelling_only():
    """The same invariant restricted to one spelling per fact: the gate is right
    when there is no conflict. This is the control that proves the property
    itself can pass; the xfail above is about the multi-spelling conflict."""

    @SETTINGS
    @given(st.sampled_from(["L0", "L1", "L2", "L3", "garbage", None]), st.booleans())
    def prop(level, use_snake):
        key = "privacy_level" if use_snake else "privacyLevel"
        fact = {"text": "synthetic fact", key: level}
        served = _gate_serves_fact(fact)
        expected = pwg_privacy.parse_privacy_level(level) in ("L1", "L2")
        assert served == expected, f"{fact!r}: served={served} expected={expected}"

    prop()


def test_mutant_fact_gate_lets_l3_through_is_caught():
    """Mutant: the outbound gate serves every parseable level. Property 1 must fail."""
    mutant = lambda fact: any(  # noqa: E731
        pwg_privacy.parse_privacy_level(fact.get(k)) is not None
        for k in pwg_privacy.FACT_PRIVACY_KEYS
    )
    msgs = _expect_red(_fact_property(mutant))
    assert any("L0/L3" in m for m in msgs)


def test_control_outbound_gate_masks_disabled_filter():
    """Control, not a mutant: with ONLY is_l3 disabled, the outbound gate still
    withholds every L3/untagged fact on single-spelling data, so the property
    holds there. That is defence in depth, and it is why the mutant below must
    disable BOTH layers."""
    with patch.object(pwg_privacy, "is_l3", lambda record, owner_level=None: False):
        _fact_property(None, facts=SINGLE_SPELLING_FACT)()


def test_mutant_both_fact_layers_disabled_is_caught():
    """Mutant: filter AND outbound gate both admit everything. Property 1 must fail."""
    with patch.object(pwg_privacy, "is_l3", lambda record, owner_level=None: False):
        _expect_red(_fact_property(lambda fact: True, facts=SINGLE_SPELLING_FACT))


# ---------------------------------------------------------------------------
# Property 2: persons through people_search, Qdrant and embed mocked at the
# HTTP boundary. A person whose tag (any spelling) is L0, L3 or garbage is never
# served. An untagged person is served by doctrine and is COUNTED, not hidden.
# ---------------------------------------------------------------------------

class _Resp:
    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body


def _run_people_search(points):
    body = json.dumps({"result": [{"score": 0.9, "payload": p} for p in points]}).encode()
    with patch.object(server, "_embed_text", lambda q, timeout=30: [0.0]), \
         patch.object(server.urllib.request, "urlopen", lambda req, timeout=None: _Resp(body)):
        return server.people_search("synthetic", limit=50)


PERSON_TAG = st.dictionaries(st.sampled_from(SPELLINGS), VALUES, max_size=2)


def _person_payload(i, tags):
    return {"display_name": f"placeholder display {i}", "person_uri": f"urn:synthetic:person:{i}",
            "facts": [], **tags}


@SETTINGS
@given(st.lists(PERSON_TAG, min_size=1, max_size=6))
def test_persons_never_served_when_tagged_l0_l3_or_garbage(tag_sets):
    points = [_person_payload(i, t) for i, t in enumerate(tag_sets)]
    served_uris = {r["person_uri"] for r in _run_people_search(points)["results"]}
    for i, tags in enumerate(tag_sets):
        uri = f"urn:synthetic:person:{i}"
        # The shipped contract reads privacy_level only. Other spellings are
        # the separate xfail below (test_person_tagged_camel_case_l3_is_not_served).
        raw = tags.get("privacy_level")
        bad = raw is not None and str(raw).strip() != "" and (
            pwg_privacy.parse_privacy_level(raw) in ("L0", "L3") or pwg_privacy.parse_privacy_level(raw) is None
        )
        if bad:
            assert uri not in served_uris, f"person tagged {tags!r} was served"


def test_persons_untagged_is_counted_not_hidden():
    """Doctrine exception, asserted so it cannot drift silently: untagged persons
    are served by people_search (133 rule). If this ever changes, the stated
    invariant and this test must be revisited together."""
    out = _run_people_search([_person_payload(0, {}), _person_payload(1, {"privacy_level": "L2"})])
    uris = {r["person_uri"] for r in out["results"]}
    assert uris == {"urn:synthetic:person:0", "urn:synthetic:person:1"}


def test_person_tagged_camel_case_l3_is_not_served():
    out = _run_people_search([_person_payload(0, {"privacyLevel": "L3"})])
    assert out["results"] == []


def test_mutant_person_gate_serves_l3_is_caught():
    """Mutant: the person gate admits L3. The property must fail on it."""
    with patch.object(server, "_outbound_level_ok", lambda raw: True):
        _expect_red(test_persons_never_served_when_tagged_l0_l3_or_garbage)


# ---------------------------------------------------------------------------
# Property 3: the pure per-item verdict in pwg_privacy.provenance_verdict.
# "ok" (serve) is returned ONLY when no own or linked source is L3 or unreadable.
# ---------------------------------------------------------------------------

RAW = st.one_of(st.none(), st.sampled_from(["L0", "L1", "L2", "L3", "l3", " L1 ", "", "junk"]))


@SETTINGS
@given(RAW, st.lists(RAW, max_size=4))
def test_provenance_ok_only_when_nothing_l3_or_unreadable(own, sources):
    verdict = pwg_privacy.provenance_verdict(own, sources)
    all_levels = [own, *sources]
    classes = [pwg_privacy._classify(x) for x in all_levels]
    if verdict == "ok":
        assert "L3" not in classes and "UNREADABLE" not in classes, (own, sources, verdict)
    if "L3" in classes:
        # own is checked before sources (pwg_privacy.provenance_verdict order), so
        # an unreadable own level may report "unknown". Both withhold.
        assert verdict in ("l3", "unknown"), (own, sources, verdict)
    if verdict == "ok":
        assert pwg_privacy._classify(own) in ("L0", "L1", "L2") or any(
            pwg_privacy._classify(s) in ("L0", "L1", "L2") for s in sources)


def test_mutant_provenance_ignores_sources_is_caught():
    """Mutant: sources are ignored. An L1 item linked to an L3 source is then
    served as ok. The property must catch it."""
    real = pwg_privacy.provenance_verdict

    def mutant(own, sources=()):
        return real(own, ())

    with patch.object(pwg_privacy, "provenance_verdict", mutant):
        _expect_red(test_provenance_ok_only_when_nothing_l3_or_unreadable)
