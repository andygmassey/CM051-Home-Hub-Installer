#!/usr/bin/env python3
"""Un-merge Person nodes that swallowed more than one macOS Contacts card (#659).

THE DEFECT
==========
``icloud_contact_uid`` is a CANONICAL key: exactly one macOS Contacts card, for
ever. RULE 2 of the ratified dedupe ruleset (Andy + TNM, 2026-06-09) says
verbatim:

    MUST NOT MERGE: different canonical keys, even if identical display name.

A Person node carrying two DIFFERENT ``icloud_contact_uid`` values is therefore
an over-merge BY DEFINITION -- no judgement, no fuzzy call.

MEASURED on a live v1.0.38 box, 2026-08-22 (re-measured, not inherited):

    over-merged person nodes        128
    Contacts cards swallowed        263   (135 people with no node of their own)
    worst single node                 5   distinct cards collapsed into one
    distribution (uids -> nodes)  {2:124, 3:2, 4:1, 5:1}
    CONTROL: icloud_contact_uid identifiers in the graph  2259

``identity_resolver.resolver`` RULE 2 (``_CANONICAL_ID_TYPES`` /
``_canonical_key_conflict``) stops NEW ones. This module repairs the ones
already written to a customer's graph. The detector -- box-walk probe
``no_person_holds_two_contact_cards.sh`` -- measures the same predicate, so the
probe going green IS this module's acceptance test.

WHY A SPLIT AND NOT A DELETE
============================
Its sibling ``repair_role_address_people`` DELETES, and is right to: those nodes
carry no identifiers, nothing points at them, and there is no per-name
provenance to split on, so a split would be invention.

This defect is the opposite shape. The nodes here carry real identifiers, real
attributes, and inbound edges (measured on the same box: ``meetingAttendee``,
``fromPerson``, ``about``, ``mergedInto``). Deleting one would destroy a real
person's record. So this module never deletes a Person node. It moves
identifiers back to the node they came from, and where it cannot prove where a
card came from it REPORTS and leaves the graph alone.

THE EVIDENCE THAT MAKES AN EXACT UN-MERGE POSSIBLE
==================================================
Identifier URIs are minted from the person_id of the node that owned them AT
WRITE TIME, and the merge never rewrites them:

    contact_syncer/syncer.py:1000   #id_{person_id}_icloud
    contact_syncer/syncer.py:1009   #id_{person_id}_phone{idx}
    contact_syncer/syncer.py:1041   #id_{person_id}_email{idx}
    contact_syncer/syncer.py:1138   #id_{person_id}_{id_type}_{value_hash}
    identity_resolver/resolver.py:950  #id_{person_short_id}_{id_type}_{hash}

and a Person URI is ``#person_{person_id}``. So an identifier URI whose embedded
person_id differs from the node currently holding it is WRITER-GENERATED
PROVENANCE that the identifier was minted on a different node and moved here by
``resolver.merge_persons`` step 1.

That step is what makes the merge look irreversible: it MOVES identifiers off
the discard (``DELETE { discard hasIdentifier ?id } INSERT { keep ... }``), so
the tombstone retains none. Measured on the box: 1,046 tombstones, ZERO of them
holding an ``icloud_contact_uid``. But steps 4-5 only COPY scalars and mark the
discard ``mergedInto`` -- they never delete the discard's own attributes.
Measured: of 1,046 tombstones, 1,013 still carry a displayName, 902 a givenName,
896 a familyName, 759 an organization. The loser's record is INTACT apart from
the identifiers that were moved off it.

So the undo is: move the identifiers back to the pid their URI names, and lift
the tombstone marker. Nothing is reconstructed from a heuristic.

WHAT THIS MODULE DELIBERATELY DOES NOT REPAIR
=============================================
Merge steps 2 and 3 re-point ``aboutPerson`` facts and ``meetingAttendee`` links
onto the keep node and leave NO record of which came from where. That
attribution is genuinely gone. Facts and meetings therefore STAY on the node
that currently holds them; this module never guesses which meeting belonged to
which of two people. Reported per node so the residue is visible, never
silently assumed away.

SAFETY (every one of these is load-bearing)
===========================================
  * DRY RUN IS THE DEFAULT. ``--apply`` is required to write anything. There is
    no config, env var or file that can turn applying on.
  * ANTI-VACUITY REFUSAL. If the control query returns zero
    ``icloud_contact_uid`` identifiers, the module REFUSES to run rather than
    report a clean graph -- a zero from a broken predicate and a zero from a
    healthy graph print identically.
  * REPORT BEFORE MUTATE. The full plan is printed, and the move-log written
    and fsynced to disk, before the first UPDATE.
  * REVERSIBLE. The move-log is a complete inverse: every triple removed and
    every triple added, per node. ``--undo <movelog>`` replays it backwards.
    A raw N-Triples backup of every touched node is written alongside it.
  * IDEMPOTENT. Re-running finds nothing to do: the planner skips any card
    whose identifier already sits on its origin node.
  * SAFE TO INTERRUPT. The move-log covers the whole plan before execution
    starts, and undo is itself idempotent (removing an absent triple is a
    no-op), so an interrupted run is fully undoable from the log on disk.
  * NEVER DELETES A PERSON NODE. Not one code path deletes ``?s a pwg:Person``.
  * WHEN UNCERTAIN, LEAVES IT. A node is only split when the origin node is
    provably identified AND still present in the graph. Everything else is
    classified, counted and reported untouched.

PII
===
This output lands in logs and support bundles, and the whole defect is that
these nodes carry the names of people who are not each other. So the report
prints node URIs, counts and shapes ONLY -- never a display name, an email, a
phone number or a Contacts UID. There is no flag to turn that off.

Usage:
    python3 -m ostler_fda.repair_overmerged_contact_cards             # dry run
    python3 -m ostler_fda.repair_overmerged_contact_cards --apply
    python3 -m ostler_fda.repair_overmerged_contact_cards --undo <movelog.json>
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Tuple

logger = logging.getLogger(__name__)

NS = "https://schema.ostler.ai/ontology#"
OXIGRAPH = os.environ.get("OXIGRAPH_URL", "http://127.0.0.1:7878")

CANONICAL_ID_TYPE = "icloud_contact_uid"
MOVELOG_SCHEMA = "ostler.repair_overmerged_contact_cards/1"

# Person URI  -> #person_<pid>
_PERSON_RE = re.compile(r"^" + re.escape(NS) + r"person_(?P<pid>[^_]+)$")
# Identifier URI -> #id_<pid>_<rest>.  person_id is a uuid5 string or a 12-char
# hex slug; neither can contain "_", so the pid is unambiguously the token
# between the first and second underscore.
_IDENT_RE = re.compile(r"^" + re.escape(NS) + r"id_(?P<pid>[^_]+)_(?P<rest>.+)$")


# ---------------------------------------------------------------------------
# N-Triples serialisation (shared shape with repair_role_address_people)
# ---------------------------------------------------------------------------

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
            out.append(f"\\u{ord(ch):04X}")
        else:
            out.append(ch)
    return "".join(out)


def _nt_term(node: Dict) -> str:
    """Serialise one SPARQL-JSON result node as an N-Triples term."""
    kind = node.get("type")
    value = node.get("value", "")
    if kind == "uri":
        return f"<{value}>"
    if kind == "bnode":
        return f"_:{value}"
    literal = f'"{_nt_escape(value)}"'
    lang = node.get("xml:lang")
    if lang:
        return f"{literal}@{lang}"
    datatype = node.get("datatype")
    if datatype:
        return f"{literal}^^<{datatype}>"
    return literal


# ---------------------------------------------------------------------------
# Store I/O
# ---------------------------------------------------------------------------

def _select(sparql: str) -> List[Dict]:
    url = f"{OXIGRAPH}/query?" + urllib.parse.urlencode({"query": sparql})
    req = urllib.request.Request(
        url, headers={"Accept": "application/sparql-results+json"}
    )
    with urllib.request.urlopen(req, timeout=180) as fh:
        return json.load(fh)["results"]["bindings"]


def _update(sparql: str) -> None:
    req = urllib.request.Request(
        f"{OXIGRAPH}/update",
        data=sparql.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as fh:
        fh.read()


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def person_pid(person_uri: str) -> Optional[str]:
    m = _PERSON_RE.match(person_uri)
    return m.group("pid") if m else None


def identifier_pid(identifier_uri: str) -> Optional[str]:
    """The person_id embedded in an identifier URI, or None if it does not parse.

    This is the ONLY provenance the merge leaves behind, so a None here is the
    difference between a provable un-merge and a guess. Callers must treat None
    as "unattributable" and refuse to move the card.
    """
    m = _IDENT_RE.match(identifier_uri)
    return m.group("pid") if m else None


# ---------------------------------------------------------------------------
# Detection -- the SAME predicate as the shipping box-walk probe
# ---------------------------------------------------------------------------

def control_count() -> int:
    """Total icloud_contact_uid identifiers. MUST be non-zero to interpret a zero."""
    rows = _select(
        f'PREFIX p: <{NS}> SELECT (COUNT(DISTINCT ?i) AS ?n) '
        f'WHERE {{ ?i p:identifierType "{CANONICAL_ID_TYPE}" }}'
    )
    return int(rows[0]["n"]["value"]) if rows else 0


def find_overmerged_nodes() -> List[str]:
    """Person nodes carrying 2+ distinct icloud_contact_uid values."""
    rows = _select(f"""PREFIX p: <{NS}>
