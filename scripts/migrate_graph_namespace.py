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

THE MAPPING IS NOT INJECTIVE IN GENERAL. IT IS INJECTIVE ON THIS STORE, WHICH
IS A MEASUREMENT, NOT A PROOF.

🔴 This block used to open "THE MAPPING IS INJECTIVE AND THAT IS THE
LOAD-BEARING CONTROL". That was an assumed property stated as a proven one,
and Archie was right to make me correct it (#888 F5): stating it that way is
what made #909 hard to see. The rules DO collide by direct call --

    https://pwg.local/x        -> https://schema.ostler.ai/enrichment/x
    https://pwg.dev/enrichment/x -> https://schema.ostler.ai/enrichment/x

-- so two distinct source IRIs CAN land on one target. What is true is
narrower and it is measured, not assumed: no such IRI exists in this store,
and the store holds exactly one named graph, so no collision is reachable
here today. That is a fact about the DATA and it expires the moment the data
changes.

The actual load-bearing control is therefore the count, not the claim: the
TOTAL TRIPLE COUNT MUST BE IDENTICAL either side. If it drops, triples merged
or were lost -- whether or not anyone predicted the collision -- and this
script refuses rather than reporting a clean migration. That check does not
depend on the mapping being injective, which is exactly why it is the one to
lean on.

A rewrite that silently loses rows is the worst outcome available here -- it
looks exactly like success from the outside, which is the failure mode this
whole codebase keeps re-learning.

LITERALS ARE NOT REWRITTEN. Only IRIs move. A literal that happens to contain
the string (a stored query, a note) is CONTENT, not an identifier, and
rewriting content is not this script's job. Those are counted and reported
separately so the residue is explained rather than discovered later.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

# 🔴 NEVER GO THROUGH A PROXY TO REACH THE LOCAL STORE. This machine sets
# HTTP_PROXY=http://127.0.0.1:8118, and urllib honours it for loopback too.
# The store is on localhost, so every request here was being answered by
# Privoxy: the probe got "503 Forwarding failure", which is indistinguishable
# from an absent Oxigraph, so the script returned CANNOT-RUN, install.sh
# mapped rc=2 to silence, the store was never migrated, and the wiki rendered
# empty at exit 0. Archie's F3, and it is live on this box today.
#
# An empty ProxyHandler means "no proxies", and it must be used for BOTH the
# GET and the POST or the half that is missed reintroduces the whole failure.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

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


def _nquads_terms(line):
    """Term kinds on one N-Quads line, or None if it does not parse.

    Whitespace is not a term separator in N-Quads: a literal may contain any
    amount of it. `<s> <p> "Hello there world" .` is a three-term DEFAULT
    GRAPH triple that a naive split reads as four terms, and the backup guard
    that counted tokens accepted a dump with no named graphs in it at all.

    So walk the line and consume whole terms: <iri>, "literal" with its
    optional ^^<datatype> or @lang suffix, and _:blank. Returns a list like
    ['iri', 'iri', 'literal'] -- kinds, not values, because the guard only
    needs the arity and the kind of the last term.
    """
    kinds, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c.isspace():
            i += 1
        elif c == "." and not line[i + 1:].strip():
            break                                   # statement terminator
        elif c == "<":
            j = line.find(">", i)
            if j < 0:
                return None
            i, _ = j + 1, kinds.append("iri")
        elif c == '"':
            j = i + 1
            while j < n and line[j] != '"':
                j += 2 if line[j] == "\\" else 1     # skip escaped chars
            if j >= n:
                return None
            j += 1
            if line[j:j + 2] == "^^":               # typed literal
                k = line.find(">", j)
                if k < 0:
                    return None
                j = k + 1
            elif line[j:j + 1] == "@":              # language tag
                while j < n and not line[j].isspace():
                    j += 1
            i, _ = j, kinds.append("literal")
        elif line[i:i + 2] == "_:":
            j = i
            while j < n and not line[j].isspace():
                j += 1
            i, _ = j, kinds.append("bnode")
        else:
            return None                             # comment, junk, or @base
    return kinds


def _nquads_is_quad(line):
    """True only for a line that names a graph: four terms, 4th an IRI/bnode."""
    kinds = _nquads_terms(line)
    return bool(kinds) and len(kinds) == 4 and kinds[3] in ("iri", "bnode")


def _get(host, url, accept, timeout):
    """A real GET, because the backup is a READ and run() only ever POSTs.

    🔴 THIS EXISTS BECAUSE THE BACKUP COULD NOT SUCCEED AND I WIRED IT INTO
    install.sh ANYWAY.

    run() always passes `--data-binary @-`, which makes every request a POST.
    Sent at /store that is an ADD-NOTHING, not a dump. Measured on the live box:

        POST /store?graph=   (as it was)          0 bytes      0 named-graph lines
        GET  /store?graph=default                52 bytes      0 named-graph lines
        GET  /store                      33,335,681 bytes  6,108 named-graph lines

    Follow that through the install path: backup returns 0 bytes, the size guard
    fires, the script exits 2, rc=2 is CANNOT-RUN and deliberately non-fatal, the
    install continues -- AND THE STORE IS NEVER MIGRATED. The compiler then
    queries schema.ostler.ai against a store holding only pwg.dev, the customer's
    wiki renders blank, and nothing anywhere goes red.

    The non-fatal choice was right. Combined with a backup that could not
    succeed, it was a silent no-op on every install, and I built the silence.

    `/store` with no graph parameter is the request that returns the WHOLE store
    including named graphs -- which is exactly what the N-Quads reasoning above
    asks for, and what `?graph=default` cannot give.
    """
    if host in ("local", "localhost", "-"):
        req = urllib.request.Request(url, method="GET",
                                     headers={"Accept": accept})
        try:
            with _OPENER.open(req, timeout=timeout - 20) as r:
                return r.read().decode("utf-8", "replace"), "", 0
        except urllib.error.HTTPError as e:
            return "", f"HTTP {e.code}: {e.read()[:200]!r}", e.code
        except Exception as e:  # noqa: BLE001
            return "", f"{type(e).__name__}: {e}", 1
    cmd = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host,
           f"curl -s --noproxy '*' --fail-with-body --max-time {timeout - 20} "
           f"-H 'Accept: {accept}' {url}"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.stdout, p.stderr, p.returncode


def run(host, path, body, ctype, accept="application/sparql-results+json",
        timeout=300, method="POST"):
    """Two transports, one caller.

    At INSTALL time this runs ON the Hub and talks to 127.0.0.1 directly --
    pass host="local". An operator driving it from a workstation passes
    user@ip and it tunnels the same request over ssh. Keeping one code path
    matters: a migration rehearsed through one transport and fired through
    another is not the thing that was rehearsed.
    """
    url = f"http://127.0.0.1:7878{path}"
    if method == "GET":
        return _get(host, url, accept, timeout)
    if host in ("local", "localhost", "-"):
        req = urllib.request.Request(
            url, data=body.encode("utf-8"),
            headers={"Content-Type": ctype, "Accept": accept})
        try:
            with _OPENER.open(req, timeout=timeout - 20) as r:
                return r.read().decode("utf-8", "replace"), "", 0
        except urllib.error.HTTPError as e:
            return "", f"HTTP {e.code}: {e.read()[:200]!r}", e.code
        except Exception as e:  # noqa: BLE001 -- transport failure is rc!=0
            return "", f"{type(e).__name__}: {e}", 1
    # --fail-with-body, NOT bare -s. Without it a 400 from Oxigraph comes back
    # as rc=0 with an error page in stdout, so the ssh path reports success on
    # a rejected UPDATE while the local path raises HTTPError -- two transports
    # disagreeing about what failure means, in the one script whose whole point
    # is that both transports run the identical thing.
    cmd = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host,
           f"curl -s --noproxy '*' --fail-with-body --max-time {timeout - 20} "
           f"-H 'Content-Type: {ctype}' "
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


# 🔴 EVERY COUNT BELOW SPANS BOTH SURFACES, AND THE FIRST VERSION DID NOT.
#
# A bare `WHERE { ?s ?p ?o }` on this store is DEFAULT-GRAPH-ONLY. The repo
# proves it rather than leaving it to be assumed: `compartment.py:475
# assert_default_graph_isolated()` exists to prove the default graph is not the
# union, and raises if it is -- compartment isolation depends on that.
#
# So the original total() called a subset "the total", the UPDATE never touched
# a named graph, and the residue check could not see what the UPDATE had missed.
# BOTH SIDES OF THE GUARD WERE BLIND THE SAME WAY, so the run printed
# `[ok] pwg.dev -> 0` over data it had never once looked at.
#
# Measured on the live Hub store, 2026-08-21, which is what turned this from an
# argument into a number:
#
#     default graph   total 235,321   pwg-bearing 234,508
#     NAMED graphs    total  11,238   pwg-bearing  11,238   <- 100%, all missed
#     real total     246,559          (the script previously reported 235,321)
#
# The UNION arm is the fix. `{ ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } }`
# spans default and named, and is what every probe here now uses.
ANY_GRAPH = "{ ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } }"


def total(host):
    return ask(host, f"SELECT (COUNT(*) AS ?n) WHERE {{ {ANY_GRAPH} }}")


def touching(host, needle):
    return ask(host, f'''SELECT (COUNT(*) AS ?n) WHERE {{ {ANY_GRAPH}
      FILTER(CONTAINS(STR(?s),"{needle}") || CONTAINS(STR(?p),"{needle}")
          || CONTAINS(STR(?o),"{needle}")) }}''')


def graphs(host):
    """Every named graph IRI in the store.

    🔴 A GRAPH NAME IS NOT A TRIPLE, AND NO UPDATE CAN REWRITE ONE.

    The live store holds exactly one named graph and it is called
    `urn:pwg:user/Andy` -- the namespace is in the NAME. A triple-level
    DELETE/INSERT, however well written and whether or not it is GRAPH-scoped,
    cannot touch that: there is no ?s ?p ?o binding whose subject is the graph.

    Left alone, a migration could rewrite all 246,559 triples, report zero
    residue against a triple-only predicate, and leave `pwg` in the name of the
    graph holding the customer's entire personal compartment.

    Graphs therefore get MOVEd explicitly, by name, computed in Python -- SPARQL
    MOVE takes literal IRIs and not expressions, so this cannot be folded into
    the UPDATE even in principle.
    """
    out, err, rc = run(host, "/query",
                       "SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }",
                       "application/sparql-query")
    i = out.find("{")
    if i < 0:
        print(f"  GRAPH PROBE FAILED rc={rc} stderr={err[:200]}")
        sys.exit(2)
    return [b["g"]["value"] for b in json.loads(out[i:])["results"]["bindings"]]


def in_literal_only(host, needle):
    """Occurrences where the ONLY carrier is a literal object.

    These are content, not identifiers, and this script leaves them. Counting
    them separately is what turns a confusing non-zero residue into a stated,
    understood one."""
    return ask(host, f'''SELECT (COUNT(*) AS ?n) WHERE {{ {ANY_GRAPH}
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


def rewrite_named_stmt(rx, needle, repl):
    """The same rewrite, scoped INSIDE each named graph.

    Identical predicate and identical BIND guards -- deliberately, so the two
    arms cannot drift into treating the same triple differently depending on
    which graph it happens to live in. The only difference is the GRAPH ?g
    wrapper, which is the entire reason the first version missed 11,238 triples.

    ?g is bound by the WHERE and reused in both DELETE and INSERT, so every
    triple is rewritten back into the graph it came from. It does NOT rename the
    graph; that is move_graph_stmt's job and it cannot be done here.
    """
    return f'''DELETE {{ GRAPH ?g {{ ?s ?p ?o }} }}
INSERT {{ GRAPH ?g {{ ?ns ?np ?no }} }} WHERE {{
  GRAPH ?g {{ ?s ?p ?o }}
  FILTER(CONTAINS(STR(?s),"{needle}") || CONTAINS(STR(?p),"{needle}")
      || (isIRI(?o) && CONTAINS(STR(?o),"{needle}")))
  BIND(IF(isIRI(?s), IRI(REPLACE(STR(?s), "{rx}", "{repl}")), ?s) AS ?ns)
  BIND(IRI(REPLACE(STR(?p), "{rx}", "{repl}")) AS ?np)
  BIND(IF(isIRI(?o), IRI(REPLACE(STR(?o), "{rx}", "{repl}")), ?o) AS ?no)
}}'''


def new_graph_iri(old, rules):
    """Apply the same rules to a graph NAME, in Python.

    Same mapping as the triples, so a graph and its contents cannot end up in
    different namespaces. Returns the original unchanged if no rule fires, and
    the caller treats that as "nothing to move" rather than moving a graph onto
    itself, which SPARQL treats as a no-op but which would read as work done.
    """
    out = old
    for _label, rx, _needle, repl in rules:
        out = re.sub(rx.replace("\\\\", "\\"), repl, out)
    return out


def move_graph_stmt(old, new):
    """MOVE, not DROP+INSERT.

    MOVE is atomic in the engine and carries every triple; a hand-rolled
    ADD-then-DROP has a window in which the data exists twice, and a failure
    between the two halves leaves the store holding both a migrated and an
    unmigrated copy of the customer's compartment. `TO` overwrites the
    destination, which is correct here only because new_graph_iri is injective
    and the destination therefore cannot already hold anyone else's data.
    """
    return f"MOVE <{old}> TO <{new}>"


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
            # 🔴 TRUNCATE FROM THE RIGHT, NOT THE LEFT.
            #
            # This printed the last 46 characters, on the reasoning that the
            # tail is the opaque per-person identifier and the prefix is the
            # interesting part. Both halves of that are right and the code did
            # the opposite of what it concluded: a PREFIX rewrite changes only
            # the head, so tail-truncation cut off the entire diff. Run against
            # the live store, every `urn:pwg:` pair printed as two IDENTICAL
            # lines while the rewrite was working perfectly.
            #
            # An operator eyeballing that sees a migration doing nothing. The
            # verdict line said "every sampled IRI moved" -- computed from the
            # real values -- so the text and the evidence beside it disagreed,
            # and the text was the one nobody could check.
            #
            # Head-first, and the tail elided instead. The customer identifier
            # is what gets cut, which is also the better privacy default for a
            # migration report someone may paste into a ticket.
            def _show(v, w=52):
                return v if len(v) <= w else v[:w] + "..."
            print(f"    {'ok ' if moved else 'BAD'}  {_show(o)}")
            print(f"          ->  {_show(n)}")
            break
    return good


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--preview", action="store_true",
                    help="evaluate the rewrite expressions without writing")
    ap.add_argument("--no-backup", action="store_true",
                    help="skip the pre-migration N-Quads dump (say why)")
    ap.add_argument("--backup-path", default="ostler-graph-backup.nq",
                    help="where to write the pre-migration N-Quads dump")
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

    # Show the named graphs up front. An operator reading a migration report
    # should not have to infer that a second surface exists.
    gs = graphs(h)
    print(f"  named graphs: {len(gs)}")
    for g in gs:
        new = new_graph_iri(g, RULES)
        print(f"    <{g}>" + ("" if new == g else f"  ->  <{new}>"))

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

    # BACKUP FIRST. This is a destructive rewrite of a live personal store and
    # every other control in this script is POST-HOC -- they tell you it went
    # wrong, none of them puts the data back. N-Quads, not Turtle: Turtle
    # cannot express a named graph, so a Turtle dump of this store would
    # silently omit the 11,238 triples that live in one, and the backup would
    # have the same blind spot as the bug.
    if not args.no_backup:
        out, err, rc = run(h, "/store", "", "application/n-quads",
                           accept="application/n-quads", timeout=600,
                           method="GET")
        # 🔴 SIZE IS NOT THE ASSERTION. A byte count cannot tell a whole-store
        # dump from a default-graph-only one -- 52 bytes and 33MB both pass a
        # ">1000" test if the tree is small, and the ONE thing this backup
        # exists to protect is the named graph holding the compartment.
        # So assert the SHAPE: N-Quads writes a fourth term ONLY for a
        # quad in a named graph, so at least one four-term line is positive
        # proof the compartment was captured. Archie's closing condition, and
        # it is the right one: a backup that cannot prove it captured the
        # compartment has the same blindness as the bug it insures against.
        #
        # 🔴 AND A WHITESPACE SPLIT IS NOT THE SHAPE EITHER. Archie built a
        # backup with ZERO named-graph quads and it PASSED this guard: the
        # first version counted `len(ln.rstrip(" .").split()) >= 4`, and
        #     <s> <p> "Hello there world" .
        # is a DEFAULT-GRAPH triple that splits into four tokens. On the real
        # dump that scored 43,399 "quads" when only 12,367 are real, and on a
        # named-graph-free backup it still scored 31,032 -- so the byte check
        # was doing all the work, which is precisely what the note above says
        # must not happen. The guard could not fail, and a guard that cannot
        # fail is not insurance.
        #
        # Count with a real term parser instead: a quad is four terms whose
        # fourth is an IRI or blank node. See _nquads_is_quad.
        quads = sum(1 for ln in out.splitlines() if _nquads_is_quad(ln))
        if rc != 0 or len(out) < 1000 or quads < 1:
            print(f"  [FAIL] BACKUP FAILED rc={rc} bytes={len(out)} "
                  f"named-graph-lines={quads}: {(err or out)[:200]}")
            print("  A backup with zero four-term lines did not capture the"
                  " named graph, so it cannot restore the compartment.")
            print("  Refusing to migrate without one. --no-backup overrides,"
                  " and you should be able to say why.")
            return 2
        # 🔴 NEVER CLOBBER AN EARLIER BACKUP. This block is unconditional and
        # runs BEFORE the already-migrated skip, at a FIXED path, and
        # install.sh:19546 invokes this script on every install. So on the
        # second install over an existing volume -- the Studio, .224, the
        # beta boxes, the box walk, precisely the population that has data
        # worth insuring -- the pre-migration dump was overwritten by a
        # post-migration one. The only recovery artefact survived exactly one
        # re-run, and it destroyed itself at the moment it was needed.
        #
        # The FIRST dump is the valuable one, because only it predates the
        # rewrite. Later runs write beside it and say so.
        backup_path = args.backup_path
        if os.path.exists(backup_path):
            stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
            backup_path = f"{args.backup_path}.{stamp}"
            n = 0
            while os.path.exists(backup_path):        # same-second re-runs
                n += 1
                backup_path = f"{args.backup_path}.{stamp}.{n}"
            print(f"  BACKUP  {args.backup_path} already exists and is NOT being"
                  " overwritten -- it may be the only copy that predates a"
                  " previous migration.")
        with open(backup_path, "w", encoding="utf-8") as fh:
            fh.write(out)
        print(f"  BACKUP  {len(out)} bytes, {quads} named-graph quads"
              f" -> {backup_path}")

    print("\napplying, in order: pwg.local first so its longer prefix wins")
    for label, rx, needle, repl in RULES:
        if before[label][0] == 0:
            print(f"  {label:12s} SKIP (already zero)")
            continue
        rc, msg = update(h, rewrite_stmt(rx, needle, repl))
        # THE NAMED-GRAPH ARM. Same rules, same order, run immediately after
        # the default-graph arm so a rule can never be half-applied across the
        # two surfaces if a later rule fails.
        rcg, msgg = update(h, rewrite_named_stmt(rx, needle, repl))
        after = touching(h, needle)
        print(f"  {label:12s} default rc={rc}  named rc={rcg}  remaining={after}"
              f"{'  ' + (msg or msgg) if (rc or rcg) else ''}")

    # GRAPH NAMES, WHICH NO UPDATE ABOVE COULD HAVE TOUCHED.
    moved = 0
    for g in graphs(h):
        new = new_graph_iri(g, RULES)
        if new == g:
            continue
        rc, msg = update(h, move_graph_stmt(g, new))
        moved += 1
        print(f"  MOVE    <{g}>\n       -> <{new}>  rc={rc}"
              f"{'  ' + msg if rc != 0 else ''}")
    if moved == 0:
        print("  MOVE    no graph name carried a pwg namespace")

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

    # THE THIRD SURFACE. A triple-only residue check reports zero over a graph
    # still NAMED urn:pwg:user/Andy, because a graph name is not a triple. This
    # is the arm that would have caught the original version, so it is asserted
    # separately rather than folded into the loop above.
    residual_graphs = [g for g in graphs(h)
                       if any(nd in g for _l, _r, nd, _p in RULES)]
    if residual_graphs:
        print(f"  [FAIL] {len(residual_graphs)} GRAPH NAME(S) still carry a pwg"
              " namespace -- the triples moved, the container did not:")
        for g in residual_graphs:
            print(f"           <{g}>")
        ok = False
    else:
        print("  [ok]   no graph NAME carries a pwg namespace")

    print(f"\n  new identifiers now present:")
    for needle in ("schema.ostler.ai/enrichment/", "schema.ostler.ai/ontology#",
                   "urn:ostler:"):
        print(f"    {needle:34s} {touching(h, needle)}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
