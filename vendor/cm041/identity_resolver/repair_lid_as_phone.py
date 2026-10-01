#!/usr/bin/env python3
"""One-time repair for CM051 #2543: a WhatsApp LID written as a "phone"
identifier before this fix landed. Idempotent: a second run on an
already-repaired graph finds zero and changes nothing.

TWO INDEPENDENT PASSES, because two different writers left two different
fingerprints (Archie, 2026-10-01: "#181's repair covers only CM041-minted
[nodes]"):

  PASS A1 -- CM041's whatsapp_bridge. Its old bug wrote the SAME unresolved
  LID value under BOTH identifierType "phone" AND identifierType
  "whatsapp_lid" -- the bridge always created both identifiers, so a sibling
  pair sharing one invalid value is this writer's fingerprint. Finds
  "phone" identifiers that (1) are NOT a valid phone number
  (``is_valid_phone``) and (2) have a sibling "whatsapp_lid" identifier on
  the SAME node carrying the SAME value. Deletes the bogus phone identifier
  (the whatsapp_lid sibling is untouched) and, where the displayName is the
  literal `"Unknown (<value>)"` sentinel the bridge wrote alongside it,
  renames it to `"WhatsApp contact"`.

  PASS A2 -- ostler_fda's ingest_whatsapp (the writer that actually ships,
  CM051 #2577). Its old bug wrote ONLY an invalid "phone" identifier for an
  LID participant -- no whatsapp_lid sibling was ever created, so Pass A1's
  predicate structurally cannot see these nodes (proven, not assumed: see
  tests/test_repair_lid_as_phone.py's
  test_pass_a1_does_not_see_the_ostler_fda_signature). Scoped by this
  writer's own marker, ``pwg:source "whatsapp_fda"``, to an invalid "phone"
  identifier value (no sibling required). The person URI this writer mints
  is a full uuid5-derived, dashed 36-char string
  (``_person_id_from_identifier`` in ostler_fda/pwg_ingest.py) rather than
  CM041's truncated uuid4 hex -- covered by a synthetic uuid5-shaped node in
  the tests, not merely asserted. RETYPES the identifier (phone ->
  whatsapp_lid) rather than deleting it, because this writer's old bug left
  no separate whatsapp_lid identifier to fall back on -- the LID value is
  still worth keeping, just under the right type. Renames the displayName to
  "WhatsApp contact" when it is exactly the phone identifier's own value
  (ostler_fda's old ``_whatsapp_display_name`` wrote the SAME "+<digits>"
  string as both the phone value and the display name, so an exact match is
  this writer's sentinel, not the "Unknown (...)" string Pass A1 looks for).

DESIGN CONSTRAINTS, matching repair_merge_consistency.py: IDEMPOTENT. A ZERO
MUST BE READABLE (every phase prints what it EXAMINED beside what it
CHANGED). UNREACHABLE IS CANNOT-RUN, NOT SUCCESS. A negative control runs
every time: a synthetic value that cannot exist on a real graph is checked
against the predicate before trusting its count.
"""
from __future__ import annotations

import argparse
import sys
from typing import Dict, List

import httpx

from identity_resolver.normalise import is_valid_phone

PWG = "https://schema.ostler.ai/ontology#"

# 15 digits with no genuine country-code structure cannot legitimately be a
# stored identifier value, so a predicate that "finds" it is broken.
CONTROL_LID_PHONE_VALUE = "999999999999999"

EXIT_OK = 0
EXIT_BROKEN_PREDICATE = 1
EXIT_CANNOT_RUN = 2


def _sparql_query(url: str, client: httpx.Client, sparql: str) -> List[Dict[str, str]]:
    resp = client.post(
        f"{url}/query",
        content=sparql,
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
    )
    resp.raise_for_status()
    rows = []
    for binding in resp.json().get("results", {}).get("bindings", []):
        rows.append({var: info.get("value", "") for var, info in binding.items()})
    return rows


def _sparql_update(url: str, client: httpx.Client, sparql: str) -> None:
    resp = client.post(
        f"{url}/update",
        content=sparql,
        headers={"Content-Type": "application/sparql-update"},
    )
    resp.raise_for_status()


def _lid_as_phone_candidates_bridge_signature(
    url: str, client: httpx.Client,
) -> List[Dict[str, str]]:
    """PASS A1. Every (person, phone_id, phone_value) where a phone
    identifier's value exactly matches a whatsapp_lid identifier's value on
    the same person -- CM041 whatsapp_bridge's fingerprint."""
    rows = _sparql_query(
        url, client,
        f"""
        SELECT ?person ?phoneId ?value ?name WHERE {{
          ?person <{PWG}hasIdentifier> ?phoneId .
          ?phoneId <{PWG}identifierType> "phone" ;
                   <{PWG}identifierValue> ?value .
          ?person <{PWG}hasIdentifier> ?lidId .
          ?lidId <{PWG}identifierType> "whatsapp_lid" ;
                 <{PWG}identifierValue> ?value .
          OPTIONAL {{ ?person <{PWG}displayName> ?name }}
        }}
        """,
    )
    return [r for r in rows if not is_valid_phone(r.get("value", ""))]


