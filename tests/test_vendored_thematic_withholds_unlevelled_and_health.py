#!/usr/bin/env python3
"""Themes are built only from preferences with an admitted canonical level.

A preference with no level at all (unlevelled) and a health preference (written
by the vendored apple.py at legacy compartment 0, the most private level) must not
feed a surfaced theme. Before this fix the thematic reader admitted both: only the
legacy highest-privacy 5 was blocked.

Drives the REAL vendored ``ThematicReader.read`` end to end (privacy_of, the
theme grouping and the sensitive gate), with a fake store gateway that returns
the same SPARQL and Qdrant shapes the product reads. Synthetic values only.

  arm 1  an unlevelled preference is withheld from the theme                (leak on main)
  arm 2  a health preference (legacy compartment 0, no level) is withheld   (leak on main)
  arm 3  a stamped canonical L1 preference that carries legacy compartment 0
         is withheld: the legacy 0 block works on its own                   (leak on main)
  arm 4  control: a stamped canonical L2 preference is admitted             (must stay admitted)
  arm 5  control: a stamped canonical L1 preference is admitted             (must stay admitted)
The two controls are also what lets the theme clear min_leaves=2 on the branch.

Exit: 0 all arms pass, 1 an arm fails, 2 cannot-run (the vendored reader did not import).
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
for p in (VENDOR / "enrich" / "src", VENDOR / "common"):
    sys.path.insert(0, str(p))

try:
    from derive.thematic import ThematicReader, WD_ENTITY
    from derive.model import PREF_URN_PREFIX
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored thematic reader did not import: {exc!r}")
    sys.exit(2)

# The shared scale stamp (services/common/privacy_scale_canonical.tsv [scale_stamp]).
STAMP_FIELD = "privacyScale"
STAMP_VALUE = "canonical-2026-11"
THEME_QID = "Q900001"
THEME_LABEL = "Astronomy"
# pref id -> (payload, arm name). Three leaves so the theme clears min_leaves=2.
PREFS = {
    "p_unlevelled": ({"source": "synthetic", "observed_at": "2026-01-01T00:00:00Z"},
                     "arm1 unlevelled withheld"),
    "p_health":     ({"source": "synthetic", "observed_at": "2026-01-01T00:00:00Z",
                      "compartment_level": 0},
                     "arm2 health (legacy 0) withheld"),
    "p_l1_legacy0": ({"source": "synthetic", "observed_at": "2026-01-01T00:00:00Z",
                      "privacy_level": "L1", STAMP_FIELD: STAMP_VALUE,
                      "compartment_level": 0},
                     "arm3 stamped L1 with legacy 0 withheld"),
    "p_l2":         ({"source": "synthetic", "observed_at": "2026-01-01T00:00:00Z",
                      "privacy_level": "L2", STAMP_FIELD: STAMP_VALUE},
                     "arm4 control stamped L2 admitted"),
    "p_l1":         ({"source": "synthetic", "observed_at": "2026-01-01T00:00:00Z",
                      "privacy_level": "L1", STAMP_FIELD: STAMP_VALUE},
                     "arm5 control stamped L1 admitted"),
}
ADMITTED_CONTROLS = {"p_l2", "p_l1"}
LEAF = {"p_unlevelled": "comets", "p_health": "planets",
        "p_l1_legacy0": "rivers", "p_l2": "telescopes", "p_l1": "meteors"}


class FakeGateway:
    def scroll(self, categories, fields):
        return [{"id": pid, "payload": payload} for pid, (payload, _) in PREFS.items()]

    def sparql(self, query):
        if "COUNT(" in query:
            return [{"n": {"value": "3"}}]
        rows = []
        for pid in PREFS:
            rows.append({
                "pref": {"value": PREF_URN_PREFIX + pid},
                "topic": {"value": "urn:synthetic:topic:" + LEAF[pid]},
                "topicLabel": {"value": LEAF[pid]},
                "broader": {"value": WD_ENTITY + THEME_QID},
                "broaderLabel": {"value": THEME_LABEL},
            })
        return rows


def main() -> int:
    reader = ThematicReader(gateway=FakeGateway(), dimension="theme.concept",
                            domain="synthetic", category="synthetic",
                            select_categories=["synthetic"])
    admitted = {e.preference_id for e in reader.read("synthetic-user")}
    stats = reader.stats
    failures = 0
    for pid, (_, arm) in PREFS.items():
        want = pid in ADMITTED_CONTROLS
        got = pid in admitted
        ok = got == want
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {arm}: admitted={got}")
    print(f"stats status={stats.get('status')} withheld_private={stats.get('withheld_private')}")
    print(f"TOTAL {len(PREFS)} arms, {failures} FAIL")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
