#!/usr/bin/env python3
"""Online enrichment never sends an L2 subject, or a legacy 2/4/6 one, to ``others``.

The vendored enrich privacy gate decides, per item, whether the item's subject may
leave the Mac in an online look-up (a third party: destination ``others``). Before
this fix it allowed canonical L2 (privacy_level "L2") and legacy compartment
integers 2, 4 and 6 (compartment_level alone) through.

Drives the REAL vendored ``privacy_gate.outbound_refusal`` (the function the
enricher calls per item), not a copy. Synthetic values only.

  arm 0  canonical L3 is refused at others
  arm 1  canonical L2 is refused at others (Andy 2026-11-18: L2 never leaves the Mac)
  arm 1b canonical L1 is refused at others today (CB135-ENRICHMENT-L1-DESTINATION)
  arm 2  legacy compartment 2 alone is refused at others           (leak on main)
  arm 3  legacy compartment 4 alone is refused at others           (leak on main)
  arm 4  legacy compartment 6 alone is refused at others           (leak on main)
  arm 5  control: a stamped canonical L0 is allowed to others      (must stay allowed)

Exit: 0 all arms pass, 1 an arm fails, 2 cannot-run (the vendored gate did not import).
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

# The shared scale stamp (services/common/privacy_scale_canonical.tsv [scale_stamp]).
STAMP_FIELD = "privacyScale"
STAMP_VALUE = "canonical-2026-11"

ARMS = [
    ("arm0 canonical L3 refused at others",
     {"privacy_level": "L3", STAMP_FIELD: STAMP_VALUE}, False),
    ("arm1 canonical L2 refused at others",
     {"privacy_level": "L2", STAMP_FIELD: STAMP_VALUE}, False),
    # CB135-ENRICHMENT-L1-DESTINATION: Andy's rule lets L1 subjects be looked up,
    # but the shared scale table (privacy_scale_canonical.tsv, pinned across 5 repos)
    # has no enrichment destination yet, so ``others`` refuses L1 (redacted only).
    # 135 adds the dedicated enrichment row; until then this arm asserts today's refusal.
    ("arm1b canonical L1 refused at others (CB135-ENRICHMENT-L1-DESTINATION)",
     {"privacy_level": "L1", STAMP_FIELD: STAMP_VALUE}, False),
    ("arm2 legacy compartment 2 refused at others",
     {"compartment_level": 2}, False),
    ("arm3 legacy compartment 4 refused at others",
     {"compartment_level": 4}, False),
    ("arm4 legacy compartment 6 refused at others",
     {"compartment_level": 6}, False),
    ("arm5 control: stamped canonical L0 allowed to others",
     {"privacy_level": "L0", STAMP_FIELD: STAMP_VALUE}, True),
]


def main() -> int:
    failures = 0
    for name, record, want_allowed in ARMS:
        reason = outbound_refusal(record)
        allowed = reason is None
        ok = allowed == want_allowed
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}: refusal={reason!r}")
    print(f"TOTAL {len(ARMS)} arms, {failures} FAIL")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
