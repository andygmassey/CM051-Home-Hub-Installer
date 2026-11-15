"""A Front Page card must never appear without a working action (walk #27).

The app routes only open_interest_profile. A consent card carries
consent_grant:<key>, which the Doctor feedback route rejects, so the card
showed with no button. Until the consent writer is reachable the vendored
CM059 front page holds consent cards back. Proven on the copy that ships.

Synthetic data only. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
from __future__ import annotations

import pathlib
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm059_editor"
if not (VENDOR / "compiler").is_dir():
    print(f"CANNOT-RUN: {VENDOR}/compiler missing")
    sys.exit(2)
sys.path.insert(0, str(VENDOR))

try:
    from compiler import frontpage as fp
    from compiler import scout_external as se
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: import failed: {exc!r}")
    sys.exit(2)

NOW = datetime(2026, 10, 14, 9, 0, tzinfo=timezone.utc)
fails = []


def build(scout_cards):
    return fp.build_frontpage({"interests": [], "stats": {}}, now=NOW,
                              scout_cards=scout_cards)


# Control: a consent card of the real shape, built by the real constructor,
# must exist (else the filter has nothing to prove).
import inspect
src = inspect.getsource(se)
if '"consent_grant:' not in src and "consent_grant:{" not in src:
    print("CANNOT-RUN: consent card constructor not found")
    sys.exit(2)

consent = fp._make_card(
    "consent", "scout_consent::demo_key", title="Keep you posted?",
    body="Demo.", now=NOW, domain="Demo", priority=fp.BAND_CONSENT,
    action={"label": "Yes", "kind": "consent_grant:demo_key"},
    source="ostler:test", privacy="L1")
# Control: the card exists before the feed assembly.
if consent.get("kind") != "consent":
    print("CANNOT-RUN: control card is not kind consent")
    sys.exit(2)
out = build([consent])
kinds = [c.get("kind") for c in out["cards"]]
if "consent" in kinds:
    fails.append(f"consent card reached the feed: {kinds}")
if out["stats"].get("consent_cards"):
    fails.append("consent_cards stat non-zero")
for c in out["cards"]:
    if c.get("kind") == "consent":
        fails.append("consent in cards")

print("FAIL" if fails else "PASS", fails)
sys.exit(1 if fails else 0)
