"""One-time repair: preference graph nodes that carry two pwg:subject values.

Before PWG #477 a preference id shared by two batch rows (an ASIN reached by two
differently-worded titles) left both pwg:subject literals on one graph node,
while Qdrant held one payload per id. This keeps, per node, the subject that
equals the Qdrant payload's ``subject`` and deletes the others.

Dry run by default. ``--apply`` is required to write. A node whose subjects
include no value equal to the Qdrant payload is reported and left alone: this
tool never guesses which title is right. Idempotent: a repaired node has one
subject and is not planned again.

    python3 -m src.repair_pref_subjects --oxigraph http://127.0.0.1:7878 \
        --qdrant http://127.0.0.1:6333 [--collection preferences] [--apply]

Exit: 0 clean (or nothing to do), 1 some nodes unresolvable, 78 cannot run.
"""

import argparse
import json
import sys
import urllib.request

PWG = "https://schema.ostler.ai/ontology#"
PREFIX = "PREFIX pwg: <%s>\n" % PWG

FIND_DUPLICATES = (
    PREFIX + "SELECT ?s ?subj WHERE { ?s pwg:subject ?subj . "
    "{ SELECT ?s WHERE { ?s pwg:subject ?x } GROUP BY ?s HAVING (COUNT(DISTINCT ?x) > 1) } }"
)


def plan(rows, payload_subject):
    """rows: iterable of (node_iri, subject). payload_subject(pref_id) -> str or None.

    Returns (fixes, unresolved): fixes is [(node_iri, pref_id, keep, drop_list)],
    unresolved is [(node_iri, reason)].
    """
    by_node = {}
    for node, subj in rows:
        by_node.setdefault(node, []).append(subj)
    fixes, unresolved = [], []
    for node in sorted(by_node):
        subjects = sorted(set(by_node[node]))
        if len(subjects) < 2:
            continue
        pref_id = node.rsplit("pref_", 1)[-1]
        want = payload_subject(pref_id)
        if want is None:
            unresolved.append((node, "no Qdrant payload for this id"))
        elif want not in subjects:
            unresolved.append((node, "no subject equals the Qdrant payload"))
        else:
            fixes.append((node, pref_id, want, [s for s in subjects if s != want]))
    return fixes, unresolved


def delete_update(fixes):
    """One SPARQL UPDATE that removes exactly the non-matching subject triples."""
    lines = []
    for node, _pid, _keep, drops in fixes:
        for s in drops:
            lines.append("  <%s> pwg:subject %s ." % (node, _literal(s)))
    if not lines:
        return None
    return PREFIX + "DELETE DATA {\n" + "\n".join(lines) + "\n}"


def _literal(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


_AUTH = []   # (name, value) headers read from a curl config file, never printed


def load_auth(path):
    """Read ``header = "Name: value"`` lines from a curl -K style file."""
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("header") and "=" in line:
                raw = line.split("=", 1)[1].strip().strip('"')
                if ":" in raw:
                    name, value = raw.split(":", 1)
                    _AUTH.append((name.strip(), value.strip()))


def _post(url, body, ctype, accept=None):
    req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST")
    req.add_header("Content-Type", ctype)
    for name, value in _AUTH:
        req.add_header(name, value)
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8")


def run(oxigraph, qdrant, collection, apply=False, out=sys.stdout):
    raw = _post(oxigraph.rstrip("/") + "/query", FIND_DUPLICATES,
                "application/sparql-query", "application/sparql-results+json")
    rows = [(b["s"]["value"], b["subj"]["value"]) for b in json.loads(raw)["results"]["bindings"]]
    cache = {}

    def payload_subject(pid):
        if pid not in cache:
            body = json.dumps({"ids": [pid], "with_payload": ["subject"]})
            res = json.loads(_post(qdrant.rstrip("/") + "/collections/%s/points" % collection,
                                   body, "application/json"))["result"]
            cache[pid] = res[0]["payload"].get("subject") if res else None
        return cache[pid]

    fixes, unresolved = plan(rows, payload_subject)
    out.write("two-subject nodes: %d fixable, %d unresolvable\n" % (len(fixes), len(unresolved)))
    for node, reason in unresolved:
        out.write("UNRESOLVED %s: %s\n" % (node, reason))
    drops = sum(len(f[3]) for f in fixes)
    if not apply:
        out.write("DRY RUN: would delete %d subject triple(s). Pass --apply to write.\n" % drops)
        return 1 if unresolved else 0
    upd = delete_update(fixes)
    if upd:
        _post(oxigraph.rstrip("/") + "/update", upd, "application/sparql-update")
    out.write("APPLIED: deleted %d subject triple(s)\n" % drops)
    return 1 if unresolved else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--oxigraph", default="http://127.0.0.1:7878")
    ap.add_argument("--qdrant", default="http://127.0.0.1:6333")
    ap.add_argument("--collection", default="preferences")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--auth-conf", help="curl -K style file holding the store header")
    a = ap.parse_args(argv)
    try:
        if a.auth_conf:
            load_auth(a.auth_conf)
        return run(a.oxigraph, a.qdrant, a.collection, apply=a.apply)
    except OSError as exc:
        sys.stderr.write("CANNOT-RUN: %s\n" % exc)
        return 78


if __name__ == "__main__":
    sys.exit(main())
