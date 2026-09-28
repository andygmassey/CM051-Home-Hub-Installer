"""CLI entry point for the pwg-email-ingest console script.

Invoked by the Ostler hub email-ingest LaunchAgent (vendored at
``vendor/email_ingest/bin/email-ingest-tick.sh`` in CM051). The
LaunchAgent calls::

    pwg-email-ingest mbox <path-to-mbox>

This module wraps CM021's FastMboxParser + EmailFilter primitives
and upserts Person + lastContactEmail triples into the customer's
local Oxigraph instance. It does NOT do signature mining or
relationship scoring (those are CM046's research-only territory and
deferred to v1.1+); the v1.0 goal here is "populate the People wing
of the wiki with who the customer has been corresponding with".

CLI shape
---------

``pwg-email-ingest mbox <path>`` [--backfill-days N] [--graph-endpoint URL]
[--json] [--dry-run]

- ``--backfill-days N``  Only ingest emails dated within the last N
  days (cutoff is wall-clock today minus N). When omitted, processes
  the entire mbox.
- ``--graph-endpoint URL``  Oxigraph SPARQL endpoint root (default
  http://localhost:7878). The CLI POSTs SPARQL UPDATE queries to
  ``{endpoint}/update`` to upsert Person triples.
- ``--json``  Emit a single line of structured JSON to stdout on
  completion. Counts only -- no subjects, bodies, or from-addresses.
  Privacy AC6 from the CX-81 B2 brief.
- ``--dry-run``  Parse + count but do not write to Oxigraph.

Exit codes
----------

The CLI is intentionally graceful: a non-existent mbox, an empty
mbox, or an Oxigraph that refuses to talk back all result in exit
code 0 with the empty / error state surfaced in the JSON. Install.sh
uses the JSON to decide which MSG_* string to render, and an exit-0
keeps the install moving rather than blocking on a transient.

Exit code 2 is reserved for argument-parsing failures (argparse
default). Any other non-zero is an unexpected crash that the calling
``email-ingest-tick.sh`` should surface to launchd.

Privacy contract (AC6)
----------------------

This CLI MUST NOT emit any email subject, body content, From
header, or addressable identifier in any output stream (stdout,
stderr, --json payload). The only outputs are counts and the
upserted Oxigraph triples (which stay on the customer's machine).
"""
from __future__ import annotations

import argparse
import email.utils
import json
import os
import re
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Set

# Absolute imports so the console_script entry point works after
# pip-install. The CM021 in-tree scripts (pipeline.py etc.) rely on
# a sys.path hack; for the vendored install path the package layout
# means src is on the venv's sys.path already.
from src.filters import EmailFilter
from src.parsers.fast_mbox_parser import FastEmail, FastMboxParser


_OXIGRAPH_DEFAULT = "http://localhost:7878"

# Canonical PWG ontology namespace. Must match the writer-side IRI
# scheme used in vendor/ostler_fda/pwg_ingest.py (the FDA ingest
# path that creates Person nodes from iMessage, WhatsApp, and Mail).
# Diverging here means email-ingest's Person triples never join the
# rest of the People graph in Oxigraph -- which was exactly the
# Z2 P0-1 bug: the old `urn:ostler:` namespace + `urn:ostler:person/<email>`
# IRI shape produced orphaned subgraphs and a blank Email column in
# the wiki for every customer.
PWG_NS = "https://schema.ostler.ai/ontology#"


def _stderr(msg: str) -> None:
    """Write a diagnostic line to stderr, never stdout.

    install.sh consumes stdout for the JSON contract -- mixing
    progress chatter there would break the parser. launchd captures
    stderr to email-ingest.err.
    """
    print(msg, file=sys.stderr, flush=True)


def _clean_email_for_iri(email: str) -> str:
    """Normalise an email for use as a PWG Person IRI key.

    Mirrors ``_person_id_from_identifier`` in
    ``vendor/ostler_fda/pwg_ingest.py`` (the canonical writer for
    iMessage / WhatsApp / Mail Person nodes), which uses
    ``identifier.strip().lower()`` before hashing into a uuid5.
    Keep these two helpers byte-for-byte equivalent so the resulting
    Person IRIs collide deterministically across sources.
    """
    return email.strip().lower()


