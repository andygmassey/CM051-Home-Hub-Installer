#!/usr/bin/env python3
"""The vendored enricher still produces look-ups, sends only the topic string, and
sends no excluded venue.

Runs the REAL vendored ``EnrichmentService.enrich_preference`` (gate, venue rule,
dispatch and the per-client routing) over a synthetic seed. Every network client is
replaced by a recorder, so no request leaves the process. Assertions:

  A  look-ups sent > 0                                            (enrichment works)
  B  every sent subject belongs to an L0/L1 seed item              (L0/L1 only)
  C  no subject from a condition-2 category, or an Art. 9 / contact venue
  D  no subject from L2, L3, unlevelled, unstamped L0, legacy 0/1/3/5
  E  no owner-record hint (author, year, artist, url, area) reaches any client
  F  positive control: a restaurant name is looked up with the name only

Prints counts by level, by category, and the list of look-ups. Synthetic values only.
Exit 0 pass, 1 an assertion failed, 2 cannot-run.
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

try:  # the enricher uses relative imports, so it is imported as the package member
    from src.enricher import EnrichmentService as Enricher
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored enricher did not import: {exc!r}")
    sys.exit(2)

STAMP = {"privacyScale": "canonical-2026-11"}
CAT_EXCLUDED = {"health", "dietary", "person", "location", "finance", "minors"}
CONTACT_NAMES = frozenset({"seedperson"})
# Owner-record values that must never reach a client (E).
HINTS = ["seed author", "seed artist", "1999", "seed-url.example.test", "seed street",
         "seed-album", "seed-video"]

# (level label, category, subject, extra record fields). Subjects are seed-subject-NN
# unless the category is a venue, where the subject must be a plain name.
SEED = [
    ("L0 stamped", "book", "seed-subject-01", {"privacy_level": "L0", **STAMP, "author": "seed author"}),
    ("L0 stamped", "music", "seed-subject-02", {"privacy_level": "L0", **STAMP, "extra": {"artist": "seed artist", "album": "seed-album"}}),
    ("L0 stamped", "food", "seed-subject-03", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "place", "seed venue harbour", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "movie", "seed-subject-05", {"privacy_level": "L0", **STAMP, "year": 1999}),
    ("L0 stamped", "podcast", "seed-subject-06", {"privacy_level": "L0", **STAMP}),
    ("L1 stamped", "music", "seed-subject-07", {"privacy_level": "L1", **STAMP}),
    ("L1 stamped", "interest", "seed-subject-08", {"privacy_level": "L1", **STAMP}),
    ("legacy 2", "book", "seed-subject-09", {"compartment_level": 2}),
    ("legacy 4", "interest", "seed-subject-10", {"compartment_level": 4}),
    ("legacy 6", "movie", "seed-subject-11", {"compartment_level": 6}),
    ("L2 stamped", "book", "seed-subject-12", {"privacy_level": "L2", **STAMP}),
    ("L2 stamped", "interest", "seed-subject-13", {"privacy_level": "L2", **STAMP}),
    ("L3 stamped", "interest", "seed-subject-14", {"privacy_level": "L3", **STAMP}),
    ("L0 unstamped", "book", "seed-subject-15", {"privacy_level": "L0"}),
    ("legacy 0", "book", "seed-subject-16", {"compartment_level": 0}),
    ("legacy 1", "book", "seed-subject-17", {"compartment_level": 1}),
    ("legacy 3", "book", "seed-subject-18", {"compartment_level": 3}),
    ("legacy 5", "book", "seed-subject-19", {"compartment_level": 5}),
    ("unlevelled", "book", "seed-subject-20", {}),
    ("L0 stamped", "health", "seed-subject-21", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "dietary", "seed-subject-22", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "person", "seed-subject-23", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "location", "seed-subject-24", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "book", "seed-subject-25", {"privacy_level": "L0", "about_minor": True, **STAMP}),
    # venue rule (F and the exclusions)
    ("L0 stamped", "restaurant", "seed venue bistro", {"privacy_level": "L0", **STAMP,
        "extra": {"area": "seed street", "restaurant": "seed venue bistro"}}),
    ("L0 stamped", "place", "seed clinic", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "place", "seed home office", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "place", "seedperson kitchen", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "place", "1 seed street, seed town", {"privacy_level": "L0", **STAMP}),
    # bookmark: the URL is owner browsing data, never sent
    ("L0 stamped", "bookmark", "seed bookmark title", {"privacy_level": "L0", **STAMP,
        "url": "https://seed-url.example.test/page"}),
]


def build_seed():
    items = []
    for i, (level, cat, subject, fields) in enumerate(SEED, start=1):
        items.append({"id": f"syn-{i:02d}", "subject": subject, "category": cat,
                      **fields, "_level": level})
    return items


class Recorder:
    """Stands in for any network client: records every string argument of a call."""

    def __init__(self, sink):
        self._sink = sink

    def __getattr__(self, name):
        sink = self._sink

        async def call(*args, **kwargs):
            sink.append((name, tuple(a for a in args if isinstance(a, str))))
            # A client that answered with no match: the enricher reads .qid etc.
            return mock.MagicMock(qid=None, label=None, confidence=0.0, match_type=None)
        return call


def _init(self, rec):
    # Same attributes the real __init__ sets, every client replaced by the recorder.
    self.privacy_refusals = {}
    self._enriched_ids = set()
    self.contact_names = CONTACT_NAMES
    for name in ("_openlibrary", "_tmdb", "_musicbrainz", "_wikidata", "_podcast_index",
                 "_url_fetcher", "_brand", "_domain_mapper"):
        setattr(self, name, rec)


async def run(seed):
    sink = []
    rec = Recorder(sink)
    with mock.patch.object(Enricher, "_consent_or_log", staticmethod(lambda ep: True)), \
         mock.patch.object(Enricher, "__init__", lambda self: _init(self, rec)), \
         mock.patch.object(Enricher, "_osm_cuisine", property(lambda self: rec), create=True), \
         mock.patch.object(Enricher, "_foursquare", property(lambda self: rec), create=True), \
         mock.patch.object(Enricher, "_google_places", property(lambda self: rec), create=True):
        e = Enricher()
        for item in seed:
            try:
                await e.enrich_preference({k: v for k, v in item.items() if not k.startswith("_")})
            except Exception as exc:  # noqa: BLE001 - one item must not hide the rest
                print(f"note: {item['id']} raised {type(exc).__name__} after dispatch")
    return sink


def main() -> int:
    seed = build_seed()
    by_subject = {it["subject"]: it for it in seed}
    try:
        calls = asyncio.run(run(seed))
    except Exception as exc:  # noqa: BLE001
        print(f"CANNOT-RUN: enricher run failed: {exc!r}")
        return 2

    sent = {}  # subject -> client method names that received it
    all_strings = []
    for name, strs in calls:
        all_strings.extend(strs)
        for s in strs:
            if s in by_subject:
                sent.setdefault(s, []).append(name)
    looked = [it for it in seed if it["subject"] in sent]
    failures = []

    if not calls:
        failures.append("A: no look-ups sent")
    bad_b = [s for s in sent if not by_subject[s]["_level"].startswith(
        ("L0 stamped", "L1 stamped", "legacy 2", "legacy 4", "legacy 6"))]
    if bad_b:
        failures.append(f"B: non-L0/L1 subjects sent: {len(bad_b)}")
    bad_c = [s for s in sent if by_subject[s]["category"] in CAT_EXCLUDED
             or by_subject[s].get("about_minor") or s in ("seed clinic", "seedperson kitchen")]
    if bad_c:
        failures.append(f"C: excluded subjects sent: {len(bad_c)}")
    bad_d = [s for s in sent if by_subject[s]["_level"].startswith(
        ("L2", "L3", "unlevelled", "L0 unstamped", "legacy 0", "legacy 1", "legacy 3", "legacy 5"))]
    if bad_d:
        failures.append(f"D: refused-level subjects sent: {len(bad_d)}")
    leaked = [h for h in HINTS if any(h in s for s in all_strings)]
    if leaked:
        failures.append(f"E: owner-record hints reached a client: {len(leaked)}")
    if "seed venue bistro" not in sent:
        failures.append("F: positive control (restaurant name) not looked up")

    print(f"look-ups sent: {len(calls)} calls, {len(sent)} subjects")
    print("look-ups (level | category | client method):")
    for it in looked:
        print(f"  {it['_level']:<12} | {it['category']:<10} | {','.join(sorted(set(sent[it['subject']])))}")
    print("by level   looked-up / seed:")
    for lvl in sorted({it['_level'] for it in seed}):
        n_look = sum(1 for it in looked if it['_level'] == lvl)
        n_seed = sum(1 for it in seed if it['_level'] == lvl)
        print(f"  {lvl:<14} {n_look:>2} / {n_seed}")
    for f in failures:
        print("FAIL " + f)
    print("PASS" if not failures else f"FAIL ({len(failures)} assertion(s))")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
