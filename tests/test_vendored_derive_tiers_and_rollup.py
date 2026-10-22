#!/usr/bin/env python3
"""Types before things, from the SHIPPED registry: tiers, and rollup into broad groups.

  arm 1  every dimension has a tier; the broad set is exactly the types.
  arm 2  ROLLUP: one enriched track settles its artist's (and album's) genre, one
         enriched episode its series' genre, one enriched order its restaurant's
         cuisine; a restaurant named for its cuisine needs no lookup.
  arm 3  MUTANT: with the rollup rows removed those broad groups vanish.
  arm 4  the rollup makes no network call.
Synthetic values only. Exit: 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import re
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
try:
    import yaml
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}")
    sys.exit(2)
sys.path[:0] = [str(TREE / "services" / "common"), str(SRC)]
from derive.config import READERS_YAML, build_readers, load_dimensions  # noqa: E402
from derive.engine import Aggregator  # noqa: E402
from derive.model import PREF_URN_PREFIX  # noqa: E402

PASS = FAIL = 0
BROAD = {"media.film.genre", "media.tv.genre", "media.music.genre", "media.book.genre",
         "media.book.topic", "media.podcast.topic", "food.cuisine", "interests.topic",
         "place.city", "health.activity", "work.industry"}


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


class Store:
    def __init__(self):
        self.points, self.tags = [], {}

    def point(self, pid, cat, subject, **extra):
        self.points.append({"id": pid, "payload": {
            "category": cat, "subject": subject, "source": "synthetic", "strength": 0.6,
            "observed_at": "2026-09-01T00:00:00Z", "extra": extra}})

    def tag(self, pid, pred, label):
        self.tags.setdefault(pred, []).append((pid, label))

    def scroll(self, categories, fields):
        return [p for p in self.points if not categories or p["payload"]["category"] in categories]

    def sparql(self, q):
        mp = re.search(r"enrichment/ontology#(\w+)>", q)
        if mp is None:
            return []   # not an overlay query: the stated readers ask the fact store, which has no rows here
        pred = mp.group(1)
        return [{"s": {"value": PREF_URN_PREFIX + pid}, "label": {"value": lab},
                 "conf": {"value": "0.9"}} for pid, lab in self.tags.get(pred, [])]


def derive(store, readers_path=READERS_YAML):
    items = [i for r in build_readers(store, path=readers_path) for i in r.read("u")]
    nodes = Aggregator(load_dimensions()).aggregate(items, now=datetime(2026, 10, 22, tzinfo=timezone.utc))
    return {(n.dimension, n.subject) for n in nodes}


def scenario():
    s = Store()
    for i in range(4):
        s.point(f"a{i}", "music", f"song-{i} - album-x", artist="artist-one")
        s.point(f"b{i}", "music", f"song-{i} - album-y", album="album-y")
        s.point(f"e{i}", "tv_show", f"series-one - episode {i}")
    for i in range(3):
        s.point(f"o{i}", "food", f"order {i}", restaurant="plain-name-place")
    for i in range(2):
        s.point(f"s{i}", "food", f"order {i}", restaurant="sushi-house-alpha")
    s.tag("a0", "hasGenre", "indie-rock")
    s.tag("b1", "hasGenre", "Hip-Hop/Rap")
    s.tag("e2", "hasGenre", "Drama-alpha")
    s.tag("o0", "hasTopic", "italian-restaurant")
    s.tag("o0", "hasTopic", "Restaurant")
    want = {("media.music.genre", "alternative"), ("media.music.genre", "rock"),
            ("media.music.genre", "hip hop"), ("media.tv.genre", "Drama-alpha"),
            ("food.cuisine", "italian"), ("food.cuisine", "japanese")}
    return s, want


print("arm 1: tiers")
tiers = {d.dimension: d.tier for d in load_dimensions()}
check(set(tiers.values()) <= {"broad", "specific"}, "every dimension states a tier")
check({d for d, t in tiers.items() if t == "broad"} == BROAD, "the broad set is exactly the types")

print("arm 2: rollup and lexicon")
store, want = scenario()
got = derive(store)
for w in sorted(want):
    check(w in got, f"{w[0]} derives {w[1]!r}")
check(("food.cuisine", "restaurant") not in got, "a venue type is not a cuisine")

print("arm 3: mutant, rollup rows removed")
rows = yaml.safe_load(READERS_YAML.read_text())
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "readers.yaml"
    p.write_text(yaml.safe_dump([r for r in rows if r["kind"] != "rollup"]))
    mut = derive(store, readers_path=p)
for w in sorted(want - {("food.cuisine", "japanese")}):
    check(w not in mut, f"{w[0]} {w[1]!r} is gone without the rollup")
check(("food.cuisine", "japanese") in mut, "control: the lexicon (no rollup) still derives japanese")

print("arm 4: no network")
orig = urllib.request.urlopen
urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(AssertionError("network"))
try:
    check(want <= derive(store), "derive-time rollup makes no network call")
finally:
    urllib.request.urlopen = orig

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
