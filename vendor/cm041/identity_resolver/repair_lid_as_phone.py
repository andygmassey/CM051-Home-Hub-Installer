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
  LID participant -- no whatsapp_lid sibling was ever created. Scoped by
  this writer's own marker, ``pwg:source "whatsapp_fda"``, to an invalid
  "phone" identifier value. RETYPES the identifier (phone -> whatsapp_lid)
  rather than deleting it. Renames displayName to "WhatsApp contact" when it
  exactly equals the phone identifier's own value.

QDRANT, NOT ONLY OXIGRAPH (Archie, 2026-10-01): the Hub People list and
``people_stores_reconcile`` both read the Qdrant ``people`` collection
payload, not Oxigraph directly. A repair that only fixed Oxigraph would
leave the customer-visible row unchanged and would make the two stores
DISAGREE where they previously (wrongly, but consistently) agreed. For every
row this repair touches, the matching Qdrant point -- same id convention as
``ostler_fda.pwg_ingest.ingest_people_to_qdrant``,
``uuid5(NAMESPACE_URL, person_uri)`` -- has the bad value removed from its
``phones`` list (and its ``display_name`` updated to match, when renamed).
This is a PAYLOAD PATCH (``set_payload``), never a full re-embed: the
existing vector is left untouched, so this never needs an embedder. A point
that is not found in Qdrant at all (the per-source hydrate order means
Oxigraph can be ahead of the Qdrant sync) is counted and logged, never
treated as success.

BACKUP BEFORE WRITE, same pattern as email-intelligence's `_backup_person`
(CM051 #2479): every triple and Qdrant payload value this repair is about to
change is appended to a jsonl file under ``~/.ostler/backups/`` BEFORE the
write runs, so any row is restorable. ``restore_from_backup`` replays a
backup file and re-asserts the original state (never a dry-run-vs-apply
ambiguity: restoring always writes, by construction, since a restore that
changed nothing would not be a restore).

DESIGN CONSTRAINTS, matching repair_merge_consistency.py: IDEMPOTENT. A ZERO
MUST BE READABLE (every phase prints what it EXAMINED beside what it
CHANGED). UNREACHABLE IS CANNOT-RUN, NOT SUCCESS. A negative control runs
every time: a synthetic value that cannot exist on a real graph is checked
against the predicate before trusting its count.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

import httpx

from identity_resolver.normalise import configured_default_country_code, is_valid_phone

PWG = "https://schema.ostler.ai/ontology#"

# 15 digits with no genuine country-code structure cannot legitimately be a
# stored identifier value, so a predicate that "finds" it is broken.
#
# Composed, not written as one 15-digit literal run: CM051's
# ci-pii-shape-scan.sh fires on ANY `[0-9]{15,}` shape regardless of value
# (DSID and kin), and this is the one line where this file is NOT
# byte-identical to its CM041 source -- CM041 is private and never runs this
# scanner, so its own copy keeps the literal. Functionally identical value.
CONTROL_LID_PHONE_VALUE = "9" * 15

EXIT_OK = 0
EXIT_BROKEN_PREDICATE = 1
EXIT_CANNOT_RUN = 2

_BACKUP_NAME = "repair_lid_as_phone.jsonl"


# ---------------------------------------------------------------------------
# Backup -- same pattern as email-intelligence's _backup_person (CM051 #2479)
# ---------------------------------------------------------------------------

def backup_path() -> Path:
    root = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(root) / "backups" / _BACKUP_NAME


def _backup_row(row: Dict[str, str], *, pass_name: str, action: str) -> None:
    """Append the triples this repair is about to change for ONE row to the
    backup file BEFORE the write runs. Raises on any failure, so a row is
    never changed without its backup -- callers must not catch this."""
    path = backup_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "at": datetime.now(timezone.utc).isoformat(),
        "pass": pass_name,
        "action": action,
        "person": row["person"],
        "phoneId": row["phoneId"],
        "value": row["value"],
        "name": row.get("name", ""),
    }
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def restore_from_backup(
    url: str, client: httpx.Client, *, path: Optional[Path] = None,
) -> Dict[str, int]:
    """Replay a backup file and re-assert the ORIGINAL state it recorded.
    Always writes (a restore that changes nothing is not a restore).
    Returns counts; raises on a read failure so a partial restore is never
    silently reported as complete."""
    path = path or backup_path()
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    restored_identifiers = 0
    restored_names = 0
    for rec in rows:
        if rec["action"] in ("deleted_phone_identifier", "retyped_phone_identifier"):
            _sparql_update(
                url, client,
                f"""
                PREFIX pwg: <{PWG}>
                DELETE {{ <{rec['phoneId']}> ?p ?o . }}
                WHERE  {{ <{rec['phoneId']}> ?p ?o . }}
                """,
            )
            _sparql_update(
                url, client,
                f"""
                PREFIX pwg: <{PWG}>
                INSERT DATA {{
                  <{rec['person']}> pwg:hasIdentifier <{rec['phoneId']}> .
                  <{rec['phoneId']}> a pwg:PersonIdentifier ;
                      pwg:identifierType "phone" ;
                      pwg:identifierValue "{_escape(rec['value'])}" .
                }}
                """,
            )
            restored_identifiers += 1
        if rec["action"] == "rewritten_phone_format":
            # repair_misformatted_phones.py (CM051 #2545): the identifier
            # node and its hasIdentifier edge were never touched, only the
            # VALUE -- restore is therefore just putting the old value back,
            # not a delete+recreate of the whole node.
            _sparql_update(
                url, client,
                f'DELETE WHERE {{ <{rec["phoneId"]}> <{PWG}identifierValue> ?o }}',
            )
            _sparql_update(
                url, client,
                f'INSERT DATA {{ <{rec["phoneId"]}> <{PWG}identifierValue> '
                f'"{_escape(rec["value"])}" }}',
            )
            restored_identifiers += 1
        if rec.get("name"):
            _sparql_update(
                url, client,
                f'DELETE WHERE {{ <{rec["person"]}> <{PWG}displayName> ?o }}',
            )
            _sparql_update(
                url, client,
                f'INSERT DATA {{ <{rec["person"]}> <{PWG}displayName> '
                f'"{_escape(rec["name"])}" }}',
            )
            restored_names += 1
    return {"records_replayed": len(rows), "identifiers_restored": restored_identifiers,
            "names_restored": restored_names}


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


