"""Elect ONE canonical display name for a person, demote the rest.

WHY THIS EXISTS (2026-08-08)
============================
The operator asked the assistant who his wife was. She had been told, correctly, that it is
Jane Doe -- and the fact came back attributed to "Mum".

It was not a dedupe failure. The merge worked perfectly: one node,
``person_<uuid>``, carrying every identifier she has (two phones, four
email addresses, two ABPerson UUIDs). The failure is that the same node carries
SIX competing ``pwg:displayName`` triples:

    Jane Doe · Mum · +44<digits> · +852<digits>
    jane.doe@icloud.example · jdoe@mac.example

Nothing marks which is canonical, so every consumer picks arbitrarily. CM044
papers over it with a tie-break in its own loader, which is why the wiki mostly
shows the right thing; the assistant reads the graph directly and gets whatever
the store returns first. A fix in CM044 alone would leave Ava still saying
"Mum".

HOW SIX NAMES GET ONTO ONE NODE
-------------------------------
``contact_syncer`` is well behaved: it DELETEs ``pwg:displayName`` before
reinserting (syncer.py ~line 826), so it holds one value. The other writers --
iMessage, WhatsApp, email ingest -- only ever INSERT. Each contributes the
label it happened to know the person by: a phone number, an address, the
nickname in the address book. Merge two such nodes and the names accumulate.

THE RULE
--------
A person has exactly one ``pwg:displayName``. Most other values the graph
knows them by become a ``pwg:alternateName``.

BARE KINSHIP WORDS ARE THE EXCEPTION: they are DROPPED, not demoted. See
``elect`` and ``relationship_labels`` -- an alternateName is offered to the
assistant as another name this person goes by, so keeping "Mum" on a card
lets it answer "your mum is <that person>". For a customer whose mother has
died, that is the worst sentence this graph can produce. A kinship word
naming nobody is not a name; a kinship word that carries a real name
("Granny Smith") is, and is kept.

Election order, most preferred first:

  1. a HUMAN name -- two or more words, letters, no @ and no digit run
  2. a single human-looking word ("Mum", "Ali") -- a real label, just partial
  3. an email local part that humanises ("jane.doe@..." -> Jane Doe
     is done elsewhere; here the raw address only wins if nothing better)
  4. a raw phone number -- last resort, and only if it is all we have

Ties break on longest-then-alphabetical, so the result is STABLE: the same
input set always elects the same winner, whatever order the store returns.
That matters more than picking the prettiest name -- an unstable canonical name
is a name that changes under the customer between two questions.
"""
from __future__ import annotations

import logging
import re
from typing import Iterable, List, Sequence, Tuple

try:
    from .relationship_labels import is_relationship_label
except ImportError:  # plain-script use (repair/audit on a customer box)
    from relationship_labels import is_relationship_label  # type: ignore

# A bare address. Deliberately loose -- anything with an @ and a dot after it.
logger = logging.getLogger(__name__)

# A bare address.
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")

# A phone number: optional +, then digits/spaces/dashes/parens only.
_PHONE_RE = re.compile(r"^\+?[\d\s().-]{6,}$")

# An opaque machine identifier: long, unbroken, no spaces.
_OPAQUE_RE = re.compile(r"^[0-9a-fA-F][0-9a-zA-Z._:-]{24,}$")

# Tier constants -- lower sorts better.
TIER_HUMAN_FULL = 0
TIER_HUMAN_WORD = 1
TIER_EMAIL = 2
TIER_PHONE = 3
TIER_OPAQUE = 4


def classify(name: str) -> int:
    """Return the election tier for one candidate name."""
    n = (name or "").strip()
    if not n:
        return TIER_OPAQUE
    if _EMAIL_RE.match(n):
        return TIER_EMAIL
    if _PHONE_RE.match(n):
        return TIER_PHONE
    if _OPAQUE_RE.match(n) and " " not in n:
        return TIER_OPAQUE
    # Letters present and not obviously machinery.
    if re.search(r"[A-Za-z]", n):
        return TIER_HUMAN_FULL if len(n.split()) >= 2 else TIER_HUMAN_WORD
    return TIER_OPAQUE