def _safe_person_iri(email: str) -> str:
    """Return the canonical PWG Person IRI for an email address.

    Shape: ``https://schema.ostler.ai/ontology#person_<uuid5>`` where the
    uuid5 is derived from ``https://schema.ostler.ai/person/<clean>`` using
    ``uuid.NAMESPACE_URL`` -- identical to the FDA ingest writer in
    ``vendor/ostler_fda/pwg_ingest.py`` so emails ingested via this
    CLI join the same Person nodes the FDA path creates from
    iMessage / WhatsApp.
    """
    clean = _clean_email_for_iri(email)
    person_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://schema.ostler.ai/person/{clean}"))
    return f"{PWG_NS}person_{person_id}"


def _escape_sparql_literal(value: str) -> str:
    """Minimal SPARQL string literal escaping.

    Enough for human names + email addresses, which is all we feed
    in. Anything that gets here has already passed FastMboxParser's
    header decoding.
    """
    return (
        value.replace("\\", "\\\\")
             .replace('"', '\\"')
             .replace("\n", "\\n")
             .replace("\r", "\\r")
    )


def _build_upsert(
    person_iri: str,
    email: str,
    name: str,
    last_contact_iso: Optional[str],
) -> str:
    """Build a SPARQL UPDATE that upserts a Person + lastContactEmail.

    Idempotent on repeated calls with the same email: the DELETE
    clause clears any prior lastContactEmail before the INSERT,
    which lets the per-tick replay (or backfill chunks crossing the
    same correspondent) advance the timestamp monotonically. The
    rdf:type + skos:prefLabel land via INSERT DATA only -- if they
    already exist Oxigraph treats the re-insert as a no-op.

    THE displayName IS TIERED AND ONLY EVER MOVES UP (CM051 #2361).
    A sender with no name used to get NO displayName at all, and the
    people index reads only Persons that have one, so every email-only
    correspondent was in the graph and absent from search and the wiki:
    28 of them on the v1.0.102 walk box, the whole of the people-count
    disagreement. The tier table is the one ostler_fda uses
    (_upsert_display_name): an email address is tier 1 and is written
    PROVISIONAL; a human name is tier 2 and clears the flag. Tier 1
    never replaces anything but an absent name or a provisional
    non-email handle; tier 2 replaces anything still provisional; a
    real name already present is never touched.
    """
    email_lit = _escape_sparql_literal(email)

    label = name if name else email
    label_lit = _escape_sparql_literal(label)

    display = name if (name and "@" not in name) else email
    display_lit = _escape_sparql_literal(display)
    is_human_name = display is name and bool(name)

    if is_human_name:
        guard = "!BOUND(?dn) || BOUND(?prov)"
        flag = ""
    else:
        guard = '!BOUND(?dn) || (BOUND(?prov) && !CONTAINS(STR(?dn), "@"))'
        flag = (
            f'  <{person_iri}> pwg:displayNameProvisional '
            '"true"^^<http://www.w3.org/2001/XMLSchema#boolean> .'
        )

    parts = []
    parts.append("PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>")
    parts.append(f"PREFIX pwg: <{PWG_NS}>")
    parts.append("PREFIX skos: <http://www.w3.org/2004/02/skos/core#>")
    parts.append("")
    parts.append(f"DELETE {{ <{person_iri}> pwg:lastContactEmail ?old }}")
    parts.append(f"WHERE  {{ <{person_iri}> pwg:lastContactEmail ?old }} ;")
    parts.append("")
    parts.append("INSERT DATA {")
    parts.append(f"  <{person_iri}> rdf:type pwg:Person ;")
    parts.append(f"                 pwg:email \"{email_lit}\" ;")
    parts.append(f"                 skos:prefLabel \"{label_lit}\" .")
    if last_contact_iso:
        ts_lit = _escape_sparql_literal(last_contact_iso)
        parts.append(
            f"  <{person_iri}> pwg:lastContactEmail "
            f"\"{ts_lit}\"^^<http://www.w3.org/2001/XMLSchema#dateTime> ."
        )
    parts.append("} ;")
    parts.append("")
    parts.append("DELETE {")
    parts.append(f"  <{person_iri}> pwg:displayName ?dn .")
    parts.append(f"  <{person_iri}> pwg:displayNameProvisional ?prov .")
    parts.append("}")
    parts.append("INSERT {")
    parts.append(f"  <{person_iri}> pwg:displayName \"{display_lit}\" .")
    if flag:
        parts.append(flag)
    parts.append("}")
    parts.append("WHERE {")
    parts.append(f"  OPTIONAL {{ <{person_iri}> pwg:displayName ?dn }}")
    parts.append(f"  OPTIONAL {{ <{person_iri}> pwg:displayNameProvisional ?prov }}")
    parts.append(f"  FILTER ({guard})")
    parts.append("}")
    return "\n".join(parts)



