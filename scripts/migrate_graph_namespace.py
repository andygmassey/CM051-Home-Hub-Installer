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


def match_filter(needle):
    """THE ONE PREDICATE. Everything that claims to describe the migration
    is built from this string, so nothing can quietly describe a different one.

    🔴 THIS EXISTS BECAUSE --preview ANSWERED A DIFFERENT QUESTION THAN THE
    ONE THE OPERATOR WAS ASKING, CONFIDENTLY.

    --preview is the last screen a human reads before authorising a
    destructive whole-store rewrite. It shipped with its own hand-written
    predicate, and that predicate was NOT the one the UPDATE uses: it had no
    `?o` arm. So the two disagreed about which rows are even candidates.

    Measured on the live Hub store, 2026-08-21, READ ONLY. The preview's
    predicate against the UPDATE's predicate, same store, same moment:

        rule        preview saw    UPDATE touches    blind    unseen
        pwg.local         4,394             5,302      908     17.1%
        pwg.dev         242,322           242,830      508      0.2%
        urn:pwg:          3,762            20,299   16,537     81.5%

    A preview that under-reports is worse than no preview at all, because it
    manufactures the confidence the operator acts on. `VERDICT: every sampled
    IRI moved` reads as a statement about the migration. It was a statement
    about 19% of the rule that owns the customer's entire compartment.

    Two independent causes, and the decomposition separates them cleanly --
    each defect has its own witness rule, which is why both are named here
    rather than treated as one bug:

        pwg.local   blind 908 of 908 in the DEFAULT graph -- rows whose only
                    carrier is the object IRI. Purely the missing `?o` arm.
        urn:pwg:    blind 16,537 of 16,537 inside the NAMED graph. Purely the
                    missing UNION arm.

    Written once, called by the default-graph UPDATE, the named-graph UPDATE,
    the candidate count and the preview. A test asserts all four carry the
    identical string, because "we kept them in sync" is the claim that was
    already false.

    ON isIRI(?o), AND WHY THE PREVIEW COPIES IT RATHER THAN BROADENING IT.
    A literal object containing the string is CONTENT -- a stored query, a
    note -- and the module docstring above commits to not rewriting it. The
    preview must predict what --apply DOES, not what a reader might wish it
    did, so it inherits the guard verbatim. The literal-only rows are not
    silently dropped either: they are counted and printed beside the
    candidates as a stated exclusion, which is what turns a surprising
    residue afterwards into an expected one beforehand. Measured on the live
    store there are currently ZERO literal objects carrying any of the three
    needles, so this choice moves no rows today -- it is made for the day the
    data changes, and the printed count is what will show that day arriving.
    """
    return (f'CONTAINS(STR(?s),"{needle}") || CONTAINS(STR(?p),"{needle}")\n'
            f'      || (isIRI(?o) && CONTAINS(STR(?o),"{needle}"))')


def rewrite_binds(rx, repl):
    """The three BIND expressions, shared for the same reason as the FILTER.

    The preview's whole value is that it evaluates the REAL expressions
    against the REAL engine. A preview built from a re-typed copy proves the
    copy works.
    """
    return (f'BIND(IF(isIRI(?s), IRI(REPLACE(STR(?s), "{rx}", "{repl}")), ?s) AS ?ns)\n'
            f'  BIND(IRI(REPLACE(STR(?p), "{rx}", "{repl}")) AS ?np)\n'
            f'  BIND(IF(isIRI(?o), IRI(REPLACE(STR(?o), "{rx}", "{repl}")), ?o) AS ?no)')


# The two surfaces, named. ANY_GRAPH above unions them for a COUNT; the
# preview has to walk them SEPARATELY and this is why.
#
# 🔴 A `LIMIT 6` OVER A UNION IS NOT A SAMPLE OF THE UNION. The engine is
# free to satisfy the limit entirely from the first arm, and on this store it
# does: the default graph holds 248,550 of 265,087 triples, so six rows of a
# unioned sample are six DEFAULT-graph rows. For urn:pwg:, 81.5% of the
# candidates live in the named graph -- the surface a unioned sample would
# never once show. Fixing the COUNT and leaving the sample unioned would have
# produced an honest denominator over rows the operator still never sees.
SURFACES = (("default graph", "?s ?p ?o ."),
            ("named graphs", "GRAPH ?g { ?s ?p ?o }"))