def _sort_key(name: str) -> Tuple[int, int, str]:
    # tier, then LONGEST first (negated), then alphabetical -- deterministic.
    return (classify(name), -len(name.strip()), name.strip().lower())


def needs_review(names: Iterable[str]) -> bool:
    """True when the election has no defensible winner and a human must pick.

    v1018-D658 reconciliation, 2026-08-10. This module broke every tie on
    longest-then-alphabetical. That is DETERMINISTIC, which is not the same
    as CORRECT: given "Jane Doe" and "Robert Doe" on one node it silently
    returns the longer string, and one of two real people loses their name
    with nothing recording that a choice was made.

    The operator's ruling is REVIEW LIST, do not guess, and CM051 #550 + #552 now
    implement exactly that on the FDA side -- a tie goes to
    ``~/.ostler/name-review.tsv`` rather than being resolved by a
    tiebreaker. This is the assistant side of the same rule, so the two
    halves of one system agree rather than each doing something defensible
    on its own.

    A genuine tie is TWO OR MORE distinct FULL human names (tier 0). It is
    NOT:
      * a full name beating a partial, an address or a number -- those are
        real tier differences and the ranking is the whole point;
      * the same name written twice, which folding already collapses.
    """
    human_full = {
        n.strip() for n in names or []
        if (n or "").strip()
        and not is_relationship_label(n.strip())
        and classify(n.strip()) == TIER_HUMAN_FULL
    }
    return len(human_full) > 1


def elect(names: Iterable[str]) -> Tuple[str, List[str]]:
    """Pick the canonical name; return ``(canonical, alternates)``.

    Alternates keep every other distinct value EXCEPT bare kinship words,
    which are discarded outright by the loop below -- not demoted, not kept
    for matching. Read that loop before changing this sentence: it is the
    behaviour, and this docstring previously claimed the opposite. A reviewer
    believed the prose over the code on 2026-08-08 and shipped a wrong
    decision on the strength of it.

    Everything that IS kept stays useful for matching while never being
    presented as the person's name.

    Empty input returns ``("", [])`` so a caller can tell "no name" from "a bad
    name" and leave the node alone rather than inventing something.
    """
    seen = []
    for raw in names or []:
        n = (raw or "").strip()
        if not n or n in seen:
            continue
        # A bare kinship word is DROPPED, not demoted.
        #
        # Operator report, 2026-08-08: "'Mum' for her is NOT - she is my WIFE and my
        # son's MUM, but not MY MUM, and my mother is dead."
        #
        # An alternateName is offered to the assistant as another name this
        # person goes by, so keeping "Mum" lets Ava answer "your mum is <that
        # person>". For a customer whose mother has died, That is the worst sentence this
        # graph can produce, and it comes from a card filed for a child's benefit.
        #
        # "Auntie Jane" and "Granny Smith" are NOT dropped -- they carry a
        # real name, are how the household refers to her, and are useful for
        # matching. Only the bare relationship word goes.
        if is_relationship_label(n):
            continue
        seen.append(n)
    if not seen:
        return "", []
    ordered = sorted(seen, key=_sort_key)
    return ordered[0], ordered[1:]


def election_sparql(person_uri: str, names: Sequence[str], ns: str) -> str:
    """SPARQL that leaves the node with ONE displayName and N alternateNames.

    Delete-then-insert in a single update so a reader never observes the node
    mid-repair with zero names.
    """
    canonical, alternates = elect(names)
    if not canonical:
        return ""
    # v1018-D658: a genuine tie is NOT ours to break. Emitting nothing
    # leaves the node exactly as it was for a human to resolve, which is
    # the same outcome the FDA-side repair reaches by writing the pair to
    # its review list. Writing a guess here would be worse than doing
    # nothing, because it would look settled.
    if needs_review(names):
        logger.info(
            "name election: %s has %d competing full human names -- "
            "left for review, not guessed", person_uri, len(set(names)),
        )
        return ""

    def lit(s: str) -> str:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

    inserts = [f"    <{person_uri}> pwg:displayName {lit(canonical)} ."]
    for alt in alternates:
        inserts.append(f"    <{person_uri}> pwg:alternateName {lit(alt)} .")

    return (
        f"PREFIX pwg: <{ns}>\n"
        "DELETE {\n"
        f"    <{person_uri}> pwg:displayName ?old .\n"
        "}\n"
        "INSERT {\n" + "\n".join(inserts) + "\n}\n"
        "WHERE {\n"
        f"    OPTIONAL {{ <{person_uri}> pwg:displayName ?old }}\n"
        "}"
    )


