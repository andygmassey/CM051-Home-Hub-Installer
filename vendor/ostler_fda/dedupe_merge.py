"""Post-ingest exact-identifier dedup merge (RULE 1).

Enforces the ratified dedup rule: two Person nodes that share an exact
identifier VALUE (same email string or same phone string) are the same
person and MUST be merged -- regardless of source, regardless of display
name. Runs AFTER all ingest writers, as a graph-level sweep against
Oxigraph, so every consumer (the wiki, the iOS People view, the Doctor
API) sees merged people -- not just one renderer.

This catches the cross-source case the resolver misses: ``pwg_ingest``
(iMessage / WhatsApp) mints its own ``uuid5`` Person URIs and never
consults the identity resolver, so an iMessage Person and a Contacts
Person that share a phone number stay split until this sweep folds them
together.

Scope (deliberate): only the EXACT shared-identifier case (the metric
``dedupe_scorecard.py`` calls "shared value owned by >1 Person"). The
fuzzy no-shared-identifier case -- same person across sources with no
overlapping email/phone -- is BW-2 / #662 and is DEFERRED to v1.1; it is
risky to auto-merge and is not touched here.

Idempotent: a second run finds no collisions and is a no-op. Safe to run
on every install / recompile.
"""

from __future__ import annotations

import argparse
import logging
import os
from typing import Dict, List, Set, Tuple

import httpx

try:
    from .person_audit import record_person_removal
    from . import phone_twins
except ImportError:  # run as a script, not as a package
    from person_audit import record_person_removal
    import phone_twins  # type: ignore

logger = logging.getLogger(__name__)

OXIGRAPH_URL = os.getenv("OXIGRAPH_URL", "http://localhost:7878")
PWG = "https://schema.ostler.ai/ontology#"

# Identifier types treated as exact-identity keys (RULE 1). Instagram /
# twitter / facebook handles are intentionally NOT here -- they are
# name-fuzzy signals only, never an exact-merge key.
EXACT_KEY_TYPES: Tuple[str, ...] = ("email", "phone")

# RULE 2's canonical key. Exactly one macOS Contacts card, for ever. The
# ratified ruleset says verbatim: "MUST NOT MERGE: different canonical keys,
# even if identical display name." A Person node carrying two different values
# of this type is an over-merge BY DEFINITION -- no judgement, no name
# comparison involved.
CANONICAL_KEY_TYPE = "icloud_contact_uid"


def _canonical_phone(value: str) -> str:
    """Canonicalise a phone identifier so a WhatsApp JID collides with the
    same E.164 number written by Contacts / iMessage. Strip the
    ``@s.whatsapp.net`` suffix and ``+``-prefix the digit local-part so the
    WhatsApp node and the Contacts node fold under RULE 1 (the "duplicate
    +number" rows). Non-JID / non-numeric values pass through unchanged.
    ``@lid`` JIDs are opaque (non-phone) and written with a non-phone type,
    so they never reach here."""
    v = value.strip()
    if v.lower().endswith("@s.whatsapp.net"):
        local = v.split("@", 1)[0]
        if local.isdigit():
            return "+" + local
    return v


def _sparql_query(sparql: str) -> list:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{OXIGRAPH_URL}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json().get("results", {}).get("bindings", [])


def _sparql_update(sparql: str) -> None:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{OXIGRAPH_URL}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def find_collisions() -> Dict[Tuple[str, str], List[str]]:
    """Return ``{(type, value): [person_uri, ...]}`` for every identifier
    value of an exact-key type owned by more than one distinct Person."""
    out: Dict[Tuple[str, str], List[str]] = {}
    for typ in EXACT_KEY_TYPES:
        rows = _sparql_query(
            f"PREFIX pwg:<{PWG}> "
            "SELECT ?v ?p WHERE { "
            "  ?p a pwg:Person ; pwg:hasIdentifier ?id . "
            f'  ?id pwg:identifierType "{typ}" ; pwg:identifierValue ?v . '
            "}"
        )
        groups: Dict[str, Set[str]] = {}
        for r in rows:
            value = r["v"]["value"]
            key = _canonical_phone(value) if typ == "phone" else value
            groups.setdefault(key, set()).add(r["p"]["value"])
        for value, persons in groups.items():
            if len(persons) > 1:
                out[(typ, value)] = sorted(persons)
    return out