SELECT ?person (COUNT(DISTINCT ?v) AS ?uids) WHERE {{
  ?person a p:Person ; p:hasIdentifier ?i .
  ?i p:identifierType "{CANONICAL_ID_TYPE}" ; p:identifierValue ?v .
}} GROUP BY ?person HAVING (COUNT(DISTINCT ?v) > 1)""")
    return [r["person"]["value"] for r in rows]


def node_identifiers(person_uri: str) -> List[Tuple[str, str]]:
    """[(identifier_uri, identifier_type)] for every identifier on a node."""
    rows = _select(
        f"PREFIX p: <{NS}> SELECT ?i ?t WHERE {{ "
        f"<{person_uri}> p:hasIdentifier ?i . ?i p:identifierType ?t }}"
    )
    return [(r["i"]["value"], r["t"]["value"]) for r in rows]


def node_triple_count(uri: str) -> int:
    rows = _select(f"SELECT (COUNT(*) AS ?n) WHERE {{ <{uri}> ?p ?o }}")
    return int(rows[0]["n"]["value"]) if rows else 0


def is_tombstone(uri: str) -> bool:
    rows = _select(
        f"PREFIX p: <{NS}> SELECT (COUNT(*) AS ?n) WHERE {{ <{uri}> p:mergedInto ?o }}"
    )
    return bool(rows) and int(rows[0]["n"]["value"]) > 0


def node_values(uri: str, predicate: str) -> List[str]:
    rows = _select(
        f"PREFIX p: <{NS}> SELECT ?v WHERE {{ <{uri}> p:{predicate} ?v }}"
    )
    return [r["v"]["value"] for r in rows]


# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

# Why a node could not be repaired. Reported verbatim so a blocked node is a
# stated fact with a reason, never a silent omission.
BLOCK_NO_HOME = (
    "no card on this node was minted on this node, so there is no evidence "
    "which of them is its own -- splitting would pick one arbitrarily"
)
BLOCK_UNATTRIBUTABLE = (
    "identifier URI does not embed an origin person_id, so the card's origin "
    "is unknowable from the graph"
)
BLOCK_ORIGIN_ABSENT = (
    "the origin node has been erased from the graph, so restoring the card "
    "would mean inventing a person record rather than reviving one"
)
BLOCK_ORIGIN_HAS_CARD = (
    "the origin node already holds a Contacts card of its own, so returning "
    "this one would over-merge the origin instead"
)


class NodePlan:
    """What would happen to one over-merged node."""

    def __init__(self, person_uri: str) -> None:
        self.person_uri = person_uri
        self.pid = person_pid(person_uri)
        self.home_cards: List[str] = []          # identifier URIs minted here
        self.movable: List[Dict] = []            # cards with a revivable origin
        self.blocked: List[Dict] = []            # {"identifier","reason"}
        self.residue_facts = 0
        self.residue_meetings = 0

    @property
    def splittable(self) -> bool:
        return bool(self.home_cards) and bool(self.movable)

    @property
    def cards(self) -> int:
        """Contacts cards accounted for. Must reconcile with the probe's count.

        ``movable`` holds GROUPS, not cards -- one origin node can have had
        several cards -- so this sums each group's card count rather than
        counting the groups. Getting that wrong under-reports the population by
        exactly the number of multi-card origins, which is how a repair tool
        and its detector come to disagree by one and nobody notices.
        """
        return (
            len(self.home_cards)
            + sum(g["cards"] for g in self.movable)
            + len(self.blocked)
        )


def plan_node(person_uri: str) -> NodePlan:
    plan = NodePlan(person_uri)
    idents = node_identifiers(person_uri)

    # Group EVERY identifier on the node by the pid its URI embeds. The merge
    # moved a discard's identifiers as a set, so the whole group travels back
    # together -- phones and emails included, not just the canonical card.
    by_pid: Dict[Optional[str], List[Tuple[str, str]]] = {}
    for uri, id_type in idents:
        by_pid.setdefault(identifier_pid(uri), []).append((uri, id_type))

    for pid, group in by_pid.items():
        canonical = [(u, t) for u, t in group if t == CANONICAL_ID_TYPE]
        if pid is None:
            for uri, _t in canonical:
                plan.blocked.append(
                    {"identifier": uri, "reason": BLOCK_UNATTRIBUTABLE}
                )
            continue
        if pid == plan.pid:
            plan.home_cards.extend(u for u, _ in canonical)
            continue
        if not canonical:
            # A foreign group with no Contacts card in it is not a RULE 2
            # violation. Leave it alone; this module repairs canonical-key
            # collisions and nothing else.
            continue

        origin = f"{NS}person_{pid}"
        if node_triple_count(origin) == 0:
            for uri, _t in canonical:
                plan.blocked.append(
                    {"identifier": uri, "reason": BLOCK_ORIGIN_ABSENT}
                )
            continue

        # NEVER FIX AN OVER-MERGE BY CREATING ANOTHER ONE. If the origin node
        # already holds a canonical card of its own, returning this one would
        # leave the origin holding two -- the exact violation this module
        # exists to remove, just moved to a different node. Measured on the
        # box, every tombstone holds zero, so this costs nothing in the normal
        # case and is the whole ballgame in the abnormal one.
        already = node_identifiers(origin)
        if any(t == CANONICAL_ID_TYPE for _u, t in already):
            for uri, _t in canonical:
                plan.blocked.append(
                    {"identifier": uri, "reason": BLOCK_ORIGIN_HAS_CARD}
                )
            continue

        plan.movable.append(
            {
                "origin": origin,
                "origin_pid": pid,
                "identifiers": [{"uri": u, "type": t} for u, t in group],
                "cards": len(canonical),
                "tombstone": is_tombstone(origin),
            }
        )

    # A node with no home card cannot be split: we would be choosing which of
    # several foreign cards gets to keep the node, which is exactly the
    # arbitrary call this module exists to avoid.
    if not plan.home_cards and plan.movable:
        for grp in plan.movable:
            for ident in grp["identifiers"]:
                if ident["type"] == CANONICAL_ID_TYPE:
                    plan.blocked.append(
                        {"identifier": ident["uri"], "reason": BLOCK_NO_HOME}
                    )
        plan.movable = []

    if plan.movable:
        facts = _select(
            f"PREFIX p: <{NS}> SELECT (COUNT(*) AS ?n) "
            f"WHERE {{ ?f p:aboutPerson <{person_uri}> }}"
        )
        meets = _select(
            f"PREFIX p: <{NS}> SELECT (COUNT(*) AS ?n) "
            f"WHERE {{ ?m p:meetingAttendee <{person_uri}> }}"
        )
        plan.residue_facts = int(facts[0]["n"]["value"]) if facts else 0
        plan.residue_meetings = int(meets[0]["n"]["value"]) if meets else 0

    return plan


def build_operations(plan: NodePlan) -> List[Dict]:
    """The concrete triple-level changes for one node.

    Each operation is a pair of triple lists: ``remove`` and ``add``. The undo
    is the same pair swapped, which is why the move-log needs nothing else.
    """
    ops: List[Dict] = []
    for grp in plan.movable:
        origin = grp["origin"]
        remove: List[Dict] = []
        add: List[Dict] = []

        for ident in grp["identifiers"]:
            remove.append(
                {"s": plan.person_uri, "p": f"{NS}hasIdentifier", "o": ident["uri"],
                 "kind": "uri"}
            )
            add.append(
                {"s": origin, "p": f"{NS}hasIdentifier", "o": ident["uri"],
                 "kind": "uri"}
            )

        # Lift the tombstone: the node is a real person again, so the marker
        # that hides it from every reader must go. ical-server.py:3107 treats
        # pwg:mergedInto as "deprecated fragment" and suppresses the node.
        if grp["tombstone"]:
            for pred in ("mergedInto", "mergedAt"):
                for row in _select(
                    f"PREFIX p: <{NS}> SELECT ?o WHERE {{ <{origin}> p:{pred} ?o }}"
                ):
                    remove.append(
                        {"s": origin, "p": f"{NS}{pred}",
                         "o": row["o"]["value"],
                         "kind": "uri" if row["o"]["type"] == "uri" else "literal",
                         "datatype": row["o"].get("datatype"),
                         "lang": row["o"].get("xml:lang")}
                    )

        # Re-type as a Person if the merge left it untyped. Measured: only 13
        # of 1,046 tombstones kept rdf:type, so most revived nodes need this or
        # they are invisible to every `?s a pwg:Person` query in the product.
        typed = _select(
            f"PREFIX p: <{NS}> SELECT (COUNT(*) AS ?n) "
            f"WHERE {{ <{origin}> a p:Person }}"
        )
        if not typed or int(typed[0]["n"]["value"]) == 0:
            add.append(
                {"s": origin,
                 "p": "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
                 "o": f"{NS}Person", "kind": "uri"}
            )

        ops.append({
            "node": plan.person_uri,
            "origin": origin,
            "cards": grp["cards"],
            "remove": remove,
            "add": add,
        })
    return ops


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

def _triple_nt(t: Dict) -> str:
    if t["kind"] == "uri":
        obj = f"<{t['o']}>"
    else:
        obj = f'"{_nt_escape(t["o"])}"'
        if t.get("lang"):
            obj += f"@{t['lang']}"
        elif t.get("datatype"):
            obj += f"^^<{t['datatype']}>"
    return f"<{t['s']}> <{t['p']}> {obj} ."


def apply_operation(op: Dict) -> None:
    """Apply one operation as a SINGLE SPARQL update.

    One request per operation means a node is never left half-moved: Oxigraph
    applies DELETE DATA/INSERT DATA in one transaction. An interrupt lands
    between operations, never inside one, and the move-log on disk already
    describes every operation including the ones not yet run.
    """
    parts = []
    if op["remove"]:
        parts.append(
            "DELETE DATA { " + " ".join(_triple_nt(t) for t in op["remove"]) + " }"
        )
    if op["add"]:
        parts.append(
            "INSERT DATA { " + " ".join(_triple_nt(t) for t in op["add"]) + " }"
        )
    if parts:
        _update(" ; ".join(parts))


def invert_operation(op: Dict) -> Dict:
    return {**op, "remove": op["add"], "add": op["remove"]}


# ---------------------------------------------------------------------------
# Reporting -- URIs, counts and shapes ONLY. Never a name, value or UID.
# ---------------------------------------------------------------------------

def print_report(plans: List[NodePlan], control: int, apply: bool) -> None:
    splittable = [p for p in plans if p.splittable]
    blocked = [p for p in plans if not p.splittable]
    cards_total = sum(p.cards for p in plans)
    cards_moved = sum(len(g["identifiers"]) for p in splittable for g in p.movable)
    cards_restored = sum(g["cards"] for p in splittable for g in p.movable)
    blocked_cards = sum(len(p.blocked) for p in plans)

    print("=" * 72)
    print("OVER-MERGED CONTACTS CARDS -- REPAIR PLAN (#659)")
    print("=" * 72)
    print(f"  control: {control} icloud_contact_uid identifiers in the graph")
    print(f"  over-merged Person nodes:            {len(plans)}")
    print(f"  Contacts cards on those nodes:       {cards_total}")
    print()
    print(f"  REPAIRABLE nodes (provable origin):  {len(splittable)}")
    print(f"    cards returned to their own node:  {cards_restored}")
    print(f"    identifiers moved in total:        {cards_moved}")
    print(f"  LEFT ALONE nodes (no proof):         {len(blocked)}")
    print(f"    cards left in place:               {blocked_cards}")
    print()

    reasons: Dict[str, int] = {}
    for p in plans:
        for b in p.blocked:
            reasons[b["reason"]] = reasons.get(b["reason"], 0) + 1
    if reasons:
        print("  WHY CARDS WERE LEFT ALONE:")
        for reason, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"    {n:>4}  {reason}")
        print()

    if splittable:
        residue_f = sum(p.residue_facts for p in splittable)
        residue_m = sum(p.residue_meetings for p in splittable)
        print("  NOT REPAIRED BY THIS MODULE (attribution destroyed at merge time):")
        print(f"    {residue_f} fact link(s) and {residue_m} meeting link(s) stay on the")
        print("    node that holds them. resolver.merge_persons steps 2-3 re-pointed")
        print("    them and kept no record of which person they came from.")
        print()
        print("  NODES THAT WOULD CHANGE (URIs only -- names are the defect):")
        for p in sorted(splittable, key=lambda p: -len(p.movable))[:20]:
            revived = ", ".join(g["origin"].rsplit("person_", 1)[-1][:8] for g in p.movable)
            print(f"    {p.person_uri}")
            print(f"      -> returns {sum(g['cards'] for g in p.movable)} card(s) "
                  f"to {len(p.movable)} node(s): {revived}")
        if len(splittable) > 20:
            print(f"    ... and {len(splittable) - 20} more")
        print()

    print("-" * 72)
    if not apply:
        print("DRY RUN -- nothing has been written. Re-run with --apply to repair.")
    print("=" * 72)


# ---------------------------------------------------------------------------
# Move-log
# ---------------------------------------------------------------------------

def default_movelog_path() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return os.path.expanduser(
        f"~/.ostler/state/overmerge_repair_{stamp}.movelog.json"
    )


def write_movelog(path: str, ops: List[Dict], control: int) -> None:
    """Write the COMPLETE plan, then fsync, BEFORE the first mutation.

    fsync is not decoration. Without it an interrupt can lose the only record
    of what was about to change, and a repair you cannot undo is not a repair.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = {
        "schema": MOVELOG_SCHEMA,
        "created": datetime.now(timezone.utc).isoformat(),
        "oxigraph": OXIGRAPH,
        "control_icloud_identifiers": control,
        "operations": ops,
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.flush()
        os.fsync(fh.fileno())


def write_backup(path: str, uris: Iterable[str]) -> int:
    """Raw N-Triples of every node this run will touch, for a manual restore."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    written = 0
    with open(path, "w", encoding="utf-8") as fh:
        for uri in sorted(set(uris)):
            for row in _select(f"SELECT ?p ?o WHERE {{ <{uri}> ?p ?o }}"):
                fh.write(f"<{uri}> <{row['p']['value']}> {_nt_term(row['o'])} .\n")
                written += 1
        fh.flush()
        os.fsync(fh.fileno())
    return written


def run_undo(path: str) -> int:
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
    if payload.get("schema") != MOVELOG_SCHEMA:
        print(f"ERROR: {path} is not a {MOVELOG_SCHEMA} move-log.", file=sys.stderr)
        return 2
    ops = payload.get("operations", [])
    print(f"Undoing {len(ops)} operation(s) from {path}")
    for op in ops:
        apply_operation(invert_operation(op))
    print(f"Undone. {len(ops)} operation(s) reversed.")
    print("Undo is idempotent -- re-running it is a no-op, so an interrupted")
    print("undo can simply be run again.")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Un-merge Person nodes holding 2+ Contacts cards (#659)."
    )
    ap.add_argument("--apply", action="store_true",
                    help="actually write the repair (default is a dry run)")
    ap.add_argument("--undo", metavar="MOVELOG",
                    help="reverse a previous --apply from its move-log")
    ap.add_argument("--movelog", metavar="PATH", default=None,
                    help="where to write the move-log (default ~/.ostler/state/)")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    if args.undo:
        return run_undo(args.undo)

    # ANTI-VACUITY GATE. A zero violation count is the pass condition, and it is
    # also exactly what a wrong namespace, an empty store or an unreachable
    # Oxigraph returns. Refuse to interpret one without a non-zero control.
    control = control_count()
    if control == 0:
        print(
            "REFUSING TO RUN: zero icloud_contact_uid identifiers in the graph.\n"
            "Either contacts have not been imported, or the predicate/namespace\n"
            "is wrong. A clean violation count would prove nothing here.",
            file=sys.stderr,
        )
        return 2

    nodes = find_overmerged_nodes()
    if not nodes:
        print(f"No over-merged Person nodes found "
              f"(checked against {control} icloud_contact_uid identifiers, "
              f"so this zero is a measurement).")
        return 0

    plans = [plan_node(uri) for uri in nodes]
    print_report(plans, control, args.apply)

    if not args.apply:
        return 0

    ops: List[Dict] = []
    for p in plans:
        if p.splittable:
            ops.extend(build_operations(p))
    if not ops:
        print("Nothing repairable. Graph unchanged.")
        return 0

    movelog = args.movelog or default_movelog_path()
    touched = {op["node"] for op in ops} | {op["origin"] for op in ops}
    backup = movelog.replace(".movelog.json", ".backup.nt")

    n = write_backup(backup, touched)
    print(f"Backed up {n} triples from {len(touched)} node(s) to {backup}")
    write_movelog(movelog, ops, control)
    print(f"Move-log written to {movelog}")
    print("  undo:  python3 -m ostler_fda.repair_overmerged_contact_cards "
          f"--undo {movelog}")
    print()

    done = 0
    for op in ops:
        apply_operation(op)
        done += 1
    print(f"Repaired: {done} operation(s) applied across "
          f"{len({op['node'] for op in ops})} over-merged node(s).")
    print("Re-run without --apply to confirm, or run the box-walk probe "
          "no_person_holds_two_contact_cards.sh.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