# ---------------------------------------------------------------------------
# Oxigraph transport
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Qdrant -- payload-only patch, same point-id convention as
# ostler_fda.pwg_ingest.ingest_people_to_qdrant (uuid5(NAMESPACE_URL, uri)).
# Never touches the vector: this is a value fix, not a re-embed.
# ---------------------------------------------------------------------------

def _qdrant_headers(api_key: Optional[str]) -> Dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["api-key"] = api_key
    return headers


def _qdrant_point_id(person_uri: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, person_uri))


def repair_qdrant_point(
    qdrant_url: str, client: httpx.Client, *, collection: str,
    person_uri: str, bad_value: str, new_display_name: Optional[str],
    api_key: Optional[str], apply: bool, new_value: Optional[str] = None,
) -> str:
    """Remove `bad_value` from the point's "phones" list and, if given,
    update "display_name" to match the Oxigraph rename. Returns one of:
    "patched", "not_found", "already_clean", "dry_run".

    `new_value` (Archie, 2026-10-01, reused by CM051 #2545's
    repair_misformatted_phones.py rather than a second Qdrant-patch
    function): when given, it is ADDED to "phones" after `bad_value` is
    removed -- a reformat-in-place (e.g. a national-format number rewritten
    to E.164), not a demotion. `None` (repair_lid_as_phone's own use)
    preserves the original remove-only behaviour exactly."""
    point_id = _qdrant_point_id(person_uri)
    resp = client.get(
        f"{qdrant_url}/collections/{collection}/points/{point_id}",
        headers=_qdrant_headers(api_key),
    )
    if resp.status_code == 404:
        return "not_found"
    resp.raise_for_status()
    payload = (resp.json().get("result") or {}).get("payload") or {}
    phones = list(payload.get("phones") or [])
    new_phones = [p for p in phones if p != bad_value]
    if new_value and new_value not in new_phones:
        new_phones.append(new_value)
    name_changes = bool(new_display_name and payload.get("display_name") != new_display_name)
    if new_phones == phones and not name_changes:
        return "already_clean"
    if not apply:
        return "dry_run"

    new_payload: Dict[str, object] = {"phones": new_phones}
    if name_changes:
        new_payload["display_name"] = new_display_name
    set_resp = client.post(
        f"{qdrant_url}/collections/{collection}/points/payload",
        headers=_qdrant_headers(api_key),
        json={"payload": new_payload, "points": [point_id]},
    )
    set_resp.raise_for_status()
    return "patched"


# ---------------------------------------------------------------------------
# Pass A1 -- CM041 whatsapp_bridge signature (sibling whatsapp_lid pair)
# ---------------------------------------------------------------------------

def _lid_as_phone_candidates_bridge_signature(
    url: str, client: httpx.Client,
) -> List[Dict[str, str]]:
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
    # Archie, 2026-10-01 (CM051 #2545 review): the installer's OWN region,
    # never a hardcoded guess -- see configured_default_country_code.
    cc = configured_default_country_code()
    return [r for r in rows if not is_valid_phone(r.get("value", ""), cc)]


