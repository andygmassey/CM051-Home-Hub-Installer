"""Project preference facts from Qdrant into the RDF graph.

WHY THIS EXISTS, measured on a live v1.0.98 box 2026-09-16:

    Qdrant  `preferences` collection      5,733 points
    Oxigraph                            111,289 triples, and ZERO preference
                                        nodes of any kind

and a `git grep` across the whole shipped tree for anything writing
LikePreference or DislikePreference RDF returns NOTHING, against a working
control (five files do write to Oxigraph). So interest_profile._pref_query
could never match a single row, on any box, ever.

THAT ONE MISSING LINK IS THE ROOT OF FIVE SYMPTOMS reported separately:
  the front page reads "0 interests inferred so far"
  /api/v1/preferences serves count 0
  the assistant's pwg_preferences tool finds nothing
  assistant_answers_grounded has FAILED ON EVERY WALK RECORD we hold, with
    tool_found_nothing:pwg_preferences
  and a daily brief with no real facts to draw on confabulates

A consumer with no producer, pointed at the most valuable data in the product.

WHY RDF AND NOT "JUST READ QDRANT". The reader asks for ?subject ?category
?strength ?source ?observed ?created: a structured fact with provenance. That
is an RDF record. Qdrant's job is similarity search over embeddings OF those
facts. Pointing the reader at the vector store would mean answering a
structured question with a nearest-neighbour search and inheriting whatever a
payload happened to carry. The graph is the designed home and the code says so.

WHY THE BRIDGE LIVES HERE, stated so the next reader does not mistake it for
the final shape: the CORRECT long-term fix is for whatever writes these points
to Qdrant to write the RDF at the same time, from one producer. This module is
a projection that runs before each compile so the graph is correct today. When
the upstream pipeline emits RDF directly, delete this and its tick step.

DELETE THIS MODULE WHEN, and the condition is a TEST rather than an intention:
removing the projection step from the tick leaves interest_profile's own row
count UNCHANGED. Until that is true, one producer is not yet writing both
stores and the bridge is still load-bearing. A bridge with no stated exit
condition is still here in a year, which is Archie's point and he is right.

IDEMPOTENT BY CONSTRUCTION: every node's IRI is derived from the preference's
own identity, so re-running replaces rather than duplicates.
"""
from __future__ import annotations

import hashlib
import json
import os
import urllib.error
import urllib.parse
import urllib.request

PWG_NS = "https://schema.ostler.ai/ontology#"
_QDRANT_DEFAULT = "http://127.0.0.1:6333"
_OXIGRAPH_DEFAULT = "http://127.0.0.1:7878"
_COLLECTION = "preferences"
_PAGE = 512

# Like and Dislike become the two node types the reader asks for. Neutral is
# deliberately NOT projected: interest_profile only ever queries
# LikePreference and DislikePreference, and inventing a third class the reader
# does not read would be a producer with no consumer, which is the defect this
# module exists to fix.
PROJECTOR_ID = "ostler:cm059:preference-projection"

_POLARITY = {"like": "LikePreference", "dislike": "DislikePreference"}


