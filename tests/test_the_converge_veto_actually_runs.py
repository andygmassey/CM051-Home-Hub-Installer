#!/usr/bin/env python3
"""The converge path's RULE 2 veto is DRIVEN, not grepped.

WHY THIS FILE EXISTS, AND IT IS THE MANIFEST'S OWN INCIDENT TEXT.

cut-manifests/v1.0.71.yaml carries `v1064-...` for the converge veto, and its
proof primitive is:

    kind: grep_in_source_at_sha
    pattern: '_canonical_keys_conflict'
    must_match: true

That proof is satisfied by the function NAME appearing in the file. The same
manifest entry explains, three lines above, exactly why that is not enough:

    "There is exactly ONE caller of merge_persons() and it IS guarded -- this
     path never called it, which is why every audit that started from the
     guarded function came back clean."

    "THAT IS WHY THE COUNT GREW while the fix was believed in place: 128 on the
     v1.0.38 box, 130 on 2026-08-26, 137 on the v1.0.63 walk."

So the historical defect was a guard that EXISTED and was NOT CALLED, and the
proof primitive that now guards it is a grep for the guard's own name. It would
survive the regression it is named after: delete the call at the merge loop,
leave the def, and `must_match` is still satisfied. It cannot see a deleted
fail-closed branch either.

MEASURED before writing this: 0 tests in the repo name
`_canonical_keys_conflict`. CONTROL: the sibling guard on the resolve path,
`_node_holds_a_different_canonical_key`, is named by 1. One of the two RULE 2
guards is driven by a test and the other is driven by a grep.

Exit: 0 all arms pass, 1 a real failure, 2 CANNOT-RUN.
"""
import json
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CM041 = os.path.join(REPO, "vendor", "cm041")
SUBJECT = os.path.join(CM041, "identity_resolver", "batch_resolver.py")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  ok    %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  FAIL  %s" % msg, file=sys.stderr)


