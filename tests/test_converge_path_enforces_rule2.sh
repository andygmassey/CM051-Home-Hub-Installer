#!/usr/bin/env bash
# The CONVERGE path must obey RULE 2, not just the resolve path.
#
# WHY THIS EXISTS. MEASURED on the Mini 16, 2026-09-04, on a FRESHLY WIPED box
# running v1.0.63:
#
#     over-merged Person nodes                   137
#     Contacts cards swallowed                   286  (149 people with no node)
#     CONTROL: icloud_contact_uid identifiers   2261
#     CONTROL: correctly single-uid nodes       1975  (so the zero was reachable)
#
# RULE 2 was implemented in IdentityResolver and recorded as "stops NEW ones".
# It stops new ones on the RESOLVE path. `batch_resolver --execute --converge`
# is a SECOND merge path -- install.sh runs it on every install and the
# dedupe-catchup agent re-runs it hourly until it completes -- and it reached
# the graph through raw SPARQL without ever consulting the veto. Grepping that
# module for a canonical-key check returned only a free-mail-domain list and
# "canonical DISPLAY NAME".
#
# That is why the count GREW rather than held: 128 on the v1.0.38 box, 130 on
# 2026-08-26, 137 here, while the walk probe failed on v1.0.52, v1.0.61 and
# v1.0.63 and the fix was believed to be in place. A guard on one of two doors
# is not a guard.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MOD_DIR="${MOD_DIR:-${REPO}/vendor/cm041}"
[ -f "${MOD_DIR}/identity_resolver/batch_resolver.py" ] || {
    echo "CANNOT-RUN: no batch_resolver.py under ${MOD_DIR}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
python3 -c 'import httpx' 2>/dev/null || { echo "CANNOT-RUN: httpx not importable; the module cannot be loaded" >&2; exit 2; }

MOD_DIR="$MOD_DIR" python3 <<'PY'
import os, sys, types
sys.path.insert(0, os.environ["MOD_DIR"])

PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

# rapidfuzz backs the FUZZY NAME strategies, which this test never drives --
# it exercises the merge-execution loop only. Stubbing it keeps the test
# runnable anywhere rather than CANNOT-RUN on a machine without the wheel, and
# a CANNOT-RUN that becomes permanent is how a gate stops gating. The stub
# raises if anything actually calls it, so it can never quietly satisfy a limb.
if "rapidfuzz" not in sys.modules:
    def _no_fuzz(*_a, **_k):
        raise AssertionError(
            "rapidfuzz was called: this test claims not to exercise fuzzy "
            "matching and that claim is now false")
    _rf = types.ModuleType("rapidfuzz")
    _rf.fuzz = types.SimpleNamespace(ratio=_no_fuzz, partial_ratio=_no_fuzz,
                                     token_sort_ratio=_no_fuzz, WRatio=_no_fuzz)
    _rf.distance = types.SimpleNamespace(
        JaroWinkler=types.SimpleNamespace(similarity=_no_fuzz),
        Levenshtein=types.SimpleNamespace(distance=_no_fuzz))
    _rf.process = types.SimpleNamespace(extractOne=_no_fuzz, extract=_no_fuzz)
    sys.modules["rapidfuzz"] = _rf
    sys.modules["rapidfuzz.fuzz"] = _rf.fuzz
    sys.modules["rapidfuzz.distance"] = _rf.distance
    sys.modules["rapidfuzz.process"] = _rf.process

try:
    from identity_resolver import batch_resolver as br
except Exception as exc:
    print("CANNOT-RUN: batch_resolver did not import (%s: %s)"
          % (type(exc).__name__, exc), file=sys.stderr)
    raise SystemExit(2)

PWG = br.PWG

# A fake store. Node A and node B each hold a DIFFERENT icloud_contact_uid,
# which is RULE 2's stated violation: different canonical keys must not merge.
GRAPH = {
    "urn:a": {"icloud_contact_uid": {"CARD-A"}},
    "urn:b": {"icloud_contact_uid": {"CARD-B"}},
    "urn:c": {},                                   # no card yet: must still merge
}

def fake_query(url, client, sparql):
    # Parse the two things the helper asks for out of the query text.
    uri = sparql.split("<", 2)[1].split(">")[0] if "<" in sparql else ""
    id_type = "icloud_contact_uid" if "icloud_contact_uid" in sparql else None
    if id_type is None:
        return []
    return [{"v": v} for v in sorted(GRAPH.get(uri, {}).get(id_type, ()))]

merged = []
def fake_merge_oxigraph(url, client, keep, discard):
    merged.append((keep, discard))
def fake_merge_qdrant(url, coll, keep, discard):
    return True
def fake_backup(url, client, uris, path):
    return None

br._sparql_query = fake_query
br._merge_oxigraph = fake_merge_oxigraph
br._merge_qdrant = fake_merge_qdrant
br._backup_triples = fake_backup
# execute() ends by reconciling the vector store. This test is about the merge
# LOOP, and leaving that live reached a real Qdrant -- via a local Privoxy that
# answered 503 for a host nothing was listening on, which is exactly why a
# probe must never be pointed at "localhost" and believed. Stubbed so the only
# thing under test is the veto.
br.BatchResolver.reconcile_qdrant = lambda self, apply=False, backup_dir="": None

def action(keep, discard):
    return br.MergeAction(keep_uri=keep, keep_name="K", discard_uri=discard,
                          discard_name="D", confidence=1.0, strategy="test",
                          details="test")

def run(actions):
    merged.clear()
    r = br.BatchResolver()
    rep = br.ResolverReport(auto_merges=list(actions))
    r.execute(rep, backup_dir="/nonexistent-on-purpose")
    return list(merged)

# ── 1. THE DEFECT: two different Contacts cards must NOT be merged ───────
got = run([action("urn:a", "urn:b")])
if got:
    bad("RULE 2 violated: merged two nodes carrying DIFFERENT icloud_contact_uid (%r)" % got)
else:
    ok("two nodes with different canonical keys are REFUSED on the converge path")

# ── 2. CONTROL: absence is not a conflict, RULE 1 must still work ────────
# If this limb fails the guard is too strict and has broken ordinary
# enrichment, which is a worse outcome than the bug being fixed.
got = run([action("urn:a", "urn:c")])
if got == [("urn:a", "urn:c")]:
    ok("CONTROL: a node with NO card still merges -- RULE 1 is intact")
else:
    bad("CONTROL: a legitimate merge was refused (%r). The guard is too strict." % got)

# ── 3. CONTROL: the guard must FAIL CLOSED when the store is unreadable ──
# A check that could not run has not passed. If a transport error let the
# merge through, the guard would evaporate exactly when the graph is sickest.
def exploding_query(url, client, sparql):
    raise br.httpx.HTTPError("store unreachable")
br._sparql_query = exploding_query
got = run([action("urn:a", "urn:b")])
br._sparql_query = fake_query
if got:
    bad("CONTROL: an unreadable store ALLOWED the merge (%r). The guard fails open." % got)
else:
    ok("CONTROL: an unreadable store REFUSES the merge -- cannot-run is not a pass")

# ── 4. Mixed batch: only the offending pair is refused ───────────────────
got = run([action("urn:a", "urn:b"), action("urn:a", "urn:c")])
if got == [("urn:a", "urn:c")]:
    ok("a mixed batch refuses only the conflicting pair and merges the rest")
else:
    bad("mixed batch behaved wrongly: %r" % got)

print()
print("== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
raise SystemExit(1 if FAIL else 0)
PY