def _components(collisions: Dict[Tuple[str, str], List[str]]) -> Dict[str, Set[str]]:
    """Union-find over all colliding persons. A person can collide with A
    on a phone and with B on an email; all three must fold into one node.
    The canonical URI of a component is its lexicographically-smallest
    member (deterministic, so re-runs are stable)."""
    parent: Dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:  # path-compress
            parent[x], x = root, parent[x]
        return root

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            # smaller URI becomes the canonical root
            lo, hi = sorted((ra, rb))
            parent[hi] = lo

    for persons in collisions.values():
        first = persons[0]
        for other in persons[1:]:
            union(first, other)

    comps: Dict[str, Set[str]] = {}
    for person in list(parent):
        comps.setdefault(find(person), set()).add(person)
    return comps


def canonical_keys_of(persons: Set[str]) -> Dict[str, Set[str]]:
    """``{person_uri: {icloud_contact_uid value, ...}}`` for the given nodes.

    One query for the whole component rather than one per node: this runs on
    the install critical path and a per-node round trip over a large address
    book is exactly the kind of thing that gets time-capped and killed.
    """
    if not persons:
        return {}
    values = " ".join(f"<{p}>" for p in sorted(persons))
    rows = _sparql_query(
        f"PREFIX pwg:<{PWG}> "
        "SELECT ?p ?v WHERE { "
        f"  VALUES ?p {{ {values} }} "
        "  ?p pwg:hasIdentifier ?id . "
        f'  ?id pwg:identifierType "{CANONICAL_KEY_TYPE}" ; pwg:identifierValue ?v . '
        "}"
    )
    out: Dict[str, Set[str]] = {}
    for r in rows:
        out.setdefault(r["p"]["value"], set()).add(r["v"]["value"])
    return out


def _merge_pair(canonical: str, dupe: str) -> None:
    """Move every triple referencing ``dupe`` onto ``canonical``, then leave
    a ``mergedInto`` tombstone on ``dupe`` so it does not cease to exist.

    THE TOMBSTONE IS NOT DECORATION (2026-09-07). This writer used to erase
    ``dupe`` completely. ``identity_resolver.merge_persons`` and
    ``batch_resolver._merge_oxigraph`` both leave ``<dupe> pwg:mergedInto
    <canonical>``, and every consumer that meets a merged URI keys on it:
    the assistant API reports ``merged_into`` instead of "unknown person",
    and the box-walk probe ``people_stores_reconcile`` counts a Qdrant
    vector as an ORPHAN only when its URI has no presence in the graph in
    any position. This module writes no Qdrant lines, and the install
    indexes people (step ``hydrate_people``) BEFORE this sweep runs, so
    every duplicate it folded left a people vector pointing at a URI that
    no longer existed: residual B on the reconcile probe (14 on the
    v1.0.74 walk, 25 on the Studio, every one of them an exact-key merge).
    The tombstone gives that vector something to resolve to, the same
    thing the other two writers give it.

    Written LAST, after both rewrites, because the outbound rewrite deletes
    every ``<dupe> ?p ?o`` -- including a tombstone written before it.
    """
    record_person_removal(dupe, "ostler_fda.dedupe_merge", "exact_identifier_merge_all_triples_moved")
    # Read both name sets BEFORE the move: afterwards they are one pile and
    # the survivor's own name can no longer be told apart from the dupe's.
    keep_names = _display_names(canonical)
    dupe_names = _display_names(dupe)
    # Outbound: <dupe> ?p ?o  ->  <canonical> ?p ?o
    _sparql_update(
        f"DELETE {{ <{dupe}> ?p ?o }} "
        f"INSERT {{ <{canonical}> ?p ?o }} "
        f"WHERE  {{ <{dupe}> ?p ?o }}"
    )
    # Inbound: ?s ?p <dupe>  ->  ?s ?p <canonical>
    _sparql_update(
        f"DELETE {{ ?s ?p <{dupe}> }} "
        f"INSERT {{ ?s ?p <{canonical}> }} "
        f"WHERE  {{ ?s ?p <{dupe}> }}"
    )
    # NAME TIERS (DMG #27): one displayName on the survivor, chosen UPWARD only.
    _elect_survivor_name(canonical, keep_names, dupe_names)
    # Tombstone: <dupe> pwg:mergedInto <canonical>
    _sparql_update(
        f"INSERT DATA {{ <{dupe}> <{PWG}mergedInto> <{canonical}> }}"
    )


