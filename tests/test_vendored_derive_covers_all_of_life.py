#!/usr/bin/env python3
"""The VENDORED derive registry derives preferences across all of life.

"What you like" shipped deriving three film dimensions only; the engine's own
comment says film was the example pattern. This drives the registry that SHIPS
(vendor/cm019_preferences/services/enrich/src/derive/{readers,dimensions}.yaml)
through the vendored readers and Aggregator, against a synthetic in-memory
store shaped like the real one (Qdrant payload points + enrichment overlay
tags). Every title below is synthetic.

  arm 1  every dimension below derives its expected value from a fixture that
         has enough evidence, and does NOT derive the control value that sits
         under that dimension's min_evidence.
  arm 2  MUTANT: with a dimension's reader rows removed from a copy of
         readers.yaml the dimension disappears. Without this arm a registry
         that never carried the row would pass arm 1 through some other row.
  arm 3  the registry spans the categories the product claims (films, tv,
         music, books, podcasts, interests, web, news, food, places, brands).
  arm 4  a node carrying pwg:evidenceTitle still passes the real SHACL gate
         (the writer refuses to write anything that does not).
  arm 5  one preference named twice is one observation; an overlay tag node
         carrying two labels is dropped rather than credited to every pointer.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

from __future__ import annotations

import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
COMMON = TREE / "services" / "common"
DERIVE = SRC / "derive"

for p in (DERIVE / "readers.yaml", DERIVE / "dimensions.yaml", COMMON / "strength.py",
          TREE / "ontology" / "shacl" / "derived-preference-shapes.ttl"):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)
try:
    import pyshacl  # noqa: F401
    import rdflib  # noqa: F401
    import yaml
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyyaml rdflib pyshacl")
    sys.exit(2)

sys.path.insert(0, str(COMMON))
sys.path.insert(0, str(SRC))

from derive.config import READERS_YAML, build_readers, load_dimensions  # noqa: E402
from derive.engine import Aggregator  # noqa: E402
from derive.model import PREF_URN_PREFIX, DerivedPreference  # noqa: E402
from derive.shacl import PyShaclValidator  # noqa: E402

NOW = datetime(2026, 10, 22, tzinfo=timezone.utc)
WHEN = "2026-09-01T00:00:00Z"
PASS = FAIL = 0


def check(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


class Store:
    def __init__(self):
        self.points, self.tags, self.nodes = [], {}, {}

    def point(self, pid, category, subject, **extra):
        self.points.append({"id": pid, "payload": {
            "category": category, "subject": subject, "source": "synthetic",
            "strength": 0.6, "observed_at": WHEN, "extra": extra}})

    def tag(self, pid, pred, label, etype=None, node=None):
        self.tags.setdefault((pred, etype), []).append((pid, label))
        if node:
            self.nodes[(pid, label)] = node

    def scroll(self, categories, fields):
        return [p for p in self.points
                if not categories or p["payload"]["category"] in categories]

    def sparql(self, query):
        mp = re.search(r"enrichment/ontology#(\w+)>", query)
        if mp is None:
            return []   # the stated-conversation reader asks the fact store, not the overlay
        pred = mp.group(1)
        m = re.search(r'LCASE\(STR\(\?etype\)\) = "(\w+)"', query)
        out = []
        for pid, lab in self.tags.get((pred, m.group(1) if m else None), []):
            row = {"s": {"value": PREF_URN_PREFIX + pid}, "label": {"value": lab},
                   "conf": {"value": "0.9"}}
            if (pid, lab) in self.nodes:
                row["g"] = {"value": self.nodes[(pid, lab)]}
            out.append(row)
        return out


def fixture():
    s = Store()
    expect = {}          # dimension -> (value that must derive, control that must not)

    def many(prefix, n, category, subject="Item {i}", **extra):
        for i in range(n):
            s.point(f"{prefix}{i}", category, subject.format(i=i), **extra)

    many("tv-a", 3, "tv_show", "synthetic-show-alpha - Episode {i}")
    many("tv-b", 2, "tv_show", "synthetic-show-beta - Episode {i}")
    expect["media.tv.series"] = ("synthetic-show-alpha", "synthetic-show-beta")
    many("tg", 3, "tv_show", "show-{i} - pilot")
    for i in range(3):
        s.tag(f"tg{i}", "hasGenre", "synthetic-noir")
        s.tag(f"tg{i}", "hasEntity", "synthetic-actor", "actor")
    expect["media.tv.genre"] = ("synthetic-noir", None)
    expect["media.tv.actor"] = ("synthetic-actor", None)
    many("m", 3, "music", "synthetic-band - Song {i}", artist="synthetic-band")
    many("m-few", 1, "music", "rare-band - Song", artist="rare-band")
    expect["media.music.artist"] = ("synthetic-band", "rare-band")
    many("mg", 3, "music", "song-{i}")
    for i in range(3):
        s.tag(f"mg{i}", "hasGenre", "synthetic-ambient")
    expect["media.music.genre"] = ("electronic", None)
    many("ba", 2, "book", "Book {i}")
    for i in range(2):
        s.tag(f"ba{i}", "hasEntity", "synthetic-author", "author")
        s.tag(f"ba{i}", "hasGenre", "synthetic-fiction")
    expect["media.book.author"] = ("synthetic-author", None)
    expect["media.book.genre"] = ("synthetic-fiction", None)
    many("bt", 3, "books", "Book T{i}")
    for i in range(3):
        s.tag(f"bt{i}", "hasTopic", "synthetic-economics")
    expect["media.book.topic"] = ("synthetic-economics", None)
    s.point("p1", "podcast", "synthetic-cast", podcast_name="synthetic-cast")
    s.point("p2", "podcast", "synthetic-cast (podcast listening pattern)")
    s.point("p3", "podcast", "lonely-cast (bookmarked episode)")
    expect["media.podcast.show"] = ("synthetic-cast", "lonely-cast")
    many("pt", 2, "podcast", "Cast T{i}")
    for i in range(2):
        s.tag(f"pt{i}", "hasTopic", "synthetic-science")
    expect["media.podcast.topic"] = ("synthetic-science", None)
    many("it", 3, "bookmark", "Page {i}", domain="x.test")
    for i in range(3):
        s.tag(f"it{i}", "hasTopic", "synthetic-gardening")
    expect["interests.topic"] = ("synthetic-gardening", None)
    many("w", 4, "bookmark", "Visit {i}", domain="www.Synthetic-Site.test")
    many("w-few", 3, "bookmark", "Visit F{i}", domain="few-visits.test")
    expect["web.site"] = ("synthetic-site.test", "few-visits.test")
    s.point("n1", "bookmark", "Story", domain="www.bbc.co.uk")
    s.point("n2", "bookmark", "Story", domain="news.bbc.co.uk")
    many("n-x", 2, "bookmark", "Post {i}", domain="not-a-publisher.test")
    expect["news.source"] = ("bbc.co.uk", "not-a-publisher.test")
    many("fd", 2, "place", "Eatery {i}")
    for i in range(2):
        s.tag(f"fd{i}", "hasTopic", "synthetic-noodles")
        s.tag(f"fd{i}", "hasTopic", "Price: $$")
    expect["food.cuisine"] = ("chinese", "Price: $$")
    many("c", 2, "transportation", "Trip {i}", city="synthetic-city")
    many("c-one", 1, "transportation", "Trip", city="single-town")
    expect["place.city"] = ("synthetic-city", "single-town")
    many("br", 2, "fashion", "Item {i}", brand="synthetic-brand")
    many("br-solo", 1, "electronics", "Item", brand="solo-brand")
    expect["commerce.brand"] = ("synthetic-brand", "solo-brand")
    many("rs", 2, "food", "Order {i}", restaurant="diner-alpha")
    many("rs-one", 1, "food", "Order", restaurant="diner-once")
    expect["food.restaurant"] = ("diner-alpha", "diner-once")
    many("ha", 2, "fitness", "Workout {i}", activity="Rowing-alpha")
    expect["health.activity"] = ("rowing-alpha", None)
    many("pa", 2, "place", "area-alpha")
    expect["place.area"] = ("area-alpha", None)
    many("fw", 2, "movie", "Film {i}")
    for i in range(2):
        s.tag(f"fw{i}", "hasEntity", "synthetic-writer", "writer")
        s.tag(f"fw{i}", "hasEntity", "synthetic-composer", "composer")
    expect["media.film.writer"] = ("synthetic-writer", None)
    expect["media.film.composer"] = ("synthetic-composer", None)
    return s, expect


def derive(store, readers_path=READERS_YAML):
    items = []
    for r in build_readers(store, path=readers_path):
        items.extend(r.read("u"))
    return Aggregator(load_dimensions()).aggregate(items, now=NOW)


def values(nodes, dim):
    return {n.subject for n in nodes if n.dimension == dim}


store, expect = fixture()
nodes = derive(store)
print("arm 1: every dimension derives, and its gate holds")
for dim, (want, control) in sorted(expect.items()):
    got = values(nodes, dim)
    check(want in got, f"{dim} derives its value")
    if control:
        check(control not in got, f"{dim} does not derive the under-gate control")

print("arm 2: mutant, a dimension's reader rows removed makes it vanish")
rows = yaml.safe_load(READERS_YAML.read_text())
for dim in sorted(expect):
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "readers.yaml"
        p.write_text(yaml.safe_dump([r for r in rows if r["dimension"] != dim]))
        check(values(derive(store, readers_path=p), dim) == set(),
              f"{dim} is gone with its rows removed")

print("arm 3: the registry spans more than films")
cats = {d.category for d in load_dimensions()}
need = {"films", "tv", "music", "books", "podcasts", "interests", "web", "news",
        "food", "place", "brands", "health", "work"}
check(need <= cats, f"categories present: missing {sorted(need - cats)}")

print("arm 4: a node with evidence titles passes the real SHACL gate")
node = DerivedPreference(
    user_id="u", dimension="media.tv.series", subject="synthetic-show-alpha",
    preference_strength=0.5, confidence=0.7, category="tv",
    evidence_from=[PREF_URN_PREFIX + "a", PREF_URN_PREFIX + "b"], evidence_count=2,
    evidence_titles=['synthetic-quoted-episode', "synthetic-episode"])
conforms, text = PyShaclValidator().validate_turtle(node.to_turtle())
check(conforms and "pwg:evidenceTitle" in node.to_turtle(), "evidenceTitle node conforms")

print("arm 5: no double counting, no collided labels")
s2 = Store()
for i in range(3):
    s2.point(f"d{i}", "music", f"synthetic-band - Song {i}", artist="synthetic-band")
    s2.tag(f"d{i}", "hasEntity", "synthetic-band", "artist")   # the same artist, twice
n2 = derive(s2)
band = [n for n in n2 if n.dimension == "media.music.artist"]
check(len(band) == 1 and band[0].evidence_count == 3,
      f"artist named by payload and overlay counts 3, not 6 (got {[b.evidence_count for b in band]})")
s3 = Store()
for i in range(6):
    s3.point(f"x{i}", "music", f"song-{i}")
    lab = "collide-a" if i % 2 else "collide-b"
    s3.tag(f"x{i}", "hasGenre", lab, node="pwg:genre_collided")
check(values(derive(s3), "media.music.genre") == set(), "a node with two labels derives nothing")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
