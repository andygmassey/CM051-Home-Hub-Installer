#!/usr/bin/env python3
"""Delete Person nodes that are a notification sender, not a person.

WHY (2026-08-08)
================
``_person_id_from_identifier`` keys a Person URI on ``uuid5(identifier)``, so
everyone sharing an identifier becomes ONE node. The SENDER address of a
notification email was being used as the RECIPIENT's identity, so every mail
from a given robot collapsed onto a single "person". Proven by matching the
uuid5 of each candidate against the merged node in Oxigraph:

    invitations@linkedin.com -> one node holding 9 people
    notifications@github.com -> one node holding 7 (Max Braun, andygmassey,
                                dependabot[bot], github-actions[bot], ...)
    dan@tldrnewsletter.com   -> one node holding 6 newsletters

Measured on a real box: 6,583 Person nodes, 265 with more than one display
name. 40 of those have ZERO identifiers -- the over-merge signature -- and
between them they hide 122 distinct contacts.

``pwg_ingest.is_role_identifier`` stops NEW ones. This removes the existing
ones.

WHY DELETE RATHER THAN SPLIT
============================
Inspected before deciding. An over-merged node carries only:

    displayName x N · prefLabel x N · type · lastContactEmail · email

No facts, no meetings, no relationships -- and NOTHING in the graph points at
it. There is no per-name provenance to split on, so a "split" would be
invention, not repair. What is really there is one junk node whose sole
identity is a robot's address.

Deleting is therefore lossless in the only sense that matters: no edge is
orphaned, and nothing that was true stops being true. The customer's real
contacts were never in these nodes -- that is the bug.

SAFETY
======
Dry run by default; ``--apply`` is required to write. Every candidate must
satisfy ALL of:

  * is a pwg:Person
  * its pwg:email is a role/bulk address (pwg_ingest.is_role_identifier)
  * has ZERO pwg:hasIdentifier -- a real merged person has many (Anthony has 12)
  * NOTHING in the graph references it as an object

The last two are what keep a real person safe. A node with identifiers, or one
that anything points at, is never touched no matter how many names it has.

Usage:
    python3 -m ostler_fda.repair_role_address_people            # dry run
    python3 -m ostler_fda.repair_role_address_people --apply
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import urllib.parse
import urllib.request
from typing import Dict, List

try:
    from .role_addresses import is_role_identifier
except ImportError:  # running as a plain script (repair on the box)
    from role_addresses import is_role_identifier  # type: ignore

logger = logging.getLogger(__name__)

NS = "https://pwg.dev/ontology#"
OXIGRAPH = os.environ.get("OXIGRAPH_URL", "http://127.0.0.1:7878")


# N-Triples control characters that MUST be escaped. The first version of the
# backup writer handled \\, " and \n only.
#
# Archie, 2026-08-08, reviewing the writer: "language tags stripped, datatypes
# stripped, blank nodes serialised as literals, N-Triples escaping is partial
# (misses \r, \t, other control chars)."
#
# Every one of those is a silent corruption: the file parses, the restore
# reports success, and what comes back is not what went in. A backup you cannot
# trust byte-for-byte is not a backup -- it is a note saying you had one.
_NT_ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    "\b": "\\b",
    "\f": "\\f",
}


def _nt_escape(value: str) -> str:
    out = []
    for ch in value:
        if ch in _NT_ESCAPES:
            out.append(_NT_ESCAPES[ch])
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            # Remaining C0 controls + DEL have no short form; \uXXXX is legal
            # N-Triples and round-trips exactly.
            out.append(f"\\u{ord(ch):04X}")
        else:
            out.append(ch)
    return "".join(out)


def _nt_term(node: Dict) -> str:
    """Serialise one SPARQL-JSON result node as an N-Triples term.

    Handles all four node types Oxigraph can return. ``typed-literal`` is the
    SPARQL 1.0 spelling some stores still emit; treated identically to a
    ``literal`` carrying a datatype.
    """
    kind = node.get("type")
    value = node.get("value", "")
    if kind == "uri":
        return f"<{value}>"
    if kind == "bnode":
        # A blank node is scoped to the document, not the store, so a restore
        # re-mints it. That is correct for a single-node backup: the label is
        # arbitrary, the structure is what matters.
        return f"_:{value}"
    literal = f'"{_nt_escape(value)}"'
    lang = node.get("xml:lang")
    if lang:
        # A language tag and a datatype are mutually exclusive in RDF; lang wins
        # because its presence implies rdf:langString.
        return f"{literal}@{lang}"
    datatype = node.get("datatype")
    if datatype:
        return f"{literal}^^<{datatype}>"
    return literal


def _select(sparql: str) -> List[Dict]:
    url = f"{OXIGRAPH}/query?" + urllib.parse.urlencode({"query": sparql})
    req = urllib.request.Request(
        url, headers={"Accept": "application/sparql-results+json"}
    )
    with urllib.request.urlopen(req, timeout=120) as fh:
        return json.load(fh)["results"]["bindings"]


def _update(sparql: str) -> None:
    req = urllib.request.Request(
        f"{OXIGRAPH}/update",
        data=sparql.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as fh:
        fh.read()


def find_candidates() -> List[Dict]:
    """Person nodes that are a role address and nothing else."""
    rows = _select(f"""PREFIX pwg: <{NS}>