def _lid_as_phone_candidates_ostler_fda_signature(
    url: str, client: httpx.Client,
) -> List[Dict[str, str]]:
    """PASS A2. Every (person, phone_id, phone_value) where a person sourced
    from ostler_fda's WhatsApp ingest (``pwg:source "whatsapp_fda"``) carries
    an invalid "phone" identifier -- no sibling whatsapp_lid required, because
    this writer's old bug never created one."""
    rows = _sparql_query(
        url, client,
        f"""
        SELECT ?person ?phoneId ?value ?name WHERE {{
          ?person <{PWG}source> "whatsapp_fda" .
          ?person <{PWG}hasIdentifier> ?phoneId .
          ?phoneId <{PWG}identifierType> "phone" ;
                   <{PWG}identifierValue> ?value .
          OPTIONAL {{ ?person <{PWG}displayName> ?name }}
        }}
        """,
    )
    return [r for r in rows if not is_valid_phone(r.get("value", ""))]


def repair_lid_as_phone(url: str, client: httpx.Client, *, apply: bool) -> Dict[str, int]:
    bridge_candidates = _lid_as_phone_candidates_bridge_signature(url, client)
    fda_candidates = _lid_as_phone_candidates_ostler_fda_signature(url, client)
    control_hit = any(
        r["value"] == CONTROL_LID_PHONE_VALUE
        for r in bridge_candidates + fda_candidates
    )
    if control_hit:
        raise RuntimeError(
            "negative control value was matched by the lid-as-phone "
            "predicate -- the query is broken, nothing was changed"
        )

    renamed = 0
    demoted = 0
    if apply:
        for row in bridge_candidates:
            _sparql_update(
                url, client,
                f"""
                PREFIX pwg: <{PWG}>
                DELETE {{ <{row['person']}> pwg:hasIdentifier <{row['phoneId']}> .
                          <{row['phoneId']}> ?p ?o . }}
                WHERE  {{ <{row['person']}> pwg:hasIdentifier <{row['phoneId']}> .
                          <{row['phoneId']}> ?p ?o . }}
                """,
            )
            demoted += 1
            sentinel = f"Unknown ({row['value']})"
            if row.get("name") == sentinel:
                _sparql_update(
                    url, client,
                    f'DELETE WHERE {{ <{row["person"]}> <{PWG}displayName> ?o }}',
                )
                _sparql_update(
                    url, client,
                    f'INSERT DATA {{ <{row["person"]}> <{PWG}displayName> '
                    f'"WhatsApp contact" }}',
                )
                renamed += 1

        for row in fda_candidates:
            # RETYPE, not delete: ostler_fda's old bug left no separate
            # whatsapp_lid identifier, so the LID value is only recorded
            # here. Keep it, under the right type.
            _sparql_update(
                url, client,
                f"""
                PREFIX pwg: <{PWG}>
                DELETE {{ <{row['phoneId']}> pwg:identifierType "phone" . }}
                INSERT {{ <{row['phoneId']}> pwg:identifierType "whatsapp_lid" . }}
                WHERE  {{ <{row['phoneId']}> pwg:identifierType "phone" . }}
                """,
            )
            demoted += 1
            # ostler_fda's old _whatsapp_display_name wrote the SAME string
            # as both the phone value and the displayName -- an exact match
            # is this writer's sentinel, not Pass A1's "Unknown (...)".
            if row.get("name") == row.get("value"):
                _sparql_update(
                    url, client,
                    f'DELETE WHERE {{ <{row["person"]}> <{PWG}displayName> ?o }}',
                )
                _sparql_update(
                    url, client,
                    f'INSERT DATA {{ <{row["person"]}> <{PWG}displayName> '
                    f'"WhatsApp contact" }}',
                )
                renamed += 1

    return {
        "examined": len(bridge_candidates) + len(fda_candidates),
        "examined_bridge_signature": len(bridge_candidates),
        "examined_ostler_fda_signature": len(fda_candidates),
        "demoted": demoted,
        "renamed": renamed,
    }


def repair(oxigraph_url: str, *, apply: bool) -> int:
    try:
        with httpx.Client(timeout=30, trust_env=False) as client:
            a = repair_lid_as_phone(oxigraph_url, client, apply=apply)
    except RuntimeError as exc:
        print(f"REFUSING: {exc}")
        return EXIT_BROKEN_PREDICATE
    except Exception as exc:  # noqa: BLE001 -- a failed READ is CANNOT-RUN
        print(
            f"CANNOT-RUN: the graph at {oxigraph_url} could not be read "
            f"({exc}). Nothing was repaired, which is NOT the same as "
            "nothing being wrong."
        )
        return EXIT_CANNOT_RUN

    print(
        "LID written as phone (CM051 #2543), apply=%s\n"
        "  phone identifiers examined (total)        : %d\n"
        "    Pass A1, CM041 bridge signature          : %d\n"
        "    Pass A2, ostler_fda signature             : %d\n"
        "  demoted/retyped                           : %d\n"
        "  displayName renamed to WhatsApp contact   : %d\n"
        % (apply, a["examined"], a["examined_bridge_signature"],
           a["examined_ostler_fda_signature"], a["demoted"], a["renamed"])
    )
    return EXIT_OK


def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--oxigraph-url", required=True)
    ap.add_argument(
        "--apply", action="store_true",
        help="Write the repair. Without this flag, counts only (dry run).",
    )
    args = ap.parse_args(argv)
    return repair(args.oxigraph_url, apply=args.apply)


if __name__ == "__main__":
    sys.exit(main())