def candidates(host, needle):
    """Rows the UPDATE would touch, counted per surface, using ITS predicate.

    This is the denominator. `touching()` above answers "how many triples
    mention this string at all", which includes literal content the migration
    deliberately leaves; this answers "how many rows will --apply rewrite",
    which is the only number a preview's coverage claim can honestly be a
    fraction of.
    """
    return [(label, ask(host, f"SELECT (COUNT(*) AS ?n) WHERE "
                              f"{{ {pattern} FILTER({match_filter(needle)}) }}"))
            for label, pattern in SURFACES]


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
  FILTER({match_filter(needle)})
  {rewrite_binds(rx, repl)}
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
  FILTER({match_filter(needle)})
  {rewrite_binds(rx, repl)}
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


def graph_transfer_stmts(old, new, dest_count):
    """Statements that move `old` into `new` WITHOUT destroying `new`.

    🔴 THIS FUNCTION USED TO RETURN A BARE `MOVE <old> TO <new>` AND THAT
    WOULD HAVE DELETED THE OPERATOR'S ENTIRE COMPARTMENT.

    SPARQL MOVE is defined as: DROP the destination, insert the source into
    it, drop the source. The old docstring justified that with "new_graph_iri
    is injective and the destination therefore cannot already hold ANYONE
    ELSE'S data". Injectivity was never the issue. The destination holds the
    SAME user's data -- already migrated -- and the sentence reasoned about
    the wrong owner.

    Measured on this box on 2026-08-21, after the migration had succeeded:

        urn:ostler:user/Andy   16577   <- the migrated compartment
        urn:pwg:user/Andy         20   <- rewritten since, by a live writer

    install.sh runs this script on EVERY install, including re-runs over an
    existing volume. The next one would have issued
    `MOVE <urn:pwg:user/Andy> TO <urn:ostler:user/Andy>`, dropping 16,577
    triples to make room for 20 -- and every check afterwards would have
    reported CLEAN, because the residue checks only ask whether OLD-namespace
    triples remain. They would not. The data would simply be gone.

    So: MOVE only into an empty or absent destination. When the destination is
    populated this is not a rename, it is a MERGE, and the lossless form is
    ADD (which does not touch the destination) followed by DROP of the source.
    That gives up MOVE's atomicity, and that trade is correct: the failure
    mode of ADD+DROP is a duplicate the next run cleans up, while the failure
    mode of MOVE is silent, permanent deletion of the customer's graph.
    """
    if dest_count > 0:
        return [f"ADD <{old}> TO <{new}>", f"DROP GRAPH <{old}>"]
    return [f"MOVE <{old}> TO <{new}>"]


def transfer_graphs(h):
    """The graph-name arm. EXTRACTED SO ITS WIRING CAN BE TESTED.

    🔴 THIS FUNCTION EXISTS BECAUSE THE TESTS ON #916 COULD NOT SEE THE BUG
    THEY WERE WRITTEN TO PREVENT.

    #916 fixed `graph_transfer_stmts` (never MOVE into a populated
    destination) and `graph_size` (raise rather than guess 0), and shipped ten
    tests, five of which went red against the old behaviour. Archie's
    adversarial reviewer then left BOTH of those functions byte-identical and
    changed exactly one line of the wiring in `main()`:

        -   dest_n = graph_size(h, new)
        +   dest_n = 0

    **The full data-destroying behaviour came back and the suite reported
    33 passed.** Reproduced here before this was written, not taken on report.

    The tests asserted on the PARTS. Nothing asserted that the parts were
    connected, because the connection lived in a 900-line `main()` that no
    test could drive. A guard that is wired in by inspection only is the same
    defect class the guard itself was written to remove.

    So the loop moves out here, where a test can stub `graphs`, `graph_size`
    and `update` and assert on the statements actually emitted. Behaviour is
    unchanged -- this is an extraction, not a rewrite.

    Returns (moved, stmts) so callers and tests read the same values the
    operator is shown.
    """
    moved, emitted = 0, []
    for g in graphs(h):
        new = new_graph_iri(g, RULES)
        if new == g:
            continue
        # SIZE THE DESTINATION FIRST. A populated destination means this is a
        # merge, not a rename, and MOVE would delete it. See
        # graph_transfer_stmts -- this is the 16,577-triple case.
        dest_n = graph_size(h, new)
        stmts = graph_transfer_stmts(g, new, dest_n)
        verb = "MOVE" if dest_n == 0 else "MERGE"
        if dest_n:
            print(f"  MERGE   <{new}> already holds {dest_n} triples, so this is"
                  " a MERGE, not a rename. Using ADD+DROP; MOVE would have"
                  " destroyed them.")
        rc, msg = 0, ""
        for s in stmts:
            emitted.append(s)
            rc, msg = update(h, s)
            if rc != 0:
                print(f"  [FAIL] {s[:60]} rc={rc} {msg}")
                break
        moved += 1
        print(f"  {verb:6s}  <{g}>\n       -> <{new}>  rc={rc}"
              f"{'  ' + msg if rc != 0 else ''}")
    if moved == 0:
        print("  MOVE    no graph name carried a pwg namespace")
    return moved, emitted