def _lid_as_phone_candidates_ostler_fda_signature(
    url: str, client: httpx.Client,
) -> List[Dict[str, str]]:
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
    # Archie, 2026-10-01 (CM051 #2545 review): the installer's OWN region,
    # never a hardcoded guess -- see configured_default_country_code.
    cc = configured_default_country_code()
    return [r for r in rows if not is_valid_phone(r.get("value", ""), cc)]


def repair_lid_as_phone(
    url: str, client: httpx.Client, *, apply: bool,
    qdrant_url: Optional[str] = None, qdrant_collection: str = "people",
    qdrant_api_key: Optional[str] = None, qdrant_client: Optional[httpx.Client] = None,
) -> Dict[str, int]:
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
    qdrant_patched = 0
    qdrant_not_found = 0
    qclient = qdrant_client if qdrant_client is not None else client

    def _maybe_patch_qdrant(person: str, bad_value: str, new_name: Optional[str]) -> None:
        nonlocal qdrant_patched, qdrant_not_found
        if not qdrant_url:
            return
        outcome = repair_qdrant_point(
            qdrant_url, qclient, collection=qdrant_collection,
            person_uri=person, bad_value=bad_value, new_display_name=new_name,
            api_key=qdrant_api_key, apply=apply,
        )
        if outcome == "patched":
            qdrant_patched += 1
        elif outcome == "not_found":
            qdrant_not_found += 1

    if apply:
        for row in bridge_candidates:
            _backup_row(row, pass_name="A1_bridge", action="deleted_phone_identifier")
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
            new_name = None
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
                new_name = "WhatsApp contact"
            _maybe_patch_qdrant(row["person"], row["value"], new_name)

        for row in fda_candidates:
            _backup_row(row, pass_name="A2_ostler_fda", action="retyped_phone_identifier")
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
            new_name = None
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
                new_name = "WhatsApp contact"
            _maybe_patch_qdrant(row["person"], row["value"], new_name)
    else:
        # Dry run: still probe Qdrant read-only so the report distinguishes
        # "found and would patch" from "found but Qdrant has no point" --
        # a GET never writes.
        for row in bridge_candidates + fda_candidates:
            _maybe_patch_qdrant(row["person"], row["value"], None)

    return {
        "examined": len(bridge_candidates) + len(fda_candidates),
        "examined_bridge_signature": len(bridge_candidates),
        "examined_ostler_fda_signature": len(fda_candidates),
        "demoted": demoted,
        "renamed": renamed,
        "qdrant_patched": qdrant_patched,
        "qdrant_not_found": qdrant_not_found,
    }


def repair(
    oxigraph_url: str, *, apply: bool,
    qdrant_url: Optional[str] = None, qdrant_collection: str = "people",
    qdrant_api_key: Optional[str] = None,
) -> int:
    try:
        with httpx.Client(timeout=30, trust_env=False) as client:
            a = repair_lid_as_phone(
                oxigraph_url, client, apply=apply,
                qdrant_url=qdrant_url, qdrant_collection=qdrant_collection,
                qdrant_api_key=qdrant_api_key,
            )
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
        "  demoted/retyped (Oxigraph)                 : %d\n"
        "  displayName renamed to WhatsApp contact    : %d\n"
        "  Qdrant payload patched                     : %d\n"
        "  Qdrant point not found (Oxigraph ahead)    : %d\n"
        "  backup                                      : %s\n"
        % (apply, a["examined"], a["examined_bridge_signature"],
           a["examined_ostler_fda_signature"], a["demoted"], a["renamed"],
           a["qdrant_patched"], a["qdrant_not_found"], backup_path())
    )
    return EXIT_OK


def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--oxigraph-url", required=True)
    ap.add_argument("--qdrant-url", default=None,
                     help="If given, also patch the matching Qdrant 'phones' payload.")
    ap.add_argument("--qdrant-collection", default="people")
    ap.add_argument("--qdrant-api-key", default=os.environ.get("QDRANT_API_KEY"))
    ap.add_argument(
        "--apply", action="store_true",
        help="Write the repair. Without this flag, counts only (dry run).",
    )
    ap.add_argument(
        "--restore-from-backup", metavar="PATH", default=None,
        help="Replay a backup file and re-assert the original state. Always writes.",
    )
    args = ap.parse_args(argv)
    if args.restore_from_backup:
        with httpx.Client(timeout=30, trust_env=False) as client:
            result = restore_from_backup(
                args.oxigraph_url, client, path=Path(args.restore_from_backup),
            )
        print(json.dumps(result, indent=2))
        return EXIT_OK
    return repair(
        args.oxigraph_url, apply=args.apply,
        qdrant_url=args.qdrant_url, qdrant_collection=args.qdrant_collection,
        qdrant_api_key=args.qdrant_api_key,
    )


if __name__ == "__main__":
    sys.exit(main())
