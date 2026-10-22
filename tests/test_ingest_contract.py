#!/usr/bin/env python3
"""The INGEST CONTRACT, enforced. See tests/ingest_contract_registry.py.

Four kinds of check, so a new importer cannot ship without declaring what it
keeps, and a declared field cannot be quietly dropped:

  1. COMPLETENESS   every vendored parser module is in REGISTRY, and every
                    REGISTRY name is a real module (no stale row).
  2. DECLARATION    every entry carries all six fields; a Gap states a reason.
  3. FIXTURE RUN    for each parser with a synthetic fixture, parse it and
                    assert the declared fields on every emitted preference.
  4. RATCHET        the number of declared Gaps equals GAP_BASELINE. Adding a
                    gap needs editing the number in review; fixing one needs
                    lowering it. A gap a fixture proves CLOSED is a failure
                    until it is removed.

The two non-parser writers of the `preferences` collection (Safari bookmarks
and iMessage social in vendor/ostler_fda/pwg_ingest.py) are driven with the
network stubbed and checked against the same shape.

Synthetic data only. Network-free.
"""
from __future__ import annotations

import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from ingest_contract_registry import REGISTRY, Decl, Gap  # noqa: E402

PARSERS_DIR = ROOT / "vendor" / "cm019_preferences" / "services" / "ingest" / "src" / "parsers"
NOT_PARSERS = {"__init__", "base"}

# Every Gap in REGISTRY, counted. Lower it when a gap is fixed; raising it is a
# visible decision in the diff, not a quiet drift.
GAP_BASELINE = 22

FIELDS = ("entity", "category", "timestamp", "owner", "privacy", "item_key")


def _gaps():
    out = []
    for name, d in REGISTRY.items():
        for f in ("category", "owner", "privacy", "item_key"):
            if isinstance(getattr(d, f), Gap):
                out.append((name, f))
        for key in d.gaps:
            out.append((name, key))
    return out


def _is_aggregate(p) -> bool:
    kind = str((p.extra or {}).get("type", ""))
    return "preference" in kind or "pattern" in kind


def _is_pattern(p) -> bool:
    """A statistic over MANY events (a usage pattern) has no single event time."""
    kind = str((p.extra or {}).get("type", ""))
    return "pattern" in kind or "statistics" in kind


# 1. COMPLETENESS ----------------------------------------------------------
def test_every_vendored_parser_is_registered():
    modules = {p.stem for p in PARSERS_DIR.glob("*.py")} - NOT_PARSERS
    assert modules, "found no parser modules: the path is wrong, not the contract"
    missing = sorted(modules - set(REGISTRY))
    assert not missing, (
        f"parser(s) {missing} write preference evidence but declare no ingest contract. "
        "Add a Decl to tests/ingest_contract_registry.py stating the entity, category, "
        "timestamp, owner, privacy and item_key fields, or a Gap with the reason.")


def test_no_registry_row_for_a_parser_that_is_gone():
    modules = {p.stem for p in PARSERS_DIR.glob("*.py")} - NOT_PARSERS
    assert sorted(set(REGISTRY) - modules) == []


# 2. DECLARATION -----------------------------------------------------------
@pytest.mark.parametrize("name", sorted(REGISTRY))
def test_declaration_is_complete(name):
    d = REGISTRY[name]
    assert isinstance(d, Decl)
    for f in FIELDS:
        assert hasattr(d, f)
    for key, gap in d.gaps.items():
        assert isinstance(gap, Gap) and gap.reason.strip(), f"{name} {key}: a gap states why"
    for f in ("category", "owner", "privacy", "item_key"):
        v = getattr(d, f)
        assert (isinstance(v, str) and v.strip()) or (isinstance(v, Gap) and v.reason.strip())


# 3. FIXTURE RUN -----------------------------------------------------------
def _run(name):
    d = REGISTRY[name]
    with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
        first = d.fixture(Path(t1))
        second = d.fixture(Path(t2))
    return d, first, second


def violations(name):
    """{field: count} of preferences breaking the declared contract."""
    d, prefs, again = _run(name)
    assert prefs, f"{name}: the fixture parsed to nothing, so the contract was not exercised"
    bad = {}

    def hit(k):
        bad[k] = bad.get(k, 0) + 1

    now = datetime.now(timezone.utc)
    for p in prefs:
        if not p.category:
            hit("category")
        if not isinstance(p.compartment_level, int) or isinstance(p.compartment_level, bool):
            hit("privacy")
        if not p.id:
            hit("item_key")
        for cat, keys in d.entity.items():
            if p.category == cat and not _is_aggregate(p):
                if not any((p.extra or {}).get(k) for k in keys):
                    hit("entity:" + cat)
        if p.category in d.timestamp and not _is_pattern(p):
            ts = p.observed_at
            if ts is None:
                hit("timestamp:" + p.category)
            else:
                ts = ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
                # An event time is in the past. `now` is the import time.
                if ts > now - timedelta(minutes=5):
                    hit("timestamp:" + p.category)
    if sorted(p.id for p in prefs) != sorted(p.id for p in again):
        hit("item_key")
    return bad