# ── the operator-run caller (#151) ──────────────────────────────────────────
#
# WHY A CLI AND NOT A PIPELINE HOOK.
#
# This module ELECTS between names a node already carries. It is not a
# write-path guard: by the time it has anything to say, the competing triples
# exist. So the thing that should call it is a pass over the store, not an
# ingest step -- and every other name-repair tool in this tree is an
# operator-run one-off for the same reason. identity_resolver's
# repair_kinship_display_names.py says it outright: "deliberately NOT wired
# into any pipeline ... it touches real contact data and the decision to run it
# is a person's."
#
# It also means this file gains NO importer. That matters beyond tidiness: a
# module imported from a shipped write-path would have to exist in CM051's
# vendored tree, and `contact_syncer/name_election.py` is in ZERO copies there
# (measured 2026-09-06; control: dedup.py in 2, an impossible filename in 0).
# An entry point adds no such coupling.
#
# WHAT IT WILL NOT DO
#   - It never invents a name. `elect` returns ("", []) for empty input and
#     `election_sparql` returns "" for it, and both are reported, not written.
#   - It never breaks a genuine tie. `needs_review` is consulted and such nodes
#     are REPORTED and LEFT ALONE, which is the v1018-D658 decision.
#   - It writes displayName and alternateName and nothing else.
#
# EXIT CODES, three states, and CANNOT-RUN is never a pass:
#   0  ran, and reported (dry run) or applied (--apply)
#   1  at least one node could not be repaired at apply time
#   2  CANNOT-RUN -- the store did not answer, or answered unusably

_DEFAULT_NS = "https://schema.ostler.ai/ontology#"


class Store:
    """Minimal SPARQL client. Separated so the tests can drive a stub."""

    def __init__(self, url: str, timeout: float = 30.0) -> None:
        self.url = url.rstrip("/")
        self.timeout = timeout

    def query(self, sparql: str) -> dict:
        import httpx

        r = httpx.post(
            f"{self.url}/query",
            content=sparql.encode("utf-8"),
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
            timeout=self.timeout,
            # The customer's store is on loopback; a configured proxy must not
            # be consulted for it. Same defect as CM041 #147 / oa #375.
            trust_env=False,
        )
        r.raise_for_status()
        return r.json()

    def update(self, sparql: str) -> None:
        import httpx

        r = httpx.post(
            f"{self.url}/update",
            content=sparql.encode("utf-8"),
            headers={"Content-Type": "application/sparql-update"},
            timeout=self.timeout,
            trust_env=False,
        )
        r.raise_for_status()


def _select(ns: str, uri: "str | None" = None) -> str:
    values = f"  VALUES ?p {{ <{uri}> }}\n" if uri else ""
    return (
        "SELECT ?p ?name WHERE {\n"
        + values
        + f"  ?p a <{ns}Person> ;\n"
        + f"     <{ns}displayName> ?name .\n"
        + "}"
    )


def _group(bindings: "List[dict]") -> "dict":
    out: dict = {}
    for b in bindings:
        uri = (b.get("p") or {}).get("value")
        val = (b.get("name") or {}).get("value")
        if not uri or not val:
            continue
        names = out.setdefault(uri, [])
        if val not in names:
            names.append(val)
    return out


def scan(store: "Store", ns: str) -> "dict":
    res = store.query(_select(ns))
    bindings = (res or {}).get("results", {}).get("bindings")
    if bindings is None:
        raise RuntimeError("the store answered without a results.bindings array")
    return _group(bindings)


