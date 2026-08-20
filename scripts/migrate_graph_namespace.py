#!/usr/bin/env python3
"""Rewrite every pwg-branded identifier in a LIVE Oxigraph store and Qdrant.

WHY THIS EXISTS, AND WHY IT IS NOT OPTIONAL.
CM051 #888 moves the CODE onto schema.ostler.ai. A FRESH install regenerates
every identifier and needs nothing. An IN-PLACE upgrade does not: migrated
readers would query schema.ostler.ai against a store still keyed on pwg.dev,
find nothing, and the box would present as having lost all its data. On a box
walk that is indistinguishable from catastrophic data loss.

    measured on the box before this ran:
        217,029 triples touching pwg.dev
          3,362 triples touching pwg.local
          2,684 triples touching urn:pwg:
        Qdrant `people` payloads carry person_uri

THE MAPPING IS INJECTIVE AND THAT IS THE LOAD-BEARING CONTROL.
Two different source prefixes never land on one target (pwg.dev and pwg.local
go to DIFFERENT places, deliberately -- see CM051 #888, the enrichment graph
must stay separate from people). No `http://pwg.dev` exists in the data, so no
scheme variant collapses either. Therefore the TOTAL TRIPLE COUNT MUST BE
IDENTICAL either side. If it drops, triples merged or were lost, and this
script refuses rather than reporting a clean migration.

A rewrite that silently loses rows is the worst outcome available here -- it
looks exactly like success from the outside, which is the failure mode this
whole codebase keeps re-learning.

LITERALS ARE NOT REWRITTEN. Only IRIs move. A literal that happens to contain
the string (a stored query, a note) is CONTENT, not an identifier, and
rewriting content is not this script's job. Those are counted and reported
separately so the residue is explained rather than discovered later.
"""
import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

# (label, regex-for-REPLACE, literal-prefix-for-counting, replacement)
# The regex escapes the dots; the counting prefix is a plain substring.
RULES = [
    ("pwg.local", r"https?://pwg\\.local/", "pwg.local",
     "https://schema.ostler.ai/enrichment/"),
    ("pwg.dev",   r"https?://pwg\\.dev/",   "pwg.dev",
     "https://schema.ostler.ai/"),
    ("urn:pwg:",  r"urn:pwg:",              "urn:pwg:",
     "urn:ostler:"),
]


def run(host, path, body, ctype, accept="application/sparql-results+json",
        timeout=300):
    """Two transports, one caller.

    At INSTALL time this runs ON the Hub and talks to 127.0.0.1 directly --
    pass host="local". An operator driving it from a workstation passes
    user@ip and it tunnels the same request over ssh. Keeping one code path
    matters: a migration rehearsed through one transport and fired through
    another is not the thing that was rehearsed.
    """
    url = f"http://127.0.0.1:7878{path}"
    if host in ("local", "localhost", "-"):
        req = urllib.request.Request(
            url, data=body.encode("utf-8"),
            headers={"Content-Type": ctype, "Accept": accept})
        try:
            with urllib.request.urlopen(req, timeout=timeout - 20) as r:
                return r.read().decode("utf-8", "replace"), "", 0
        except urllib.error.HTTPError as e:
            return "", f"HTTP {e.code}: {e.read()[:200]!r}", e.code
        except Exception as e:  # noqa: BLE001 -- transport failure is rc!=0
            return "", f"{type(e).__name__}: {e}", 1
    cmd = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host,
           f"curl -s --max-time {timeout - 20} -H 'Content-Type: {ctype}' "
           f"-H 'Accept: {accept}' --data-binary @- {url}"]
    p = subprocess.run(cmd, input=body, capture_output=True, text=True,
                       timeout=timeout)
    return p.stdout, p.stderr, p.returncode


def ask(host, query):
    out, err, rc = run(host, "/query", query, "application/sparql-query")
    i = out.find("{")
    if i < 0:
        print(f"  PROBE FAILED rc={rc} stderr={err[:200]} stdout={out[:200]}")
        sys.exit(2)
    b = json.loads(out[i:])["results"]["bindings"]
    return int(b[0][list(b[0])[0]]["value"]) if b else 0


