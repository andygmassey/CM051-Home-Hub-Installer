#!/usr/bin/env python3
"""The SHIPPED Whoop parser writes health data at the floor, and the shipped helper keeps it home.

Whoop data is health data (GDPR Art 9). The vendored parser defaulted to
compartment 2 (L2Trusted), which the vendored online look-up gate lets out. It
now writes numeric 0 whatever the caller passes, plus privacy_level "L3" and the
scale stamp under the shared table's field name (privacyScale). Grafted from
personal-world-graph #539; the helper, loader and table are CM041 #296 6c5f709.

Drives vendor/cm019_preferences/services (the real WhoopParser, ParsedPreference
and services/common/pwg_privacy.py), not a copy. Synthetic values only.
  arm 1  caller default None, 2 and 4 all give compartment 0, privacy_level "L3",
         and the stamp under privacyScale (and never under privacy_scale)
  arm 2  the shipped helper: owner_local serves it labelled "private"; every
         other table destination, and an undeclared one, withholds it
  arm 3  the three vendored privacy files match their sha256 pin
  arm 4  CONTROL: a stamped public L0 record leaves for every destination
Exit: 0 pass, 1 fail, 2 cannot-run (the vendored parser or helper did not import).
"""
from __future__ import annotations

import asyncio
import hashlib
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
COMMON = VENDOR / "common"
for p in (VENDOR / "ingest", COMMON):
    sys.path.insert(0, str(p))

try:
    import pwg_privacy
    from src.parsers.whoop import WhoopParser
except Exception as exc:  # noqa: BLE001 - cannot-run, reported with its reason
    print(f"CANNOT-RUN: vendored Whoop parser or helper did not import: {exc!r}")
    sys.exit(2)

FAILS: list[str] = []


def check(cond: bool, what: str) -> None:
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        FAILS.append(what)


def whoop_zip(d: Path) -> Path:
    z = d / "whoop_export.zip"
    header = ("Cycle start time,Workout start time,Activity name,Duration (min),Activity Strain,"
              "Energy burned (cal),Max HR (bpm),Average HR (bpm)\n")
    body = "".join(f"2025-01-{n:02d} 06:00:00,2025-01-{n:02d} 07:00:00,Running,40,11,400,170,140\n"
                   for n in range(1, 6))
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("workouts.csv", header + body)
    return z


def collect(agen):
    async def run():
        return [p async for p in agen]
    return asyncio.run(run())


def main() -> int:
    payloads = []
    with tempfile.TemporaryDirectory() as td:
        z = whoop_zip(Path(td))
        print("arm 1: the floor, whatever the caller passes")
        for default in (None, 2, 4):
            prefs = collect(WhoopParser().parse(z, default_compartment=default))
            check(len(prefs) >= 1, f"default={default}: {len(prefs)} record(s) produced")
            for p in prefs:
                pl = p.to_payload("synthetic-user")
                payloads.append(pl)
                check(pl.get("compartment_level") == 0, f"default={default}: compartment 0")
                check(pl.get("privacy_level") == "L3", f"default={default}: privacy_level L3")
                check(pl.get("privacyScale") == "canonical-2026-11" and "privacy_scale" not in pl,
                      f"default={default}: stamp under privacyScale only")
    print("arm 2: the shipped helper, per destination")
    others = [d for d in pwg_privacy.DESTINATIONS if d != "owner_local"]
    check(len(others) >= 5, f"{len(others)} non-owner destinations in the table")
    check(bool(payloads), f"{len(payloads)} payload(s) judged")
    for pl in payloads:
        check(pwg_privacy.outbound_ok(pl, destination="owner_local")
              and pwg_privacy.served_label(pl, destination="owner_local") == "private",
              "owner_local: served, labelled private")
        for d in others + ["somewhere-new"]:
            check(not pwg_privacy.outbound_ok(pl, destination=d), f"{d}: withheld")
        check(not pwg_privacy.outbound_ok(pl), "undeclared destination: withheld")
    print("arm 3: the vendored privacy files match their pin")
    pin = {}
    for line in (COMMON / "pwg_privacy.PIN").read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            k, v = line.split("\t")
            pin[k] = v
    for name in ("pwg_privacy.py", "privacy_scale.py", "privacy_scale_canonical.tsv"):
        got = hashlib.sha256((COMMON / name).read_bytes()).hexdigest()
        check(got == pin.get("sha256:" + name), f"{name} sha256 matches the pin")
    print("arm 4: CONTROL, a stamped public record leaves")
    public = {"privacy_level": "L0", pwg_privacy.CANONICAL_SCALE_KEY: pwg_privacy.CANONICAL_SCALE_VALUE}
    check(all(pwg_privacy.outbound_ok(public, destination=d) for d in pwg_privacy.DESTINATIONS),
          "stamped L0 leaves for every destination")
    print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failed check(s)")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
