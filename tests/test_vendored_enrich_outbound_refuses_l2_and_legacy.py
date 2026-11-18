#!/usr/bin/env python3
"""The enrichment look-up gate sends only L0/L1 subjects, and no excluded category.

Ruling dated 18 Nov 2026 (verbatim, also in the UNRECORDED divergence record): "L0/L1 only,
never L2 (Recommended)". Legacy numerics follow PWG services/ingest/src/parsers/
base.py: legacy 2, 4 and 6 may map to L0/L1; legacy 0, 1, 3 and 5 are refused.
Health and the other excluded categories are refused whatever the level.

Drives the REAL vendored ``privacy_gate.outbound_refusal`` (the function the
enricher calls per item). Synthetic values only. Exit 0 pass, 1 an arm fails,
2 cannot-run.

  arm 0   canonical L3 refused
  arm 1   canonical L2 refused                              (leak on main: allowed)
  arm 2   canonical L1 allowed                              (CB135 row; refused on main)
  arm 3   stamped canonical L0 allowed                      (control)
  arm 4   unstamped L0 refused (legacy-ambiguous)
  arm 5   legacy 2 / 4 / 6 alone allowed
  arm 6   legacy 0 / 1 / 3 / 5 alone refused
  arm 7   unlevelled refused
  arm 8   stamped L0 in a health / person / dietary / minor category refused
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
for p in (VENDOR / "enrich" / "src", VENDOR / "common"):
    sys.path.insert(0, str(p))

try:
    from privacy_gate import outbound_refusal
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored privacy_gate did not import: {exc!r}")
    sys.exit(2)

STAMP = {"privacyScale": "canonical-2026-11"}
C = {"category": "book"}  # a category the enricher dispatches


def rec(**kw):
    out = dict(C)
    out.update(kw)
    return out


CASES = [
    ("arm0 canonical L3 refused", rec(privacy_level="L3", **STAMP), False),
    ("arm1 canonical L2 refused", rec(privacy_level="L2", **STAMP), False),
    ("arm2 canonical L1 allowed", rec(privacy_level="L1", **STAMP), True),
    ("arm3 control: stamped L0 allowed", rec(privacy_level="L0", **STAMP), True),
    ("arm4 unstamped L0 refused", rec(privacy_level="L0"), False),
    ("arm5a legacy 2 alone allowed", rec(compartment_level=2), True),
    ("arm5b legacy 4 alone allowed", rec(compartment_level=4), True),
    ("arm5c legacy 6 alone allowed", rec(compartment_level=6), True),
    ("arm6a legacy 0 refused (health floor)", rec(compartment_level=0), False),
    ("arm6b legacy 1 refused (personal location, base.py:58)", rec(compartment_level=1), False),
    ("arm6c legacy 3 refused", rec(compartment_level=3), False),
    ("arm6d legacy 5 refused", rec(compartment_level=5), False),
    ("arm7 unlevelled refused", rec(), False),
    ("arm8a stamped L0 health category refused", rec(category="health", privacy_level="L0", **STAMP), False),
    ("arm8b stamped L0 person category refused", rec(category="person", privacy_level="L0", **STAMP), False),
    ("arm8c stamped L0 dietary category refused", rec(category="dietary", privacy_level="L0", **STAMP), False),
    ("arm8d stamped L0 about a minor refused", rec(privacy_level="L0", about_minor=True, **STAMP), False),
]


def main() -> int:
    failures = 0
    for name, record, want_allowed in CASES:
        reason = outbound_refusal(record)
        ok = (reason is None) == want_allowed
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}: refusal={reason!r}")
    print(f"TOTAL {len(CASES)} arms, {failures} FAIL")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
