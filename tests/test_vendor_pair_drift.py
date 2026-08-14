#!/usr/bin/env python3
"""Cross-artefact drift gate: the copy that RUNS vs the copy that is REVIEWED.

THE FAULT THIS EXISTS FOR
-------------------------
Two hand-maintained copies of the same code live in two places, one of them
asserting in its own header that it is "a VERBATIM copy ... Do not diverge",
and nothing compares them. Measured 2026-08-14:

    sealed tick (executes)     0 FDA preflight tokens   control token 13
    vendored tick (dormant)   16 FDA preflight tokens   control token 17

The FDA preflight was reasoned about, fixed and reviewed in the vendored copy.
The daemon forks the sealed copy. So the fix was never in the code that ran, and
a gate written specifically to make the check and the defect share a surface was
pointed at the dormant one and would have stayed green forever.

An assertion in a comment is not a gate.

WHY NOT A BYTE DIFF
-------------------
The two sides legitimately differ: 222 lines sealed against 268 vendored,
different headers, no SOURCE_DIR placeholder in the seal. A diff would be red on
a correct tree, and a gate that is red on a correct tree gets switched off. That
is exactly how the prose comment ended up being the only enforcement anyone
could stomach.

So the invariant is SURVIVAL, not equality: every behavioural guarantee a
customer depends on must be present on BOTH sides. The set is explicit and
appendable (tests/tick_seal_invariants.tsv), each row drawn from a fault that
actually happened, rather than derived from a diff.

WHAT THIS GATE REFUSES TO DO
----------------------------
* It does not hardcode the path to the executing artefact. The sealed location
  is declared in the registry and resolved at run time. A gate holding a literal
  path goes green comparing nothing the moment that path moves, which is the
  same failure one constant along.
* It does not silently skip. An `enforced` pair whose side cannot be resolved is
  a FAILURE, never a pass, because a gate that cannot see what it enforces has
  no opinion worth having.
* It does not hide the denominator. Every run prints pairs declared, resolved,
  enforced and unreconciled, because a gate covering one of three pairs while
  looking green is worse than no gate: it licenses the belief that the other two
  are checked.
* It does not collapse direction. "Present in the source of truth, absent in the
  artefact that runs" is a shipped regression. The reverse is an artefact that
  has grown a guarantee its source lacks. Opposite faults, opposite fixes, so
  the output names which side each miss was found on.

RELATIONSHIP TO tests/test_no_divergent_vendor_twin.sh
------------------------------------------------------
That gate is a SIBLING, not a duplicate, and neither subsumes the other. It
compares vendor/<pkg> against a top-level <pkg> twin INSIDE this repo. This one
compares this repo against artefacts OUTSIDE it: the signed app bundle and a
sibling repo. Do not merge them; they read different surfaces.

MODES
-----
    (default)        run what can be resolved, report the gap, exit 0. For CI,
                     where no app bundle exists.
    --require-full   any unresolved `enforced` pair is a failure. THIS is what
                     the cut must use. run_all_cut_gates.sh passes it.
"""
from __future__ import annotations

import glob
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REGISTRY = REPO / "tests" / "vendor_pair_registry.tsv"

GREEN, RED, YELLOW, DIM, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def rows(path: Path) -> list[dict]:
    """Parse a tab-separated manifest, skipping comments and the header."""
    out: list[dict] = []
    header: list[str] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if header is None:
            header = parts
            continue
        out.append(dict(zip(header, parts)))
    return out


def expand(pattern: str) -> tuple[list[Path], str | None]:
    """Resolve a registry glob. Returns (paths, unresolved_reason)."""
    for var in ("OSTLER_ASSISTANT_DIR", "OSTLER_APP_PATH", "HR015_ROOT"):
        token = f"${var}"
        if token in pattern:
            value = os.environ.get(var, "")
            if not value:
                return [], f"{var} is not set"
            pattern = pattern.replace(token, value)
    if not pattern.startswith("/"):
        pattern = str(REPO / pattern)
    hits = sorted(Path(p) for p in glob.glob(pattern))
    if not hits:
        return [], f"no file matched {pattern}"
    return hits, None


PAIR_MAP = REPO / "tests" / "tick_pair_map.tsv"


