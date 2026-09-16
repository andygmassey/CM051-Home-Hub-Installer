#!/usr/bin/env python3
"""CM051 #1690 behavioural check, driven by
tests/test_the_owner_node_is_minted_and_named_once.sh.

THE DEFECT. `pwg:user_<id>` is the owner / me-card anchor: the OBJECT of
every `pwg:belongsToUser` triple, and the identity the privacy layer
branches on. CM041 ships a writer that mints it
(`contact_syncer/owner_node.py`) and CM041 #154 fixed that writer so it can
no longer accumulate a second display name on the one node whose job is to
answer "who is the owner". Both were inert on a customer box, because
NOTHING CALLED IT: `--mint-owner` and `contact_syncer.owner_node` had three
references repo-wide and all three were inside owner_node.py and syncer.py
themselves, against a positive control (`--vcf`, a flag install.sh really
passes) of six hits in install.sh.

WHAT THIS ASSERTS, AND WHY IT IS NOT A GREP. It executes the SPARQL the
SHIPPED vendored module actually emits against a REAL SPARQL 1.1 engine
(rdflib) and reads the resulting graph back. A grep for
`FILTER NOT EXISTS` proves a string is in a file; it cannot tell you
whether the owner ends up carrying one name or two, which is the only
question a customer can see the answer to.

The tier rule this protects is Andy's locked one: display-name overwrites
go UPWARD ONLY, phone < email < human. `build_owner_sparql` is allowed to
DECLINE and never to overwrite, so it can never move a name down a tier.
Arm 4 is that property; arm 5 is the mutation that proves arm 1 and arm 4
can fail.

Rule 0: every name below is synthetic.

Emits one `PASS: ` / `FAIL: ` line per assertion. Never a raw traceback.
"""

from __future__ import annotations

import pathlib
import sys

RESULTS: list[str] = []


def ok(msg: str) -> None:
    RESULTS.append("PASS: " + msg)


def bad(msg: str) -> None:
    RESULTS.append("FAIL: " + msg)