FIXTURED = sorted(n for n, d in REGISTRY.items() if d.fixture is not None)


def test_some_parsers_have_fixtures():
    assert len(FIXTURED) >= 4, FIXTURED


@pytest.mark.parametrize("name", FIXTURED)
def test_fixture_meets_the_declared_contract(name):
    d = REGISTRY[name]
    bad = violations(name)
    declared = set(d.gaps)
    undeclared = {k: v for k, v in bad.items() if k not in declared and k.split(":")[0] + ":*" not in declared}
    assert not undeclared, (
        f"{name} drops a field its contract requires: {undeclared}. "
        "Fix the parser; do not add a gap to hide it.")


@pytest.mark.parametrize("name", FIXTURED)
def test_a_declared_gap_is_still_a_gap(name):
    """A gap a fixture proves closed must be removed, so the ratchet moves."""
    d = REGISTRY[name]
    bad = violations(name)
    for key in d.gaps:
        if key == "measure" or key.endswith(":*"):
            continue
        if key.split(":")[0] == "entity" and key.split(":")[1] not in d.entity:
            continue  # documentary gap for a category the fixture does not cover
        if key.split(":")[0] == "timestamp" and key.split(":")[1] not in d.timestamp:
            continue
        assert key in bad, f"{name}: gap {key} is declared but the fixture meets it; remove the gap"


# 4. RATCHET ---------------------------------------------------------------
def test_gap_count_matches_the_baseline():
    n = len(_gaps())
    assert n == GAP_BASELINE, (
        f"{n} declared gaps, baseline {GAP_BASELINE}. If you FIXED a gap, lower "
        "GAP_BASELINE. If you ADDED one, say why in the PR and raise it knowingly.")


# NON-PARSER WRITERS -------------------------------------------------------
def _capture(monkeypatch, m):
    sent = []
    monkeypatch.setattr(m, "_ollama_embed_batch", lambda texts: [[0.1] * 8 for _ in texts])
    monkeypatch.setattr(m, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(m, "_qdrant_upsert_points", lambda coll, pts: sent.extend(pts) or len(pts))
    return sent


def test_bookmarks_keep_the_real_save_time_an_int_level_and_the_owner(monkeypatch, tmp_path):
    from ostler_fda import pwg_ingest as m
    import json
    monkeypatch.setenv("OSTLER_USER_ID", "fixture_owner")
    sent = _capture(monkeypatch, m)
    (tmp_path / "safari_bookmarks.json").write_text(json.dumps([
        {"title": "fixture-read-later", "url": "https://example.com/a", "domain": "example.com",
         "folder": "Reading List", "date_added": "2021-05-04T10:00:00+00:00"},
        {"title": "fixture-plain", "url": "https://example.org/b", "domain": "example.org",
         "folder": "Favorites", "date_added": None},
    ]))
    assert m.ingest_bookmarks(tmp_path)["status"] == "ok"
    by_url = {p["payload"]["extra"]["url"]: p["payload"] for p in sent}
    dated = by_url["https://example.com/a"]
    plain = by_url["https://example.org/b"]
    assert dated["observed_at"].startswith("2021-05-04"), "the save date, not the import time"
    assert plain["observed_at"] is None, "no real date means no date, never `now`"
    assert plain["extra"]["observed_at_known"] is False
    for pl in (dated, plain):
        assert isinstance(pl["compartment_level"], int)
        assert pl["privacy_level"] == "L2"
        assert pl["user_id"] == "fixture_owner"


def test_bookmarks_never_invent_an_owner(monkeypatch, tmp_path):
    from ostler_fda import pwg_ingest as m
    import json
    monkeypatch.delenv("OSTLER_USER_ID", raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "no-install-here"))
    sent = _capture(monkeypatch, m)
    (tmp_path / "safari_bookmarks.json").write_text(json.dumps([
        {"title": "fixture", "url": "https://example.com/a", "domain": "example.com", "folder": "F"}]))
    m.ingest_bookmarks(tmp_path)
    assert sent and "user_id" not in sent[0]["payload"]


def test_imessage_social_keeps_the_last_message_time(monkeypatch, tmp_path):
    from ostler_fda import pwg_ingest as m
    import json
    monkeypatch.setenv("OSTLER_USER_ID", "fixture_owner")
    sent = _capture(monkeypatch, m)
    (tmp_path / "imessage_conversations.json").write_text(json.dumps([
        {"chat_id": 1, "display_name": "", "participants": ["+447700900123"], "message_count": 120,
         "is_group": False, "first_message": "2019-01-01T09:00:00+00:00",
         "last_message": "2023-02-03T04:05:06+00:00"}]))
    assert m.ingest_social(tmp_path)["status"] == "ok"
    pl = sent[0]["payload"]
    assert pl["observed_at"].startswith("2023-02-03"), pl["observed_at"]
    assert isinstance(pl["compartment_level"], int)
    assert pl["user_id"] == "fixture_owner"