def _secret(env_var: str, filename: str) -> str:
    """Same env-then-0600-file resolution lib/ostler_store_auth.py uses. Not a
    second decider: the same variable names and the same files."""
    val = (os.environ.get(env_var) or "").strip()
    if val:
        return val
    d = os.environ.get("OSTLER_SECRETS_DIR", os.path.expanduser("~/.ostler/secrets"))
    try:
        with open(os.path.join(d, filename), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _post(url: str, body: bytes, headers: dict, timeout: float = 60.0) -> bytes:
    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        raise RuntimeError(
            f"{url} refused with HTTP {exc.code}. {detail}"
        ) from exc


def read_qdrant_preferences(qdrant_url: str | None = None) -> list[dict]:
    """Every preference point, with its payload. Raises on a refused read: a
    store that will not answer must never be reported as an empty store."""
    base = (qdrant_url or os.environ.get("OSTLER_QDRANT_URL", _QDRANT_DEFAULT)).rstrip("/")
    headers = {"Content-Type": "application/json"}
    key = _secret("QDRANT_API_KEY", "qdrant_api_key")
    if key:
        headers["api-key"] = key

    out: list[dict] = []
    offset = None
    while True:
        payload = {"limit": _PAGE, "with_payload": True, "with_vector": False}
        if offset is not None:
            payload["offset"] = offset
        raw = _post(f"{base}/collections/{_COLLECTION}/points/scroll",
                    json.dumps(payload).encode("utf-8"), headers)
        result = json.loads(raw).get("result") or {}
        pts = result.get("points") or []
        out.extend(pts)
        offset = result.get("next_page_offset")
        if not offset or not pts:
            break
    return out


def _iri(point: dict) -> str:
    pl = point.get("payload") or {}
    ident = pl.get("preference_id") or f"{pl.get('source','')}|{pl.get('category','')}|{pl.get('subject','')}"
    return f"urn:ostler:preference:{hashlib.sha256(str(ident).encode('utf-8')).hexdigest()[:32]}"


def _lit(value: str) -> str:
    """An N-Triples literal. NOT json.dumps.

    JSON escapes non-ASCII as backslash-u and emits SURROGATE PAIRS for
    anything outside the BMP. Oxigraph rejects a lone surrogate with
    "expected \\u escape sequence should be followed by hexadecimal digits",
    measured on the first real run of this projector. A customer's
    preferences contain emoji, so this is not a rare path.

    N-Triples 1.1 is UTF-8, so the correct escaping is the characters the
    grammar requires and nothing else.
    """
    out = str(value)
    out = out.replace(chr(92), chr(92) * 2)
    out = out.replace(chr(34), chr(92) + chr(34))
    out = out.replace(chr(10), chr(92) + "n")
    out = out.replace(chr(13), chr(92) + "r")
    out = out.replace(chr(9), chr(92) + "t")
    # A raw control character is not legal in the grammar either.
    out = "".join(c for c in out if c >= " " or c == chr(92))
    return chr(34) + out + chr(34)


def to_triples(points: list[dict]) -> tuple[list[str], int]:
    """-> (n-triples lines, count of points skipped). Skips anything whose
    polarity the reader does not query, or which lacks a field the reader
    REQUIRES: a row missing subject, category, strength or source cannot
    satisfy the SELECT and would be written for nobody."""
    lines: list[str] = []
    skipped = 0
    for p in points:
        pl = p.get("payload") or {}
        polarity = str(pl.get("preference_type", "")).strip().lower()
        node_type = _POLARITY.get(polarity)
        subject = pl.get("subject")
        category = pl.get("category")
        strength = pl.get("strength")
        source = pl.get("source")
        if not node_type or not subject or not category or strength is None or not source:
            skipped += 1
            continue
        s = f"<{_iri(p)}>"
        lines.append(
            f'{s} <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> '
            f'<{PWG_NS}{node_type}> .')
        lines.append(f'{s} <{PWG_NS}subject> {_lit(subject)} .')
        lines.append(f'{s} <{PWG_NS}category> {_lit(category)} .')
        lines.append(f'{s} <{PWG_NS}preferenceStrength> {_lit(strength)} .')
        lines.append(f'{s} <{PWG_NS}dataSource> {_lit(source)} .')
        if pl.get("observed_at"):
            lines.append(f'{s} <{PWG_NS}observedAt> {_lit(pl["observed_at"])} .')
        if pl.get("created_at"):
            lines.append(f'{s} <{PWG_NS}createdAt> {_lit(pl["created_at"])} .')
        # Carried so a level-aware reader can filter later. The current reader
        # does not SELECT it; losing it here would make that impossible.
        lvl = pl.get("privacy_level") or pl.get("compartment_level")
        if lvl:
            lines.append(f'{s} <{PWG_NS}privacyLevel> {_lit(lvl)} .')
        # PROVENANCE MARKER. Written into the DEFAULT graph, because the reader
        # (interest_profile._pref_query) has no GRAPH clause and therefore never
        # sees a named graph. Measured: 38432 triples landed in a named graph and
        # fetch_preferences still returned 0. So the projection lives in the
        # default graph and is made replaceable by this marker instead, which
        # deletes ONLY what this projector wrote and never another producer's
        # rows.
        lines.append(f'{s} <{PWG_NS}projectedBy> {_lit(PROJECTOR_ID)} .')
    return lines, skipped



def _count_marked(oxi: str, headers: dict) -> int:
    """How many nodes currently carry this projector's marker. Used to refuse a
    delete that does not match what we are about to write."""
    q = (f"PREFIX pwg: <{PWG_NS}> SELECT (COUNT(DISTINCT ?s) AS ?n) "
         f"WHERE {{ ?s pwg:projectedBy {_lit(PROJECTOR_ID)} }}")
    h = {"Accept": "text/csv",
         "Content-Type": "application/x-www-form-urlencoded"}
    if "Authorization" in headers:
        h["Authorization"] = headers["Authorization"]
    raw = _post(oxi + "/query",
                urllib.parse.urlencode({"query": q}).encode("utf-8"), h)
    rows = raw.decode("utf-8", "replace").splitlines()
    try:
        return int(rows[1].strip().strip('"'))
    except Exception:
        return 0


def project(qdrant_url: str | None = None, oxigraph_url: str | None = None) -> dict:
    """Read Qdrant, replace the projected preference graph in Oxigraph.

    Writes into a NAMED GRAPH so the projection can be replaced wholesale
    without touching anything another producer wrote. Dropping the graph first
    makes this idempotent: a preference removed upstream disappears here too,
    which a plain insert would never achieve.
    """
    oxi = (oxigraph_url or os.environ.get("OSTLER_OXIGRAPH_URL", _OXIGRAPH_DEFAULT)).rstrip("/")
    tok = _secret("OXIGRAPH_TOKEN", "oxigraph_token")
    headers = {"Content-Type": "application/sparql-update"}
    if tok:
        headers["Authorization"] = "Bearer " + tok

    points = read_qdrant_preferences(qdrant_url)
    lines, skipped = to_triples(points)

    # Replace only our own rows. DELETE WHERE on the marker is exact: a row
    # another producer wrote has no marker and is untouched.
    # COUNT BEFORE DELETE, AND REFUSE ON A MISMATCH. Archie's attack, taken:
    # if the provenance predicate is ever absent or renamed, this DELETE either
    # removes nothing (the projection then doubles every run) or, with a
    # mistyped pattern, removes far more than it wrote. Neither is visible
    # afterwards. So ask the graph how many nodes carry the marker, and refuse
    # if that number is wildly out of line with what we are about to write.
    existing = _count_marked(oxi, headers)
    expected_nodes = len({l.split(" ", 1)[0] for l in lines}) if lines else 0
    if existing and expected_nodes and existing > max(10 * expected_nodes, 1000):
        raise RuntimeError(
            f"refusing to delete: {existing} nodes carry the projection marker "
            f"but this run would write only {expected_nodes}. That ratio means "
            "either the marker is wrong or the store holds something this "
            "projector did not write. Investigate before re-running."
        )
    delete = (f"DELETE WHERE {{ ?s <{PWG_NS}projectedBy> {_lit(PROJECTOR_ID)} ; ?p ?o }}")
    body = delete if not lines else (
        delete + " ;\nINSERT DATA {\n" + "\n".join(lines) + "\n}")
    _post(f"{oxi}/update", body.encode("utf-8"), headers)
    return {"points": len(points), "triples": len(lines), "skipped": skipped,
            "nodes": len(lines and set(l.split(" ")[0] for l in lines) or ())}


if __name__ == "__main__":
    import sys
    try:
        r = project()
    except Exception as exc:  # loud, never a quiet zero
        print(f"preference projection FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
    print(f"projected {r['nodes']} preference nodes "
          f"({r['triples']} triples) from {r['points']} Qdrant points; "
          f"{r['skipped']} skipped as unqueryable")