# ---------------------------------------------------------------------------
# NAME TIERS ON MERGE (DMG #27, KNOWN-ISSUE 1). phone < email < human.
# ---------------------------------------------------------------------------
# The outbound rewrite above moves EVERY triple of the dupe, displayName and
# displayNameProvisional included, so a survivor came out holding BOTH names:
# "Jane Doe" and "+1 555 0100 01" side by side, and every reader picks one in
# arbitrary SPARQL order. Measured read-only on the DMG #27 walk box: 257
# survivors held a mixed set and every one of them had a merged-in node with no
# mergedAt, which only this writer leaves. 158 of them had a human-named
# merged-in node. CM051 #2857 put the tier rule into the two identity_resolver
# merge paths and the install-time repair, but not here, and install.sh runs
# this sweep AFTER that repair, so the repair saw a clean graph and this sweep
# then undid it.
#
# The rule is the one the other two paths use: the survivor takes the dupe's
# best name only when it is a HIGHER tier than anything the survivor already
# carries. Equal tiers keep the survivor's own name. A losing name is DEMOTED
# to alternateName (still useful for matching), never deleted -- the same
# convention as repair_placeholder_names. A kinship word ("Mum", "Dad") is
# never ELECTED: it cannot be the displayName. It is still demoted to
# alternateName like any losing name, because deleting it is data loss on
# exactly the family nodes this protects, and "who is Mum" then has nothing to
# match (Archie, #2866 review).


def _display_names(uri: str) -> List[str]:
    rows = _sparql_query(
        f"SELECT ?n WHERE {{ <{uri}> <{PWG}displayName> ?n }}"
    )
    return [r["n"]["value"] for r in rows if r.get("n", {}).get("value")]


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r")


def _tier_fn():
    # Lazy: pwg_ingest pulls in phonenumbers and package-relative imports, and
    # is only needed when there is a name to rank. One predicate, not a copy.
    # Branch on how THIS module was loaded, not on an ImportError: a missing
    # dependency inside pwg_ingest must surface as itself, not be masked by a
    # second, misleading "no module named pwg_ingest".
    if __package__:
        from .pwg_ingest import _display_name_tier, _NAME_TIER_NAME, _NAME_TIER_PLACEHOLDER
    else:  # run as a script, not as a package
        from pwg_ingest import _display_name_tier, _NAME_TIER_NAME, _NAME_TIER_PLACEHOLDER  # type: ignore
    return _display_name_tier, _NAME_TIER_NAME, _NAME_TIER_PLACEHOLDER


