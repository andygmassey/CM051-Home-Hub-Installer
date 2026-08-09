#!/usr/bin/env python3
"""v1018-D658 destructive-path guards, driven by tests/test_name_repair.sh.

Everything here exercises the SHIPPED ``main()`` with the network stubbed
out. That matters: the two guards under test live in ``main`` and not in
the pure ``decide``, so the existing helper -- which lifts ``decide`` out
and runs it standalone -- cannot see them at all. A grep would pass
against a guard placed AFTER the first write.

Both guards were TNM's review points on the PR, and both are about the
same thing: this module DELETES, on a customer graph, with no undo.

  1. ORDERING. The household split must run first. An unsplit node holds
     several people behind one URI, and a kinship word deleted from it may
     be the only label one of them has.
  2. SNAPSHOT. "No undo" was stated five times and mitigated zero times.

The assertions that matter are the negative ones -- that NOTHING is
written when a precondition fails. A guard that warns and proceeds is not
a guard.
"""
from __future__ import annotations

import importlib
import os
import pathlib
import sys
import tempfile
import types


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


NS = "https://ostler.ai/ns#"
SKOS = "http://www.w3.org/2004/02/skos/core#"
URI = "https://ostler.ai/person/test-0001"


def _bindings(values):
    return [{"s": {"value": URI}, "v": {"value": v}} for v in values]


def load(repo: pathlib.Path):
    # ostler_fda.pwg_ingest pulls in identifier_quality, which imports
    # `nameparser` -- a third-party package that is NOT declared anywhere
    # this gate can rely on. Stubbing it is legitimate here and only here:
    # the code under test is main()'s two refusal guards, which never
    # reach a name parser. What it must NOT do is hide the gap, so the
    # stub is loud rather than silent, and the gap is on the PR.
    for name in ("nameparser", "rapidfuzz", "rapidfuzz.fuzz"):
        if name not in sys.modules:
            stub = types.ModuleType(name)
            stub.HumanName = lambda *a, **k: None       # noqa: E731
            stub.fuzz = stub
            stub.__stubbed_by_gate__ = True
            sys.modules[name] = stub
    sys.path.insert(0, str(repo / "vendor"))
    # A STALE __pycache__ makes this gate assert against code that is no
    # longer in the file, and it does it silently: inspect.getsource reads
    # the .py while the executing code object came from the .pyc. That is
    # not hypothetical -- it cost an hour on 2026-08-10, reporting RED
    # against a source ordering that was already correct. A gate that can
    # be fooled by a cache is not a gate, so refuse the cache outright.
    sys.dont_write_bytecode = True
    importlib.invalidate_caches()
    mod = importlib.import_module("ostler_fda.repair_placeholder_names")
    return importlib.reload(mod)


class Recorder:
    """Stands in for the graph. Records, never talks to anything."""

    def __init__(self, mod, names, construct_raises=False, alternates=()):
        self.mod = mod
        self.names = names
        self.alternates = list(alternates)
        self.updates: list[str] = []
        self.constructs: list[str] = []
        self.order: list[str] = []
        self.construct_raises = construct_raises

    def __enter__(self):
        self._real = (self.mod._query, self.mod._update, self.mod._construct)

        # Model the store rather than ignore the question. If the candidate
        # query ASKS for alternateName, it gets the alternates back -- which
        # is the whole idempotence hazard, and a stub that returned a fixed
        # list regardless would make the mutation that reintroduces it look
        # green here.
        def _query(q):
            names = list(self.names)
            if "alternateName" in q:
                names += self.alternates
            return _bindings(names)

        self.mod._query = _query

        def _update(sparql):
            self.updates.append(sparql)
            self.order.append("update")

        def _construct(sparql):
            if self.construct_raises:
                raise OSError("disk full (simulated)")
            self.constructs.append(sparql)
            self.order.append("construct")
            return "# n-triples\n"

        self.mod._update = _update
        self.mod._construct = _construct
        return self

    def __exit__(self, *exc):
        self.mod._query, self.mod._update, self.mod._construct = self._real
        return False