def main(argv: "List[str] | None" = None) -> int:
    import argparse
    import os
    import sys

    ap = argparse.ArgumentParser(
        description="Elect ONE canonical displayName per person; demote the rest."
    )
    ap.add_argument("--apply", action="store_true", help="write; omit for a dry run")
    ap.add_argument("--limit", type=int, default=0, help="stop after N elections (0 = no limit)")
    ap.add_argument("--store", default=os.environ.get("OXIGRAPH_URL", "http://127.0.0.1:7878"))
    ap.add_argument("--namespace", default=os.environ.get("PWG_NS", _DEFAULT_NS))
    args = ap.parse_args(argv)

    store = Store(args.store)
    print("=== display-name election ===")
    print(f"  store     : {args.store}")
    print(f"  namespace : {args.namespace}")
    print(f"  mode      : {'APPLY' if args.apply else 'dry run'}\n")

    try:
        nodes = scan(store, args.namespace)
    except Exception as exc:  # noqa: BLE001 -- any failure to read is CANNOT-RUN
        print(f"  CANNOT-RUN  the store did not answer usably: {type(exc).__name__}: {exc}")
        print("  A store this tool could not read has not been checked. That is not")
        print("  the same as a graph with nothing to elect.")
        return 2

    print(f"  person nodes with a displayName : {len(nodes)}")
    if not nodes:
        print("  CANNOT-RUN  zero person nodes came back. An empty graph and a broken")
        print("  query print identically, so this refuses rather than reporting clean.")
        return 2

    contested = {u: n for u, n in nodes.items() if len(n) > 1}
    print(f"  carrying MORE THAN ONE name     : {len(contested)}")

    electable, ties, empty = [], [], []
    for uri, names in sorted(contested.items()):
        canonical, alternates = elect(names)
        if not canonical:
            empty.append((uri, names))
        elif needs_review(names):
            ties.append((uri, names))
        else:
            electable.append((uri, names, canonical, alternates))

    print(f"    electable now                 : {len(electable)}")
    print(f"    genuine ties, LEFT ALONE      : {len(ties)}")
    print(f"    no usable name at all         : {len(empty)}\n")

    for uri, names, canonical, alternates in electable:
        print(f"    {uri.rsplit('/', 1)[-1]:<30} -> {canonical!r}  (demoting {len(alternates)})")
    for uri, names in ties:
        print(f"    {uri.rsplit('/', 1)[-1]:<30} TIE, not ours to break: {names}")
    for uri, names in empty:
        print(f"    {uri.rsplit('/', 1)[-1]:<30} no usable name: {names}")

    if not args.apply:
        print("\n  DRY RUN. Nothing was written. Re-run with --apply.")
        return 0

    print()
    done, failures = 0, 0
    for uri, names, canonical, _alt in electable:
        if args.limit and done >= args.limit:
            print(f"  stopping at --limit {args.limit}")
            break
        # RE-READ and decide again against what is there NOW. The scan's list is
        # a description of the past; a concurrent ingest may have added a name.
        try:
            fresh = _group(
                store.query(_select(args.namespace, uri))
                .get("results", {})
                .get("bindings", [])
            ).get(uri)
        except Exception as exc:  # noqa: BLE001
            print(f"    SKIP {uri}: re-read failed: {type(exc).__name__}: {exc}")
            failures += 1
            continue
        if not fresh:
            print(f"    SKIP {uri}: gone or unreadable on the fresh read")
            failures += 1
            continue
        again, _ = elect(fresh)
        if again != canonical or needs_review(fresh):
            print(f"    SKIP {uri}: changed since the scan, not electing")
            failures += 1
            continue
        sparql = election_sparql(uri, fresh, args.namespace)
        if not sparql:
            print(f"    SKIP {uri}: the module declined to emit an update")
            failures += 1
            continue
        store.update(sparql)
        print(f"    ELECTED {uri.rsplit('/', 1)[-1]}: {canonical!r}")
        done += 1

    print(f"\n  elected {done}, skipped {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
