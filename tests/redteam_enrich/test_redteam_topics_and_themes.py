"""Red-team: Wikidata topic-label gate (shared topic nodes, IRI shapes) and thematic admission."""
import asyncio
from unittest import mock

import pytest
from conftest import STAMP, Sink, Recorder, _init
from src.enricher import EnrichmentService
from src.derive.thematic import privacy_of, leaf_is_sensitive
from src.derive.readers import _not_minor

L1 = {"privacy_level": "L1", **STAMP}


def _bindings(rows):
    return {"results": {"bindings": [
        {"topic": {"value": "urn:topic:x"}, "label": {"value": lab}, "pref": {"value": pref}}
        for lab, pref in rows]}}


class _Resp:
    def __init__(self, body):
        self.status_code = 200
        self.text = ""
        self._b = body

    def json(self):
        return self._b


class _FakeClient:
    def __init__(self, body):
        self._body = body

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def post(self, *a, **k):
        return _Resp(self._body)


def _svc(sink, owner_refusals):
    from contextlib import ExitStack
    st = ExitStack()
    rec = Recorder(sink)
    st.enter_context(mock.patch.object(EnrichmentService, "__init__", lambda self: _init(self, rec)))
    svc = EnrichmentService()
    svc._topic_owner_refusals = mock.AsyncMock(side_effect=lambda client, ids: owner_refusals)
    return svc, st


async def _normalize(rows, owner_refusals):
    sink = Sink()
    svc, st = _svc(sink, owner_refusals)
    with st, mock.patch("src.enricher.public_lookup_allowed", lambda: True), \
         mock.patch("src.enricher.httpx.AsyncClient", lambda **k: _FakeClient(_bindings(rows))):
        await svc.normalize_topics_with_wikidata()
    return sink.strings()


# Positive control: an L1 pref's topic is normalised.
@pytest.mark.asyncio
async def test_T01_L1_only_topic_is_normalised_control():
    out = await _normalize([("control-topic T01", "urn:ostler:preference:music-1")],
                           {"music-1": None})
    assert "control-topic T01" in out, f"L1-only topic not normalised; sent={out}"


# Shared topic node: an L3 health pref and an L1 music pref point at the same label.
@pytest.mark.asyncio
async def test_T02_health_pref_sharing_topic_with_L1_pref_is_not_sent():
    out = await _normalize(
        [("metformin-doe T02", "urn:ostler:preference:health-1"),
         ("metformin-doe T02", "urn:ostler:preference:music-1")],
        {"health-1": "level_L3", "music-1": None})
    assert "metformin-doe T02" not in out, \
        f"L3 health pref's topic label sent because an L1 sibling shares it; sent={out}"


# Pref IRI outside the urn:ostler:preference: namespace is invisible to the owner check.
@pytest.mark.asyncio
async def test_T03_health_pref_with_other_iri_shape_is_not_sent():
    out = await _normalize(
        [("metformin-doe T03", "https://example.invalid/pref/health-3"),
         ("metformin-doe T03", "urn:ostler:preference:music-1")],
        {"health-3": "level_L3", "music-1": None})
    assert "metformin-doe T03" not in out, \
        f"L3 pref with non-urn IRI is not checked; its label was sent; sent={out}"


# Only L3 owners: must be withheld (control for the owner check itself).
@pytest.mark.asyncio
async def test_T04_only_L3_owner_is_withheld_control():
    out = await _normalize([("only-private T04", "urn:ostler:preference:health-4")],
                           {"health-4": "level_L3"})
    assert "only-private T04" not in out, f"L3-only topic was sent; sent={out}"


# Unreadable store: nothing sent (fail-closed control).
@pytest.mark.asyncio
async def test_T05_unreadable_privacy_store_sends_nothing_control():
    out = await _normalize([("Unreadable T05", "urn:ostler:preference:music-5")], None)
    assert "Unreadable T05" not in out, f"sent with privacy store unreadable; sent={out}"


# ---------------- thematic admission ----------------
def test_M01_legacy_1_beside_canonical_L1_is_refused_for_themes():
    lvl = privacy_of({"privacy_level": "L1", "privacyScale": "canonical-2026-11",
                      "compartment_level": 1})
    assert lvl is None, f"legacy 1 (finance/family per base.py) beside L1 feeds a theme; got {lvl!r}"


def test_M02_legacy_1_as_string_beside_canonical_L1_is_refused_for_themes():
    lvl = privacy_of({"privacy_level": "L1", "privacyScale": "canonical-2026-11",
                      "compartment_level": " 1"})
    assert lvl is None, f"padded legacy 1 feeds a theme; got {lvl!r}"


def test_M03_unlevelled_refused_control():
    assert privacy_of({"extra": {}}) is None


def test_M04_L3_refused_control():
    assert privacy_of({"privacy_level": "L3", **STAMP}) is None


def test_M05_stamped_L1_admitted_control():
    assert privacy_of({"privacy_level": "L1", **STAMP}) == "L1"


def test_M06_lowercase_stamped_L1_admitted_control():
    assert privacy_of({"privacy_level": " l1 ", **STAMP}) == "L1"


def test_M07_unstamped_L0_refused_control():
    assert privacy_of({"privacy_level": "L0"}) is None


def test_M08_extra_about_minor_yes_string_is_dropped():
    pts = [{"id": 1, "payload": {"category": "book", "extra": {"about_minor": "yes"}, **L1}}]
    assert list(_not_minor(pts)) == [], f"about_minor='yes' kept in theme admission"


def test_M09_extra_about_minor_upper_TRUE_is_dropped():
    pts = [{"id": 1, "payload": {"category": "book", "extra": {"about_minor": "TRUE"}, **L1}}]
    assert list(_not_minor(pts)) == [], f"about_minor='TRUE' kept in theme admission"


def test_M10_extra_about_minor_int_2_is_dropped():
    pts = [{"id": 1, "payload": {"category": "book", "extra": {"about_minor": 2}, **L1}}]
    assert list(_not_minor(pts)) == [], f"about_minor=2 kept in theme admission"


def test_M11_dietary_category_dropped_control():
    pts = [{"id": 1, "payload": {"category": "dietary", **L1}}]
    assert list(_not_minor(pts)) == []


def test_M12_health_topic_under_interest_with_no_vocab_hit_is_not_admitted():
    # A health subject outside the sensitive vocabulary, under an admitted theme
    # category, stamped L1. Health must not feed a theme.
    admitted = [p for p in _not_minor([{"id": 1, "payload": {
        "category": "interest", "subject": "metformin-doe M12", **L1}}])]
    lvl = privacy_of(admitted[0]["payload"]) if admitted else None
    assert lvl is None, f"health topic (no vocab hit) admitted to themes; leaf_sensitive={leaf_is_sensitive('metformin-doe M12')}"


def test_M13_health_vocab_leaf_is_sensitive_control():
    assert leaf_is_sensitive("diabetes") is True
