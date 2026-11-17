#!/usr/bin/env python3
"""A derived node from the SHIPPED derive engine never inherits L0 or a garbage level.

On the PWG scale L0 is OWNER-PRIVATE. The vendored max_privacy ranked it lowest,
so owner-L0 evidence plus L2 evidence derived an L2 node, which the Hub serves
and the taste assembler can brief. The fix is one fail-closed rule: any L0, any
unparseable or unknown-scale level gives L3. Unstated ("" / None) evidence is
still ignored, as behavioural evidence always was.

Drives vendor/cm019_preferences/services/enrich/src/derive (model.py and the
real Aggregator in engine.py), not a copy. Synthetic values only.
  arm 1  owner-L0 plus L2 evidence derives an L3 node, in both orders, through the Aggregator
  arm 2  owner-L0 alone derives L3
  arm 3  unparseable and unknown-scale levels derive L3
  arm 4  unstated evidence is ignored: behavioural nodes keep their level, L1 and L2 still max
Exit: 0 pass, 1 fail, 2 cannot-run (the vendored derive package did not import).
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
for p in (VENDOR / "enrich" / "src", VENDOR / "common"):
    sys.path.insert(0, str(p))

try:
    from derive.engine import Aggregator, DimensionConfig
    from derive.model import EvidenceItem, max_privacy
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored derive did not import: {exc!r}")
    sys.exit(2)

NOW = datetime(2026, 11, 16, tzinfo=timezone.utc)
GENRE = "media.film.genre"
OBSERVED = datetime(2026, 1, 1, tzinfo=timezone.utc)
FAILS: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  [{detail}]"))
    if not ok:
        FAILS.append(name)


def _ev(i: int, level: str) -> EvidenceItem:
    return EvidenceItem(
        preference_id=f"synthetic-{i}", user_id="synthetic-user", domain="media.film",
        dimension=GENRE, value="synthetic genre", value_qid=None, item_strength=0.6,
        polarity_source="stated", source="synthetic", observed_at=OBSERVED,
        enrichment_confidence=0.8, raw_subject="synthetic genre", privacy_level=level,
    )


def derived_level(levels: list[str]) -> str:
    agg = Aggregator([DimensionConfig(GENRE, "films", min_evidence=1)])
    nodes = agg.aggregate([_ev(i, lvl) for i, lvl in enumerate(levels)], now=NOW)
    if len(nodes) != 1:
        return f"nodes={len(nodes)}"
    return nodes[0].privacy_level


def main() -> int:
    check("arm1 owner-L0 + L2 derives L3 (L0 first)", derived_level(["L0", "L2"]) == "L3",
          derived_level(["L0", "L2"]))
    check("arm1 owner-L0 + L2 derives L3 (L2 first)", derived_level(["L2", "L0"]) == "L3",
          derived_level(["L2", "L0"]))
    check("arm2 owner-L0 alone derives L3", derived_level(["L0"]) == "L3", derived_level(["L0"]))
    for bad in ("l2", "L9", "private", " L2"):
        check(f"arm3 unknown-scale level {bad!r} derives L3", max_privacy(["L1", bad]) == "L3",
              max_privacy(["L1", bad]))
    check("arm4 unstated evidence ignored (all unstated -> '')", max_privacy(["", None]) == "")
    check("arm4 unstated plus L1 -> L1", max_privacy(["", "L1"]) == "L1")
    check("arm4 L1 plus L2 -> L2", max_privacy(["L1", "L2"]) == "L2")
    check("arm4 L3 stays L3", max_privacy(["L1", "L3"]) == "L3")
    print(f"{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