def check_invariant_survival(pair: dict, a: list[Path], b: list[Path]) -> list[str]:
    """Compare declared pairs only.

    The pairing is READ, never inferred. The two naming schemes do not line up
    (email keeps its "-bundle" suffix, the other three drop it), so any rule that
    derives one name from the other is wrong for some feed -- and a mis-derived
    pair compares two unrelated files and then reports "no drift" confidently.
    tests/tick_pair_map.tsv carries the mapping and how it was established.
    """
    manifest = rows(REPO / pair["manifest"])
    pmap = rows(PAIR_MAP)
    by_dir = {p.parent.name: p for p in a}       # release/ingest-ticks/<feed>/tick.sh
    by_base = {p.name: p for p in b}             # vendor/<pkg>/bin/<feed>-bundle-tick.sh
    failures: list[str] = []

    paired = [r for r in pmap if r["status"] == "paired"]
    unpaired = [r for r in pmap if r["status"] == "unpaired"]

    # UNPAIRED IS A STEADY STATE, NOT A FAILURE -- but it is never silent.
    # "no counterpart exists" and "the counterpart went missing" print
    # identically if you do not say which one you mean.
    print(f"    feeds: {len(by_dir)} executing, {len(by_base)} vendored, "
          f"{len(paired)} declared pairs, {len(unpaired)} declared unpaired")
    if unpaired:
        print(f"    {DIM}unpaired (daemon-only, expected): "
              f"{', '.join(r['feed_dir'] for r in unpaired)}{OFF}")

    # A feed on disk that the map does not mention at all is a REAL gap: the map
    # has gone stale against the tree, and an undeclared feed is an unchecked one.
    undeclared = sorted(set(by_dir) - {r["feed_dir"] for r in pmap})
    for u in undeclared:
        failures.append(f"{u}: executing feed is not declared in tick_pair_map.tsv "
                        f"-- the map is stale, so this feed is unchecked")

    for r in paired:
        k, vb = r["feed_dir"], r["vendored_basename"]
        if k not in by_dir:
            failures.append(f"{k}: declared paired but no executing tick resolved")
            continue
        if vb not in by_base:
            failures.append(f"{k}: declared paired but vendored {vb} did not resolve")
            continue
        text_a = by_dir[k].read_text(encoding="utf-8", errors="replace")
        text_b = by_base[vb].read_text(encoding="utf-8", errors="replace")
        for inv in manifest:
            if inv["feed"] not in ("*", k):
                continue
            in_a = re.search(inv["pattern"], text_a) is not None
            in_b = re.search(inv["pattern"], text_b) is not None
            if in_a and in_b:
                continue
            # DIRECTION is the whole point: which side is missing it?
            if in_b and not in_a:
                where = (f"MISSING from {pair['side_a_label']}, present in "
                         f"{pair['side_b_label']}  <- a shipped regression")
            elif in_a and not in_b:
                where = (f"MISSING from {pair['side_b_label']}, present in "
                         f"{pair['side_a_label']}  <- the artefact grew a guarantee "
                         f"its source of truth lacks")
            else:
                where = "MISSING from BOTH sides"
            failures.append(f"{k}: {inv['id']} {where}\n        why: {inv['why']}")
    return failures