def graph_size(host, iri):
    """Triples in one named graph. 0 for a graph that does not exist."""
    rows = run(host, "/query",
               f"SELECT (COUNT(*) AS ?n) WHERE {{ GRAPH <{iri}> {{ ?s ?p ?o }} }}",
               "application/sparql-query")[0]
    try:
        return int(json.loads(rows)["results"]["bindings"][0]["n"]["value"])
    except Exception:  # noqa: BLE001 -- unreadable count must not read as empty
        raise RuntimeError(f"could not size graph <{iri}>; refusing to guess")


def preview_query(pattern, rx, needle, repl, limit):
    """The preview SELECT for ONE surface, built from the UPDATE's own parts.

    Same FILTER string, same BIND strings, one graph pattern swapped. That is
    the entire difference between what this shows and what --apply does, and
    it is the property the tests assert rather than assume.

    ?o and ?no are selected as well as ?s/?p, because the FILTER now matches
    on the object: a row whose ONLY carrier is the object IRI -- 908 of them
    in the default graph for pwg.local -- would otherwise be counted as
    examined and printed as nothing at all.
    """
    return f'''SELECT ?s ?ns ?p ?np ?o ?no WHERE {{
  {pattern}
  FILTER({match_filter(needle)})
  {rewrite_binds(rx, repl)}
}} LIMIT {limit}'''


def _show(v, w=52):
    # 🔴 TRUNCATE FROM THE RIGHT, NOT THE LEFT.
    #
    # This printed the last 46 characters, on the reasoning that the tail is
    # the opaque per-person identifier and the prefix is the interesting part.
    # Both halves of that are right and the code did the opposite of what it
    # concluded: a PREFIX rewrite changes only the head, so tail-truncation
    # cut off the entire diff. Run against the live store, every `urn:pwg:`
    # pair printed as two IDENTICAL lines while the rewrite was working
    # perfectly.
    #
    # An operator eyeballing that sees a migration doing nothing. The verdict
    # line said "every sampled IRI moved" -- computed from the real values --
    # so the text and the evidence beside it disagreed, and the text was the
    # one nobody could check.
    #
    # Head-first, and the tail elided instead. The customer identifier is what
    # gets cut, which is also the better privacy default for a migration
    # report someone may paste into a ticket.
    return v if len(v) <= w else v[:w] + "..."


def graph_sizes(host):
    """Named graphs WITH their triple counts.

    graphs() returns names only, and names alone cannot answer the one
    question the MOVE preview has to ask: what is standing where this graph
    is about to land, and how much of it is there.
    """
    out, err, rc = run(host, "/query",
                       "SELECT ?g (COUNT(*) AS ?n) WHERE"
                       " { GRAPH ?g { ?s ?p ?o } } GROUP BY ?g",
                       "application/sparql-query")
    i = out.find("{")
    if i < 0:
        print(f"  GRAPH SIZE PROBE FAILED rc={rc} stderr={err[:200]}")
        sys.exit(2)
    return {b["g"]["value"]: int(b["n"]["value"])
            for b in json.loads(out[i:])["results"]["bindings"]}