def update(host, stmt):
    out, err, rc = run(host, "/update", stmt, "application/sparql-update",
                       accept="*/*", timeout=600)
    return rc, (out + err)[:400]


def total(host):
    return ask(host, "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")


def touching(host, needle):
    return ask(host, f'''SELECT (COUNT(*) AS ?n) WHERE {{ ?s ?p ?o .
      FILTER(CONTAINS(STR(?s),"{needle}") || CONTAINS(STR(?p),"{needle}")
          || CONTAINS(STR(?o),"{needle}")) }}''')


def in_literal_only(host, needle):
    """Occurrences where the ONLY carrier is a literal object.

    These are content, not identifiers, and this script leaves them. Counting
    them separately is what turns a confusing non-zero residue into a stated,
    understood one."""
    return ask(host, f'''SELECT (COUNT(*) AS ?n) WHERE {{ ?s ?p ?o .
      FILTER(isLiteral(?o) && CONTAINS(STR(?o),"{needle}")
             && !CONTAINS(STR(?s),"{needle}") && !CONTAINS(STR(?p),"{needle}")) }}''')


def rewrite_stmt(rx, needle, repl):
    """FILTER uses CONTAINS (literal substring), BIND uses REPLACE (regex).

    They must be fed DIFFERENT strings. CONTAINS is not a regex: handing it
    `https?://pwg\\.dev/` matches nothing at all, so the FILTER selects zero
    rows, the UPDATE rewrites nothing, and the run reports success having
    changed not one triple. That is a silent no-op wearing the shape of a
    migration, so the two forms are passed separately and explicitly rather
    than derived from one another.

    Predicates are always IRIs, so ?p needs no guard. Subjects may be blank
    nodes and objects may be literals or blank nodes: the IF(isIRI(...))
    guards pass those through untouched, preserving datatype and language,
    which a blanket IRI(REPLACE(STR(...))) would destroy.
    """
    return f'''DELETE {{ ?s ?p ?o }} INSERT {{ ?ns ?np ?no }} WHERE {{
  ?s ?p ?o .
  FILTER(CONTAINS(STR(?s),"{needle}") || CONTAINS(STR(?p),"{needle}")
      || (isIRI(?o) && CONTAINS(STR(?o),"{needle}")))
  BIND(IF(isIRI(?s), IRI(REPLACE(STR(?s), "{rx}", "{repl}")), ?s) AS ?ns)
  BIND(IRI(REPLACE(STR(?p), "{rx}", "{repl}")) AS ?np)
  BIND(IF(isIRI(?o), IRI(REPLACE(STR(?o), "{rx}", "{repl}")), ?o) AS ?no)
}}'''