def choose_survivor_name(keep_names: List[str], dupe_names: List[str]):
    """Pure decision. Returns (winner, demote, is_human) or None when there is
    no name to choose. ``winner`` is the survivor's single displayName and is
    never a kinship word; every other name, kinship words included, is in
    ``demote`` (written as alternateName). Nothing is deleted."""
    keep = [n for n in dict.fromkeys(keep_names) if n and n.strip()]
    dupe = [n for n in dict.fromkeys(dupe_names) if n and n.strip() and n not in keep]
    every = keep + dupe
    if not every:
        return None
    tier, tier_name, tier_placeholder = _tier_fn()
    kinship = [n for n in every if tier(n) < tier_placeholder]   # never elected
    keep_ok = [n for n in keep if n not in kinship]
    dupe_ok = [n for n in dupe if n not in kinship]
    if not keep_ok and not dupe_ok:
        return None                       # only kinship words: leave untouched
    best_keep = max((tier(n) for n in keep_ok), default=-1)
    up = sorted((n for n in dupe_ok if tier(n) > best_keep), key=lambda n: (-tier(n), n))
    if up:
        winner = up[0]
    else:
        # The survivor's own best name. Among its own equal-tier values keep the
        # first in a stable order; this writer never reorders two human names.
        top = sorted(keep_ok, key=lambda n: (-tier(n), n))
        winner = top[0]
    demote = [n for n in keep_ok + dupe_ok if n != winner] + kinship
    return winner, demote, tier(winner) >= tier_name


def _elect_survivor_name(canonical: str, keep_names: List[str], dupe_names: List[str]) -> None:
    decided = choose_survivor_name(keep_names, dupe_names)
    if decided is None:
        return
    winner, demote, is_human = decided
    inserts = [f'<{canonical}> <{PWG}displayName> "{_escape(winner)}" .']
    inserts += [f'<{canonical}> <{PWG}alternateName> "{_escape(d)}" .' for d in demote]
    _sparql_update(
        f"DELETE {{ <{canonical}> <{PWG}displayName> ?old }} "
        f"WHERE {{ <{canonical}> <{PWG}displayName> ?old }} ; "
        f"INSERT DATA {{ {' '.join(inserts)} }}"
    )
    if is_human:
        # A real name is the resolution the provisional flag was waiting for.
        # The dupe's flag moved over with everything else; it must not label a
        # human-named survivor as a placeholder.
        _sparql_update(
            f"DELETE {{ <{canonical}> <{PWG}displayNameProvisional> ?f }} "
            f"WHERE {{ <{canonical}> <{PWG}displayNameProvisional> ?f }}"
        )


def merge_provisional_phone_twins(dry_run: bool = False) -> Dict[str, int]:
    """P13: fold each number-named person (no human name, no Contacts card)
    into the ONE named person who holds the same number, compared in
    normalised form. A number held by two or more named people is shared (a
    household landline) and is left alone, counted. See phone_twins.py.

    The exact-string sweep above cannot do this: a card stored in national
    form never string-matches the "+44..." handle. Raises on an unreadable
    store, like every read in this module; ``run`` reports that.
    """
    index = phone_twins.load_index(_sparql_query)
    merged = 0
    shared = 0
    for person in sorted(p for p in index.phones if index.is_unnamed(p)):
        holders: Set[str] = set()
        for v in index.phones[person]:
            holders |= index.named_holders(v)
        holders.discard(person)
        if not holders:
            continue
        if len(holders) > 1:
            shared += 1
            logger.info(
                "dedupe_merge: a number-named person shares its number with %d "
                "named people; not merged (household rule)", len(holders),
            )
            continue
        if not dry_run:
            _merge_pair(next(iter(holders)), person)
        merged += 1
    return {"phone_twins_merged": merged, "phone_twins_shared_refused": shared}


