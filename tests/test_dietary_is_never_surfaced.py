#!/usr/bin/env python3
"""RATCHET: the `dietary` category (grocery diet signals) is never read for display.

Diet-shaped grocery signals are stored as category `dietary` at compartment 0, a
health-adjacent inference (GDPR Art. 9 adjacent) that must never be derived,
shown on the Front Page / editor cards, used in the brief, or nudged on.

  arm 1  no derive reader row selects `dietary` (vendored registry)
  arm 2  no derive, editor-compiler or brief code names the category, except lines
         tagged `dietary-guard` (the two places that REFUSE it)
  arm 3  BEHAVIOUR: the preference projector (which feeds the Front Page and the
         brief) drops a dietary point and keeps a normal one; the interest profile
         classes the category as L3
  arm 4  the scanner is proven able to FAIL: a fake reader row and fake code both
         turn it red
Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
try:
    import yaml
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}")
    sys.exit(2)

DERIVE = REPO / "vendor/cm019_preferences/services/enrich/src/derive"
CODE_ROOTS = [DERIVE, REPO / "vendor/cm059_editor/compiler", REPO / "vendor/cm041/assistant_api"]
QUOTED = re.compile(r"""["']dietary["']""")
PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


def offending_rows(text):
    return [r["dimension"] for r in (yaml.safe_load(text) or [])
            if "dietary" in [str(c).lower() for c in r.get("select_categories", [])]
            or str(r.get("category", "")).lower() == "dietary"]


def offending_code(roots):
    hits = []
    for root in roots:
        for f in sorted(Path(root).rglob("*.py")):
            if "/tests/" in str(f) or f.name.startswith("test_"):
                continue
            for n, line in enumerate(f.read_text(errors="ignore").splitlines(), 1):
                if QUOTED.search(line) and "dietary-guard" not in line:
                    hits.append(f"{f.relative_to(REPO) if f.is_relative_to(REPO) else f}:{n}")
    return hits


check(all(r.is_dir() for r in CODE_ROOTS), "arm 2: all three scanned roots exist (a missing root would scan nothing)")
n_files = sum(1 for r in CODE_ROOTS for _ in r.rglob("*.py"))
check(n_files > 20, f"arm 2: the scan examined {n_files} python files, not zero")
check(offending_rows((DERIVE / "readers.yaml").read_text()) == [], "arm 1: no reader row selects dietary")
check(offending_code(CODE_ROOTS) == [], f"arm 2: no derive/editor/brief code names the category ({offending_code(CODE_ROOTS)})")

sys.path.insert(0, str(REPO / "vendor/cm059_editor"))
from compiler import project_preferences as pp  # noqa: E402
from compiler import interest_profile as ip  # noqa: E402


def pt(cat, subj):
    return {"id": "x", "payload": {"preference_id": f"id-{subj}", "preference_type": "Like", "category": cat,
                                    "subject": subj, "strength": 0.5, "source": "food_evidence"}}


lines, skipped = pp.to_triples([pt("food", "Synthetic Trattoria"), pt("dietary", "dietary signal: vegan"), pt("Dietary", "dietary signal: halal")])
dump = "\n".join(lines)
check("Synthetic Trattoria" in dump, "arm 3: control, a normal food point is projected")
check("vegan" not in dump and "halal" not in dump and skipped == 2, "arm 3: dietary points are NOT projected to the Front Page / brief graph")
check(ip.classify_privacy("dietary", "food_evidence", []) == "L3", "arm 3: the interest profile classes dietary as L3")

fake_row = (DERIVE / "readers.yaml").read_text() + (
    "\n- dimension: food.diet\n  domain: food\n  category: food\n  kind: qdrant_field\n"
    "  select_categories: [dietary]\n  field: extra.diet_signal\n")
check(offending_rows(fake_row) == ["food.diet"], "arm 4: a fake reader row turns the ratchet RED")
with tempfile.TemporaryDirectory() as d:
    (Path(d) / "card.py").write_text("CARDS = ['food', 'dietary']\n")
    check(len(offending_code([d])) == 1, "arm 4: fake card code naming the category turns the ratchet RED")
    (Path(d) / "card.py").write_text("CARDS = ['dietary']  # dietary-guard\n")
    check(offending_code([d]) == [], "arm 4: control, a guard-tagged line is the only allowed mention")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
