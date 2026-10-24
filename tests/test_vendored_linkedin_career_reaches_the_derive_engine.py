#!/usr/bin/env python3
"""The owner's LinkedIn career reaches the derive engine, from the SHIPPED parser.

Positions.csv and the Industry column of Profile.csv used to be read by nothing
that writes a preference, so "work" could never be derived. This drives the
vendored parser (vendor/cm019_preferences/services/ingest) on synthetic exports,
then feeds its output through the vendored derive registry:

  arm 1  Positions.csv -> work.role and work.employer; the free-text Description
         is not read.
  arm 2  Profile.csv -> work.industry, and NOTHING else in the file is read
         (name, birth date, address are absent from every parsed record).
  arm 3  Skills.csv, Positions.csv and Profile.csv in one export directory all
         reach the parser (before: the directory branch read three other files).
  arm 4  CONTROL: a foreign Profile.csv / Positions.csv (other columns) is NOT
         claimed, so the generic CSV parser keeps it.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
try:
    import aiofiles  # noqa: F401
    import pydantic_settings  # noqa: F401
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install aiofiles pydantic-settings pyyaml")
    sys.exit(2)

sys.path[:0] = [str(TREE / "services" / "ingest"), str(TREE / "services" / "common"),
                str(TREE / "services" / "enrich" / "src")]
from src.parsers.linkedin import LinkedInParser  # noqa: E402
from derive.config import build_readers, load_dimensions  # noqa: E402
from derive.engine import Aggregator  # noqa: E402

PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


def parse(path):
    async def go():
        return [p async for p in LinkedInParser().parse(path, default_compartment=1)]
    return asyncio.run(go())


class Store:
    def __init__(self, prefs):
        self.points = [{"id": f"p{i}", "payload": {
            "category": p.category, "subject": p.subject, "source": "linkedin",
            "strength": p.strength, "observed_at": None, "extra": p.extra}}
            for i, p in enumerate(prefs)]

    def scroll(self, categories, fields):
        return [p for p in self.points if not categories or p["payload"]["category"] in categories]

    def sparql(self, q):
        return []


def derived(prefs):
    items = [i for r in build_readers(Store(prefs)) for i in r.read("u")]
    nodes = Aggregator(load_dimensions()).aggregate(items, now=datetime(2026, 10, 22, tzinfo=timezone.utc))
    return {(n.dimension, n.subject) for n in nodes}


d = Path(tempfile.mkdtemp())
(d / "Positions.csv").write_text(
    "Company Name,Title,Description,Location,Started On,Finished On\n"
    "alpha-works,synthetic-foreman,secret-free-text,X,Mar 2019,\n"
    "beta-works,synthetic-apprentice,,X,2015,Feb 2019\n")
PROFILE_HEADER = ",".join(
    c.title() for c in ("first name", "last name", "birth date", "address", "headline", "industry"))
(d / "Profile.csv").write_text(
    PROFILE_HEADER + "\n" + "zed1,quux1,Jan 1,9 addr-x,hl-text,synthetic-mining\n")
(d / "Skills.csv").write_text("Name\nsynthetic-welding\n")

print("arm 1: positions")
pos = parse(d / "Positions.csv")
got = derived(pos)
check(("work.role", "synthetic-foreman") in got and ("work.employer", "alpha-works") in got,
      "role and employer derive")
check("secret-free-text" not in repr([p.__dict__ for p in pos]), "Description is not read")

print("arm 2: profile industry only")
prof = parse(d / "Profile.csv")
check(("work.industry", "synthetic-mining") in derived(prof), "industry derives")
dump = repr([p.__dict__ for p in prof])
check(not any(x in dump for x in ("zed1", "quux1", "Jan 1", "addr-x", "hl-text")),
      "name, birth date, address and headline are not read")

print("arm 3: a directory export reaches all three")
kinds = {p.extra["data_type"] for p in parse(d)}
check({"linkedin_skill", "linkedin_position", "linkedin_profile_industry"} <= kinds,
      f"directory export kinds: {sorted(kinds)}")
check(("work.skill", "synthetic-welding") in derived(parse(d)), "skill derives")

print("arm 4: foreign files are not claimed")
o = Path(tempfile.mkdtemp())
(o / "Profile.csv").write_text("a,b\n1,2\n")
(o / "Positions.csv").write_text("x,y\n1,2\n")
lp = LinkedInParser()
check(not lp.can_parse(o / "Profile.csv") and not lp.can_parse(o / "Positions.csv"),
      "foreign Profile.csv and Positions.csv stay with the generic parser")
check(lp.can_parse(d / "Positions.csv") and lp.can_parse(d / "Profile.csv"),
      "LinkedIn's own are claimed (control: the predicate can say yes)")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