def run(dry_run: bool = False) -> Dict[str, int]:
    """Sweep the graph and merge all exact-identifier-colliding Persons.
    Returns ``{"collision_keys": N, "merged": M}`` (M = duplicate nodes
    folded away)."""
    collisions = find_collisions()
    comps = _components(collisions)

    # ── RULE 2 VETO. THIS MODULE HAD NONE, AND IT IS WHY THE OVER-MERGE
    #    SURVIVED TWO FIXES TO OTHER WRITERS. ────────────────────────────
    #
    # MEASURED on the v1.0.71 walk box, 2026-09-05, on a graph built entirely
    # inside the walk window:
    #
    #     icloud_contact_uid identifiers        1673   (anti-vacuity control)
    #     Person nodes with 2+ distinct uids      54
    #     Contacts cards swallowed               117
    #     mergedInto tombstones in the graph       1   (control: the predicate
    #                                                   CAN see tombstones)
    #     of the 54, how many carry a tombstone     0
    #
    # That last pair is the discriminator. `identity_resolver.merge_persons`
    # and `batch_resolver._merge_oxigraph` ALWAYS write a `mergedInto`
    # tombstone and both already veto on canonical keys (#1418, #1543). This
    # module writes no tombstone. Not one of the 54 survivors carries one, so
    # every one of them was welded here.
    #
    # WHY EVERY EARLIER AUDIT CAME BACK CLEAN: this file never mentions
    # `icloud_contact_uid` at all. It groups on email and phone VALUES, so a
    # search that starts from the canonical key -- or from the guarded
    # function -- cannot see the writer that corrupts it.
    #
    # THE VETO MUST ACCUMULATE ACROSS THE COMPONENT, NOT JUST THE PAIR.
    # `_components` is union-find, so A and C fold together through a bridging
    # node B that shares A's phone and C's email while sharing nothing with
    # each other. Checking only (canonical, dupe) in isolation would still let
    # a second card arrive transitively. So the surviving node's key set is
    # carried forward and every candidate is tested against it.
    #
    # FAIL CLOSED. If the key set cannot be read, refuse every merge in this
    # run rather than merging blind: a missed RULE 1 merge is visible and
    # fixable on the next sweep, while a RULE 2 violation is a silently
    # corrupted person that no later pass looks for.
    try:
        keys = canonical_keys_of({p for members in comps.values() for p in members})
    except Exception as exc:  # noqa: BLE001 -- deliberately broad; see above
        logger.error(
            "dedupe_merge: REFUSING ALL MERGES -- could not read %s values "
            "to enforce RULE 2 (%s). No writes were made.",
            CANONICAL_KEY_TYPE,
            exc,
        )
        return {"collision_keys": len(collisions), "merged": 0, "refused_rule2": 0,
                "refused_unreadable": True}

    merged = 0
    refused = 0
    for canonical, members in comps.items():
        held: Set[str] = set(keys.get(canonical, set()))
        for dupe in sorted(members - {canonical}):
            dupe_keys = keys.get(dupe, set())
            if len(held | dupe_keys) > 1:
                refused += 1
                logger.warning(
                    "dedupe_merge: RULE 2 veto -- not merging a node holding %d "
                    "canonical key(s) into one already holding %d. RULE 1 says "
                    "merge, RULE 2 says these are different people, and RULE 2 "
                    "wins. Both nodes left intact.",
                    len(dupe_keys),
                    len(held),
                )
                continue
            if not dry_run:
                _merge_pair(canonical, dupe)
            held |= dupe_keys
            merged += 1

    logger.info(
        "dedupe_merge: %d exact-id collision key(s); merged %d duplicate Person "
        "node(s); refused %d on RULE 2%s",
        len(collisions),
        merged,
        refused,
        " (dry-run, no writes)" if dry_run else "",
    )
    out = {"collision_keys": len(collisions), "merged": merged,
           "refused_rule2": refused, "refused_unreadable": False}
    # P13: the number-named twins the exact-string pass cannot see.
    try:
        out.update(merge_provisional_phone_twins(dry_run=dry_run))
    except Exception as exc:  # noqa: BLE001 -- reported in the result, not swallowed
        logger.error("dedupe_merge: phone-twin pass could not read the store (%s)", exc)
        out["phone_twins_unreadable"] = True
    return out


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    ap = argparse.ArgumentParser(description="Post-ingest exact-identifier dedup merge (RULE 1)")
    ap.add_argument("--dry-run", action="store_true", help="report collisions without merging")
    args = ap.parse_args()
    result = run(dry_run=args.dry_run)
    print(f"dedupe_merge: {result['collision_keys']} collision keys, {result['merged']} merged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