def die(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


PWG = "https://schema.ostler.ai/ontology#"
OWNER = PWG + "user_jane"

# Synthetic throughout. "Jane Doe" is the customer's own typed answer to
# "what should your assistant call you?"; "Jane Q. Doe" stands for a better
# name that arrived from a real address book first.
TYPED_NAME = "Jane Doe"
BETTER_NAME = "Jane Q. Doe"
NOW = "2026-01-01T00:00:00+00:00"


def names(graph) -> list[str]:
    """Every pwg:displayName on the owner node, as plain strings."""
    q = (
        "PREFIX pwg: <%s>\n"
        "SELECT ?n WHERE { <%s> pwg:displayName ?n }" % (PWG, OWNER)
    )
    return sorted(str(row[0]) for row in graph.query(q))


def ask(graph, pattern: str) -> bool:
    q = "PREFIX pwg: <%s>\nASK { %s }" % (PWG, pattern)
    return bool(graph.query(q).askAnswer)


def main(repo: pathlib.Path) -> int:
    try:
        import rdflib  # noqa: F401
    except Exception as exc:  # pragma: no cover - reported, never swallowed
        die(
            "rdflib is not importable (%s). This check EXECUTES SPARQL; without "
            "an engine it would measure nothing, and measuring nothing is not a "
            "pass. Install rdflib." % exc
        )

    src = repo / "vendor" / "cm041"
    module = src / "contact_syncer" / "owner_node.py"
    if not module.is_file():
        die("the shipped writer is missing at %s" % module)

    # The vendored tree goes FIRST on the path. The repo root carries its own
    # top-level contact_syncer/ twin, and `cd`-ing anywhere near it silently
    # imports the wrong copy -- measured while writing this: the twin has no
    # owner_node at all, so the import fails in a way that reads as "the fix is
    # gone" rather than "you loaded the other package".
    sys.path.insert(0, str(src))
    try:
        from contact_syncer import owner_node  # type: ignore[import-untyped]
    except Exception as exc:
        die("cannot import the shipped contact_syncer.owner_node: %r" % exc)

    loaded = pathlib.Path(owner_node.__file__).resolve()
    if loaded != module.resolve():
        die(
            "imported the WRONG copy: %s, expected the vendored %s. Every "
            "assertion below would be about a file that does not ship."
            % (loaded, module.resolve())
        )
    ok("the module under test is the vendored copy that ships (%s)"
       % loaded.relative_to(repo))

    if owner_node.PWG_NS != PWG:
        die(
            "the shipped namespace is %r, this check asserts %r. A namespace "
            "change makes every query below match nothing and read as clean."
            % (owner_node.PWG_NS, PWG)
        )
    if owner_node.owner_uri("jane") != OWNER:
        die("owner_uri('jane') is %r, expected %r"
            % (owner_node.owner_uri("jane"), OWNER))
    ok("owner_uri derives the IRI this check queries (no silent namespace drift)")

    sparql = owner_node.build_owner_sparql("jane", TYPED_NAME, now_iso=NOW)

    # -- arm 1: a bare graph gets a complete owner node with ONE name --------
    g = rdflib.Graph()
    before = len(g)
    try:
        g.update(sparql)
    except Exception as exc:
        die("the shipped SPARQL did not execute: %r" % exc)
    if len(g) <= before:
        die(
            "the update added no triples (%d -> %d). Every assertion below "
            "would pass on an engine that silently does nothing."
            % (before, len(g))
        )
    ok("the shipped SPARQL executes and writes (%d triples from a bare graph)"
       % len(g))

    got = names(g)
    if got == [TYPED_NAME]:
        ok("a bare owner node ends with EXACTLY ONE display name, the customer's own")
    else:
        bad("a bare owner node ended with %d display name(s): %r" % (len(got), got))

    for pattern, label in (
        ("<%s> a pwg:Person" % OWNER, "a pwg:Person, so the owner has a person node at all"),
        ('<%s> pwg:isOwner true' % OWNER, "pwg:isOwner true, the flag privacy branching reads"),
        ('<%s> pwg:privacyLevel "L0"' % OWNER, "privacyLevel L0, the owner's own identity"),
    ):
        if ask(g, pattern):
            ok("the minted owner node is " + label)
        else:
            bad("the minted owner node is NOT " + label)

    # -- arm 2: idempotent. The install may run twice; a customer may re-run --
    g.update(owner_node.build_owner_sparql("jane", TYPED_NAME, now_iso=NOW))
    got = names(g)
    if got == [TYPED_NAME]:
        ok("a SECOND mint leaves exactly one display name (idempotent)")
    else:
        bad("a second mint left %d display name(s): %r -- the owner node "
            "accumulates, which is #1690's original defect" % (len(got), got))

    # -- arm 3: a DIFFERENT typed name on a second run still does not add ----
    # The install re-asks the question on a repair run, and a customer who
    # answers differently must not end up with two names on the anchor node.
    g.update(owner_node.build_owner_sparql("jane", "Janet Doe", now_iso=NOW))
    got = names(g)
    if got == [TYPED_NAME]:
        ok("a re-run with a DIFFERENT name still leaves one name, the first")
    else:
        bad("a re-run with a different name left %r" % (got,))

    # -- arm 4: it DECLINES, it does not clobber -----------------------------
    # The locked tier rule: overwrites go upward only. A writer that can only
    # decline can never move a name DOWN a tier, which is why this is the
    # shape to keep.
    g4 = rdflib.Graph()
    g4.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s> pwg:displayName "%s" . }'
        % (PWG, OWNER, BETTER_NAME)
    )
    g4.update(sparql)
    got = names(g4)
    if got == [BETTER_NAME]:
        ok("a name that arrived first SURVIVES the mint (declines, never clobbers)")
    else:
        bad("the mint overwrote or duplicated a pre-existing name: %r" % (got,))
    if ask(g4, "<%s> pwg:isOwner true" % OWNER):
        ok("and the structural triples still land on a node that already had a name")
    else:
        bad("declining the name also dropped the structural triples -- the owner "
            "node would never be minted on a graph that already named it")

    # -- arm 5: MUTATION. Reintroduce the pre-#154 shape --------------------
    # The old writer put displayName inside the INSERT DATA block. On a fixed,
    # deterministic owner IRI that is additive, so a node that has since
    # acquired a name ends up with two. If this arm does NOT produce two names
    # then the engine is not discriminating and arms 1-4 prove nothing.
    old_shape = (
        "PREFIX pwg: <%s>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {\n"
        "  <%s> a pwg:Person ;\n"
        '    pwg:displayName "%s" ;\n'
        '    pwg:privacyLevel "L0" ;\n'
        "    pwg:isOwner true .\n"
        "}" % (PWG, OWNER, TYPED_NAME)
    )
    g5 = rdflib.Graph()
    g5.update(
        'PREFIX pwg: <%s> INSERT DATA { <%s> pwg:displayName "%s" . }'
        % (PWG, OWNER, BETTER_NAME)
    )
    g5.update(old_shape)
    got = names(g5)
    if len(got) == 2:
        ok("MUTATION CONTROL: the pre-#154 INSERT DATA shape leaves TWO names, "
           "so arms 1-4 are capable of failing")
    else:
        bad("MUTATION CONTROL DID NOT FIRE: the old shape left %d name(s) %r. "
            "The engine is not discriminating and every green above is vacuous."
            % (len(got), got))

    for line in RESULTS:
        print(line)
    return 1 if any(r.startswith("FAIL") for r in RESULTS) else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        die("usage: check_owner_node_mint.py <repo-root>")
    raise SystemExit(main(pathlib.Path(sys.argv[1]).resolve()))
