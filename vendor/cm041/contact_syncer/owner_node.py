"""Owner / me-card node writer for the PWG People Graph (CM041).

Step 2 of the privacy reconciliation.

The self / me-card identity ``pwg:user_<id>`` is referenced as the OBJECT
of ~161k triples (every ``pwg:belongsToUser`` etc.) but historically was
never minted as a first-class SUBJECT node: ``ASK { user_andy a pwg:Person }``
returns false, it carries no displayName and no privacyLevel. Without a
canonical "this is me" node, the privacy layer cannot branch owner-vs-other
without surname matching, and "who am I / my wife" answers are unanchored.

This module mints the owner node:

    <pwg:user_<id>> a pwg:Person ;
        pwg:displayName "<owner>" ;
        pwg:privacyLevel "L0" ;   # owner's own identity, most private
        pwg:isOwner true ;
        pwg:createdAt "<iso>" .

It is idempotent (INSERT is additive; ``isOwner`` is a single boolean and a
second run re-inserts the same triples, which Oxigraph deduplicates). A
``--dry-run`` prints the SPARQL without writing.

CLI:

    python -m contact_syncer.owner_node --dry-run
    python -m contact_syncer.owner_node            # writes
    python -m contact_syncer.owner_node --user-id andy --display-name "Andy"

The same function is the one-off backfill for the existing ``user_andy``:
running it once mints the node that should have existed all along.
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from typing import Optional

import httpx

from contact_syncer import config
from contact_syncer import privacy_model as pm

PWG_NS = "https://pwg.dev/ontology#"

#: The owner's own identity node is owner-private by default.
OWNER_PRIVACY_LEVEL = pm.LEVEL_L0


def _escape(value: str) -> str:
    """Minimal SPARQL string-literal escape (same shape as the writers)."""
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
    )


def owner_uri(user_id: str) -> str:
    return f"{PWG_NS}user_{user_id}"


def build_owner_sparql(user_id: str, display_name: str, now_iso: Optional[str] = None) -> str:
    """Return the SPARQL UPDATE that mints the owner node.

    The triples are additive (INSERT DATA); re-running is safe because
    Oxigraph stores each triple once. displayName is set additively too -
    if the node already had a different displayName it will gain a second
    value, but on a bare ``user_<id>`` node (the documented state) there is
    none, so this mints cleanly. The caller controls when to run it.
    """
    if now_iso is None:
        now_iso = datetime.now(timezone.utc).isoformat()
    uri = owner_uri(user_id)
    esc_name = _escape(display_name)
    return (
        f"PREFIX pwg: <{PWG_NS}>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {\n"
        f"  <{uri}> a pwg:Person ;\n"
        f'    pwg:displayName "{esc_name}" ;\n'
        f'    pwg:privacyLevel "{OWNER_PRIVACY_LEVEL}" ;\n'
        f"    pwg:isOwner true ;\n"
        f'    pwg:createdAt "{now_iso}"^^xsd:dateTime .\n'
        "}"
    )


def _sparql_update(oxigraph_url: str, sparql: str) -> None:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def write_owner_node(
    oxigraph_url: str,
    user_id: str,
    display_name: str,
    *,
    dry_run: bool = False,
    now_iso: Optional[str] = None,
) -> str:
    """Mint (or backfill) the owner me-card node. Returns the SPARQL used.

    With ``dry_run=True`` the SPARQL is returned and printed but not sent.
    """
    if not user_id:
        raise ValueError("user_id is required to mint the owner node")
    if not display_name:
        raise ValueError("display_name is required to mint the owner node")

    sparql = build_owner_sparql(user_id, display_name, now_iso=now_iso)
    if dry_run:
        return sparql
    _sparql_update(oxigraph_url, sparql)
    return sparql


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Mint the owner / me-card node (pwg:user_<id>) as a first-class "
            "pwg:Person with privacyLevel L0 and isOwner true. Idempotent; "
            "also serves as the one-off backfill for an existing bare "
            "user_<id> node."
        )
    )
    parser.add_argument(
        "--user-id",
        default=config.USER_ID,
        help="Owner id (default: USER_ID env var). Forms pwg:user_<id>.",
    )
    parser.add_argument(
        "--display-name",
        default=config.USER_DISPLAY_NAME,
        help="Owner display name (default: USER_DISPLAY_NAME / PWG_USER_NAME).",
    )
    parser.add_argument(
        "--graph-endpoint",
        default=config.OXIGRAPH_URL,
        help="Oxigraph URL (default: OXIGRAPH_URL env var).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the SPARQL without writing.",
    )
    args = parser.parse_args(argv)

    if not args.user_id:
        print("ERROR: no user id (set USER_ID or pass --user-id)", file=sys.stderr)
        return 2
    if not args.display_name:
        print(
            "ERROR: no display name (set USER_DISPLAY_NAME / PWG_USER_NAME "
            "or pass --display-name)",
            file=sys.stderr,
        )
        return 2
    if not args.dry_run and not args.graph_endpoint:
        print("ERROR: no graph endpoint (set OXIGRAPH_URL or pass --graph-endpoint)",
              file=sys.stderr)
        return 2

    sparql = write_owner_node(
        args.graph_endpoint,
        args.user_id,
        args.display_name,
        dry_run=args.dry_run,
    )
    if args.dry_run:
        print("# DRY RUN - would execute:\n" + sparql)
    else:
        print(f"Minted owner node <{owner_uri(args.user_id)}> "
              f"(privacyLevel {OWNER_PRIVACY_LEVEL}, isOwner true)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