def cannot(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    print("A check that could not run has not passed.", file=sys.stderr)
    sys.exit(2)


if not os.path.isfile(SUBJECT):
    cannot("no batch_resolver.py at %s" % SUBJECT)

# rapidfuzz is the only import on the transitive graph that a bare runner
# lacks. httpx is REAL and deliberately not stubbed: the fail-closed arm
# depends on `except httpx.HTTPError` catching a genuine exception class, and
# a stubbed exception would let that arm pass without proving anything.
try:
    import httpx  # noqa: F401
except ImportError:
    cannot("httpx is genuinely required by this test and is not importable")

# Derived, not guessed: the ONLY rapidfuzz import anywhere in vendor/cm041 is
# `from rapidfuzz.distance import JaroWinkler` in identity_resolver/normalise.py.
# The stub is a package (it needs __path__) exposing exactly that one name, and
# it returns a similarity of 0.0 -- no arm below depends on fuzzy scoring, so a
# stub that scored anything would be pretending to measure something.
try:
    import rapidfuzz.distance  # noqa: F401
except ImportError:
    _rf = types.ModuleType("rapidfuzz")
    _rf.__path__ = []
    _dist = types.ModuleType("rapidfuzz.distance")

    class _JaroWinkler(object):
        @staticmethod
        def similarity(a, b, **kw):
            return 0.0

        @staticmethod
        def normalized_similarity(a, b, **kw):
            return 0.0

        @staticmethod
        def distance(a, b, **kw):
            return 1.0

    _dist.JaroWinkler = _JaroWinkler
    _rf.distance = _dist
    sys.modules["rapidfuzz"] = _rf
    sys.modules["rapidfuzz.distance"] = _dist

sys.path.insert(0, CM041)
try:
    from identity_resolver import batch_resolver as B
except Exception as exc:  # pragma: no cover - environment problem, not a verdict
    cannot("could not import batch_resolver: %s: %s" % (type(exc).__name__, exc))

if os.path.abspath(B.__file__) != os.path.abspath(SUBJECT):
    cannot("imported %s, not the subject %s" % (B.__file__, SUBJECT))
ok("driving the real batch_resolver at %s" % os.path.relpath(B.__file__, REPO))

if not hasattr(B, "_canonical_keys_conflict"):
    bad("batch_resolver has no _canonical_keys_conflict; the converge veto is gone")
    print("\n%d passed, %d failed" % (PASS, FAIL))
    sys.exit(1)

CANON = sorted(
    __import__("identity_resolver.resolver", fromlist=["IdentityResolver"])
    .IdentityResolver._CANONICAL_ID_TYPES
)
if not CANON:
    cannot("the canonical id-type set is empty; there is nothing RULE 2 could protect")
ID_TYPE = CANON[0]
ok("CONTROL: %d canonical id type(s) declared, so the veto has a subject (%s)"
   % (len(CANON), ", ".join(CANON)))


class _Resp(object):
    def __init__(self, rows):
        self._rows = rows

    def raise_for_status(self):
        return None

    def json(self):
        return {"results": {"bindings": [
            {"v": {"value": v}} for v in self._rows
        ]}}


class _Client(object):
    """Answers each person URI with the canonical values it was given."""

    def __init__(self, values_by_uri):
        self._values = values_by_uri
        self.calls = 0

    def post(self, url, content=None, headers=None):
        self.calls += 1
        for uri, vals in self._values.items():
            if "<%s>" % uri in content:
                return _Resp(vals)
        return _Resp([])


class _ExplodingClient(object):
    """A store that cannot be read. Raises the REAL httpx.HTTPError."""

    def __init__(self):
        self.calls = 0

    def post(self, url, content=None, headers=None):
        self.calls += 1
        raise httpx.HTTPError("connection reset")


A = "http://example.invalid/person/a"
Z = "http://example.invalid/person/z"

# ── ARM 1: THE DEFECT. Two different cards must never merge ────────────────
cl = _Client({A: ["CARD-AAA"], Z: ["CARD-ZZZ"]})
verdict = B._canonical_keys_conflict("http://store.invalid", cl, A, Z)
if verdict is None:
    bad("two DIFFERENT canonical keys reported no conflict -- RULE 2 would allow "
        "the over-merge this veto exists to stop")
elif cl.calls == 0:
    bad("a verdict was returned without reading the store (%d calls); the guard "
        "is not measuring anything" % cl.calls)
else:
    ok("two different canonical keys -> conflict %r, the merge is refused" % verdict)

# ── ARM 2: CONTROL. Identical keys are the SAME person and must merge ──────
cl = _Client({A: ["CARD-AAA"], Z: ["CARD-AAA"]})
if B._canonical_keys_conflict("http://store.invalid", cl, A, Z) is None:
    ok("CONTROL: identical canonical keys -> no conflict, so arm 1 is a "
       "measurement and not a guard that refuses everything")
else:
    bad("identical canonical keys were reported as a conflict; the veto would "
        "block every legitimate merge and dedupe would never converge")

# ── ARM 3: CONTROL. A node with no card can still be merged ────────────────
cl = _Client({A: ["CARD-AAA"], Z: []})
if B._canonical_keys_conflict("http://store.invalid", cl, A, Z) is None:
    ok("CONTROL: one side holding no card is not a conflict, so a duplicate "
       "with no Contacts card can still be tidied away")
else:
    bad("a node with no canonical key was treated as conflicting; this would "
       "strand every card-less duplicate for ever")

# ── ARM 4: FAILS CLOSED. THE LOAD-BEARING ARM ──────────────────────────────
# An unreadable store must REFUSE. An over-merge interleaves two people on one
# node and is irreversible in practice; a refused merge leaves a duplicate that
# is still fixable. A transport error must not unlock a door the guard holds.
cl = _ExplodingClient()
try:
    verdict = B._canonical_keys_conflict("http://store.invalid", cl, A, Z)
except Exception as exc:
    # Propagating also refuses the merge: the caller never reaches the write.
    ok("an unreadable store raises %s out of the veto, so the merge below it "
       "is never reached" % type(exc).__name__)
else:
    if verdict is None:
        bad("AN UNREADABLE STORE REPORTED 'no conflict'. A check that could not "
            "run has not passed, and this one would hand back a licence to merge")
    else:
        ok("an unreadable store returns %r, so the merge is refused rather than "
           "allowed (fails closed)" % verdict)

# ── ARM 5: THE VETO IS CALLED, WHICH IS WHAT THE GREP CANNOT SEE ───────────
# The historical defect was a guard that existed and was never called on this
# path. Assert the call sits before the write, in the merge loop, and that the
# refusal skips the write rather than falling through to it.
src = open(SUBJECT, encoding="utf-8").read().split("\n")
call_lines = [i for i, l in enumerate(src)
              if "_canonical_keys_conflict(" in l and not l.lstrip().startswith("#")
              and "def _canonical_keys_conflict" not in l]
merge_lines = [i for i, l in enumerate(src)
               if "_merge_oxigraph(" in l and not l.lstrip().startswith("#")
               and "def _merge_oxigraph" not in l]
if not call_lines:
    bad("_canonical_keys_conflict is DEFINED but never CALLED -- this is the "
        "exact shape of the defect the manifest entry describes, and the "
        "grep_in_source proof would still pass")
elif not merge_lines:
    cannot("no call to _merge_oxigraph found; the merge path has moved and this "
           "arm can no longer locate its subject")
else:
    first_call, first_merge = min(call_lines), min(merge_lines)
    if first_call < first_merge:
        window = "\n".join(src[first_call:first_merge])
        if "continue" in window:
            ok("the veto is called at line %d, before the write at line %d, and "
               "the refusal path skips the merge" % (first_call + 1, first_merge + 1))
        else:
            bad("the veto is called at line %d before the write at %d, but no "
                "`continue` separates them: a refusal would fall through to the "
                "merge it just vetoed" % (first_call + 1, first_merge + 1))
    else:
        bad("_canonical_keys_conflict is called at line %d, AFTER the write at "
            "line %d. The graph is already merged by the time the veto runs"
            % (first_call + 1, first_merge + 1))

print()
print("%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
