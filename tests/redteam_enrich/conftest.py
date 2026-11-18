"""Red-team regression suite for the enrichment gate (CB134, red-team report 2026-11-18).

Each test was an attack that got through. Synthetic values only. Network clients are
replaced by a recorder; the people store is not mocked (the contact loader fails closed).
"""
import sys
from pathlib import Path
from unittest import mock
import os

# The worktree this file lives in (tests/redteam_enrich/ -> repo root). REDTEAM_WT overrides.
WT = Path(os.environ.get("REDTEAM_WT", Path(__file__).resolve().parents[2]))
VENDOR = WT / "vendor" / "cm019_preferences" / "services"
for p in (VENDOR / "enrich", VENDOR / "common"):
    sys.path.insert(0, str(p))

import pytest

from src.enricher import EnrichmentService, EnrichmentStats  # noqa: E402

STAMP = {"privacyScale": "canonical-2026-11"}
CLIENT_ATTRS = ("_openlibrary", "_tmdb", "_musicbrainz", "_wikidata", "_podcast_index",
                "_url_fetcher", "_brand", "_domain_mapper", "_foursquare", "_events",
                "_osm_cuisine", "_youtube", "_google_places", "_linkedin")


class Sink:
    def __init__(self):
        self.calls = []

    def strings(self):
        out = []
        for name, args in self.calls:
            out.extend(args)
        return out


class Recorder:
    def __init__(self, sink):
        self._sink = sink

    def __getattr__(self, name):
        sink = self._sink

        async def call(*args, **kwargs):
            strs = [a for a in args if isinstance(a, str)]
            strs += [v for v in kwargs.values() if isinstance(v, str)]
            sink.calls.append((name, tuple(strs)))
            return mock.MagicMock(qid=None, label=None, confidence=0.0, match_type=None,
                                  is_successful=lambda: False)
        return call


def _init(self, rec):
    self.privacy_refusals = {}
    self._enriched_ids = set()
    for n in CLIENT_ATTRS:
        if not isinstance(getattr(EnrichmentService, n, None), property):
            setattr(self, n, rec)


async def _no_enriched(_pid):
    return False


@pytest.fixture
def svc_and_sink():
    from contextlib import ExitStack
    sink = Sink()
    rec = Recorder(sink)
    with ExitStack() as st:
        st.enter_context(mock.patch.object(EnrichmentService, "_consent_or_log", staticmethod(lambda ep: True)))
        st.enter_context(mock.patch.object(EnrichmentService, "__init__", lambda self: _init(self, rec)))
        for n in CLIENT_ATTRS:
            if isinstance(getattr(EnrichmentService, n, None), property):
                st.enter_context(mock.patch.object(EnrichmentService, n, new=property(lambda self, _r=rec: _r)))
        svc = EnrichmentService()
        svc._check_already_enriched = _no_enriched
        yield svc, sink


async def run_batch(svc, items):
    stats = EnrichmentStats()
    try:
        await svc.enrich_batch(items, stats)
    except Exception as exc:  # noqa: BLE001 - recorded, the sink is what matters
        print(f"note: enrich_batch raised {type(exc).__name__}: {exc}")
    return stats


async def run_one(svc, item):
    try:
        await svc.enrich_preference(item)
    except Exception as exc:  # noqa: BLE001
        print(f"note: enrich_preference raised {type(exc).__name__}: {exc}")


def pref(pid, subject, category, **fields):
    """Synthetic preference. Provenance is DECLARED (extra.category_inferred=False):
    without it eligibility.is_eligible refuses every item, so a control would
    pass or fail for a reason other than the privacy gate under test."""
    extra = fields.pop("extra", None)
    if extra is None:
        extra = {"category_inferred": False}
    elif isinstance(extra, dict):
        extra = {"category_inferred": False, **extra}
    return {"id": pid, "subject": subject, "category": category, "extra": extra, **fields}
