#!/usr/bin/env python3
"""A person's name goes to a look-up only from a structured creator field, and never when it is an owner contact.

Archie's ruling (2026-11-18): a creator name may be looked up ONLY from the
structured creator field of a media record (artist on a track, author on a book),
never from a free-text interest or person label. Refused: a creator that matches an
owner contact (case, diacritics, whitespace and "Last, First" order ignored); an
interest label that reads as a person's name; an artist-category subject (a creator
typed as free text). Positive control: an artist from a track record is looked up.

The contact list comes from the REAL people-store loader, served by an HTTP mock.
Synthetic values only. Exit 0 pass, 1 an arm failed, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
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
# One contact stored "Last, First" so both orders are exercised.
STORE_NAMES = ["Person, Seed"]


def store_handler(request: httpx.Request) -> httpx.Response:
    body = request.content.decode("utf-8", "replace")
    if "pwg:displayName" in body:
        rows = [{"name": {"type": "literal", "value": n}} for n in STORE_NAMES]
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
            sink.append((name, tuple(a for a in args if isinstance(a, str))))
            return mock.MagicMock(qid=None, label=None, confidence=0.0, match_type=None)
        return call


def _init(self, rec):
    self.privacy_refusals = {}
    self._enriched_ids = set()
    self._contacts_loaded = False
    self._contact_names_value = None
    for name in ("_openlibrary", "_tmdb", "_musicbrainz", "_wikidata", "_podcast_index",
                 "_url_fetcher", "_brand", "_domain_mapper"):
        setattr(self, name, rec)


async def run_one_item(item):
    sink = []
    rec = Recorder(sink)
    with mock.patch.object(Enricher, "_consent_or_log", staticmethod(lambda ep: True)), \
         mock.patch.object(Enricher, "__init__", lambda self: _init(self, rec)), \
         mock.patch.object(httpx, "AsyncClient", FakeStoreClient):
        e = Enricher()
        await e.enrich_preference(dict(item))
    return sink, dict(e.privacy_refusals)


def rec_(i, category, subject, **fields):
    return {"id": f"syn-{i:02d}", "subject": subject, "category": category,
            "extra": {"category_inferred": False}, **STAMP, "privacy_level": "L1", **fields}


def sent_anywhere(sink, text):
    return any(text in s for _, strs in sink for s in strs)


ARMS = [
    # (name, item, check(sink, refusals) -> bool)
    ("arm 1a author matches a contact, case variant: refused",
     rec_(1, "book", "seed book title", author="PERSON SEED"),
     lambda sink, r: not sent_anywhere(sink, "seed book title") and r.get("creator_is_contact") == 1),
    ("arm 1b author matches a contact, reversed order: refused",
     rec_(2, "book", "seed book title", author="seed-person"),
     lambda sink, r: not sent_anywhere(sink, "seed book title") and r.get("creator_is_contact") == 1),
    ("arm 1c author matches a contact, with diacritics and spaces: refused",
     rec_(3, "book", "seed book title", author="  Pérson   Séed "),
     lambda sink, r: not sent_anywhere(sink, "seed book title") and r.get("creator_is_contact") == 1),
    ("arm 2  interest label that reads as a person's name: refused",
     rec_(4, "interest", "Jane Smith"),
     lambda sink, r: not sent_anywhere(sink, "Jane Smith") and r.get("person_label") == 1),
    ("arm 3  artist category subject (a creator as free text): refused",
     rec_(5, "artist", "Jane Smith"),
     lambda sink, r: not sent_anywhere(sink, "Jane Smith") and r.get("creator_free_text") == 1),
    ("arm 4  positive control: artist from a track record's structured field is looked up",
     rec_(6, "music", "seed track title", extra={"category_inferred": False, "artist": "Sam Doe"}),
     lambda sink, r: ("enrich", ("syn-06", "Sam Doe", "artist")) in sink
     and not sent_anywhere(sink, "seed track title")),
]


def main() -> int:
    failures = 0
    for name, item, check in ARMS:
        sink, refusals = asyncio.run(run_one_item(item))
        ok = check(sink, refusals)
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}: calls={len(sink)} refusals={refusals}")
    print(f"TOTAL {len(ARMS)} arms, {failures} FAIL")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
