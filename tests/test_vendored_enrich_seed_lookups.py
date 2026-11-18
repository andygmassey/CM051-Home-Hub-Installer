#!/usr/bin/env python3
"""The vendored enricher still produces look-ups, and sends none it must not.

Runs the REAL vendored ``Enricher.enrich_preference`` (gate, dispatch and the
category routing) over a synthetic seed. Every network client is replaced by a
recorder, so NO request leaves the process. Assertions:

  A  look-ups sent > 0                                   (enrichment works)
  B  every sent subject belongs to an L0/L1 seed item     (L0/L1 only)
  C  zero sent subjects from a condition-2 category        (health, dietary,
     person, location, finance, minor), whatever the level
  D  zero sent subjects from L2, L3, unlevelled, unstamped L0, or legacy 0/1/3/5

Prints counts by level and by category. Synthetic values only.
Exit 0 pass, 1 an assertion failed, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
import sys
from collections import Counter
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

# (level label, category, extra fields). Subject is "seed-subject-NN".
SEED = [
    ("L0 stamped", "book", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "music", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "food", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "place", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "movie", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "podcast", {"privacy_level": "L0", **STAMP}),
    ("L1 stamped", "music", {"privacy_level": "L1", **STAMP}),
    ("L1 stamped", "interest", {"privacy_level": "L1", **STAMP}),
    ("legacy 2", "book", {"compartment_level": 2}),
    ("legacy 4", "interest", {"compartment_level": 4}),
    ("legacy 6", "movie", {"compartment_level": 6}),
    ("L2 stamped", "book", {"privacy_level": "L2", **STAMP}),
    ("L2 stamped", "interest", {"privacy_level": "L2", **STAMP}),
    ("L3 stamped", "interest", {"privacy_level": "L3", **STAMP}),
    ("L0 unstamped", "book", {"privacy_level": "L0"}),
    ("legacy 0", "book", {"compartment_level": 0}),
    ("legacy 1", "book", {"compartment_level": 1}),
    ("legacy 3", "book", {"compartment_level": 3}),
    ("legacy 5", "book", {"compartment_level": 5}),
    ("unlevelled", "book", {}),
    ("L0 stamped", "health", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "dietary", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "person", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "location", {"privacy_level": "L0", **STAMP}),
    ("L0 stamped", "book", {"privacy_level": "L0", "about_minor": True, **STAMP}),
]


def build_seed():
    items = []
    for i, (level, cat, fields) in enumerate(SEED, start=1):
        items.append({"id": f"syn-{i:02d}", "subject": f"seed-subject-{i:02d}",
                      "category": cat, **fields, "_level": level})
    return items


class Recorder:
    """Stands in for any network client: records (method, pref_id, subject)."""

    def __init__(self, sink):
        self._sink = sink

    def __getattr__(self, name):
        sink = self._sink

        async def call(*args, **kwargs):
            # Every string argument is recorded. normalize_topic(subject) passes the
            # subject first; the other methods pass (pref_id, subject, ...).
            sink.append((name, tuple(a for a in args if isinstance(a, str))))
            # A client that answered with no match: the enricher reads .qid etc.
            return mock.MagicMock(qid=None, label=None, confidence=0.0, match_type=None)
        return call


async def run(seed):
    sink = []
    rec = Recorder(sink)
    with mock.patch.object(Enricher, "_consent_or_log", staticmethod(lambda ep: True)), \
         mock.patch.object(Enricher, "__init__", lambda self: _init(self, rec)):
        e = Enricher()
        for item in seed:
            try:
                await e.enrich_preference(dict(item))
            except Exception as exc:  # noqa: BLE001 - one item must not hide the rest
                print(f"note: {item['id']} raised {type(exc).__name__} after dispatch")
    return sink


def _init(self, rec):
    # Same attributes the real __init__ sets, every client replaced by the recorder.
    self.privacy_refusals = {}
    self._enriched_ids = set()
    for name in ("_openlibrary", "_tmdb", "_musicbrainz", "_wikidata", "_podcast_index",
                 "_url_fetcher", "_brand", "_domain_mapper"):
        setattr(self, name, rec)


def main() -> int:
    seed = build_seed()
    by_subject = {it["subject"]: it for it in seed}
    try:
        sent = asyncio.run(run(seed))
    except Exception as exc:  # noqa: BLE001
        print(f"CANNOT-RUN: enricher run failed: {exc!r}")
        return 2

    looked = Counter()
    refused = Counter()
    sent_subjects = {s for _, strs in sent for s in strs if s.startswith("seed-subject-")}
    for it in seed:
        bucket = looked if it["subject"] in sent_subjects else refused
        bucket[it["_level"]] += 1
    seed_by_cat = Counter(it["category"] for it in seed)

    failures = []
    if len(sent) == 0:
        failures.append("A: no look-ups sent")
    bad_b = [s for s in sent_subjects if s not in by_subject
             or not by_subject[s]["_level"].startswith(("L0 stamped", "L1 stamped", "legacy 2", "legacy 4", "legacy 6"))]
    if bad_b:
        failures.append(f"B: non-L0/L1 subjects sent: {len(bad_b)}")
    bad_c = [s for s in sent_subjects if s in by_subject and
             (by_subject[s]["category"] in CAT_EXCLUDED or by_subject[s].get("about_minor"))]
    if bad_c:
        failures.append(f"C: excluded-category subjects sent: {len(bad_c)}")
    bad_d = [s for s in sent_subjects if s in by_subject and
             by_subject[s]["_level"].startswith(("L2", "L3", "unlevelled", "L0 unstamped", "legacy 0", "legacy 1", "legacy 3", "legacy 5"))]
    if bad_d:
        failures.append(f"D: refused-level subjects sent: {len(bad_d)}")

    print(f"look-ups sent: {len(sent)} across {len(sent_subjects)} subjects")
    print("by level   looked-up / seed:")
    for lvl in sorted({it['_level'] for it in seed}):
        n_seed = sum(1 for it in seed if it["_level"] == lvl)
        print(f"  {lvl:<14} {looked[lvl]:>2} / {n_seed}")
    print("by category looked-up / seed:")
    for cat in sorted(seed_by_cat):
        n_look = sum(1 for it in seed if it["category"] == cat and it["subject"] in sent_subjects)
        print(f"  {cat:<14} {n_look:>2} / {seed_by_cat[cat]}")
    for f in failures:
        print("FAIL " + f)
    print("PASS" if not failures else f"FAIL ({len(failures)} assertion(s))")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