def preview_graph_names(sizes, rules):
    """The graph-NAME surface, previewed and folded into the verdict.

    🔴 A GRAPH NAME IS NOT A TRIPLE. No SELECT over ?s ?p ?o can see one, so
    a preview built entirely out of triple patterns reports a surface it has
    not looked at -- and it is the surface holding the customer's whole
    compartment. The live store's one named graph is called
    `urn:pwg:user/Andy`: a migration could rewrite all 265,087 triples,
    preview clean, verify clean against a triple-only residue check, and
    leave `pwg` in the NAME of the container.

    These move by SPARQL MOVE, computed in Python, so the preview is computed
    in Python too -- by calling new_graph_iri, the same function --apply
    calls. Counted with a denominator like everything else: N of M graphs
    carry a rule.

    🔴 AND IT CHECKS WHAT IS STANDING ON THE DESTINATION. `MOVE <a> TO <b>`
    DROPS <b> FIRST. That is SPARQL 1.1, not an Oxigraph quirk.

    move_graph_stmt's own docstring says overwriting is "correct here only
    because new_graph_iri is injective and the destination therefore cannot
    already hold anyone else's data". Injectivity was the wrong property to
    lean on. It rules out ANOTHER graph landing on the same target; it says
    nothing about the target ALREADY EXISTING, which is what happens the
    moment a migration is run twice with a live writer in between.

    Measured on the live Hub store, 2026-08-21 02:46Z, READ ONLY, and this is
    not hypothetical -- it is the state of the box right now:

        <urn:ostler:user/Andy>   16,577 triples   (migrated, an hour earlier)
        <urn:pwg:user/Andy>          20 triples   (re-created since, by a
                                                   writer still on old code)

    A second --apply computes `MOVE <urn:pwg:user/Andy> TO
    <urn:ostler:user/Andy>`, which DROPS the destination. 16,577 triples --
    the customer's entire compartment -- are destroyed to make room for 20,
    and every check downstream then passes: the residue is zero, no graph
    name carries pwg, and the run reports clean. The before/after total guard
    WOULD see the drop, but only after the fact, and by then the pre-migration
    backup has been superseded.

    So the preview refuses it. This is the last screen before the destructive
    step; a collision found here costs nothing, and found afterwards costs the
    compartment.
    """
    gs = list(sizes)
    print(f"  GRAPH NAMES -- {len(gs)} named graph(s) exist; no UPDATE can"
          " rewrite one")
    if not gs:
        print("    none. Nothing on this surface to move.")
        return True
    carrying = [g for g in gs if any(nd in g for _l, _r, nd, _p in rules)]
    print(f"    {len(carrying)} of {len(gs)} carry a pwg namespace"
          f" -- these are MOVEd by name, not rewritten")
    good = True
    for g in gs:
        new = new_graph_iri(g, rules)
        if new == g:
            print(f"    --   <{_show(g)}>  ({sizes[g]} triples; no rule fires,"
                  " left alone)")
            continue
        moved = not any(nd in new for _l, _r, nd, _p in rules)
        collides = new in sizes
        ok = moved and not collides
        good = good and ok
        print(f"    {'ok ' if ok else 'BAD'}  <{_show(g)}>  ({sizes[g]} triples)")
        print(f"      ->  <{_show(new)}>")
        if not moved:
            print("      [FAIL] the new name STILL carries a pwg namespace")
        if collides:
            print(f"      [FAIL] DESTINATION ALREADY EXISTS and holds"
                  f" {sizes[new]} triples. MOVE ... TO DROPS IT FIRST, so"
                  " --apply would")
            print(f"             destroy those {sizes[new]} triples to make"
                  f" room for {sizes[g]}. Merge them by hand, or DROP the"
                  " source if it is")
            print("             junk. Do NOT --apply.")
    return good


