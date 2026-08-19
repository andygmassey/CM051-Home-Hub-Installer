#!/usr/bin/env python3
"""A sweep that spent its whole allowance must not print ENRICHMENT COMPLETE.

THE DEFECT, introduced by #815 and measured at source on 35ab2d49.

`enrich_categories` gives each category a fair share of the remaining wall
clock so one dead third party cannot own the whole budget. When a category
stops on its share, `enrich_all` sets `stats.budget_exhausted = True`. The
merge loop then zeroed that flag before merging, on the stated grounds that
otherwise the sweep would "mark the whole pass exhausted after the first slow
category and stop".

MEASURED: nothing stops on it. `combined_stats.budget_exhausted` is local to
`enrich_categories` and has exactly ONE consumer in the shipping tree,
`cli.py:685`, which uses it to choose between

    ENRICHMENT PAUSED (allowance spent, more still owed)
    ENRICHMENT COMPLETE

The loop's own stopping condition is the `now >= deadline` check at the top,
which reads the clock. So the suppression bought no protection from
starvation. What it bought was a pass that spent its entire allowance, left
backlog in every category, and reported COMPLETE. That is the defect class
this whole service is being hardened against, one level up: machinery that
did not finish, reporting success.

WHAT THIS PINS

  1. A category truncated by its own share propagates "work is owed", so the
     sweep reports PAUSED.
  2. POSITIVE CONTROL: a sweep where NOTHING was truncated reports
     not-exhausted. Without this limb, "always True" passes limb 1 and makes
     COMPLETE unreachable for ever, which is the same lie inverted.
  3. RED PROOF against the REAL module, not a replica: the suppression
     statement is re-inserted by AST into a second copy of `enricher.py`, and
     that copy MUST fail limb 1. If re-inserting the defect changes nothing,
     this test cannot see the thing it exists to see and says so rather than
     passing.

No network, no Qdrant, no Oxigraph. `enrich_all` is stubbed, so what is under
test is the merge and reporting logic and nothing else.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import ast
import asyncio
import sys
import types
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
SRC = ENRICH / "src" / "enricher.py"

if not SRC.is_file():
    print(f"CANNOT RUN: enricher missing at {SRC}", file=sys.stderr)
    sys.exit(2)

sys.path.insert(0, str(ENRICH))

try:
    from src.enricher import EnrichmentService, EnrichmentStats
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)

PASS = FAIL = 0


def ok(m):
    global PASS
    print(f"  PASS  {m}")
    PASS += 1


def no(m):
    global FAIL
    print(f"  FAIL  {m}")
    FAIL += 1


def sweep(service_cls, truncate):
    """Run enrich_categories over 3 categories with enrich_all stubbed.

    `truncate` decides whether each stubbed category claims it stopped on its
    allowance. Returns the merged stats. The service is built with
    object.__new__ so no client, cache or HTTP session is constructed: this
    exercises the merge, not the enrichment.
    """
    svc = object.__new__(service_cls)

    async def fake_enrich_all(user_id, category=None, limit=100, deadline=None,
                              **kw):
        st = EnrichmentStats()
        st.total_processed = 3
        st.successful = 1
        st.budget_exhausted = truncate
        return st

    svc.enrich_all = fake_enrich_all
    return asyncio.run(svc.enrich_categories(
        user_id="synthetic-user",
        categories=["book", "movie_tv", "music"],
        limit_per_category=10,
        deadline=datetime.utcnow() + timedelta(seconds=60),
    ))


def load_mutated():
    """Re-insert the suppression into a second copy of the real module.

    AST, not text: no reformatting, no dependence on comment wording, and it
    fails loudly if the shape it expects is gone. Returns (module, inserted).
    """
    tree = ast.parse(SRC.read_text(encoding="utf-8"), str(SRC))
    fn = next((n for n in ast.walk(tree)
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
               and n.name == "enrich_categories"), None)
    if fn is None:
        return None, False

    inserted = False
    for parent in ast.walk(fn):
        body = getattr(parent, "body", None)
        if not isinstance(body, list):
            continue
        for i, stmt in enumerate(body):
            # the `stats = await self.enrich_all(...)` assignment
            if (isinstance(stmt, ast.Assign)
                    and isinstance(stmt.value, ast.Await)
                    and len(stmt.targets) == 1
                    and isinstance(stmt.targets[0], ast.Name)
                    and stmt.targets[0].id == "stats"):
                body.insert(i + 1, ast.Assign(
                    targets=[ast.Attribute(
                        value=ast.Name(id="stats", ctx=ast.Load()),
                        attr="budget_exhausted", ctx=ast.Store())],
                    value=ast.Constant(value=False)))
                inserted = True
                break
        if inserted:
            break
    if not inserted:
        return None, False

    ast.fix_missing_locations(tree)
    mod = types.ModuleType("src._enricher_with_defect_reinserted")
    mod.__package__ = "src"
    mod.__file__ = str(SRC)
    exec(compile(tree, str(SRC), "exec"), mod.__dict__)  # noqa: S102
    return mod, True


# ── 1. a truncated category means work is owed ────────────────────────────
merged = sweep(EnrichmentService, truncate=True)
if merged.budget_exhausted:
    ok("a category truncated by its share reports PAUSED, not COMPLETE")
else:
    no("a sweep that spent its whole allowance would print ENRICHMENT COMPLETE")

# ── 2. POSITIVE CONTROL: nothing truncated is genuinely complete ──────────
clean = sweep(EnrichmentService, truncate=False)
if clean.budget_exhausted:
    no("POSITIVE CONTROL BROKEN: an untruncated sweep also reports PAUSED, so "
       "COMPLETE is now unreachable and limb 1 proves nothing")
else:
    ok("POSITIVE CONTROL: a sweep with nothing truncated still reports COMPLETE")

# ── 3. RED PROOF against the real module ──────────────────────────────────
mutated, inserted = load_mutated()
if not inserted:
    no("RED PROOF IMPOSSIBLE: no `stats = await ...` assignment found in "
       "enrich_categories, so the defect cannot be re-inserted and limbs 1-2 "
       "are unverified")
else:
    reintroduced = sweep(mutated.EnrichmentService, truncate=True)
    if reintroduced.budget_exhausted:
        no("RED PROOF FAILED: re-inserting `stats.budget_exhausted = False` "
           "changed NOTHING, so this test cannot see the defect it exists to "
           "find and its green on the real tree is worth nothing")
    else:
        ok("RED PROOF: re-inserting the suppression makes limb 1 fail")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