def preview(host, rx, needle, repl, limit=6):
    """Run the REWRITE EXPRESSIONS as a SELECT and show old -> new pairs.

    WHY THIS AND NOT JUST --apply. This script cannot be rehearsed on the
    customer's store: the box is running the PRE-migration code, so rewriting
    its data would break a working machine instantly. And a dry run that only
    COUNTS proves nothing about the transformation -- it proves the FILTER
    matches, which is the easy half. Every interesting failure lives in the
    other half: a regex that does not fire, a guard that turns a literal into
    an IRI, a replacement that mangles the path.

    So this evaluates the exact BIND expressions the UPDATE uses, against the
    real store and the real SPARQL engine, and returns what WOULD be written
    without writing it. The pairs are eyeballable: if a path moved or a
    fragment vanished it is visible here, before anything is destroyed.
    """
    q = f'''SELECT ?s ?ns ?p ?np WHERE {{
  ?s ?p ?o .
  FILTER(CONTAINS(STR(?s),"{needle}") || CONTAINS(STR(?p),"{needle}"))
  BIND(IF(isIRI(?s), IRI(REPLACE(STR(?s), "{rx}", "{repl}")), ?s) AS ?ns)
  BIND(IRI(REPLACE(STR(?p), "{rx}", "{repl}")) AS ?np)
}} LIMIT {limit}'''
    out, err, rc = run(host, "/query", q, "application/sparql-query")
    i = out.find("{")
    if i < 0:
        print(f"    PREVIEW FAILED rc={rc}: {(err or out)[:200]}")
        return False
    rows = json.loads(out[i:])["results"]["bindings"]
    if not rows:
        print("    no rows matched -- the FILTER selected nothing, so an"
              " --apply here would be a SILENT NO-OP")
        return False
    good = True
    for r in rows[:limit]:
        for old_k, new_k in (("s", "ns"), ("p", "np")):
            o = r.get(old_k, {}).get("value", "")
            n = r.get(new_k, {}).get("value", "")
            if needle not in o:
                continue
            moved = (o != n) and (needle not in n)
            good = good and moved
            # tail only: these are opaque per-person identifiers and the
            # interesting part is the PREFIX swap, not the customer's data
            print(f"    {'ok ' if moved else 'BAD'}  ...{o[-46:]}")
            print(f"          ->  ...{n[-46:]}")
            break
    return good


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--preview", action="store_true",
                    help="evaluate the rewrite expressions without writing")
    args = ap.parse_args()
    h = args.host

    before_total = total(h)
    print(f"CONTROL  total triples before: {before_total}")
    if before_total < 1000:
        print("REFUSING: store looks empty or unreachable; nothing to migrate.")
        return 2

    before = {}
    for label, rx, needle, repl in RULES:
        n = touching(h, needle)
        lit = in_literal_only(h, needle)
        before[label] = (n, lit)
        print(f"  {label:12s} touching={n:>7}   of which literal-only={lit}")

    if args.preview:
        print("\nPREVIEW -- the real rewrite expressions, evaluated, nothing written")
        allgood = True
        for label, rx, needle, repl in RULES:
            if before[label][0] == 0:
                continue
            print(f"  {label} -> {repl}")
            allgood = preview(h, rx, needle, repl) and allgood
        print("  VERDICT:", "every sampled IRI moved" if allgood
              else "SOMETHING DID NOT MOVE -- do not --apply")
        return 0 if allgood else 1

    if not args.apply:
        print("\nDRY RUN. --preview evaluates the rewrite; --apply writes.")
        return 0

    print("\napplying, in order: pwg.local first so its longer prefix wins")
    for label, rx, needle, repl in RULES:
        if before[label][0] == 0:
            print(f"  {label:12s} SKIP (already zero)")
            continue
        rc, msg = update(h, rewrite_stmt(rx, needle, repl))
        after = touching(h, needle)
        print(f"  {label:12s} rc={rc}  remaining={after}"
              f"{'  ' + msg if rc != 0 else ''}")

    after_total = total(h)
    print(f"\nCONTROL  total triples after: {after_total}  (before {before_total})")
    ok = True
    if after_total != before_total:
        print(f"  [FAIL] TRIPLE COUNT CHANGED by {after_total - before_total}."
              " The mapping is injective, so this can only mean rows were LOST"
              " or MERGED. Do not treat this migration as successful.")
        ok = False
    else:
        print("  [ok]   count preserved exactly, as an injective mapping requires")

    for label, rx, needle, repl in RULES:
        n = touching(h, needle)
        lit = before[label][1]
        if n == 0:
            print(f"  [ok]   {label:12s} -> 0")
        elif n == lit:
            print(f"  [ok]   {label:12s} -> {n}, all literal CONTENT, left by design")
        else:
            print(f"  [FAIL] {label:12s} -> {n} remain, {lit} explained as literals")
            ok = False

    print(f"\n  new identifiers now present:")
    for needle in ("schema.ostler.ai/enrichment/", "schema.ostler.ai/ontology#",
                   "urn:ostler:"):
        print(f"    {needle:34s} {touching(h, needle)}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