# --- Automated and organisation senders are not people (CM051 v1.0.106) ---
#
# Andy's v1.0.105 walk: the People list was full of card issuers, trade
# bodies, shops and promotions, because every inbound sender became a
# pwg:Person. The domain filter above only knows a curated list. These are
# the signals a mail client itself uses to tell bulk and machine mail from a
# person writing: RFC 2369 list headers, RFC 3834 Auto-Submitted, the
# Precedence convention, the feedback and campaign headers every bulk
# sending platform stamps, and the no-reply family of local parts.

_AUTOMATED_HEADERS = (
    "list-unsubscribe", "list-id", "list-post", "feedback-id",
    "x-campaign-id", "x-mc-user", "x-mailgun-sid", "x-sg-eid",
    "x-ses-outgoing",
    # NOT x-auto-response-suppress: Exchange/Outlook can stamp it on
    # ordinary person-to-person mail, so it would demote real people.
)
_BULK_PRECEDENCE = {"bulk", "list", "junk"}
_AUTOMATED_LOCAL_RE = re.compile(
    r"(^|[._+-])(no[._-]?reply|do[._-]?not[._-]?reply|notifications?|alerts?|"
    r"news(letters?)?|marketing|mailer[._-]?daemon|postmaster|bounces?|"
    r"promo(tions?)?|offers?|deals|digest|updates?|info)([._+-]|$)"
)


def automated_sender_reason(email: FastEmail) -> Optional[str]:
    """Why this message is machine or bulk mail, or None for a person.

    Returns a short category, never a header value, so the reason can be
    counted in the JSON summary without leaking anything about the mail.
    """
    headers = {k.lower(): (v or "") for k, v in (email.headers or {}).items()}
    for name in _AUTOMATED_HEADERS:
        if headers.get(name, "").strip():
            return "header"
    if headers.get("precedence", "").strip().lower() in _BULK_PRECEDENCE:
        return "precedence"
    auto = headers.get("auto-submitted", "").strip().lower()
    if auto and auto != "no":
        return "auto-submitted"
    local = (email.from_address or "").split("@", 1)[0].lower()
    if _AUTOMATED_LOCAL_RE.search(local):
        return "local-part"
    return None


# The predicates THIS CLI writes for a sender. A Person carrying anything
# else was also seen by another source (Contacts, iMessage, WhatsApp,
# calendar) or enriched, and is never removed from here.
_EMAIL_ONLY_PREDICATES = (
    "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>",
    "pwg:email", "pwg:lastContactEmail", "pwg:displayName",
    "pwg:displayNameProvisional", "skos:prefLabel",
)


def _build_demote(person_iri: str) -> str:
    """SPARQL UPDATE removing a Person this CLI created for an automated
    sender, only while it still has the email-only shape."""
    _check_person_iri(person_iri)
    allowed = ", ".join(_EMAIL_ONLY_PREDICATES)
    return "\n".join([
        "PREFIX pwg: <" + PWG_NS + ">",
        "PREFIX skos: <http://www.w3.org/2004/02/skos/core#>",
        "DELETE { <" + person_iri + "> ?p ?o }",
        "WHERE {",
        "  <" + person_iri + "> a pwg:Person ; ?p ?o .",
        "  FILTER NOT EXISTS { <" + person_iri + "> ?q ?x . FILTER(?q NOT IN (" + allowed + ")) }",
        "  FILTER NOT EXISTS { ?other ?r <" + person_iri + "> }",
        "}",
    ])



_IRI_FORBIDDEN = set('<>" \t\r\n{}|\\^`')