SELECT ?p ?email
       (COUNT(DISTINCT ?n)   AS ?names)
       (COUNT(DISTINCT ?idv) AS ?ids)
       (GROUP_CONCAT(DISTINCT ?n; separator=' | ') AS ?namelist)
WHERE {{
  ?p a pwg:Person ; pwg:displayName ?n .
  OPTIONAL {{ ?p pwg:email ?email }}
  OPTIONAL {{ ?p pwg:hasIdentifier ?i . ?i pwg:identifierValue ?idv }}
}} GROUP BY ?p ?email""")

    out = []
    for r in rows:
        email = (r.get("email", {}) or {}).get("value", "")
        if not email or not is_role_identifier(email):
            continue
        if int(r["ids"]["value"]) != 0:
            # A real person carries identifiers. Never touch one.
            continue
        uri = r["p"]["value"]
        # Refuse anything the graph references -- deleting it would orphan an
        # edge, and an orphan is worse than a wrong name.
        refs = _select(f"SELECT (COUNT(*) AS ?n) WHERE {{ ?s ?pr <{uri}> }}")
        if refs and int(refs[0]["n"]["value"]) > 0:
            logger.info("skipping %s: %s references point at it",
                        uri, refs[0]["n"]["value"])
            continue
        out.append({
            "uri": uri,
            "email": email,
            "names": int(r["names"]["value"]),
            "namelist": (r.get("namelist", {}) or {}).get("value", ""),
        })
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="actually delete (default is a dry run)")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    cands = find_candidates()
    if not cands:
        print("No role-address person nodes found. Nothing to repair.")
        return 0

    hidden = sum(c["names"] for c in cands)
    print(f"{'WOULD DELETE' if not args.apply else 'DELETING'} "
          f"{len(cands)} role-address node(s), hiding {hidden} contacts:\n")
    for c in sorted(cands, key=lambda c: -c["names"]):
        print(f"  {c['email']:34} {c['names']:>3} names")
        print(f"      {c['namelist'][:110]}")

    if not args.apply:
        print("\nDry run. Re-run with --apply to delete.")
        return 0

    # BACK UP FIRST, ALWAYS.
    #
    # This deletes from a customer's live graph. Dumping every triple as
    # N-Triples before the first DELETE turns an irreversible operation into a
    # reversible one -- restore is `curl -X POST --data-binary @<file>` against
    # /store. Without this the only recovery is a full re-ingest, which costs
    # the customer days of settling.
    backup = os.environ.get(
        "OSTLER_REPAIR_BACKUP",
        os.path.expanduser("~/.ostler/state/role_address_repair_backup.nt"),
    )
    os.makedirs(os.path.dirname(backup), exist_ok=True)
    written = 0
    with open(backup, "w", encoding="utf-8") as fh:
        for c in cands:
            for row in _select(
                f"SELECT ?p ?o WHERE {{ <{c['uri']}> ?p ?o }}"
            ):
                fh.write(
                    f"<{c['uri']}> <{row['p']['value']}> "
                    f"{_nt_term(row['o'])} .\n"
                )
                written += 1
    print(f"\nBacked up {written} triples to {backup}")
    # ?default is LOAD-BEARING. Oxigraph follows the SPARQL Graph Store
    # Protocol, where POST to the store with no parameter creates a NEW NAMED
    # GRAPH. Without it the restore returns HTTP 201 and the data lands
    # somewhere nothing queries -- a safety net that reports success and
    # catches nothing.
    #
    # Found 2026-08-08 by round-tripping one URI on the live box, after Archie
    # flagged that the restore had never been validated. It had not, and it
    # was broken. Verified after the fix: 5 triples out, 5 triples back into
    # the default graph.
    print("  restore (VERIFIED 2026-08-08 -- note ?default, without it the")
    print("           POST returns 201 and stores nothing you can query):")
    print("    curl -X POST -H 'Content-Type: application/n-triples' \\")
    print(f"         --data-binary @{backup} '{OXIGRAPH}/store?default'")

    for c in cands:
        _update(f"""PREFIX pwg: <{NS}>
DELETE WHERE {{ <{c['uri']}> ?p ?o }}""")
        logger.info("deleted %s (%s)", c["uri"], c["email"])

    print(f"\nDeleted {len(cands)} node(s). "
          "Re-ingest will not recreate them: is_role_identifier now refuses "
          "to key a person on a role address.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