def _names_from(path: Path) -> tuple[list[str], str]:
    """Extract a declared name-list from a file. Returns (names, how).

    The two sides are in different languages, so extraction is per-file and
    deliberately narrow: a loose pattern that silently matches nothing yields an
    empty list, and two empty lists compare EQUAL. That is a gate that passes by
    finding nothing, so each extractor reports its own count and the caller
    refuses a zero.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".rs":
        # `fn dir_name` match arms:  Self::Foo => "foo-bar",
        block = re.search(r"fn dir_name.*?\n    \}", text, re.S)
        scope = block.group(0) if block else ""
        return re.findall(r'=>\s*"([a-z][a-z0-9-]*)"', scope), "Rust dir_name match arms"
    # bash:  INGEST_SOURCES=( ... )
    block = re.search(r"INGEST_SOURCES=\((.*?)\)", text, re.S)
    scope = block.group(1) if block else ""
    return re.findall(r"^\s*([a-z][a-z0-9-]*)\s*$", scope, re.M), "INGEST_SOURCES array"


def check_list_parity(pair: dict, a: list[Path], b: list[Path]) -> list[str]:
    na, how_a = _names_from(a[0])
    nb, how_b = _names_from(b[0])
    print(f"    {pair['side_a_label']}: {len(na)} names ({how_a})")
    print(f"    {pair['side_b_label']}: {len(nb)} names ({how_b})")
    # REFUSE A VACUOUS PASS. Two empty lists are equal, and an extractor that
    # matched nothing looks exactly like a list that is legitimately empty.
    if not na or not nb:
        return [f"{pair['pair_id']}: an extractor returned ZERO names "
                f"({how_a}={len(na)}, {how_b}={len(nb)}). Two empty lists compare "
                f"equal, so this is a broken reader, not a passing gate."]
    out = []
    for miss in sorted(set(nb) - set(na)):
        out.append(f"{miss}: in {pair['side_b_label']}, absent from {pair['side_a_label']}")
    for miss in sorted(set(na) - set(nb)):
        out.append(f"{miss}: in {pair['side_a_label']}, absent from {pair['side_b_label']}"
                   f"  <- seals nothing; the daemon will fork a tick that was never bundled")
    return out


def check_size_report(pair: dict, a: list[Path], b: list[Path]) -> list[str]:
    for pa, pb in zip(a, b):
        sa, sb = pa.stat().st_size, pb.stat().st_size
        delta = sa - sb
        print(f"    {pair['side_a_label']}: {sa} bytes")
        print(f"    {pair['side_b_label']}: {sb} bytes")
        print(f"    delta: {delta:+d} bytes "
              f"({'A larger' if delta > 0 else 'B larger' if delta else 'identical'})")
    return []


def main() -> int:
    require_full = "--require-full" in sys.argv
    if not REGISTRY.exists():
        print(f"{RED}registry missing: {REGISTRY}{OFF}", file=sys.stderr)
        return 2

    pairs = rows(REGISTRY)
    declared = len(pairs)
    resolved = unresolved = 0
    failures: list[str] = []
    unresolved_enforced: list[str] = []

    print(f"vendor-pair drift gate  ({'CUT mode, full coverage required' if require_full else 'CI mode, reports gaps'})")
    print(f"registry: {REGISTRY.relative_to(REPO)}  --  {declared} pair(s) declared\n")

    for pair in pairs:
        pid, status, kind = pair["pair_id"], pair["status"], pair["kind"]
        print(f"  [{status}] {pid}  ({kind})")
        a, why_a = expand(pair["side_a_glob"])
        b, why_b = expand(pair["side_b_glob"])
        if why_a or why_b:
            unresolved += 1
            reason = why_a or why_b
            side = pair["side_a_label"] if why_a else pair["side_b_label"]
            if status == "enforced":
                unresolved_enforced.append(f"{pid}: {side} unresolved -- {reason}")
                print(f"    {RED if require_full else YELLOW}UNRESOLVED{OFF}: {side} -- {reason}")
            else:
                print(f"    {DIM}unresolved{OFF}: {side} -- {reason}")
            continue
        resolved += 1
        checker = {
            "invariant_survival": check_invariant_survival,
            "list_parity": check_list_parity,
            "size_report": check_size_report,
        }.get(kind)
        if checker is None:
            failures.append(f"{pid}: unknown kind '{kind}' -- a registry row this "
                            f"gate cannot execute is not a checked row")
            print(f"    {RED}UNKNOWN KIND{OFF}: {kind}")
            continue
        found = checker(pair, a, b)
        if found:
            failures.extend(f"{pid}: {f}" for f in found)
            for f in found:
                print(f"    {RED}DRIFT{OFF}  {f}")
        else:
            print(f"    {GREEN}ok{OFF}")
        print()

    enforced = sum(1 for p in pairs if p["status"] == "enforced")
    unrec = declared - enforced
    print("-" * 68)
    print(f"DENOMINATOR  declared {declared}   resolved {resolved}   "
          f"unresolved {unresolved}   enforced {enforced}   unreconciled {unrec}")
    if unrec:
        print(f"{YELLOW}NOT ENFORCED{OFF}: {unrec} declared pair(s) are `unreconciled` -- "
              f"reported above, but drift in them does NOT fail this gate.")

    if failures:
        print(f"\n{RED}FAIL{OFF}: {len(failures)} invariant(s) did not survive.")
        return 1
    if unresolved_enforced:
        if require_full:
            print(f"\n{RED}FAIL{OFF}: an enforced pair could not be resolved. "
                  f"A gate that cannot see what it enforces must not pass.")
            for u in unresolved_enforced:
                print(f"  {u}")
            print("\n  For the ingest_ticks pair, set OSTLER_APP_PATH to the built "
                  "Ostler.app whose sealed ticks the daemon forks.")
            return 1
        print(f"\n{YELLOW}INCOMPLETE{OFF}: {len(unresolved_enforced)} enforced pair(s) "
              f"unresolved in CI mode. The cut runs this with --require-full, where "
              f"this is a failure.")
        return 0
    print(f"\n{GREEN}PASS{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
