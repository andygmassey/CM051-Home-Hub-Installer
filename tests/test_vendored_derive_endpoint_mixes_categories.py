#!/usr/bin/env python3
"""The VENDORED derive endpoint interleaves its top-N round-robin by category.

Ranked by confidence alone, one wide category (every TV series, every site) owns
the whole "What you like" list. This drives the shipped reader and response
builder (vendor/cm019_preferences/services/enrich/src/derive/{query,endpoint}.py)
against a fake store that answers the reader's SPARQL the way Oxigraph would
(ORDER BY confidence, strength; LIMIT). Synthetic values only.

  arm 1  13 categories, one wide and most confident: no category takes more than
         ceil(N/3) of the top N.
  arm 2  a lone category still fills the list.
  arm 3  when the others run out the wide one takes the rest.
  arm 4  CONTROL: the plain ranked read (get_derived_preferences) of the SAME
         store IS dominated by the wide category, so arm 1 measures the change.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "vendor" / "cm019_preferences" / "services" / "enrich" / "src"
if not (SRC / "derive" / "query.py").is_file():
    print("CANNOT-RUN: vendored derive/query.py is missing")
    sys.exit(2)
sys.path.insert(0, str(SRC))
sys.path.insert(0, str(REPO / "vendor" / "cm019_preferences" / "services" / "common"))
from derive.endpoint import build_derived_preferences_response  # noqa: E402
from derive.query import DerivedGraphReader  # noqa: E402

PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


class Store:
    def __init__(self, spec, broad_n=0):
        self.rows = []
        for cat, (n, conf) in spec.items():
            for v in range(n):
                self.rows.append({"uri": f"urn:n:{cat}-{v}", "dim": f"{cat}.dim",
                                  "subject": f"{cat}-val{v:02d}", "conf": conf - v * 0.001,
                                  "strength": 0.6, "category": cat,
                                  "tier": "broad" if v < broad_n else "specific"})

    def __call__(self, q):
        if "pwg:derivedFrom" in q:
            return []                      # no evidence titles in this fake
        limit = int(re.search(r"LIMIT (\d+)", q).group(1))
        rows = sorted(self.rows, key=lambda r: (-r["conf"], -r["strength"]))[:limit]
        return [{"s": {"value": r["uri"]}, "dimension": {"value": r["dim"]},
                 "subject": {"value": r["subject"]}, "strength": {"value": str(r["strength"])},
                 "confidence": {"value": str(r["conf"])}, "intensity": {"value": "casual"},
                 "category": {"value": r["category"]},
                 "tier": {"value": r["tier"]}} for r in rows]


def mix(spec, limit):
    resp = build_derived_preferences_response(DerivedGraphReader(Store(spec)), "u",
                                              limit=limit, min_confidence=0.0, tier="all")
    counts = {}
    for it in resp["items"]:
        c = it["label"].split("-")[0]
        counts[c] = counts.get(c, 0) + 1
    return counts, resp


cats = [f"cat{i:02d}" for i in range(13)]
spec = {cats[0]: (40, 0.95)} | {c: (4, 0.70) for c in cats[1:]}

print("arm 1: 13 categories")
counts, resp = mix(spec, 12)
check(not resp["degraded"] and len(resp["items"]) == 12, "12 items served")
check(max(counts.values()) <= math.ceil(12 / 3), f"no category above ceil(12/3): {max(counts.values())}")
check(len(counts) == 12, f"one per category before any second: {len(counts)} categories")

print("arm 2: a lone category fills the list")
counts, _ = mix({cats[0]: (20, 0.9)}, 8)
check(counts == {cats[0]: 8}, f"{counts}")

print("arm 3: the wide one takes the rest")
counts, _ = mix({cats[0]: (40, 0.95), cats[1]: (1, 0.7), cats[2]: (1, 0.7)}, 10)
check(counts == {cats[0]: 8, cats[1]: 1, cats[2]: 1}, f"{counts}")

print("arm 4: control, the plain ranked read is dominated")
plain = DerivedGraphReader(Store(spec)).get_derived_preferences("u", min_confidence=0.0, limit=12)
top = sum(1 for v in plain if v.subject.startswith(cats[0]))
check(top == 12, f"plain read gives the wide category {top} of 12")

print("arm 5: tier filter, default broad, broad first")
spec5 = {cats[0]: (6, 0.95), cats[1]: (6, 0.90)}
st = Store(spec5, broad_n=2)
rd = DerivedGraphReader(st)
broad = build_derived_preferences_response(rd, "u", limit=20, min_confidence=0.0)
check(len(broad["items"]) == 4, f"default tier is broad: {len(broad['items'])} items (2 per category)")
spec_only = build_derived_preferences_response(rd, "u", limit=20, min_confidence=0.0, tier="specific")
check(len(spec_only["items"]) == 8, f"tier=specific: {len(spec_only['items'])} items")
allt = build_derived_preferences_response(rd, "u", limit=20, min_confidence=0.0, tier="all")
check(len(allt["items"]) == 12, f"tier=all keeps today's behaviour: {len(allt['items'])} items")
none = build_derived_preferences_response(DerivedGraphReader(Store(spec5, broad_n=0)), "u",
                                          limit=5, min_confidence=0.0, tier="broad")
check(none["degraded"] and "broad tier" in none["cannot_check"], "an empty broad tier is degraded and says so")

print("arm 6: a pre-tier graph on an upgraded box")
pre = Store(spec5, broad_n=0)
for r in pre.rows:
    r["tier"] = ""
    r["tier_absent"] = True
_orig = Store.__call__
def _no_tier(self, q):
    rows = _orig(self, q)
    for b in rows:
        if b.get("tier", {}).get("value", None) == "":
            del b["tier"]
    return rows
Store.__call__ = _no_tier
dflt = build_derived_preferences_response(DerivedGraphReader(pre), "u", limit=6, min_confidence=0.0)
check(dflt["items"] and dflt.get("tier") == "all" and dflt.get("tier_fallback") is True,
      "default tier on a pre-tier graph serves items and flags tier_fallback")
strict = build_derived_preferences_response(DerivedGraphReader(pre), "u", limit=6,
                                            min_confidence=0.0, tier="broad")
check(strict["items"] == [] and strict["degraded"] and "tier_fallback" not in strict,
      "an explicit tier=broad stays strict")
tiered = build_derived_preferences_response(DerivedGraphReader(Store(spec5, broad_n=2)), "u",
                                            limit=6, min_confidence=0.0)
check(tiered["items"] and "tier_fallback" not in tiered, "a tiered graph is not flagged")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