def preview(host, rx, needle, repl, touching_n, literal_n, limit=6):
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

    🔴 AND IT SAYS HOW MUCH OF THE SURFACE IT LOOKED AT. A VERDICT WITH NO
    DENOMINATOR IS THE FAILURE MODE THIS CODEBASE KEEPS HITTING.

    Six eyeballed rows out of 20,299 candidates is a fine thing to show and a
    terrible thing to summarise as "every sampled IRI moved" with the sample
    size left off the screen. The reader supplies the denominator they expect,
    and the one they expect is "all of it". So both numbers are printed, every
    time, on the same line: sampled N of POPULATION.

    Returns (good, sampled, population) so the caller can carry the fraction
    into the verdict instead of re-deriving or, as before, omitting it.
    """
    per_surface = candidates(host, needle)
    population = sum(n for _label, n in per_surface)
    breakdown = ", ".join(f"{label} {n}" for label, n in per_surface)
    print(f"    COVERAGE  {touching_n} triple(s) mention {needle!r} anywhere")
    print(f"              {population} match the rewrite predicate ({breakdown})")
    if literal_n:
        print(f"              {literal_n} carry it ONLY in a literal object"
              " -- content, left by design, and expected as residue")
    if touching_n != population + literal_n:
        print(f"              [warn] {touching_n} - {population} - {literal_n}"
              f" = {touching_n - population - literal_n} unaccounted; the"
              " numbers above do not close")

    good, sampled = True, 0
    for (label, pattern), (_l, n_here) in zip(SURFACES, per_surface):
        if n_here == 0:
            print(f"    {label}: 0 candidates, nothing to sample")
            continue
        q = preview_query(pattern, rx, needle, repl, limit)
        out, err, rc = run(host, "/query", q, "application/sparql-query")
        i = out.find("{")
        if i < 0:
            print(f"    PREVIEW FAILED on {label} rc={rc}: {(err or out)[:200]}")
            good = False
            continue
        rows = json.loads(out[i:])["results"]["bindings"]
        if not rows:
            # The COUNT said there are candidates and the SELECT returned
            # none. Same predicate, same surface, same engine, same second --
            # so this is not "nothing to do", it is the two halves of this
            # function disagreeing, and it must not read as success.
            print(f"    [FAIL] {label}: COUNT says {n_here} candidates but the"
                  " SELECT returned none. Do not --apply on this.")
            good = False
            continue
        print(f"    {label}: sampled {len(rows)} of {n_here}"
              f" ({100.0 * len(rows) / n_here:.2f}%)")
        sampled += len(rows)
        for r in rows[:limit]:
            shown = False
            for old_k, new_k in (("s", "ns"), ("p", "np"), ("o", "no")):
                o = r.get(old_k, {}).get("value", "")
                n = r.get(new_k, {}).get("value", "")
                if needle not in o:
                    continue
                # A literal object is passed through by design, so it is not
                # evidence for or against the rewrite firing. Skip it here
                # rather than scoring it BAD; it is already counted above.
                if old_k == "o" and r.get("o", {}).get("type") != "uri":
                    continue
                moved = (o != n) and (needle not in n)
                good, shown = good and moved, True
                print(f"    {'  ok ' if moved else '  BAD'} {old_k}  {_show(o)}")
                print(f"           ->  {_show(n)}")
                break
            if not shown:
                # The FILTER matched, so SOME term carries the needle, and the
                # loop above found none of s/p/o carrying it. That is not a
                # boring row to skip quietly -- it means the printer and the
                # predicate disagree about what matched, which is exactly the
                # class of bug that produced a confident empty preview before.
                print("    [FAIL] a row matched the FILTER but no term shown"
                      " carries the needle; the preview cannot explain it")
                good = False
    return good, sampled, population


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
        allgood, tot_sampled, tot_pop = True, 0, 0
        for label, rx, needle, repl in RULES:
            n, lit = before[label]
            if n == 0:
                print(f"  {label} -> {repl}\n    COVERAGE  0 triple(s) mention"
                      f" {needle!r} anywhere; nothing to preview")
                continue
            print(f"  {label} -> {repl}")
            ok, sampled, pop = preview(h, rx, needle, repl, n, lit)
            allgood = ok and allgood
            tot_sampled += sampled
            tot_pop += pop
        # The graph-name surface participates in the verdict. It used to be
        # printed above the preview and then left out of the conclusion, so a
        # clean VERDICT was compatible with a compartment still named urn:pwg:.
        sizes = graph_sizes(h)
        graphs_moving = sum(1 for g in sizes if new_graph_iri(g, RULES) != g)
        allgood = preview_graph_names(sizes, RULES) and allgood

        # 🔴 THE DENOMINATOR IS PART OF THE VERDICT, NOT A FOOTNOTE.
        pct = f"{100.0 * tot_sampled / tot_pop:.2f}%" if tot_pop else "n/a"
        print()
        if tot_pop == 0 and graphs_moving == 0:
            # 🔴 "every sampled IRI moved" OVER ZERO IRIs IS THE SAME
            # OVER-CLAIM IN ITS PUREST FORM: a success sentence about work
            # that does not exist. Seen for real -- this store was migrated by
            # another actor mid-review and the fixed preview promptly printed
            # `VERDICT: every sampled IRI moved / SAMPLED 0 of 0`. Nothing
            # about that is false, and an operator would read it as
            # confirmation the migration is good to run.
            print("  VERDICT: NOTHING TO MIGRATE. No triple and no graph name"
                  " carries a pwg namespace.")
            print("           This is not a statement that the rewrite works."
                  " It was not exercised.")
            return 0
        print(f"  VERDICT: {'every sampled IRI moved' if allgood else 'SOMETHING DID NOT MOVE -- do not --apply'}")
        print(f"           SAMPLED {tot_sampled} of {tot_pop} candidate"
              f" triple(s) ({pct}); graph names checked IN FULL"
              f" ({graphs_moving} of {len(sizes)} move).")
        if allgood:
            print("           This is a SAMPLE of the triples. It proves the"
                  " expressions fire on both")
            print("           surfaces; it does NOT prove every row moves."
                  " The control that covers")
            print("           every row is the before/after total, and it runs"
                  " during --apply.")
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
    transfer_graphs(h)

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