def main(repo_str: str) -> int:
    repo = pathlib.Path(repo_str)
    mod = load(repo)
    checks: list[tuple[str, bool]] = []

    KIN, NAME = "Mum", "Jane Smith"
    tmp = tempfile.mkdtemp(prefix="d658guard.")
    review = os.path.join(tmp, "review.tsv")
    snapshot = os.path.join(tmp, "snap")
    absent = os.path.join(tmp, "no-such-marker")
    os.environ["OSTLER_HOUSEHOLD_SPLIT_MARKER"] = absent

    base = ["--apply", "--review-out", review, "--snapshot-out", snapshot]

    # --- 1. ORDERING: refuse, and write NOTHING -------------------------
    with Recorder(mod, [KIN, NAME]) as rec:
        rc = mod.main(base)
    checks.append(("no split marker and no acknowledgement: --apply REFUSES",
                   rc == 2))
    checks.append(("...and not one update is issued", rec.updates == []))
    checks.append(("...and no snapshot is taken either, because nothing runs",
                   rec.constructs == []))

    # The refusal must not be evadable by the thing it is protecting: a
    # node with work to do is exactly the case that must be blocked.
    checks.append(("...even though this node HAD work to do (a kinship drop)",
                   mod.decide([KIN, NAME])[2] == [KIN]))

    # --- 2. the two ways past it, and only those two --------------------
    with Recorder(mod, [KIN, NAME]) as rec:
        rc = mod.main(base + ["--households-already-split"])
    checks.append(("an explicit acknowledgement is accepted", rc == 0))
    checks.append(("...and the write then happens", len(rec.updates) == 1))

    marker = os.path.join(tmp, "household-split.done")
    pathlib.Path(marker).write_text("ok\n", encoding="utf-8")
    os.environ["OSTLER_HOUSEHOLD_SPLIT_MARKER"] = marker
    with Recorder(mod, [KIN, NAME]) as rec:
        rc = mod.main(base)
    checks.append(("a split marker is accepted without the flag", rc == 0))
    checks.append(("...and the write then happens", len(rec.updates) == 1))

    # --- 3. SNAPSHOT precedes the first write ---------------------------
    # Not "a snapshot exists" -- a snapshot taken AFTER the delete is a
    # copy of the damage.
    checks.append(("the snapshot is taken BEFORE any update",
                   rec.order[:1] == ["construct"]))
    checks.append(("...and it covers the subject about to be written",
                   bool(rec.constructs) and URI in rec.constructs[0]))
    checks.append(("...and it lands under a user-local path, never the repo",
                   any(f.startswith("snap-") for f in os.listdir(tmp))))

    # --- 4. a snapshot that FAILS stops the run -------------------------
    # A backup step that silently skips is worse than none: it is the
    # sentence "there is a backup" with nothing behind it.
    with Recorder(mod, [KIN, NAME], construct_raises=True) as rec:
        rc = mod.main(base)
    checks.append(("a snapshot that cannot be written REFUSES the run", rc == 2))
    checks.append(("...and not one update is issued", rec.updates == []))

    # --- 5. IDEMPOTENCE: a second --apply is a no-op --------------------
    # The hazard TNM named: if run 2 read the demoted alternateName back as
    # a candidate, it could re-elect and undo run 1. It does not, because
    # the candidate query asks for displayName and prefLabel only -- so
    # assert exactly that, at the source, rather than trusting the shape.
    src = (repo / "vendor/ostler_fda/repair_placeholder_names.py").read_text(
        encoding="utf-8")
    sel = src[src.index("SELECT ?s ?v"):src.index("SELECT ?s ?v") + 400]
    checks.append(("the candidate query never reads alternateName back",
                   "alternateName" not in sel))

    # And behaviourally: feed it the state run 1 leaves behind. The case
    # has to be one that actually DEMOTES -- a kinship drop leaves no
    # alternate behind, so it cannot exercise the read-back hazard at all.
    PHONE = "+852 1234 5678"
    keep, demote, drop, clear, verdict = mod.decide([PHONE, NAME])
    if not demote:
        fail("fixture no longer demotes; the idempotence check would be vacuous")
    after = [keep]                       # loser is now an alternate, not a name
    k2, d2, g2, c2, v2 = mod.decide(after)
    checks.append(("re-deciding on the post-run state demotes nothing", d2 == []))
    checks.append(("...deletes nothing", g2 == []))
    checks.append(("...and is 'single', so the pass writes nothing second time",
                   v2 == "single"))

    # The real second run: the store also HOLDS the demoted name as an
    # alternate. If the candidate query ever starts asking for alternates,
    # this run re-elects and undoes run 1 -- so it must stay a no-op.
    with Recorder(mod, after, alternates=demote) as rec:
        rc = mod.main(base)
    checks.append(("a second --apply over the settled graph issues NO update",
                   rc == 0 and rec.updates == []))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_repair_guards.py <repo-root>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
