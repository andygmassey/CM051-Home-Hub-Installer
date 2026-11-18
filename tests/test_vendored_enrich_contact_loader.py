#!/usr/bin/env python3
"""The venue contact exclusion is fed by the REAL people-store loader, and fails closed.

The enricher loads the owner's contact names from the local people store (Oxigraph,
``pwg:Person`` / ``pwg:displayName``, written by the CM041 contact syncer) through
``EnrichmentService._venue_contact_names``. This test serves that store from an HTTP
mock, so the real loader runs, with no injected list.

  arm 1  a venue containing a seeded contact's name is refused         (loader path)
  arm 2  a venue with no contact name is looked up                     (control)
  arm 3  the people store answers HTTP 500: every venue refused, a book still looked up
  arm 4  the people store is unreachable: every venue refused, a book still looked up
  arm 5  the store is read once per run, not once per item

Exit 0 pass, 1 an arm failed, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
for p in (VENDOR / "enrich", VENDOR / "common"):
    sys.path.insert(0, str(p))

try:
    import httpx
    from src.enricher import EnrichmentService as Enricher
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored enricher did not import: {exc!r}")
    sys.exit(2)

_RealAsyncClient = httpx.AsyncClient
STAMP = {"privacyScale": "canonical-2026-11"}
SEED_CONTACT = "seedperson"
STORE = {"mode": "people", "queries": 0}


def store_handler(request: httpx.Request) -> httpx.Response:
    body = request.content.decode("utf-8", "replace")
    if "pwg:displayName" in body:
        STORE["queries"] += 1
        if STORE["mode"] == "http500":
            return httpx.Response(500)
        if STORE["mode"] == "unreachable":
            raise httpx.ConnectError("store unreachable", request=request)
        rows = [{"name": {"type": "literal", "value": SEED_CONTACT.title()}}]
        return httpx.Response(200, json={"head": {"vars": ["name"]},
                                         "results": {"bindings": rows}})
    return httpx.Response(200, json={"boolean": False})


class FakeStoreClient(_RealAsyncClient):
    def __init__(self, *a, **kw):
        kw["transport"] = httpx.MockTransport(store_handler)
        super().__init__(*a, **kw)


class Recorder:
    def __init__(self, sink):
        self._sink = sink

    def __getattr__(self, name):
        sink = self._sink

        async def call(*args, **kwargs):
            sink.append(tuple(a for a in args if isinstance(a, str)))
            return None
        return call


def _init(self, rec):
    self.privacy_refusals = {}
    self._enriched_ids = set()
    self._contacts_loaded = False
    self._contact_names_value = None
    for name in ("_openlibrary", "_tmdb", "_musicbrainz", "_wikidata", "_podcast_index",
                 "_url_fetcher", "_brand", "_domain_mapper"):
        setattr(self, name, rec)


async def run_items(items, mode):
    STORE["mode"] = mode
    STORE["queries"] = 0
    sink = []
    rec = Recorder(sink)
    with mock.patch.object(Enricher, "_consent_or_log", staticmethod(lambda ep: True)), \
         mock.patch.object(Enricher, "__init__", lambda self: _init(self, rec)), \
         mock.patch.object(Enricher, "_osm_cuisine", property(lambda self: rec), create=True), \
         mock.patch.object(Enricher, "_foursquare", property(lambda self: rec), create=True), \
         mock.patch.object(Enricher, "_google_places", property(lambda self: rec), create=True), \
         mock.patch.object(httpx, "AsyncClient", FakeStoreClient):
        e = Enricher()
        for item in items:
            await e.enrich_preference(dict(item))
    return sink, dict(e.privacy_refusals), STORE["queries"]


def item(i, category, subject, **fields):
    return {"id": f"syn-{i:02d}", "subject": subject, "category": category, **fields}


async def main() -> int:
    failures = 0

    def check(name, ok, detail=""):
        nonlocal failures
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}{'' if ok else '  ' + detail}")

    venue_a = item(1, "restaurant", "seedperson kitchen", privacy_level="L0", **STAMP)
    venue_b = item(2, "restaurant", "seed venue bistro", privacy_level="L0", **STAMP)
    book = item(3, "book", "seed-subject-03", privacy_level="L0", **STAMP)

    sink, refusals, _ = await run_items([venue_a, venue_b, book], "people")
    looked = {s for call in sink for s in call}
    check("arm 1  venue containing a seeded contact's name refused (real loader)",
          "seedperson kitchen" not in looked and refusals.get("venue_contains_contact_name") == 1,
          f"looked={sorted(looked)} refusals={refusals}")
    check("arm 2  venue with no contact name looked up (control)",
          "seed venue bistro" in looked, f"looked={sorted(looked)}")

    sink, refusals, _ = await run_items([venue_b, book], "http500")
    looked = {s for call in sink for s in call}
    check("arm 3  store HTTP 500: venue refused, book still looked up",
          "seed venue bistro" not in looked and "seed-subject-03" in looked
          and refusals.get("venue_contacts_unavailable") == 1,
          f"looked={sorted(looked)} refusals={refusals}")

    sink, refusals, _ = await run_items([venue_b, book], "unreachable")
    looked = {s for call in sink for s in call}
    check("arm 4  store unreachable: venue refused, book still looked up",
          "seed venue bistro" not in looked and "seed-subject-03" in looked
          and refusals.get("venue_contacts_unavailable") == 1,
          f"looked={sorted(looked)} refusals={refusals}")

    _, _, queries = await run_items([venue_a, venue_b, venue_b, venue_a], "people")
    check("arm 5  store read once per run, not once per item", queries == 1, f"queries={queries}")

    print(f"TOTAL 5 arms, {failures} FAIL")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
