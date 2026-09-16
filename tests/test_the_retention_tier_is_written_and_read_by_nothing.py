#!/usr/bin/env python3
"""Guard: `retention_tier` is DECORATIVE, and must not quietly stop being so.

WHAT IS TRUE, measured 2026-09-16 on origin/main.

`vendor/cm048_pipeline/src/ingest.py` computes a `retention_tier` for every
conversation and stamps it onto every Qdrant point and every SQLite
`observations` row -- the column is even `TEXT NOT NULL`. `git grep -n
retention_tier -- .` returns 11 hits: 4 in that file (payload, DDL, INSERT,
classifier) and 7 in CM048 prose and prompt templates.

READERS: 0. TESTS: 0. SWEEPERS: 0. Nothing anywhere in the repo deletes,
ages out, or even branches on a tier. So a record stamped `tier-3-years` is
kept exactly as long as one stamped `tier-1-forever`, which is forever, and
THERE IS NO RIGHT-TO-ERASURE MECHANISM BEHIND THE TIERS.

`PLAN.md` pointed at `HR015/DATA_RETENTION.md` for the cross-cutting spec.
No file matching `*retention*` exists in the repo and none ever did.

WHY THIS TEST EXISTS RATHER THAN A SWEEPER. A sweeper DELETES customer data.
It needs a designed, consented, reversible mechanism and a restore story; it
is not a follow-on commit. What this pins instead is that the gap stays
VISIBLE and stays MEASURED:

  * every tier value written is a key of the single `RETENTION_TIERS`
    definition, so the durations stop living inside the names (CM048's own
    prompt writes "tier-1 forever" with a space -- a form no code produces
    and no reader could match);
  * the reader count is RE-MEASURED here, not quoted. The day somebody adds
    a reader, this test fails and tells them to update the register rather
    than letting a half-built retention story ship quietly;
  * the register entry stays on the record.

Network-free. Reads `ingest.py` with `ast` rather than importing it: the
module refuses to load without `ostler_security`, by design.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INGEST = REPO_ROOT / "vendor" / "cm048_pipeline" / "src" / "ingest.py"

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"ok: {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        FAILURES.append(msg)


check(INGEST.is_file(), f"the writer exists at {INGEST.relative_to(REPO_ROOT)}")
if not INGEST.is_file():
    raise SystemExit(1)

tree = ast.parse(INGEST.read_text())


def module_assign(name: str):
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for t in targets:
                if isinstance(t, ast.Name) and t.id == name:
                    return node.value
    return None


# ── 1. The tier names and their durations live in ONE place ──────────
tiers_node = module_assign("RETENTION_TIERS")
check(tiers_node is not None,
      "RETENTION_TIERS is defined at module level in ingest.py")
tiers = ast.literal_eval(tiers_node) if tiers_node is not None else {}
check(len(tiers) >= 3,
      f"denominator: RETENTION_TIERS defines {len(tiers)} tiers (expected 3+)")
check(all(v is None or isinstance(v, int) for v in tiers.values()),
      "each tier carries a duration in days, or None for 'kept indefinitely' "
      "-- the name is no longer the entire specification")

# ── 2. Every value the classifier can emit is one of those keys ──────
#
# This is the invariant that would have caught "tier-1 forever" with a
# space. Read the real function body, not a copy of the literals.
fn = next((n for n in ast.walk(tree)
           if isinstance(n, ast.FunctionDef) and n.name == "_retention_tier_for"),
          None)
check(fn is not None, "_retention_tier_for is present")
returned = {
    n.value.value for n in ast.walk(fn)
    if isinstance(n, ast.Return)
    and isinstance(n.value, ast.Constant)
    and isinstance(n.value.value, str)
} if fn is not None else set()
check(len(returned) >= 3,
      f"denominator: the classifier can return {len(returned)} distinct "
      f"tier values (expected 3+)")
check(returned <= set(tiers),
      f"every value the classifier returns is a defined tier "
      f"(undefined: {sorted(returned - set(tiers))})")

coach_node = module_assign("COACH_RETENTION_TIER")
check(coach_node is not None,
      "the coach path's tier is a named constant, not an inline literal")
coach = ast.literal_eval(coach_node) if coach_node is not None else None
check(coach in tiers,
      f"and it is a defined tier (got {coach!r})")

# NEGATIVE CONTROL for the two arms above. If `returned <= set(tiers)` were
# satisfied by an empty `returned`, or by a `tiers` that contained
# everything, it would prove nothing. A value that is deliberately NOT a
# tier must be rejected by the same predicate.
check("tier-1 forever" not in tiers,
      "CONTROL: the space-separated form CM048's own prompt writes is NOT "
      "a defined tier, so the membership check above can fail")

# ── 3. THE READER COUNT, re-measured rather than quoted ──────────────
SCAN_ROOTS = [REPO_ROOT / "vendor", REPO_ROOT / "scripts"]
WRITER = INGEST.resolve()

code_hits: list[str] = []
scanned = 0
for root in SCAN_ROOTS:
    for path in root.rglob("*.py"):
        if "__pycache__" in path.parts:
            continue
        scanned += 1
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            # A file we could not read is not a file with no readers.
            FAILURES.append(f"could not read {path}")
            continue
        if "retention_tier" in text and path.resolve() != WRITER:
            code_hits.append(str(path.relative_to(REPO_ROOT)))

# DENOMINATOR. A zero reader count and a scan that examined nothing print
# identically; this is the difference.
check(scanned > 100,
      f"denominator: {scanned} Python files under vendor/ and scripts/ were "
      f"examined for a reader")
# POSITIVE CONTROL: the same scan, same shape, for a token that MUST be
# found. If this comes back empty the scan is broken and the zero above is
# meaningless.
control = sum(
    1 for root in SCAN_ROOTS for p in root.rglob("*.py")
    if "__pycache__" not in p.parts
    and "privacy_level" in p.read_text(encoding="utf-8", errors="replace")
)
check(control > 10,
      f"CONTROL: the same scan finds 'privacy_level' in {control} files, so "
      f"an empty result for retention_tier is a real absence")

check(not code_hits,
      f"retention_tier is still read by NO Python file outside its writer. "
      f"If this fails, a reader has appeared ({code_hits}) -- update "
      f"PRIVACY_ENFORCEMENT_GAPS.md entry 2 and say what it does, because "
      f"a partial retention implementation is worse than an honest absence")

# ── 4. No sweeper has appeared without the register noticing ─────────
sweeper_pat = re.compile(r"retention_tier", re.IGNORECASE)
plists = list(REPO_ROOT.rglob("*.plist"))
check(len(plists) > 5,
      f"denominator: {len(plists)} launchd plists were examined")
scheduled = [
    str(p.relative_to(REPO_ROOT)) for p in plists
    if sweeper_pat.search(p.read_text(encoding="utf-8", errors="replace"))
]
check(not scheduled,
      f"no scheduled job acts on a retention tier (found {scheduled})")

# ── 5. The dangling spec pointer is gone ─────────────────────────────
#
# A file that is read first must not point at facts the reader cannot
# reach. PLAN.md sent readers to HR015/DATA_RETENTION.md, which does not
# exist and never did.
# Scoped to DOCUMENTS, and excluding tests/ -- this file's own name
# matches the pattern, and a test that finds itself is not evidence.
retention_docs = [
    str(p.relative_to(REPO_ROOT)) for p in REPO_ROOT.rglob("*.md")
    if ".git" not in p.parts
    and "tests" not in p.parts
    and "retention" in p.name.lower()
]
check(not retention_docs,
      f"the retention spec DATA_RETENTION.md still does not exist "
      f"(found {retention_docs})")
# POSITIVE CONTROL: the same rglob must find the document this change
# added, or "no retention doc" would just mean "no documents were seen".
md_seen = sum(1 for p in REPO_ROOT.rglob("*.md") if ".git" not in p.parts)
check(md_seen > 20,
      f"CONTROL: the same search examined {md_seen} markdown files")
plan = REPO_ROOT / "vendor" / "cm048_pipeline" / "PLAN.md"
plan_text = plan.read_text() if plan.is_file() else ""
check("does not exist" in plan_text or "NOT IMPLEMENTED" in plan_text,
      "PLAN.md says plainly that the retention spec is absent rather than "
      "pointing at a file nobody can open")

# ── 6. The gap stays on the record ───────────────────────────────────
gaps = REPO_ROOT / "PRIVACY_ENFORCEMENT_GAPS.md"
check(gaps.is_file(), "PRIVACY_ENFORCEMENT_GAPS.md exists")
gaps_text = gaps.read_text() if gaps.is_file() else ""
check("retention_tier" in gaps_text,
      "and it records the retention gap")
check("right-to-erasure" in gaps_text.lower()
      or "erasure" in gaps_text.lower(),
      "and states the consequence: no erasure mechanism stands behind the "
      "tiers, so they must not be described to a customer as though one does")

print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} check(s)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: the retention tier is decorative, said so, and still measured")
