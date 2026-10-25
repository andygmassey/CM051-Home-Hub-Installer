#!/usr/bin/env python3
"""Food evidence reaches smart preferences, from the SHIPPED tree.

smart preferences derived 2 restaurants on a walked box because nothing wrote
restaurant or cuisine evidence. This drives the vendored FDA step, the vendored
CM019 parser and the vendored derive registry on synthetic extracts:

  arm 1  ingest_food is in the FDA dispatch and stages ONLY the extracts the food
         parser claims (reminders, notes, messages in the same folder are never
         offered), then calls the CM019 ingest once (the single writer path).
  arm 2  every staged file name is claimed by FoodEvidenceParser and by no parser
         ahead of it in the pipeline's list.
  arm 3  the parser's output derives food.restaurant, food.cuisine and food.item
         through the vendored registry; a single visit stays under the gate.
  arm 4  a diet-shaped grocery signal is private (compartment 0) and no derive
         row reads its category.
  arm 5  CONSENT: the OSM cuisine client makes ZERO requests unless the install
         recorded "accepted", and one request when it did.
  arm 6  one cuisine is one value: Szechuan, Sichuanese, Sichuan -> sichuan.
  arm 7  regions stay apart: love Sichuan / not a fan of Cantonese are two nodes.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
import importlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
try:
    import aiofiles  # noqa: F401
    import httpx  # noqa: F401
    import pydantic_settings  # noqa: F401
    import yaml  # noqa: F401
    import aiolimiter  # noqa: F401
    import click  # noqa: F401
    import phonenumbers  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install aiofiles httpx pydantic-settings pyyaml aiolimiter click phonenumbers beautifulsoup4")
    sys.exit(2)

sys.path[:0] = [str(REPO / "vendor"), str(TREE / "services" / "common"), str(TREE / "services" / "enrich" / "src")]
from ostler_fda import pwg_ingest as fda  # noqa: E402

PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


# ── synthetic FDA folder ─────────────────────────────────────────────────────
TMP = Path(tempfile.mkdtemp(prefix="food-vendored-"))
FDA = TMP / "imports" / "fda"
FDA.mkdir(parents=True)
(TMP / "imports" / "email").mkdir()
cal = [{"title": "Dinner @ Test Trattoria", "location": "", "start_date": f"2026-0{m}-05T19:00:00+00:00"} for m in (5, 6, 7)]
cal += [{"title": "Lunch @ The Noodle House", "location": "", "start_date": f"2026-0{m}-09T12:00:00+00:00"} for m in (5, 6)]
cal += [{"title": "Lunch @ Synthetic Once Cafe", "location": "", "start_date": "2026-05-02T12:00:00+00:00"}]
(FDA / "calendar_events.json").write_text(json.dumps(cal))
mail = [{"subject": "Your reservation at Test Trattoria is confirmed", "sender": "OpenTable <noreply@opentable.com>",
         "date_sent": "2026-06-01T10:00:00+00:00", "message_id": 1}]
(FDA / "apple_mail.json").write_text(json.dumps(mail))
for decoy in ("reminders.json", "apple_notes.json", "imessage_conversations.json", "whatsapp_conversations.json"):
    (FDA / decoy).write_text("[]")
MBOX_DAY = "Thu"  # mbox From_ line: weekday, then month, kept apart for the name guard
GRO = ("From a@b " + MBOX_DAY + " Sep  3 12:00:00 2026\nFrom: Tesco <orders@mail.tesco.com>\nSubject: your Tesco order confirmation\n"
       "Date: Thu, 3 Sep 2026 12:00:00 +0000\nMessage-ID: <{i}@x>\nContent-Type: text/plain\n\n"
       "1 x Heinz baked beans 4pk £3.50\nSynthetic vegan sausages 300g £2.75\nTotal £6.25\n\n")
(TMP / "imports" / "email" / "2026-10-22-19.mbox.txt").write_text("".join(GRO.format(i=i) for i in range(3)))

# ── arm 1: dispatch + staging ────────────────────────────────────────────────
check(("food", "ingest_food") in fda._INGEST_DISPATCH, "arm 1: ingest_food is in the FDA dispatch")
seen = {}


def fake_run(stage, ostler_dir, user):
    seen["files"] = sorted(p.name for p in Path(stage).iterdir())
    seen["calls"] = seen.get("calls", 0) + 1
    seen["staged_dir"] = Path(stage)
    seen["copy"] = {p.name: p.resolve() for p in Path(stage).iterdir()}
    return True


with mock.patch("ostler_fda.apple_music_refresh.run_cm019_ingest", fake_run):
    res = fda.ingest_food(FDA)
check(res == {"status": "ok", "staged": 3} and seen["calls"] == 1, f"arm 1: one CM019 ingest call, 3 files staged (got {res})")
check(seen["files"] == ["2026-10-22-19.mbox.txt", "apple_mail.json", "calendar_events.json"],
      "arm 1: only the claimed extracts are offered; reminders, notes and messages are not")
check(all(p.parent in (FDA.resolve(), (TMP / "imports" / "email").resolve()) for p in seen["copy"].values()), "arm 1: staged by link, no 750 MB copy")
check(not seen["staged_dir"].exists(), "arm 1: the staging dir is removed afterwards")
check(fda.ingest_food(TMP / "nowhere" / "fda") == {"status": "no_data", "staged": 0}, "arm 1: no extracts is no_data, not ok")
with mock.patch("ostler_fda.apple_music_refresh.run_cm019_ingest", lambda *a: False):
    check(fda.ingest_food(FDA)["status"] == "error", "arm 1: a failed ingest is reported error, not ok")

# ── arm 2: the pipeline offers each file to the food parser first ────────────
sys.path.insert(0, str(TREE / "services" / "ingest"))
parsers = importlib.import_module("src.parsers")
src = (TREE / "services/ingest/src/pipeline.py").read_text()
order = re.findall(r"^\s+(\w+Parser)\(\)", src.split("self.parsers: List[BaseParser] = [", 1)[1].split("\n        ]", 1)[0], re.M)
check("FoodEvidenceParser" in order, "arm 2: FoodEvidenceParser is in the pipeline's parser list")
for name in ("calendar_events.json", "apple_mail.json", "2026-10-22-19.mbox.txt"):
    first = next((n for n in order if getattr(parsers, n)().can_parse(FDA / name)), None)
    check(first == "FoodEvidenceParser", f"arm 2: {name} reaches the food parser first (first claimant: {first})")

# ── arm 3/4/6: parse -> derive ───────────────────────────────────────────────
from src.parsers.food_evidence import FoodEvidenceParser, FoodExtractor, make_cuisine_resolver  # noqa: E402
from derive.config import build_readers, load_dimensions  # noqa: E402
from derive.engine import Aggregator  # noqa: E402

ex = FoodExtractor(cuisine_for=make_cuisine_resolver(use_model=False), now=datetime(2026, 10, 22, tzinfo=timezone.utc))


async def parse_all():
    out = []
    for p in (FDA / "calendar_events.json", FDA / "apple_mail.json", TMP / "imports/email/2026-10-22-19.mbox.txt"):
        out += [x async for x in FoodEvidenceParser(ex).parse(p)]
    return out


prefs = asyncio.run(parse_all())


class Store:
    def __init__(self, ps):
        self.pts = [{"id": f"p{i}", "payload": {"category": p.category, "subject": p.subject, "source": p.source, "strength": 0.6,
                                                 "observed_at": "2026-09-01T00:00:00Z", "extra": p.extra}} for i, p in enumerate(ps)]

    def scroll(self, cats, fields):
        return [p for p in self.pts if not cats or p["payload"]["category"] in cats]

    def sparql(self, q):
        return []


def derive(ps):
    items = [i for r in build_readers(Store(ps)) for i in r.read("u")]
    return {(n.dimension, n.subject): n for n in Aggregator(load_dimensions()).aggregate(items, now=datetime(2026, 10, 22, tzinfo=timezone.utc))}


got = derive(prefs)
rest = {s for (d, s) in got if d == "food.restaurant"}
check({"Test Trattoria", "The Noodle House"} <= rest, f"arm 3: restaurants derive ({sorted(rest)})")
check("Synthetic Once Cafe" not in rest, "arm 3: control, one visit is under the gate")
check({"italian", "chinese"} <= {s for (d, s) in got if d == "food.cuisine"}, "arm 3: cuisines derive")
items_ = {s for (d, s) in got if d == "food.item"}
check("heinz baked beans" in items_, "arm 3: grocery items derive")
# Since T0j (PWG 5af9f5b5) food.item carries sensitive_match: contains, so a diet
# word in an item ("vegan sausages") is a diet signal and must NOT derive.
check("synthetic vegan sausages" not in items_, "arm 3: a diet word in a grocery item is dropped by the sensitive gate")
check({"Tesco", "Heinz"} <= {s for (d, s) in got if d == "commerce.brand"}, "arm 3: retailer and known brand derive")
diet = [p for p in prefs if p.category == "dietary"]
check(diet and all(p.compartment_level == 0 and p.extra["nudge"] is False for p in diet), "arm 4: diet signal stored private, never nudge")
check(not any(d.startswith("dietary") or "vegan" in s.lower() and d != "food.item" for (d, s) in got), "arm 4: no derive row surfaces it")
check(not re.search(r"select_categories:.*\bdietary\b", (TREE / "services/enrich/src/derive/readers.yaml").read_text()), "arm 4: registry never selects 'dietary'")


def cuisines(spellings):
    class S(Store):
        pass
    pts = []
    for i, sp in enumerate(spellings):
        pts.append(type("P", (), {"category": "food", "subject": f"R{i}", "source": "s", "extra": {"restaurant": f"Synthetic R{i}", "cuisine": sp}})())
    return {s for (d, s) in derive(pts) if d == "food.cuisine"}


check(cuisines(["Szechuan", "Sichuanese", "sichuan"]) == {"sichuan", "chinese"},
      "arm 6: Szechuan, Sichuanese, Sichuan are ONE value (sichuan) plus the chinese roll-up")


def region_pts(spec):
    return [type("P", (), {"category": "food", "subject": f"R{i}", "source": "s", "strength": st,
                           "extra": {"restaurant": f"Synthetic R{i}", "cuisine": cu}})() for i, (cu, st) in enumerate(spec)]


def derive2(ps):
    items = [i for r in build_readers(Store2(ps)) for i in r.read("u")]
    return {(n.dimension, n.subject): n for n in Aggregator(load_dimensions()).aggregate(items, now=datetime(2026, 10, 22, tzinfo=timezone.utc))}


class Store2(Store):
    def __init__(self, ps):
        self.pts = [{"id": f"p{i}", "payload": {"category": p.category, "subject": p.subject, "source": p.source, "strength": p.strength,
                                                 "observed_at": "2026-09-01T00:00:00Z", "extra": p.extra}} for i, p in enumerate(ps)]


g = derive2(region_pts([("Szechuan", 0.8)] * 3 + [("Hong Kong-style", -0.5)] * 3))
check(g[("food.cuisine", "sichuan")].preference_strength > 0 > g[("food.cuisine", "cantonese")].preference_strength,
      "arm 7: love Sichuan, not a fan of Cantonese = two nodes, opposite polarity")
check(("food.cuisine", "chinese") in g and g[("food.cuisine", "chinese")].evidence_count == 6, "arm 7: the chinese roll-up exists and erases neither")

# ── arm 5: consent ───────────────────────────────────────────────────────────
import types  # noqa: E402

_enrich = types.ModuleType("enrich_src")   # the ingest service already owns the name `src`
_enrich.__path__ = [str(TREE / "services" / "enrich" / "src")]
sys.modules["enrich_src"] = _enrich
OsmCuisineClient = importlib.import_module("enrich_src.clients.osm_cuisine").OsmCuisineClient


def lookups(decision):
    os.environ["OSTLER_DIR"] = str(TMP)
    os.environ.pop("OSTLER_CONSENT_ENRICHMENT_DECISION", None)
    (TMP / "config").mkdir(exist_ok=True)
    (TMP / "config" / ".env").write_text("" if decision is None else f'OSTLER_CONSENT_ENRICHMENT_DECISION="{decision}"\n')
    calls = []

    async def rec(method, url, params=None, json_data=None):
        calls.append(url)
        return [{"osm_type": "node", "osm_id": 1, "category": "amenity", "type": "restaurant", "name": "The Noodle House",
                 "extratags": {"cuisine": "szechuan"}}]
    c = OsmCuisineClient(cache_path=TMP / f"osm-{decision}.json")
    c._make_request = rec
    r = asyncio.run(c.enrich_venue("p", "The Noodle House", "Testville"))
    return len(calls), [t.name for t in r.topics]


for bad in ("declined", "ACCEPTED", "Accepted", " accepted ", "accepted\t"):
    check(lookups(bad) == (0, []), f"arm 5: {bad!r} -> zero requests (consent is EXACT 'accepted')")
check(lookups(None) == (0, []), "arm 5: absent -> zero requests")
check(lookups("accepted") == (1, ["sichuan"]), "arm 5: accepted -> one request, cuisine read and normalised")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