def _check_person_iri(person_iri: str) -> None:
    """Refuse anything that is not a plain IRI in our person namespace
    before it is spliced into SPARQL (Archie, review of CM051 #2479)."""
    prefix = PWG_NS + "person_"
    if (not isinstance(person_iri, str) or not person_iri.startswith(prefix)
            or len(person_iri) <= len(prefix)
            or any(c in _IRI_FORBIDDEN for c in person_iri)):
        raise ValueError("refused: not a person IRI in the pwg namespace")


_BACKUP_NAME = "demoted_people.jsonl"


def _backup_path() -> Path:
    root = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(root) / "state" / _BACKUP_NAME


def _backup_person(endpoint: str, person_iri: str, reason: str) -> int:
    """Append every triple the demote WOULD remove to the backup file BEFORE
    the UPDATE runs. Returns the triple count. Raises on any failure, so a
    Person is never deleted without its backup."""
    _check_person_iri(person_iri)
    allowed = ", ".join(_EMAIL_ONLY_PREDICATES)
    q = "\n".join([
        "PREFIX pwg: <" + PWG_NS + ">",
        "PREFIX skos: <http://www.w3.org/2004/02/skos/core#>",
        "SELECT ?p ?o WHERE {",
        "  <" + person_iri + "> a pwg:Person ; ?p ?o .",
        "  FILTER NOT EXISTS { <" + person_iri + "> ?q ?x . FILTER(?q NOT IN (" + allowed + ")) }",
        "  FILTER NOT EXISTS { ?other ?r <" + person_iri + "> }",
        "}",
    ])
    rows = _sparql_select(endpoint, q)
    if not rows:
        return 0
    path = _backup_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).isoformat()
    with open(path, "a", encoding="utf-8") as fh:
        for p, o in rows:
            fh.write(json.dumps({"at": ts, "reason": reason, "s": person_iri, "p": p, "o": o}) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    return len(rows)


def _sparql_select(endpoint: str, query: str, timeout: float = 10.0) -> list:
    """(p, o) pairs from a SELECT, over the same httpx transport as updates
    (so the store-auth shim in the service venv applies to both)."""
    import httpx
    response = httpx.post(
        endpoint.rstrip("/") + "/query",
        content=query,
        headers={"Content-Type": "application/sparql-query",
                 "Accept": "application/sparql-results+json"},
        timeout=timeout,
    )
    response.raise_for_status()
    body = response.json()
    out = []
    for b in body.get("results", {}).get("bindings", []):
        out.append((b["p"]["value"], b["o"]["value"]))
    return out


def _demote(endpoint: str, person_iri: str, reason: str) -> int:
    """Backup, THEN delete. Returns the triples backed up (0 = nothing to do)."""
    n = _backup_person(endpoint, person_iri, reason)
    if n:
        _post_sparql_update(endpoint, _build_demote(person_iri))
    return n


def _post_sparql_update(endpoint: str, query: str, timeout: float = 5.0) -> None:
    """POST a SPARQL UPDATE to Oxigraph.

    Imported lazily so the CLI's `--help` path works in environments
    without httpx installed (e.g. CI scaffolding for the structural
    vendor regression test).
    """
    import httpx

    url = endpoint.rstrip("/") + "/update"
    response = httpx.post(
        url,
        content=query,
        headers={"Content-Type": "application/sparql-update"},
        timeout=timeout,
    )
    response.raise_for_status()


def cmd_mbox(args: argparse.Namespace) -> int:
    """Run the mbox ingest path. Returns the process exit code."""
    mbox_path = Path(args.path)

    started = time.time()
    result: Dict[str, Any] = {
        "messages_read": 0,
        "people_extracted": 0,
        "signatures_extracted": 0,
        "skipped": 0,
        "skipped_automated": 0,
        "people_demoted": 0,
        "errors": [],
    }

    # Empty / missing mbox => graceful exit. install.sh reads the
    # counts and renders MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT.
    if not mbox_path.exists():
        _stderr(f"pwg-email-ingest: mbox not found at {mbox_path}; nothing to ingest.")
        if args.json:
            print(json.dumps(result))
        return 0

    if mbox_path.stat().st_size == 0:
        _stderr(f"pwg-email-ingest: mbox empty at {mbox_path}; nothing to ingest.")
        if args.json:
            print(json.dumps(result))
        return 0

    # Date cutoff. backfill-days reads against today's wall-clock
    # (timezone-aware UTC). Emails older than the cutoff are counted
    # in `skipped` so install.sh can render an honest "N skipped"
    # detail if it wants to.
    cutoff: Optional[datetime] = None
    if args.backfill_days is not None and args.backfill_days > 0:
        cutoff = datetime.now(timezone.utc) - timedelta(days=args.backfill_days)

    seen_emails: Set[str] = set()
    demoted: Set[str] = set()
    email_filter = EmailFilter()
    parser = FastMboxParser(str(mbox_path), email_filter=email_filter)

    for email in parser.stream():
        result["messages_read"] += 1

        # Skip the user's own outbound mail -- we want correspondents,
        # not the user. The parser's is_sent flag is best-effort
        # (Gmail-Labels header + user_domain heuristic). For v1.0
        # we accept the false-negative rate; the customer's "last
        # contact with X" will still be correct because every
        # outbound has a corresponding inbound thread head.
        if email.is_sent:
            result["skipped"] += 1
            continue

        if not email.from_address or "@" not in email.from_address:
            result["skipped"] += 1
            continue

        # Domain-noise filter (newsletters, automated senders, etc.).
        # Reuses CM021's curated EmailFilter list.
        if email_filter.should_exclude_domain(email.from_domain):
            result["skipped"] += 1
            continue

        # Machine and bulk mail is not a person (CM051 v1.0.106). Count it,
        # and remove a Person this CLI made for the same sender earlier,
        # but only while that node still has the email-only shape.
        if automated_sender_reason(email) is not None:
            result["skipped"] += 1
            result["skipped_automated"] += 1
            addr_auto = email.from_address.lower()
            if not args.dry_run and addr_auto not in demoted:
                demoted.add(addr_auto)
                try:
                    if _demote(args.graph_endpoint, _safe_person_iri(addr_auto),
                               automated_sender_reason(email) or "automated"):
                        result["people_demoted"] += 1
                except Exception as exc:
                    if len(result["errors"]) < 5:
                        result["errors"].append(type(exc).__name__)
            continue

        # Date filter. Emails with no date header pass through;
        # they're rare on legitimate correspondence.
        if cutoff is not None and email.date is not None:
            email_dt = email.date
            if email_dt.tzinfo is None:
                email_dt = email_dt.replace(tzinfo=timezone.utc)
            if email_dt < cutoff:
                result["skipped"] += 1
                continue

        addr = email.from_address.lower()
        if addr in seen_emails:
            # Multiple emails from the same correspondent in this
            # mbox => upsert wins, but we count this correspondent
            # once for the "people_extracted" headline number. The
            # upsert still runs so lastContactEmail tracks the
            # latest message in the chunk.
            pass
        else:
            seen_emails.add(addr)

        if not args.dry_run:
            try:
                last_contact_iso = (
                    email.date.astimezone(timezone.utc).isoformat()
                    if email.date is not None
                    else None
                )
                query = _build_upsert(
                    person_iri=_safe_person_iri(addr),
                    email=addr,
                    name=email.from_name or "",
                    last_contact_iso=last_contact_iso,
                )
                _post_sparql_update(args.graph_endpoint, query)
            except Exception as exc:
                # Collect the first few errors but cap the list so a
                # broken Oxigraph endpoint doesn't blow up the JSON
                # payload. Privacy: the message must not contain the
                # email address (which is in the SPARQL query) -- we
                # surface only the exception type and a generic
                # description.
                if len(result["errors"]) < 5:
                    result["errors"].append(type(exc).__name__)

    result["people_extracted"] = len(seen_emails)

    elapsed = time.time() - started
    _stderr(
        f"pwg-email-ingest: processed mbox in {elapsed:.1f}s; "
        f"messages_read={result['messages_read']} "
        f"people_extracted={result['people_extracted']} "
        f"skipped={result['skipped']} "
        f"skipped_automated={result['skipped_automated']} "
        f"errors={len(result['errors'])}"
    )

    if args.json:
        print(json.dumps(result))

    # Errors during the upsert loop do NOT propagate to the exit
    # code -- they're surfaced in the JSON so install.sh can decide.
    # A non-zero exit would cause launchd to flag the LaunchAgent as
    # failing on every hourly tick, which is overkill for transient
    # Oxigraph hiccups.
    return 0


def _add_mbox_subcommand(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser(
        "mbox",
        help="Ingest correspondents from an mbox file into Oxigraph.",
        description=(
            "Stream-parse an mbox file, filter noise + outbound, and "
            "upsert Person + lastContactEmail triples for each remaining "
            "correspondent."
        ),
    )
    p.add_argument("path", help="Path to the mbox file to ingest.")
    p.add_argument(
        "--backfill-days",
        type=int,
        default=None,
        help=(
            "Only ingest emails dated within the last N days "
            "(default: process the entire mbox)."
        ),
    )
    p.add_argument(
        "--graph-endpoint",
        default=os.environ.get("OXIGRAPH_URL", _OXIGRAPH_DEFAULT),
        help=(
            "Oxigraph SPARQL endpoint root "
            f"(default: {_OXIGRAPH_DEFAULT} or $OXIGRAPH_URL if set)."
        ),
    )
    p.add_argument(
        "--json",
        action="store_true",
        help=(
            "Emit a single structured JSON line to stdout on completion. "
            "Counts only -- no email content."
        ),
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse + count but do not write to Oxigraph.",
    )



def cmd_reclassify_mail(args: argparse.Namespace) -> int:
    """One-off: remove Persons earlier ticks made for automated senders.

    The hourly tick only sees new mail, so a sender turned into a Person
    before v1.0.106 is never looked at again. This reads the HEADERS only
    (never a body) of every .emlx in the Mail store, finds the automated
    senders, and runs the same guarded demote as the tick. Counts only in
    the JSON, never an address.
    """
    import email.parser
    from types import SimpleNamespace

    result: Dict[str, Any] = {"files_read": 0, "unreadable": 0,
                              "automated_senders": 0, "people_demoted": 0,
                              "errors": []}
    root = Path(args.mail_dir).expanduser()
    automated: Set[str] = set()
    reasons: Dict[str, str] = {}
    hp = email.parser.BytesHeaderParser()
    for path in root.rglob("*.emlx"):
        result["files_read"] += 1
        try:
            with open(path, "rb") as fh:
                fh.readline()  # emlx: first line is the byte count
                head = b""
                for line in fh:
                    if line in (b"\n", b"\r\n"):
                        break
                    head += line
            msg = hp.parsebytes(head)
            frm = email.utils.parseaddr(msg.get("From", ""))[1].strip().lower()
        except Exception:
            result["unreadable"] += 1
            continue
        if "@" not in frm or frm in automated:
            continue
        probe = SimpleNamespace(from_address=frm, headers=dict(msg.items()))
        why = automated_sender_reason(probe)
        if why is not None:
            automated.add(frm)
            reasons[frm] = why
    result["automated_senders"] = len(automated)
    result["by_rule"] = {r: sum(1 for v in reasons.values() if v == r) for r in sorted(set(reasons.values()))}
    result["backup"] = str(_backup_path())
    if not args.dry_run:
        for addr in sorted(automated):
            try:
                if _demote(args.graph_endpoint, _safe_person_iri(addr), reasons[addr]):
                    result["people_demoted"] += 1
            except Exception as exc:
                if len(result["errors"]) < 5:
                    result["errors"].append(type(exc).__name__)
    print(json.dumps(result))
    return 0


def _add_reclassify_subcommand(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser(
        "reclassify-mail",
        help="One-off: remove Persons made for automated senders (headers only).",
    )
    p.add_argument("mail_dir", nargs="?", default="~/Library/Mail")
    p.add_argument("--graph-endpoint", default="http://localhost:7878")
    p.add_argument("--dry-run", action="store_true")


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="pwg-email-ingest",
        description=(
            "Ostler hub email-ingest CLI. Invoked by the email-ingest "
            "LaunchAgent's hourly tick and by install.sh's hydrate_email "
            "sub-phase."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    _add_mbox_subcommand(sub)
    _add_reclassify_subcommand(sub)

    args = parser.parse_args(argv)
    if args.cmd == "mbox":
        return cmd_mbox(args)
    if args.cmd == "reclassify-mail":
        return cmd_reclassify_mail(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
